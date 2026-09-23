#!/usr/bin/env bash
# board-cursor-fastforward.sh — one-shot migration step
# (tracker-flow-projection-cutover task 10.1): before the board pusher's
# default flips on, every existing (ticket, board) cursor must be advanced
# to that ticket's outbox tail. Without this, enabling projection replays
# each ticket's entire transition history and flaps its board column
# through every past state before settling — visible to everyone watching
# the board, and undoable by nothing (tracker-board-pusher spec).
#
# Usage: board-cursor-fastforward.sh [--dry-run]
#
# Reads FLEET_BOARD_DRIVERS (comma-separated, default "linear") and, for
# every ticket with an outbox file under FLEET_PIPELINE_LOG_DIR, sets each
# configured board's cursor to that outbox's tail seq — unless the cursor
# is already at or past the tail, which is left untouched. Idempotent:
# running it twice advances nothing the second time. --dry-run writes
# nothing and reports what it would advance.
#
# Exit codes:
#   0  ran cleanly (including "nothing to advance")
#   2  usage error
#
# -u intentionally omitted — see events.sh's identical note.
set -eo pipefail

_FF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FF_LIB_DIR="$(cd "$_FF_DIR/../../lib" && pwd)"

source "$_FF_LIB_DIR/board-cursor.sh"

_ff_log_dir() {
  echo "${FLEET_PIPELINE_LOG_DIR:-./logs}"
}

_ff_configured_drivers() {
  local drivers="${FLEET_BOARD_DRIVERS:-linear}"
  local -a out=()
  IFS=',' read -ra out <<<"$drivers"
  printf '%s\n' "${out[@]}"
}

_ff_outbox_tail_seq() {
  local outbox="$1"
  tail -n 1 "$outbox" 2>/dev/null | jq -r '.seq // 0' 2>/dev/null || echo 0
}

# board_cursor_fastforward_sweep [--dry-run]
#
# Prints one line per (tid, board_id) pair touched:
#   ADVANCED <tid> <board_id> <old_seq> -> <new_seq>
#   SKIPPED  <tid> <board_id> already at <seq>
# and a final summary line:
#   SUMMARY tickets=<n> advanced=<n> skipped=<n> dry_run=<true|false>
board_cursor_fastforward_sweep() {
  local dry_run=false
  case "${1:-}" in
  --dry-run) dry_run=true ;;
  "") ;;
  *)
    echo "board-cursor-fastforward.sh: unknown argument: $1" >&2
    return 2
    ;;
  esac

  local log_dir
  log_dir=$(_ff_log_dir)
  local -a drivers=()
  mapfile -t drivers < <(_ff_configured_drivers)

  local tickets_seen=0 advanced=0 skipped=0
  local outbox tid board_id tail_seq current_seq

  shopt -s nullglob
  for outbox in "$log_dir"/*-outbox.jsonl; do
    [ -f "$outbox" ] || continue
    tid=$(basename "$outbox")
    tid="${tid%-outbox.jsonl}"
    [ -n "$tid" ] || continue
    tickets_seen=$((tickets_seen + 1))

    tail_seq=$(_ff_outbox_tail_seq "$outbox")
    [[ "$tail_seq" =~ ^[0-9]+$ ]] || tail_seq=0

    for board_id in "${drivers[@]}"; do
      [ -z "$board_id" ] && continue

      board_cursor_lock "$tid" "$board_id" || continue
      current_seq=$(board_cursor_get "$tid" "$board_id")
      [[ "$current_seq" =~ ^[0-9]+$ ]] || current_seq=0

      if [ "$current_seq" -ge "$tail_seq" ]; then
        echo "SKIPPED ${tid} ${board_id} already at ${current_seq}"
        skipped=$((skipped + 1))
      else
        if ! $dry_run; then
          board_cursor_advance "$tid" "$board_id" "$tail_seq"
        fi
        echo "ADVANCED ${tid} ${board_id} ${current_seq} -> ${tail_seq}"
        advanced=$((advanced + 1))
      fi
      board_cursor_unlock
    done
  done
  shopt -u nullglob

  echo "SUMMARY tickets=${tickets_seen} advanced=${advanced} skipped=${skipped} dry_run=${dry_run}"
  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  board_cursor_fastforward_sweep "${1:-}"
fi
