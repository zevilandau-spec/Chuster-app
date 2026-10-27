"""Turn what the office PC read from QuickBooks (raw JSON sets) into the same files a QuickBooks export gives,
so the normal build makes the app from them.
Usage: python3 -I convert_raw.py <raw_dir> <out_export_dir>
raw_dir holds one <set>.json per set: meta, customers, items, reps, inv_YYYY, cm_YYYY, sr_YYYY, pay_YYYY, pur_YYYY, po, pl, bs
"""
import csv, json, os, sys, glob, datetime as dt, collections

RAW, OUT = sys.argv[1], sys.argv[2]
INTERNAL_CUST = 'Chuster Packaging Wholsale'
INTERNAL_VENDOR = 'Chuster Packaging Retail'


def load(name, default=None):
    p = os.path.join(RAW, name + '.json')
    return json.load(open(p, encoding='utf-8')) if os.path.exists(p) else default


def sets(prefix):
    out = []
    for p in sorted(glob.glob(os.path.join(RAW, prefix + '_*.json'))):
        out.extend(json.load(open(p, encoding='utf-8')))
    return out


def mdy(iso):
    return f'{iso[5:7]}/{iso[8:10]}/{iso[0:4]}' if iso else ''


def money(x):
    return f'{float(x or 0):.2f}'


def qty(x):
    x = float(x or 0)
    return str(int(x)) if x == int(x) else f'{x:g}'


def write(path, header, rows, bom=True):
    full = os.path.join(OUT, path); os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w', encoding='utf-8-sig' if bom else 'utf-8', newline='') as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL)
        if header is not None:
            w.writerow(header)
        w.writerows(rows)


meta = load('meta', {})
AS_OF = meta.get('asOf') or dt.date.today().isoformat()
FROM = meta.get('from') or '2020-01-01'
asof = dt.date.fromisoformat(AS_OF)
tag = AS_OF

items = load('items', [])
desc_of = {it['n']: (it.get('desc') or '') for it in items}


def item_txt(full, desc=None):
    d = desc if desc else desc_of.get(full, '')
    return f'{full} ({d})' if d else full


inv = [dict(x, kind='Invoice') for x in sets('inv')]
cm = [dict(x, kind='Credit Memo') for x in sets('cm')]
sr = [dict(x, kind='Sales Receipt') for x in sets('sr')]
pay = sets('pay')
pur = sets('pur')

# ---------- transactions list by customer (flat) ----------
flat = []
for t in inv:
    flat.append([t['c'], 'Invoice', mdy(t['d']), t.get('n', ''), t.get('memo', ''), 'Accounts Receivable', '', '', money(float(t.get('sub', 0)) + float(t.get('tax', 0))), ''])
for t in cm:
    flat.append([t['c'], 'Credit Memo', mdy(t['d']), t.get('n', ''), t.get('memo', ''), 'Accounts Receivable', '', '', '', money(t.get('tot', 0))])
for t in pay:
    flat.append([t['c'], 'Payment', mdy(t['d']), t.get('n', ''), t.get('memo', ''), 'Undeposited Funds', '', 'Accounts Receivable', money(t.get('amt', 0)), ''])
for t in sr:
    flat.append([t['c'], 'Sales Receipt', mdy(t['d']), t.get('n', ''), t.get('memo', ''), 'Undeposited Funds', '', '', money(t.get('tot', 0)), ''])
flat.sort(key=lambda r: (r[0], r[2][6:] + r[2][:2] + r[2][3:5], r[3]))
write(f'derived/Chuster_Customer_Transactions_Flat_{FROM}_to_{AS_OF}.csv', ['Customer', 'Type', 'Date', 'Num', 'Memo', 'Account', 'Clr', 'Split', 'Debit', 'Credit'], flat)

# ---------- sales lines by year ----------
by_year = collections.defaultdict(list)
for t in inv + cm + sr:
    sign = -1 if t['kind'] == 'Credit Memo' else 1
    for l in t.get('l', []):
        full, desc, q, amt = l[0], l[1], float(l[2] or 0), float(l[3] or 0)
        if not full:
            continue
        price = abs(amt / q) if q else 0
        by_year[t['d'][:4]].append([t['c'], t['kind'], mdy(t['d']), t.get('n', ''), desc or desc_of.get(full, ''), item_txt(full, desc_of.get(full) or desc), qty(sign * q), money(price), money(sign * amt), ''])
for y, rows in by_year.items():
    rows.sort(key=lambda r: (r[0], r[2][6:] + r[2][:2] + r[2][3:5], r[3]))
    write(f'derived/Chuster_Sales_Lines_{y}.csv', ['Customer', 'Type', 'Date', 'Num', 'Memo', 'Item', 'Qty', 'SalesPrice', 'Amount', 'ReportRunningBalance'], rows)

# ---------- customers ----------
custs = load('customers', [])


def addr_lines(a):
    a = a or {}
    lines = [x for x in (a.get('a') or []) if x]
    city = ', '.join(x for x in [a.get('city', ''), ' '.join(x for x in [a.get('state', ''), a.get('zip', '')] if x)] if x)
    if city:
        lines.append(city)
    return (lines + [''] * 5)[:5]


CH = ['', 'Active Status', 'Customer', 'Balance', 'Balance Total', 'Company', 'Mr./Ms./...', 'First Name', 'M.I.', 'Last Name', 'Primary Contact', 'Main Phone', 'Fax', 'Alt. Phone', 'Secondary Contact', 'Job Title', 'Main Email',
      'Bill to 1', 'Bill to 2', 'Bill to 3', 'Bill to 4', 'Bill to 5', 'Ship to 1', 'Ship to 2', 'Ship to 3', 'Ship to 4', 'Ship to 5', 'Customer Type', 'Terms', 'Rep', 'Sales Tax Code', 'Tax item', 'Resale Num', 'Account No.', 'Credit Limit',
      'Job Status', 'Job Type', 'Job Description', 'Start Date', 'Projected End', 'End Date']
crow = []
for c in custs:
    if c.get('sub'):
        continue
    b, s = addr_lines(c.get('bill')), addr_lines(c.get('ship'))
    crow.append(['', 'Active' if c.get('active', True) else 'Not-active', c['n'], money(c.get('bal')), money(c.get('tbal', c.get('bal'))), c.get('company', ''), '', '', '', '', c.get('contact', ''), c.get('phone', ''), '', c.get('alt', ''), '', '', c.get('email', ''),
                 *b, *s, c.get('type', ''), c.get('terms', ''), c.get('rep', ''), '', '', '', '', money(c['limit']) if c.get('limit') else '', '', '', '', '', '', ''])
write(f'originals/Chuster_Customers_All_{tag}.csv', CH, crow)

# ---------- item listing ----------
TYPES = {'inv': 'Inventory Part', 'asm': 'Inventory Assembly', 'non': 'Non-inventory Part', 'svc': 'Service', 'oth': 'Other Charge', 'disc': 'Discount', 'sub': 'Subtotal', 'grp': 'Group', 'pay': 'Payment'}
irow = []
for it in items:
    t = TYPES.get(it.get('t'), it.get('t', ''))
    if t == 'Inventory Assembly':
        t = 'Inventory Part'  # the app treats assemblies like parts
    q = lambda k: '' if it.get(k) is None or t not in ('Inventory Part',) else qty(it[k])
    irow.append(['', it['n'], it.get('desc', ''), t, money(it.get('cost')), money(it.get('price')), 'Non', q('qoh'), q('qso'), q('rp'), q('qpo'), it.get('vendor', '')])
write(f'originals/Chuster_Item_Listing_{tag}.csv', ['', 'Item', 'Description', 'Type', 'Cost', 'Price', 'Sales Tax Code', 'Quantity On Hand', 'Quantity On Sales Order', 'Reorder Pt (Min)', 'Quantity On Purchase Order', 'Preferred Vendor'], irow)

# ---------- A/R aging detail ----------
BUCKETS = ['Current', '1 - 30', '31 - 60', '61 - 90', '> 90']
ag = {b: [] for b in BUCKETS}
terms = {c['n']: c.get('terms', '') for c in custs}


def bucket(due_iso):
    late = (asof - dt.date.fromisoformat(due_iso)).days if due_iso else 0
    return BUCKETS[0] if late <= 0 else BUCKETS[1] if late <= 30 else BUCKETS[2] if late <= 60 else BUCKETS[3] if late <= 90 else BUCKETS[4]


for t in inv:
    if float(t.get('bal') or 0) > 0.004:
        ag[bucket(t.get('due') or t['d'])].append(['', 'Invoice', mdy(t['d']), t.get('n', ''), '', t['c'], t.get('terms') or terms.get(t['c'], ''), mdy(t.get('due') or ''), '', '', money(t['bal'])])
for t in cm:
    if float(t.get('rem') or 0) > 0.004:
        ag[bucket(t['d'])].append(['', 'Credit Memo', mdy(t['d']), t.get('n', ''), '', t['c'], '', mdy(t['d']), '', '', money(-float(t['rem']))])
for t in pay:
    if float(t.get('unused') or 0) > 0.004:
        ag[bucket(t['d'])].append(['', 'Payment', mdy(t['d']), t.get('n', ''), '', t['c'], '', mdy(t['d']), '', '', money(-float(t['unused']))])
arows = []
for b in BUCKETS:
    arows.append([b] + [''] * 10)
    L = sorted(ag[b], key=lambda r: (r[2][6:] + r[2][:2] + r[2][3:5], r[3]))
    arows.extend(L)
    arows.append([f'Total {b}'] + [''] * 9 + [money(sum(float(r[10]) for r in L))])
write(f'originals/Chuster_AR_Aging_Detail_{tag}.csv', ['', 'Type', 'Date', 'Num', 'P. O. #', 'Name', 'Terms', 'Due Date', 'Class', 'Aging', 'Open Balance'], arows, bom=False)

# ---------- packing: loose used (invoices to the packaging customer) and boxes made (bills from the packaging vendor) ----------
lrows = [[INTERNAL_CUST, '', '', '', '']]
for t in sorted((t for t in inv if t['c'] == INTERNAL_CUST), key=lambda t: t['d']):
    for l in t.get('l', []):
        if l[0]:
            lrows.append(['', 'Invoice', mdy(t['d']), item_txt(l[0], desc_of.get(l[0]) or l[1]), qty(l[2])])
write('loose.csv', ['', 'Type', 'Date', 'Item', 'Qty'], lrows, bom=False)
prows = [[INTERNAL_VENDOR, '', '', '']]
for t in sorted((t for t in pur if t.get('v') == INTERNAL_VENDOR), key=lambda t: t['d']):
    for l in t.get('l', []):
        if l[0]:
            prows.append([t.get('t', 'Bill'), mdy(t['d']), item_txt(l[0], desc_of.get(l[0]) or l[1]), qty(l[2])])
write('packed.csv', ['Type', 'Date', 'Item', 'Qty'], prows, bom=False)

# ---------- purchases by vendor detail ----------
by_v = collections.defaultdict(list)
for t in pur:
    for l in t.get('l', []):
        if l[0]:
            by_v[t.get('v', '')].append((t, l))
urows = []
for v in sorted(by_v):
    urows.append([v] + [''] * 10)
    bal = 0.0
    for t, l in sorted(by_v[v], key=lambda x: (x[0]['d'], x[0].get('n', ''))):
        amt = float(l[4] or 0); bal += amt
        urows.append(['', t.get('t', 'Bill'), mdy(t['d']), t.get('n', ''), l[1] or desc_of.get(l[0], ''), v, item_txt(l[0], desc_of.get(l[0]) or l[1]), qty(l[2]), (f'{float(l[3] or 0):.5f}'.rstrip('0').rstrip('.') or '0'), money(amt), money(bal)])
    urows.append([f'Total {v}'] + [''] * 8 + [money(sum(float(l[4] or 0) for t, l in by_v[v])), ''])
write('purchases_all.csv', ['', 'Type', 'Date', 'Num', 'Memo', 'Name', 'Item', 'Qty', 'Cost Price', 'Amount', 'Balance'], urows, bom=False)

# ---------- open purchase orders by item ----------
by_i = collections.defaultdict(list)
for p in load('po', []):
    for l in p.get('l', []):
        if l[0] and float(l[2] or 0) - float(l[3] or 0) > 0:
            by_i[l[0]].append((p, l))
orows = [['Inventory'] + [''] * 13]
for full in sorted(by_i):
    leaf = full.split(':')[-1].strip()
    orows.append([item_txt(leaf, desc_of.get(full, ''))] + [''] * 13)
    for p, l in sorted(by_i[full], key=lambda x: x[0]['d']):
        q, rcv, rate = float(l[2] or 0), float(l[3] or 0), float(l[4] or 0)
        orows.append(['', mdy(p['d']), p.get('n', ''), p.get('v', ''), p.get('v', ''), l[1] or desc_of.get(full, ''), mdy(p.get('deliv') or ''), qty(q), '', qty(rcv), qty(q - rcv), money(q * rate), money((q - rcv) * rate), p.get('shipto', '')])
write('open_po.csv', ['', 'Date', 'Num', 'Name', 'Source Name', 'Memo', 'Deliv Date', 'Qty', 'FOB', "Rcv'd", 'Backordered', 'Amount', 'Open Balance', 'Ship To Address 1'], orows, bom=False)

# ---------- reports: P&L by month and balance sheet ----------
MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']


def report_rows(rep):
    out = []
    for r in rep.get('rows', []):
        name = r.get('n') or ''
        if not name:
            continue
        vals = r.get('v') or []
        out.append((name, vals))
    return out


pl = load('pl')
if pl:
    f = dt.date.fromisoformat(pl.get('from', FROM)); months = []
    y, m = f.year, f.month
    while (y, m) <= (asof.year, asof.month):
        months.append((y, m)); m += 1
        if m == 13:
            y, m = y + 1, 1
    last_day = (dt.date(asof.year + (asof.month == 12), asof.month % 12 + 1, 1) - dt.timedelta(days=1)).day
    heads = [f'{MON[m - 1]} {str(y)[2:]}' for y, m in months]
    if asof.day < last_day:
        heads[-1] = f'{MON[asof.month - 1]} 1 - {asof.day}, {str(asof.year)[2:]}'
    rows = []
    for name, vals in report_rows(pl):
        v = (list(vals) + [None] * len(months))[:len(months)]
        rows.append([name] + ['' if x is None else f'{float(x):.2f}' for x in v] + [''])
    write('pl.csv', [''] + heads + ['TOTAL'], rows, bom=False)
bs = load('bs')
if bs:
    write('bs.csv', ['', f'{MON[asof.month - 1]} {asof.day}, {str(asof.year)[2:]}'], [[n, '' if not v or v[0] is None else f'{float(v[0]):.2f}'] for n, v in report_rows(bs)], bom=False)

write('reps.csv', ['INITIALS', 'NAME', 'SALES REP TYPE'], [[r['i'], r.get('n') or r['i'], 'Other Name'] for r in load('reps', [])], bom=False)
open(os.path.join(OUT, 'inv_val.csv'), 'w').write(',"On Hand","Avg Cost","Asset Value"\n')
print('converted', AS_OF, 'from', FROM, '| invoices', len(inv), 'credits', len(cm), 'payments', len(pay), 'purchases', len(pur), '| customers', len(custs), 'items', len(items), '| years', sorted(by_year))
