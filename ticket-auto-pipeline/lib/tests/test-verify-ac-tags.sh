#!/usr/bin/env bash
# test-verify-ac-tags.sh — ticket-verify's `[unit]` / `[live]` criterion tags
# (GitHub #773, lib/verify-ac-tags.sh, flag VERIFY_AC_TAGS).
#
#   - flag off: the gate is off whatever the body says, and SKILL.md carries
#     exactly one guarded line about the tags;
#   - the criteria list reuses the dor-body-v2 reader; untagged means live;
#   - the test command is learned from configuration only;
#   - a named test passes only on this run's own evidence; a missing test,
#     a missing command, a failed or skipped test and a stale report all fail.
# Usage: bash test-verify-ac-tags.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
HELPER="$LIB_DIR/verify-ac-tags.sh"
SKILL_MD="$PLUGIN_DIR/skills/ticket-verify/SKILL.md"
REF_MD="$PLUGIN_DIR/skills/ticket-verify/references/ac-tags.md"

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}
assert_eq() {
  if [ "$2" = "$3" ]; then
    _pass "$1"
  else
    _fail "$1 (got '$2', want '$3')"
  fi
}
assert_has() {
  if grep -qF -- "$3" <<<"$2"; then
    _pass "$1"
  else
    _fail "$1 (no '$3' in: $2)"
  fi
}

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Nothing from the host leaks in: no flag, no test fields, no ticket env file.
unset VERIFY_AC_TAGS VERIFY_AC_TAGS_TIMEOUT BE_SERVICES BE_TEST_CMD BE_TEST_RUNNER FE_TEST_CMD
unset FLEET_PIPELINE_LOG_DIR LOG_FILE TAP_LOG
export TICKET_TMP_DIR="$TMP_ROOT/scratch"
export REPOS_ROOT="$TMP_ROOT/repos"
mkdir -p "$REPOS_ROOT"

TID="TICKET-A"
TD="$TMP_ROOT/tickets/$TID--sample"
mkdir -p "$TD/artifacts"
cat >"$TD/context.md" <<'BODY'
# TICKET-A: Sample

---

## Description

## Summary
Save an invoice.

## Acceptance Criteria

- [ ] [live] The form shows the saved invoice number.
- [ ] [unit] A total below zero is rejected.
- [ ] An untagged criterion.
- [ ] [unit] An empty total is rejected.

## Verify Mode

**Verify mode:** browser
BODY
cat >"$TD/legacy.md" <<'BODY'
## Acceptance Criteria

- [ ] The form shows the saved invoice number.
- [ ] A total below zero is rejected.
BODY

_gate() { bash "$HELPER" gate "$@" | tr '\n' ' ' | sed 's/ $//'; }

# ── Flag off: no change ──────────────────────────────────────────────────

assert_eq "gate: flag unset is off" "$(_gate "$TD")" "AC_TAGS=off AC_TAGS_REASON=flag-off"
assert_eq "gate: flag false is off" "$(VERIFY_AC_TAGS=false _gate "$TD")" "AC_TAGS=off AC_TAGS_REASON=flag-off"
assert_eq "gate: only the exact value true turns it on" "$(VERIFY_AC_TAGS=1 _gate "$TD")" "AC_TAGS=off AC_TAGS_REASON=flag-off"
assert_eq "gate: flag off never reads the body" "$(_gate "$TMP_ROOT/absent")" "AC_TAGS=off AC_TAGS_REASON=flag-off"

n=$(grep -c 'ac-tags' "$SKILL_MD" || true)
assert_eq "SKILL.md: one line names the tags reference" "$n" "1"
line=$(grep -F 'references/ac-tags.md' "$SKILL_MD")
assert_has "SKILL.md: the line is guarded by the gate" "$line" 'verify-ac-tags.sh gate'
assert_has "SKILL.md: the guard is the gate printing on" "$line" '**If it prints `AC_TAGS=on`**'
assert_has "SKILL.md: read through the resolver" "$line" 'bash ~/.claude/skills/lib/skill-ref.sh ticket-verify references/ac-tags.md'
assert_has "SKILL.md: read in full" "$line" 'Read the printed path in full'
assert_has "SKILL.md: hard stop when the resolver fails" "$line" 'META reference-missing fail "references/ac-tags.md"'
assert_has "SKILL.md: off means live proof" "$line" 'Otherwise skip it: every criterion is proved live.'
n=$(grep -c 'VERIFY_AC_TAGS\|\[unit\]' "$SKILL_MD" || true)
assert_eq "SKILL.md: no tag rule outside the reference" "$n" "0"
order=$(awk '{ c = index($0, "**If it prints"); p = index($0, "references/ac-tags.md"); r = index($0, "Read the printed path"); s = index($0, "exits non-zero"); if (p) print (c > 0 && c < p && p < r && r < s) ? "ok" : "bad" }' "$SKILL_MD")
assert_eq "SKILL.md: condition, path, read, stop in that order" "$order" "ok"

# ── Flag on: gate ────────────────────────────────────────────────────────

export VERIFY_AC_TAGS=true
assert_eq "gate: on with unit criteria" "$(_gate "$TD")" "AC_TAGS=on AC_TAGS_REASON=unit:2"
assert_eq "gate: uat is off" "$(_gate "$TD" --env uat)" "AC_TAGS=off AC_TAGS_REASON=uat"
assert_eq "gate: a body with no unit criterion is off" "$(_gate "$TD" --body "$TD/legacy.md")" "AC_TAGS=off AC_TAGS_REASON=no-unit"
assert_eq "gate: no body is off" "$(_gate "$TMP_ROOT/absent")" "AC_TAGS=off AC_TAGS_REASON=no-body"
rc=0
bash "$HELPER" gate "$TMP_ROOT/absent" >/dev/null || rc=$?
assert_eq "gate: always exit 0" "$rc" "0"

# ── list ─────────────────────────────────────────────────────────────────

want=$'1\tlive\tThe form shows the saved invoice number.\n2\tunit\tA total below zero is rejected.\n3\tlive\tAn untagged criterion.\n4\tunit\tAn empty total is rejected.'
assert_eq "list: tags read, untagged is live" "$(bash "$HELPER" list "$TD")" "$want"
want=$'1\tlive\tThe form shows the saved invoice number.\n2\tlive\tA total below zero is rejected.'
assert_eq "list: a legacy body is all live" "$(bash "$HELPER" list "$TD" --body "$TD/legacy.md")" "$want"
# The list is the dor-body-v2 reader's, not a second parser.
source "$LIB_DIR/dor-body-v2.sh"
assert_eq "list: same criteria as _dor_v2_ac_items" \
  "$(bash "$HELPER" list "$TD" | wc -l | tr -d ' ')" \
  "$(_dor_v2_ac_items "$(cat "$TD/context.md")" | wc -l | tr -d ' ')"
n=$(grep -c '_dor_v2_ac_items' "$HELPER" || true)
[ "$n" -ge 2 ] && _pass "helper calls _dor_v2_ac_items" || _fail "helper does not call _dor_v2_ac_items"
rc=0
bash "$HELPER" list "$TMP_ROOT/absent" >/dev/null 2>&1 || rc=$?
assert_eq "list: no body is exit 1" "$rc" "1"

# ── test-cmd ─────────────────────────────────────────────────────────────

MD="$TMP_ROOT/CLAUDE.md"
_cmd() { bash "$HELPER" test-cmd "$TID" --repo "$1" --claude-md "$MD" | tr '\n' ' ' | sed 's/ $//'; }
_cmd_rc() {
  local rc=0
  bash "$HELPER" test-cmd "$TID" --repo "$1" --claude-md "$MD" >/dev/null || rc=$?
  echo "$rc"
}

: >"$MD"
assert_has "test-cmd: nothing configured is none" "$(_cmd api || true)" "TEST_CMD_NONE=no BE_TEST_RUNNER, BE_TEST_CMD or FE_TEST_CMD"
assert_eq "test-cmd: none is exit 1" "$(_cmd_rc api)" "1"

printf '%s\n' 'BE_SERVICES = `api, worker`' 'BE_TEST_CMD = `make test`' 'FE_TEST_CMD = `npm test`' >"$MD"
assert_eq "test-cmd: backend repo uses BE_TEST_CMD" "$(_cmd api)" "TEST_CMD_SOURCE=BE_TEST_CMD TEST_CMD=make test"
assert_eq "test-cmd: other repo uses FE_TEST_CMD" "$(_cmd web)" "TEST_CMD_SOURCE=FE_TEST_CMD TEST_CMD=npm test"
printf '%s\n' 'BE_TEST_RUNNER = `/opt/py/bin/pytest`' >>"$MD"
assert_eq "test-cmd: BE_TEST_RUNNER wins over BE_TEST_CMD" "$(_cmd worker)" "TEST_CMD_SOURCE=BE_TEST_RUNNER TEST_CMD=/opt/py/bin/pytest"
assert_eq "test-cmd: the environment wins over CLAUDE.md" "$(BE_TEST_RUNNER='env-runner' _cmd api)" "TEST_CMD_SOURCE=BE_TEST_RUNNER TEST_CMD=env-runner"

printf '%s\n' 'BE_SERVICES = `api`' 'BE_TEST_CMD = `make test`' >"$MD"
assert_has "test-cmd: other repo with no FE_TEST_CMD is none" "$(_cmd web || true)" "TEST_CMD_NONE=not a BE_SERVICES repo, no FE_TEST_CMD"
printf '%s\n' 'BE_SERVICES = `api`' 'FE_TEST_CMD = `npm test`' >"$MD"
assert_has "test-cmd: backend repo with no backend command is none" "$(_cmd api || true)" "TEST_CMD_NONE=backend repo"

printf '%s\n' 'BE_TEST_CMD = `make test`' >"$MD"
assert_eq "test-cmd: no BE_SERVICES, one side set" "$(_cmd anything)" "TEST_CMD_SOURCE=BE_TEST_CMD TEST_CMD=make test"
printf '%s\n' 'FE_TEST_CMD = `npm test`' >"$MD"
assert_eq "test-cmd: no BE_SERVICES, only the front-end side" "$(_cmd anything)" "TEST_CMD_SOURCE=FE_TEST_CMD TEST_CMD=npm test"
printf '%s\n' 'BE_TEST_CMD = `make test`' 'FE_TEST_CMD = `npm test`' >"$MD"
assert_has "test-cmd: no BE_SERVICES and both sides set is none, not a guess" "$(_cmd anything || true)" "TEST_CMD_NONE=BE_SERVICES is empty and both"
assert_eq "test-cmd: ambiguous is exit 1" "$(_cmd_rc anything)" "1"

# ── run ──────────────────────────────────────────────────────────────────

REPO="$REPOS_ROOT/api"
WT="$REPOS_ROOT/.verify-worktrees/api/$TID"
mkdir -p "$REPO" "$WT"
OUT="$TD/artifacts"

# A fake test command: writes whatever report the case stages, prints its
# output, exits with its code.
cat >"$TMP_ROOT/fake-test.sh" <<'SH'
#!/usr/bin/env bash
[ -f "$FAKE_REPORT" ] && mkdir -p reports && cp "$FAKE_REPORT" reports/TEST-result.xml
[ -f "$FAKE_OUTPUT" ] && cat "$FAKE_OUTPUT"
pwd >"$FAKE_CWD"
exit "${FAKE_RC:-0}"
SH
chmod +x "$TMP_ROOT/fake-test.sh"
export FAKE_REPORT="$TMP_ROOT/report.xml" FAKE_OUTPUT="$TMP_ROOT/output.txt" FAKE_CWD="$TMP_ROOT/cwd.txt"
printf '%s\n' 'BE_SERVICES = `api`' "BE_TEST_CMD = \`bash $TMP_ROOT/fake-test.sh\`" >"$MD"

RUN_RC=0
_run() {
  RUN_RC=0
  RUN_OUT=$(bash "$HELPER" run "$TID" --repo-path "$REPO" --branch feat/sample --out "$OUT" --claude-md "$MD" "$@" 2>&1) || RUN_RC=$?
}
_result() { awk -F'\t' -v n="$1" '$1 == "UNIT_TEST" && $2 == n { print $3 ": " $4 }' <<<"$RUN_OUT"; }

cat >"$FAKE_REPORT" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="com.example.InvoiceServiceTest" tests="4">
  <testcase name="rejectsNegativeTotal" classname="com.example.InvoiceServiceTest" time="0.01"/>
  <testcase name="rejectsEmptyTotal(String)[1]" classname="com.example.InvoiceServiceTest" time="0.01"/>
  <testcase name="savesInvoice" classname="com.example.InvoiceServiceTest" time="0.01">
    <failure message="expected 1 but was 0">trace</failure>
  </testcase>
  <testcase name="roundsTotal" classname="com.example.InvoiceServiceTest" time="0">
    <skipped/>
  </testcase>
  <testcase name="test_rejects_empty_total" classname="tests.test_invoice" time="0.01"/>
</testsuite>
XML
: >"$FAKE_OUTPUT"

_run --test rejectsNegativeTotal --test InvoiceServiceTest.rejectsEmptyTotal --test 'tests/test_invoice.py::test_rejects_empty_total'
assert_eq "run: all named tests passed is exit 0" "$RUN_RC" "0"
assert_eq "run: method name passes on the report" "$(_result rejectsNegativeTotal)" "pass: junit: 1 passed"
assert_eq "run: Class.method with a parameter suffix passes" "$(_result InvoiceServiceTest.rejectsEmptyTotal)" "pass: junit: 1 passed"
assert_eq "run: file::function passes" "$(_result 'tests/test_invoice.py::test_rejects_empty_total')" "pass: junit: 1 passed"
assert_has "run: reports what ran" "$RUN_OUT" $'UNIT_RUN\tstatus=ran\trc=0\tsource=BE_TEST_CMD\tdir='"$WT"
assert_eq "run: the command ran in the verify worktree" "$(cat "$FAKE_CWD")" "$WT"
[ -f "$OUT/verify-unit-api.log" ] && _pass "run: the log is kept in artifacts" || _fail "run: no log in artifacts"

_run --test savesInvoice --test roundsTotal --test neverWritten --test rejectsNegativeTotal
assert_eq "run: any named test not passed is exit 1" "$RUN_RC" "1"
assert_eq "run: a failed test fails" "$(_result savesInvoice)" "fail: test failed in this run"
assert_eq "run: a skipped test fails" "$(_result roundsTotal)" "fail: test was skipped in this run"
assert_eq "run: a test that is in no report fails" "$(_result neverWritten)" "fail: not in this run's test reports"
assert_eq "run: the passing one still passes beside them" "$(_result rejectsNegativeTotal)" "pass: junit: 1 passed"

# A class name passes only when none of its tests failed.
_run --test InvoiceServiceTest
assert_eq "run: a class with a failed test fails" "$(_result InvoiceServiceTest)" "fail: test failed in this run"

# A report from before this run proves nothing: the implementer's own run
# may have left it. The command writes none this time and names no test.
rm -f "$FAKE_REPORT"
touch -d '2001-01-01' "$WT/reports/TEST-result.xml"
: >"$FAKE_OUTPUT"
_run --test rejectsNegativeTotal
assert_eq "run: a stale report is not evidence" "$(_result rejectsNegativeTotal)" "fail: no test report and the name is not in the output"
assert_has "run: a stale report is not counted" "$RUN_OUT" "reports=0"
rm -rf "$WT/reports"

# No report at all: the run's own output decides.
printf '%s\n' 'PASS  src/invoice.test.js' '  ok rejects a negative total (3 ms)' '  skipped rounds the total' '  ok handles error codes' >"$FAKE_OUTPUT"
_run --test 'rejects a negative total' --test 'rounds the total' --test 'handles error codes' --test 'never written'
assert_eq "run: named on a passing output line passes" "$(_result 'rejects a negative total')" "pass: output: named in a passing run"
assert_eq "run: named on a skip line fails" "$(_result 'rounds the total')" "fail: output line reports a skip or failure"
assert_eq "run: a failure word inside the name itself is not a failure" "$(_result 'handles error codes')" "pass: output: named in a passing run"
assert_eq "run: not in the output fails" "$(_result 'never written')" "fail: no test report and the name is not in the output"

FAKE_RC=3 _run --test 'rejects a negative total'
assert_eq "run: a non-zero exit with no report fails every name" "$(_result 'rejects a negative total')" "fail: no test report and the command exited 3"
assert_eq "run: and is exit 1" "$RUN_RC" "1"

# The implementer's word is not evidence: notes that claim the test passed
# change nothing when this run does not show it.
printf '%s\n' '- Tests: neverWritten passed locally' >"$TD/notes.md"
: >"$FAKE_OUTPUT"
_run --test neverWritten
assert_eq "run: a claim in notes.md proves nothing" "$(_result neverWritten)" "fail: no test report and the name is not in the output"

# No test command: every named test fails, nothing runs.
rm -f "$FAKE_CWD"
: >"$MD"
_run --test rejectsNegativeTotal
assert_eq "run: no test command is exit 1" "$RUN_RC" "1"
assert_has "run: no test command is reported" "$RUN_OUT" $'UNIT_RUN\tstatus=no-command'
assert_has "run: no test command fails the test" "$(_result rejectsNegativeTotal)" "fail: no test command:"
[ ! -e "$FAKE_CWD" ] && _pass "run: nothing ran without a command" || _fail "run: something ran without a command"

# No worktree and no branch to make one from: fails, nothing runs.
printf '%s\n' "BE_TEST_CMD = \`bash $TMP_ROOT/fake-test.sh\`" >"$MD"
mkdir -p "$REPOS_ROOT/other"
RUN_RC=0
RUN_OUT=$(bash "$HELPER" run "$TID" --repo-path "$REPOS_ROOT/other" --branch feat/sample --out "$OUT" --claude-md "$MD" --test rejectsNegativeTotal 2>&1) || RUN_RC=$?
assert_has "run: no worktree is reported" "$RUN_OUT" $'UNIT_RUN\tstatus=no-worktree'
assert_eq "run: no worktree fails the test" "$(_result rejectsNegativeTotal)" "fail: no verify worktree for other"
[ ! -e "$FAKE_CWD" ] && _pass "run: nothing ran without a worktree" || _fail "run: something ran without a worktree"

# A missing worktree is created at the pushed branch tip (build-only mode).
GREPO="$REPOS_ROOT/lib-repo"
git init -q -b main "$GREPO"
git -C "$GREPO" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
git -C "$GREPO" branch feat/sample
printf '%s\n' 'ok rejectsNegativeTotal' >"$FAKE_OUTPUT"
RUN_RC=0
RUN_OUT=$(bash "$HELPER" run "$TID" --repo-path "$GREPO" --branch feat/sample --out "$OUT" --claude-md "$MD" --test rejectsNegativeTotal 2>&1) || RUN_RC=$?
assert_eq "run: creates the verify worktree when there is none" "$(cat "$FAKE_CWD" 2>/dev/null)" "$REPOS_ROOT/.verify-worktrees/lib-repo/$TID"
assert_eq "run: and judges the test from that run" "$(_result rejectsNegativeTotal)" "pass: output: named in a passing run"

# Usage.
for args in "" "--test x" "--repo-path $REPO --branch b --out $OUT"; do
  rc=0
  # shellcheck disable=SC2086
  bash "$HELPER" run "$TID" $args >/dev/null 2>&1 || rc=$?
  assert_eq "run: incomplete arguments are exit 2 ($args)" "$rc" "2"
done
rc=0
bash "$HELPER" run "../x" --repo-path "$REPO" --branch b --out "$OUT" --test x >/dev/null 2>&1 || rc=$?
assert_eq "run: a bad ticket id is exit 2" "$rc" "2"
rc=0
bash "$HELPER" nonsense >/dev/null 2>&1 || rc=$?
assert_eq "unknown command is exit 2" "$rc" "2"

# ── Reference file ───────────────────────────────────────────────────────

[ -f "$REF_MD" ] && _pass "references/ac-tags.md exists" || _fail "references/ac-tags.md missing"
ref=$(cat "$REF_MD" 2>/dev/null || true)
assert_has "reference: a unit criterion that cannot be proved fails" "$ref" 'If a `[unit]` criterion cannot be proved by a named test, it **fails**.'
assert_has "reference: a claim is not proof" "$ref" 'notes.md, the plan, the PR text, an IMPLEMENT log line, a CI result and an earlier verify attempt are not proof'
assert_has "reference: the helper runs the command" "$ref" 'bash ~/.claude/skills/lib/verify-ac-tags.sh run {TICKET-ID}'
assert_has "reference: unit items still count" "$ref" 'It counts in `criteria_met` and `criteria_total`'
assert_has "reference: live and untagged are unchanged" "$ref" 'a criterion with no tag, is proved on the running system exactly as SKILL.md'
# The verify agent holds Bash, Read and Playwright only.
if grep -qE '\b(Grep|Glob|Write|Edit) tool|mcp__gitnexus' <<<"$ref"; then
  _fail "reference asks for a tool the verify agent does not hold"
else
  _pass "reference asks for no tool the verify agent lacks"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
