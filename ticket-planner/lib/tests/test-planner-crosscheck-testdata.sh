#!/usr/bin/env bash
# test-planner-crosscheck-testdata.sh — Tests for planner-crosscheck-testdata.sh
# (#503 test-data Source field, #504 cited external artifacts) and the phase
# prompt / stop-describe text that feeds it.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-testdata.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
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

# Usage: new_init <init> [legacy] — prints the specs dir. A contract initiative
# gets planner_state_init (which writes the contract marker); a legacy one gets
# a hand-written log without it, the shape a pre-0.17.0 initiative has.
new_init() {
  local d="${REPOS_ROOT}/.ticket-auto/initiatives/$1"
  mkdir -p "$d/artifacts/specs"
  if [ "${2:-}" = "legacy" ]; then
    printf '2026-01-01T00:00:00Z|META|schema|start|1\n' >"$d/state.log"
  else
    planner_state_init "$1" "test idea" >/dev/null 2>&1
  fi
  echo "$d/artifacts/specs"
}
# Usage: write_spec <dir> <slug> <verification-notes> [extra-section-text] [heading]
write_spec() {
  cat >"$1/$2.md" <<EOF
# $2

## Acceptance Criteria

- [ ] Something observable.

${5:-## Verification Notes}

$3

${4:-}
EOF
}

echo "=== planner-crosscheck-testdata tests ==="

# ── Source field parsing ────────────────────────────────────────────────────

echo "--- owned sources are clean ---"
D=$(new_init INIT-owned)
write_spec "$D" "a-one" "1. Role: admin. Test data: none.
2. Role: admin. Test data: none (read-only view).
3. Role: admin. Test data: an archived client. Source: exists:staging clients.sql.
4. Role: admin. Test data: the sample file. Source: \`external:client finance team\`.
5. Role: admin. Test data: invoices. Source: seeded-by:pack.
6. Role: admin. Test data: tickets from another plan. Source: seeded-by:ABC-123.
7. Role: admin. Test data: none. Source: none.
8. Role: admin. Test data: no special data required.
9. Role: admin. Test data: not applicable.
10. Role: admin. Test data: N/A."
write_spec "$D" "pack-data" "1. Role: any authenticated user. Test data: none." "## Test Data Provided

- Invoice seed script."
out=$(planner_crosscheck_testdata INIT-owned)
rc=$?
[ "$rc" -eq 0 ] && pass "owned: returns 0" || fail "owned: returns 0" "rc=$rc out=$out"
[ -z "$out" ] && pass "owned: no output" || fail "owned: no output" "$out"

echo "--- every unowned shape is reported, in one finding ---"
D=$(new_init INIT-unowned)
write_spec "$D" "b-one" "1. Role: admin. Test data: 5 invoices.
2. Role: admin. Test data: a 60MB file. Source: generate.
3. Role: admin. Test data: a file. Source: magic:somewhere.
4. Role: admin. Test data: a record. Source: exists:
5. Role: admin. Test data: a record. Source: seeded-by:nowhere.
6. Role: admin. Test data: a record. Source: seeded-by:b-two.
7. Role: admin. Test data: a record. Source: none."
write_spec "$D" "b-two" "1. Role: admin. Test data: none."
out=$(planner_crosscheck_testdata INIT-unowned)
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

echo "--- parser leniency: last Source wins, markdown, case, punctuation, bullets, heading variants ---"
D=$(new_init INIT-lenient)
write_spec "$D" "c-one" "1. Role: admin. Test data: a client. Source: exists:staging. Test data: a 1,000-row file. Source: generate.
2. Role: admin. **Test Data:** a file. **Source:** Generate.
3. Role: admin. Test data: a file. Source: exists:old. Source: generate!
4. Role: admin. _Test data:_ a file. _Source:_ \`EXTERNAL:vendor\`;
- Role: admin. Test-data: a bulleted need. source: generate
* Role: admin. Test data: none" "" "## Verification Notes (per AC)"
out=$(planner_crosscheck_testdata INIT-lenient)
assert_contains "lenient: second pair of a line flagged" "$out" "c-one.md#1 (generate)"
n=$(printf '%s' "$out" | grep -o 'c-one.md#1 ' | wc -l)
[ "$n" -eq 1 ] && pass "lenient: first pair of a line owned" || fail "lenient: first pair owned" "$out"
assert_contains "lenient: bold markers + capitalised kind" "$out" "c-one.md#2 (generate)"
assert_contains "lenient: last Source wins" "$out" "c-one.md#3 (generate)"
assert_not_contains "lenient: italic markers + backticked upper-case kind owned" "$out" "c-one.md#4"
assert_contains "lenient: bullet need parsed and labelled" "$out" "c-one.md#b1 (generate)"
assert_not_contains "lenient: bullet none is fine" "$out" "c-one.md#b2"

echo "--- fences ignored, spec without Verification Notes skipped ---"
D=$(new_init INIT-misc)
write_spec "$D" "d-one" "1. Role: admin. Test data: a file. Source: generate.

\`\`\`
2. Role: admin. Test data: inside a fence. Source: generate.
\`\`\`"
cat >"$D/d-nonotes.md" <<'EOF'
# d-nonotes

## Acceptance Criteria

- [ ] Something.
EOF
out=$(planner_crosscheck_testdata INIT-misc)
assert_contains "misc: real line flagged" "$out" "d-one.md#1 (generate)"
assert_not_contains "misc: fenced line ignored" "$out" "d-one.md#2"
assert_not_contains "misc: spec without Verification Notes skipped" "$out" "d-nonotes"

echo "--- ambiguous seeded-by prefix does not resolve ---"
D=$(new_init INIT-ambig)
write_spec "$D" "e-one" "1. Role: admin. Test data: x. Source: seeded-by:pack."
write_spec "$D" "pack-a" "1. Role: admin. Test data: none." "## Test Data Provided

- a"
write_spec "$D" "pack-b" "1. Role: admin. Test data: none." "## Test Data Provided

- b"
out=$(planner_crosscheck_testdata INIT-ambig)
assert_contains "ambig: prefix of two specs is unresolved" "$out" "seeded-by:pack names no sibling spec"

echo "--- long lists are capped; messages are state-log safe ---"
D=$(new_init INIT-long)
notes=""
for i in $(seq 1 30); do notes="${notes}${i}. Role: admin. Test data: file ${i} | with pipe. Source: generate.
"; done
write_spec "$D" "f-many" "$notes"
out=$(planner_crosscheck_testdata INIT-long)
assert_contains "long: cap note" "$out" "… and 5 more"
assert_contains "long: all needs counted" "$out" "30 test-data need(s)"
case "$out" in *"|"*) fail "long: no pipe in finding" "$out" ;; *) pass "long: no pipe in finding" ;; esac

# ── Legacy grandfathering (#503 review item 4) ──────────────────────────────

echo "--- legacy initiative: Source-less spec warns, Source-bearing spec blocks ---"
D=$(new_init INIT-legacy legacy)
write_spec "$D" "g-old" "1. Role: admin. Test data: 5 seeded invoices.
2. Role: admin. Test data: a 60MB file."
out=$(planner_crosscheck_testdata INIT-legacy)
rc=$?
[ "$rc" -eq 0 ] && pass "legacy: Source-less spec does not block" || fail "legacy: no block" "rc=$rc $out"
assert_contains "legacy: warn code" "$out" "TEST_DATA_UNSOURCED_LEGACY 2 test-data need(s)"
assert_not_contains "legacy: no blocking code" "$out" "TEST_DATA_UNOWNED"
write_spec "$D" "g-new" "1. Role: admin. Test data: a file. Source: generate."
out=$(planner_crosscheck_testdata INIT-legacy)
rc=$?
[ "$rc" -eq 1 ] && pass "legacy: a spec with a Source field blocks" || fail "legacy: Source spec blocks" "rc=$rc"
assert_contains "legacy: blocking names the new spec" "$out" "TEST_DATA_UNOWNED 1 test-data need(s) across 1 spec(s) [g-new]"
assert_contains "legacy: old spec still only warns" "$out" "TEST_DATA_UNSOURCED_LEGACY 2"

echo "--- contract marker: written by planner_state_init ---"
planner_testdata_contract_initiative INIT-owned && pass "marker: new initiative carries it" || fail "marker present" "missing"
planner_testdata_contract_initiative INIT-legacy && fail "marker absent on legacy" "present" || pass "marker: legacy initiative lacks it"

# ── No-tests rule (#503 point 4) ────────────────────────────────────────────

echo "--- self-seeded: owned normally, unowned under the persisted rule ---"
D=$(new_init INIT-self)
write_spec "$D" "h-one" "1. Role: admin. Test data: x. Source: seeded-by:h-one." "## Test Data Provided

- its own seed"
out=$(planner_crosscheck_testdata INIT-self)
[ -z "$out" ] && pass "self: owned while the rule is unset" || fail "self: owned without the rule" "$out"

out=$(PLANNER_NO_TESTS_RULE=true planner_crosscheck_testdata INIT-self)
[ -z "$out" ] && pass "self: the environment is never read at check time" || fail "self: env ignored" "$out"

planner_testdata_no_tests_rule_persist INIT-self true
out=$(planner_crosscheck_testdata INIT-self)
assert_contains "self: persisted flag flags it" "$out" "h-one.md#1 (self-seeded"
assert_contains "self: remedy mandatory" "$out" "MANDATORY"
assert_contains "self: names the rule source" "$out" "operator flag --no-tests-rule=true"
planner_testdata_no_tests_rule_persist INIT-self false
out=$(planner_crosscheck_testdata INIT-self)
[ -z "$out" ] && pass "self: --no-tests-rule=false overwrites" || fail "self: false overwrites" "$out"

echo "--- detection: once, recorded with its source, never re-detected ---"
mkdir -p "${REPOS_ROOT}/svc-a"
echo "Implementation must not write unit tests." >"${REPOS_ROOT}/svc-a/CLAUDE.md"
D=$(new_init INIT-detect)
planner_testdata_no_tests_rule_persist INIT-detect
src=$(planner_testdata_no_tests_rule INIT-detect) && pass "detect: rule on" || fail "detect: rule on" "off"
assert_contains "detect: source names the file and line" "$src" "svc-a/CLAUDE.md:1:"
rm -f "${REPOS_ROOT}/svc-a/CLAUDE.md"
planner_testdata_no_tests_rule_persist INIT-detect
planner_testdata_no_tests_rule INIT-detect >/dev/null && pass "detect: not re-detected after CLAUDE.md changes" || fail "detect: sticky" "flipped off"

D=$(new_init INIT-nodetect)
planner_testdata_no_tests_rule_persist INIT-nodetect
[ "$(planner_config_get INIT-nodetect no-tests-rule)" = "false" ] && pass "detect: no rule records false" || fail "detect: records false" "$(planner_config_get INIT-nodetect no-tests-rule)"

echo "--- detection is narrow: unscoped rules only ---"
for phrase in "Implementation does not write tests." "Never add tests" "Agents don't write any automated tests." "You must not create test fixtures; QA does." \
  "Do not write or add tests when implementing tickets." "Do not write tests when implementing tickets." \
  "Implementation agents must not write tests: QA owns them." "Never write tests, QA owns them."; do
  echo "$phrase" >"${REPOS_ROOT}/CLAUDE.md"
  planner_testdata_no_tests_rule_scan >/dev/null && pass "rule on: $phrase" || fail "rule on: $phrase" "not detected"
done
for phrase in "Always write tests for new code." "Run the tests before committing." "Do not write to production." \
  "Do not write tests for generated code." "Don't write tests that hit the network." "Never add tests to the vendored folder."; do
  echo "$phrase" >"${REPOS_ROOT}/CLAUDE.md"
  planner_testdata_no_tests_rule_scan >/dev/null && fail "rule off: $phrase" "false positive" || pass "rule off: $phrase"
done
rm -f "${REPOS_ROOT}/CLAUDE.md"

# ── Cited artifacts (#504) ──────────────────────────────────────────────────

new_init INIT-cited >/dev/null
ART="${REPOS_ROOT}/.ticket-auto/initiatives/INIT-cited/artifacts"
cat >"${ART}/discovery.md" <<'EOF'
# Discovery

## Cited Artifacts

- `client sample file (43 rows)` — NOT FOUND (searched: attachments, artifacts/, REPOS_ROOT)
- `export template` — FOUND: docs/NOT FOUND list.xlsx
2. legacy mapping sheet – not found (searched: REPOS_ROOT)
3) **`rate card`** - Found: wiki

## Constraints

- `not an artifact` — NOT FOUND in this section, must be ignored
EOF

echo "--- parsing: status token, numbered items, bare names, other sections ignored ---"
out=$(planner_cited_artifacts_missing INIT-cited)
assert_contains "missing: backticked" "$out" "client sample file (43 rows)"
assert_contains "missing: bare name, en dash, lower case" "$out" "legacy mapping sheet"
assert_not_contains "missing: NOT FOUND inside a FOUND location" "$out" "export template"
assert_not_contains "missing: bold-wrapped FOUND" "$out" "rate card"
assert_not_contains "missing: other sections ignored" "$out" "not an artifact"

echo "--- question lines are canonical ---"
out=$(planner_cited_artifacts_questions INIT-cited)
assert_contains "questions: canonical line" "$out" '- CITED_ARTIFACT: `client sample file (43 rows)` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING'
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT)" -eq 2 ] && pass "questions: one per missing artifact" || fail "questions: count" "$out"

echo "--- no consensus.md: both unraised ---"
out=$(planner_crosscheck_cited_artifacts INIT-cited)
rc=$?
[ "$rc" -eq 1 ] && pass "unraised: returns 1" || fail "unraised: returns 1" "rc=$rc"
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT_UNRAISED)" -eq 2 ] && pass "unraised: two findings" || fail "unraised: two findings" "$out"

echo "--- pasted questions left PENDING: unresolved ---"
{
  echo "## Open Questions"
  echo ""
  planner_cited_artifacts_questions INIT-cited
} >"${ART}/consensus.md"
out=$(planner_crosscheck_cited_artifacts INIT-cited)
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT_UNRESOLVED)" -eq 2 ] && pass "pending: two unresolved" || fail "pending: two unresolved" "$out"
assert_contains "pending: quotes the answer" "$out" "Answer: PENDING"

echo "--- source mismatch: pending artifacts stay generate ---"
SP="${ART}/specs"
write_spec "$SP" "m-one" "1. Role: admin. Test data: the \`client sample file (43 rows)\`. Source: external:client finance team.
2. Role: admin. Test data: the \`legacy mapping sheet\`. Source: generate."
out=$(planner_crosscheck_cited_artifacts INIT-cited)
assert_contains "mismatch: invented external while pending" "$out" "CITED_ARTIFACT_SOURCE_MISMATCH m-one.md#1"
assert_not_contains "mismatch: generate while pending is right" "$out" "m-one.md#2"
out=$(planner_crosscheck_testdata INIT-cited)
assert_not_contains "testdata: pending-artifact generate left to UNRESOLVED" "$out" "m-one.md#2"

echo "--- answered (case-insensitive, emphasis): clean when specs agree ---"
cat >"${ART}/consensus.md" <<'EOF'
## Open Questions

- CITED_ARTIFACT: `Client Sample File (43 rows)` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: **external:Client Finance Team**
- CITED_ARTIFACT: `legacy mapping sheet` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: `generate`.
EOF
out=$(planner_crosscheck_cited_artifacts INIT-cited)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "answered: clean" || fail "answered: clean" "rc=$rc out=$out"
out=$(planner_crosscheck_testdata INIT-cited)
assert_contains "testdata: answered generate now needs an owner" "$out" "m-one.md#2 (generate)"

echo "--- answered generate, spec still external: mismatch (review repro) ---"
sed -i 's/Answer: \*\*external:Client Finance Team\*\*/Answer: generate/' "${ART}/consensus.md"
out=$(planner_crosscheck_cited_artifacts INIT-cited)
assert_contains "repro: mismatch reported" "$out" "CITED_ARTIFACT_SOURCE_MISMATCH m-one.md#1"
assert_contains "repro: names the expected source" "$out" "generate or seeded-by:<pack>"

echo "--- malformed answers stay unresolved ---"
sed -i 's/Answer: generate$/Answer: external:/; s/Answer: `generate`\./Answer: generate it please/' "${ART}/consensus.md"
out=$(planner_crosscheck_cited_artifacts INIT-cited)
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT_UNRESOLVED)" -eq 2 ] && pass "malformed answer: both unresolved" || fail "malformed: both unresolved" "$out"

echo "--- malformed Cited Artifacts items are findings, not skips ---"
new_init INIT-malformed >/dev/null
ART2="${REPOS_ROOT}/.ticket-auto/initiatives/INIT-malformed/artifacts"
printf '## Cited Artifacts\n\n- `vendor rate card` — lost somewhere\n- just some words\n- None.\n- None — no external artifacts are cited.\n- No other files cited.\n' >"${ART2}/discovery.md"
out=$(planner_crosscheck_cited_artifacts INIT-malformed)
rc=$?
[ "$rc" -eq 1 ] && pass "malformed: blocks" || fail "malformed: blocks" "rc=$rc"
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT_MALFORMED)" -eq 2 ] && pass "malformed: two findings; None. and none-statements skipped" || fail "malformed: count" "$out"

echo "--- a backticked item is never a none-statement ---"
new_init INIT-nonebt >/dev/null
ART3="${REPOS_ROOT}/.ticket-auto/initiatives/INIT-nonebt/artifacts"
printf '## Cited Artifacts\n\n- No files: `w` NOT FOUND\n- No external files besides `y` which was NOT FOUND\n' >"${ART3}/discovery.md"
out=$(planner_crosscheck_cited_artifacts INIT-nonebt)
[ "$(printf '%s\n' "$out" | grep -c CITED_ARTIFACT_MALFORMED)" -eq 2 ] && pass "none-statement: backticked items reported, not skipped" || fail "none-statement: backticked items" "$out"

echo "--- UNREFERENCED: a none need does not reference; names are normalised ---"
new_init INIT-unref >/dev/null
ART4="${REPOS_ROOT}/.ticket-auto/initiatives/INIT-unref/artifacts"
printf '## Cited Artifacts\n\n- `x file` — NOT FOUND (searched: REPOS_ROOT)\n- `client  sample – v2` — NOT FOUND (searched: REPOS_ROOT)\n- `rate card` — NOT FOUND (searched: REPOS_ROOT)\n' >"${ART4}/discovery.md"
{
  echo "## Open Questions"
  echo
  planner_cited_artifacts_questions INIT-unref
} >"${ART4}/consensus.md"
write_spec "${ART4}/specs" "u-one" "1. Role: admin. Test data: none (\`x file\` handled elsewhere).
2. Role: admin. Test data: the x file. Source: external:someone.
3. Role: admin. Test data: the \`Client sample - v2\`. Source: generate.
4. Role: admin. Test data: the \`rate card.\`. Source: generate."
out=$(planner_crosscheck_cited_artifacts INIT-unref)
assert_contains "unref: none need does not count as a reference" "$out" 'CITED_ARTIFACT_UNREFERENCED no spec Verification Notes need cites `x file`'
assert_not_contains "unref: double space and en dash normalised" "$out" 'cites `client  sample – v2`'
assert_not_contains "unref: trailing dot inside backticks normalised" "$out" 'cites `rate card`'
assert_not_contains "unref: normalised names still find their answers" "$out" "CITED_ARTIFACT_UNRAISED"

echo "--- missing section: warn on contract initiatives, silent on legacy ---"
printf '# Discovery\n\n## Code Paths\n\nnone\n' >"${ART2}/discovery.md"
out=$(planner_crosscheck_cited_artifacts INIT-malformed)
rc=$?
[ "$rc" -eq 0 ] && pass "section missing: not blocking" || fail "section missing: not blocking" "rc=$rc"
assert_contains "section missing: warn" "$out" "CITED_ARTIFACTS_SECTION_MISSING"
new_init INIT-legacy2 legacy >/dev/null
printf '# Discovery\n\n## Code Paths\n\nnone\n' >"${REPOS_ROOT}/.ticket-auto/initiatives/INIT-legacy2/artifacts/discovery.md"
out=$(planner_crosscheck_cited_artifacts INIT-legacy2)
[ -z "$out" ] && pass "section missing: legacy silent" || fail "section missing: legacy silent" "$out"

# ── Orchestrator wiring ─────────────────────────────────────────────────────

echo "--- Crosscheck wiring: block/warn split, cross-file grouping, hints ---"
source "${LIB_DIR}/planner-crosscheck.sh"
for code in TEST_DATA_UNOWNED CITED_ARTIFACT_UNRAISED CITED_ARTIFACT_UNRESOLVED CITED_ARTIFACT_SOURCE_MISMATCH CITED_ARTIFACT_MALFORMED; do
  _planner_crosscheck_is_warn_code "$code" && fail "$code blocking" "listed as warn" || pass "$code is blocking"
done
for code in TEST_DATA_UNSOURCED_LEGACY CITED_ARTIFACTS_SECTION_MISSING; do
  _planner_crosscheck_is_warn_code "$code" && pass "$code is warn" || fail "$code warn" "not a warn code"
done
for code in TEST_DATA_UNOWNED TEST_DATA_UNSOURCED_LEGACY CITED_ARTIFACT_UNRAISED CITED_ARTIFACT_UNRESOLVED CITED_ARTIFACT_SOURCE_MISMATCH CITED_ARTIFACT_MALFORMED CITED_ARTIFACTS_SECTION_MISSING; do
  hint=$(planner_crosscheck_fix_hint "$code")
  assert_not_contains "$code has a fix hint" "$hint" "no canned hint"
done
assert_contains "TEST_DATA_UNOWNED groups cross-file" " ${PLANNER_CROSSCHECK_CROSS_FILE_CODES} " " TEST_DATA_UNOWNED "
run_body=$(declare -f planner_crosscheck_run)
assert_contains "run calls testdata check" "$run_body" "planner_crosscheck_testdata"
assert_contains "run calls cited-artifacts check" "$run_body" "planner_crosscheck_cited_artifacts"

echo "--- stop-describe lists every unresolved artifact (#504 headless) ---"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-stop-describe.sh"
SDI="INIT-describe"
new_init "$SDI" >/dev/null
SDA="${REPOS_ROOT}/.ticket-auto/initiatives/${SDI}/artifacts"
printf '## Cited Artifacts\n\n- `alpha file` — NOT FOUND (searched: x)\n- `beta file` — NOT FOUND (searched: x)\n' >"${SDA}/discovery.md"
for ph in Appraisal Discovery Architecture Specify Review Consensus; do
  planner_state_write "$SDI" "$ph" "x" "start" "s" >/dev/null 2>&1
  planner_state_write "$SDI" "$ph" "x" "done" "d" >/dev/null 2>&1
done
planner_crosscheck_run "$SDI" >/dev/null 2>&1
model=$(planner_stop_describe_json "$SDI" 2>/dev/null)
qtext=$(printf '%s' "$model" | jq -r '.questions[] | select(.id == "accept-CITED_ARTIFACT_UNRAISED") | .text' 2>/dev/null)
assert_contains "describe: first artifact named" "$qtext" '`alpha file`'
assert_contains "describe: second artifact named" "$qtext" '`beta file`'
assert_contains "describe: says how to answer" "$qtext" "Answer: exists:<where>, external:<who> or generate"

# ── Phase prompts ───────────────────────────────────────────────────────────

echo "--- phase prompts carry the contract ---"
source "${LIB_DIR}/planner-phase-prompts.sh"
SD="${TMPDIR}/state"
p_spec=$(planner_prompt_specify "INIT-1" "an idea" "$SD")
assert_contains "Specify: Source field" "$p_spec" "Source: seeded-by:"
assert_contains "Specify: closed enum" "$p_spec" "Source: exists:<where> | seeded-by:<spec-slug> | external:<who> | generate"
assert_contains "Specify: Test Data Provided" "$p_spec" "## Test Data Provided"
assert_contains "Specify: rule read from config" "$p_spec" 'planner_testdata_no_tests_rule "INIT-1"'
assert_not_contains "Specify: no env read" "$p_spec" "PLANNER_NO_TESTS_RULE"
assert_contains "Specify: NOT FOUND artifacts stay generate" "$p_spec" "write \`Source: generate\` — never \`exists:\` or \`external:\`"
assert_contains "Specify: contract doc" "$p_spec" "docs/test-data-source.md"

p_disc=$(planner_prompt_discovery "INIT-1" "an idea" "$SD")
assert_contains "Discovery: Cited Artifacts section required" "$p_disc" "discovery.md must have a \`## Cited Artifacts\` section"
assert_contains "Discovery: NOT FOUND shape" "$p_disc" "— NOT FOUND (searched:"
assert_contains "Discovery: FOUND shape" "$p_disc" "— FOUND:"

p_cons=$(planner_prompt_consensus "INIT-1" "an idea" "$SD")
assert_contains "Consensus: Open Questions section" "$p_cons" "**Open Questions**"
assert_contains "Consensus: question assembly in bash" "$p_cons" "planner_cited_artifacts_questions \"INIT-1\""
assert_contains "Consensus: specs stay generate until answered" "$p_cons" "stays \`Source: generate\`"
assert_not_contains "Consensus: no pre-fill instruction" "$p_cons" "says \`Source: external:<who>\`"

p_tg=$(planner_prompt_ticketgen "INIT-1" "an idea" "$SD" 2>/dev/null)
assert_contains "TicketGen: Test Data Prerequisites carry Source" "$p_tg" "Source: <kind>[:<value>]"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
