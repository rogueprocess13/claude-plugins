#!/usr/bin/env bash
# test-board-pusher-integration.sh — cross-runner parity, crash-safety, and
# second-driver integration tests (tracker-event-board-pusher, Phase B2,
# Sections 6 and 7). Exercises outbox-drain.sh (bash) and fleetd/pusher.py
# (Python) against the SAME outbox/cursor state, since the whole point of
# these tests is that the two runners agree — a mock of either would prove
# nothing about the real cross-language contract.
# Usage: bash test-board-pusher-integration.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
DRAIN="$LIB_DIR/../skills/ticket-flow/outbox-drain.sh"
EV="$LIB_DIR/events.sh"
BC="$LIB_DIR/board-cursor.sh"
FIXTURES_DRIVER_DIR="$LIB_DIR/tests/fixtures/board-drivers"
FLEETD_ROOT="$REPO_ROOT/fleet-controller"

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
_ddir=""

_setup() {
  _ws=$(mktemp -d)
  _ddir=$(mktemp -d)
  export FLEET_PIPELINE_LOG_DIR="$_ws"
  unset FLEET_GENERATION FLEET_STATE_DIR
}

_teardown() {
  rm -rf "$_ws" "$_ddir" 2>/dev/null || true
  unset FLEET_PIPELINE_LOG_DIR FLEET_GENERATION FLEET_STATE_DIR FLEET_BOARD_DRIVERS
}

_py_drain_ticket() {
  # _py_drain_ticket <tid> <log_dir> <driver_dir_override> <drivers_csv>
  local tid="$1" log_dir="$2" driver_dir="$3" drivers="$4"
  python3 -c "
import sys
sys.path.insert(0, '$FLEETD_ROOT')
from fleetd import pusher
drivers = '$drivers'.split(',') if '$drivers' else None
ok = pusher.drain_ticket('$tid', log_dir='$log_dir', lib_dir='$LIB_DIR',
                          driver_dir_override='$driver_dir' or None,
                          drivers=drivers)
sys.exit(0 if ok else 1)
"
}

# ── 6.1 fleetd-down parity: outbox-drain.sh drains part of a ticket's
# backlog (fleetd not running), then pusher.py drains the rest (fleetd
# starting up) — cursor state stays consistent across the handoff ─────────
test_fleetd_down_parity_handoff() {
  _setup
  emit_event T-1 gate-held '{"reason":"a"}' >/dev/null
  emit_event T-1 gate-released '{"provenance":"human"}' >/dev/null

  FLEET_BOARD_DRIVERS="linear" outbox_drain_ticket T-1 >/dev/null 2>&1
  local cursor_after_bash
  cursor_after_bash=$(board_cursor_get T-1 linear)

  emit_event T-1 human-hold-requested '{"question":"x"}' >/dev/null

  _py_drain_ticket T-1 "$_ws" "" "linear" >/dev/null 2>&1
  local py_rc=$?
  local cursor_after_py
  cursor_after_py=$(board_cursor_get T-1 linear)

  _teardown
  [ "$cursor_after_bash" -eq 2 ] && [ "$py_rc" -eq 0 ] && [ "$cursor_after_py" -eq 3 ]
}

# ── 6.2 a crash between a driver's successful apply and the cursor write
# does not lose the record — the next drain re-dispatches it, and the
# no-second-mutation requirement still holds because dispatch is
# idempotent ─────────────────────────────────────────────────────────────
test_crash_between_apply_and_cursor_write_redispatches_safely() {
  _setup
  emit_event T-2 gate-held '{"reason":"a"}' >/dev/null

  # Simulate the crash: the driver's own dispatch record exists (as if
  # apply already ran successfully), but the cursor was never advanced —
  # exactly the state a kill between the two steps would leave.
  FLEET_PIPELINE_LOG_DIR="$_ws" bash "$FIXTURES_DRIVER_DIR/jsonl-audit.sh" apply T-2 gate-held 1 '{"reason":"a"}' >/dev/null
  local cursor_before
  cursor_before=$(board_cursor_get T-2 jsonl-audit)

  # Next drain: re-dispatches seq 1 (cursor is still 0), but the driver's
  # own seq-keyed dedup means no second line is written.
  OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$FIXTURES_DRIVER_DIR" FLEET_BOARD_DRIVERS="jsonl-audit" outbox_drain_ticket T-2 >/dev/null 2>&1
  local rc=$?
  local cursor_after
  cursor_after=$(board_cursor_get T-2 jsonl-audit)
  local line_count
  line_count=$(wc -l <"$_ws/T-2-board-dispatch-jsonl-audit.jsonl")

  _teardown
  [ "$cursor_before" -eq 0 ] && [ "$rc" -eq 0 ] && [ "$cursor_after" -eq 1 ] && [ "$line_count" -eq 1 ]
}

# ── 6.3 pusher.py and outbox-drain.sh invoked concurrently against the
# same (tid, board_id) — exactly one advances the cursor past any given
# entry, neither double-dispatches ──────────────────────────────────────
test_concurrent_cross_runner_drain_no_double_dispatch() {
  _setup
  emit_event T-3 gate-held '{"reason":"a"}' >/dev/null
  emit_event T-3 gate-released '{"provenance":"human"}' >/dev/null
  emit_event T-3 human-hold-requested '{"question":"x"}' >/dev/null

  (FLEET_BOARD_DRIVERS="jsonl-audit" OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$FIXTURES_DRIVER_DIR" \
    bash -c "source '$DRAIN'; outbox_drain_ticket T-3" >/dev/null 2>&1) &
  local p1=$!
  (_py_drain_ticket T-3 "$_ws" "$FIXTURES_DRIVER_DIR" "jsonl-audit" >/dev/null 2>&1) &
  local p2=$!
  wait "$p1"
  wait "$p2"

  local cursor line_count uniq_seqs
  cursor=$(board_cursor_get T-3 jsonl-audit)
  line_count=$(wc -l <"$_ws/T-3-board-dispatch-jsonl-audit.jsonl")
  uniq_seqs=$(jq -r '.seq' "$_ws/T-3-board-dispatch-jsonl-audit.jsonl" | sort -n | uniq | wc -l)

  _teardown
  [ "$cursor" -eq 3 ] && [ "$line_count" -eq 3 ] && [ "$uniq_seqs" -eq 3 ]
}

# ── 7.1 two drivers configured together each receive every event
# independently, with independently-advancing cursors ─────────────────────
test_two_configured_drivers_each_receive_every_event() {
  _setup
  mkdir -p "$_ddir"
  # Only jsonl-audit is placed in the override dir — linear falls back to
  # its real production location (lib/board-drivers/linear.sh), since its
  # own BASH_SOURCE-anchored path resolution only works from there (see
  # _outbox_drain_driver_script's fallback rule).
  cp "$FIXTURES_DRIVER_DIR/jsonl-audit.sh" "$_ddir/jsonl-audit.sh"

  emit_event T-4 gate-held '{"reason":"a"}' >/dev/null
  emit_event T-4 gate-released '{"provenance":"human"}' >/dev/null

  OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$_ddir" FLEET_BOARD_DRIVERS="linear,jsonl-audit" outbox_drain_ticket T-4 >/dev/null 2>&1
  local rc=$?

  local linear_cursor audit_cursor audit_lines
  linear_cursor=$(board_cursor_get T-4 linear)
  audit_cursor=$(board_cursor_get T-4 jsonl-audit)
  audit_lines=$(wc -l <"$_ws/T-4-board-dispatch-jsonl-audit.jsonl")

  _teardown
  [ "$rc" -eq 0 ] && [ "$linear_cursor" -eq 2 ] && [ "$audit_cursor" -eq 2 ] && [ "$audit_lines" -eq 2 ]
}

# ── 7.2 one driver fails on an event while the other keeps succeeding —
# the failing driver's cursor stops and retries; the healthy driver's
# cursor keeps advancing, unaffected ────────────────────────────────────
test_one_driver_failure_does_not_stall_the_other() {
  _setup
  mkdir -p "$_ddir"
  cat >"$_ddir/linear.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Driver CLI contract: $1=apply $2=TID $3=EVENT $4=SEQ $5=JSON_DATA.
event="$3"
if [ "$event" = "gate-released" ]; then exit 1; else exit 0; fi
SCRIPT
  chmod +x "$_ddir/linear.sh"
  cp "$FIXTURES_DRIVER_DIR/jsonl-audit.sh" "$_ddir/jsonl-audit.sh"

  emit_event T-5 gate-held '{"reason":"a"}' >/dev/null
  emit_event T-5 gate-released '{"provenance":"human"}' >/dev/null
  emit_event T-5 blocked '{"by":[]}' >/dev/null

  OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$_ddir" FLEET_BOARD_DRIVERS="linear,jsonl-audit" outbox_drain_ticket T-5 >/dev/null 2>&1
  local rc=$?

  local linear_cursor audit_cursor
  linear_cursor=$(board_cursor_get T-5 linear)
  audit_cursor=$(board_cursor_get T-5 jsonl-audit)

  _teardown
  # linear.sh stopped at seq 1 (gate-held succeeded, gate-released failed);
  # jsonl-audit is a wholly independent driver and drained all 3.
  [ "$rc" -eq 1 ] && [ "$linear_cursor" -eq 1 ] && [ "$audit_cursor" -eq 3 ]
}

_run "6.1 fleetd-down parity: bash-then-python handoff is consistent" test_fleetd_down_parity_handoff
_run "6.2 crash between apply and cursor write re-dispatches safely" test_crash_between_apply_and_cursor_write_redispatches_safely
_run "6.3 concurrent cross-runner drain: no double-dispatch" test_concurrent_cross_runner_drain_no_double_dispatch
_run "7.1 two configured drivers each receive every event" test_two_configured_drivers_each_receive_every_event
_run "7.2 one driver's failure does not stall the other" test_one_driver_failure_does_not_stall_the_other

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
