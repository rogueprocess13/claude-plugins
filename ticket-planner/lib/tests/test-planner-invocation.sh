#!/usr/bin/env bash
# test-planner-invocation.sh — planner-invocation.sh (skill-deterministic-
# extraction 1): flag parsing (SKILL.md step 2a), persistence (step 2b) and
# the intent idea line (step 3).
#
# The expected messages below are the literal `echo` lines the inline SKILL.md
# blocks printed before the extraction — the fixture, not the script's output.
# Every persist assertion writes in one process and reads in another, the
# boundary the dispatch loop puts between phases (#144).
#
# Run: bash ticket-planner/lib/tests/test-planner-invocation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REPOS_ROOT="$TMPDIR/repos"
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

# A fresh process with the step-1 libraries sourced and nothing inherited
# except what a planner run has (the PLANNER_* defaults are passed explicitly).
in_new_process() {
  env -i HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" USER=tester "${@:2}" \
    bash -c '
      source "${LIB_DIR}/planner-state.sh"
      source "${LIB_DIR}/planner-router.sh"
      source "${LIB_DIR}/planner-invocation.sh"
      '"$1"
}

echo "=== planner-invocation tests ==="
echo '{}' >"${TMPDIR}/answers.json"

# ── 1. parse: flags and env defaults ──────────────────────────────────────────

echo "--- 1. planner_flags_parse sets the step-2a variables ---"

got=$(in_new_process 'planner_flags_parse resume INIT-1-2 --create --until Review --team ENG \
  --project=Atlas --milestone M1 --shared-branch --refresh-bodies --no-tests-rule=false \
  --base-branch main --accept "A_B:why: here" --accept=C_D:two --answers "$ANS" --dry-run || echo REJECTED
  echo "${CREATE_FLAG}|${UNTIL_PHASE}|${TEAM_REF}|${PROJECT_REF}|${MILESTONE_REF}|${SHARED_BRANCH_FLAG}|${REFRESH_BODIES_FLAG}|${NO_TESTS_RULE_FLAG}|${BASE_BRANCH_REF}|${ANSWERS_FILE}|${#ACCEPT_FLAGS[@]}|${ACCEPT_FLAGS[0]}"' ANS="${TMPDIR}/answers.json")
if [ "$got" = "true|Review|ENG|Atlas|M1|true|true|false|main|${TMPDIR}/answers.json|2|A_B:why: here" ]; then
  pass "every flag form parses (space and = forms, repeated --accept, reason with ':')"
else
  fail "flag parsing" "got '$got'"
fi

got=$(in_new_process 'planner_flags_parse resume INIT-1-2 --converge --only PRO-1,PRO-2
  echo "${CONVERGE_FLAG}|${CONVERGE_ONLY}|${CONVERGE_BY}"')
if [ "$got" = "true|PRO-1,PRO-2|tester" ]; then
  pass "--converge with no --by defaults the operator to \$USER"
else
  fail "converge default operator" "got '$got'"
fi

got=$(in_new_process 'planner_flags_parse plan
  echo "${UNTIL_PHASE}|${TEAM_REF}|${PROJECT_REF}|${MILESTONE_REF}|${NO_TESTS_RULE_FLAG}|${UAT_POLICY_REF}|${BASE_BRANCH_REF}"' \
  PLANNER_REVIEW_HOLD=true LINEAR_TEAM_ID=T1 LINEAR_PROJECT=P1 LINEAR_PROJECT_MILESTONE=M9 \
  PLANNER_NO_TESTS_RULE=true PLANNER_UAT_POLICY=epic PLANNER_BASE_BRANCH=develop)
if [ "$got" = "Review|T1|P1|M9|true|epic|develop" ]; then
  pass "env vars are the defaults, read once at parsing (PLANNER_REVIEW_HOLD → Review)"
else
  fail "env defaults" "got '$got'"
fi

got=$(in_new_process 'planner_flags_parse plan --until Consensus; echo "$UNTIL_PHASE"' PLANNER_UNTIL=Review PLANNER_REVIEW_HOLD=true)
if [ "$got" = "Consensus" ]; then
  pass "a --until flag overrides PLANNER_UNTIL / PLANNER_REVIEW_HOLD"
else
  fail "--until overrides env" "got '$got'"
fi

# ── 2. parse: every rejection, message for message ────────────────────────────

echo "--- 2. planner_flags_parse rejects bad invocations with the step-2a messages ---"

# expect_reject <label> <expected stderr> <args...>
expect_reject() {
  local label="$1" expected="$2" err rc=0
  shift 2
  err=$(env -i HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" \
    bash -c 'source "${LIB_DIR}/planner-state.sh"; source "${LIB_DIR}/planner-router.sh"
             source "${LIB_DIR}/planner-invocation.sh"; planner_flags_parse "$@"' _ "$@" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -eq 1 ] && [ "$err" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "rc=$rc stderr='$err'"
  fi
}

expect_reject "--shared-branch with --no-shared-branch" \
  "ERROR: --shared-branch and --no-shared-branch are mutually exclusive" \
  resume INIT-1-2 --shared-branch --no-shared-branch
expect_reject "--project with --no-project" \
  "ERROR: --project and --no-project are mutually exclusive" \
  resume INIT-1-2 --project Atlas --no-project
expect_reject "--create on plan" \
  "ERROR: --create is not valid for 'plan'. Plan first, read the artifacts, then:
       /ticket-planner resume <INIT_ID> --create" \
  plan "an idea" --create
expect_reject "--accept on plan" \
  "ERROR: --accept is not valid for 'plan'. Accept a finding only after Crosscheck reports it:
       /ticket-planner resume <INIT_ID> --accept CODE:\"reason\"" \
  plan "an idea" --accept A:b
expect_reject "--refresh-bodies on plan" \
  "ERROR: --refresh-bodies is not valid for 'plan'. It re-evaluates tickets Refinement already held:
       /ticket-planner resume <INIT_ID> --refresh-bodies" \
  plan "an idea" --refresh-bodies
expect_reject "--converge on plan" \
  "ERROR: --converge is not valid for 'plan'. It releases tickets Refinement already held:
       /ticket-planner resume <INIT_ID> --converge --only <TID[,TID...]> [--by <name>]" \
  plan "an idea" --converge --only PRO-1
expect_reject "--converge without --only" \
  "ERROR: --converge requires --only <TID[,TID...]> — there is no epic-wide converge" \
  resume INIT-1-2 --converge
expect_reject "--answers on plan" \
  "ERROR: --answers is not valid for 'plan'. Answer a stopped run's questions on resume:
       /ticket-planner resume <INIT_ID> --answers <file>" \
  plan "an idea" --answers "${TMPDIR}/answers.json"
expect_reject "--answers with a missing file" \
  "ERROR: --answers file not found: ${TMPDIR}/nope.yml" \
  resume INIT-1-2 --answers "${TMPDIR}/nope.yml"
expect_reject "--accept without a colon" \
  "ERROR: --accept requires CODE:\"reason\" (got 'CARVE_SCOPE_LOST')" \
  resume INIT-1-2 --accept CARVE_SCOPE_LOST
expect_reject "--accept with a lower-case code" \
  "ERROR: --accept code 'carve' is not a valid Crosscheck code (expected upper-snake-case, e.g. CARVE_SCOPE_LOST)" \
  resume INIT-1-2 --accept carve:why
expect_reject "--accept with an empty reason" \
  "ERROR: --accept requires a non-empty reason: CODE:\"reason\"" \
  resume INIT-1-2 --accept CARVE_SCOPE_LOST:
expect_reject "--accept PARAM_LITERAL code-wide" \
  "ERROR: --accept PARAM_LITERAL is per literal: --accept PARAM_LITERAL@<slug>:\"<literal>\" (got 'PARAM_LITERAL:all fine')" \
  resume INIT-1-2 --accept "PARAM_LITERAL:all fine"
expect_reject "--accept PARAM_LITERAL with no colon" \
  "ERROR: --accept PARAM_LITERAL is per literal: --accept PARAM_LITERAL@<slug>:\"<literal>\" (got 'PARAM_LITERAL')" \
  resume INIT-1-2 --accept PARAM_LITERAL
expect_reject "--accept PARAM_LITERAL@ with text that is not one literal" \
  "ERROR: --accept PARAM_LITERAL@export-link: 'about half an hour' is not exactly one unit literal, e.g. PARAM_LITERAL@export-link:\"15 minutes\"" \
  resume INIT-1-2 --accept 'PARAM_LITERAL@export-link:"about half an hour"'
expect_reject "--accept PARAM_LITERAL@ with a bad slug" \
  "ERROR: --accept PARAM_LITERAL@<slug>: 'a/b' is not a spec slug (letters, digits, - and _)" \
  resume INIT-1-2 --accept 'PARAM_LITERAL@a/b:15 minutes'
expect_reject "--no-tests-rule with a non-boolean" \
  "ERROR: --no-tests-rule takes true or false, got 'maybe'" \
  resume INIT-1-2 --no-tests-rule=maybe
expect_reject "--base-branch with an invalid name" \
  "ERROR: --base-branch 'bad..name' is not a valid branch name" \
  resume INIT-1-2 --base-branch bad..name
expect_reject "--until with an unknown phase" \
  "ERROR: unknown phase 'Nope' for --until. Valid phases: Appraisal, Discovery, Architecture, Specify, Review, Consensus, Crosscheck, EpicGen, TicketGen, Refinement, Completed" \
  plan "an idea" --until Nope

rc=0
err=$(env -i HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" PLANNER_UAT_POLICY=bogus \
  bash -c 'source "${LIB_DIR}/planner-state.sh"; source "${LIB_DIR}/planner-router.sh"
           source "${LIB_DIR}/planner-invocation.sh"; planner_flags_parse plan x' 2>&1 >/dev/null) || rc=$?
if [ "$rc" -eq 1 ] && [ "$err" = "ERROR: PLANNER_UAT_POLICY takes per-ticket or epic, got 'bogus'" ]; then
  pass "an invalid PLANNER_UAT_POLICY is rejected"
else
  fail "PLANNER_UAT_POLICY rejection" "rc=$rc stderr='$err'"
fi

# ── 3. persist: written in one process, read in the next ──────────────────────

echo "--- 3. planner_flags_persist survives the process boundary ---"

in_new_process 'planner_state_init INIT-P1 "an idea" >/dev/null
  planner_flags_parse resume INIT-P1 --create --team ENG --project Atlas --milestone M1 \
    --no-shared-branch --refresh-bodies --converge --only PRO-1 --by alice --no-tests-rule \
    --base-branch main --accept "CARVE_SCOPE_LOST:rescoped in consensus.md"
  planner_flags_persist INIT-P1' PLANNER_UAT_POLICY=epic >/dev/null

got=$(in_new_process 'for k in linear-team linear-project linear-milestone branch-override uat-policy \
    base-branch refresh-bodies converge stop-after; do printf "%s=%s;" "$k" "$(planner_config_get INIT-P1 "$k")"; done
  planner_create_authorized INIT-P1 && printf "authorized"')
want="linear-team=ENG;linear-project=Atlas;linear-milestone=M1;branch-override=no-shared;uat-policy=epic;"
want+="base-branch=main;refresh-bodies=true;converge=PRO-1 alice;stop-after=;authorized"
if [ "$got" = "$want" ]; then
  pass "every flag is restored from disk by a later process"
else
  fail "persisted flags" "got '$got'"
fi

log="${REPOS_ROOT}/.ticket-auto/initiatives/INIT-P1/state.log"
if grep -qF '|META|crosscheck|accepted|CARVE_SCOPE_LOST rescoped in consensus.md' "$log"; then
  pass "--accept is recorded as META|crosscheck|accepted"
else
  fail "--accept persisted" "$(grep crosscheck "$log" || echo absent)"
fi
if grep -qF '|META|no-tests-rule|done|true' "$log"; then
  pass "--no-tests-rule is persisted"
else
  fail "--no-tests-rule persisted" "absent from $log"
fi

# Per-literal accept (planner-specify-parameters D7): parsed, then recorded
# with its canonical form; a code-wide accept writes nothing.
rc=0
in_new_process 'planner_state_init INIT-P2 "an idea" >/dev/null
  planner_flags_parse resume INIT-P2 --accept "PARAM_LITERAL@export-link:15 minutes" \
    --accept=PARAM_LITERAL@export-link:\"24h\" || exit 9
  planner_flags_persist INIT-P2' >/dev/null 2>&1 || rc=$?
log2="${REPOS_ROOT}/.ticket-auto/initiatives/INIT-P2/state.log"
got=$(grep '|META|crosscheck|accepted|' "$log2" 2>/dev/null | cut -d'|' -f5- | paste -sd';' -)
if [ "$rc" -eq 0 ] && [ "$got" = "PARAM_LITERAL@export-link=time:900000 15 minutes;PARAM_LITERAL@export-link=time:86400000 24h" ]; then
  pass "--accept PARAM_LITERAL@<slug>:<literal> is recorded with its canonical form"
else
  fail "per-literal accept persisted" "rc=$rc got '$got'"
fi
rc=0
in_new_process 'planner_state_init INIT-P3 "an idea" >/dev/null
  planner_flags_parse resume INIT-P3 --accept "PARAM_LITERAL:all fine" 2>/dev/null && planner_flags_persist INIT-P3' >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && ! grep -q 'crosscheck|accepted' "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-P3/state.log"; then
  pass "a code-wide PARAM_LITERAL accept fails with rc 1 and writes nothing"
else
  fail "code-wide PARAM_LITERAL accept" "rc=$rc"
fi

# A resume that re-supplies nothing changes nothing.
in_new_process 'planner_flags_parse resume INIT-P1; planner_flags_persist INIT-P1' >/dev/null
got=$(in_new_process 'planner_config_get INIT-P1 linear-project; planner_create_authorized INIT-P1 && echo authorized')
if [ "$got" = "Atlas
authorized" ]; then
  pass "a bare resume keeps the persisted flags"
else
  fail "bare resume keeps flags" "got '$got'"
fi

in_new_process 'planner_state_init INIT-P2 "an idea" >/dev/null
  planner_flags_parse plan "an idea" --until Consensus --no-project --shared-branch
  planner_flags_persist INIT-P2' >/dev/null
got=$(in_new_process 'echo "$(planner_config_get INIT-P2 stop-after)|$(planner_config_get INIT-P2 no-project)|$(planner_config_get INIT-P2 branch-override)"
  planner_create_authorized INIT-P2 && echo authorized || echo unauthorized')
if [ "$got" = "Consensus|true|shared
unauthorized" ]; then
  pass "plan --until persists the stop point without authorizing creation"
else
  fail "plan --until persist" "got '$got'"
fi

# --create with no --until clears an earlier stop point.
in_new_process 'planner_flags_parse resume INIT-P2 --create; planner_flags_persist INIT-P2' >/dev/null
got=$(in_new_process 'planner_config_get INIT-P2 stop-after')
if [ -z "$got" ]; then
  pass "resume --create clears the stop point plan recorded"
else
  fail "--create clears stop-after" "got '$got'"
fi

# ── 4. intent idea line ──────────────────────────────────────────────────────

echo "--- 4. planner_intent_idea derives the state log's idea line ---"

source "${LIB_DIR}/planner-intent-gate.sh"

intent="${TMPDIR}/intent.md"
printf '# Intent\n\n## Objective\n\nLet finance export\ninvoices as CSV.\n\n## Scope\n\nBilling.\n' >"$intent"
got=$(planner_intent_idea "$intent")
if [ "$got" = "Let finance export invoices as CSV." ]; then
  pass "the Objective lines are joined with spaces, blanks dropped"
else
  fail "objective join" "got '$got'"
fi

printf '# Intent\n\n## Objective\n\n_None specified_\n\n## Scope\n' >"$intent"
got=$(planner_intent_idea "$intent")
if [ "$got" = "$intent" ]; then
  pass "the _None specified_ placeholder falls back to the path"
else
  fail "placeholder fallback" "got '$got'"
fi

printf '# Intent\n\n## Scope\n\nBilling.\n' >"$intent"
got=$(planner_intent_idea "$intent")
if [ "$got" = "$intent" ]; then
  pass "no Objective section falls back to the path"
else
  fail "missing section fallback" "got '$got'"
fi

printf '# Intent\n\n## Objective\nabcdefghij\n' >"$intent"
got=$(PLANNER_IDEA_MAX_LENGTH=4 planner_intent_idea "$intent")
if [ "$got" = "abcd" ]; then
  pass "the idea is truncated to PLANNER_IDEA_MAX_LENGTH"
else
  fail "truncation" "got '$got'"
fi

echo ""
echo "=== planner-invocation: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
