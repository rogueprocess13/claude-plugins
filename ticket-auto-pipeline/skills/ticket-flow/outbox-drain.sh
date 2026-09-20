#!/usr/bin/env bash
# outbox-drain.sh — standalone per-ticket event-outbox drain
# (tracker-event-board-pusher, Phase B2 of the tracker-decoupling programme,
# Track B).
#
# Usage: outbox-drain.sh <TID>
#
# Reads FLEET_BOARD_DRIVERS (comma-separated, default "linear") and, for
# each configured driver, drains that ticket's outbox from its persisted
# cursor forward: every unconsumed entry, in seq order, is dispatched to
# the driver and the cursor advances after each successful dispatch. Shares
# cursor state and idempotency with fleetd/pusher.py via
# lib/board-cursor.sh and lib/board-drivers/*.sh — one implementation of
# the read-apply-write sequence, two callers — so a ticket's board state
# after a drain does not depend on which of the two drained it
# (tracker-board-pusher spec's "fleetd-down parity" requirement).
#
# Called at the router's normal exit path (pipeline-finalize.sh, every
# call site — success and gate-held/human-hold alike) so a fleetd-down run
# still drains its own ticket before the process ends.
#
# The lock for a (tid, board_id) pair is held across that board's whole
# pending backlog for this invocation, not re-acquired per entry — the
# concern design.md's "one outbox entry at a time, not for the whole
# drain" guards against is a *different* ticket being blocked by a slow
# driver, which per-(tid, board_id) lock scoping already prevents on its
# own (a different ticket's lock file is a different file). A crash
# between one entry's successful driver apply and its cursor write still
# only costs re-dispatching that one entry next time — the driver contract
# requires idempotent replay for exactly this reason.
#
# Exit codes:
#   0  drained cleanly (including "nothing to drain")
#   1  a driver failed on some entry — its cursor is left at the last
#      successful entry to retry next drain; never fatal to the caller
#   2  usage error
#
# -u intentionally omitted — see events.sh's identical note.
set -eo pipefail

_OD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_OD_LIB_DIR="$(cd "$_OD_DIR/../../lib" && pwd)"

source "$_OD_LIB_DIR/board-cursor.sh"

_outbox_drain_dir() {
  echo "${FLEET_PIPELINE_LOG_DIR:-./logs}"
}

_outbox_drain_file() {
  echo "$(_outbox_drain_dir)/${1}-outbox.jsonl"
}

# Resolves a configured driver name to its script path. OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE
# (tests only, never production config) is checked FIRST and, if it holds a
# script by that name, wins — this lets a test mix a real production driver
# (resolved from lib/board-drivers/, e.g. `linear`, whose own BASH_SOURCE-
# anchored path resolution only works from its real location) alongside a
# test-only fixture driver (e.g. jsonl-audit) named in the same override
# directory. Anything not found in the override falls back to the
# production directory (lib/board-drivers/).
_outbox_drain_driver_script() {
  local name="$1"
  if [ -n "${OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE:-}" ] && [ -f "${OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE}/${name}.sh" ]; then
    echo "${OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE}/${name}.sh"
    return 0
  fi
  echo "$_OD_LIB_DIR/board-drivers/${name}.sh"
}

# Drains one (tid, board_id) pair against one driver script, from that
# board's persisted cursor forward. Returns 0 if every entry unconsumed at
# the start of this call dispatched successfully, 1 if a driver failure
# stopped the drain early (the cursor is left at the last successful seq).
_outbox_drain_one_board() {
  local tid="$1" board_id="$2" driver_script="$3"
  local outbox
  outbox=$(_outbox_drain_file "$tid")
  [ -f "$outbox" ] || return 0

  board_cursor_lock "$tid" "$board_id" || return 1

  local cursor
  cursor=$(board_cursor_get "$tid" "$board_id")

  local rc=0
  local line seq event data
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    seq=$(printf '%s' "$line" | jq -r '.seq // empty' 2>/dev/null) || seq=""
    [ -z "$seq" ] && continue
    [ "$seq" -le "$cursor" ] && continue

    event=$(printf '%s' "$line" | jq -r '.event // empty' 2>/dev/null) || event=""
    data=$(printf '%s' "$line" | jq -c '.data // {}' 2>/dev/null) || data="{}"
    [ -z "$event" ] && continue

    if bash "$driver_script" apply "$tid" "$event" "$seq" "$data"; then
      board_cursor_advance "$tid" "$board_id" "$seq"
    else
      echo "outbox-drain.sh: driver ${driver_script} failed on ${tid}/${event} (seq ${seq}) — cursor left at last successful entry, will retry next drain" >&2
      rc=1
      break
    fi
  done <"$outbox"

  board_cursor_unlock
  return "$rc"
}

# outbox_drain_ticket <TID>
#
# Drains a ticket's outbox against every driver named in
# FLEET_BOARD_DRIVERS (default "linear"), independently — one driver's
# failure does not stop another configured driver from draining.
outbox_drain_ticket() {
  local tid="$1"
  if [ -z "$tid" ]; then
    echo "outbox-drain.sh: TID is required" >&2
    return 2
  fi

  local drivers="${FLEET_BOARD_DRIVERS:-linear}"
  local overall_rc=0
  local driver_name driver_script
  local _configured_drivers=()
  IFS=',' read -ra _configured_drivers <<<"$drivers"
  for driver_name in "${_configured_drivers[@]}"; do
    [ -z "$driver_name" ] && continue
    driver_script=$(_outbox_drain_driver_script "$driver_name")
    if [ ! -f "$driver_script" ]; then
      echo "outbox-drain.sh: configured driver '${driver_name}' has no script at ${driver_script} — skipping" >&2
      continue
    fi
    _outbox_drain_one_board "$tid" "$driver_name" "$driver_script" || overall_rc=1
  done

  return "$overall_rc"
}

# ── CLI entrypoint ───────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  outbox_drain_ticket "${1:-}"
fi
