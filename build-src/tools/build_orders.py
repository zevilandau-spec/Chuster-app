"""Add recent orders (QuickBooks invoices) with their lines to the app data.
Usage: python3 -I build_orders.py <export_folder> <data.json> [days=120]
"""
import csv, json, sys, os, collections, datetime as dt

SRC, DATA = sys.argv[1], sys.argv[2]
DAYS = int(sys.argv[3]) if len(sys.argv) > 3 else 120
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


def day(s):
    m, d, y = s.split('/')
    return dt.date(int(y), int(m), int(d))


data = json.load(open(DATA))
as_of = dt.date.fromisoformat(data['asOf'])
start = as_of - dt.timedelta(days=DAYS - 1)
cat = {c['full']: i for i, c in enumerate(data['catalog'])}

# invoice totals (and credit memos) from the transactions file
flat = csv.DictReader(text(sorted(__import__('glob').glob(os.path.join(SRC, 'derived/Chuster_Customer_Transactions_Flat_*.csv')))[-1]).splitlines())
orders = {}
for r in flat:
    if r['Type'] not in ('Invoice', 'Credit Memo') or r['Customer'] == INTERNAL:
        continue
    d = day(r['Date'])
    if not (start <= d <= as_of):
        continue
    amt = num(r['Debit']) if r['Type'] == 'Invoice' else -num(r['Credit'])
    orders[(r['Customer'], r['Num'], r['Type'])] = {'d': d.isoformat(), 'n': r['Num'], 'c': r['Customer'], 't': 'cm' if r['Type'] == 'Credit Memo' else 'inv', 'a': round(amt, 2), 'l': []}

for y in sorted({start.year, as_of.year}):
    for r in csv.DictReader(text(os.path.join(SRC, f'derived/Chuster_Sales_Lines_{y}.csv')).splitlines()):
        k = (r['Customer'], r['Num'], r['Type'])
        if k not in orders:
            continue
        it = r['Item']
        full = it.rsplit(' (', 1)[0].strip() if it.endswith(')') and ' (' in it else it.strip()
        q, a = num(r['Qty']), num(r['Amount'])
        ref = cat.get(full)
        name = None if ref is not None else (it.rsplit(' (', 1)[1][:-1].strip() if it.endswith(')') and ' (' in it else it)
        orders[k]['l'].append([ref if ref is not None else name, q, round(a, 2)])

out = sorted(orders.values(), key=lambda o: (o['d'], o['n']), reverse=True)
data['orders'] = {'from': start.isoformat(), 'to': as_of.isoformat(), 'list': out}
json.dump(data, open(DATA, 'w'), separators=(',', ':'))

by_day = collections.Counter(o['d'] for o in out if o['t'] == 'inv')
amt_day = collections.defaultdict(float)
for o in out:
    if o['t'] == 'inv':
        amt_day[o['d']] += o['a']
print('orders', len(out), 'invoices', sum(by_day.values()), 'credit memos', sum(1 for o in out if o['t'] == 'cm'), 'from', start, 'to', as_of)
print('lines', sum(len(o['l']) for o in out), '| lines not in product list:', sum(1 for o in out for l in o['l'] if isinstance(l[0], str)))
for d in sorted(by_day)[-3:]:
    print('  ', d, by_day[d], 'invoices', round(amt_day[d], 2))
