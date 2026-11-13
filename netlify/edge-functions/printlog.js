// Receives box-print counts from the factory PC (CHUS-04) and writes them into the app's live shared
// database so the Box printer screen updates in seconds. The sync key stays here on Netlify (env).
// Only a caller with the shared secret is accepted. The factory PC just POSTs plain JSON — no crypto there.
const DB = 'https://chuster-afb77-default-rtdb.firebaseio.com';
const json = (o, status) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

const b64 = u8 => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const sha256hex = async t => { const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t))); return Array.from(d).map(b => b.toString(16).padStart(2, '0')).join(''); };

async function keyOf(raw) { return crypto.subtle.importKey('raw', unb64(raw), 'AES-GCM', false, ['encrypt', 'decrypt']); }
async function enc(k, obj) { const iv = crypto.getRandomValues(new Uint8Array(12)); const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, k, new TextEncoder().encode(JSON.stringify(obj)))); const all = new Uint8Array(12 + ct.length); all.set(iv); all.set(ct, 12); return b64(all); }

const clip = (s, n) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const isDay = s => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ''));

export default async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const rawKey = Netlify.env.get('CHUSTER_SYNC_KEY');
  const space = Netlify.env.get('CHUSTER_SYNC_SPACE');
  const fp = Netlify.env.get('CHUSTER_PRINT_FP');
  if (!rawKey || !space || !fp) return json({ error: 'Not set up yet (Netlify env: CHUSTER_SYNC_KEY, CHUSTER_SYNC_SPACE, CHUSTER_PRINT_FP).' }, 503);
  const secret = req.headers.get('x-print-secret') || '';
  if (await sha256hex(secret) !== fp) return json({ error: 'Not allowed' }, 401);

  let body; try { body = await req.json(); } catch (e) { return json({ error: 'Bad request' }, 400); }
  const day = isDay(body.day) ? body.day : null;
  // labels: { "<printer label>": <count made that day> }. Keep it clean and bounded.
  const labelsIn = (body.labels && typeof body.labels === 'object') ? body.labels : {};
  const labels = {};
  Object.keys(labelsIn).slice(0, 200).forEach(k => { const n = Math.round(+labelsIn[k]); if (isFinite(n) && n > 0) labels[clip(k, 60)] = n; });
  // now: live status line
  const nowIn = body.now && typeof body.now === 'object' ? body.now : null;
  const now = nowIn && nowIn.label ? {
    label: clip(nowIn.label, 60),
    state: [0, 1, 2].includes(+nowIn.state) ? +nowIn.state : 0,
    counter: Math.max(0, Math.round(+nowIn.counter || 0)),
    at: String(nowIn.at || new Date().toISOString()).replace('Z', '').slice(0, 19)
  } : null;

  if (!day && !now) return json({ error: 'Nothing to write (need day+labels or now).' }, 400);

  const key = await keyOf(rawKey);
  const put = async (keyid, k, val) => {
    const v = await enc(key, { k, val, by: 'Printer' });
    const w = await fetch(`${DB}/${space}/mp/${keyid}.json`, { method: 'PUT', body: JSON.stringify({ v, t: { '.sv': 'timestamp' } }) });
    if (!w.ok) throw new Error('db write failed ' + w.status);
  };

  try {
    if (day) await put(day.replace(/-/g, ''), day, { d: day, labels, upd: (now && now.at) || new Date().toISOString().slice(0, 19) });
    if (now) await put('now', 'now', now);
  } catch (e) { return json({ error: String(e.message || e) }, 502); }

  await fetch(`${DB}/${space}/_t.json`, { method: 'PUT', body: JSON.stringify({ '.sv': 'timestamp' }) }).catch(() => {});
  return json({ ok: true, day, labels: Object.keys(labels).length, now: !!now }, 200);
};

export const config = { path: '/printlog/in' };
