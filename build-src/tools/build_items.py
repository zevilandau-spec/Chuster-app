"""Per-product money: list price, what sold (12 months + this year), cost per case, profit.
Retail = packs (sold to stores); Wholesale = loose bulk cases.
Usage: python3 -I build_items.py <export_folder> <data.json>
"""
import csv, json, sys, os, collections, datetime as dt, statistics

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


def day(s):
    m, d, y = s.split('/')
    return dt.date(int(y), int(m), int(d))


data = json.load(open(DATA))
as_of = dt.date.fromisoformat(data['asOf'])
y12 = as_of - dt.timedelta(days=364)
ytd0 = dt.date(as_of.year, 1, 1)
cat = data['catalog']
idx = {c['full']: i for i, c in enumerate(cat)}

listing = {r['Item'].strip(): r for r in csv.DictReader(text(sorted(__import__('glob').glob(os.path.join(SRC, 'originals/Chuster_Item_Listing_*.csv')))[-1]).splitlines())}

# ---- sales per product ----
Q12 = collections.Counter(); A12 = collections.Counter(); QY = collections.Counter(); AY = collections.Counter()
prices = collections.defaultdict(list); buyers = collections.defaultdict(set); recent = {}
for y in (as_of.year - 1, as_of.year):
    for r in csv.DictReader(text(os.path.join(SRC, f'derived/Chuster_Sales_Lines_{y}.csv')).splitlines()):
        if r['Customer'] == INTERNAL:
            continue
        it = r['Item']
        full = it.rsplit(' (', 1)[0].strip() if it.endswith(')') and ' (' in it else it.strip()
        i = idx.get(full)
        if i is None:
            continue
        d = day(r['Date'])
        if d > as_of or d < y12:
            continue
        q, a, p = num(r['Qty']), num(r['Amount']), num(r['SalesPrice'])
        Q12[i] += q; A12[i] += a
        if d >= ytd0:
            QY[i] += q; AY[i] += a
        if r['Type'] == 'Invoice' and q > 0 and p > 0:
            prices[i].append(p)
            if d >= as_of - dt.timedelta(days=90):
                recent.setdefault(i, []).append(p)
        if q > 0:
            buyers[i].add(r['Customer'])

# ---- cost per case ----
B = data['buy']
last_buy = {}
for iso, v, ii, q, price, amt, n in B['lines']:  # sorted? take the latest date
    full = B['items'][ii]['full']
    if q > 0 and price > 0 and (full not in last_buy or iso >= last_buy[full][0]):
        last_buy[full] = (iso, price, B['vendors'][v] if isinstance(B['vendors'][v], str) else B['vendors'][v].get('name'))

# packing ratio: packs made per loose box, matched by product key
PK = data['pack']
lo, mk, loose_of = collections.Counter(), collections.Counter(), {}
for it in PK['items']:
    if it['unit'] != 'boxes':
        continue
    (lo if it['kind'] == 'loose' else mk)[it['key']] += it['total']
    if it['kind'] == 'loose':
        loose_of.setdefault(it['key'], it['full'])
made_key = {it['full']: it['key'] for it in PK['items'] if it['kind'] == 'made'}


def own_cost(full):
    if full in last_buy:
        return last_buy[full][1], 'bought', last_buy[full][0]
    c = num(listing.get(full, {}).get('Cost', 0))
    if c > 0:
        return c, 'qb', None
    return None, None, None


# boxes: every snack case goes in one PA10 carton (latest Prime price)
pa10 = None
for iso, v, ii, q, price, amt, n in B['lines']:
    if B['items'][ii]['full'] == 'Cartons:PA10A' and q > 0 and price > 0 and (pa10 is None or iso >= pa10[0]):
        pa10 = (iso, price)
BOX = {'Chuster Snacks': pa10}

out = []
for i, c in enumerate(cat):
    cost, src, when = own_cost(c['full'])
    note = None
    if False and cost is None and c['full'] in made_key:  # packing-ratio estimate too noisy (loose and packs logged on different days)
        k = made_key[c['full']]
        if lo[k] and mk[k] and k in loose_of:
            lc, _, _ = own_cost(loose_of[k])
            if lc:
                per = lo[k] / mk[k]  # loose boxes per pack case
                cost, src = round(lc * per, 2), 'est'
                note = f'{per:.2f} loose box per case × ${lc:.2f}'
    if cost is None and 'barley' in c['full'].lower() and 'loose' not in c['name'].lower():
        # barley cases: case weight × bulk barley price per lb
        import re
        lb = None
        m = re.search(r'(\d+)\s*/\s*(\d+)', c.get('pack') or '')
        if m:
            lb = int(m.group(1)) * int(m.group(2)) / 16
        m2 = re.search(r'(\d+)\s*lb', c['full'], re.I)
        if lb is None and m2:
            lb = int(m2.group(1))
        bulk = 'Landaus Loose:Barley Loose' if 'landau' in c['full'].lower() else 'Chuster Loose:Barley  Loose'
        bc, _, _ = own_cost(bulk)
        if lb and bc:
            cost, src = round(lb * bc, 2), 'est'
            note = f'{lb:g} lb × ${bc:.2f}/lb bulk barley'
    p = prices.get(i, [])
    rp = recent.get(i, [])
    common = statistics.mode(rp or p) if (rp or p) else None
    lst = num(listing.get(c['full'], {}).get('Price', 0)) or c.get('price') or None
    out.append({
        'kind': 'w' if 'Loose' in c['group'] else 'r',
        'list': round(lst, 2) if lst else None,
        'common': round(common, 2) if common else None,
        'q12': round(Q12[i], 1), 'a12': round(A12[i], 2),
        'qy': round(QY[i], 1), 'ay': round(AY[i], 2),
        'stores': len(buyers[i]),
        'cost': round(cost, 3) if cost else None, 'src': src, 'when': when, 'note': note,
        'box': [BOX[c['group']][1], BOX[c['group']][0], 'PA10'] if BOX.get(c['group']) else None,
        'desc': (listing.get(c['full'], {}).get('Description') or c['name']).strip(),
    })

data['items'] = {'from12': y12.isoformat(), 'ytdFrom': ytd0.isoformat(), 'list': out}
json.dump(data, open(DATA, 'w'), separators=(',', ':'))

tot = sum(o['a12'] for o in out)
print('products', len(out), '| retail', sum(o['kind'] == 'r' for o in out), 'wholesale', sum(o['kind'] == 'w' for o in out))
print('12-month sales', round(tot, 2), '| with cost:', sum(1 for o in out if o['cost']), {s: sum(1 for o in out if o['src'] == s) for s in ('bought', 'qb', 'est')})
prof = sum(o['a12'] - o['q12'] * o['cost'] for o in out if o['cost'])
print('profit on products with cost', round(prof, 2), 'on sales', round(sum(o['a12'] for o in out if o['cost']), 2))
for o, c in sorted(zip(out, cat), key=lambda t: -t[0]['a12'])[:8]:
    print(f"  {c['full'][:38]:38} {o['kind']} list {o['list']} common {o['common']} sold {o['q12']} ${o['a12']:,.0f} cost {o['cost']} {o['src']} {o['note'] or ''}")
