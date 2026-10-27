"""Turn the Chuster QuickBooks export into one compact JSON file for the app.
Usage: python3 -I build_data.py <export_folder> <out_json>
"""
import csv, json, sys, re, statistics, datetime as dt, collections, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import heb  # Hebrew calendar math (same algorithm as the app)

SRC, OUT = sys.argv[1], sys.argv[2]
AS_OF = dt.date.fromisoformat(os.environ.get('CHUSTER_AS_OF', '2026-10-23'))
FROM = dt.date.fromisoformat(os.environ.get('CHUSTER_FROM', '2023-10-23'))  # first day of history in the export
import glob as _glob
def one(pat): return os.path.relpath(sorted(_glob.glob(os.path.join(SRC, pat)))[-1], SRC)
YEARS = sorted(int(re.search(r'(\d{4})\.csv$', p).group(1)) for p in _glob.glob(os.path.join(SRC, 'derived/Chuster_Sales_Lines_*.csv')))
def same_day(d, y):
    try: return d.replace(year=y)
    except ValueError: return d.replace(year=y, day=28)
PREV_END = same_day(AS_OF, AS_OF.year - 1)


def rd(path):
    b = open(os.path.join(SRC, path), 'rb').read()
    try:
        s = b.decode('utf-8-sig')
    except UnicodeDecodeError:
        s = b.decode('cp1252')
    return list(csv.DictReader(s.splitlines()))


def rows_raw(path):
    b = open(os.path.join(SRC, path), 'rb').read()
    try:
        s = b.decode('utf-8-sig')
    except UnicodeDecodeError:
        s = b.decode('cp1252')
    return list(csv.reader(s.splitlines()))


def num(x):
    try:
        return float(str(x).replace(',', ''))
    except (TypeError, ValueError):
        return 0.0


def day(s):
    m, d, y = s.split('/')
    return dt.date(int(y), int(m), int(d))


def iso(d):
    return d.isoformat() if d else None


def r2(x):
    return round(x + 0.0, 2)


# ---------------- transactions (invoices, credits, payments) ----------------
flat = rd(one('derived/Chuster_Customer_Transactions_Flat_*.csv'))
inv_rows = [r for r in flat if r['Type'] == 'Invoice']
cm_rows = [r for r in flat if r['Type'] == 'Credit Memo']
pay_rows = [r for r in flat if r['Type'] == 'Payment']

monthly = collections.defaultdict(float)
daily = collections.defaultdict(lambda: [0, 0.0])
cust_inv_dates = collections.defaultdict(list)
for r in inv_rows:
    d = day(r['Date']); a = num(r['Debit'])
    monthly[d.strftime('%Y-%m')] += a
    daily[d][0] += 1; daily[d][1] += a
    cust_inv_dates[r['Customer']].append((d, a))
for r in cm_rows:
    d = day(r['Date']); monthly[d.strftime('%Y-%m')] -= num(r['Credit'])

pay_daily = collections.defaultdict(float)
for r in pay_rows:
    pay_daily[day(r['Date'])] += num(r['Debit'])


def net_sales(a, b):
    """invoices minus credit memos, dates a..b inclusive"""
    s = sum(num(r['Debit']) for r in inv_rows if a <= day(r['Date']) <= b)
    s -= sum(num(r['Credit']) for r in cm_rows if a <= day(r['Date']) <= b)
    return s


inv_days = sorted(daily)
last_day = inv_days[-1]; prev_day = inv_days[-2]

# ---------------- sales lines (items, cases) ----------------
lines = []
inv_lines = collections.defaultdict(lambda: collections.defaultdict(float))
last_inv = {}
cust_invs = collections.defaultdict(dict)
for y in YEARS:
    for r in rd(f'derived/Chuster_Sales_Lines_{y}.csv'):
        if r['Type'] not in ('Invoice', 'Credit Memo'):
            continue
        it = r['Item']
        full = it.rsplit(' (', 1)[0].strip() if it.endswith(')') else it.strip()
        desc = it.rsplit(' (', 1)[1][:-1].strip() if it.endswith(')') and ' (' in it else ''
        lines.append((day(r['Date']), r['Customer'], full, desc, num(r['Qty']), num(r['Amount'])))
        if r['Type'] == 'Invoice' and full.startswith('Packs') or (r['Type'] == 'Invoice' and full.startswith(('Chuster Loose', 'Landaus Loose'))):
            inv_lines[(r['Customer'], r['Num'])][full] += num(r['Qty'])
        if r['Type'] == 'Invoice':
            k = (day(r['Date']), r['Num'])
            if r['Customer'] not in last_inv or k > last_inv[r['Customer']]:
                last_inv[r['Customer']] = k
            cust_invs[r['Customer']][r['Num']] = day(r['Date'])

is_case = lambda full: full.startswith('Packs')


def cases(a, b):
    return sum(q for d, c, f, ds, q, am in lines if a <= d <= b and is_case(f))


# ---------------- items ----------------
items_src = rd(one('originals/Chuster_Item_Listing_*.csv'))
sold90 = collections.defaultdict(float); sold28 = collections.defaultdict(float)
sold_ytd = collections.defaultdict(lambda: [0.0, 0.0])
last_price = {}
for d, c, f, ds, q, am in lines:
    if (AS_OF - d).days < 90: sold90[f] += q
    if (AS_OF - d).days < 28: sold28[f] += q
    if d.year == AS_OF.year:
        sold_ytd[f][0] += q; sold_ytd[f][1] += am
    if q > 0 and am > 0:
        last_price[f] = (d, am / q)

desc_of = {}
for d, c, f, ds, q, am in lines:
    if ds: desc_of[f] = ds


def nice(full, desc):
    if desc and not desc.endswith('-') and len(desc) > 3:
        return re.sub(r'\s+', ' ', desc).strip()
    leaf = full.split(':')[-1]
    return re.sub(r'^\d+\s*', '', leaf).strip()


def code_pack(full):
    leaf = full.split(':')[-1].strip()
    m = re.match(r'^(\d+)\s+(.*)$', leaf)
    code = m.group(1) if m else ''
    rest = m.group(2) if m else leaf
    pm = re.search(r'(\d+\s*[/x]\s*[\d.]+\s*(oz)?|\d+\s*Lb|\d+\s*Pcks? [\dx ]+|\b\d+\b$)', rest, re.I)
    return code, (pm.group(0).strip() if pm else '')


catalog, below_zero, low = [], [], []
for r in items_src:
    if r['Type'] not in ('Inventory Part', 'Non-inventory Part'):
        continue
    full = r['Item'].strip()
    top = full.split(':')[0].strip()
    if ':' not in full:
        continue
    if top in ('Amazon', 'Film', 'Cartons') or 'OLD' in top.upper():
        q0 = r['Quantity On Hand']
        if r['Type'] == 'Inventory Part' and q0 not in ('', None) and num(q0) < 0:
            below_zero.append({'name': nice(full, r['Description']), 'code': '', 'group': top, 'stock': int(num(q0)), 'sold28': 0, 'reorderAt': None})
        continue
    qoh = r['Quantity On Hand']; qoh = None if qoh in ('', None) else num(qoh)
    rp = r['Reorder Pt (Min)']; rp = None if rp in ('', None) else num(rp)
    price = num(r['Price'])
    lp = last_price.get(full)
    if price <= 0 and lp:
        price = lp[1]
    code, pack = code_pack(full)
    entry = {
        'name': nice(full, r['Description'] or desc_of.get(full, '')),
        'code': code, 'pack': pack, 'group': top.replace('Packs', '').strip() or top,
        'price': r2(price) if price else None, 'stock': None if qoh is None else int(qoh),
        'reorderAt': None if rp is None else int(rp), 'sold90': int(sold90.get(full, 0)),
        'full': full
    }
    if r['Type'] == 'Inventory Part' and qoh is not None and qoh < 0:
        below_zero.append({'name': entry['name'], 'code': code, 'group': entry['group'], 'stock': int(qoh), 'sold28': int(sold28.get(full, 0)), 'reorderAt': entry['reorderAt']})
    catalog.append(entry)
    if r['Type'] == 'Inventory Part' and qoh is not None and rp is not None and qoh < rp:
        low.append({'name': entry['name'], 'code': code, 'group': entry['group'], 'stock': int(qoh), 'sold28': int(sold28.get(full, 0)), 'reorderAt': int(rp)})

below_zero_all = sum(1 for r in items_src if r['Type'] == 'Inventory Part' and r['Quantity On Hand'] not in ('', None) and num(r['Quantity On Hand']) < 0)
below_zero.sort(key=lambda x: x['stock'])
low.sort(key=lambda x: x['stock'] - x['reorderAt'])
GROUP_ORDER = ['Chuster', 'Landaus', 'Chuster Snacks', 'WEGE', 'Chuster Loose', 'Landaus Loose']
catalog.sort(key=lambda x: (GROUP_ORDER.index(x['group']) if x['group'] in GROUP_ORDER else 99, x['group'], int(x['code']) if x['code'].isdigit() else 9999, x['name']))

top_items = sorted(((f, v) for f, v in sold_ytd.items() if is_case(f) and v[1] > 0), key=lambda x: -x[1][0])[:10]
top_items = [{'name': nice(f, desc_of.get(f, '')), 'cases': int(v[0]), 'amount': r2(v[1])} for f, v in top_items]
_ps, _pe = dt.date(AS_OF.year - 1, 1, 1), same_day(dt.date.fromisoformat(os.environ.get('CHUSTER_PREV_TO', AS_OF.isoformat())), AS_OF.year - 1)
sold_prev = collections.defaultdict(lambda: [0.0, 0.0])
for d, c, f, ds, q, am in lines:
    if _ps <= d <= _pe:
        sold_prev[f][0] += q; sold_prev[f][1] += am
all_items = []
for f in set(sold_ytd) | set(sold_prev):
    cur, prv = sold_ytd.get(f, [0.0, 0.0]), sold_prev.get(f, [0.0, 0.0])
    if cur[1] <= 0 and prv[1] <= 0:
        continue
    top = f.split(':')[0].strip()
    grp = (top.replace('Packs', '').strip() if top.startswith('Packs') else top) if ':' in f else 'Other'
    code, pack = code_pack(f)
    all_items.append({'name': nice(f, desc_of.get(f, '')), 'full': f, 'group': grp, 'code': code, 'pack': pack, 'qty': round(cur[0], 2), 'amount': r2(cur[1]), 'qtyPrev': round(prv[0], 2), 'amountPrev': r2(prv[1])})
all_items.sort(key=lambda x: -x['amount'])

# ---------------- A/R aging ----------------
ar = rows_raw(one('originals/Chuster_AR_Aging_Detail_*.csv'))
hdr = ar[0]
i_name, i_open, i_type, i_date, i_num, i_due = hdr.index('Name'), hdr.index('Open Balance'), hdr.index('Type'), hdr.index('Date'), hdr.index('Num'), hdr.index('Due Date')
BUCKETS = ['Current', '1 - 30', '31 - 60', '61 - 90', '> 90']
bucket = None
ar_tot = [0.0] * 5
ar_cust = collections.defaultdict(lambda: [0.0] * 5)
ar_open_inv = collections.defaultdict(list)
for row in ar[1:]:
    if row and row[0] in BUCKETS:
        bucket = BUCKETS.index(row[0]); continue
    if not row or row[0] or bucket is None or len(row) <= i_open:
        continue
    amt = num(row[i_open]); name = row[i_name]
    if not name:
        continue
    ar_tot[bucket] += amt; ar_cust[name][bucket] += amt
    if row[i_type] == 'Invoice':
        ar_open_inv[name].append((row[i_date], row[i_num], amt, row[i_due]))

# ---------------- same time last year (Jewish calendar) ----------------
hm, hd, hy = heb.from_abs(AS_OF.toordinal())
pm = 12 if (hm == 13 and not heb.leap(hy - 1)) else hm
ly_center = dt.date.fromordinal(heb.to_abs(pm, min(hd, heb.mdays(pm, hy - 1)), hy - 1))
LY_FROM, LY_TO = ly_center - dt.timedelta(days=30), ly_center + dt.timedelta(days=90)

# ---------------- customers ----------------
cust_src = rd(one('originals/Chuster_Customers_All_*.csv'))
cat_idx = {c['full']: i for i, c in enumerate(catalog)}
customers = []
late = []
sales12 = collections.defaultdict(float); ytd_c = collections.defaultdict(float); ytd_prev_c = collections.defaultdict(float)
item_by_cust = collections.defaultdict(lambda: collections.defaultdict(float))
y_start = dt.date(AS_OF.year, 1, 1); prev_start, prev_end = dt.date(AS_OF.year - 1, 1, 1), _pe
for d, c, f, ds, q, am in lines:
    if (AS_OF - d).days < 365: sales12[c] += am
    if d >= y_start: ytd_c[c] += am
    if prev_start <= d <= prev_end: ytd_prev_c[c] += am
    if (AS_OF - d).days < 180 and is_case(f): item_by_cust[c][f] += q

for r in cust_src:
    name = r['Customer'].strip()
    if not name or name.startswith(']'):
        continue
    active = r['Active Status'] == 'Active'
    dates = sorted(d for d, a in cust_inv_dates.get(name, []))
    recent = [d for d in dates if (AS_OF - d).days <= 365]
    last = dates[-1] if dates else None
    gap = None
    if len(recent) >= 4:
        gaps = [(b - a).days for a, b in zip(recent, recent[1:]) if (b - a).days > 0]
        if gaps: gap = int(statistics.median(gaps))
    since = (AS_OF - last).days if last else None
    is_late = bool(active and gap and last and since <= 120 and since > max(gap * 1.5, gap + 7))
    # seasonal stores (summer camps, Catskills): no orders around this time last year -> off season, not late
    ly_c = AS_OF - dt.timedelta(days=365)
    history_days = (AS_OF - dates[0]).days if dates else 0
    active_months = sorted({d.month for d in dates if (AS_OF - d).days <= 730})
    off_season = (bool(dates) and history_days > 395 and len(active_months) <= 7
                  and AS_OF.month not in active_months and not any(abs((d - ly_c).days) <= 30 for d in dates))
    is_late = is_late and not off_season
    bal = num(r['Balance'])
    ag = ar_cust.get(name, [0.0] * 5)
    if not active and abs(bal) < 0.01 and sales12.get(name, 0) == 0:
        continue
    area = (r['Customer Type'] or '').replace('Retail:', '').replace('Cataring', 'Catering') or 'Other'
    addr = ', '.join(x for x in [r['Ship to 2'] or r['Bill to 2'], r['Ship to 3'] or r['Bill to 3']] if x)
    tops = sorted(item_by_cust[name].items(), key=lambda x: -x[1])[:3]
    c = {
        'name': name, 'area': area, 'phone': r['Main Phone'], 'email': r['Main Email'], 'address': addr,
        'rep': r['Rep'], 'terms': r['Terms'], 'limit': num(r['Credit Limit']) or None, 'active': active,
        'balance': r2(bal), 'aging': [r2(x) for x in ag], 'last': iso(last), 'gap': gap, 'late': is_late,
        'offSeason': off_season, 'months': active_months,
        'sales12': r2(sales12.get(name, 0)), 'ytd': r2(ytd_c.get(name, 0)), 'ytdPrev': r2(ytd_prev_c.get(name, 0)),
        'orders12': len(recent), 'top': [nice(f, desc_of.get(f, '')) for f, q in tops],
        'ly': [[iso(d), n, [[cat_idx[f], int(q) if q == int(q) else q] for f, q in inv_lines[(name, n)].items() if f in cat_idx and q > 0]]
               for n, d in sorted(cust_invs.get(name, {}).items(), key=lambda x: x[1]) if LY_FROM <= d <= LY_TO],
        'lastOrder': ({'date': iso(last_inv[name][0]), 'num': last_inv[name][1], 'lines': [[f, q] for f, q in inv_lines[(name, last_inv[name][1])].items() if q > 0]} if name in last_inv else None),
        'open': [{'date': d, 'num': n, 'amt': r2(a), 'due': du} for d, n, a, du in sorted(ar_open_inv.get(name, []), key=lambda x: day(x[0]))]
    }
    customers.append(c)
    if is_late:
        late.append(name)
customers.sort(key=lambda c: -c['sales12'])

# ---------------- Yom Tov seasons (6 weeks before the first day) ----------------
def greg(abs_day):
    return dt.date.fromordinal(abs_day)


seasons = []
# name, Hebrew month (Nisan = 1), day, weeks before
# name, Hebrew month (Nisan = 1), day, weeks; 'After Pesach' starts on Isru Chag (23 Nisan) and runs forward
for label, m, d, wk in (('Chanuka', 9, 25, 4), ('Purim', 12, 14, 3), ('Pesach', 1, 15, 6), ('After Pesach', 1, 23, 3), ('Shavuos', 3, 6, 3), ('Rosh Hashana', 7, 1, 6)):
    rows_s = []
    for hy in range(heb.from_abs(FROM.toordinal())[2], heb.from_abs(AS_OF.toordinal())[2] + 2):
        mm = 13 if (m == 12 and heb.leap(hy)) else m  # Purim is in Adar II in a leap year
        yt = greg(heb.to_abs(mm, d, hy))
        if label == 'After Pesach':
            a, b = yt, yt + dt.timedelta(days=7 * wk - 1)
        else:
            a, b = yt - dt.timedelta(days=7 * wk), yt - dt.timedelta(days=1)
        if a < FROM or b > AS_OF:
            continue
        rows_s.append({'year': yt.year, 'heb': hy, 'weeks': wk, 'after': label == 'After Pesach', 'start': iso(a), 'end': iso(b), 'yt': iso(yt), 'sales': r2(net_sales(a, b)), 'cases': int(cases(a, b))})
    seasons.append({'name': label, 'rows': rows_s})

# ---------------- summary ----------------
ytd = net_sales(y_start, AS_OF); ytd_prev = net_sales(prev_start, prev_end)
_m1 = AS_OF.replace(day=1); _pm1 = _m1.replace(year=_m1.year - 1); _pm_end = (_pm1.replace(day=28) + dt.timedelta(days=4)); _pm_end = _pm_end - dt.timedelta(days=_pm_end.day)
oct_now = net_sales(_m1, AS_OF); oct_prev_same = net_sales(_pm1, min(_pe if _pe.month == _pm1.month else same_day(AS_OF, _pm1.year), _pm_end)); oct_prev_full = net_sales(_pm1, _pm_end)
years = {str(y): r2(net_sales(max(FROM, dt.date(y, 1, 1)), dt.date(y, 12, 31))) for y in range(FROM.year, AS_OF.year)}
years[str(AS_OF.year)] = r2(ytd)
cases_y = {str(AS_OF.year - 1): int(cases(prev_start, dt.date(AS_OF.year - 1, 12, 31))), str(AS_OF.year): int(cases(y_start, AS_OF)), str(AS_OF.year - 1) + 'same': int(cases(prev_start, prev_end))}

data = {
    'asOf': iso(AS_OF),
    'source': os.environ.get('CHUSTER_SOURCE', 'QuickBooks export, Oct 23, 2026'), 'from': iso(FROM), 'nightly': bool(os.environ.get('CHUSTER_NIGHTLY')),
    'lastDay': {'date': iso(last_day), 'count': daily[last_day][0], 'amount': r2(daily[last_day][1])},
    'prevDay': {'date': iso(prev_day), 'count': daily[prev_day][0], 'amount': r2(daily[prev_day][1])},
    'paidLast7': r2(sum(v for d, v in pay_daily.items() if (AS_OF - d).days < 7)),
    'ytd': r2(ytd), 'ytdPrev': r2(ytd_prev), 'years': years, 'cases': cases_y,
    'oct': {'now': r2(oct_now), 'prevSame': r2(oct_prev_same), 'prevFull': r2(oct_prev_full)},
    'monthly': [[k, r2(v)] for k, v in sorted(monthly.items())],
    'ar': {'buckets': BUCKETS, 'totals': [r2(x) for x in ar_tot], 'total': r2(sum(ar_tot)), 'customerBalanceTotal': r2(sum(num(r['Balance']) for r in cust_src))},
    'counts': {'activeCustomers': sum(1 for r in cust_src if r['Active Status'] == 'Active' and not r['Customer'].startswith(']')), 'belowZero': below_zero_all, 'low': len(low), 'late': len(late)},
    'lyWindow': {'from': iso(LY_FROM), 'to': iso(LY_TO), 'center': iso(ly_center)},
    'customers': customers, 'catalog': catalog, 'belowZero': below_zero, 'low': low,
    'topItems': top_items, 'allItems': all_items,
    'topCustomers': [{'name': c['name'], 'ytd': c['ytd'], 'ytdPrev': c['ytdPrev']} for c in sorted(customers, key=lambda c: -c['ytd'])[:10]],
    'seasons': seasons
}
os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump(data, open(OUT, 'w'), separators=(',', ':'))
print('written', OUT, os.path.getsize(OUT), 'bytes')
print('last day', data['lastDay'], 'prev', data['prevDay'])
print('ytd', data['ytd'], 'ytdPrev', data['ytdPrev'], 'years', years, 'cases', cases_y)
print('oct', data['oct'])
print('AR', data['ar'])
print('counts', data['counts'], 'customers kept', len(customers), 'catalog', len(catalog))
print('seasons', json.dumps(seasons))
print('top items', top_items[:5])
print('top customers', data['topCustomers'][:5])
print('late sample', late[:8])
