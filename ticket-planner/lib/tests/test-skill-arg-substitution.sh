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
# Test 2 renders ticket-planner's flag-parse call the way the loader does and runs it.
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

# ── Test 2: the rendered planner flag call parses its flags ────────────────────
#
# The flag loop lives in lib/planner-invocation.sh since skill-deterministic-
# extraction 1, out of the loader's reach. What the skill still carries is the
# call line: render it the way the loader does, then run it against the lib.

echo "--- Test 2: rendered planner_flags_parse call parses resume <ID> --create ---"

if grep -qE '^while \[ "\$#" -gt 0 \]; do$' "$PLANNER_SKILL"; then
  fail "flag loop location" "SKILL.md carries an inline flag loop again — it belongs in lib/planner-invocation.sh"
fi
call=$(grep -m1 '^planner_flags_parse ' "$PLANNER_SKILL" || true)
if [ -z "$call" ]; then
  fail "flag call extraction" "no 'planner_flags_parse' call in step 2a of SKILL.md"
else
  # Emulate the loader for `/ticket-planner resume INIT-1-2 --create --until Review`:
  # every bare $N becomes the Nth (0-based) invocation argument.
  rendered=$(printf '%s\n' "$call" | SKILL_ARGS="resume INIT-1-2 --create --until Review" \
    perl -pe 'BEGIN { @a = split / /, $ENV{SKILL_ARGS} } s/\$(\d+)(?!\w)/$a[$1] \/\/ ""/ge')

  # Step 2 shifts the mode off, so the call sees the remaining args.
  got=$(RENDERED="$rendered" LIB="${PLUGIN_ROOT}/lib" REPOS_ROOT="$(mktemp -d)" bash -c '
    source "${LIB}/planner-state.sh"; source "${LIB}/planner-router.sh"
    source "${LIB}/planner-invocation.sh"
    MODE=resume
    set -- INIT-1-2 --create --until Review
    eval "$RENDERED"
    echo "${CREATE_FLAG}|${UNTIL_PHASE}"
  ' 2>&1 || true)

  if [ "$got" = "true|Review" ]; then
    pass "rendered call sets CREATE_FLAG=true and UNTIL_PHASE=Review"
  else
    fail "rendered call did not parse flags" "expected 'true|Review', got '${got}'"
  fi
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
