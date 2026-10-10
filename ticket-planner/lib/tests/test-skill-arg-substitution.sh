#!/usr/bin/env bash
# test-skill-arg-substitution.sh — Guards against skill-argument substitution
# clobbering bash positional parameters in skill bodies (#455).
#
# Claude Code substitutes `$ARGUMENTS`, `$ARGUMENTS[N]` and the bare `$N`
# shorthand (0-based: `$0` is the first argument) in a skill body before the
# agent ever sees it. It does not know about bash: a bare positional parameter
# inside a ```bash block is rewritten too. ticket-planner's flag loop had
# `case "$1" in`, which rendered as `case "INIT-..." in`, so no flag parsed.
# The braced forms (`${1}`, `${1:-}`, `${1#*=}`) are not substituted.
#
# Test 1 lints every SKILL.md and commands/*.md in the repo for a bare token.
# Test 2 renders ticket-planner's flag loop the way the loader does and runs it.
#
# Run: bash ticket-planner/lib/tests/test-skill-arg-substitution.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_ROOT}/.." && pwd)"
PLANNER_SKILL="${PLUGIN_ROOT}/skills/ticket-planner/SKILL.md"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

echo "=== skill argument substitution tests ==="

# ── Test 1: no bare $N / $ARGUMENTS in any skill or command body ────────────────

echo "--- Test 1: no bare positional/\$ARGUMENTS tokens in skill bodies ---"

bodies=()
while IFS= read -r -d '' f; do
  bodies+=("$f")
done < <(find "$REPO_ROOT" \( -name .git -o -name node_modules -o -path "${REPO_ROOT}/.claude" \) -prune -o \
  -type f \( -name SKILL.md -o -path '*/commands/*.md' \) -print0)

if [ "${#bodies[@]}" -eq 0 ]; then
  fail "skill body discovery" "found no SKILL.md under ${REPO_ROOT}"
else
  # A `$` followed by a digit or ARGUMENTS, not escaped with a backslash.
  hits=$(grep -nHE '(^|[^\\])\$([0-9]|ARGUMENTS)' "${bodies[@]}" || true)
  if [ -z "$hits" ]; then
    pass "${#bodies[@]} skill bodies contain no bare \$N/\$ARGUMENTS token"
  else
    fail "bare positional tokens found (use \${N} instead)" ""
    printf '%s\n' "$hits" | sed "s|^${REPO_ROOT}/|    |"
  fi
fi

# ── Test 2: the rendered planner flag loop parses its flags ─────────────────────

echo "--- Test 2: rendered flag loop parses resume <ID> --create ---"

loop=$(awk '/^while \[ "\$#" -gt 0 \]; do$/ {p = 1} p {print} p && /^done$/ {exit}' "$PLANNER_SKILL")
if [ -z "$loop" ]; then
  fail "flag loop extraction" "no 'while [ \"\$#\" -gt 0 ]' loop in step 2a of SKILL.md"
else
  # Emulate the loader for `/ticket-planner resume INIT-1-2 --create --until Review`:
  # every bare $N becomes the Nth (0-based) invocation argument.
  rendered=$(printf '%s\n' "$loop" | SKILL_ARGS="resume INIT-1-2 --create --until Review" \
    perl -pe 'BEGIN { @a = split / /, $ENV{SKILL_ARGS} } s/\$(\d+)(?!\w)/$a[$1] \/\/ ""/ge')

  # Step 2 shifts the mode off, so the loop sees the remaining args.
  got=$(RENDERED="$rendered" bash -c '
    CREATE_FLAG=""; UNTIL_PHASE=""; SHARED_BRANCH_FLAG=""; NO_SHARED_BRANCH_FLAG=""
    TEAM_REF=""; PROJECT_REF=""; NO_PROJECT_FLAG=""; MILESTONE_REF=""
    REFRESH_BODIES_FLAG=""; ACCEPT_FLAGS=()
    set -- INIT-1-2 --create --until Review
    eval "$RENDERED"
    echo "${CREATE_FLAG}|${UNTIL_PHASE}"
  ' 2>&1 || true)

  if [ "$got" = "true|Review" ]; then
    pass "rendered loop sets CREATE_FLAG=true and UNTIL_PHASE=Review"
  else
    fail "rendered loop did not parse flags" "expected 'true|Review', got '${got}'"
  fi
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
