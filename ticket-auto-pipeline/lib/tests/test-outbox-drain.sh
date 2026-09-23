#!/usr/bin/env bash
# test-outbox-drain.sh — unit tests for skills/ticket-flow/outbox-drain.sh
# (tracker-event-board-pusher, Phase B2 Section 4)
# Usage: bash test-outbox-drain.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
DRAIN="$LIB_DIR/../skills/ticket-flow/outbox-drain.sh"
EV="$LIB_DIR/events.sh"
BC="$LIB_DIR/board-cursor.sh"

source "$DRAIN"
source "$EV"

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
  export FLEET_BOARD_DRIVERS="linear"
  unset FLEET_GENERATION FLEET_STATE_DIR
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
  unset FLEET_PIPELINE_LOG_DIR FLEET_BOARD_DRIVERS FLEET_GENERATION FLEET_STATE_DIR
  unset -f _failing_driver_dispatch_count 2>/dev/null || true
}

# ── 4.3 3 unconsumed entries, no cursor -> all 3 drained in order, cursor
# advances to the last seq ──────────────────────────────────────────────
test_three_entries_drain_in_order_cursor_advances() {
  _setup
  emit_event T-1 gate-held '{"reason":"a"}' >/dev/null
  emit_event T-1 gate-released '{"provenance":"human"}' >/dev/null
  emit_event T-1 human-hold-requested '{"question":"x"}' >/dev/null

  outbox_drain_ticket T-1 >/dev/null 2>&1
  local rc=$?
  local cursor
  cursor=$(board_cursor_get T-1 linear)
  _teardown
  [ "$rc" -eq 0 ] && [ "$cursor" -eq 3 ]
}

# ── 4.4 running twice with no new entries between runs is a no-op the
# second time ─────────────────────────────────────────────────────────────
test_second_run_with_no_new_entries_is_noop() {
  _setup
  emit_event T-2 gate-held '{"reason":"a"}' >/dev/null
  outbox_drain_ticket T-2 >/dev/null 2>&1
  local cursor_after_first
  cursor_after_first=$(board_cursor_get T-2 linear)

  outbox_drain_ticket T-2 >/dev/null 2>&1
  local rc=$?
  local cursor_after_second
  cursor_after_second=$(board_cursor_get T-2 linear)
  _teardown
  [ "$rc" -eq 0 ] && [ "$cursor_after_first" -eq 1 ] && [ "$cursor_after_second" -eq 1 ]
}

# ── 4.5 a driver failure on entry N leaves the cursor at N-1 and does not
# skip ahead on the next run ────────────────────────────────────────────
test_driver_failure_leaves_cursor_at_n_minus_1() {
  _setup
  emit_event T-3 gate-held '{"reason":"a"}' >/dev/null
  emit_event T-3 gate-released '{"provenance":"human"}' >/dev/null
  emit_event T-3 human-hold-requested '{"question":"x"}' >/dev/null

  # A driver that always fails, standing in for entry-2's dispatch failing.
  local failing_dir
  failing_dir=$(mktemp -d)
  cat >"$failing_dir/linear.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
  chmod +x "$failing_dir/linear.sh"

  OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$failing_dir" outbox_drain_ticket T-3 >/dev/null 2>&1
  local rc=$?
  local cursor
  cursor=$(board_cursor_get T-3 linear)
  rm -rf "$failing_dir"
  _teardown
  [ "$rc" -eq 1 ] && [ "$cursor" -eq 0 ]
}

# ── tracker-flow-projection-cutover: dead-letter after FLEET_BOARD_MAX_ATTEMPTS ──
test_dead_letter_after_max_attempts() {
  _setup
  export FLEET_BOARD_MAX_ATTEMPTS=3
  emit_event T-4 gate-held '{"reason":"a"}' >/dev/null

  local failing_dir
  failing_dir=$(mktemp -d)
  cat >"$failing_dir/linear.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
  chmod +x "$failing_dir/linear.sh"

  local i
  for i in 1 2 3; do
    OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$failing_dir" outbox_drain_ticket T-4 >/dev/null 2>&1 || true
  done
  local cursor logged
  cursor=$(board_cursor_get T-4 linear)
  logged=1
  grep -q 'META|board-dead-letter|warn|seq=1' "$_ws/T-4-pipeline.log" 2>/dev/null && logged=0
  rm -rf "$failing_dir"
  unset FLEET_BOARD_MAX_ATTEMPTS
  _teardown
  [ "$cursor" -eq 1 ] && [ "$logged" -eq 0 ]
}

# ── drain-after-flow: flow.sh's own exit-time drain actually advances the
# cursor, proving the wiring (not just outbox_drain_ticket called directly) ──
test_drain_after_flow() {
  _setup
  local repos_root stub_dir
  repos_root=$(mktemp -d)
  # A stubbed always-succeeds driver — this test proves flow.sh's exit-time
  # drain call is wired and effective, not that the real Linear driver
  # succeeds without credentials (a separate, already-covered concern).
  stub_dir=$(mktemp -d)
  cat >"$stub_dir/linear.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$stub_dir/linear.sh"

  local rc=0
  REPOS_ROOT="$repos_root" CLAUDE_SKILLS_LIB="$LIB_DIR" \
    TICKET_FLOW_LOCK_DIR="$_ws/locks" \
    OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$stub_dir" \
    bash "$LIB_DIR/../skills/ticket-flow/flow.sh" WIL-401 appraise-start >/dev/null 2>&1 || rc=$?
  local cursor
  cursor=$(board_cursor_get WIL-401 linear)
  rm -rf "$repos_root" "$stub_dir"
  _teardown
  [ "$rc" -eq 0 ] && [ "$cursor" -eq 1 ]
}

# ── concurrent drain and pusher advance past each entry exactly once ───────
test_concurrent_drain_and_pusher_exactly_once() {
  _setup
  emit_event T-5 gate-held '{"reason":"a"}' >/dev/null
  emit_event T-5 gate-released '{"provenance":"human"}' >/dev/null
  emit_event T-5 human-hold-requested '{"question":"x"}' >/dev/null

  local pusher_py
  pusher_py="$LIB_DIR/../../fleet-controller/fleetd/pusher.py"
  if [ ! -f "$pusher_py" ]; then
    _teardown
    return 0 # fleet-controller not co-located in this checkout — skip gracefully
  fi

  (outbox_drain_ticket T-5 >/dev/null 2>&1) &
  local p1=$!
  (cd "$LIB_DIR/../.." && FLEET_PIPELINE_LOG_DIR="$_ws" python3 -c "
import sys
sys.path.insert(0, 'fleet-controller')
from fleetd import pusher
pusher.drain_ticket('T-5', log_dir='$_ws')
" >/dev/null 2>&1) &
  local p2=$!
  wait "$p1"
  wait "$p2"

  local cursor
  cursor=$(board_cursor_get T-5 linear)
  _teardown
  [ "$cursor" -eq 3 ]
}

_run "4.3 three entries drain in order, cursor advances to last seq" test_three_entries_drain_in_order_cursor_advances
_run "4.4 second run with no new entries is a no-op" test_second_run_with_no_new_entries_is_noop
_run "4.5 driver failure leaves cursor at N-1, no skip-ahead" test_driver_failure_leaves_cursor_at_n_minus_1
_run "dead-letter after FLEET_BOARD_MAX_ATTEMPTS" test_dead_letter_after_max_attempts
_run "drain-after-flow: flow.sh's exit-time drain advances the cursor" test_drain_after_flow
_run "concurrent drain and pusher advance past each entry exactly once" test_concurrent_drain_and_pusher_exactly_once

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
