"""Every invoice of the last ~14 months, compact, for the salesman dashboard: day -> [[customerIdx, amount, cases], ...].
Cases come from the sales lines (packs); invoices newer than the sales lines have cases = null.
Usage: python3 -I build_daily.py <export_folder> <data.json>
"""
import csv, json, sys, os, collections, datetime as dt
SRC, DATA = sys.argv[1:3]
INTERNAL = 'Chuster Packaging Wholsale'
def text(p):
    b = open(p, 'rb').read()
    try: return b.decode('utf-8-sig')
    except UnicodeDecodeError: return b.decode('cp1252')
def num(x):
    try: return float(str(x).replace(',', ''))
    except ValueError: return 0.0
def day(s): m, d, y = s.split('/'); return dt.date(int(y), int(m), int(d))
data = json.load(open(DATA)); as_of = dt.date.fromisoformat(data['asOf']); start = as_of - dt.timedelta(days=430)
ci = {c['name']: i for i, c in enumerate(data['customers'])}
cases = collections.Counter(); lines_to = None
for y in sorted({start.year, as_of.year, as_of.year - 1}):
    p = os.path.join(SRC, f'derived/Chuster_Sales_Lines_{y}.csv')
    if not os.path.exists(p): continue
    for r in csv.DictReader(text(p).splitlines()):
        if r['Type'] != 'Invoice' or not r['Item'].startswith('Packs'): continue
        cases[(r['Customer'], r['Num'])] += num(r['Qty']); d = day(r['Date'])
        if not lines_to or d > lines_to: lines_to = d
flat = glob = __import__('glob').glob(os.path.join(SRC, 'derived/Chuster_Customer_Transactions_Flat_*.csv'))[0]
days = collections.defaultdict(list)
for r in csv.DictReader(text(flat).splitlines()):
    if r['Type'] not in ('Invoice', 'Credit Memo') or r['Customer'] == INTERNAL or r['Customer'] not in ci: continue
    d = day(r['Date'])
    if not (start <= d <= as_of): continue
    amt = num(r['Debit']) if r['Type'] == 'Invoice' else -num(r['Credit'])
    cs = cases.get((r['Customer'], r['Num'])) if r['Type'] == 'Invoice' and d <= lines_to else (0 if r['Type'] != 'Invoice' else None)
    days[d.isoformat()].append([ci[r['Customer']], round(amt, 2), cs if cs is None else round(cs)])
data['daily'] = {'from': start.isoformat(), 'to': as_of.isoformat(), 'casesTo': lines_to.isoformat(), 'days': dict(sorted(days.items()))}
json.dump(data, open(DATA, 'w'), separators=(',', ':'))
print('daily', len(days), 'days', sum(len(v) for v in days.values()), 'invoices | cases known to', lines_to, '| bytes', len(json.dumps(data['daily'])))
