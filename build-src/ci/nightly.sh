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
if ! python3 tools/fetch_history.py "$CHUSTER_DB_URL" sync.json raw; then
  echo "No full history yet; the app stays as it is."; exit 0
fi
python3 -I tools/convert_raw.py raw export
ASOF=$(python3 -c "import json;print(json.load(open('raw/meta.json'))['asOf'])")
FROM=$(python3 -c "import json;print(json.load(open('raw/meta.json'))['from'])")
mkdir -p build
CHUSTER_NIGHTLY=1 sh tools/build_from.sh export build/data.json "$ASOF" "$FROM"
python3 -I tools/add_sync.py build/data.json sync.json build/data_sync.json
node tools/lock.js build/data_sync.json passcodes.json build/locked.json
python3 -I tools/build_locked.py .
cp netlify/index.html ../index.html
echo "built from QuickBooks history $FROM to $ASOF"
