#!/usr/bin/env bash
# ticket-cancel: the one actuator for retiring a ticket nobody will finish
# (GitHub #770). Wraps `flow.sh <TID> cancel --reason <text>` and writes the
# pipeline-log record. Setting the tracker's cancelled state by hand bypasses
# the manifest, the outbox and the log; this script is the sanctioned path.
#
# What it does, in order:
#   1. Refuses while a pipeline worker for the ticket is alive (exit 6),
#      unless --force. Stop the run first; a cancel under a live worker races
#      the worker's own log writes.
#   2. Fires the `cancel` trigger: manifest stage -> Canceled, the four
#      projected flags cleared, approval cleared, one `ticket-cancelled`
#      outbox event carrying the reason. The board driver moves the card and
#      removes those labels when the outbox drains.
#   3. Appends two lines to the ticket's pipeline log, the outcome line last:
#        META|cancel|info|reason=<text>; from=<stage>; by=<operator|agent>
#        META|outcome|info|cancelled: <text>
#      Fleet's terminal classifiers read that outcome as finished, so no
#      detector, resume or dispatch pass picks the ticket up again.
#
# What it does not do:
#   - It does not release blocked-by dependents. A cancelled blocker is not
#     Done; dependents stay blocked and dispatch names the cancelled blocker.
#   - It does not kill a worker (fleet-controller owns that).
#   - It does not apply to an epic or to a ticket that is Done (exit 5).
#
# A repeat on an already-cancelled ticket is a no-op (exit 0): no second
# event, and the log record is written only if the first run did not get
# that far.
#
# Exit codes: 0 cancelled or already cancelled, 1 usage, 2 flow.sh not found,
#   3 manifest not addressable, 5 refused (Done, or an epic), 6 a worker is
#   alive, any other code is flow.sh's own (9/10 fence, 13 no REPOS_ROOT,
#   42 lock busy).
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/manifest-write.sh"
_tc_source() {
  source "$LIB_DIR/$1" 2>/dev/null || source "$SCRIPT_DIR/../../lib/$1" 2>/dev/null || true
}
declare -f _plog >/dev/null 2>&1 || _tc_source heartbeat.sh
declare -f ticket_log_dir >/dev/null 2>&1 || _tc_source log-dir.sh

usage() {
  echo "Usage: $0 <TICKET-ID> --reason \"<why the ticket is retired>\" [--force]" >&2
  exit 1
}

TICKET_ID=""
REASON=""
FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
  --reason)
    [ $# -ge 2 ] || usage
    REASON="$2"
    shift
    ;;
  --reason=*) REASON="${1#--reason=}" ;;
  --force) FORCE=true ;;
  -*) usage ;;
  *)
    [ -z "$TICKET_ID" ] || usage
    TICKET_ID="$1"
    ;;
  esac
  shift
done
[ -n "$TICKET_ID" ] || usage
[[ "$TICKET_ID" =~ ^[A-Z]+-[0-9]+$ ]] || {
  echo "ticket-cancel: invalid ticket id '$TICKET_ID'" >&2
  exit 1
}
# One line, no pipes: the reason lands in a pipe-delimited log line.
REASON="${REASON//$'\r'/ }"
REASON="${REASON//$'\n'/ }"
REASON="${REASON//|/ }"
REASON="$(printf '%s' "$REASON" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [ -z "$REASON" ]; then
  echo "ticket-cancel: --reason is required — say why the ticket is retired" >&2
  usage
fi

# ── Resolve flow.sh (same pattern as ticket-approve / ticket-reject) ────────
if [ -z "${FLOW_SH:-}" ]; then
  FLOW_SH="$HOME/.claude/skills/ticket-flow/flow.sh"
  if [ ! -f "$FLOW_SH" ]; then
    _tc_source plugin-cache.sh
    FLOW_SH=$(tap_cache_find ticket-auto-pipeline skills/ticket-flow/flow.sh 2>/dev/null || true)
  fi
fi
if [ -z "$FLOW_SH" ] || [ ! -f "$FLOW_SH" ]; then
  echo "ticket-cancel: flow.sh not found — reinstall the plugin" >&2
  exit 2
fi

# An epic is refused before any manifest is touched: ensure_ticket_manifest
# below would otherwise give the epic id an ad-hoc ticket manifest.
if declare -f epic_manifest_exists >/dev/null 2>&1 && epic_manifest_exists "$TICKET_ID" 2>/dev/null; then
  echo "ticket-cancel: $TICKET_ID is an epic — cancel applies to tickets only. Stop the epic with fleet-controller, then cancel its children." >&2
  exit 5
fi

ensure_ticket_manifest "$TICKET_ID" || {
  echo "ticket-cancel: could not make $TICKET_ID manifest-addressable (is REPOS_ROOT exported?)" >&2
  exit 3
}

# ── Pipeline log path ───────────────────────────────────────────────────────
# The anchored per-ticket log dir (lib/log-dir.sh). With no anchor, an
# existing ./logs/<TID>-pipeline.log is used; otherwise there is no log to
# write and the manifest and outbox alone carry the record.
LOG_DIR=""
if declare -f ticket_log_dir >/dev/null 2>&1; then
  LOG_DIR=$(ticket_log_dir 2>/dev/null) || LOG_DIR=""
fi
if [ -z "$LOG_DIR" ] && [ -f "./logs/${TICKET_ID}-pipeline.log" ]; then
  LOG_DIR="$PWD/logs"
fi
LOG_PATH=""
[ -z "$LOG_DIR" ] || LOG_PATH="$LOG_DIR/${TICKET_ID}-pipeline.log"

# ── Live worker check ───────────────────────────────────────────────────────
# fleetd's run registry (<state dir>/<TID>-run.json) names the worker pid; a
# headless router shows up in the process list as "ticket-auto <TID>".
_tc_worker_alive() {
  local dir run_file pid
  for dir in "${FLEET_STATE_DIR:-}" "$LOG_DIR"; do
    [ -n "$dir" ] || continue
    run_file="$dir/${TICKET_ID}-run.json"
    [ -f "$run_file" ] || continue
    pid=$(jq -r '.pid // empty' "$run_file" 2>/dev/null) || pid=""
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "pid $pid ($run_file)"
      return 0
    fi
  done
  if [ "${TICKET_CANCEL_PGREP-}" != "false" ] && command -v pgrep >/dev/null 2>&1; then
    pid=$(pgrep -f "ticket-auto ${TICKET_ID}([^0-9]|\$)" 2>/dev/null | head -1) || pid=""
    if [ -n "$pid" ]; then
      echo "pid $pid (process list)"
      return 0
    fi
  fi
  return 1
}

STAGE_BEFORE=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)

if [ "$STAGE_BEFORE" != "Canceled" ]; then
  if _worker=$(_tc_worker_alive); then
    if $FORCE; then
      echo "ticket-cancel: a worker for $TICKET_ID is still alive — $_worker. Cancelling anyway (--force): its later transitions are refused by flow.sh (exit 14). Stop it." >&2
    else
      echo "ticket-cancel: a pipeline worker for $TICKET_ID is alive — $_worker. Stop it first (fleet-controller kill, or end the /ticket-auto session), then cancel. --force cancels under it." >&2
      exit 6
    fi
  fi

  _rc=0
  # No LOG_FILE/TAP_LOG for flow.sh: the two log lines below are the whole
  # record, and the outcome line must stay last.
  env -u LOG_FILE -u TAP_LOG bash "$FLOW_SH" "$TICKET_ID" cancel --reason "$REASON" >/dev/null || _rc=$?
  case "$_rc" in
  0) ;;
  8)
    echo "ticket-cancel: $TICKET_ID cannot be cancelled — it is Done or an epic (stage: ${STAGE_BEFORE:-none})" >&2
    exit 5
    ;;
  *)
    echo "ticket-cancel: flow.sh cancel failed (exit $_rc)" >&2
    exit "$_rc"
    ;;
  esac
  ALREADY=false
else
  ALREADY=true
fi

STAGE=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)
if [ "$STAGE" != "Canceled" ]; then
  echo "ticket-cancel: manifest stage is '${STAGE:-none}' after flow.sh succeeded — expected Canceled" >&2
  exit 4
fi

# ── Pipeline-log record ─────────────────────────────────────────────────────
# Written once: a repeat finds the cancel outcome already last and adds
# nothing. The outcome line closes any open run window, so the log is
# terminal for every reader (pipeline-log-format.md rule 1 and rule 6).
LOGGED=false
if [ -n "$LOG_PATH" ] && declare -f _plog >/dev/null 2>&1; then
  _last=""
  [ -s "$LOG_PATH" ] && _last=$(grep -v '^[[:space:]]*$' "$LOG_PATH" 2>/dev/null | tail -1) || true
  case "$_last" in
  *"|META|outcome|info|cancelled: "*) LOGGED=true ;;
  *)
    [ -s "$LOG_PATH" ] || _plog "$LOG_PATH" "META" "schema" "info" "1"
    _by="operator"
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${FLEET_WORKER_PID:-}" ]; then
      _by="agent"
    fi
    _plog "$LOG_PATH" "META" "cancel" "info" "reason=${REASON}; from=${STAGE_BEFORE:-none}; by=${_by}"
    _plog "$LOG_PATH" "META" "outcome" "info" "cancelled: ${REASON}"
    LOGGED=true
    ;;
  esac
else
  echo "ticket-cancel: no pipeline log dir resolved for $TICKET_ID — the manifest and the outbox event carry the record" >&2
fi

echo "stage=${STAGE}"
echo "already_cancelled=${ALREADY}"
echo "reason=${REASON}"
echo "log=${LOG_PATH:-}"
echo "logged=${LOGGED}"

# ── Dependents: named, never released ───────────────────────────────────────
# Every ticket manifest whose blocked_by lists this ticket. They stay blocked
# (blocked-by resolves on Done only); printing them is what makes the
# decision visible to the person cancelling.
DEPENDENTS=""
if [ -n "${REPOS_ROOT:-}" ] && [ -d "$REPOS_ROOT/.ticket-auto/initiatives" ]; then
  while IFS= read -r _mf; do
    [ -n "$_mf" ] || continue
    if jq -e --arg t "$TICKET_ID" '(.blocked_by // []) | index($t) != null' "$_mf" >/dev/null 2>&1; then
      _dep=$(basename "$(dirname "$(dirname "$_mf")")")
      DEPENDENTS="${DEPENDENTS:+$DEPENDENTS }${_dep}"
    fi
  done < <(find "$REPOS_ROOT/.ticket-auto/initiatives" -mindepth 5 -maxdepth 5 \
    -path '*/tickets/*/planner/manifest.json' 2>/dev/null | sort)
fi
echo "blocked_dependents=${DEPENDENTS}"
if [ -n "$DEPENDENTS" ]; then
  echo "ticket-cancel: still blocked by $TICKET_ID, not released: $DEPENDENTS — cancel them too, or re-plan to drop the dependency" >&2
fi

exit 0
