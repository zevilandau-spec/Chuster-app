"""Add the 'books' part of QuickBooks to the app data: expenses, deposits, vendors and bill payments,
sales orders and estimates, stock moves, all purchase orders, journal entries, chart of accounts.
Reads the raw sets the office PC sent. Usage: python3 -I build_extra.py <raw_dir> <data.json>
"""
import collections, datetime as dt, glob, json, os, sys

RAW, DATA = sys.argv[1], sys.argv[2]
data = json.load(open(DATA))
as_of = dt.date.fromisoformat(data['asOf'])


def load(name, default=None):
    p = os.path.join(RAW, name + '.json')
    return json.load(open(p, encoding='utf-8')) if os.path.exists(p) else default


def years(prefix):
    out = []
    for p in sorted(glob.glob(os.path.join(RAW, prefix + '_*.json'))):
        out.extend(json.load(open(p, encoding='utf-8')))
    return out


def days_ago(d):
    try:
        return (as_of - dt.date.fromisoformat(d)).days
    except (TypeError, ValueError):
        return 99999


r2 = lambda x: round(float(x or 0), 2)
exp, dep, bp, je = years('exp'), years('dep'), years('bp'), years('je')
so, est, adj, bld, poall, pur = years('so'), years('est'), years('adj'), years('build'), years('poall'), years('pur')
vendors, accounts = load('vendors', []), load('accounts', [])
if not any([exp, dep, bp, je, so, est, adj, bld, poall, vendors, accounts]):
    print('books: nothing yet'); sys.exit(0)

# months the app shows (same range as the P&L)
first = min([x['d'] for x in exp + dep if x.get('d')] or [as_of.isoformat()])[:7]
months = []
y, m = int(first[:4]), int(first[5:7])
while (y, m) <= (as_of.year, as_of.month):
    months.append(f'{y}-{m:02d}'); m += 1
    if m == 13:
        y, m = y + 1, 1
mi = {k: i for i, k in enumerate(months)}

# ---- expenses: per account per month, per vendor, recent list
by_acct = collections.defaultdict(lambda: [0.0] * len(months))
by_vendor = collections.defaultdict(lambda: [0.0, 0.0])  # last 12 months, this year
recent = []
for t in exp:
    k = mi.get(t['d'][:7]); tot = sum(float(l[2] or 0) for l in t['l'])
    for l in t['l']:
        if k is not None:
            by_acct[l[0] or 'No account'][k] += float(l[2] or 0)
    if days_ago(t['d']) < 365: by_vendor[t.get('v') or '—'][0] += tot
    if t['d'][:4] == str(as_of.year): by_vendor[t.get('v') or '—'][1] += tot
    if days_ago(t['d']) < 180:
        recent.append([t['d'], t['t'], t.get('n', ''), t.get('v', ''), t.get('acct', ''), r2(tot), [[l[0], r2(l[2]), l[1]] for l in t['l']][:6]])
recent.sort(key=lambda x: x[0], reverse=True)
expenses = {'months': months, 'accounts': sorted(([a, [r2(v) for v in vals]] for a, vals in by_acct.items()), key=lambda x: -sum(x[1][-12:])),
            'vendors': sorted(([v, r2(a[0]), r2(a[1])] for v, a in by_vendor.items()), key=lambda x: -x[1])[:150], 'recent': recent[:600]}

# ---- bank: deposits per account per month, recent deposits, bank and card balances
dep_m = collections.defaultdict(lambda: [0.0] * len(months)); drecent = []
for t in dep:
    k = mi.get(t['d'][:7])
    if k is not None: dep_m[t.get('to') or '—'][k] += float(t.get('tot') or 0)
    if days_ago(t['d']) < 180:
        who = collections.Counter()
        for l in t['l']: who[l[0] or l[1] or '—'] += float(l[3] or 0)
        drecent.append([t['d'], t.get('to', ''), r2(t.get('tot')), len(t['l']), [[w, r2(a)] for w, a in who.most_common(8)], t.get('memo', '')])
drecent.sort(key=lambda x: x[0], reverse=True)
bank = {'months': months, 'deposits': [[a, [r2(v) for v in vals]] for a, vals in dep_m.items()], 'recent': drecent[:500],
        'accounts': [[a['n'], a['type'], r2(a.get('bal'))] for a in accounts if a.get('active', True) and a.get('type') in ('Bank', 'CreditCard', 'OtherCurrentAsset', 'OtherCurrentLiability', 'LongTermLiability')]}

# ---- vendors: what we owe, what we bought, bill payments
spend = collections.defaultdict(float)
for t in pur:
    if days_ago(t['d']) < 365: spend[t.get('v') or '—'] += sum(float(l[4] or 0) for l in t['l'])
for t in exp:
    if days_ago(t['d']) < 365: spend[t.get('v') or '—'] += sum(float(l[2] or 0) for l in t['l'])
last_paid = {}
for t in bp:
    v = t.get('v') or '—'
    if v not in last_paid or t['d'] > last_paid[v][0]: last_paid[v] = (t['d'], r2(t.get('amt')))
vlist = []
for v in vendors:
    if not v.get('active', True) and abs(v.get('bal') or 0) < 0.01 and v['n'] not in spend: continue
    lp = last_paid.get(v['n'])
    vlist.append([v['n'], r2(v.get('bal')), r2(spend.get(v['n'], 0)), v.get('phone', ''), v.get('email', ''), v.get('terms', ''), lp[0] if lp else None, lp[1] if lp else None, v.get('type', '')])
vlist.sort(key=lambda x: (-abs(x[1]), -x[2]))
payrec = sorted(([t['d'], t['t'], t.get('n', ''), t.get('v', ''), t.get('acct', ''), r2(t.get('amt'))] for t in bp if days_ago(t['d']) < 180), key=lambda x: x[0], reverse=True)
vend = {'list': vlist, 'payments': payrec[:500]}

# ---- sales orders and estimates
def doc(t):
    return [t['d'], t.get('n', ''), t.get('c', ''), r2(t.get('tot')), t.get('ship', ''), [[l[0], l[1], l[2], l[4] or 0, r2(l[3])] for l in t['l']], t.get('memo', '')]


so_open = [doc(t) for t in so if not t.get('closed') and not t.get('done')]
so_open.sort(key=lambda x: x[0], reverse=True)
so_done = sum(1 for t in so if (t.get('closed') or t.get('done')) and days_ago(t['d']) < 90)
est_open = sorted((doc(t) for t in est if days_ago(t['d']) < 365 and not t.get('closed')), key=lambda x: x[0], reverse=True)
orders = {'so': so_open[:400], 'soDone90': so_done, 'est': est_open[:300]}

# ---- stock moves: adjustments and assembly builds
adjr = sorted(([t['d'], t.get('n', ''), t.get('acct', ''), t.get('memo', ''), [[l[0], l[1], r2(l[2])] for l in t['l']]] for t in adj if days_ago(t['d']) < 365), key=lambda x: x[0], reverse=True)
bldr = sorted(([t['d'], t.get('n', ''), t.get('item', ''), t.get('q'), bool(t.get('pending')), t.get('memo', '')] for t in bld if days_ago(t['d']) < 365), key=lambda x: x[0], reverse=True)
stock = {'adj': adjr[:600], 'build': bldr[:800]}

# ---- every purchase order (two years)
pos = []
for t in poall:
    if days_ago(t['d']) > 730: continue
    q = sum(float(l[2] or 0) for l in t['l']); rc = sum(min(float(l[3] or 0), float(l[2] or 0)) for l in t['l'])
    tot = t.get('tot') or sum(float(l[2] or 0) * float(l[4] or 0) for l in t['l'])
    st = 'closed' if t.get('closed') else 'received' if t.get('rcv') else 'part' if rc > 0 else 'open'
    pos.append([t['d'], t.get('n', ''), t.get('v', ''), r2(tot), st, t.get('deliv', ''), round(rc / q * 100) if q else 0, [[l[0], l[2], l[3]] for l in t['l']][:12]])
pos.sort(key=lambda x: x[0], reverse=True)

# ---- journal entries and chart of accounts
jer = sorted(([t['d'], t.get('n', ''), bool(t.get('adj')), [[l[0], l[1], r2(l[2]), l[3], l[4]] for l in t['l']]] for t in je if days_ago(t['d']) < 365), key=lambda x: x[0], reverse=True)
acc = [[a['n'], a['type'], a.get('num', ''), r2(a.get('bal')), bool(a.get('active', True))] for a in accounts]

data['books'] = {'asOf': data['asOf'], 'expenses': expenses, 'bank': bank, 'vendors': vend, 'orders': orders, 'stock': stock, 'po': pos[:800], 'journal': jer[:400], 'accounts': acc}
json.dump(data, open(DATA, 'w'), separators=(',', ':'))
print('books', len(json.dumps(data['books'])), 'bytes | expenses', len(exp), 'deposits', len(dep), 'bill payments', len(bp), 'open sales orders', len(so_open), 'estimates', len(est_open), 'adjustments', len(adjr), 'builds', len(bldr), 'POs', len(pos), 'journal', len(jer), 'accounts', len(acc))
