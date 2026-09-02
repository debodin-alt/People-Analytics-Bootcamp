#!/usr/bin/env bash
# Meridian regression suite runner.
#
#   ./tests/run.sh
#
# Runs the SQL assertions against the linked Supabase project, then an
# HTTP check with the publishable key. Exits non-zero if anything fails,
# so it can gate a deploy.
#
# The HTTP check is not redundant with the SQL grant assertions: those
# verify what the database permits, this verifies what the deployed API
# actually returns. An earlier revoke looked correct at the grant level
# and still served data, so both layers get checked.

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

echo "── SQL assertions ──────────────────────────────────────────"
raw=$(supabase db query --linked --output-format json -f tests/suite.sql 2>&1)

if ! echo "$raw" | grep -q '"rows"'; then
  echo "  suite failed to run:"
  echo "$raw" | tail -20 | sed 's/^/    /'
  exit 1
fi

echo "$raw" | python3 tests/report.py || fail=1

echo
echo "── HTTP: anonymous key must reach nothing ──────────────────"
if [ -f .env.local ]; then
  URL=$(grep '^VITE_SUPABASE_URL=' .env.local | cut -d= -f2-)
  KEY=$(grep '^VITE_SUPABASE_ANON_KEY=' .env.local | cut -d= -f2-)

  check_blocked() { # label, path, extra-header
    code=$(curl -s -o /dev/null -w "%{http_code}" "$URL/rest/v1/$2" \
      -H "apikey: $KEY" ${3:+-H "$3"})
    if [ "$code" = "200" ]; then
      echo "  [FAIL] $1 returned HTTP 200 — reachable anonymously"
      fail=1
    else
      echo "  [ ok ] $1 blocked (HTTP $code)"
    fi
  }

  check_blocked "employees table"      "employees?select=*&limit=1"
  check_blocked "dim_employee view"    "dim_employee?select=*&limit=1" "Accept-Profile: metrics"
  check_blocked "engagement verbatims" "engagement_open_ended?select=*&limit=1"
  check_blocked "recruiters"           "recruiters?select=*&limit=1"

  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$URL/rest/v1/rpc/active_headcount" \
    -H "apikey: $KEY" -H "Content-Profile: metrics" -H "Content-Type: application/json" --data '{}')
  if [ "$code" = "200" ]; then
    echo "  [FAIL] active_headcount RPC callable anonymously"
    fail=1
  else
    echo "  [ ok ] measures blocked anonymously (HTTP $code)"
  fi
else
  echo "  [skip] .env.local not found"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "SUITE FAILED"
  exit 1
fi
echo "SUITE PASSED"
