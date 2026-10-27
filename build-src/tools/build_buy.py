"""Add purchases (bills from real suppliers) and loose-stock flow to the app data.
Usage: python3 -I build_buy.py <purchases_all.csv> <export_folder> <data.json>
"""
import csv, json, re, sys, collections, datetime as dt, os

PUR, SRC, DATA = sys.argv[1:4]
INTERNAL_VENDOR = 'Chuster Packaging Retail'
INTERNAL_CUSTOMER = 'Chuster Packaging Wholsale'


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


def split_item(raw):
    raw = raw.strip()
    if raw.endswith(')') and ' (' in raw:
        full, desc = raw.rsplit(' (', 1)
        return full.strip(), re.sub(r'\s+', ' ', desc[:-1]).strip()
    return raw, ''


def describe(full, desc):
    top = full.split(':')[0].strip() if ':' in full else 'Other'
    leaf = full.split(':')[-1].strip()
    cm = re.match(r'^(\d+)\s*-?\s*(.*)$', leaf)
    code = cm.group(1) if cm else ''
    rest = cm.group(2) if cm else leaf
    sm = re.search(r'(\d+\s*[/x]\s*[\d.]+|\d+\s*Lbs?|\d+#|\b\d+\s*$)', rest, re.I)
    size = (re.sub(r'\s+', '', sm.group(0)) if 'lb' in sm.group(0).lower() else sm.group(0).strip()) if sm else ''
    name = desc if desc and not desc.endswith('-') else re.sub(r'\s+', ' ', rest).strip()
    group = top.replace('Packs', '').strip() if top.startswith('Packs') else top
    return {'full': full, 'name': name or full, 'code': code, 'size': size, 'group': re.sub(r'\s*\(.*$', '', group).strip() or 'Other'}


# ---------------- purchases ----------------
rows = list(csv.reader(text(PUR).splitlines()))
hdr = rows[0]; off = 1 if hdr[0] == '' else 0
recs, vendor = [], None
for r in rows[1:]:
    if not r:
        continue
    if r[0] and all(not x for x in r[1:]):
        vendor = r[0]; continue
    if r[0].lower().startswith('total'):
        continue
    rec = dict(zip(hdr[off:], r[off:]))
    if not rec.get('Date'):
        continue
    rec['vendor'] = vendor
    recs.append(rec)

real = [r for r in recs if r['vendor'] != INTERNAL_VENDOR]
vendors, vidx = [], {}
items, iidx = [], {}
lines = []
for r in real:
    v = r['vendor']
    if v not in vidx:
        vidx[v] = len(vendors); vendors.append(v)
    full, desc = split_item(r.get('Item') or '')
    if full not in iidx:
        iidx[full] = len(items); items.append(describe(full, desc))
    sign = 1  # QuickBooks already shows credits as negative
    lines.append([day(r['Date']).isoformat(), vidx[v], iidx[full], round(num(r['Qty']) * sign, 4), round(num(r['Cost Price']), 4), round(num(r['Amount']) * sign, 2), r.get('Num', '')])
lines.sort(key=lambda x: x[0])

data = json.load(open(DATA))
pk = data.get('pack', {})
end = max(day(r['Date']) for r in recs if r['Date'])
end = min(end, dt.date.fromisoformat(data['asOf']) if 'asOf' in data else end)
start90 = end - dt.timedelta(days=89)

# units: Barley Loose is counted per pound (QB qty), everything else in boxes
for it in items:
    it['unit'] = 'qty' if re.search(r'barley\s+loose', it['full'], re.I) else 'boxes'

# ---------------- loose flow (last 90 days) ----------------
bought = collections.defaultdict(float)
for d, v, i, q, p, a, n in lines:
    if start90.isoformat() <= d <= end.isoformat():
        bought[items[i]['full']] += q
used = collections.defaultdict(float)
made = collections.defaultdict(float)
pk_items = pk.get('items', [])
for d, lo, mk in pk.get('days', []):
    if start90.isoformat() <= d <= end.isoformat():
        for i, q in lo:
            used[pk_items[i]['full']] += q
        for i, q in mk:
            made[pk_items[i]['full']] += q
sold = collections.defaultdict(float)
for y in (int(data['asOf'][:4]), int(data['asOf'][:4]) - 1):
    path = os.path.join(SRC, f'derived/Chuster_Sales_Lines_{y}.csv')
    for r in csv.DictReader(text(path).splitlines()):
        if r['Customer'] == INTERNAL_CUSTOMER or r['Type'] not in ('Invoice', 'Credit Memo'):
            continue
        d = day(r['Date'])
        if not (start90 <= d <= end):
            continue
        full, _ = split_item(r['Item'])
        if full.startswith(('Chuster Loose', 'Landaus Loose')):
            sold[full] += num(r['Qty'])
on_hand = {c['full']: c['stock'] for c in data['catalog']}
for b in data.get('belowZero', []):
    pass
flow = []
fulls = set(k for k in list(bought) + list(used) + list(sold) + list(made) if k.startswith(('Chuster Loose', 'Landaus Loose')))
for full in fulls:
    full_desc = next((it for it in items if it['full'] == full), None) or next((it for it in pk_items if it['full'] == full), None)
    info = describe(full, full_desc['name'] if full_desc else '')
    info['unit'] = 'qty' if re.search(r'barley\s+loose', full, re.I) else 'boxes'
    info.update({'onHand': on_hand.get(full), 'bought90': round(bought.get(full, 0), 2), 'used90': round(used.get(full, 0), 2), 'made90': round(made.get(full, 0), 2), 'sold90': round(sold.get(full, 0), 2)})
    flow.append(info)

data['buy'] = {'from': lines[0][0], 'to': lines[-1][0], 'end90': end.isoformat(), 'vendors': vendors, 'items': items, 'lines': lines, 'flow': flow}
json.dump(data, open(DATA, 'w'), separators=(',', ':'))

tot = collections.defaultdict(float)
for d, v, i, q, p, a, n in lines:
    tot[vendors[v]] += a
print('real vendors', len(vendors), 'bill lines', len(lines), lines[0][0], '->', lines[-1][0])
print('spend by vendor (3y):', sorted(((k, round(v, 2)) for k, v in tot.items()), key=lambda x: -x[1])[:6])
print('total spend', round(sum(tot.values()), 2))
print('flow items', len(flow), 'with on-hand', sum(1 for f in flow if f['onHand'] is not None))
for f in sorted(flow, key=lambda f: -(f['used90'] + f['sold90']))[:8]:
    print('  ', f['name'], f['size'], '| on hand', f['onHand'], '| bought', f['bought90'], '| used', f['used90'], '| sold', f['sold90'])
