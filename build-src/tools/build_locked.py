"""Build the Netlify version with the real data locked behind a passcode.
Usage: python3 -I build_locked.py <scratchpad>   (needs build/locked.json from lock.js)
"""
import json, os, sys, zipfile

root = sys.argv[1]
import datetime as _dt, zoneinfo as _zi
VERSION = os.environ.get('CHUSTER_VERSION') or _dt.datetime.now(_zi.ZoneInfo('America/New_York')).strftime('%Y-%m-%d %H:%M')
tpl = open(os.path.join(root, 'app/chuster-app.html'), encoding='utf-8').read()
locked = open(os.path.join(root, 'build/locked.json'), encoding='utf-8').read()

start_old = "<script>\n(function () {"
end_old = "go((location.hash || '').slice(1) || 'home');\n})();\n</script>"
assert tpl.count(start_old) == 1 and tpl.count(end_old) == 1
app = tpl.replace('<!--DATA-->', '').replace(start_old, "<script>\nwindow.__startApp = function () {")
lock_ui = '''<div id="lock" style="position:fixed;inset:0;z-index:100;background:var(--bg);overflow-y:auto;display:grid;place-items:center;padding-block:24px;padding-left:max(16px, env(safe-area-inset-left, 0px));padding-right:max(16px, env(safe-area-inset-right, 0px))">
  <form id="lock-form" class="card stack" style="width:min(420px,100%)" autocomplete="on">
    <div class="brand-logo" role="img" aria-label="Chuster" style="width:200px;margin:0 auto"></div>
    <h1 style="font-size:22px">Enter your passcode</h1>
    <p class="sub" style="margin:0">Your business numbers are locked. Type the passcode to open the app.</p>
    <label class="lbl" for="lock-pass">Passcode</label>
    <input class="inp" id="lock-pass" type="password" autocomplete="current-password" autocapitalize="none" autocorrect="off" spellcheck="false" required>
    <label style="display:flex;gap:10px;align-items:center;font-size:14px"><input type="checkbox" id="lock-remember" checked style="width:20px;height:20px">Remember on this device</label>
    <button class="btn primary big full" type="submit" id="lock-btn">Open</button>
    <p id="lock-err" class="sub" style="margin:0;color:var(--bad-text);font-weight:700" hidden>That passcode is not right. Try again.</p>
  </form>
</div>
<script>window.CHUSTER_VERSION = ''' + json.dumps(VERSION) + '''; window.CHUSTER_LOCKED = ''' + locked + ''';</script>
<script>
(function () {
  "use strict";
  var L = window.CHUSTER_LOCKED;
  var form = document.getElementById('lock-form'), input = document.getElementById('lock-pass'), btn = document.getElementById('lock-btn'), err = document.getElementById('lock-err'), remember = document.getElementById('lock-remember');
  function b64(s) { var bin = atob(s), out = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; }
  function unlock(pass) {
    return crypto.subtle.importKey('raw', new TextEncoder().encode(pass), 'PBKDF2', false, ['deriveKey'])
      .then(function (km) { return crypto.subtle.deriveKey({ name: 'PBKDF2', salt: b64(L.salt), iterations: L.iter, hash: 'SHA-256' }, km, { name: 'AES-GCM', length: 256 }, false, ['decrypt']); })
      .then(function (kek) {
        var i = 0;
        function next() {
          if (i >= L.keys.length) return Promise.reject(new Error('wrong passcode'));
          var k = L.keys[i++];
          return crypto.subtle.decrypt({ name: 'AES-GCM', iv: b64(k.iv) }, kek, b64(k.wk)).then(function (raw) { return { raw: raw, role: k.role }; }, next);
        }
        return next();
      })
      .then(function (r) {
        window.CHUSTER_ROLE = r.role;
        return crypto.subtle.importKey('raw', r.raw, 'AES-GCM', false, ['decrypt'])
          .then(function (dk) { return crypto.subtle.decrypt({ name: 'AES-GCM', iv: b64(L.iv) }, dk, b64(L.ct)); });
      })
      .then(function (pt) {
        var ds = new Response(new Blob([pt]).stream().pipeThrough(new DecompressionStream('gzip')));
        return ds.text().then(JSON.parse);
      });
  }
  function start(data) {
    window.CHUSTER_DATA = data; var l = document.getElementById('lock'); if (l) l.remove();
    try { window.__startApp(); } catch (e) {
      var box = document.createElement('div'); box.setAttribute('style', 'position:fixed;inset:12px;z-index:9999;background:#fff;border:3px solid #b42318;border-radius:14px;padding:18px;overflow:auto;font:14px system-ui;color:#111');
      box.innerHTML = '<h2 style="margin:0 0 8px">The app could not start</h2><p>Send a screenshot of this to Claude.</p><pre style="white-space:pre-wrap;font-size:12px"></pre><button style="padding:10px 14px;font-size:15px" onclick="try{Object.keys(localStorage).forEach(function(k){if(k!==\'chuster-pass\')localStorage.removeItem(k)})}catch(x){};location.reload()">Clear saved data and reload</button>';
      box.querySelector('pre').textContent = String((e && (e.stack || e.message)) || e).slice(0, 2000) + '\n' + (navigator.userAgent || '');
      document.body.appendChild(box);
    }
  }
  if (!(window.crypto && crypto.subtle) || !window.DecompressionStream) { err.textContent = 'This browser is too old to open the app. Update your iPad / iPhone (Settings → General → Software Update), or open the link in Chrome.'; err.hidden = false; btn.disabled = true; return; }
  var saved = null; try { saved = localStorage.getItem('chuster-pass'); } catch (e) { /* storage blocked */ }
  if (saved) { btn.disabled = true; btn.textContent = 'Opening…'; unlock(saved).then(start).catch(function () { try { localStorage.removeItem('chuster-pass'); } catch (e) { /* ignore */ } btn.disabled = false; btn.textContent = 'Open'; }); }
  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var pass = input.value.trim(); if (!pass) return;
    btn.disabled = true; btn.textContent = 'Opening…'; err.hidden = true;
    unlock(pass).then(function (data) {
      if (remember.checked) { try { localStorage.setItem('chuster-pass', pass); } catch (x) { /* ignore */ } }
      start(data);
    }).catch(function () { err.hidden = false; btn.disabled = false; btn.textContent = 'Open'; input.select(); });
  });
})();
</script>'''
app = app.replace(end_old, "go((location.hash || '').slice(1) || 'home');\n};\n</script>\n" + lock_ui)
# "Lock app" button in the menu footer (forgets the saved passcode on this device)
foot_old = '''<button class="btn ghost sm full" id="lang-btn" data-act="lang" style="margin-top:10px;color:#FFFFFF;border-color:rgba(255,255,255,.4)">אידיש (Yiddish)</button>'''
assert app.count(foot_old) == 1
app = app.replace(foot_old, foot_old + '''\n      <button class="btn ghost sm full" data-act="lock-app" style="margin-top:10px">Lock the app on this device</button>''')

head_end = app.index('</style>') + len('</style>')
doc = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
       '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
       '<meta name="robots" content="noindex, nofollow">\n'
       '<title>Chuster</title>\n'
       '<link rel="apple-touch-icon" href="apple-touch-icon.png">\n'
       '<link rel="icon" type="image/png" sizes="32x32" href="favicon-32.png">\n'
       '<link rel="manifest" href="manifest.webmanifest">\n'
       '<meta name="apple-mobile-web-app-title" content="Chuster">\n'
       '<meta name="apple-mobile-web-app-capable" content="yes">\n'
       '<meta name="mobile-web-app-capable" content="yes">\n'
       '<meta name="theme-color" content="#21409A">\n'
       '<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)} body{margin:0} [hidden]{display:none!important} img{max-width:100%}</style>\n'
       + app[:head_end] + '\n</head>\n<body>\n' + app[head_end:] + '\n</body>\n</html>\n')
assert 'window.CHUSTER_DATA=' not in doc and 'ROSENFELD' not in doc and 'Aron' not in doc and 'WINLAND' not in doc
out = os.path.join(root, 'netlify')
os.makedirs(out, exist_ok=True)
open(os.path.join(out, 'index.html'), 'w', encoding='utf-8').write(doc)
open(os.path.join(out, 'version.json'), 'w').write(json.dumps({'v': VERSION}))
zp = os.path.join(out, 'chuster-app.zip')
if os.path.exists(zp):
    os.remove(zp)
with zipfile.ZipFile(zp, 'w', zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(out, 'index.html'), 'index.html')
    for n in ('apple-touch-icon.png', 'icon-192.png', 'icon-512.png', 'favicon-32.png'):
        z.write(os.path.join(root, 'icons', n), n)
    z.writestr('manifest.webmanifest', json.dumps({'name': 'Chuster', 'short_name': 'Chuster', 'start_url': './', 'display': 'standalone', 'background_color': '#FBF8EF', 'theme_color': '#21409A',
        'icons': [{'src': 'icon-192.png', 'sizes': '192x192', 'type': 'image/png'}, {'src': 'icon-512.png', 'sizes': '512x512', 'type': 'image/png'}]}))
print('locked page', len(doc), 'bytes; zip', os.path.getsize(zp))
