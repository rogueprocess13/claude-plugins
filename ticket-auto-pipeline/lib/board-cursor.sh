#!/usr/bin/env bash
# board-cursor.sh — shared, flock-guarded, atomic cursor read/advance helper
# for the tracker event-board pusher (tracker-event-board-pusher, Phase B2 of
# the tracker-decoupling programme, Track B).
#
# Cursor state is a flat file beside the outbox it tracks, not a database
# row (design.md Decision 2): fleetd's SQLite store is fleetd-process-only,
# and outbox-drain.sh must produce identical results with fleetd not running
# at all.
#
# File shape: {FLEET_PIPELINE_LOG_DIR}/.{TID}-cursor-{BOARD_ID}.json holding
# {"tid", "board_id", "seq", "updated_at"}, plus a matching
# .{TID}-cursor-{BOARD_ID}.lock flock file.
#
# Locking is deliberately explicit and separate from the read/write
# functions below: board_cursor_get/board_cursor_advance never lock
# internally. A caller sequencing "read cursor -> apply driver -> write
# cursor" for one outbox entry acquires board_cursor_lock first and holds it
# across the driver invocation too (design.md Decision 2's "held across the
# driver's own apply call, one outbox entry at a time"). Locking inside
# get/advance themselves would either not span the driver call (defeating
# the point) or self-deadlock a caller (pusher.py) that already holds its
# own flock on the same file and then shells out to this script's get/
# advance CLI subcommands.
#
# Locking style is **blocking** (flock -w "${EVENTS_LOCK_TIMEOUT_SECS:-30}"),
# matching lib/events.sh's convention exactly — explicitly NOT flow.sh's
# non-blocking `flock -n -E 42` style (design.md Decision 2, "Locking,
# disambiguated"): a racing pusher cycle or exit-time drain waits for the
# lock rather than erroring out, then proceeds from whatever cursor value
# the winner left behind — the only choice consistent with "exactly one
# advances the cursor past any given entry, neither double-dispatches".
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention (see
# events.sh's identical note).
#
# set -eo pipefail only when executed directly, never when sourced — this is
# a sourceable library, same convention as events.sh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eo pipefail
fi

_BC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_board_cursor_dir() {
  echo "${FLEET_PIPELINE_LOG_DIR:-./logs}"
}

_board_cursor_file() {
  echo "$(_board_cursor_dir)/.${1}-cursor-${2}.json"
}

_board_cursor_lock_file() {
  echo "$(_board_cursor_dir)/.${1}-cursor-${2}.lock"
}

# board_cursor_lock <tid> <board_id>
#
# Opens and blocking-flocks the lock file for (tid, board_id) on FD 8 in the
# CALLING shell — this only works because board-cursor.sh is sourced, not
# subshelled, so `exec 8>...` here persists in the caller's own shell after
# this function returns. FD 8 is fixed and distinct from events.sh's FD 7
# and flow.sh's FD 9, so a caller sourcing more than one of these libraries
# never collides. Must be paired with board_cursor_unlock.
#
# Exit codes: 0 locked, 1 failed to open the lock file or lock timeout, 2
# usage error.
board_cursor_lock() {
  local tid="$1" board_id="$2"
  if [ -z "$tid" ] || [ -z "$board_id" ]; then
    echo "board_cursor_lock: TID and BOARD_ID are required" >&2
    return 2
  fi
  local dir lock_file
  dir=$(_board_cursor_dir)
  mkdir -p "$dir" 2>/dev/null || true
  lock_file=$(_board_cursor_lock_file "$tid" "$board_id")
  exec 8>"$lock_file" || {
    echo "board_cursor_lock: failed to open lock file ${lock_file}" >&2
    return 1
  }
  if ! flock -w "${EVENTS_LOCK_TIMEOUT_SECS:-30}" 8; then
    echo "board_cursor_lock: lock timeout acquiring cursor lock for ${tid}/${board_id}" >&2
    exec 8>&-
    return 1
  fi
  return 0
}

# board_cursor_unlock — releases the lock acquired by board_cursor_lock.
board_cursor_unlock() {
  exec 8>&- 2>/dev/null || true
  return 0
}

# board_cursor_get <tid> <board_id>
#
# Echoes the persisted seq (0 if the cursor has never been written). Does
# NOT lock — a caller needing a consistent read-modify-write sequence must
# hold board_cursor_lock across this call and the matching
# board_cursor_advance (and, per design.md, across the driver invocation in
# between).
board_cursor_get() {
  local tid="$1" board_id="$2"
  if [ -z "$tid" ] || [ -z "$board_id" ]; then
    echo "board_cursor_get: TID and BOARD_ID are required" >&2
    return 2
  fi
  local file
  file=$(_board_cursor_file "$tid" "$board_id")
  [ -f "$file" ] || {
    echo 0
    return 0
  }
  local seq
  seq=$(jq -r '.seq // 0' "$file" 2>/dev/null) || seq=0
  [[ "$seq" =~ ^[0-9]+$ ]] || seq=0
  echo "$seq"
}

# board_cursor_get_attempts <tid> <board_id>
#
# Echoes the persisted consecutive-failure count for the entry the cursor
# is currently blocked on (0 if never written or the cursor has never
# failed) — tracker-flow-projection-cutover's dead-letter mechanism.
# Does NOT lock — same contract as board_cursor_get.
board_cursor_get_attempts() {
  local tid="$1" board_id="$2"
  if [ -z "$tid" ] || [ -z "$board_id" ]; then
    echo "board_cursor_get_attempts: TID and BOARD_ID are required" >&2
    return 2
  fi
  local file
  file=$(_board_cursor_file "$tid" "$board_id")
  [ -f "$file" ] || {
    echo 0
    return 0
  }
  local attempts
  attempts=$(jq -r '.attempts // 0' "$file" 2>/dev/null) || attempts=0
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
  echo "$attempts"
}

# board_cursor_advance <tid> <board_id> <new_seq>
#
# Atomically persists new_seq as the cursor position, resetting `attempts`
# to 0 — a successful dispatch always clears the failure streak, whether it
# followed prior failures on this same entry or not. Write to a
# process-unique tmp file (never sharing the live cursor's name), then `mv`
# into place — same directory, same filesystem, atomic on every filesystem
# this pipeline runs on. A crash between the tmp write and the mv leaves the
# previous cursor value intact and readable; the tmp file is never mistaken
# for the live cursor.
#
# Does NOT lock — same contract as board_cursor_get.
board_cursor_advance() {
  local tid="$1" board_id="$2" new_seq="$3"
  if [ -z "$tid" ] || [ -z "$board_id" ] || [ -z "$new_seq" ]; then
    echo "board_cursor_advance: TID, BOARD_ID and NEW_SEQ are required" >&2
    return 2
  fi
  [[ "$new_seq" =~ ^[0-9]+$ ]] || {
    echo "board_cursor_advance: NEW_SEQ must be a non-negative integer: ${new_seq}" >&2
    return 2
  }
  local dir file tmp
  dir=$(_board_cursor_dir)
  mkdir -p "$dir" 2>/dev/null || true
  file=$(_board_cursor_file "$tid" "$board_id")
  tmp="${file}.tmp.$$"
  jq -nc \
    --arg tid "$tid" \
    --arg board_id "$board_id" \
    --argjson seq "$new_seq" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tid: $tid, board_id: $board_id, seq: $seq, attempts: 0, updated_at: $updated_at}' >"$tmp" || {
    echo "board_cursor_advance: failed to build cursor JSON for ${tid}/${board_id}" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  mv "$tmp" "$file" || {
    echo "board_cursor_advance: mv failed for ${file}" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  return 0
}

# board_cursor_note_failure <tid> <board_id>
#
# Increments `attempts` by one, leaving `seq` unchanged — the cursor stays
# blocked on the same entry, one more failed dispatch recorded against it.
# Same atomic tmp+mv write as board_cursor_advance. Does NOT lock — a
# caller sequencing "read cursor -> apply driver -> write cursor" holds
# board_cursor_lock across this call too, same contract as board_cursor_get.
board_cursor_note_failure() {
  local tid="$1" board_id="$2"
  if [ -z "$tid" ] || [ -z "$board_id" ]; then
    echo "board_cursor_note_failure: TID and BOARD_ID are required" >&2
    return 2
  fi
  local current_seq current_attempts
  current_seq=$(board_cursor_get "$tid" "$board_id")
  current_attempts=$(board_cursor_get_attempts "$tid" "$board_id")
  local dir file tmp
  dir=$(_board_cursor_dir)
  mkdir -p "$dir" 2>/dev/null || true
  file=$(_board_cursor_file "$tid" "$board_id")
  tmp="${file}.tmp.$$"
  jq -nc \
    --arg tid "$tid" \
    --arg board_id "$board_id" \
    --argjson seq "$current_seq" \
    --argjson attempts "$((current_attempts + 1))" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tid: $tid, board_id: $board_id, seq: $seq, attempts: $attempts, updated_at: $updated_at}' >"$tmp" || {
    echo "board_cursor_note_failure: failed to build cursor JSON for ${tid}/${board_id}" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  mv "$tmp" "$file" || {
    echo "board_cursor_note_failure: mv failed for ${file}" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────
# Lets outbox-drain.sh and fleetd's Python pusher (via subprocess) call
# get/advance identically. lock/unlock are deliberately NOT exposed via the
# CLI — a lock acquired inside a subprocess is released the instant that
# subprocess exits, which cannot span the "read -> apply driver -> write"
# sequence this script exists to protect. A bash caller sources this file
# directly and calls board_cursor_lock in its own shell; pusher.py takes its
# own OS-level flock (fcntl.flock) on the identical lock-file path
# in-process, which correctly excludes bash callers too, because flock
# contention is per-inode, not per-process — see design.md Decision 2.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  get)
    shift
    board_cursor_get "$@"
    ;;
  advance)
    shift
    board_cursor_advance "$@"
    ;;
  get-attempts)
    shift
    board_cursor_get_attempts "$@"
    ;;
  note-failure)
    shift
    board_cursor_note_failure "$@"
    ;;
  *)
    echo "Usage: board-cursor.sh {get|advance|get-attempts|note-failure} <TID> <BOARD_ID> [NEW_SEQ]" >&2
    exit 1
    ;;
  esac
fi
