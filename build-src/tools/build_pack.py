"""Add daily packing history to the app data.
Loose used  = invoices to Chuster Packaging Wholsale (report "Packaged By Day Loose")
Boxes made  = bills from Chuster Packaging Retail (report "Purchases By Vendor Detail")
Usage: python3 -I build_pack.py <loose.csv> <packed.csv> <data.json>
"""
import csv, json, re, statistics, sys, collections, datetime as dt

LOOSE, PACKED, DATA = sys.argv[1:4]


def load(p):
    b = open(p, 'rb').read()
    try:
        s = b.decode('utf-8-sig')
    except UnicodeDecodeError:
        s = b.decode('cp1252')
    rows = list(csv.reader(s.splitlines()))
    hdr = rows[0]; off = 1 if hdr[0] == '' else 0
    out, group = [], None
    for r in rows[1:]:
        if not r:
            continue
        if r[0] and all(not x for x in r[1:]):
            group = r[0]; continue
        if r[0].lower().startswith('total'):
            continue
        rec = dict(zip(hdr[off:], r[off:]))
        if not rec.get('Date') or not rec.get('Item'):
            continue
        rec['group'] = group
        out.append(rec)
    return out


def day(s):
    m, d, y = s.split('/')
    return dt.date(int(y), int(m), int(d)).isoformat()


def num(x):
    try:
        return float(str(x).replace(',', ''))
    except ValueError:
        return 0.0


loose = [r for r in load(LOOSE) if r['group'] == 'Chuster Packaging Wholsale']
made = [r for r in load(PACKED) if r['group'] == 'Chuster Packaging Retail']

items, idx = [], {}


def item_id(raw, kind):
    full = raw.rsplit(' (', 1)[0].strip() if raw.endswith(')') and ' (' in raw else raw.strip()
    k = (full, kind)
    if k in idx:
        return idx[k]
    m = re.search(r'\(([^()]*)\)\s*$', raw)
    desc = re.sub(r'\s+', ' ', m.group(1)).strip() if m else ''
    top = full.split(':')[0].strip()
    leaf = full.split(':')[-1].strip()
    cm = re.match(r'^(\d+)\s*-?\s*(.*)$', leaf)
    code = cm.group(1) if cm else ''
    rest = cm.group(2) if cm else leaf
    size = ''
    sm = re.search(r'(\d+\s*[/x]\s*[\d.]+|\d+\s*Lbs?|\d+#|\b\d+\s*$)', rest, re.I)
    if sm:
        size = re.sub(r'\s+', '', sm.group(0)) if 'lb' in sm.group(0).lower() else sm.group(0).strip()
    name = desc if desc and not desc.endswith('-') else re.sub(r'\s+', ' ', rest).strip()
    group = top.replace('Packs', '').strip() if top.startswith('Packs') else top
    group = re.sub(r'\s*\(.*$', '', group).strip()
    key = re.sub(r'\s+', ' ', (desc or rest)).strip().lower()
    items.append({'full': full, 'name': name, 'code': code, 'size': size, 'group': group, 'kind': kind, 'key': key})
    idx[k] = len(items) - 1
    return idx[k]


days = collections.defaultdict(lambda: [collections.defaultdict(float), collections.defaultdict(float)])
qty_by_item = collections.defaultdict(list)
for r in loose:
    i = item_id(r['Item'], 'loose'); q = num(r['Qty'])
    days[day(r['Date'])][0][i] += q; qty_by_item[i].append(q)
for r in made:
    i = item_id(r['Item'], 'made'); q = num(r['Qty'])
    days[day(r['Date'])][1][i] += q; qty_by_item[i].append(q)

# units: everything is boxes, except bulk items counted in big numbers (Barley Loose)
for i, it in enumerate(items):
    med = statistics.median(qty_by_item[i]) if qty_by_item[i] else 0
    it['unit'] = 'qty' if (med >= 500 and 'lb' not in it['size'].lower()) else 'boxes'
    it['total'] = round(sum(qty_by_item[i]), 2)
    it['lines'] = len(qty_by_item[i])
    it['last'] = None

out_days = []
for d in sorted(days):
    lo, mk = days[d]
    for i in list(lo) + list(mk):
        items[i]['last'] = d
    out_days.append([d, [[i, round(q, 2)] for i, q in lo.items() if q], [[i, round(q, 2)] for i, q in mk.items() if q]])

data = json.load(open(DATA))
data['pack'] = {
    'from': out_days[0][0], 'to': out_days[-1][0],
    'looseCustomer': 'Chuster Packaging Wholsale', 'madeVendor': 'Chuster Packaging Retail',
    'items': items, 'days': out_days
}
json.dump(data, open(DATA, 'w'), separators=(',', ':'))

lt = sum(q for r in loose for q in [num(r['Qty'])] if items[idx[(r['Item'].rsplit(' (', 1)[0].strip() if r['Item'].endswith(')') and ' (' in r['Item'] else r['Item'].strip(), 'loose')]]['unit'] == 'boxes')
mt = sum(num(r['Qty']) for r in made if items[idx[(r['Item'].rsplit(' (', 1)[0].strip() if r['Item'].endswith(')') and ' (' in r['Item'] else r['Item'].strip(), 'made')]]['unit'] == 'boxes')
print('days', len(out_days), out_days[0][0], '->', out_days[-1][0])
print('items', len(items), 'loose items', sum(1 for x in items if x['kind'] == 'loose'), 'made items', sum(1 for x in items if x['kind'] == 'made'))
print('counted-not-boxes items:', [(x['name'], x['kind'], x['total']) for x in items if x['unit'] == 'qty'])
print('loose boxes used (3y):', lt, ' boxes made (3y):', mt)
print('last day', out_days[-1])
