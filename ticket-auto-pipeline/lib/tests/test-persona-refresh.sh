#!/usr/bin/env bash
# test-persona-refresh.sh — persona-refresh.sh `list` target enumeration
# (DET-SU-20: the skill's inline `find` was malformed and enumerated nothing).
# Usage: bash test-persona-refresh.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
PR="$LIB_DIR/persona-refresh.sh"

PASS=0
FAIL=0
ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
nok() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mk() { # mk <relpath> <last-reviewed|"">
  mkdir -p "$(dirname "$TMP/personas/$1")"
  {
    echo "---"
    echo "name: x"
    echo "version: 1"
    [ -n "$2" ] && echo "last-reviewed: $2"
    echo "---"
    echo "body"
  } >"$TMP/personas/$1"
}
mk base/analyzer.md 2026-10-15
mk base/architect.md 2026-01-01
mk base/README.md 2026-01-01
mk specializers/backend/python.md 2026-10-20
mk specializers/frontend/react.md ""
mk specializers/README.md ""
echo "# changelog" >"$TMP/personas/CHANGELOG.md"

export PERSONA_REFRESH_TODAY=2026-10-23
run() { CLAUDE_PLUGIN_ROOT="$TMP" bash "$PR" "$@"; }

# 1. `list all` enumerates base + specializers, excluding README/CHANGELOG
out=$(run list all 2>&1)
rc=$?
n=$(printf '%s\n' "$out" | grep -c '\.md' || true)
if [ "$rc" -eq 0 ] && [ "$n" -eq 4 ] && ! printf '%s' "$out" | grep -q README; then
  ok "list all enumerates 4 persona files, no README"
else
  nok "list all enumerates 4 persona files, no README (rc=$rc n=$n): $out"
fi

# 2. default target is all
out2=$(run list 2>&1)
if [ "$out2" = "$out" ]; then ok "list defaults to all"; else nok "list defaults to all"; fi

# 3. staleness: reviewed 8 days ago → skip; 3 days ago → skip; Jan → refresh;
#    missing last-reviewed → refresh
act() { printf '%s\n' "$out" | awk -F'\t' -v p="$1" 'index($1,p){print $3}'; }
if [ "$(act base/analyzer.md)" = skip ] && [ "$(act backend/python.md)" = skip ] &&
  [ "$(act base/architect.md)" = refresh ] && [ "$(act frontend/react.md)" = refresh ]; then
  ok "30-day staleness skip; missing last-reviewed refreshes"
else
  nok "30-day staleness skip; missing last-reviewed refreshes: $out"
fi

# 4. --stale-days 5 → the 8-day-old file refreshes
out3=$(run list all --stale-days 5 2>&1)
a=$(printf '%s\n' "$out3" | awk -F'\t' 'index($1,"base/analyzer.md"){print $3}')
if [ "$a" = refresh ]; then ok "--stale-days overrides threshold"; else nok "--stale-days overrides threshold: $out3"; fi

# 5. explicit name always refreshes (specializer and base)
o=$(run list backend/python 2>&1)
o2=$(run list analyzer 2>&1)
if [[ "$o" == *"specializers/backend/python.md"*"refresh" ]] && [[ "$o2" == *"base/analyzer.md"*"refresh" ]]; then
  ok "explicit name resolves and always refreshes"
else
  nok "explicit name resolves and always refreshes: $o | $o2"
fi

# 6. unknown persona → exit 1
if run list backend/cobol >/dev/null 2>&1; then nok "unknown persona exits 1"; else ok "unknown persona exits 1"; fi

# 7. real personas dir: list all finds every shipped persona file
real=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PR" list all 2>/dev/null | wc -l)
expect=$(find "$PLUGIN_DIR/personas/base" "$PLUGIN_DIR/personas/specializers" -type f -name '*.md' -not -name README.md | wc -l)
if [ "$real" -gt 0 ] && [ "$real" -eq "$expect" ]; then
  ok "list all over shipped personas ($real files)"
else
  nok "list all over shipped personas (got $real, expected $expect)"
fi

# 8. the skill no longer carries the malformed inline find
SKILL="$PLUGIN_DIR/skills/ticket-persona-refresh/SKILL.md"
if grep -q 'find personas/base .*personas/specializers' "$SKILL"; then
  nok "SKILL.md Step 1 has no malformed find"
elif grep -q 'persona-refresh.sh list' "$SKILL"; then
  ok "SKILL.md Step 1 has no malformed find"
else
  nok "SKILL.md Step 1 uses persona-refresh.sh list"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
