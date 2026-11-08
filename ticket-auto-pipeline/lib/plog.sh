#!/usr/bin/env bash
# plog.sh — CLI over `_plog` (heartbeat.sh) for writing one pipeline-log line.
#
# Usage:
#   bash ~/.claude/skills/lib/plog.sh [--log-file PATH] PHASE STEP STATUS [MSG]
#
# Appends `ISO|PHASE|STEP|STATUS|MSG` to "$LOG_FILE" (or PATH). This is a
# wrapper, never a second writer: the line is whatever `_plog` writes, so the
# grammar stays defined in one place (pipeline-log-format.md). `_plog`
# replaces `|`, CR and LF in MSG with spaces, so one call is always exactly
# one 5-field line, and creates the log's parent directory.
#
# Why a script and not a sourced function: skills run each fence in a fresh
# Bash call, so a function would need a `source` line pasted into every fence.
# The inline `echo "$(date -u ...)|..." >> "$LOG_FILE"` it replaces had no
# sanitisation, and its usual `[ -n "$LOG_FILE" ] && echo ...` guard aborts a
# `set -e` caller when LOG_FILE is empty.
#
# Exit codes:
#   0  line written, or no log file configured (LOG_FILE/TAP_LOG empty and no
#      spawn-meta LOG_FILE for $TICKET_ID: the line is dropped with a stderr
#      warning, #605) — safe as the last statement under `set -e`
#   1  heartbeat.sh not found next to this script, or the log is not writable
#   2  usage: fewer than PHASE STEP STATUS, or --log-file without a value
#   2  also: PHASE, STEP or STATUS outside [A-Za-z0-9_-]+ (a `|`, CR or LF
#      there would forge extra fields or a whole extra line; GitHub #610)
#   3  refused: META|adversarial-override or META|verify-attempts-reset is an
#      operator marker, written only by its own operator script
#      (adversarial-override.sh, verify-attempts-reset.sh), never through
#      this agent-facing writer (GitHub #610)

_PLOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_plog_usage() {
  echo "usage: plog.sh [--log-file PATH] PHASE STEP STATUS [MSG]" >&2
  exit 2
}

if [ "${1:-}" = "--log-file" ]; then
  [ "$#" -ge 2 ] || _plog_usage
  LOG_FILE="$2"
  shift 2
fi

[ "$#" -ge 3 ] || _plog_usage

# GitHub #610: PHASE/STEP/STATUS are bare tokens. A `|`, CR or LF in one
# would let a caller forge extra fields or a whole extra line (e.g.
# `plog.sh "META|adversarial-override" info ...`), so reject anything else
# before the operator-marker check below. MSG is sanitised by _plog.
for _plog_f in "$1" "$2" "$3"; do
  if ! [[ "$_plog_f" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf 'plog.sh: invalid PHASE/STEP/STATUS %q - must match [A-Za-z0-9_-]+\n' "$_plog_f" >&2
    exit 2
  fi
done

# GitHub #610: operator markers clear gates (the adversarial override counts
# as a WARN in flow.sh's verdict gate). They have their own operator-only
# scripts, so the agent-facing writer refuses them. This closes the one-call
# path, not every path: a direct `>>` append is still possible (accepted
# residual risk, see lib/verifier-result.sh).
if [ "$1" = "META" ]; then
  case "$2" in
  adversarial-override | verify-attempts-reset)
    echo "plog.sh: refusing META|$2 - operator marker; run lib/$2.sh from a terminal" >&2
    exit 3
    ;;
  esac
fi

# A test harness may pre-load a mock _plog; otherwise use the real one.
if ! declare -f _plog >/dev/null 2>&1; then
  if [ ! -f "$_PLOG_LIB_DIR/heartbeat.sh" ]; then
    echo "plog.sh: heartbeat.sh not found in $_PLOG_LIB_DIR" >&2
    exit 1
  fi
  # shellcheck source=heartbeat.sh
  source "$_PLOG_LIB_DIR/heartbeat.sh"
fi

# TAP_LOG is the name phase agents export (GitHub #575). An
# unsubstituted "{LOG_FILE}" placeholder falls back the same way flow-run.sh's
# --log-file does, instead of creating a file literally named that.
case "${LOG_FILE:-}" in "{"*"}") LOG_FILE="" ;; esac
LOG_FILE="${LOG_FILE:-${TAP_LOG:-}}"
# GitHub #605: an agent's Bash calls do not keep env vars between calls, so a
# call that did not re-source the env file has no log path. Recover it from
# the router's spawn-meta file when TICKET_ID is known; otherwise say on
# stderr that the line was dropped instead of losing it silently. Still
# exit 0: a missing log must not abort a `set -e` caller.
if [ -z "${LOG_FILE:-}" ] && [ -n "${TICKET_ID:-}" ]; then
  # Same fixed path spawn_agent_pre writes (lib/spawn-helper.sh).
  _plog_meta="/tmp/ticket-auto-${TICKET_ID}-spawn-meta.txt"
  if [ -f "$_plog_meta" ]; then
    LOG_FILE=$(sed -n 's/^LOG_FILE=//p' "$_plog_meta" 2>/dev/null | head -1)
    case "$LOG_FILE" in "{"*"}") LOG_FILE="" ;; esac
  fi
fi
if [ -z "${LOG_FILE:-}" ]; then
  echo "plog.sh: WARNING no pipeline log (TAP_LOG/LOG_FILE unset; source /tmp/ticket-auto-<ID>-env.sh or pass --log-file) - line dropped: $1|$2|$3" >&2
  exit 0
fi

if ! _plog "$LOG_FILE" "$1" "$2" "$3" "${4:-}" 2>/dev/null; then
  echo "plog.sh: could not append to $LOG_FILE" >&2
  exit 1
fi
exit 0
