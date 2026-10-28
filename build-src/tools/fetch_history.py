"""Download the full QuickBooks history the office PC sent to the shared database and unscramble it.
Usage: python3 fetch_history.py <db_url> <sync.json> <raw_out_dir>
"""
import base64, gzip, hashlib, hmac, json, os, sys, urllib.request
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
URL, SYNC, OUT = sys.argv[1].rstrip('/'), sys.argv[2], sys.argv[3]
cfg = json.load(open(SYNC)); key = base64.b64decode(cfg['key'])
EK = hmac.new(key, b'chuster-qb-enc', hashlib.sha256).digest(); MK = hmac.new(key, b'chuster-qb-mac', hashlib.sha256).digest()


def unscramble(c):
    assert c.startswith('c1.'), 'not a c1 record'
    b = base64.b64decode(c[3:]); body, mac = b[:-32], b[-32:]
    if not hmac.compare_digest(hmac.new(MK, body, hashlib.sha256).digest(), mac):
        raise ValueError('wrong key or damaged data')
    d = Cipher(algorithms.AES(EK), modes.CBC(body[:16])).decryptor(); p = d.update(body[16:]) + d.finalize()
    return p[:-p[-1]]


with urllib.request.urlopen(f"{URL}/{cfg['space']}/hx.json", timeout=300) as r:
    hx = json.load(r) or {}
if 'manifest' not in hx:
    sys.exit('No history from the office PC yet.')
man = json.loads(unscramble(hx['manifest']['v']))
prev = os.environ.get('CHUSTER_LAST_HISTORY', '')
if prev and man.get('at', '') <= prev:
    print('history unchanged since', prev); sys.exit(3)
open(os.path.join(os.path.dirname(os.path.abspath(OUT)) or '.', 'history-at.txt'), 'w').write(man.get('at', ''))
os.makedirs(OUT, exist_ok=True)
n = 0
for name, info in man['sets'].items():
    parts = int(info['parts'])
    try:
        c = ''.join(hx[f'{name}-{i:04d}']['v'] for i in range(parts))
    except KeyError:
        sys.exit(f'History piece missing for {name}; the office PC may still be sending.')
    raw = gzip.decompress(unscramble(c))
    if hashlib.sha1(raw).hexdigest() != info['sha']:
        print('note: checksum differs for', name)
    open(os.path.join(OUT, name + '.json'), 'wb').write(raw); n += 1
print('history', man.get('asOf'), 'from', man.get('from'), '|', n, 'sets')
