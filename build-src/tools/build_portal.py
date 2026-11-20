"""Customer portals: one private, locked file per store, built every night from the QuickBooks history.
Usage: python3 -I build_portal.py <raw_dir> <build/data.json> <sync.json> <out_dir>
Each store's link is  https://chuster.netlify.app/c/#<id>.<key>
  id  = first 22 chars of base64url(HMAC(PS, "id|<v>|<name>"))     -> file name, <out_dir>/<id>.json
  key = HMAC(PS, "key|<v>|<name>")  (32 bytes, base64url in the link) -> AES-GCM key; never sent to the server
  PS  = HMAC(sync key, "chuster-portal-v1")   (the app computes the same link from the same key)
The payload has no build date, and the IV comes from the content, so a store's file only changes when its
numbers change (keeps the repo small). Days late, aging and "this year vs last year" are worked out in the page.
"""
import base64, collections, glob, hashlib, hmac, json, os, re, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

RAW, DATA, SYNC, OUT = sys.argv[1:5]
D = json.load(open(DATA, encoding='utf-8'))
cfg = json.load(open(SYNC, encoding='utf-8'))
PS = hmac.new(base64.b64decode(cfg['key']), b'chuster-portal-v1', hashlib.sha256).digest()
b64u = lambda b: base64.urlsafe_b64encode(b).decode().rstrip('=')


def sets(prefix):
    out = []
    for p in sorted(glob.glob(os.path.join(RAW, prefix + '_*.json'))):
        out.extend(json.load(open(p, encoding='utf-8')))
    return out


AS_OF = D.get('asOf') or ''
Y0 = str(int(AS_OF[:4]) - 1) + '-01-01' if AS_OF else '2000-01-01'   # from Jan 1 last year: enough for "this year vs last year"
# nice names for items: catalog first, else the text after the last ':'
cat = {c.get('full'): c for c in D.get('catalog', []) if c.get('full')}


def nice(full):
    c = cat.get(full)
    if c:
        nm, pk = c.get('name') or full, c.get('pack') or ''
        return [nm, '' if pk and nm.lower().endswith(pk.lower()) else pk]
    t = str(full).split(':')[-1].strip()
    return [re.sub(r'^\d{3}\s+', '', t), '']


def skip_line(full):
    return not full or (re.search(r'total', full, re.I) and not str(full).startswith(('Packs', 'Chuster Loose', 'Landaus Loose')))


top = lambda c: str(c or '').split(':')[0].strip()
tx = collections.defaultdict(list)    # store -> [kind, date, num, total, lines]
for kind, pre in (('i', 'inv'), ('c', 'cm'), ('r', 'sr')):
    for t in sets(pre):
        if (t.get('d') or '') < Y0:
            continue
        lines = []
        for l in t.get('l', []):
            full, q, amt = l[0], float(l[2] or 0), float(l[3] or 0)
            if skip_line(full) or (not q and not amt):
                continue
            lines.append([full, round(q, 3), round(amt, 2)])
        tot = float(t.get('sub', 0) or 0) + float(t.get('tax', 0) or 0) if kind == 'i' else float(t.get('tot', 0) or 0)
        tx[top(t.get('c'))].append([kind, t['d'], str(t.get('n', '')), round(tot, 2), lines])
pays = collections.defaultdict(list)
for p in sets('pay'):
    if (p.get('d') or '') >= Y0:
        pays[top(p.get('c'))].append([p['d'], round(float(p.get('amt', 0) or 0), 2), str(p.get('n', ''))])

os.makedirs(OUT, exist_ok=True)
made, links = 0, {}
for c in D.get('customers', []):
    name = c.get('name')
    if not name:
        continue
    T = sorted(tx.get(name, []), key=lambda r: (r[1], r[2]))
    if not T and not (c.get('balance') or 0):
        continue
    items = []; idx = {}
    def ii(full):
        if full not in idx:
            idx[full] = len(items); items.append(nice(full))
        return idx[full]
    T2 = [[k, d, n, tot, [[ii(f), q, a] for f, q, a in L]] for k, d, n, tot, L in T]
    payload = {
        'v': 1, 'n': name, 'a': c.get('address') or '', 'ph': c.get('phone') or '', 't': c.get('terms') or '',
        'b': round(c.get('balance') or 0, 2),
        'o': [[o.get('date', ''), str(o.get('num', '')), o.get('due', ''), round(o.get('amt') or 0, 2)] for o in (c.get('open') or [])],
        'it': items, 'tx': T2, 'p': sorted(pays.get(name, [])),
    }
    raw = json.dumps(payload, separators=(',', ':'), ensure_ascii=False, sort_keys=True).encode('utf-8')
    v = '1'
    fid = b64u(hmac.new(PS, ('id|' + v + '|' + name).encode(), hashlib.sha256).digest())[:22]
    key = hmac.new(PS, ('key|' + v + '|' + name).encode(), hashlib.sha256).digest()
    iv = hmac.new(key, raw, hashlib.sha256).digest()[:12]
    body = b64u(iv) + '.' + b64u(AESGCM(key).encrypt(iv, raw, None))
    path = os.path.join(OUT, fid + '.json')
    old = open(path).read() if os.path.exists(path) else None
    if old != body:
        open(path, 'w').write(body)
    made += 1
json.dump({'asOf': AS_OF}, open(os.path.join(OUT, 'meta.json'), 'w'))
print(f'portals: {made} stores (history from {Y0})')
