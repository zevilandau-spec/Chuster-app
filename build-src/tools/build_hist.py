"""What every customer bought: per customer, per product, per month (cases) + per Yom Tov season. For 'Ask the portal'.
Usage: python3 -I build_hist.py <export_folder> <data.json>
"""
import csv, json, sys, os, collections, datetime as dt

SRC, DATA = sys.argv[1], sys.argv[2]
INTERNAL = 'Chuster Packaging Wholsale'


def text(p):
    b = open(p, 'rb').read()
    try:
        return b.decode('utf-8-sig')
    except UnicodeDecodeError:
        return b.decode('cp1252')


def num(x):
    try:
        return float(str(x).replace(',', ''))
    except ValueError:
        return 0.0


data = json.load(open(DATA))
cat = {c['full']: i for i, c in enumerate(data['catalog'])}
cust = {c['name']: i for i, c in enumerate(data['customers'])}
months = data['reps']['months']; mi = {m: i for i, m in enumerate(months)}
seas = []  # [name, year, start, end]
for s in data['seasons']:
    for r in s['rows']:
        seas.append([s['name'], r['year'], r['start'], r['end']])
Q = collections.defaultdict(float); A = collections.defaultdict(float); SQ = collections.defaultdict(float)
for y in sorted(int(p[-8:-4]) for p in __import__('glob').glob(os.path.join(SRC, 'derived/Chuster_Sales_Lines_*.csv'))):
    p = os.path.join(SRC, f'derived/Chuster_Sales_Lines_{y}.csv')
    if not os.path.exists(p):
        continue
    for r in csv.DictReader(text(p).splitlines()):
        if r['Customer'] == INTERNAL or r['Customer'] not in cust:
            continue
        it = r['Item']; full = it.rsplit(' (', 1)[0].strip() if it.endswith(')') and ' (' in it else it.strip()
        i = cat.get(full)
        if i is None:
            continue
        m, d, yy = r['Date'].split('/'); mon = f'{yy}-{m}'
        if mon not in mi:
            continue
        k = (cust[r['Customer']], i, mi[mon]); q = num(r['Qty']); Q[k] += q; A[k] += num(r['Amount'])
        iso = f'{yy}-{m}-{d}'
        for si, (n, yr, a, b) in enumerate(seas):
            if a <= iso <= b:
                SQ[(cust[r['Customer']], i, si)] += q
# compact: per customer "item:month=q|month=q;item:..." keeps the JSON small
H = {}
by = collections.defaultdict(lambda: collections.defaultdict(list))
for (c, i, m), q in Q.items():
    if abs(q) >= 0.01:
        by[c][i].append((m, round(q, 2), round(A[(c, i, m)])))
for c, items in by.items():
    H[c] = ';'.join(f'{i}:' + '|'.join(f'{m}={q:g}' for m, q, a in sorted(v)) for i, v in items.items())
SS = collections.defaultdict(list)
for (c, i, si), q in SQ.items():
    if abs(q) >= 0.01:
        SS[c].append(f'{i}:{si}={q:g}')
data['hist'] = {'seasons': seas, 'q': {str(k): v for k, v in H.items()}, 's': {str(k): ';'.join(v) for k, v in SS.items()}}
json.dump(data, open(DATA, 'w'), separators=(',', ':'))
print('customers', len(H), '| cells', sum(1 for _ in Q), '| bytes', len(json.dumps(data['hist'])))
