"""Diagnostics only: did the office PC send open POs for the Order Tracker, and which items match? Prints counts and product names, no customers."""
import json, os, re, base64, hmac, hashlib, gzip, urllib.request
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
S = json.loads(os.environ['CHUSTER_SECRETS'])['sync']; url = os.environ['CHUSTER_DB_URL'].strip().rstrip('/'); sp = S['space']; k = base64.b64decode(S['key'])
EK = hmac.new(k, b'chuster-qb-enc', hashlib.sha256).digest(); MK = hmac.new(k, b'chuster-qb-mac', hashlib.sha256).digest()
def un(v):
    if not isinstance(v, str): return None
    if v.startswith('c1:'):
        b = base64.b64decode(v[3:]); body, mac = b[:-32], b[-32:]
        if not hmac.compare_digest(hmac.new(MK, body, hashlib.sha256).digest(), mac): return None
        d = Cipher(algorithms.AES(EK), modes.CBC(body[:16])).decryptor(); p = d.update(body[16:]) + d.finalize(); p = p[:-p[-1]]
        try: p = gzip.decompress(p)
        except Exception: pass
        return json.loads(p)
    return None
def get(path):
    return json.load(urllib.request.urlopen(f"{url}/{sp}/{path}", timeout=120))
# the PC program version it reports, if any
for c in ('qh',):
    try:
        recs = get(f"{c}.json?orderBy=%22t%22&limitToLast=3") or {}
        for kk, r in recs.items():
            v = un(r.get('v')) if isinstance(r, dict) else None
            if isinstance(v, dict): print("::notice::pc-status " + json.dumps({x: v.get(x) for x in ('k',) if x in v})[:200] + " " + json.dumps(v.get('val') if isinstance(v.get('val'), dict) else {}, default=str)[:300])
    except Exception as e: print("::notice::qh read: " + str(e)[:150])
recs = get("qx.json") or {}
print(f"::notice::qx records: {len(recs)}")
found = None
for kk, r in recs.items():
    v = un(r.get('v')) if isinstance(r, dict) else None
    if isinstance(v, dict) and v.get('k') == 'openpo': found = v.get('val'); break
    if isinstance(v, dict) and v.get('val') and isinstance(v['val'], dict) and 'l' in v['val']: found = v['val']
if not found:
    print("::warning::No open-PO list from the office PC yet (sync 4.3 has not sent qx/openpo).")
else:
    pos = found.get('l') or []; lines = [l for p in pos for l in (p.get('l') or [])]
    print(f"::notice::open POs sent at {found.get('at')}: {len(pos)} POs, {len(lines)} lines")
    src = open('build-src/app/chuster-app.html', encoding='utf-8').read()
    items = json.loads(re.search(r'const OT_ITEMS0 = (\[.*?\]);', src).group(1))
    cp = lambda s: re.sub(r'[^a-z0-9]', '', str(s or '').lower())
    nn = lambda s: re.sub(r'[^a-z0-9]+', ' ', re.sub(r'\b\d{5,}[a-z]*\d*\b|\b[0-9a-z]*\d{4,}[0-9a-z]*\b', ' ', str(s or '').lower())).strip()
    names = {nn(i[1]) for i in items}
    hit, miss = 0, {}
    for l in lines:
        full, desc = str(l[0]), str(l[1] or ''); hay = cp(full + ' ' + desc)
        ok = any(i[0] and len(cp(i[0])) >= 6 and cp(i[0]) in hay for i in items) or any(x in names for x in (nn(full.split(':')[-1]), nn(desc)))
        if ok: hit += 1
        else: miss[full] = miss.get(full, 0) + 1
    print(f"::notice::lines matching a tracker item: {hit} of {len(lines)}")
    for full, n in sorted(miss.items(), key=lambda x: -x[1])[:25]: print(f"::notice::not matched: {full[:90]} (x{n})")
    for l in lines[:8]: print(f"::notice::sample line: {str(l[0])[:70]} | {str(l[1] or '')[:60]}")
