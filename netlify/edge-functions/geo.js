// Turns store addresses into map points (for the shortest delivery order). Free US Census geocoder, OpenStreetMap as backup.
// Only the Chuster app can use it (same check as the AI).
const OK = '6258ba263a0ce9b25e7b415f89a513d564d7715be510f0e71c0b76f64c31d62f';
const json = (o, status) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
async function census(a) {
  const u = 'https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?benchmark=Public_AR_Current&format=json&address=' + encodeURIComponent(a);
  const r = await fetch(u); if (!r.ok) return null;
  const j = await r.json(); const m = j && j.result && j.result.addressMatches && j.result.addressMatches[0];
  return m ? { lat: m.coordinates.y, lng: m.coordinates.x, how: 'census' } : null;
}
async function osm(a) {
  const u = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=us&q=' + encodeURIComponent(a);
  const r = await fetch(u, { headers: { 'user-agent': 'chuster-app/1.0 (delivery routes)' } }); if (!r.ok) return null;
  const j = await r.json(); return j && j[0] ? { lat: +j[0].lat, lng: +j[0].lon, how: 'osm' } : null;
}
export default async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const tok = req.headers.get('x-chuster') || '';
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(tok)));
  if (Array.from(d).map(b => b.toString(16).padStart(2, '0')).join('') !== OK) return json({ error: 'Not allowed' }, 401);
  let body; try { body = await req.json(); } catch (e) { return json({ error: 'Bad request' }, 400); }
  const list = (Array.isArray(body.addrs) ? body.addrs : []).slice(0, 25).map(a => String(a || '').slice(0, 200));
  const out = [];
  for (const a of list) {
    let p = null;
    try { p = await census(a); } catch (e) { p = null; }
    if (!p) { try { p = await osm(a); await new Promise(r => setTimeout(r, 1100)); } catch (e) { p = null; } }
    out.push(p);
  }
  return json({ points: out }, 200);
};
export const config = { path: '/geo' };
