#!/usr/bin/env bash
# test-planner-sibling-rules.sh — the two rules about what a spec takes from a
# sibling ticket in the same initiative reach the prompts that write and amend
# specs (dispatch rehearsal iteration 05):
#   F43  planner_sibling_blocker_rule: a sibling a spec builds on is a direct
#        blocked-by, also when it is already reachable through another blocker.
#   F38  planner_sibling_citation_rule: a file an earlier ticket creates is
#        cited `Name (new in <slug>):path`, and the citation linter accepts it.
#
# Usage: bash ticket-planner/lib/tests/test-planner-sibling-rules.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-phase-prompts.sh"
source "${LIB_DIR}/planner-crosscheck-citations.sh"

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
assert_contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing '$3'" ;;
  esac
}

echo "=== planner sibling rules tests ==="

INIT="INIT-77"
STATE_DIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
mkdir -p "${STATE_DIR}/artifacts/specs"

blocker=$(planner_sibling_blocker_rule)
citation=$(planner_sibling_citation_rule)
assert_contains "F43: blocker rule names the direct blocked-by" "$blocker" 'blocked-by:<that sibling'
assert_contains "F43: blocker rule covers the transitive case" "$blocker" "already depends on that sibling"
assert_contains "F38: citation rule shows the sibling marker" "$citation" '(new in <sibling-slug>):path'

specify=$(planner_prompt_specify "$INIT" "an idea" "$STATE_DIR" 2>/dev/null)
consensus=$(planner_prompt_consensus "$INIT" "an idea" "$STATE_DIR" 2>/dev/null)
[ -n "$specify" ] && pass "Specify prompt renders" || fail "Specify prompt renders" "empty"
[ -n "$consensus" ] && pass "Consensus prompt renders" || fail "Consensus prompt renders" "empty"
assert_contains "F43: Specify carries the blocker rule" "$specify" "Every sibling a spec builds on is a direct blocker."
assert_contains "F43: Consensus carries the blocker rule" "$consensus" "Every sibling a spec builds on is a direct blocker."
assert_contains "F38: Specify carries the citation rule" "$specify" '(new in <sibling-slug>):path'
assert_contains "F38: Consensus carries the citation rule" "$consensus" '(new in <sibling-slug>):path'
assert_contains "F38: Consensus re-lints citations after its edits" "$consensus" "planner_crosscheck_citations \"${INIT}\""

# The linter accepts the marker the rule teaches: a file that does not exist
# yet resolves with `(new in <slug>)` and fails without it.
echo "--- the citation linter accepts the sibling marker ---"
mkdir -p "${REPOS_ROOT}/svc"
(cd "${REPOS_ROOT}/svc" && git init -q && git commit -q --allow-empty -m init) 2>/dev/null
spec_with() {
  printf '# s\n\n## Signals\n\n```json\n{\n  "TargetSymbols": "%s"\n}\n```\n' "$1" >"${STATE_DIR}/artifacts/specs/s.md"
}
spec_with 'envStart (new in backend-foundation):svc/scripts/env-start.sh'
out=$(planner_crosscheck_citations "$INIT" 2>&1)
case "$out" in *CITATION_UNRESOLVED*) fail "F38: (new in <slug>) resolves" "$out" ;; *) pass "F38: (new in <slug>) resolves" ;; esac
spec_with 'envStart:svc/scripts/env-start.sh'
out=$(planner_crosscheck_citations "$INIT" 2>&1)
assert_contains "F38: the same path with no marker is unresolved" "$out" "CITATION_UNRESOLVED"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
