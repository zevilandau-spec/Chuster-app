"""Customer portals: one private, locked file per store, built every night from the QuickBooks history.
Usage: python3 -I build_portal.py <raw_dir> <build/data.json> <sync.json> <out_dir>
Each store's link is  https://chuster.netlify.app/c/#<id>.<key>
  id  = first 22 chars of base64url(HMAC(PS, "id|<v>|<name>"))     -> file name, <out_dir>/<id>.json
  key = HMAC(PS, "key|<v>|<name>")  (32 bytes, base64url in the link) -> AES-GCM key; never sent to the server
  PS  = HMAC(sync key, "chuster-portal-v1")   (the app computes the same link from the same key)
The payload has no build date, and the IV comes from the content, so a store's file only changes when its
numbers change (keeps the repo small). Days late, aging and "this year vs last year" are worked out in the page.
"""
import base64, collections, datetime as dt, glob, hashlib, hmac, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import heb
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

# ---- settings (news, order cutoff, salesmen's WhatsApp) ----
CFGP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'portal.json')
PC = json.load(open(CFGP, encoding='utf-8')) if os.path.exists(CFGP) else {}
REPN = D.get('repNames') or {}

# ---- Yom Tov dates: the next 12 months, and the same Yom Tov last year ----
TODAY = dt.date.fromisoformat(AS_OF) if AS_OF else dt.date.today()
YT = [  # key, name, hebrew month, day, days it runs, closed (no delivery), days before to look at last year
    ('ch', 'Chanukah', 9, 25, 8, False, 21), ('pu', 'Purim', 'adar', 14, 1, False, 14), ('pe', 'Pesach', 1, 15, 8, True, 30),
    ('sh', 'Shavuos', 3, 6, 2, True, 14), ('rh', 'Rosh Hashana', 7, 1, 2, True, 21), ('su', 'Sukkos', 7, 15, 9, True, 21)]


def yt_date(m, d, hy):
    if m == 'adar':
        m = heb.last_month(hy)
    return dt.date.fromordinal(heb.to_abs(m, d, hy))


def yt_upcoming():
    hy = heb.from_abs(TODAY.toordinal())[2]
    out = []
    for y in (hy, hy + 1):
        for k, nm, m, d, ln, closed, back in YT:
            g = yt_date(m, d, y)
            if g + dt.timedelta(days=ln - 1) >= TODAY and g <= TODAY + dt.timedelta(days=365):
                prev = yt_date(m, d, y - 1)
                out.append({'k': k, 'h': nm, 'd': g.isoformat(), 'n': ln, 'x': closed, 'back': back, 'ly': prev.isoformat()})
    return sorted(out, key=lambda r: r['d'])


UPC = yt_upcoming()
NEXT_YT = next((u for u in UPC if (dt.date.fromisoformat(u['d']) - TODAY).days <= 60), None)
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
        'r': [c.get('rep') or '', REPN.get(c.get('rep') or '', '')],
    }
    if NEXT_YT:   # what this store bought for the same Yom Tov last year
        a = (dt.date.fromisoformat(NEXT_YT['ly']) - dt.timedelta(days=NEXT_YT['back'])).isoformat()
        b = (dt.date.fromisoformat(NEXT_YT['ly']) + dt.timedelta(days=NEXT_YT['n'] - 1)).isoformat()
        got = collections.Counter()
        for k, d, n, tot, L in T2:
            if a <= d <= b and k in ('i', 'c'):
                for i, q, amt in L:
                    got[i] += q if k == 'i' else -abs(q)
        its = [[i, round(q)] for i, q in got.most_common() if q >= 1][:10]
        if its:
            payload['yt'] = {'k': NEXT_YT['k'], 'h': NEXT_YT['h'], 'd': NEXT_YT['d'], 'from': a, 'to': b, 'items': its}
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
# one shared file for every store: news, order cutoff, Yom Tov dates, products (names and case sizes only, no prices)
CAT = [[c.get('full'), c.get('name') or '', c.get('pack') or '', c.get('group') or '', c.get('code') or ''] for c in D.get('catalog', []) if c.get('full') and not c.get('off')]
info = {'asOf': AS_OF, 'news': PC.get('news'), 'cutoff': PC.get('cutoff', ''), 'office': PC.get('office', {}), 'kosher': PC.get('kosher', ''),
        'reps': PC.get('reps', {}), 'closed': PC.get('closedDays', [6]), 'yt': [{k: u[k] for k in ('k', 'h', 'd', 'n', 'x')} for u in UPC],
        'cat': [[nice(f)[0], nice(f)[1], g, code] for f, n, p, g, code in CAT]}
json.dump(info, open(os.path.join(OUT, 'meta.json'), 'w'), ensure_ascii=False, separators=(',', ':'))
print(f'portals: {made} stores (history from {Y0})')
