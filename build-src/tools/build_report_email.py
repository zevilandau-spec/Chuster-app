"""Render reports/daily-report.json as a styled HTML daily report email.
Usage: python3 -I build_report_email.py reports/daily-report.json out.html
"""
import sys, json, datetime

SRC = sys.argv[1] if len(sys.argv) > 1 else 'reports/daily-report.json'
OUT = sys.argv[2] if len(sys.argv) > 2 else 'report-email.html'
R = json.load(open(SRC, encoding='utf-8'))

def money(x): return '$' + format(round(x), ',d')
def num(x): return format(int(x), ',d')
d = datetime.date.fromisoformat(R['date'])
DATE_LONG = d.strftime('%A, %B %-d, %Y')

sales = R.get('sales', {}) or {}
prod = R.get('production', {}) or {}
deliv = R.get('deliveries', {}) or {}
cov = R.get('coverage', {}) or {}

# ---------- KPI tiles ----------
dtot = deliv.get('totals', {}) or {}
dl_done, dl_not = dtot.get('delivered', 0), dtot.get('notDelivered', 0)
dl_all = dl_done + dl_not
cov_areas = cov.get('areas', []) or []
c_miss = sum(len(w['notCovered']) for w in cov_areas)
c_cov = sum(w['covered'] for w in cov_areas)
c_tot = sum(w['total'] for w in cov_areas)
tiles = [
    ('#C2410C', money(sales.get('total', 0)), 'sales today', f"{sales.get('invoices',0)} invoices"),
    ('#0F766E', num(prod.get('total', 0)), 'boxes made', f"{num(prod.get('packs',0))} packs"),
    ('#1D4ED8', f"{dl_done}/{dl_all}", 'deliveries', f"{dl_not} not yet"),
    ('#7C3AED', (f"{c_cov}/{c_tot}" if cov_areas else '—'), 'coverage', (f"{c_miss} missed" if cov_areas else 'no route today')),
]
tiles_html = ''.join(f'''<td style="width:25%;padding:0 5px;" valign="top">
  <div style="background:#F8FAFC;border:1px solid #E7E9EE;border-radius:12px;padding:12px 8px;text-align:center;">
    <div style="font-size:22px;font-weight:800;color:{c};line-height:1.05;">{big}</div>
    <div style="font-size:11px;color:#475569;margin-top:4px;font-weight:600;">{lab}</div>
    <div style="font-size:10px;color:#94A3B8;margin-top:1px;">{sub}</div>
  </div></td>''' for c, big, lab, sub in tiles)

def section_head(title, sub=''):
    return f'''<tr><td style="padding:22px 22px 6px;">
      <div style="font-size:16px;font-weight:800;color:#1F2430;border-bottom:2px solid #F1F2F5;padding-bottom:6px;">
        {title}{f' <span style="font-weight:600;color:#94A3B8;font-size:13px;">{sub}</span>' if sub else ''}</div>
    </td></tr>'''

# ---------- SALES ----------
areas = sales.get('byArea', []) or []
amax = max((a['net'] for a in areas), default=1) or 1
area_rows = ''
for a in areas:
    w = round(a['net'] / amax * 100)
    area_rows += f'''<tr>
      <td style="padding:4px 0;font-size:13px;color:#1F2430;white-space:nowrap;width:120px;">{a['area']}</td>
      <td style="padding:4px 8px;width:100%;"><div style="background:#EA580C;height:9px;width:{w}%;border-radius:999px;"></div></td>
      <td style="padding:4px 0;font-size:13px;color:#5B6370;text-align:right;white-space:nowrap;">{money(a['net'])}</td>
    </tr>'''
tops = sales.get('topCustomers', []) or []
top_rows = ''.join(f'''<tr>
    <td style="padding:3px 0;font-size:12.5px;color:#374151;">{t['name']}</td>
    <td style="padding:3px 0;font-size:12.5px;color:#6B7280;text-align:right;">{money(t['net'])}</td></tr>''' for t in tops)
sales_block = section_head('Sales', f"{money(sales.get('total',0))} · {sales.get('invoices',0)} invoices") + f'''
<tr><td style="padding:4px 22px 6px;">
  <table style="width:100%;border-collapse:collapse;">{area_rows}</table>
  {f'<div style="font-size:11px;color:#94A3B8;text-transform:uppercase;letter-spacing:.05em;margin:12px 0 2px;">Top stores</div><table style="width:100%;border-collapse:collapse;">{top_rows}</table>' if top_rows else ''}
</td></tr>'''

# ---------- PRODUCTION ----------
items = prod.get('items', []) or []
pmax = max((i['boxes'] for i in items), default=1) or 1
prod_rows = ''
for i in items:
    w = round(i['boxes'] / pmax * 100)
    pk = f" · {num(i['packs'])} packs" if i.get('packs') else ''
    prod_rows += f'''<tr>
      <td style="padding:3px 0;font-size:12.5px;color:#1F2430;white-space:nowrap;width:140px;">{i['name']}</td>
      <td style="padding:3px 8px;width:100%;"><div style="background:#0F766E;height:8px;width:{w}%;border-radius:999px;"></div></td>
      <td style="padding:3px 0;font-size:12.5px;color:#5B6370;text-align:right;white-space:nowrap;"><b>{i['boxes']}</b>{pk}</td>
    </tr>'''
prod_block = section_head('Production', f"{num(prod.get('total',0))} boxes · {num(prod.get('packs',0))} packs") + (f'''
<tr><td style="padding:4px 22px 6px;"><table style="width:100%;border-collapse:collapse;">{prod_rows}</table></td></tr>''' if prod_rows else
'<tr><td style="padding:4px 22px 10px;"><p style="margin:0;font-size:13px;color:#94A3B8;">No production recorded today.</p></td></tr>')

# ---------- DELIVERIES ----------
def truck_card(t):
    done, nd = len(t['delivered']), len(t['notDelivered'])
    hd = t['name'] + (f' · {t["driver"]}' if t.get('driver') else '')
    rows = ''
    for s in t['delivered']:
        rows += f'''<tr><td style="padding:6px 10px;border-bottom:1px solid #EEF0F3;font-size:13px;color:#1F2430;">
          <span style="color:#16A34A;">●</span> {s}</td></tr>'''
    for s in t['notDelivered']:
        rows += f'''<tr><td style="padding:6px 10px;border-bottom:1px solid #EEF0F3;font-size:13px;color:#1F2430;">
          <span style="color:#DC2626;">●</span> {s}</td></tr>'''
    return f'''<div style="border:1px solid #E7E9EE;border-radius:12px;overflow:hidden;margin:10px 0;">
      <table style="width:100%;border-collapse:collapse;background:#F7F8FA;"><tr>
        <td style="padding:10px 12px;font-weight:700;color:#1F2430;font-size:14px;">{hd}</td>
        <td style="padding:10px 12px;text-align:right;font-size:12px;color:#5B6370;">
          <span style="color:#16A34A;font-weight:700;">{done}</span> del · <span style="color:#DC2626;font-weight:700;">{nd}</span> not</td>
      </tr></table>
      <table style="width:100%;border-collapse:collapse;">{rows}</table></div>'''
trucks = deliv.get('trucks', []) or []
deliv_block = section_head('Deliveries', f"{dl_done} delivered · {dl_not} not yet") + f'''
<tr><td style="padding:2px 22px 6px;">{''.join(truck_card(t) for t in trucks) if trucks else '<p style="margin:6px 0;font-size:13px;color:#94A3B8;">No delivery stops today.</p>'}</td></tr>'''

# ---------- SALESMAN COVERAGE (areas worked today -> stores missed) ----------
if cov_areas:
    cov_sub = 'worked ' + ', '.join(w['area'] for w in cov_areas)
    blocks = ''
    for w in cov_areas:
        missed = w['notCovered']
        if missed:
            lis = ''.join(f'<li style="margin:2px 0;">{s}</li>' for s in missed)
            body = f'''<p style="margin:5px 0 3px;font-size:12.5px;color:#B91C1C;">Not covered ({len(missed)}):</p>
              <ul style="margin:0 0 4px;padding-left:20px;font-size:13px;color:#1F2430;">{lis}</ul>'''
        else:
            body = '<p style="margin:5px 0 4px;font-size:13px;color:#16A34A;font-weight:600;">Every store covered 🎉</p>'
        blocks += f'''<div style="border-top:1px solid #F1F2F5;padding:8px 0 2px;">
          <div style="font-weight:700;font-size:14px;color:#1F2430;">{w['area']}
            <span style="font-weight:600;color:#94A3B8;font-size:12.5px;">· {w['covered']} of {w['total']} covered</span></div>
          {body}</div>'''
    cov_body = blocks
else:
    cov_sub = 'no route today'
    cov_body = '<p style="margin:0;font-size:13px;color:#6B7280;">No orders or visits from the salesman’s stores today, so no neighborhood shows as worked.</p>'
cov_block = section_head('Salesman coverage', cov_sub) + f'''
<tr><td style="padding:4px 22px 14px;">{cov_body}</td></tr>'''

HTML = f'''<!doctype html><html><head><meta charset="utf-8"></head>
<body style="margin:0;background:#EEF0F4;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
<div style="max-width:600px;margin:0 auto;padding:22px 14px;">
  <div style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 1px 3px rgba(16,24,40,.08);">
    <div style="background:linear-gradient(135deg,#C2410C,#EA580C);padding:22px;">
      <div style="color:#FFE8DA;font-size:12px;letter-spacing:.08em;text-transform:uppercase;font-weight:600;">Chuster Noodle</div>
      <div style="color:#fff;font-size:23px;font-weight:800;margin-top:2px;">Daily Report</div>
      <div style="color:#FFD9C2;font-size:13px;margin-top:3px;">{DATE_LONG}</div>
    </div>
    <table style="width:100%;border-collapse:collapse;padding:16px;"><tr><td style="padding:16px 17px 2px;">
      <table style="width:100%;border-collapse:collapse;"><tr>{tiles_html}</tr></table>
    </td></tr></table>
    <table style="width:100%;border-collapse:collapse;">
      {sales_block}
      {prod_block}
      {deliv_block}
      {cov_block}
    </table>
    <div style="padding:6px 22px 20px;text-align:center;color:#9AA1AC;font-size:11px;line-height:1.5;">
      Sales & production from QuickBooks and the box printer · deliveries and visits from the app.<br>
      “Covered” = a store ordered today or was marked visited. · Chuster Noodle automated nightly report
    </div>
  </div>
</div>
</body></html>'''
open(OUT, 'w').write(HTML)
print('wrote', OUT, len(HTML), 'bytes')
