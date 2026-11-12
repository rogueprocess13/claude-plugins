#!/usr/bin/env bash
# test-board-cursor-fastforward.sh — proves the migration ordering itself
# (tracker-flow-projection-cutover task 10.2a): a fixture ticket with a
# legacy multi-entry outbox and no cursor, plus a counting stub driver.
# Since board-cursor-first-drain the fast-forward is optional: case (a)
# proves a drain without it replays nothing.
#
# The evidence is the driver's INVOCATION COUNT, not the final cursor
# value or column — a replay that ends on the correct cursor position
# still dispatched every historical entry along the way, which is exactly
# the hazard the fast-forward step exists to prevent.
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
FF_SH="$LIB_DIR/../skills/ticket-flow/board-cursor-fastforward.sh"
EV="$LIB_DIR/events.sh"

source "$FF_SH"
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
_driver_dir=""

_setup() {
  _ws=$(mktemp -d)
  export FLEET_PIPELINE_LOG_DIR="$_ws"
  export FLEET_BOARD_DRIVERS="counting"
  unset FLEET_GENERATION FLEET_STATE_DIR

  _driver_dir=$(mktemp -d)
  cat >"$_driver_dir/counting.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Counting stub driver — appends one line per dispatch, never fails.
echo "$1 $2 $3 $4" >>"${COUNTING_DRIVER_LOG}"
exit 0
SCRIPT
  chmod +x "$_driver_dir/counting.sh"
}

_teardown() {
  rm -rf "$_ws" "$_driver_dir" 2>/dev/null || true
  unset FLEET_PIPELINE_LOG_DIR FLEET_BOARD_DRIVERS FLEET_GENERATION FLEET_STATE_DIR COUNTING_DRIVER_LOG
}

_seed_outbox() {
  # A legacy 3-entry outbox for T-1, no cursor: written before projection
  # existed (< 0.55.0), so it has no origin sidecar. Written directly, not
  # through emit_event, which would write a `new` sidecar.
  _seed_legacy_n T-1 3
}

_seed_legacy_n() {
  local tid="$1" n="$2" i
  for i in $(seq 1 "$n"); do
    printf '{"seq":%d,"tid":"%s","ts":"2026-01-01T00:00:00Z","gen":0,"event":"gate-held","data":{"reason":"a"},"from_hint":null,"idem":null}\n' \
      "$i" "$tid" >>"$_ws/${tid}-outbox.jsonl"
  done
}

_drain_tid() {
  OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$_driver_dir" \
    bash "$LIB_DIR/../skills/ticket-flow/outbox-drain.sh" "$1" >/dev/null 2>&1 || true
}

_drain() {
  export COUNTING_DRIVER_LOG="$_ws/counting-calls.log"
  : >"$COUNTING_DRIVER_LOG"
  OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$_driver_dir" \
    bash "$LIB_DIR/../skills/ticket-flow/outbox-drain.sh" T-1 >/dev/null 2>&1 || true
}

# (a) drain with no fast-forward → the stub records zero. Before
# board-cursor-first-drain a missing cursor read as 0 and this replayed every
# historical entry; a legacy outbox with no origin sidecar now starts at its
# tail, so fast-forward is optional.
test_no_fastforward_replays_nothing() {
  _setup
  _seed_outbox
  _drain
  local count
  count=$(wc -l <"$COUNTING_DRIVER_LOG" 2>/dev/null || echo 0)
  _teardown
  [ "$count" -eq 0 ]
}

# A new ticket (emit_event writes a `new` sidecar): two emit+drain rounds, the
# way flow.sh emits then drains at exit, dispatch both events.
test_new_ticket_projects_every_event() {
  _setup
  export COUNTING_DRIVER_LOG="$_ws/counting-calls.log"
  : >"$COUNTING_DRIVER_LOG"
  emit_event T-N gate-held '{"reason":"a"}' >/dev/null
  _drain_tid T-N
  emit_event T-N gate-released '{"provenance":"human"}' >/dev/null
  _drain_tid T-N
  local seqs
  seqs=$(awk '{print $4}' "$COUNTING_DRIVER_LOG" | tr '\n' ,)
  _teardown
  [ "$seqs" = "1,2," ]
}

# A legacy ticket with 6 records gets one new event: exactly that one is
# dispatched, none of the history.
test_legacy_ticket_projects_only_new_event() {
  _setup
  export COUNTING_DRIVER_LOG="$_ws/counting-calls.log"
  : >"$COUNTING_DRIVER_LOG"
  _seed_legacy_n T-L 6
  emit_event T-L gate-released '{"provenance":"human"}' >/dev/null
  _drain_tid T-L
  local seqs sidecar
  seqs=$(awk '{print $4}' "$COUNTING_DRIVER_LOG" | tr '\n' ,)
  sidecar=$(jq -c '[.origin_seq, .kind]' "$_ws/.T-L-outbox-origin.json")
  _teardown
  [ "$seqs" = "7," ] && [ "$sidecar" = '[6,"legacy"]' ]
}

# (b) fast-forward, then drain → the stub records zero.
test_fastforward_then_drain_records_zero() {
  _setup
  _seed_outbox
  board_cursor_fastforward_sweep >/dev/null
  _drain
  local count
  count=$(wc -l <"$COUNTING_DRIVER_LOG" 2>/dev/null || echo 0)
  _teardown
  [ "$count" -eq 0 ]
}

# (c) fast-forward twice → the second run advances nothing.
test_fastforward_twice_second_run_advances_nothing() {
  _setup
  _seed_outbox
  local out2
  board_cursor_fastforward_sweep >/dev/null
  out2=$(board_cursor_fastforward_sweep)
  local advanced_line
  advanced_line=$(echo "$out2" | grep '^SUMMARY' | grep -o 'advanced=[0-9]*')
  _teardown
  [ "$advanced_line" = "advanced=0" ]
}

# (d) --dry-run writes no cursor file.
test_dry_run_writes_no_cursor_file() {
  _setup
  _seed_outbox
  board_cursor_fastforward_sweep --dry-run >/dev/null
  local exists=1
  [ -f "$_ws/.T-1-cursor-counting.json" ] && exists=0
  _teardown
  [ "$exists" -eq 1 ]
}

# A ticket whose outbox is already drained (cursor already at the tail) is
# left unchanged — reported SKIPPED, not ADVANCED.
test_already_drained_ticket_is_skipped() {
  _setup
  _seed_outbox
  board_cursor_fastforward_sweep >/dev/null # first pass: advances to seq 3
  local out
  out=$(board_cursor_fastforward_sweep)
  _teardown
  grep -q '^SKIPPED T-1 counting already at 3$' <<<"$out"
}

_run "(a) no fast-forward: a legacy outbox replays nothing" test_no_fastforward_replays_nothing
_run "new ticket: two emit+drain rounds dispatch both events" test_new_ticket_projects_every_event
_run "legacy ticket: one new event, exactly one dispatch" test_legacy_ticket_projects_only_new_event
_run "(b) fast-forward then drain records zero dispatches" test_fastforward_then_drain_records_zero
_run "(c) fast-forward twice: second run advances nothing" test_fastforward_twice_second_run_advances_nothing
_run "(d) --dry-run writes no cursor file" test_dry_run_writes_no_cursor_file
_run "an already-drained ticket is skipped, not advanced" test_already_drained_ticket_is_skipped

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
