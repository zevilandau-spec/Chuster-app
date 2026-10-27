"""Add the shared-database settings (space, key, url) to the data that gets locked. Only the locked Netlify build gets them.
Usage: python3 -I add_sync.py build/data.json secret/sync.json build/data_sync.json"""
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
d['sync'] = json.load(open(sys.argv[2], encoding='utf-8'))
json.dump(d, open(sys.argv[3], 'w', encoding='utf-8'), separators=(',', ':'), ensure_ascii=False)
print('sync added; url =', d['sync'].get('url') or '(none yet)')
