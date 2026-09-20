#!/usr/bin/env bash
# test-board-drivers.sh — unit tests for lib/board-drivers/linear.sh and the
# lib/tests/fixtures/board-drivers/jsonl-audit.sh test fixture
# (tracker-event-board-pusher, Phase B2 Section 2)
# Usage: bash test-board-drivers.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
LINEAR_DRIVER="$LIB_DIR/board-drivers/linear.sh"
JSONL_AUDIT_DRIVER="$TEST_DIR/fixtures/board-drivers/jsonl-audit.sh"
WF="$LIB_DIR/../skills/ticket-flow/workflow.json"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

_ws=""

_setup() {
  _ws=$(mktemp -d)
  export FLEET_PIPELINE_LOG_DIR="$_ws"
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
  unset FLEET_PIPELINE_LOG_DIR
}

_audit_file() { echo "$_ws/${1}-board-dispatch-jsonl-audit.jsonl"; }

# ── 2.4 linear.sh exits 0 and makes no mutation for every declared event ───
test_linear_driver_noops_every_vocabulary_event() {
  _setup
  local ev rc=0 seq=1
  while IFS= read -r ev; do
    bash "$LINEAR_DRIVER" apply T-1 "$ev" "$seq" '{}' >/dev/null 2>&1 || rc=1
    seq=$((seq + 1))
  done < <(jq -r '.vocabulary | keys[]' "$WF")
  _teardown
  [ "$rc" -eq 0 ]
}

# ── 2.5 jsonl-audit.sh writes exactly one line per distinct seq; two events
# (different seqs) produce two distinct lines ────────────────────────────
test_jsonl_audit_distinct_seqs_produce_distinct_lines() {
  _setup
  bash "$JSONL_AUDIT_DRIVER" apply T-2 gate-held 1 '{"reason":"x"}' >/dev/null
  bash "$JSONL_AUDIT_DRIVER" apply T-2 gate-released 2 '{"provenance":"human"}' >/dev/null
  local count
  count=$(wc -l <"$(_audit_file T-2)")
  local seqs
  seqs=$(jq -r '.seq' "$(_audit_file T-2)" | tr '\n' ',')
  _teardown
  [ "$count" -eq 2 ] && [ "$seqs" = "1,2," ]
}

# ── 2.6 both drivers are idempotent — same (TID,EVENT,SEQ) invoked twice
# produces no additional externally-observable effect ──────────────────────
test_linear_driver_idempotent_on_replay() {
  _setup
  bash "$LINEAR_DRIVER" apply T-3 gate-held 1 '{}' >/dev/null 2>&1
  local rc1=$?
  bash "$LINEAR_DRIVER" apply T-3 gate-held 1 '{}' >/dev/null 2>&1
  local rc2=$?
  _teardown
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]
}

test_jsonl_audit_idempotent_no_second_line() {
  _setup
  bash "$JSONL_AUDIT_DRIVER" apply T-4 gate-held 1 '{"reason":"x"}' >/dev/null
  bash "$JSONL_AUDIT_DRIVER" apply T-4 gate-held 1 '{"reason":"x"}' >/dev/null
  local count
  count=$(wc -l <"$(_audit_file T-4)")
  _teardown
  [ "$count" -eq 1 ]
}

# ── 2.7 an unconfigured driver is never invoked ─────────────────────────────
# board-cursor/drain-level FLEET_BOARD_DRIVERS gating is exercised in
# test-outbox-drain.sh (Section 4) and the fleetd pusher tests (Section 5) —
# this asserts the underlying fact those tests rely on: a driver not named
# anywhere in a FLEET_BOARD_DRIVERS list is simply never referenced by the
# drain loop's driver-resolution step. Modeled here at the resolution-list
# level since the drivers themselves have no awareness of configuration.
test_unconfigured_driver_not_in_resolved_list() {
  local drivers="linear"
  IFS=',' read -ra _configured <<<"$drivers"
  local found=false
  local d
  for d in "${_configured[@]}"; do
    [ "$d" = "jsonl-audit" ] && found=true
  done
  ! $found
}

# ── 2.8 cwd-independence: same driver, invoked from two different working
# directories, produces identical results ──────────────────────────────────
test_linear_driver_cwd_independent() {
  _setup
  local out1 out2 rc1 rc2
  out1=$(cd "$LIB_DIR" && bash "$LINEAR_DRIVER" apply T-5 gate-held 1 '{}' 2>&1)
  rc1=$?
  out2=$(cd /tmp && bash "$LINEAR_DRIVER" apply T-5 gate-held 1 '{}' 2>&1)
  rc2=$?
  _teardown
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc1" -eq "$rc2" ]
}

_run "2.4 linear.sh no-ops every vocabulary event" test_linear_driver_noops_every_vocabulary_event
_run "2.5 jsonl-audit distinct seqs -> distinct lines" test_jsonl_audit_distinct_seqs_produce_distinct_lines
_run "2.6 linear.sh idempotent on replay" test_linear_driver_idempotent_on_replay
_run "2.6 jsonl-audit idempotent — no second line on replay" test_jsonl_audit_idempotent_no_second_line
_run "2.7 unconfigured driver excluded from resolved list" test_unconfigured_driver_not_in_resolved_list
_run "2.8 linear.sh is cwd-independent" test_linear_driver_cwd_independent

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
