#!/usr/bin/env bash
# test-planner-draft-readiness-gate-recover.sh — planner-draft-readiness slice
# S2b, scenarios 6–8 of the halt-only draft readiness gate. Split from
# test-planner-draft-readiness-gate.sh with the scenario bodies unchanged;
# shared setup and stubs live in draft-readiness-gate-harness.sh.
#
# Covers:
#   6. A blocked run followed by a spec edit re-runs Crosscheck; a blocking
#      Crosscheck halts with Crosscheck's report.
#   7. Two failed agent attempts make the verdict `unavailable` (blocks);
#      the next run retries it.
#   8. A removed spec loses its directory; --until Crosscheck skips the gate.
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-readiness-gate-recover.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/draft-readiness-gate-harness.sh"

echo "=== planner draft readiness gate (S2b): recover ==="

# Scenario 6 starts from a passed run whose b-api criterion reads
# "Export responds with HTTP 200 OK" (where scenario 5 left it).
_gate_prelude "HTTP 200 OK"

# ── 6. Crosscheck re-run blocks ──────────────────────────────────────────
echo "--- 6. spec edit after a blocked run: Crosscheck first ---"
sed -i 's/Export responds with HTTP 200 OK/Export responds with HTTP 200/' "${SPECS}/b-api.md"
export FINDINGS_b_api="EDGE_CASE_GAP|Export responds with HTTP 200"
_gate
unset FINDINGS_b_api
[ "$GATE_RC" -eq 3 ] && pass "blocked again (setup)" || fail "setup" "rc=$GATE_RC"
sed -i 's/Export responds with HTTP 200/Export responds with status 200/' "${SPECS}/b-api.md"
CROSSCHECK_RC=1
_gate
CROSSCHECK_RC=0
report=$(planner_draft_readiness_report "$INIT")
if [ "$GATE_RC" -eq 3 ] && [ "$SPAWNS" -eq 0 ] &&
  tail -1 "$LOG" | grep -q '|META|draft-readiness|done|blocked crosscheck$' &&
  grep -q 'CROSSCHECK REPORT' <<<"$report" &&
  [ "$(planner_draft_readiness_state "$INIT")" = "crosscheck" ]; then
  pass "Crosscheck blocks: halt with Crosscheck's report, no draft spawn"
else
  fail "crosscheck halt" "rc=$GATE_RC spawns=$SPAWNS $report"
fi

# ── 7. unavailable ───────────────────────────────────────────────────────
echo "--- 7. two failed attempts → unavailable ---"
export BROKEN_b_api=1
_gate
unset BROKEN_b_api
if [ "$GATE_RC" -eq 3 ] && [ "$(cut -d' ' -f3 "${DR}/b-api/verdict")" = "unavailable" ] &&
  tail -3 "$LOG" | grep -q '|META|draft-readiness|fail|b-api SEMANTIC_UNAVAILABLE' && [ "$SPAWNS" -eq 4 ]; then
  pass "unparseable twice: unavailable, blocks, after exactly one retry"
else
  fail "unavailable" "rc=$GATE_RC spawns=$SPAWNS $(cat "${DR}/b-api/verdict" 2>/dev/null) $(tail -3 "$LOG")"
fi
sed -i 's/Export responds with status 200/Export responds with status code 200/' "${SPECS}/b-api.md"
export MISSING_b_api=1
_gate
unset MISSING_b_api
if [ "$GATE_RC" -eq 3 ] && [ "$(cut -d' ' -f3 "${DR}/b-api/verdict")" = "unavailable" ] && [ "$SPAWNS" -eq 2 ]; then
  pass "no result file written twice: unavailable"
else
  fail "missing result" "rc=$GATE_RC spawns=$SPAWNS"
fi
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 2 ] && [ "$(cut -d' ' -f3 "${DR}/b-api/verdict")" = "ready" ]; then
  pass "the next run retries an unavailable draft (no edit needed)"
else
  fail "unavailable retry" "rc=$GATE_RC spawns=$SPAWNS"
fi

# ── 8. removed spec, --until Crosscheck ──────────────────────────────────
echo "--- 8. removed spec and --until Crosscheck ---"
rm -f "${SPECS}/b-api.md"
_gate
if [ ! -e "${DR}/b-api" ] && [ "$GATE_RC" -eq 0 ] && tail -1 "$LOG" | grep -q 'ready 1/1$'; then
  pass "a removed spec drops its directory; the rest passes"
else
  fail "removed spec" "rc=$GATE_RC $(ls "$DR") $(tail -1 "$LOG")"
fi
planner_stop_after_set "$INIT" "Crosscheck"
rc=0
planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ] && tail -1 "$LOG" | grep -q '|META|draft-readiness|skip|--until Crosscheck$'; then
  pass "--until Crosscheck skips the gate with a skip line"
else
  fail "until skip" "rc=$rc $(tail -1 "$LOG")"
fi
planner_stop_after_set "$INIT" ""

_gate_finish 7
