// Receives a "new email arrived" ping (from Power Automate), turns it into an inbox item,
// and writes it into the app's live shared database so the Email inbox updates in seconds.
// The sync key stays on Netlify (env). Only a caller with the shared secret is accepted.
const DB = 'https://chuster-afb77-default-rtdb.firebaseio.com';
const json = (o, status) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

const b64 = u8 => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const sha256hex = async t => { const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t))); return Array.from(d).map(b => b.toString(16).padStart(2, '0')).join(''); };

async function keyOf(raw) { return crypto.subtle.importKey('raw', unb64(raw), 'AES-GCM', false, ['encrypt', 'decrypt']); }
async function enc(k, obj) { const iv = crypto.getRandomValues(new Uint8Array(12)); const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, k, new TextEncoder().encode(JSON.stringify(obj)))); const all = new Uint8Array(12 + ct.length); all.set(iv); all.set(ct, 12); return b64(all); }
async function dec(k, s) { const a = unb64(s); const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: a.subarray(0, 12) }, k, a.subarray(12)); return JSON.parse(new TextDecoder().decode(pt)); }

const clip = (s, n) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };

function categorize(subject, from, preview) {
  const sub = String(subject || ''), f = String(from || '').toLowerCase(), pv = String(preview || '');
  const both = (sub + ' ' + pv).toLowerCase();
  if (/^items missing/i.test(sub.trim()) || /boxes? not delivered|box(es)? short|\bshort\b/i.test(both)) return 'shortage';
  if (f.includes('thelogicaledge.com') || f.includes('winlandfoods.com')) return 'pickup';
  if (/\b(check|ach|remittance|payment received|wire received|paid invoice)\b/i.test(both)) return 'payment';
  if (f.includes('bickelssnacks.com') || f.includes('hanoverfoods.com') || f.includes('nu-spice') || f.includes('nuspice') || /\b(invoice|kosher cert)\b/i.test(both)) return 'bill';
  if (/\b(order|drop (my |the )?order|deliver|delivery)\b/i.test(both)) return 'order';
  return null;
}
function flagOf(cat, subject, preview) {
  const both = (String(subject || '') + ' ' + String(preview || '')).toLowerCase();
  if (cat === 'pickup') { if (/reschedul|not .{0,12}ready|will not be ready|freeze|do not pull/i.test(both)) return 'reschedule'; if (String(preview || '').trim().endsWith('?')) return 'reply'; }
  if (cat === 'shortage') return 'short';
  return '';
}
const poOf = sub => { const m = String(sub || '').match(/\b(6\d{4})\b/) || String(sub || '').match(/\b(\d{5})\b/); return m ? m[1] : null; };

export default async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const rawKey = Netlify.env.get('CHUSTER_SYNC_KEY');
  const space = Netlify.env.get('CHUSTER_SYNC_SPACE');
  const fp = Netlify.env.get('CHUSTER_MAIL_FP');
  if (!rawKey || !space || !fp) return json({ error: 'Not set up yet (Netlify env: CHUSTER_SYNC_KEY, CHUSTER_SYNC_SPACE, CHUSTER_MAIL_FP).' }, 503);
  const secret = req.headers.get('x-mail-secret') || '';
  if (await sha256hex(secret) !== fp) return json({ error: 'Not allowed' }, 401);

  let body; try { body = await req.json(); } catch (e) { return json({ error: 'Bad request' }, 400); }
  const subject = body.subject, from = body.from || '', name = body.name || body.senderName || '';
  const preview = body.preview || body.bodyPreview || '', received = body.received || body.receivedDateTime || new Date().toISOString();
  const cat = categorize(subject, from, preview);
  if (!cat) return json({ ok: true, skipped: true }, 200);

  const item = { cat, who: clip(name || from, 48), subj: clip(subject, 80), sum: clip(preview, 140), at: String(received).replace('Z', '').slice(0, 19) };
  const fl = flagOf(cat, subject, preview); if (fl) item.flag = fl;

  const key = await keyOf(rawKey);
  // read current list
  let items = [];
  try { const r = await fetch(`${DB}/${space}/ei/z.json`); if (r.ok) { const j = await r.json(); if (j && j.v) { const o = await dec(key, j.v); if (o && Array.isArray(o.val)) items = o.val; } } } catch (e) { /* start fresh */ }
  // dedup
  const po = cat === 'pickup' ? poOf(subject) : null;
  items = items.filter(x => {
    if (po && x.cat === 'pickup' && poOf(x.subj) === po) return false;      // same PO → replace
    if (x.cat === cat && String(x.subj).toLowerCase() === item.subj.toLowerCase()) return false; // same subject → replace
    return true;
  });
  items.unshift(item);
  items.sort((a, b) => String(b.at).localeCompare(String(a.at)));
  items = items.slice(0, 20);

  const v = await enc(key, { k: 'zevi', val: items, by: 'Email' });
  const w = await fetch(`${DB}/${space}/ei/z.json`, { method: 'PUT', body: JSON.stringify({ v, t: { '.sv': 'timestamp' } }) });
  if (!w.ok) return json({ error: 'db write failed ' + w.status }, 502);
  await fetch(`${DB}/${space}/_t.json`, { method: 'PUT', body: JSON.stringify({ '.sv': 'timestamp' }) }).catch(() => {});
  return json({ ok: true, cat, count: items.length }, 200);
};

export const config = { path: '/mail/in' };
