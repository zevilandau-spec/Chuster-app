// Encrypt the app data once with a random key; that key is wrapped once per passcode (Owner, Office, Warehouse, Driver).
// The passcode that opens the app decides the role. Usage: node lock.js <data.json> <passcodes.json> <out.json>
const fs = require('fs'); const crypto = require('crypto'); const zlib = require('zlib');
const [dataPath, passPath, outPath] = process.argv.slice(2);
const passes = JSON.parse(fs.readFileSync(passPath, 'utf8'));
const plain = zlib.gzipSync(Buffer.from(fs.readFileSync(dataPath, 'utf8'), 'utf8'), { level: 9 });
const K = crypto.randomBytes(32), iv = crypto.randomBytes(12), salt = crypto.randomBytes(16), iter = 600000;
const enc = (key, iv2, buf) => { const c = crypto.createCipheriv('aes-256-gcm', key, iv2); return Buffer.concat([c.update(buf), c.final(), c.getAuthTag()]); };
const ct = enc(K, iv, plain);
const keys = Object.entries(passes).map(([role, pass]) => { const kek = crypto.pbkdf2Sync(pass.trim(), salt, iter, 32, 'sha256'); const wiv = crypto.randomBytes(12); return { role, iv: wiv.toString('base64'), wk: enc(kek, wiv, K).toString('base64') }; });
fs.writeFileSync(outPath, JSON.stringify({ v: 3, iter, salt: salt.toString('base64'), iv: iv.toString('base64'), ct: ct.toString('base64'), keys }));
// round trip with each passcode
let ok = true;
for (const [role, pass] of Object.entries(passes)) {
  const kek = crypto.pbkdf2Sync(pass.trim(), salt, iter, 32, 'sha256'); const k = keys.find(x => x.role === role); const w = Buffer.from(k.wk, 'base64');
  const d = crypto.createDecipheriv('aes-256-gcm', kek, Buffer.from(k.iv, 'base64')); d.setAuthTag(w.subarray(w.length - 16)); const K2 = Buffer.concat([d.update(w.subarray(0, w.length - 16)), d.final()]);
  ok = ok && K2.equals(K);
}
console.log('locked', plain.length, 'bytes for', Object.keys(passes).join(', '), '| round trip ok:', ok);
