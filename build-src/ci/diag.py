"""Diagnostics only (prints counts, no customer names): do invoice lines add up to invoice totals?"""
import json, glob, os, collections, sys
raw = sys.argv[1]
for y in ('2026', '2025', '2022'):
    p = os.path.join(raw, f'inv_{y}.json')
    if not os.path.exists(p): continue
    inv = json.load(open(p))
    n = len(inv); nol = [t for t in inv if not t.get('l')]
    mis = []; kinds = collections.Counter(); shapes = collections.Counter()
    for t in inv:
        tot = float(t.get('sub') or 0); ls = sum(float(l[3] or 0) for l in (t.get('l') or []) if isinstance(l, list) and len(l) > 3)
        for l in (t.get('l') or []): shapes[type(l).__name__ + str(len(l) if isinstance(l, list) else '')] += 1
        if abs(tot - ls) > max(1, abs(tot) * 0.01): mis.append((t, tot, ls))
    for t, tot, ls in mis[:40]:
        for l in (t.get('l') or [])[:3]: kinds[str(l[0])[:18] if isinstance(l, list) else 'notlist'] += 1
    print(f"::notice::{y}: invoices {n}, no lines {len(nol)} (${sum(float(t.get('sub') or 0) for t in nol):,.0f}), totals not matching lines {len(mis)} (invoice ${sum(m[1] for m in mis):,.0f} vs lines ${sum(m[2] for m in mis):,.0f}); line shapes {dict(shapes.most_common(4))}; sample items {dict(kinds.most_common(6))}")
    ex = mis[:3]
    for t, tot, ls in ex: print(f"::notice::{y} example: {len(t.get('l') or [])} lines, total {tot:,.2f}, lines {ls:,.2f}, first line {json.dumps((t.get('l') or [[]])[0])[:120]}")
