#!/usr/bin/env bash
# test-fleet-detect-outbox-staleness.sh — unit tests for detect_outbox_staleness
# (tracker-event-board-pusher, Phase B2 Section 8)
# Usage: bash test-fleet-detect-outbox-staleness.sh [test_name_filter]
set -e pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

source "$LIB_DIR/fleet-detect.sh"

_setup_workspace() {
  mktemp -d
}

_outbox_entry() {
  local ws="$1" tid="$2" seq="$3" event="$4" ts="$5"
  mkdir -p "$ws"
  jq -nc --argjson seq "$seq" --arg tid "$tid" --arg ts "$ts" \
    --arg event "$event" \
    '{seq: $seq, tid: $tid, ts: $ts, gen: 0, event: $event, data: {}, from_hint: null}' \
    >>"${ws}/${tid}-outbox.jsonl"
}

_write_cursor() {
  local ws="$1" tid="$2" board="$3" seq="$4"
  jq -nc --arg tid "$tid" --arg board "$board" --argjson seq "$seq" \
    --arg updated_at "2026-01-01T00:00:00Z" \
    '{tid: $tid, board_id: $board, seq: $seq, updated_at: $updated_at}' \
    >"${ws}/.${tid}-cursor-${board}.json"
}

# ── 8.3 a ticket with a long-undrained entry is flagged at severity 1 ──────
test_stale_undrained_entry_flags_severity_1() {
  local ws
  ws=$(_setup_workspace)
  # Ancient timestamp -> guaranteed to exceed any sane threshold.
  _outbox_entry "$ws" "CRE-1" 1 "gate-held" "2020-01-01T00:00:00Z"
  # No cursor file at all — cursor defaults to 0, entry is unconsumed.

  local sev
  sev=$(FLEET_OUTBOX_STALE_THRESHOLD_SECS=3600 detect_outbox_staleness "CRE-1" "$ws")
  rm -rf "$ws"
  [ "$sev" = "1" ]
}

# ── 8.4 a fully-drained ticket (cursor at or past latest seq, for every
# configured board) is not flagged ──────────────────────────────────────
test_fully_drained_ticket_not_flagged() {
  local ws
  ws=$(_setup_workspace)
  _outbox_entry "$ws" "CRE-2" 1 "gate-held" "2020-01-01T00:00:00Z"
  _outbox_entry "$ws" "CRE-2" 2 "gate-released" "2020-01-01T00:01:00Z"
  _write_cursor "$ws" "CRE-2" "linear" 2

  local sev
  sev=$(FLEET_OUTBOX_STALE_THRESHOLD_SECS=3600 detect_outbox_staleness "CRE-2" "$ws")
  rm -rf "$ws"
  [ "$sev" = "0" ]
}

# A recent entry, well under threshold, is also not flagged — the young
# sibling of the fully-drained case above.
test_recent_undrained_entry_not_flagged() {
  local ws
  ws=$(_setup_workspace)
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _outbox_entry "$ws" "CRE-3" 1 "gate-held" "$now_iso"

  local sev
  sev=$(FLEET_OUTBOX_STALE_THRESHOLD_SECS=3600 detect_outbox_staleness "CRE-3" "$ws")
  rm -rf "$ws"
  [ "$sev" = "0" ]
}

# No outbox file at all is not flagged — nothing to be stale about.
test_no_outbox_file_not_flagged() {
  local ws
  ws=$(_setup_workspace)
  local sev
  sev=$(detect_outbox_staleness "CRE-4" "$ws")
  rm -rf "$ws"
  [ "$sev" = "0" ]
}

# ── 8.5 the detector never returns a severity above 1 regardless of
# staleness age ─────────────────────────────────────────────────────────
test_never_exceeds_severity_1_regardless_of_age() {
  local ws
  ws=$(_setup_workspace)
  # An entry far older than any plausible threshold — decades stale.
  _outbox_entry "$ws" "CRE-5" 1 "gate-held" "1990-01-01T00:00:00Z"

  local sev
  sev=$(FLEET_OUTBOX_STALE_THRESHOLD_SECS=1 detect_outbox_staleness "CRE-5" "$ws")
  rm -rf "$ws"
  [ "$sev" = "1" ]
}

# One stale board and one fresh board, both configured — max severity
# across boards is still capped at 1, and the fresh board alone would not
# have flagged.
test_multi_board_max_severity_still_capped_at_1() {
  local ws
  ws=$(_setup_workspace)
  _outbox_entry "$ws" "CRE-6" 1 "gate-held" "2020-01-01T00:00:00Z"
  _write_cursor "$ws" "CRE-6" "jsonl-audit" 1

  local sev
  sev=$(FLEET_OUTBOX_STALE_THRESHOLD_SECS=3600 FLEET_BOARD_DRIVERS="linear,jsonl-audit" \
    detect_outbox_staleness "CRE-6" "$ws")
  rm -rf "$ws"
  [ "$sev" = "1" ]
}

# ── tracker-flow-projection-cutover task 6.7: a dead-lettered entry
# reports as a lost mutation (severity 1), even when the entry is fresh ──
test_dead_lettered_entry_flags_severity_1() {
  local ws
  ws=$(_setup_workspace)
  _outbox_entry "$ws" "CRE-7" 1 "gate-held" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _write_cursor "$ws" "CRE-7" "linear" 0
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|board-dead-letter|warn|seq=1" >>"$ws/CRE-7-pipeline.log"

  local sev
  sev=$(FLEET_OUTBOX_STALE_THRESHOLD_SECS=3600 detect_outbox_staleness "CRE-7" "$ws")
  rm -rf "$ws"
  [ "$sev" = "1" ]
}

_run "8.3 stale undrained entry flags severity 1" test_stale_undrained_entry_flags_severity_1
_run "8.4 fully-drained ticket is not flagged" test_fully_drained_ticket_not_flagged
_run "recent undrained entry is not flagged" test_recent_undrained_entry_not_flagged
_run "no outbox file is not flagged" test_no_outbox_file_not_flagged
_run "8.5 never exceeds severity 1 regardless of age" test_never_exceeds_severity_1_regardless_of_age
_run "multi-board: one stale board still caps at severity 1" test_multi_board_max_severity_still_capped_at_1
_run "dead-lettered entry flags severity 1 (lost, not pending)" test_dead_lettered_entry_flags_severity_1

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
