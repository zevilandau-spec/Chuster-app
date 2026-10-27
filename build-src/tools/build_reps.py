"""Sales and payments per sales rep, per month and per customer (rep = the customer's rep in QuickBooks today).
Usage: python3 -I build_reps.py <export_folder> <data.json>
"""
import csv, json, sys, os, collections

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
rep_of = {c['name']: (c.get('rep') or '—') for c in data['customers']}
flat = csv.DictReader(text(sorted(__import__('glob').glob(os.path.join(SRC, 'derived/Chuster_Customer_Transactions_Flat_*.csv')))[-1]).splitlines())
S = collections.defaultdict(float); P = collections.defaultdict(float); N = collections.defaultdict(int)
CS = collections.defaultdict(float)  # (customer, month) -> sales
months = set()
for r in flat:
    c = r['Customer']
    if c == INTERNAL or not r['Date']:
        continue
    m, d, y = r['Date'].split('/'); mon = f'{y}-{m}'
    rep = rep_of.get(c, '—')
    if r['Type'] == 'Invoice':
        a = num(r['Debit']); S[(rep, mon)] += a; N[(rep, mon)] += 1; CS[(c, mon)] += a
    elif r['Type'] == 'Credit Memo':
        a = -num(r['Credit']); S[(rep, mon)] += a; CS[(c, mon)] += a
    elif r['Type'] == 'Payment':
        P[(rep, mon)] += num(r['Debit']) - num(r['Credit'])
    else:
        continue
    months.add(mon)
months = sorted(months)
reps = sorted({k[0] for k in S}, key=lambda r: -sum(v for k, v in S.items() if k[0] == r))
custs = sorted({k[0] for k in CS})
data['reps'] = {
    'months': months,
    'list': [{'code': r, 'sales': [round(S[(r, m)], 2) for m in months], 'paid': [round(P[(r, m)], 2) for m in months], 'inv': [N[(r, m)] for m in months]} for r in reps],
    # per customer per month sales, sparse: name -> [[monthIdx, amount], ...]
    'cust': {c: [[i, round(CS[(c, m)], 2)] for i, m in enumerate(months) if abs(CS[(c, m)]) >= 0.005] for c in custs},
}
json.dump(data, open(DATA, 'w'), separators=(',', ':'))
print('months', months[0], '→', months[-1], '| reps', [(x['code'], round(sum(x['sales'][-12:]))) for x in data['reps']['list']])
print('total sales all months', round(sum(S.values()), 2), '| payments', round(sum(P.values()), 2))
