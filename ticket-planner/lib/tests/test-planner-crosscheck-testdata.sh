#!/usr/bin/env bash
# test-planner-crosscheck-testdata.sh — Tests for planner-crosscheck-testdata.sh
# (#503 test-data Source field, #504 cited external artifacts) and the phase
# prompt text that feeds it.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-testdata.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-crosscheck-propagation.sh"
source "${LIB_DIR}/planner-crosscheck-testdata.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"
unset PLANNER_NO_TESTS_RULE

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
  *) fail "$1" "missing '$3' in: $2" ;;
  esac
}
assert_not_contains() {
  case "$2" in
  *"$3"*) fail "$1" "unexpected '$3' in: $2" ;;
  *) pass "$1" ;;
  esac
}

# Usage: specs_dir <init>
specs_dir() {
  local d="${REPOS_ROOT}/.ticket-auto/initiatives/$1/artifacts/specs"
  mkdir -p "$d"
  echo "$d"
}
# Usage: write_spec <dir> <slug> <verification-notes> [extra-section-text]
write_spec() {
  cat >"$1/$2.md" <<EOF
# $2

## Acceptance Criteria

- [ ] Something observable.

## Verification Notes

$3

${4:-}
EOF
}

echo "=== planner-crosscheck-testdata tests ==="

# ── Source field parsing ────────────────────────────────────────────────────

echo "--- owned sources are clean ---"
D=$(specs_dir init-owned)
write_spec "$D" "a-one" "1. Role: admin. Test data: none.
2. Role: admin. Test data: none (read-only view).
3. Role: admin. Test data: an archived client. Source: exists:staging clients.sql.
4. Role: admin. Test data: the sample file. Source: \`external:client finance team\`.
5. Role: admin. Test data: invoices. Source: seeded-by:pack.
6. Role: admin. Test data: tickets from another plan. Source: seeded-by:ABC-123.
7. Role: admin. Test data: none. Source: none."
write_spec "$D" "pack-data" "1. Role: any authenticated user. Test data: none." "## Test Data Provided

- Invoice seed script."
out=$(planner_crosscheck_testdata init-owned)
rc=$?
[ "$rc" -eq 0 ] && pass "owned: returns 0" || fail "owned: returns 0" "rc=$rc out=$out"
[ -z "$out" ] && pass "owned: no output" || fail "owned: no output" "$out"

echo "--- every unowned shape is reported, in one finding ---"
D=$(specs_dir init-unowned)
write_spec "$D" "b-one" "1. Role: admin. Test data: 5 invoices.
2. Role: admin. Test data: a 60MB file. Source: generate.
3. Role: admin. Test data: a file. Source: magic:somewhere.
4. Role: admin. Test data: a record. Source: exists:
5. Role: admin. Test data: a record. Source: seeded-by:nowhere.
6. Role: admin. Test data: a record. Source: seeded-by:b-two.
7. Role: admin. Test data: a record. Source: none."
write_spec "$D" "b-two" "1. Role: admin. Test data: none."
out=$(planner_crosscheck_testdata init-unowned)
rc=$?
[ "$rc" -eq 1 ] && pass "unowned: returns 1" || fail "unowned: returns 1" "rc=$rc"
lines=$(printf '%s\n' "$out" | grep -c 'TEST_DATA_UNOWNED')
[ "$lines" -eq 1 ] && pass "unowned: exactly one aggregated finding" || fail "unowned: one finding" "$lines lines: $out"
assert_contains "unowned: count" "$out" "7 test-data need(s) across 1 spec(s) [b-one]"
assert_contains "unowned: missing Source" "$out" "b-one.md#1 (missing Source)"
assert_contains "unowned: generate" "$out" "b-one.md#2 (generate)"
assert_contains "unowned: unknown kind" "$out" "b-one.md#3 (unknown Source kind 'magic')"
assert_contains "unowned: empty exists" "$out" "b-one.md#4 (exists with no value)"
assert_contains "unowned: dangling seeded-by" "$out" "b-one.md#5 (seeded-by:nowhere names no sibling spec)"
assert_contains "unowned: target lacks Test Data Provided" "$out" "b-one.md#6 (seeded-by:b-two resolves to b-two.md, which has no ## Test Data Provided section)"
assert_contains "unowned: none for real data" "$out" "b-one.md#7 (Source: none for real test data)"
assert_contains "unowned: proposes the pack" "$out" "test-data-pack"
assert_not_contains "unowned: not mandatory without the rule" "$out" "MANDATORY"

echo "--- two pairs on one line are checked separately ---"
D=$(specs_dir init-pairs)
write_spec "$D" "c-one" "1. Role: admin. Test data: a client. Source: exists:staging. Test data: a 1,000-row file. Source: generate."
out=$(planner_crosscheck_testdata init-pairs)
assert_contains "pairs: second pair flagged" "$out" "c-one.md#1 (generate)"
lines=$(printf '%s' "$out" | grep -o 'c-one.md#1' | wc -l)
[ "$lines" -eq 1 ] && pass "pairs: first pair owned" || fail "pairs: first pair owned" "$out"

echo "--- case-insensitive markers, fenced blocks ignored, legacy spec skipped ---"
D=$(specs_dir init-misc)
write_spec "$D" "d-one" "1. Role: admin. test data: a file. source: generate.

\`\`\`
2. Role: admin. Test data: inside a fence. Source: generate.
\`\`\`"
cat >"$D/d-legacy.md" <<'EOF'
# d-legacy

## Acceptance Criteria

- [ ] Something.
EOF
out=$(planner_crosscheck_testdata init-misc)
assert_contains "misc: lower-case markers parse" "$out" "d-one.md#1 (generate)"
assert_not_contains "misc: fenced line ignored" "$out" "d-one.md#2"
assert_not_contains "misc: legacy spec without Verification Notes skipped" "$out" "d-legacy"

echo "--- ambiguous seeded-by prefix does not resolve ---"
D=$(specs_dir init-ambig)
write_spec "$D" "e-one" "1. Role: admin. Test data: x. Source: seeded-by:pack."
write_spec "$D" "pack-a" "1. Role: admin. Test data: none." "## Test Data Provided

- a"
write_spec "$D" "pack-b" "1. Role: admin. Test data: none." "## Test Data Provided

- b"
out=$(planner_crosscheck_testdata init-ambig)
assert_contains "ambig: prefix of two specs is unresolved" "$out" "seeded-by:pack names no sibling spec"

# ── No-tests rule (#503 point 4) ────────────────────────────────────────────

echo "--- self-seeded: owned normally, unowned under the no-tests rule ---"
D=$(specs_dir init-self)
write_spec "$D" "f-one" "1. Role: admin. Test data: x. Source: seeded-by:f-one." "## Test Data Provided

- its own seed"
out=$(planner_crosscheck_testdata init-self)
[ -z "$out" ] && pass "self: owned without the rule" || fail "self: owned without the rule" "$out"

out=$(PLANNER_NO_TESTS_RULE=true planner_crosscheck_testdata init-self)
assert_contains "self: env rule flags it" "$out" "f-one.md#1 (self-seeded"
assert_contains "self: env rule makes remedy mandatory" "$out" "MANDATORY"
assert_contains "self: names the rule source" "$out" "(env)"

mkdir -p "${REPOS_ROOT}/svc-a"
echo "Implementation must not write unit tests; QA owns fixtures." >"${REPOS_ROOT}/svc-a/CLAUDE.md"
out=$(planner_crosscheck_testdata init-self)
assert_contains "self: repo CLAUDE.md rule flags it" "$out" "svc-a/CLAUDE.md"
out=$(PLANNER_NO_TESTS_RULE=false planner_crosscheck_testdata init-self)
[ -z "$out" ] && pass "self: PLANNER_NO_TESTS_RULE=false overrides detection" || fail "self: env false override" "$out"
rm -f "${REPOS_ROOT}/svc-a/CLAUDE.md"

echo "--- no-tests rule detection is narrow ---"
for phrase in "Implementation does not write tests." "Never add tests in feature tickets." "Agents don't write any automated tests." "You must not create test fixtures."; do
  echo "$phrase" >"${REPOS_ROOT}/CLAUDE.md"
  planner_testdata_no_tests_rule >/dev/null && pass "rule on: $phrase" || fail "rule on: $phrase" "not detected"
done
for phrase in "Always write tests for new code." "Run the tests before committing." "Do not write to production." "No tests are flaky here."; do
  echo "$phrase" >"${REPOS_ROOT}/CLAUDE.md"
  planner_testdata_no_tests_rule >/dev/null && fail "rule off: $phrase" "false positive" || pass "rule off: $phrase"
done
rm -f "${REPOS_ROOT}/CLAUDE.md"

# ── Cited artifacts (#504) ──────────────────────────────────────────────────

ART="${REPOS_ROOT}/.ticket-auto/initiatives/init-cited/artifacts"
mkdir -p "$ART"
cat >"${ART}/discovery.md" <<'EOF'
# Discovery

## Cited Artifacts

- `client sample file (43 rows)` — NOT FOUND (searched: attachments, artifacts/, REPOS_ROOT)
- `export template` — FOUND: docs/export.xlsx
- `legacy mapping sheet` — NOT FOUND (searched: REPOS_ROOT)

## Constraints

- `not an artifact` — NOT FOUND in this section, must be ignored
EOF

echo "--- missing artifacts come from the Cited Artifacts section only ---"
out=$(planner_cited_artifacts_missing init-cited)
assert_contains "missing: first" "$out" "client sample file (43 rows)"
assert_contains "missing: second" "$out" "legacy mapping sheet"
assert_not_contains "missing: FOUND excluded" "$out" "export template"
assert_not_contains "missing: other sections ignored" "$out" "not an artifact"

echo "--- question lines are canonical ---"
out=$(planner_cited_artifacts_questions init-cited)
assert_contains "questions: canonical line" "$out" '- CITED_ARTIFACT: `client sample file (43 rows)` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING'
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT)" -eq 2 ] && pass "questions: one per missing artifact" || fail "questions: count" "$out"

echo "--- no consensus.md: both unraised ---"
out=$(planner_crosscheck_cited_artifacts init-cited)
rc=$?
[ "$rc" -eq 1 ] && pass "unraised: returns 1" || fail "unraised: returns 1" "rc=$rc"
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT_UNRAISED)" -eq 2 ] && pass "unraised: two findings" || fail "unraised: two findings" "$out"

echo "--- pasted questions left PENDING: unresolved ---"
{
  echo "# Consensus"
  echo ""
  echo "## Open Questions"
  echo ""
  planner_cited_artifacts_questions init-cited
} >"${ART}/consensus.md"
out=$(planner_crosscheck_cited_artifacts init-cited)
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT_UNRESOLVED)" -eq 2 ] && pass "pending: two unresolved" || fail "pending: two unresolved" "$out"
assert_contains "pending: quotes the answer" "$out" "Answer: PENDING"

echo "--- answered (case-insensitive name): clean; malformed answers stay unresolved ---"
cat >"${ART}/consensus.md" <<'EOF'
## Open Questions

- CITED_ARTIFACT: `Client Sample File (43 rows)` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: external:client finance team
- CITED_ARTIFACT: `legacy mapping sheet` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: generate
EOF
out=$(planner_crosscheck_cited_artifacts init-cited)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "answered: clean" || fail "answered: clean" "rc=$rc out=$out"

sed -i 's/Answer: external:client finance team/Answer: external:/; s/Answer: generate/Answer: generate it please/' "${ART}/consensus.md"
out=$(planner_crosscheck_cited_artifacts init-cited)
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT_UNRESOLVED)" -eq 2 ] && pass "malformed: both unresolved" || fail "malformed: both unresolved" "$out"

echo "--- no Cited Artifacts section (legacy discovery.md): skipped ---"
ART2="${REPOS_ROOT}/.ticket-auto/initiatives/init-legacy/artifacts"
mkdir -p "$ART2"
printf '# Discovery\n\n## Code Paths\n\nnone\n' >"${ART2}/discovery.md"
out=$(planner_crosscheck_cited_artifacts init-legacy)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "legacy: clean" || fail "legacy: clean" "rc=$rc out=$out"

# ── Orchestrator wiring ─────────────────────────────────────────────────────

echo "--- Crosscheck wiring: codes are blocking, cross-file grouped, hinted ---"
source "${LIB_DIR}/planner-crosscheck.sh"
for code in TEST_DATA_UNOWNED CITED_ARTIFACT_UNRAISED CITED_ARTIFACT_UNRESOLVED; do
  _planner_crosscheck_is_warn_code "$code" && fail "$code blocking" "listed as warn" || pass "$code is blocking"
  hint=$(planner_crosscheck_fix_hint "$code")
  assert_not_contains "$code has a fix hint" "$hint" "no canned hint"
done
assert_contains "TEST_DATA_UNOWNED groups cross-file" " ${PLANNER_CROSSCHECK_CROSS_FILE_CODES} " " TEST_DATA_UNOWNED "
run_body=$(declare -f planner_crosscheck_run)
assert_contains "run calls testdata check" "$run_body" "planner_crosscheck_testdata"
assert_contains "run calls cited-artifacts check" "$run_body" "planner_crosscheck_cited_artifacts"

# ── Phase prompts ───────────────────────────────────────────────────────────

echo "--- phase prompts carry the contract ---"
source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-phase-prompts.sh"
SD="${TMPDIR}/state"
p_spec=$(planner_prompt_specify "INIT-1" "an idea" "$SD")
assert_contains "Specify: Source field" "$p_spec" "Source: seeded-by:"
assert_contains "Specify: closed enum" "$p_spec" "Source: exists:<where> | seeded-by:<spec-slug> | external:<who> | generate"
assert_contains "Specify: Test Data Provided" "$p_spec" "## Test Data Provided"
assert_contains "Specify: no-tests rule check" "$p_spec" "planner_testdata_no_tests_rule"
assert_contains "Specify: contract doc" "$p_spec" "docs/test-data-source.md"

p_disc=$(planner_prompt_discovery "INIT-1" "an idea" "$SD")
assert_contains "Discovery: Cited Artifacts section required" "$p_disc" "discovery.md must have a \`## Cited Artifacts\` section"
assert_contains "Discovery: NOT FOUND shape" "$p_disc" "— NOT FOUND (searched:"
assert_contains "Discovery: FOUND shape" "$p_disc" "— FOUND:"

p_cons=$(planner_prompt_consensus "INIT-1" "an idea" "$SD")
assert_contains "Consensus: Open Questions section" "$p_cons" "**Open Questions**"
assert_contains "Consensus: question assembly in bash" "$p_cons" "planner_cited_artifacts_questions \"INIT-1\""
assert_not_contains "Consensus: plugin root interpolated, not left to the agent" "$p_cons" 'CLAUDE_PLUGIN_ROOT="${_PLANNER_PROMPT_LIB_ROOT}"'

p_tg=$(planner_prompt_ticketgen "INIT-1" "an idea" "$SD" 2>/dev/null)
assert_contains "TicketGen: Test Data Prerequisites carry Source" "$p_tg" "Source: <kind>[:<value>]"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
