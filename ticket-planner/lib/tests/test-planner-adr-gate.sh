#!/usr/bin/env bash
# test-planner-adr-gate.sh — Tests for planner-adr-gate.sh (adr-governance-gate)
#
# Run: bash ticket-planner/lib/tests/test-planner-adr-gate.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-adr-gate.sh"

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

INIT="INIT-adrgate"

# ── test: no adr-gate marker at all — not blocked ───────────────────────────
test_no_marker_not_blocked() {
  planner_state_init "$INIT" "test idea" >/dev/null
  planner_state_write "$INIT" "Architecture" "design" "start" "Evaluating technical approaches"

  if planner_adr_gate_blocked "$INIT" "Architecture" "design"; then
    fail "no_marker_not_blocked" "reported blocked with no adr-gate marker present"
  else
    pass "no_marker_not_blocked"
  fi
}

# ── test: a CREATED_PROPOSED marker after start is detected, verdict+id parsed ──
test_created_proposed_detected() {
  planner_state_write "$INIT" "META" "adr-gate" "fail" "CREATED_PROPOSED ADR_ID=ADR-0007"
  planner_state_write "$INIT" "Architecture" "design" "fail" "parked on ADR gate: CREATED_PROPOSED ADR-0007"

  local out
  if out=$(planner_adr_gate_blocked "$INIT" "Architecture" "design"); then
    local verdict adr_id
    verdict=$(echo "$out" | cut -f1)
    adr_id=$(echo "$out" | cut -f2)
    if [ "$verdict" = "CREATED_PROPOSED" ] && [ "$adr_id" = "ADR-0007" ]; then
      pass "created_proposed_detected"
    else
      fail "created_proposed_detected" "got verdict='$verdict' adr_id='$adr_id'"
    fi
  else
    fail "created_proposed_detected" "reported not blocked"
  fi
}

# ── test: scoped to the most recent attempt — a new start marker with no new
#          adr-gate line clears the block (resume after human ratification) ──
test_scoped_to_latest_attempt() {
  planner_state_write "$INIT" "Architecture" "design" "start" "Evaluating technical approaches (resume)"

  if planner_adr_gate_blocked "$INIT" "Architecture" "design"; then
    fail "scoped_to_latest_attempt" "reported blocked using a stale marker from a prior attempt"
  else
    pass "scoped_to_latest_attempt"
  fi
}

# ── test: GOVERNED/NOT_ARCHITECTURAL path never writes the fail marker —
#          an ordinary 'done' after start is not blocked ───────────────────
test_governed_path_not_blocked() {
  planner_state_write "$INIT" "Architecture" "design" "done" "Architecture decision: use existing pattern"

  if planner_adr_gate_blocked "$INIT" "Architecture" "design"; then
    fail "governed_path_not_blocked" "reported blocked on a clean done"
  else
    pass "governed_path_not_blocked"
  fi
}

# ── test: a CONFLICT verdict with no ADR_ID token still parses (empty adr_id
#          rather than crashing) — mirrors adr-gate-parse.sh's own tolerance ──
test_conflict_verdict_parses_without_crashing() {
  local init2="INIT-adrgate-conflict"
  planner_state_init "$init2" "conflict test" >/dev/null
  planner_state_write "$init2" "Architecture" "design" "start" "Evaluating technical approaches"
  planner_state_write "$init2" "META" "adr-gate" "fail" "CONFLICT ADR_ID=ADR-0002"

  local out
  if out=$(planner_adr_gate_blocked "$init2" "Architecture" "design"); then
    local verdict
    verdict=$(echo "$out" | cut -f1)
    if [ "$verdict" = "CONFLICT" ]; then
      pass "conflict_verdict_parses_without_crashing"
    else
      fail "conflict_verdict_parses_without_crashing" "got verdict='$verdict'"
    fi
  else
    fail "conflict_verdict_parses_without_crashing" "reported not blocked"
  fi
}

# ── test: no state log at all (never initialized) — not blocked, no crash ───
test_no_state_log_not_blocked() {
  if planner_adr_gate_blocked "INIT-never-existed" "Architecture" "design"; then
    fail "no_state_log_not_blocked" "reported blocked with no state log at all"
  else
    pass "no_state_log_not_blocked"
  fi
}

echo "=== planner-adr-gate.sh tests ==="
test_no_marker_not_blocked
test_created_proposed_detected
test_scoped_to_latest_attempt
test_governed_path_not_blocked
test_conflict_verdict_parses_without_crashing
test_no_state_log_not_blocked

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
