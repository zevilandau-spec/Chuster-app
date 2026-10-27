"""Finance (P&L by month, balance sheet), open purchase orders, sales rep names.
Usage: python3 -I build_fin.py <export_dir> <data.json> <snapshot YYYY-MM-DD>
"""
import csv, json, sys, os, collections
D, DATA, SNAP = sys.argv[1:4]
def rows(p): return list(csv.reader(open(os.path.join(D, p), encoding='utf-8').read().splitlines()))
def num(x):
    try: return float(str(x).replace(',', ''))
    except ValueError: return None
data = json.load(open(DATA))
# ---- P&L by month: keep every line with its indent level (QuickBooks puts headers with empty values)
R = rows('pl.csv'); months = R[0][1:-1]  # last column is TOTAL
lines = []
for r in R[1:]:
    if not r or not r[0]: continue
    vals = [num(x) for x in r[1:len(months) + 1]]
    if all(v is None for v in vals): lines.append({'n': r[0], 'h': 1}); continue
    lines.append({'n': r[0], 'v': [round(v or 0, 2) for v in vals]})
def mkey(m):  # "Jan 23" -> 2023-01, "Oct 1 - 26, 26" -> 2026-10
    mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'].index(m[:3]) + 1
    return f'20{m[-2:]}-{mon:02d}'
data['fin'] = {'months': [mkey(m) for m in months], 'partial': months[-1] if '-' in months[-1] else None, 'pl': lines, 'snap': SNAP}
# ---- balance sheet
B = rows('bs.csv'); bs = []
for r in B[1:]:
    if not r or not r[0]: continue
    v = num(r[1]) if len(r) > 1 else None
    bs.append({'n': r[0], 'v': round(v, 2)} if v is not None else {'n': r[0], 'h': 1})
data['fin']['bs'] = bs
# ---- open purchase orders: what's on the way, per item
P = rows('open_po.csv'); hdr = P[0]; ix = {h: i for i, h in enumerate(hdr)}
po = []; item = None
for r in P[1:]:
    if not r: continue
    if r[0] and not r[0].startswith('Total') and r[0] not in ('Inventory', 'Parts', 'TOTAL'): item = r[0]; continue
    if r[0] or not r[ix['Date']]: continue
    left = num(r[ix['Backordered']]) or 0
    if left <= 0: continue
    full = item.rsplit(' (', 1)[0].strip() if item and item.endswith(')') else item
    po.append({'item': full, 'name': (item.rsplit(' (', 1)[1][:-1] if item and item.endswith(')') else item), 'date': r[ix['Date']], 'num': r[ix['Num']], 'vendor': r[ix['Source Name']] or r[ix['Name']], 'deliv': r[ix['Deliv Date']], 'qty': num(r[ix['Qty']]), 'left': left, 'open': num(r[ix['Open Balance']]) or 0})
data['openPO'] = {'asOf': SNAP, 'list': po}
# ---- sales reps
S = rows('reps.csv'); data['repNames'] = {r[0]: r[1] for r in S[1:] if r and r[0] and r[1] and r[1] != r[0]}
data['snapAsOf'] = SNAP
json.dump(data, open(DATA, 'w'), separators=(',', ':'))
inc = next(l for l in lines if l['n'] == 'Total Income'); net = next(l for l in lines if l['n'] == 'Net Income')
print('P&L months', len(months), months[0], '→', months[-1], '| 2026 income', round(sum(v for m, v in zip(data['fin']['months'], inc['v']) if m.startswith('2026'))), '| 2026 net', round(sum(v for m, v in zip(data['fin']['months'], net['v']) if m.startswith('2026'))))
print('balance lines', len(bs), '| open PO lines', len(po), 'open $', round(sum(p['open'] for p in po)), '| reps', data['repNames'])
