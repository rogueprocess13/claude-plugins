#!/usr/bin/env bash
# test-planner-draft-readiness-loop-limits.sh — planner-draft-readiness slice S3b
# (design D8, D11, D12, D14): the bounded auto-revise loop of the draft
# readiness gate — Crosscheck regression, agent retry, drift and the limits.
# The harness, stub agents and the _gate driver are in
# draft-readiness-loop-harness.sh; the suite is split over four
# test-planner-draft-readiness-loop-*.sh files so the parallel runner can
# spread it.
#
# Covers (tasks.md 6.7):
#  6. Crosscheck re-run after an applied round; regression reverts the spec
#  7. agent retry: one retry, then failed:AGENT_FAILED (demoted `failed`);
#     a retry that succeeds
#  8. new gap on a revised unit: `round-limit`/`revised`; same code on the
#     same unit: `drift`
#  9. spawn budget halts before spawning
#  10. MAX_ROUNDS=0 is halt-only; an invalid value is refused
#  12. (every file) no Linear call, no ticket manifest, no snapshot left
#      behind
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-loop-limits.sh

# shellcheck source=draft-readiness-loop-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/draft-readiness-loop-harness.sh"

echo "=== planner draft readiness revise loop (S3b): limits ==="

# ── 6. Crosscheck regression ─────────────────────────────────────────────
echo "--- 6. Crosscheck regression reverts the round ---"
_setup INIT-L6
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
printf '1\n0\n' >"$CROSSCHECK_QUEUE"
cp "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$(_status b-api 1)" = "reverted:CROSSCHECK_REGRESSION" ] && cmp -s "${SPECS}/b-api.md" "${TMP_ROOT}/b-api.orig" &&
  [ "$(wc -l <"$CROSSCHECK_CALLS")" -eq 2 ] &&
  _run_lines | grep -q '|META|draft-revise|fail|b-api round=1 CROSSCHECK_REGRESSION "CITATION_UNRESOLVED"' &&
  [ "$GATE_RC" -eq 0 ] &&
  jq -e '[.findings[] | select(.demote_reason == "reverted")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "regression: spec restored, status reverted:CROSSCHECK_REGRESSION, Crosscheck passes again"
else
  fail "regression" "rc=$GATE_RC st=$(_status b-api 1) xc=$(wc -l <"$CROSSCHECK_CALLS") $(_run_lines | grep draft-revise)"
fi
# Crosscheck still blocking after the revert halts the run.
_setup INIT-L6b
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
printf '1\n1\n' >"$CROSSCHECK_QUEUE"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$GATE_RC" -eq 3 ] && _run_lines | grep -q '|META|draft-readiness|fail|(run) CROSSCHECK_BLOCKED "CITATION_UNRESOLVED"'; then
  pass "Crosscheck still blocking after the revert halts with CROSSCHECK_BLOCKED"
else
  fail "regression halt" "rc=$GATE_RC $(_run_lines | grep -E 'fail|done')"
fi

# ── 7. agent retry ───────────────────────────────────────────────────────
echo "--- 7. revise agent retry ---"
_setup INIT-L7
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=missing
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$REVISES" -eq 2 ] && [ "$(_status b-api 1)" = "failed:AGENT_FAILED" ] && [ "$GATE_RC" -eq 0 ] &&
  jq -e '[.findings[] | select(.demote_reason == "failed")] | length == 1' "${DR}/b-api/semantic.json" >/dev/null; then
  pass "two spawns, then failed:AGENT_FAILED; demoted with reason failed"
else
  fail "retry fail" "revises=$REVISES st=$(_status b-api 1) rc=$GATE_RC"
fi
_setup INIT-L7b
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=missing-once
rm -f "${TMP_ROOT}/stub-once-b-api"
_gate
if [ "$REVISES" -eq 2 ] && [ "$(_status b-api 1)" = "applied" ] && [ ! -e "${DR}/b-api/revise.r2.status" ] && [ "$GATE_RC" -eq 0 ]; then
  pass "a retry that writes its result settles the same round"
else
  fail "retry ok" "revises=$REVISES st=$(_status b-api 1) $(_status b-api 2) rc=$GATE_RC"
fi

# ── 8. drift on revised units ────────────────────────────────────────────
echo "--- 8. new finding on a revised unit ---"
_setup INIT-L8
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=extend
export AFTER_b_api="SCOPE_AMBIGUOUS|Export responds with 200 for a finance user"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$GATE_RC" -eq 0 ] && [ "$(_status b-api 1)" = "applied" ] &&
  jq -e '[.findings[] | select(.code == "SCOPE_AMBIGUOUS" and .demoted == "round-limit" and .demote_reason == "revised")] | length == 1' \
    "${DR}/b-api/semantic.json" >/dev/null; then
  pass "a different code on the revised unit: round-limit / revised, not drift"
else
  fail "new gap" "rc=$GATE_RC $(jq -c .findings "${DR}/b-api/semantic.json")"
fi
_setup INIT-L8b
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
export REVISE_b_api=extend
export AFTER_b_api="EDGE_CASE_GAP|Export responds with 200 for a finance user"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=1 _gate
if [ "$GATE_RC" -eq 0 ] &&
  jq -e '[.findings[] | select(.code == "EDGE_CASE_GAP" and .demoted == "drift" and .demote_reason == "revised")] | length == 1' \
    "${DR}/b-api/semantic.json" >/dev/null &&
  _run_lines | grep -q '|META|draft-readiness|info|b-api DEMOTED EDGE_CASE_GAP drift revised '; then
  pass "the addressed code re-phrased on the same unit: drift / revised"
else
  fail "drift" "rc=$GATE_RC $(jq -c .findings "${DR}/b-api/semantic.json")"
fi

# ── 9. spawn budget ──────────────────────────────────────────────────────
echo "--- 9. spawn budget ---"
_setup INIT-L9
export FINDINGS_a_schema="EDGE_CASE_GAP|The Export button appears on the invoice list"
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
PLANNER_DRAFT_SPAWN_BUDGET=5 _gate
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 4 ] && [ "$REVISES" -eq 0 ] &&
  [ ! -e "${DR}/b-api/findings.r1.json" ] && [ ! -e "${PLANNER_DRAFT_SNAPSHOT_ROOT}/${INIT}/round" ] &&
  _run_lines | grep -q '|META|draft-readiness|fail|(run) SPAWN_BUDGET ' &&
  _run_lines | grep -q '|META|draft-readiness|done|blocked 2/2 SPAWN_BUDGET$'; then
  pass "the revise list (2) would exceed 5: halt before spawning, no round files"
else
  fail "budget" "rc=$GATE_RC spawns=$SPAWNS revises=$REVISES $(_run_lines | grep -E 'fail|done|warn')"
fi
report=$(planner_draft_readiness_report "$INIT")
printf '%s\n' "$report" | grep -q 'SPAWN_BUDGET' && pass "report shows SPAWN_BUDGET" || fail "budget report" "$report"
if ! (PLANNER_DRAFT_SPAWN_BUDGET=abc planner_draft_readiness_begin "$INIT" >/dev/null 2>&1); then
  pass "an invalid spawn budget is refused at gate start"
else
  fail "budget validate" "accepted"
fi

# ── 10. MAX_ROUNDS=0 and validation ──────────────────────────────────────
echo "--- 10. MAX_ROUNDS=0 is halt-only ---"
_setup INIT-L10
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with 200"
PLANNER_DRAFT_REVISE_MAX_ROUNDS=0 _gate
if [ "$GATE_RC" -eq 3 ] && [ "$REVISES" -eq 0 ] && [ "$SPAWNS" -eq 4 ] &&
  [ ! -e "${DR}/b-api/findings.r1.json" ] && ! grep -q '|META|draft-readiness|info|' "$LOG" &&
  _run_lines | grep -q '|META|draft-readiness|fail|b-api EDGE_CASE_GAP "Export responds with 200"'; then
  pass "no revision, no info line, halt on the fixable finding"
else
  fail "max0" "rc=$GATE_RC revises=$REVISES $(_run_lines | tail -3)"
fi
rc=0
PLANNER_DRAFT_REVISE_MAX_ROUNDS=x planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && pass "a non-integer MAX_ROUNDS is refused (rc 1)" || fail "max validate" "rc=$rc"

_loop_side_effects
_loop_finish
