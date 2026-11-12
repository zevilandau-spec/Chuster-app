#!/bin/sh
# Rebuild the locked app from the full QuickBooks history the office PC sent to the shared database.
# Needs: CHUSTER_DB_URL (Firebase link) and CHUSTER_SECRETS ({"sync": {...}, "passcodes": {...}}).
set -e
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, os
s = json.loads(os.environ['CHUSTER_SECRETS'])
s['sync']['url'] = os.environ['CHUSTER_DB_URL'].strip().rstrip('/'); json.dump(s['sync'], open('sync.json', 'w')); json.dump(s['passcodes'], open('passcodes.json', 'w'))
PY
cleanup() { rm -rf raw export build netlify sync.json passcodes.json; }
trap cleanup EXIT
export CHUSTER_LAST_HISTORY=$(python3 -c "import json;print(json.load(open('../build-status.json')).get('history',''))" 2>/dev/null || true)
if [ "$CHUSTER_FORCE" = "true" ]; then CHUSTER_LAST_HISTORY=""; fi
python3 tools/fetch_history.py "$CHUSTER_DB_URL" sync.json raw && R=0 || R=$?
if [ "$R" = 3 ]; then echo "UNCHANGED"; exit 0; fi
if [ "$R" != 0 ]; then echo "No full history yet; the app stays as it is."; exit 0; fi
python3 -I tools/convert_raw.py raw export
ASOF=$(python3 -c "import json;print(json.load(open('raw/meta.json'))['asOf'])")
FROM=$(python3 -c "import json;print(json.load(open('raw/meta.json'))['from'])")
mkdir -p build
CHUSTER_NIGHTLY=1 sh tools/build_from.sh export build/data.json "$ASOF" "$FROM"
python3 -I tools/build_extra.py raw build/data.json || echo "books part skipped"
# Merge the per-user email feed (refreshed by the email-watcher task writing email-feed.json).
python3 - <<'PY' || echo "email feed skipped"
import json
p = 'build/data.json'
d = json.load(open(p, encoding='utf-8'))
try:
    ef = json.load(open('email-feed.json', encoding='utf-8'))
    d['emailFeed'] = ef.get('feed', ef) if isinstance(ef, dict) else ef
    json.dump(d, open(p, 'w', encoding='utf-8'), separators=(',', ':'), ensure_ascii=False)
    print('email feed merged:', len(d['emailFeed']) if hasattr(d['emailFeed'], '__len__') else '?')
except FileNotFoundError:
    print('no email-feed.json yet')
PY
python3 -I tools/add_sync.py build/data.json sync.json build/data_sync.json
# Lock + build the page. build_locked.py has a data-guard assert that very rarely trips on a
# transient bad lock; retry the lock+build a few times so one flake doesn't abandon the deploy.
set +e
locked_ok=0
for i in 1 2 3 4 5 6; do
  node tools/lock.js build/data_sync.json passcodes.json build/locked.json && python3 -I tools/build_locked.py .
  if [ $? -eq 0 ]; then locked_ok=1; break; fi
  echo "lock/build-locked guard tripped, retry $i"
  sleep 1
done
set -e
[ "$locked_ok" = 1 ] || { echo "lock/build-locked failed after retries"; exit 1; }
cp netlify/index.html ../index.html
cp netlify/version.json ../version.json
echo "built from QuickBooks history $FROM to $ASOF"
