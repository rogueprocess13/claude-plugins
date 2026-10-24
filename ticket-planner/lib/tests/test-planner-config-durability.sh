#!/usr/bin/env bash
# test-planner-config-durability.sh — Proves invocation config survives the process
# boundary the dispatch loop puts between every pair of phases.
#
# This is the suite that #144 needed and did not have. The stop-condition tests set
# PLANNER_UNTIL and read it back in the same shell, so they passed 25/25 while
# --dry-run did nothing at all in production: an Agent tool call sits between the
# shell that parses arguments and the shell that checks the stop condition, and an
# `export` does not cross it.
#
# Every assertion below therefore writes in one `bash -c` and reads in another. A
# helper that reintroduces an environment read will fail here and nowhere else.
#
# Run: bash ticket-planner/lib/tests/test-planner-config-durability.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REPOS_ROOT="$TMPDIR"

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

# Run a snippet in a *fresh process* with the libraries sourced and nothing else
# inherited — the closest faithful model of one dispatch-loop iteration.
in_new_process() {
  env -i \
    HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" \
    bash -c '
      source "${LIB_DIR}/planner-state.sh"
      source "${LIB_DIR}/planner-router.sh"
      source "${LIB_DIR}/planner-phase-prompts.sh"
      '"$1"'
    '
}

echo "=== planner config durability (cross-process) tests ==="

# ── Test 1: the stop point survives the boundary ───────────────────────────────
#
# The exact repro from #144: export in one call, read in the next.

echo "--- Test 1: the stop point crosses the boundary ---"

in_new_process 'planner_state_init INIT-DURABLE "an idea" >/dev/null
                planner_stop_after_set INIT-DURABLE Consensus'

got=$(in_new_process 'planner_stop_phase INIT-DURABLE')
if [ "$got" = "Consensus" ]; then
  pass "a stop point written in one process is read in the next"
else
  fail "stop point crosses the boundary" "got '${got}'"
fi

# The counter-example: the old mechanism, to show the boundary is real and that
# this suite would have caught the regression.
got=$(
  env -i HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" \
    bash -c 'export PLANNER_UNTIL=Consensus' 2>/dev/null
  in_new_process 'echo "${PLANNER_UNTIL:-<UNSET>}"'
)
if [ "$got" = "<UNSET>" ]; then
  pass "an exported variable does NOT cross the boundary (the #144 mechanism)"
else
  fail "the boundary is real" "PLANNER_UNTIL read back as '${got}'"
fi

# ── Test 2: creation is refused across the boundary ────────────────────────────

echo "--- Test 2: the create gate holds across the boundary ---"

if in_new_process 'planner_create_gate_check INIT-DURABLE EpicGen' 2>/dev/null; then
  fail "EpicGen is refused in a fresh process" "allowed"
else
  pass "EpicGen is refused in a process that never saw the flags"
fi

if in_new_process 'planner_should_stop_after INIT-DURABLE Consensus'; then
  pass "the loop stops after Consensus in a fresh process"
else
  fail "stop decision crosses the boundary" "did not stop"
fi

# ── Test 3: authorization survives a crash between --create and EpicGen ────────
#
# The issue's own verification step: authorize, lose the process, resume with no
# flag at all, and creation must still be authorized — because it is on disk.

echo "--- Test 3: authorization survives a crash ---"

in_new_process 'planner_authorize_create INIT-DURABLE
                planner_stop_after_set INIT-DURABLE ""'

if in_new_process 'planner_create_authorized INIT-DURABLE'; then
  pass "authorization written in one process is visible in another"
else
  fail "authorization crosses the boundary" "not authorized"
fi

if in_new_process 'planner_create_gate_check INIT-DURABLE EpicGen' 2>/dev/null; then
  pass "a resume with no flags still proceeds once authorized"
else
  fail "authorized resume proceeds" "refused"
fi

got=$(in_new_process 'planner_stop_phase INIT-DURABLE')
if [ -z "$got" ]; then
  pass "--create lifts the stop point across the boundary"
else
  fail "--create lifts the stop point" "got '${got}'"
fi

# ── Test 4: project and milestone reach the prompt generator ───────────────────
#
# EpicGen's prompt is built six phases and at least six process boundaries after
# --project was parsed. The value has to come off disk or it is not there at all.

echo "--- Test 4: project/milestone reach prompt generation ---"

in_new_process 'planner_state_init INIT-PROJ "an idea" >/dev/null
                planner_authorize_create INIT-PROJ
                planner_config_set INIT-PROJ linear-team "LED"
                planner_config_set INIT-PROJ linear-project "Ledgerly M1"
                planner_config_set INIT-PROJ linear-milestone "Vertical Slice 1"
                planner_config_set INIT-PROJ branch-override "shared"'

prompt=$(in_new_process 'planner_prompt_epicgen INIT-PROJ "an idea" /tmp/state')

# Here-strings (not `echo "$var" | grep`) throughout this block — under
# `pipefail`, `grep -q`/`grep -m1` closing early after its first match on a
# large multi-KB prompt can SIGPIPE an upstream `echo` still mid-write,
# intermittently corrupting the pipeline's reported exit status regardless
# of whether the match was actually found. Confirmed as the root cause of
# this file's long-standing CI flakiness (multiple prior observations) —
# reproduced ~25-40% failure rate under `echo | grep -q`, 0/40 under
# `grep <<<`.
if grep -qF 'PROJECT_REF="Ledgerly M1"' <<<"$prompt"; then
  pass "the project ref is interpolated into the EpicGen prompt as a literal"
else
  fail "project ref reaches EpicGen" "$(grep -m1 'PROJECT_REF=' <<<"$prompt" || echo 'absent')"
fi

if grep -qF 'MILESTONE_REF="Vertical Slice 1"' <<<"$prompt"; then
  pass "the milestone ref is interpolated into the EpicGen prompt as a literal"
else
  fail "milestone ref reaches EpicGen" "$(grep -m1 'MILESTONE_REF=' <<<"$prompt" || echo 'absent')"
fi

if grep -qF 'BRANCH_OVERRIDE="shared"' <<<"$prompt"; then
  pass "the branch override is interpolated into the EpicGen prompt as a literal"
else
  fail "branch override reaches EpicGen" "$(grep -m1 'BRANCH_OVERRIDE=' <<<"$prompt" || echo 'absent')"
fi

if grep -qF 'TEAM_REF="LED"' <<<"$prompt"; then
  pass "the team ref is interpolated into the EpicGen prompt as a literal"
else
  fail "team ref reaches EpicGen" "$(grep -m1 'TEAM_REF=' <<<"$prompt" || echo 'absent')"
fi

# The project gate is the reason an unset --project is no longer silent (#256).
# It has to be wired into the prompt, and wired in *before* the create call —
# after it, the epic is already filed with no project and the gate is theatre.
if grep -qF 'planner_project_gate_check "INIT-PROJ" "$TEAM_ID"' <<<"$prompt"; then
  pass "EpicGen calls the project gate"
else
  fail "EpicGen calls the project gate" "no planner_project_gate_check call in the prompt"
fi

if grep -qF 'source "${CLAUDE_PLUGIN_ROOT}/lib/planner-project-gate.sh"' <<<"$prompt"; then
  pass "EpicGen sources the gate it calls"
else
  fail "EpicGen sources the gate" "no source line for planner-project-gate.sh"
fi

gate_line=$(grep -m1 -n 'planner_project_gate_check' <<<"$prompt" | cut -d: -f1)
create_line=$(grep -m1 -n 'EPIC_RESPONSE=$(planner_linear_create_issue' <<<"$prompt" | cut -d: -f1)
if [ -n "$gate_line" ] && [ -n "$create_line" ] && [ "$gate_line" -lt "$create_line" ]; then
  pass "the gate runs before the epic is created"
else
  fail "gate precedes creation" "gate at line '${gate_line}', create at line '${create_line}'"
fi

# ── Test 5: TicketGen prefers the ids EpicGen resolved ─────────────────────────

echo "--- Test 5: TicketGen files against the resolved ids ---"

tg=$(in_new_process 'planner_prompt_ticketgen INIT-PROJ "an idea" /tmp/state')
if grep -qF '"Ledgerly M1"' <<<"$tg"; then
  pass "TicketGen falls back to the raw ref before EpicGen has resolved one"
else
  fail "TicketGen falls back to the raw ref" "no project ref in the prompt"
fi

in_new_process 'planner_config_set INIT-PROJ linear-project-id "11111111-2222-3333-4444-555555555555"
                planner_config_set INIT-PROJ linear-milestone-id "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                planner_config_set INIT-PROJ linear-team-id "99999999-8888-7777-6666-555555555555"'

tg=$(in_new_process 'planner_prompt_ticketgen INIT-PROJ "an idea" /tmp/state')
if grep -qF '"11111111-2222-3333-4444-555555555555"' <<<"$tg" &&
  ! grep -qF '"Ledgerly M1"' <<<"$tg"; then
  pass "TicketGen prefers the resolved project id EpicGen persisted"
else
  fail "TicketGen prefers the resolved project id" "still using the raw ref"
fi

# The team is the one value where a second, independent lookup would be actively
# harmful: children on a different team from their parent epic is unrecoverable
# without deleting and recreating them.
if grep -qF 'TEAM_ID="99999999-8888-7777-6666-555555555555"' <<<"$tg"; then
  pass "TicketGen files children against the team id EpicGen resolved"
else
  fail "TicketGen reuses the resolved team id" "$(grep -m1 'TEAM_ID=' <<<"$tg" || echo 'absent')"
fi

# ── Test 6: no library reads the flag variables at use time ────────────────────
#
# A structural guard. If someone reintroduces `${LINEAR_PROJECT:-}` into a phase
# prompt or the router, the value silently reverts to empty in production and only
# this check notices.

echo "--- Test 6: no mid-run environment reads ---"

leaks=""
for var in PLANNER_UNTIL PLANNER_REVIEW_HOLD PLANNER_CONSENSUS_HOLD \
  PLANNER_SHARED_BRANCH PLANNER_NO_SHARED_BRANCH LINEAR_PROJECT LINEAR_PROJECT_MILESTONE PLANNER_UAT_POLICY \
  PLANNER_BASE_BRANCH PLANNER_MERGE_POLICY PLANNER_SYNC_POLICY; do
  hits=$(grep -ln "\${${var}[:-]" "${LIB_DIR}/planner-router.sh" "${LIB_DIR}/planner-phase-prompts.sh" 2>/dev/null || true)
  [ -n "$hits" ] && leaks="${leaks}${var} in ${hits}; "
done

if [ -z "$leaks" ]; then
  pass "the router and phase prompts read none of the flag variables"
else
  fail "no mid-run environment reads" "$leaks"
fi

# SKILL.md may *read* the env vars once during argument parsing — that shell does
# see them. What it must never do again is `export` one and expect a later phase to
# find it, which is the line-for-line mistake #144 was.
skill_md="${LIB_DIR}/../skills/ticket-planner/SKILL.md"
exports=$(grep -nE '^\s*export (PLANNER_UNTIL|PLANNER_SHARED_BRANCH|PLANNER_NO_SHARED_BRANCH|LINEAR_PROJECT|LINEAR_PROJECT_MILESTONE)' "$skill_md" 2>/dev/null || true)
if [ -z "$exports" ]; then
  pass "SKILL.md exports no flag variable across the dispatch loop"
else
  fail "SKILL.md does not export flag variables" "$exports"
fi

# And it must persist the authorization before it can dispatch a write phase.
if grep -q 'planner_authorize_create' "$skill_md" && grep -q 'planner_create_gate_check' "$skill_md"; then
  pass "SKILL.md persists authorization and checks the gate"
else
  fail "SKILL.md wires the create gate" "missing planner_authorize_create or planner_create_gate_check"
fi

# ── Test 7: the no-tests rule crosses the boundary (#503) ─────────────────────
#
# Persisted once at argument parsing (flag, PLANNER_NO_TESTS_RULE read there, or
# detection from REPOS_ROOT CLAUDE.md); Specify and Crosscheck run in later
# processes and must read it from the state log, never from the environment.

echo "--- Test 7: the no-tests rule crosses the boundary ---"

in_new_process 'planner_state_init INIT-NOTESTS "an idea" >/dev/null
                source "${LIB_DIR}/planner-crosscheck-testdata.sh"
                planner_testdata_no_tests_rule_persist INIT-NOTESTS true'

got=$(in_new_process 'source "${LIB_DIR}/planner-crosscheck-testdata.sh"
                      planner_testdata_no_tests_rule INIT-NOTESTS >/dev/null && echo on || echo off')
if [ "$got" = "on" ]; then
  pass "--no-tests-rule written in one process is read in the next"
else
  fail "no-tests rule crosses the boundary" "got '${got}'"
fi

mkdir -p "${REPOS_ROOT}/svc-notests"
echo "Implementation does not write tests." >"${REPOS_ROOT}/svc-notests/CLAUDE.md"
in_new_process 'planner_state_init INIT-NOTESTS-DETECT "an idea" >/dev/null
                source "${LIB_DIR}/planner-crosscheck-testdata.sh"
                planner_testdata_no_tests_rule_persist INIT-NOTESTS-DETECT'
rm -f "${REPOS_ROOT}/svc-notests/CLAUDE.md"
got=$(in_new_process 'source "${LIB_DIR}/planner-crosscheck-testdata.sh"
                      planner_testdata_no_tests_rule INIT-NOTESTS-DETECT || echo off')
case "$got" in
*svc-notests/CLAUDE.md*) pass "a detected rule is persisted with its source and survives a CLAUDE.md change" ;;
*) fail "detected rule persists" "got '${got}'" ;;
esac

got=$(
  env -i HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" PLANNER_NO_TESTS_RULE=true \
    bash -c 'source "${LIB_DIR}/planner-state.sh"
             planner_state_init INIT-NOTESTS-ENV "an idea" >/dev/null
             source "${LIB_DIR}/planner-crosscheck-testdata.sh"
             planner_testdata_no_tests_rule INIT-NOTESTS-ENV >/dev/null && echo on || echo off'
)
if [ "$got" = "off" ]; then
  pass "PLANNER_NO_TESTS_RULE in a later phase's environment is ignored"
else
  fail "no ambient env read of PLANNER_NO_TESTS_RULE" "got '${got}'"
fi

hits=$(grep -ln '\${PLANNER_NO_TESTS_RULE' "${LIB_DIR}"/*.sh 2>/dev/null || true)
if [ -z "$hits" ]; then
  pass "no library reads PLANNER_NO_TESTS_RULE (SKILL.md reads it once at parsing)"
else
  fail "no library reads PLANNER_NO_TESTS_RULE" "$hits"
fi

# ── Test 8: the UAT policy crosses the boundary (planner-test-data-derivation 5.1) ──
#
# PLANNER_UAT_POLICY is read once at argument parsing and persisted as the
# `uat-policy` config key. EpicGen's prompt, generated in a later process, must
# interpolate it from disk — and, with no explicit value, stamp `epic` when
# Crosscheck's synthesis wrote test-data specs (testdata-synth.json).

echo "--- Test 8: the UAT policy crosses the boundary ---"

_uat_arg() { grep -m1 -o -- '--arg uat "[^"]*"' <<<"$1" || echo absent; }

in_new_process 'planner_state_init INIT-UAT "an idea" >/dev/null
                planner_config_set INIT-UAT uat-policy per-ticket'
prompt=$(in_new_process 'planner_prompt_epicgen INIT-UAT "an idea" /tmp/state' </dev/null)
got=$(_uat_arg "$prompt")
if [ "$got" = '--arg uat "per-ticket"' ]; then
  pass "an explicit uat-policy written in one process reaches EpicGen in the next"
else
  fail "explicit uat-policy reaches EpicGen" "got ${got}"
fi

# Explicit wins over synthesized TD specs.
mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-UAT/artifacts"
echo '{"version":1,"td_specs":[{"slug":"a-test-data","kind":"single"}],"overrides":[],"edges":[]}' \
  >"${REPOS_ROOT}/.ticket-auto/initiatives/INIT-UAT/artifacts/testdata-synth.json"
got=$(_uat_arg "$(in_new_process 'planner_prompt_epicgen INIT-UAT "an idea" /tmp/state' </dev/null)")
if [ "$got" = '--arg uat "per-ticket"' ]; then
  pass "an explicit uat-policy is kept when TD specs exist"
else
  fail "explicit uat-policy wins" "got ${got}"
fi

in_new_process 'planner_state_init INIT-UAT-TD "an idea" >/dev/null'
mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-UAT-TD/artifacts"
cp "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-UAT/artifacts/testdata-synth.json" \
  "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-UAT-TD/artifacts/testdata-synth.json"
got=$(
  env -i HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" PLANNER_UAT_POLICY=per-ticket \
    bash -c 'source "${LIB_DIR}/planner-state.sh"; source "${LIB_DIR}/planner-router.sh"
             source "${LIB_DIR}/planner-phase-prompts.sh"
             planner_prompt_epicgen INIT-UAT-TD "an idea" /tmp/state' </dev/null
)
got=$(_uat_arg "$got")
if [ "$got" = '--arg uat "epic"' ]; then
  pass "TD specs + no persisted policy → epic (an ambient PLANNER_UAT_POLICY is ignored)"
else
  fail "auto epic UAT" "got ${got}"
fi

in_new_process 'planner_state_init INIT-UAT-NONE "an idea" >/dev/null'
got=$(_uat_arg "$(in_new_process 'planner_prompt_epicgen INIT-UAT-NONE "an idea" /tmp/state' </dev/null)")
if [ "$got" = '--arg uat ""' ]; then
  pass "no TD specs and no explicit policy → field omitted (per-ticket)"
else
  fail "no TD specs leaves uat empty" "got ${got}"
fi

# A sibling chain with no TD spec (rehearsal iter-01 shape) → epic, and the
# decision record carries the generator's values, not agent-side references.
in_new_process 'planner_state_init INIT-UAT-CHAIN "an idea" >/dev/null'
_chain_dir="${REPOS_ROOT}/.ticket-auto/initiatives/INIT-UAT-CHAIN/artifacts/specs"
mkdir -p "$_chain_dir"
printf '# a\n\n## Labels\n\nchore\n' >"${_chain_dir}/a-store.md"
printf '# b\n\n## Labels\n\nfeature, blocked-by:a-store\n' >"${_chain_dir}/b-auth.md"
prompt=$(in_new_process 'planner_prompt_epicgen INIT-UAT-CHAIN "an idea" /tmp/state' </dev/null)
got=$(_uat_arg "$prompt")
if [ "$got" = '--arg uat "epic"' ]; then
  pass "a sibling chain with no TD spec → epic"
else
  fail "chain gives epic UAT" "got ${got}"
fi
if grep -qF '"policy=epic reason=chain"' <<<"$prompt"; then
  pass "uat-policy-decision record is interpolated by the generator"
else
  fail "uat-policy-decision literal" "$(grep -m1 -A1 'uat-policy-decision' <<<"$prompt" || echo absent)"
fi

if grep -q 'planner_config_set "\$INITIATIVE_ID" "uat-policy"' "$skill_md"; then
  pass "SKILL.md persists PLANNER_UAT_POLICY as the uat-policy config key"
else
  fail "SKILL.md persists uat-policy" "no planner_config_set ... uat-policy line"
fi

# ── Test 9: base branch, merge and sync policy cross the boundary ─────────────
#
# planner-base-branch-config (rehearsal F13). Iter 01's directive said `main`
# only because the agent exported PLANNER_BASE_BRANCH itself; now the value is
# a config key or a detection, interpolated by the generator as a literal.

echo "--- Test 9: base branch crosses the boundary ---"

_dir_arg() { grep -m1 -o -- "--arg $2 \"[^\"]*\"" <<<"$1" || echo absent; }

# One pinned repo with only `main` (dexter-sandbox shape), under --shared-branch.
git init -q -b main "${REPOS_ROOT}/sandbox-main"
git -C "${REPOS_ROOT}/sandbox-main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
in_new_process 'planner_state_init INIT-BASE "an idea" >/dev/null
                planner_config_set INIT-BASE branch-override shared >/dev/null
                planner_state_write INIT-BASE META discovery repo-ref "sandbox-main@main@0000000" >/dev/null'
prompt=$(in_new_process 'planner_prompt_epicgen INIT-BASE "an idea" /tmp/state' </dev/null)
got=$(_dir_arg "$prompt" base)
if [ "$got" = '--arg base "main"' ]; then
  pass "a main-only pinned repo gives base main with no env var set"
else
  fail "detected base reaches EpicGen" "got ${got}"
fi
if grep -qF '|META|base-branch-source|done|detected:sandbox-main=main' \
  "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-BASE/state.log"; then
  pass "detection is recorded as META|base-branch-source"
else
  fail "base-branch-source line" "absent"
fi
got=$(_dir_arg "$prompt" merge)/$(_dir_arg "$prompt" sync)
if [ "$got" = '--arg merge "manual"/--arg sync "rebase-on-base-change"' ]; then
  pass "merge and sync default to literals"
else
  fail "merge/sync defaults" "got ${got}"
fi

# Explicit --base-branch plus merge/sync env, persisted by the parsing shell
# (planner_directive_config_persist) and read by a later one.
in_new_process 'planner_state_init INIT-BASE-EXP "an idea" >/dev/null
                planner_config_set INIT-BASE-EXP branch-override shared >/dev/null
                planner_state_write INIT-BASE-EXP META discovery repo-ref "sandbox-main@main@0000000" >/dev/null
                source "${LIB_DIR}/planner-crosscheck-repo-ref.sh"
                PLANNER_MERGE_POLICY=on-all-children-done PLANNER_SYNC_POLICY=none \
                  planner_directive_config_persist INIT-BASE-EXP main >/dev/null'
prompt=$(in_new_process 'planner_prompt_epicgen INIT-BASE-EXP "an idea" /tmp/state' </dev/null)
got=$(_dir_arg "$prompt" base)/$(_dir_arg "$prompt" merge)/$(_dir_arg "$prompt" sync)
if [ "$got" = '--arg base "main"/--arg merge "on-all-children-done"/--arg sync "none"' ]; then
  pass "explicit base, merge and sync (none) reach EpicGen as literals"
else
  fail "explicit directive config" "got ${got}"
fi

# An explicit base the pinned repo lacks: the prompt fails before any agent runs.
in_new_process 'planner_state_init INIT-BASE-BAD "an idea" >/dev/null
                planner_config_set INIT-BASE-BAD branch-override shared >/dev/null
                planner_config_set INIT-BASE-BAD base-branch release >/dev/null
                planner_state_write INIT-BASE-BAD META discovery repo-ref "sandbox-main@main@0000000" >/dev/null'
if out=$(in_new_process 'planner_prompt_for_phase EpicGen INIT-BASE-BAD "an idea" /tmp/state' </dev/null 2>&1); then
  fail "missing explicit base stops EpicGen" "prompt rendered (rc 0)"
elif grep -qF 'BASE_BRANCH_UNRESOLVED' <<<"$out"; then
  pass "missing explicit base fails prompt rendering with BASE_BRANCH_UNRESOLVED"
else
  fail "missing explicit base message" "$out"
fi

# Not shared: the base is irrelevant, so a bad base must not block the epic.
in_new_process 'planner_state_init INIT-BASE-NS "an idea" >/dev/null
                planner_config_set INIT-BASE-NS branch-override no-shared >/dev/null
                planner_config_set INIT-BASE-NS base-branch release >/dev/null
                planner_state_write INIT-BASE-NS META discovery repo-ref "sandbox-main@main@0000000" >/dev/null'
if in_new_process 'planner_prompt_epicgen INIT-BASE-NS "an idea" /tmp/state' </dev/null >/dev/null 2>&1; then
  pass "a no-shared epic never runs the base resolver"
else
  fail "no-shared epic renders" "prompt failed"
fi

if grep -q 'planner_directive_config_persist "\$INITIATIVE_ID"' "$skill_md" &&
  grep -q -- '--base-branch) shift; BASE_BRANCH_REF=' "$skill_md"; then
  pass "SKILL.md parses --base-branch and persists the directive config"
else
  fail "SKILL.md base-branch wiring" "flag or persist call missing"
fi

echo ""
echo "=== planner config durability: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
