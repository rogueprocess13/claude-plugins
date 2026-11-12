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

# ── record shape: exactly the 8 declared keys, no position/column field ────
test_record_shape_is_closed() {
  _setup
  emit_event "T-8" gate-held '{"reason":"x"}' >/dev/null
  local keys idem
  keys=$(jq -c '. | keys | sort' "$(_outbox T-8)")
  idem=$(jq -r '.idem' "$(_outbox T-8)")
  _teardown
  [ "$keys" = '["data","event","from_hint","gen","idem","seq","tid","ts"]' ] && [ "$idem" = "null" ]
}

# ── tracker-flow-projection-cutover: --idem KEY dedup ───────────────────────
test_idem_same_key_appends_once() {
  _setup
  emit_event --idem "T-10:1" "T-10" gate-held '{"reason":"a"}' >/dev/null
  local rc1=$?
  emit_event --idem "T-10:1" "T-10" gate-held '{"reason":"a"}' >/dev/null
  local rc2=$?
  local count
  count=$(wc -l <"$(_outbox T-10)")
  _teardown
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$count" -eq 1 ]
}

test_idem_distinct_keys_append_two_consecutive_seqs() {
  _setup
  emit_event --idem "T-11:1" "T-11" gate-held '{"reason":"a"}' >/dev/null
  emit_event --idem "T-11:2" "T-11" gate-released '{"provenance":"human"}' >/dev/null
  local seqs
  seqs=$(jq -r '.seq' "$(_outbox T-11)" | tr '\n' ',')
  _teardown
  [ "$seqs" = "1,2," ]
}

test_idem_suppressed_append_does_not_advance_seq() {
  _setup
  emit_event --idem "T-12:1" "T-12" gate-held '{"reason":"a"}' >/dev/null
  emit_event --idem "T-12:1" "T-12" gate-held '{"reason":"a"}' >/dev/null
  emit_event --idem "T-12:2" "T-12" gate-released '{"provenance":"human"}' >/dev/null
  local seqs
  seqs=$(jq -r '.seq' "$(_outbox T-12)" | tr '\n' ',')
  _teardown
  [ "$seqs" = "1,2," ]
}

test_idem_concurrent_same_key_appends_exactly_once() {
  _setup
  local i pids=()
  for i in $(seq 1 10); do
    (emit_event --idem "T-13:1" "T-13" gate-held '{"reason":"x"}' >/dev/null 2>&1) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  local count
  count=$(wc -l <"$(_outbox T-13)")
  _teardown
  [ "$count" -eq 1 ]
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

# ── sourcing events.sh must not mutate the caller's shell flags ────────────
# events.sh is sourced unconditionally at file scope by epic-branch.sh and
# fleet-intervene.sh, both of which are themselves sourced by
# fleet-monitor.sh — a leaked -e/pipefail there breaks the whole monitor
# loop, exactly the class of bug fleet-dispatch.sh already works around for
# linear-api.sh.
test_sourcing_does_not_leak_shell_flags() {
  bash -c "
    source '$EV' >/dev/null 2>&1
    case \$- in
      *e*) exit 1 ;;
    esac
    case \$(set +o | grep -w pipefail) in
      'set +o pipefail') ;;
      *) exit 1 ;;
    esac
    exit 0
  "
}

# ── torn outbox line (review ARCH-10 / QA-7 / BE-5) ─────────────────────────
# A partial last line (disk full, kill mid-write) used to: glue the next
# record onto it (no newline), restart seq at 1 (tail hit invalid JSON), and
# disable idem dedup (jq over the whole file exits non-zero at the parse
# error). The drains skip seq <= cursor, so every later event was lost.
_torn_outbox() {
  local f
  f=$(_outbox "$1")
  printf '%s\n' \
    '{"seq":4,"tid":"'"$1"'","ts":"2026-01-01T00:00:00Z","gen":0,"event":"gate-held","data":{},"from_hint":null,"idem":"k1"}' \
    '{"seq":5,"tid":"'"$1"'","ts":"2026-01-01T00:00:00Z","gen":0,"event":"gate-held","data":{},"from_hint":null,"idem":null}' >"$f"
  printf '%s' '{"seq":6,"tid":"'"$1"'","ev' >>"$f"
}

test_torn_line_next_seq_is_max_plus_one() {
  _setup
  _torn_outbox T-9
  emit_event "T-9" gate-released '{"provenance":"human"}' >/dev/null 2>&1
  local rc=$? last
  # The new record must be on its own line and parse.
  last=$(tail -n 1 "$(_outbox T-9)" | jq -r '"\(.seq) \(.event)"' 2>/dev/null)
  _teardown
  [ "$rc" -eq 0 ] && [ "$last" = "6 gate-released" ]
}

test_torn_line_idem_still_dedups() {
  _setup
  _torn_outbox T-9
  emit_event --idem k1 "T-9" gate-held '{}' >/dev/null 2>&1
  local rc=$? count
  count=$(grep -c '"idem":"k1"' "$(_outbox T-9)")
  _teardown
  [ "$rc" -eq 0 ] && [ "$count" -eq 1 ]
}

_run "sourcing events.sh does not leak -e/pipefail" test_sourcing_does_not_leak_shell_flags
_run "torn last line: next record gets max(seq)+1 on its own line" test_torn_line_next_seq_is_max_plus_one
_run "torn last line: idem dedup still works" test_torn_line_idem_still_dedups
_run "3.6 sequential emission -> consecutive seq" test_sequential_seq_consecutive
_run "3.7 concurrent same-ticket -> no gap/collision" test_concurrent_same_ticket_no_collision
_run "3.8 concurrent different tickets -> independent" test_concurrent_different_tickets_independent
_run "3.9 stale generation rejected, current succeeds" test_stale_generation_rejected_current_succeeds
_run "3.10 pipe character in data round-trips" test_pipe_character_round_trips
_run "3.11 undeclared event name rejected" test_undeclared_event_rejected
_run "record shape is exactly the 8 declared keys" test_record_shape_is_closed
_run "usage errors reject without writing" test_usage_errors
_run "idem: same key appends once, both calls exit 0" test_idem_same_key_appends_once
_run "idem: distinct keys append two consecutive seqs" test_idem_distinct_keys_append_two_consecutive_seqs
_run "idem: suppressed append does not advance seq" test_idem_suppressed_append_does_not_advance_seq
_run "idem: concurrent same-key emission appends exactly once" test_idem_concurrent_same_key_appends_exactly_once

# ── origin sidecar (board-cursor-first-drain, review ARCH-9) ───────────────
_origin() { echo "$_ws/.${1}-outbox-origin.json"; }

# A legacy outbox: records written before projection existed, no sidecar.
_seed_legacy() {
  local tid="$1" n="$2" i
  for i in $(seq 1 "$n"); do
    printf '{"seq":%d,"tid":"%s","ts":"2026-01-01T00:00:00Z","gen":0,"event":"gate-held","data":{},"from_hint":null,"idem":null}\n' \
      "$i" "$tid" >>"$(_outbox "$tid")"
  done
}

test_origin_new_outbox_is_new_zero() {
  _setup
  emit_event T-O1 gate-held '{}' >/dev/null
  local got
  got=$(jq -c '[.origin_seq, .kind, .tid]' "$(_origin T-O1)" 2>/dev/null)
  _teardown
  [ "$got" = '[0,"new","T-O1"]' ]
}

test_origin_legacy_outbox_is_tail() {
  _setup
  _seed_legacy T-O2 5
  printf '{"seq":6,"tid":"T-O2","ev' >>"$(_outbox T-O2)" # torn last line
  emit_event T-O2 gate-held '{}' >/dev/null
  local got
  got=$(jq -c '[.origin_seq, .kind]' "$(_origin T-O2)" 2>/dev/null)
  _teardown
  [ "$got" = '[5,"legacy"]' ]
}

test_origin_not_rewritten_by_later_emit() {
  _setup
  emit_event T-O3 gate-held '{}' >/dev/null
  local before after
  before=$(cat "$(_origin T-O3)")
  sleep 1
  emit_event T-O3 gate-released '{"provenance":"human"}' >/dev/null
  after=$(cat "$(_origin T-O3)")
  _teardown
  [ -n "$before" ] && [ "$before" = "$after" ]
}

test_origin_not_written_by_idem_dropped_emit() {
  _setup
  _seed_legacy T-O4 2
  # Record 2 carries idem k; re-emitting k is dropped, so no sidecar.
  jq -c 'if .seq == 2 then .idem = "k" else . end' "$(_outbox T-O4)" >"$_ws/t" &&
    mv "$_ws/t" "$(_outbox T-O4)"
  emit_event --idem k T-O4 gate-held '{}' >/dev/null
  local rc=0
  [ ! -e "$(_origin T-O4)" ] || rc=1
  _teardown
  return $rc
}

test_origin_reset_when_outbox_missing() {
  _setup
  printf '{"tid":"T-O5","origin_seq":7,"created_at":"x","kind":"legacy"}' >"$(_origin T-O5)"
  emit_event T-O5 gate-held '{}' >/dev/null
  local got
  got=$(jq -c '[.origin_seq, .kind]' "$(_origin T-O5)" 2>/dev/null)
  _teardown
  [ "$got" = '[0,"new"]' ]
}

test_origin_write_failure_does_not_block_append() {
  _setup
  # A directory squatting on the sidecar path makes the mv fail.
  mkdir -p "$(_origin T-O6)/x"
  local rc=0
  emit_event T-O6 gate-held '{}' >/dev/null 2>"$_ws/err" || rc=1
  local n
  n=$(wc -l <"$(_outbox T-O6)" 2>/dev/null || echo 0)
  grep -q "origin sidecar" "$_ws/err" || rc=1
  _teardown
  [ "$rc" -eq 0 ] && [ "$n" -eq 1 ]
}

_run "origin: a new outbox gets new/0" test_origin_new_outbox_is_new_zero
_run "origin: a legacy outbox gets legacy/max seq, torn line ignored" test_origin_legacy_outbox_is_tail
_run "origin: a later emit does not rewrite it" test_origin_not_rewritten_by_later_emit
_run "origin: an idem-dropped emit writes none" test_origin_not_written_by_idem_dropped_emit
_run "origin: reset to new/0 when the outbox is gone" test_origin_reset_when_outbox_missing
_run "origin: a write failure still appends, warns on stderr" test_origin_write_failure_does_not_block_append

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
