"""Formats the SQL suite's result rows and sets the exit code.

Reads the CLI's JSON output on stdin. Exits 1 if any assertion failed, so
the runner can gate on it.
"""

import json
import sys

raw = sys.stdin.read()

# supabase db query --output-format json has been observed returning two
# different top-level shapes for the identical CLI version (2.111.0) and
# the identical query: {"boundary": ..., "rows": [...]} locally, and a
# bare [...] array of row objects in GitHub Actions. Rather than assume
# either is authoritative, accept both — whichever bracket appears first
# is where the payload starts.
brace = raw.find('{')
bracket = raw.find('[')
candidates = [i for i in (brace, bracket) if i >= 0]
if not candidates:
    print("  no JSON in suite output:")
    print(raw[-2000:])
    sys.exit(1)
start = min(candidates)

parsed = json.loads(raw[start:])
rows = parsed["rows"] if isinstance(parsed, dict) else parsed
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
