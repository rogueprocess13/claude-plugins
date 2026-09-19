#!/usr/bin/env bash
# test-events.sh — unit tests for lib/events.sh (tracker-event-vocabulary-and-emitter)
# Usage: bash test-events.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
EV="$LIB_DIR/events.sh"

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
  unset FLEET_GENERATION FLEET_STATE_DIR
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
  unset FLEET_PIPELINE_LOG_DIR FLEET_GENERATION FLEET_STATE_DIR
}

_outbox() { echo "$_ws/${1}-outbox.jsonl"; }

# ── 3.6 sequential emission -> consecutive seq ──────────────────────────────
test_sequential_seq_consecutive() {
  _setup
  emit_event "T-1" gate-held '{"reason":"complex-ticket"}' >/dev/null
  emit_event "T-1" gate-released '{"provenance":"human"}' >/dev/null
  emit_event "T-1" human-hold-requested '{"question":"x"}' >/dev/null
  local seqs
  seqs=$(jq -r '.seq' "$(_outbox T-1)" | tr '\n' ',')
  _teardown
  [ "$seqs" = "1,2,3," ]
}

# ── 3.7 concurrent same-ticket emission serializes, no gap/collision ────────
test_concurrent_same_ticket_no_collision() {
  _setup
  local i pids=()
  for i in $(seq 1 10); do
    (emit_event "T-2" gate-held '{"reason":"x"}' >/dev/null 2>&1) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  local count uniq_count
  count=$(wc -l <"$(_outbox T-2)")
  uniq_count=$(jq -r '.seq' "$(_outbox T-2)" | sort -n | uniq | wc -l)
  local max_seq
  max_seq=$(jq -r '.seq' "$(_outbox T-2)" | sort -n | tail -1)
  _teardown
  [ "$count" -eq 10 ] && [ "$uniq_count" -eq 10 ] && [ "$max_seq" -eq 10 ]
}

# ── 3.8 concurrent different-ticket emission does not block ─────────────────
test_concurrent_different_tickets_independent() {
  _setup
  emit_event "T-3" gate-held '{"reason":"a"}' >/dev/null &
  local p1=$!
  emit_event "T-4" gate-held '{"reason":"b"}' >/dev/null &
  local p2=$!
  wait "$p1"
  wait "$p2"
  local ok=true
  [ -f "$(_outbox T-3)" ] || ok=false
  [ -f "$(_outbox T-4)" ] || ok=false
  [ "$(jq -r '.seq' "$(_outbox T-3)")" = "1" ] || ok=false
  [ "$(jq -r '.seq' "$(_outbox T-4)")" = "1" ] || ok=false
  _teardown
  $ok
}

# ── 3.9 stale-generation rejected, current-generation succeeds ─────────────
test_stale_generation_rejected_current_succeeds() {
  _setup
  mkdir -p "$_ws/state"
  jq -n '{fenced_generation: 5}' >"$_ws/state/T-5-fence"
  export FLEET_STATE_DIR="$_ws/state"

  set +e
  FLEET_GENERATION=5 emit_event "T-5" gate-held '{"reason":"x"}' >/dev/null 2>&1
  local rc_stale=$?
  set -e
  local wrote_on_stale=false
  [ -f "$(_outbox T-5)" ] && wrote_on_stale=true

  FLEET_GENERATION=6 emit_event "T-5" gate-held '{"reason":"x"}' >/dev/null
  local rc_current=$?
  local wrote_on_current=false
  [ -f "$(_outbox T-5)" ] && [ "$(wc -l <"$(_outbox T-5)")" -eq 1 ] && wrote_on_current=true

  _teardown
  [ "$rc_stale" -eq 10 ] && ! $wrote_on_stale && [ "$rc_current" -eq 0 ] && $wrote_on_current
}

# ── 3.10 a `|`-containing data value round-trips ────────────────────────────
test_pipe_character_round_trips() {
  _setup
  local data
  data=$(jq -nc --arg q "does this | break it?" '{question: $q}')
  emit_event "T-6" human-hold-requested "$data" >/dev/null
  local read_back
  read_back=$(jq -r '.data.question' "$(_outbox T-6)")
  _teardown
  [ "$read_back" = "does this | break it?" ]
}

# ── 3.11 undeclared event name is rejected ──────────────────────────────────
test_undeclared_event_rejected() {
  _setup
  set +e
  emit_event "T-7" this-event-does-not-exist '{}' >/dev/null 2>&1
  local rc=$?
  set -e
  local wrote=false
  [ -f "$(_outbox T-7)" ] && wrote=true
  _teardown
  [ "$rc" -eq 3 ] && ! $wrote
}

# ── record shape: exactly the 7 declared keys, no position/column field ────
test_record_shape_is_closed() {
  _setup
  emit_event "T-8" gate-held '{"reason":"x"}' >/dev/null
  local keys
  keys=$(jq -c '. | keys | sort' "$(_outbox T-8)")
  _teardown
  [ "$keys" = '["data","event","from_hint","gen","seq","tid","ts"]' ]
}

# ── missing args / invalid JSON -> usage error (2), no write ────────────────
test_usage_errors() {
  _setup
  set +e
  emit_event "" gate-held '{}' >/dev/null 2>&1
  local rc1=$?
  emit_event "T-9" "" '{}' >/dev/null 2>&1
  local rc2=$?
  emit_event "T-9" gate-held 'not json' >/dev/null 2>&1
  local rc3=$?
  set -e
  local wrote=false
  [ -f "$(_outbox T-9)" ] && wrote=true
  _teardown
  [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ] && [ "$rc3" -eq 2 ] && ! $wrote
}

_run "3.6 sequential emission -> consecutive seq" test_sequential_seq_consecutive
_run "3.7 concurrent same-ticket -> no gap/collision" test_concurrent_same_ticket_no_collision
_run "3.8 concurrent different tickets -> independent" test_concurrent_different_tickets_independent
_run "3.9 stale generation rejected, current succeeds" test_stale_generation_rejected_current_succeeds
_run "3.10 pipe character in data round-trips" test_pipe_character_round_trips
_run "3.11 undeclared event name rejected" test_undeclared_event_rejected
_run "record shape is exactly the 7 declared keys" test_record_shape_is_closed
_run "usage errors reject without writing" test_usage_errors

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
