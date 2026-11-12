// Address type-ahead for the Chuster app's "Check address" tool.
// Takes a partial address (?q=...) and returns up to 6 suggestions from TomTom, biased to the NYC metro
// where Chuster delivers. The TomTom key stays here on the server, never in the app. Fails soft (returns
// an empty list) so the UI just falls back to manual typing if anything goes wrong.
const json = (o, status) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

export default async (req) => {
  const key = Netlify.env.get('TOMTOM_API_KEY');
  if (!key) return json([], 200);
  let q = '';
  try { q = (new URL(req.url).searchParams.get('q') || '').trim(); } catch (e) { /* ignore */ }
  if (!q && req.method === 'POST') { try { q = String((await req.json()).q || '').trim(); } catch (e) { /* ignore */ } }
  if (q.length < 3) return json([], 200);

  const url = `https://api.tomtom.com/search/2/search/${encodeURIComponent(q)}.json`
    + `?key=${key}&typeahead=true&limit=6&countrySet=US&idxSet=PAD,Addr,Str,POI&lat=40.67&lon=-73.94&radius=250000`;
  try {
    const ctrl = AbortSignal.timeout ? AbortSignal.timeout(6000) : undefined;
    const r = await fetch(url, ctrl ? { signal: ctrl } : {});
    if (!r.ok) return json([], 200);
    const d = await r.json();
    const out = (d.results || [])
      .map(x => ({ address: (x.address && x.address.freeformAddress) || '', lat: x.position && x.position.lat, lng: x.position && x.position.lon }))
      .filter(x => x.address && isFinite(x.lat) && isFinite(x.lng));
    return json(out, 200);
  } catch (e) { return json([], 200); }
};

export const config = { path: '/suggest' };
