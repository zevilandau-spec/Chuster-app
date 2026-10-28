// The app's built-in AI: passes questions to Claude (Anthropic) with the key kept on Netlify.
// Only the Chuster app can use it: it sends a code made from the app's own key (checked by its fingerprint). (key read at request time)
const OK = '6258ba263a0ce9b25e7b415f89a513d564d7715be510f0e71c0b76f64c31d62f';
const MODELS = ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5'];
const json = (o, status) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

export default async (req) => {
  if (req.method !== 'POST') return json({ error: { message: 'POST only' } }, 405);
  const tok = req.headers.get('x-chuster') || '';
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(tok)));
  const h = Array.from(d).map(b => b.toString(16).padStart(2, '0')).join('');
  if (h !== OK) return json({ error: { message: 'Not allowed' } }, 401);
  const key = Netlify.env.get('ANTHROPIC_API_KEY');
  if (!key) return json({ error: { message: 'The AI key is not set up yet (Netlify > Environment variables > ANTHROPIC_API_KEY).' } }, 503);
  let body; try { body = await req.json(); } catch (e) { return json({ error: { message: 'Bad request' } }, 400); }
  if (!MODELS.includes(body.model)) body.model = MODELS[0];
  body.max_tokens = Math.min(Number(body.max_tokens) || 4000, 16000);
  body.stream = true;
  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });
  if (!r.ok) { const t = await r.text(); let m = t; try { m = JSON.parse(t).error.message; } catch (e) { /* keep text */ } return json({ error: { message: 'Claude: ' + String(m).slice(0, 300) } }, r.status); }
  return new Response(r.body, { status: 200, headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-store' } });
};

export const config = { path: '/ai/msg' };
