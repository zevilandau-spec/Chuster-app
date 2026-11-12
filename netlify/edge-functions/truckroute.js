// Truck routing for the Chuster app. Takes the day's stops + the truck's size, asks TomTom for a
// truck-legal route (avoids low bridges / weight-restricted roads) and the shortest stop order.
// The TomTom key stays here on the server, never in the app.
const json = (o, status) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

export default async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const key = Netlify.env.get('TOMTOM_API_KEY');
  if (!key) return json({ error: 'Truck routing is not set up yet (add TOMTOM_API_KEY in Netlify > Environment variables).' }, 503);

  let body; try { body = await req.json(); } catch (e) { return json({ error: 'Bad request' }, 400); }
  const stops = Array.isArray(body.stops) ? body.stops.filter(s => s && isFinite(s.lat) && isFinite(s.lng)) : [];
  if (stops.length < 2) return json({ error: 'Need at least 2 stops with a location.' }, 400);
  const start = body.start && isFinite(body.start.lat) && isFinite(body.start.lng) ? body.start : null;
  const t = body.truck || {};

  // Build the location list. If we have a depot, make it a round trip (depot ... depot) so the
  // optimizer is free to order every stop; otherwise first stop is the anchor.
  const loc = p => `${(+p.lat).toFixed(6)},${(+p.lng).toFixed(6)}`;
  const seq = start ? [start, ...stops, start] : [...stops];
  const path = seq.map(loc).join(':');

  const qs = new URLSearchParams({ key, travelMode: 'truck', vehicleCommercial: 'true', routeType: 'fastest', traffic: 'false', routeRepresentation: 'polyline' });
  // Vehicle dimensions (SI units). Only send what we were given.
  if (t.weightKg) qs.set('vehicleWeight', String(Math.round(t.weightKg)));
  if (t.axleWeightKg) qs.set('vehicleAxleWeight', String(Math.round(t.axleWeightKg)));
  if (t.lengthM) qs.set('vehicleLength', String(t.lengthM));
  if (t.widthM) qs.set('vehicleWidth', String(t.widthM));
  if (t.heightM) qs.set('vehicleHeight', String(t.heightM));
  // Ask TomTom to order the in-between stops into the shortest legal sequence (first/last stay put).
  const canOptimize = seq.length >= 4 && seq.length <= 50;
  if (canOptimize) qs.set('computeBestOrder', 'true');

  const url = `https://api.tomtom.com/routing/1/calculateRoute/${encodeURI(path)}/json?${qs.toString()}`;
  let r, data;
  try {
    const ctrl = AbortSignal.timeout ? AbortSignal.timeout(12000) : undefined;
    r = await fetch(url, ctrl ? { signal: ctrl } : {});
    data = await r.json();
  } catch (e) { return json({ error: 'Could not reach the routing service. Try again.' }, 502); }
  if (!r.ok) {
    const msg = (data && (data.detailedError?.message || data.error?.description || data.message)) || ('TomTom error ' + r.status);
    return json({ error: String(msg).slice(0, 300) }, r.status === 400 ? 400 : 502);
  }

  const route = data.routes && data.routes[0];
  if (!route) return json({ error: 'No truck route found for these stops.' }, 502);

  // Optimized order: optimizedWaypoints maps provided waypoint index -> optimized position.
  // Waypoints are the stops between origin and destination; providedIndex is 0-based among them.
  let order = stops.map((_, i) => i);
  if (canOptimize && Array.isArray(data.optimizedWaypoints) && data.optimizedWaypoints.length) {
    const byOpt = [...data.optimizedWaypoints].sort((a, b) => a.optimizedIndex - b.optimizedIndex);
    const mapped = byOpt.map(w => w.providedIndex);
    // When there is a depot, providedIndex already refers to the stops array (origin/dest excluded).
    if (mapped.every(i => i >= 0 && i < stops.length)) order = mapped;
  }

  const miles = Math.round((route.summary?.lengthInMeters || 0) / 1609.34);
  const minutes = Math.round((route.summary?.travelTimeInSeconds || 0) / 60);
  // Route geometry for drawing on the map.
  const line = [];
  (route.legs || []).forEach(lg => (lg.points || []).forEach(p => line.push({ lat: p.latitude, lng: p.longitude })));

  return json({
    ok: true,
    order,                 // order of the input stops, shortest truck-legal sequence
    miles, minutes,
    roundTrip: !!start,    // distance/time include the return to the depot
    line: line.length > 1200 ? line.filter((_, i) => i % 2 === 0) : line,
    note: 'Routed for your truck size — avoids low bridges and weight-restricted roads.'
  }, 200);
};

export const config = { path: '/route' };
