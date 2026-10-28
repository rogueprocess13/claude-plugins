#!/usr/bin/env bash
# test-planner-crosscheck-ac-coverage.sh — planner-ac-coverage-and-epic-uat
# group 2: AC_STATUS_UNCOVERED's token and response-context rules, the
# sentence excerpt, TD-spec skip, filing under the spec in the findings
# report, and the --accept override. The fixture harness
# (test-planner-crosscheck-fixtures.sh: ac-status-*) covers the full run.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-ac-coverage.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

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
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing '$3' in: $2" ;;
  esac
}

# _codes <behaviour-lines> <ac-lines> — uncovered codes, space-separated.
_codes() {
  local f="${TMPDIR}/one.md"
  printf '# s\n\n## Proposed Behaviour\n\n%s\n\n## Acceptance Criteria\n\n%s\n' "$1" "$2" >"$f"
  _planner_crosscheck_ac_coverage_one "$f" | cut -f1 | tr '\n' ' ' | sed 's/ $//'
}

echo "--- response context ---"
assert_eq "returns <code> uncovered" "$(_codes '- Unexpected errors return 500.' '- [ ] ok')" "500"
assert_eq "covered by an AC naming the code" "$(_codes '- Unexpected errors return 500.' '- [ ] a crash returns 500')" ""
assert_eq "code followed by a backticked body" "$(_codes '- Then 409 `{"errors":{}}` comes back.' '- [ ] ok')" "409"
assert_eq "responds with status <code>" "$(_codes '- It responds with status 503.' '- [ ] ok')" "503"
assert_eq "→ <code>" "$(_codes '- Duplicate slug → 422.' '- [ ] ok')" "422"
assert_eq "quantity after the verb is not a response" "$(_codes '- The list returns at most 100 entries.' '- [ ] ok')" ""
assert_eq "verb in an earlier sentence does not reach" "$(_codes '- It returns nothing. Cap is 200 rows.' '- [ ] ok')" ""
assert_eq "on <code> is not a response" "$(_codes '- On 401, clear the token.' '- [ ] ok')" ""
assert_eq "port and cost are not codes" "$(_codes '- Listen on port 3000 and return cost 10 hashes.' '- [ ] ok')" ""
assert_eq "hyphen-glued digits are not codes" "$(_codes '- Seed password `Jake-Pass-123` returns it.' '- [ ] ok')" ""
assert_eq "one finding per code" "$(_codes $'- Bad input returns 422.\n- Blank title returns 422.' '- [ ] ok')" "422"
assert_eq "AC substring is not coverage" "$(_codes '- Errors return 500.' '- [ ] request id 5000 logged')" "500"

f="${TMPDIR}/fence.md"
printf '# s\n\n## Technical Context\n\n```\nreturn 503\n```\n\n## Acceptance Criteria\n\n- [ ] ok\n' >"$f"
assert_eq "fenced code ignored" "$(_planner_crosscheck_ac_coverage_one "$f")" ""
f="${TMPDIR}/other.md"
printf '# s\n\n## Out of Scope\n\nreturns 500\n\n## Acceptance Criteria\n\n- [ ] ok\n' >"$f"
assert_eq "other sections ignored" "$(_planner_crosscheck_ac_coverage_one "$f")" ""

echo "--- excerpt ---"
f="${TMPDIR}/ex.md"
printf '# s\n\n## Proposed Changes\n\n- First sentence returns 400 `{}`. Any other error returns 500 `{"a":1}`. Trailing text.\n\n## Acceptance Criteria\n\n- [ ] it returns 400\n' >"$f"
assert_eq "excerpt is the sentence holding the code" "$(_planner_crosscheck_ac_coverage_one "$f" | cut -f2)" 'Any other error returns 500 `{"a":1}`.'

echo "--- initiative run ---"
INIT="INIT-ACC-1"
planner_state_init "$INIT" "an idea" >/dev/null
SPECS="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/artifacts/specs"
mkdir -p "$SPECS"
printf '# a\n\n## Proposed Changes\n\n- Unexpected errors return 500.\n\n## Acceptance Criteria\n\n- [ ] ok\n' >"${SPECS}/api-errors.md"
printf '<!-- planner:testdata-synth v1 -->\n# td\n\n## Proposed Changes\n\n- Seeding returns 500 on failure.\n\n## Acceptance Criteria\n\n- [ ] ok\n' >"${SPECS}/api-errors-test-data.md"
out=$(planner_crosscheck_ac_coverage "$INIT")
rc=$?
assert_eq "rc 1 on a finding" "$rc" "1"
assert_eq "one finding (TD spec skipped)" "$(grep -c AC_STATUS_UNCOVERED <<<"$out")" "1"
assert_contains "finding shape" "$out" "planner-crosscheck-ac-coverage: AC_STATUS_UNCOVERED api-errors.md status 500"

planner_crosscheck_run "$INIT" >/dev/null 2>&1
log=$(planner_state_log "$INIT")
assert_contains "finding reaches state.log" "$(cat "$log")" "|META|crosscheck|fail|AC_STATUS_UNCOVERED api-errors.md status 500"
report=$(planner_crosscheck_findings_report "$INIT" 2>&1)
if grep -q "(no file)" <<<"$report"; then
  fail "report files it under the spec" "$report"
else
  assert_contains "report files it under the spec" "$report" "api-errors.md"
fi
assert_contains "report carries the fix hint" "$report" "never delete the behaviour sentence"

planner_crosscheck_accept_set "$INIT" AC_STATUS_UNCOVERED "fallback covered by integration suite" >/dev/null
planner_crosscheck_run "$INIT" >/dev/null 2>&1
assert_contains "--accept makes it non-blocking" "$(tail -5 "$log")" "|META|crosscheck|accepted|AC_STATUS_UNCOVERED"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
