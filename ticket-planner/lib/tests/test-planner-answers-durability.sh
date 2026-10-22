#!/usr/bin/env bash
# test-planner-answers-durability.sh — the headless loop across real process
# boundaries: halt → describe → answers → resume crosses the gate
# (planner-headless-questions task 4.6).
#
# Same discipline as test-planner-config-durability.sh: every step runs in a
# fresh `env -i bash -c`, because that is what an orchestrator does — one
# `claude -p` per step, hours apart, with nothing in common but the disk. A
# describer or intake that leaned on a variable set by an earlier step would
# pass a same-process test and fail here.
#
# Run: bash ticket-planner/lib/tests/test-planner-answers-durability.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOLD_PARSER="${LIB_DIR}/../../ticket-auto-pipeline/lib/human-hold-parse.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export REPOS_ROOT="${WORK}/repos"
export HOME="${WORK}/home"
mkdir -p "$REPOS_ROOT" "$HOME"

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

in_new_process() {
  env -i \
    HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" \
    SCRIPT_DIR="$SCRIPT_DIR" CLAUDE_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)" \
    bash -c '
      source "${LIB_DIR}/planner-state.sh"
      source "${LIB_DIR}/planner-router.sh"
      source "${SCRIPT_DIR}/halt-fixtures.sh"
      '"$1"'
    '
}

# answers_from_hold <hold_file> <id> <value> <out>
answers_from_hold() {
  local parsed round
  parsed=$(bash "$HOLD_PARSER" --phase PLANNER --return-file "$1")
  round=$(printf '%s' "$parsed" | jq -r '.round')
  jq -n --argjson round "$round" --arg id "$2" --arg value "$3" \
    '{schema_version: 1, round: $round, answers: [{id: $id, value: $value,
      answered_by: "U123", role: "operator", ts: "2026-10-11T19:30:00Z"}]}' >"$4"
}

INIT="INIT-1700000000-7777"

echo "=== planner answers durability (cross-process) tests ==="

# ── create gate ────────────────────────────────────────────────────────────

echo "--- create gate: halt → describe → answers → resume ---"

out=$(in_new_process "halt_fixture_init create-gate-stop ${INIT} >/dev/null
  halt_fixture_run create-gate-stop ${INIT} ${WORK}/run; cat ${WORK}/run/create-gate-stop.out")
if [[ "$out" == "Stopped after Crosscheck — creation not authorized"* ]]; then
  pass "process 1: the plan run halts at the create gate"
else
  fail "process 1: the plan run halts at the create gate" "$out"
fi

in_new_process "bash \${LIB_DIR}/planner-stop-describe.sh ${INIT}" >"${WORK}/round1.hold"
if grep -qx 'REASON: CREATE_GATE' "${WORK}/round1.hold"; then
  pass "process 2: the describer reports CREATE_GATE"
else
  fail "process 2: the describer reports CREATE_GATE" "$(cat "${WORK}/round1.hold")"
fi

answers_from_hold "${WORK}/round1.hold" create yes "${WORK}/round1.json"
in_new_process "bash \${LIB_DIR}/planner-answers.sh ${INIT} ${WORK}/round1.json" >"${WORK}/apply.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'ANSWERS_APPLIED round=1' "${WORK}/apply.out"; then
  pass "process 3: the answers file is applied"
else
  fail "process 3: the answers file is applied" "rc=$rc $(cat "${WORK}/apply.out")"
fi

# Process 4 is the resume: SKILL.md step 1 (create gate) for the phase it
# derives, then step 6's stop check for the phase that just completed.
got=$(in_new_process "
  PHASE=\$(planner_position_derive ${INIT})
  planner_create_gate_check ${INIT} \"\$PHASE\" 2>/dev/null && echo \"gate-open \$PHASE\"
  planner_should_stop_after ${INIT} Crosscheck || echo 'no-stop'")
if [ "$got" = "gate-open EpicGen
no-stop" ]; then
  pass "process 4: resume crosses the create gate into Epic Gen without --create"
else
  fail "process 4: resume crosses the create gate into Epic Gen without --create" "$got"
fi

got=$(in_new_process "bash \${LIB_DIR}/planner-stop-describe.sh ${INIT}")
if [ "$got" = "REASON=RUNNING" ]; then
  pass "process 5: with the gate answered, nothing is left to ask"
else
  fail "process 5: with the gate answered, nothing is left to ask" "$got"
fi

# Replaying the same file in yet another process is still a no-op.
in_new_process "bash \${LIB_DIR}/planner-answers.sh ${INIT} ${WORK}/round1.json" >"${WORK}/replay.out" 2>&1
if grep -q 'ANSWERS_ALREADY_APPLIED round=1' "${WORK}/replay.out" &&
  [ "$(grep -c '|META|human-hold|done|' "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/state.log")" = "1" ]; then
  pass "process 6: a replay after the fact is a no-op"
else
  fail "process 6: a replay after the fact is a no-op" "$(cat "${WORK}/replay.out")"
fi

# ── crosscheck accept ──────────────────────────────────────────────────────

echo "--- crosscheck: answered accept is honoured by the next Crosscheck run ---"

INIT2="INIT-1700000000-8888"
in_new_process "halt_fixture_init crosscheck ${INIT2} >/dev/null
  halt_fixture_run crosscheck ${INIT2} ${WORK}/run" >/dev/null 2>&1
in_new_process "bash \${LIB_DIR}/planner-stop-describe.sh ${INIT2}" >"${WORK}/cc.hold"
answers_from_hold "${WORK}/cc.hold" accept-CARVE_SCOPE_LOST "documented rescope" "${WORK}/cc.json"
in_new_process "bash \${LIB_DIR}/planner-answers.sh ${INIT2} ${WORK}/cc.json" >/dev/null 2>&1

# The real finding emitter, in a fresh process, as the re-run Crosscheck
# would call it: rc 3 means "operator-accepted, non-blocking".
got=$(in_new_process "source \${LIB_DIR}/planner-crosscheck.sh
  _planner_crosscheck_emit_finding ${INIT2} 'planner-crosscheck-propagation: CARVE_SCOPE_LOST count changed'; echo \$?")
if [ "$got" = "3" ]; then
  pass "the re-run Crosscheck treats the answered code as accepted"
else
  fail "the re-run Crosscheck treats the answered code as accepted" "emit rc=$got"
fi

# ── Specify decision (planner-specify-waiting-on-human) ────────────────────

echo "--- specify decision: describe → answers → gate clears in a new process ---"

INIT3="INIT-1700000000-9999"
in_new_process "planner_state_init ${INIT3} idea >/dev/null
  _halt_done ${INIT3} Appraisal Discovery Architecture Specify
  printf '%s\n' '# Proposal' '' '## Business Outcomes' '' '### O1' \
    '**Outcome:** NEEDS_HUMAN_DECISION — which role consumes the classified documents?' \
    >\"\$(planner_initiative_dir ${INIT3})/artifacts/proposal.md\"" >/dev/null 2>&1
in_new_process "bash \${LIB_DIR}/planner-stop-describe.sh ${INIT3}" >"${WORK}/sd.hold"
if grep -qx 'REASON: SPECIFY_DECISION' "${WORK}/sd.hold"; then
  pass "specify: the describer reports SPECIFY_DECISION in a fresh process"
else
  fail "specify: the describer reports SPECIFY_DECISION in a fresh process" "$(cat "${WORK}/sd.hold")"
fi

sd_id=$(bash "$HOLD_PARSER" --phase PLANNER --return-file "${WORK}/sd.hold" | jq -r '.questions[0].id')
answers_from_hold "${WORK}/sd.hold" "$sd_id" "Tax accountants preparing returns" "${WORK}/sd.json"
in_new_process "bash -c 'bash \${LIB_DIR}/planner-answers.sh ${INIT3} ${WORK}/sd.json'" >"${WORK}/sd-apply.out" 2>&1
rc=$?

got=$(in_new_process "source \${LIB_DIR}/planner-specify-decisions.sh
  rc=0; planner_specify_gate ${INIT3} || rc=\$?
  echo \"gate=\$rc\"
  bash \${LIB_DIR}/planner-stop-describe.sh ${INIT3}")
if [ "$rc" -eq 0 ] && [ "$got" = "gate=0
REASON=RUNNING" ] &&
  grep -qxF '**Outcome:** Human decision (verbatim, round 1, operator): "Tax accountants preparing returns"' \
    "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT3}/artifacts/proposal.md"; then
  pass "specify: after the answers are applied, a new process sees the gate clear and the answer in proposal.md"
else
  fail "specify: after the answers are applied, a new process sees the gate clear and the answer in proposal.md" "rc=$rc got=$got $(cat "${WORK}/sd-apply.out")"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
