"""Formats the SQL suite's result rows and sets the exit code.

Reads the CLI's JSON output on stdin. Exits 1 if any assertion failed, so
the runner can gate on it.
"""

import json
import sys

raw = sys.stdin.read()
start = raw.find('{')
if start < 0:
    print("  no JSON in suite output:")
    print(raw[-2000:])
    sys.exit(1)

rows = json.loads(raw[start:])["rows"]
failed = [r for r in rows if not r["pass"]]

by_section = {}
for r in rows:
    by_section.setdefault(r["section"], []).append(r)

for section in sorted(by_section):
    rs = by_section[section]
    bad = [r for r in rs if not r["pass"]]
    mark = "FAIL" if bad else " ok "
    print(f"  [{mark}] {section:12s} {len(rs) - len(bad)}/{len(rs)}")
    for r in bad:
        print(f"         {r['test']}")
        print(f"           expected: {r['expected']}")
        print(f"           actual:   {r['actual']}")

print()
print(f"  {len(rows) - len(failed)}/{len(rows)} assertions passed")
sys.exit(1 if failed else 0)
