"""Turn the text of a Winland "Order Acknowledgment PO nnnnn.pdf" into one JSON record.
Usage: python3 build-src/ci/parse_ack.py ack.txt [webLink]   (prints JSON; exit 1 if it is not an acknowledgement)
Shared by the hourly email watcher (writes feed/winland-acks.json) and the app's Order Tracker."""
import json, re, sys

def mdy(s):
    m = re.match(r'(\d{1,2})/(\d{1,2})/(\d{4})', s or '')
    return f"{m[3]}-{int(m[1]):02d}-{int(m[2]):02d}" if m else ''

def num(s):
    try: return float(str(s).replace(',', ''))
    except Exception: return None

def parse(t, link=''):
    t = re.sub(r'\s+', ' ', t)
    g = lambda pat: (re.search(pat, t, re.I) or [None, ''])[1].strip()
    po = g(r'Purchase Order No\.\s+(\d{4,})')
    if not po: return None
    rec = {
        'po': po,
        'so': g(r'Sales Order No\.\s+(\d+)'),
        'reqPickup': mdy(g(r'Requested Pickup Date\s+(\d{1,2}/\d{1,2}/\d{4})')),
        'poDate': mdy(g(r'Purchase Order Date\s+(\d{1,2}/\d{1,2}/\d{4})')),
        'shipFrom': g(r'Ship From\s+(.+?)\s+Incoterms'),
        'pallets': num(g(r'Unit Loads\s+([\d,.]+)\s*PAL')),
        'weightLb': num(g(r'Gross Weight\s+([\d,.]+)\s*LB')),
        'ackAt': '',
        'lines': [],
        'link': link,
    }
    m = re.search(r'Date/Time:\s*(\d{1,2}/\d{1,2}/\d{4})\s+(\d{1,2}:\d{2}(?::\d{2})?)', t)
    if m: rec['ackAt'] = mdy(m[1]) + 'T' + (m[2] if m[2].count(':') == 2 else m[2] + ':00')
    # line items: <winland material> <customer material#> <qty> <uom> <unit price> <total> <description>
    for lm in re.finditer(r'(\S+)\s+([0-9A-Z][0-9A-Z\-`]{5,})\s+([\d,]+(?:\.\d+)?)\s+(LB|CS|EA|CA|BX|PAL|KG)\s+([\d,]+\.\d+)\s+([\d,]+\.\d{2})\s+(.+?)(?=\s+Sold To|\s+\S+\s+[0-9A-Z][0-9A-Z\-`]{5,}\s+[\d,]+(?:\.\d+)?\s+(?:LB|CS|EA|CA|BX|PAL|KG)\s|$)', t):
        rec['lines'].append({'mat': lm[1], 'mpn': lm[2], 'qty': num(lm[3]), 'uom': lm[4], 'price': num(lm[5]), 'total': num(lm[6]), 'desc': lm[7].strip()[:60]})
    return rec

if __name__ == '__main__':
    r = parse(open(sys.argv[1], encoding='utf-8').read(), sys.argv[2] if len(sys.argv) > 2 else '')
    if not r: sys.exit(1)
    print(json.dumps(r))
