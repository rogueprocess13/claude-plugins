#!/usr/bin/env bash
# test-board-cursor.sh — unit tests for lib/board-cursor.sh
# (tracker-event-board-pusher, Phase B2 Section 1)
# Usage: bash test-board-cursor.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
BC="$LIB_DIR/board-cursor.sh"

source "$BC"

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
  board_cursor_unlock 2>/dev/null || true
  rm -rf "$_ws" 2>/dev/null || true
  unset FLEET_PIPELINE_LOG_DIR
}

# ── 1.3 sequential single-writer advancement persists correctly ────────────
test_sequential_advancement_persists() {
  _setup
  board_cursor_lock T-1 linear
  board_cursor_advance T-1 linear 1
  board_cursor_unlock
  board_cursor_lock T-1 linear
  board_cursor_advance T-1 linear 2
  board_cursor_unlock
  local got
  got=$(board_cursor_get T-1 linear)
  _teardown
  [ "$got" = "2" ]
}

# ── 1.4 concurrent same-(tid,board) advancement serializes, no lost update ──
test_concurrent_same_pair_serializes() {
  _setup
  local i pids=()
  for i in $(seq 1 10); do
    (
      source "$BC"
      board_cursor_lock T-2 linear
      local cur
      cur=$(board_cursor_get T-2 linear)
      # A small window to make a real race likely if locking is broken.
      sleep 0.02
      board_cursor_advance T-2 linear "$((cur + 1))"
      board_cursor_unlock
    ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  local final
  final=$(board_cursor_get T-2 linear)
  _teardown
  [ "$final" -eq 10 ]
}

# ── 1.5 concurrent different-board advancement does not block/interfere ────
test_concurrent_different_boards_independent() {
  _setup
  board_cursor_lock T-3 linear
  board_cursor_advance T-3 linear 5
  # A separate board for the same ticket must be independently lockable
  # while the linear lock above is still held — proves the lock is scoped
  # per (tid, board_id), not per ticket.
  (
    source "$BC"
    board_cursor_lock T-3 jsonl-audit
    board_cursor_advance T-3 jsonl-audit 7
    board_cursor_unlock
  )
  board_cursor_unlock
  local a b
  a=$(board_cursor_get T-3 linear)
  b=$(board_cursor_get T-3 jsonl-audit)
  _teardown
  [ "$a" -eq 5 ] && [ "$b" -eq 7 ]
}

# ── 1.6 reading a never-written cursor returns seq 0 ────────────────────────
test_unwritten_cursor_returns_zero() {
  _setup
  local got
  got=$(board_cursor_get T-4 linear)
  _teardown
  [ "$got" = "0" ]
}

# ── 1.7 crash mid-write (kill between tmp write and mv) leaves the previous
# cursor value intact and readable — the tmp file is never mistaken for the
# live cursor. ────────────────────────────────────────────────────────────
test_crash_mid_write_leaves_previous_value() {
  _setup
  board_cursor_lock T-5 linear
  board_cursor_advance T-5 linear 3
  board_cursor_unlock

  # Simulate a crash mid-write: write a tmp file directly (as
  # board_cursor_advance would, just before its `mv`) and never move it
  # into place.
  local cursor_file="$_ws/.T-5-cursor-linear.json"
  local tmp="${cursor_file}.tmp.99999"
  echo '{"tid":"T-5","board_id":"linear","seq":999,"updated_at":"bogus"}' >"$tmp"

  local got
  got=$(board_cursor_get T-5 linear)
  local tmp_survives=false
  [ -f "$tmp" ] && tmp_survives=true
  rm -f "$tmp"
  _teardown
  [ "$got" = "3" ] && $tmp_survives
}

_run "1.3 sequential single-writer advancement persists" test_sequential_advancement_persists
_run "1.4 concurrent same-pair advancement serializes, no lost update" test_concurrent_same_pair_serializes
_run "1.5 concurrent different-board advancement is independent" test_concurrent_different_boards_independent
_run "1.6 unwritten cursor returns seq 0" test_unwritten_cursor_returns_zero
_run "1.7 crash mid-write leaves previous cursor value intact" test_crash_mid_write_leaves_previous_value

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
