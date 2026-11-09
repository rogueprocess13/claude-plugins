#!/usr/bin/env bash
# test-planner-draft-readiness-gate-block.sh — planner-draft-readiness slice
# S2b, scenarios 4–5 of the halt-only draft readiness gate. Split from
# test-planner-draft-readiness-gate.sh with the scenario bodies unchanged;
# shared setup and stubs live in draft-readiness-gate-harness.sh.
#
# Covers:
#   4. A blocking finding halts (rc 3) with one fail line per finding; the
#      report and the describer read only the latest run (halt lines scoped
#      to the latest start); the describer reports DRAFT_NOT_READY.
#   5. --accept DRAFT_NOT_READY binds to the current draft hashes: the gate
#      passes with a warn line; no META|crosscheck|accepted from the accept
#      function or from planner-answers.sh; a spec edit re-arms the gate and
#      re-runs Crosscheck first.
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-gate-block.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/draft-readiness-gate-harness.sh"

echo "=== planner draft readiness gate (S2b): block ==="

# Scenario 4 starts from a passed first run.
_gate_prelude

# ── 4. blocking finding ──────────────────────────────────────────────────
echo "--- 4. blocking finding halts ---"
sed -i 's/Export responds with 200/Export responds with 200 OK/' "${SPECS}/b-api.md"
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200 OK"
_gate
unset FINDINGS_b_api
run_fails=$(grep -c '|META|draft-readiness|fail|b-api EDGE_CASE_GAP "Export responds with 200 OK"' "$LOG")
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 2 ] && [ "$run_fails" -eq 1 ] &&
  grep -q '|META|draft-readiness|done|blocked 1/2$' "$LOG" &&
  [ "$(cut -d' ' -f3 "${DR}/b-api/verdict")" = "blocked" ] && [ -s "${DR}/blocked-specs" ]; then
  pass "rc 3, one fail line per finding, done blocked 1/2, blocked-specs recorded"
else
  fail "blocked" "rc=$GATE_RC spawns=$SPAWNS fails=$run_fails $(tail -4 "$LOG")"
fi
# A second, cached run: still blocked, no spawn, and the report shows the
# finding once — readers scope to the latest start.
_gate
report=$(planner_draft_readiness_report "$INIT")
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 0 ] &&
  [ "$(grep -c '|META|draft-readiness|fail|b-api EDGE_CASE_GAP' "$LOG")" -eq 2 ] &&
  [ "$(printf '%s\n' "$report" | grep -c 'EDGE_CASE_GAP')" -eq 1 ] &&
  grep -q '^b-api (artifacts/specs/b-api.md)$' <<<"$report" &&
  grep -q 'does not guarantee Refinement passes' <<<"$report" &&
  grep -q -- '--accept DRAFT_NOT_READY' <<<"$report"; then
  pass "cached re-run still blocks; report reads only the latest run"
else
  fail "scoped report" "rc=$GATE_RC spawns=$SPAWNS $report"
fi
desc=$(planner_stop_describe_json "$INIT")
if [ "$(echo "$desc" | jq -r .reason)" = "DRAFT_NOT_READY" ] &&
  [ "$(echo "$desc" | jq -r '[.questions[].id] | join(",")')" = "draft-b-api,accept-DRAFT_NOT_READY,draft-resolved" ] &&
  echo "$desc" | jq -e '.questions[0].text | contains("EDGE_CASE_GAP")' >/dev/null &&
  case " $PLANNER_STOP_BLOCK_REASONS " in *" DRAFT_NOT_READY "*) true ;; *) false ;; esac then
  pass "describer: DRAFT_NOT_READY before CREATE_GATE, note per spec + accept + resolved"
else
  fail "describer" "$desc"
fi
planner_stop_describe "$INIT" | grep -q 'DRAFT_NOT_READY' && pass "describer block prints DRAFT_NOT_READY" ||
  fail "describer block" "$(planner_stop_describe "$INIT")"

# ── 5. accept ────────────────────────────────────────────────────────────
echo "--- 5. --accept DRAFT_NOT_READY ---"
planner_draft_readiness_accept "$INIT" "known gap, tracked elsewhere" >/dev/null 2>&1
acc_hash=$(planner_draft_readiness_combined_hash "$INIT")
if grep -q "|META|draft-readiness|accepted|${acc_hash} known gap, tracked elsewhere$" "$LOG" &&
  ! grep -q '|META|crosscheck|accepted|' "$LOG"; then
  pass "accept binds to the combined hash; no META|crosscheck|accepted"
else
  fail "accept" "$(grep accepted "$LOG")"
fi
[ "$(planner_draft_readiness_state "$INIT")" = "accepted" ] && pass "state: accepted" ||
  fail "state accepted" "$(planner_draft_readiness_state "$INIT")"
[ "$(planner_stop_describe_json "$INIT" | jq -r .reason)" = "CREATE_GATE" ] &&
  pass "describer: an accepted halt is no longer DRAFT_NOT_READY" ||
  fail "describer accepted" "$(planner_stop_describe_json "$INIT" | jq -c .)"
rc=0
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ] && tail -2 "$LOG" | grep -q "|META|draft-readiness|warn|accepted ${acc_hash} known gap" &&
  tail -1 "$LOG" | grep -q '|META|draft-readiness|done|accepted 2/2$'; then
  pass "gate passes on the accept, with a warn line"
else
  fail "accepted gate" "rc=$rc $(tail -2 "$LOG")"
fi
if ! planner_draft_readiness_accept "$INIT" "   " >/dev/null 2>&1; then
  pass "an empty reason is refused"
else
  fail "empty reason" "accepted"
fi

# planner-answers.sh: its own branch ahead of flag:accept:*.
source "${LIB_DIR}/planner-answers.sh"
# Re-block on a fresh edit first so the describer offers the accept question.
sed -i 's/Export responds with 200 OK/Export responds with HTTP 200 OK/' "${SPECS}/b-api.md"
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with HTTP 200 OK"
: >"$CROSSCHECK_CALLS"
_gate
unset FINDINGS_b_api
if [ "$GATE_RC" -eq 3 ] && [ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 1 ]; then
  pass "a spec edit re-arms the accepted gate, after re-running Crosscheck"
else
  fail "re-arm" "rc=$GATE_RC crosscheck=$(wc -l <"$CROSSCHECK_CALLS")"
fi
round=$(planner_stop_round "$INIT")
jq -n --argjson r "$round" '{schema_version: 1, round: $r, answers: [
  {id: "accept-DRAFT_NOT_READY", value: "accepted via answers", answered_by: "U1", role: "operator", ts: "2026-10-30T00:00:00Z"}]}' \
  >"${TMP_ROOT}/answers.json"
arc=0
planner_answers_apply "$INIT" "${TMP_ROOT}/answers.json" >/dev/null 2>&1 || arc=$?
acc2=$(planner_draft_readiness_combined_hash "$INIT")
if [ "$arc" -eq 0 ] && grep -q "|META|draft-readiness|accepted|${acc2} accepted via answers$" "$LOG" &&
  ! grep -q '|META|crosscheck|accepted|' "$LOG"; then
  pass "answers flag:accept:DRAFT_NOT_READY → draft accept, never a Crosscheck accept"
else
  fail "answers accept" "rc=$arc $(grep accepted "$LOG")"
fi

_gate_finish 5
