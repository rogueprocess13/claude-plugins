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
#      warning, #605), or the spawn-meta file or the path it names is not
#      trusted (#619, also dropped with a warning) — safe as the last
#      statement under `set -e`
#   1  heartbeat.sh not found next to this script, or the log is not writable
#   2  usage: fewer than PHASE STEP STATUS, or --log-file without a value

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
# GitHub #619: the meta file sits at a predictable path, so it is trusted only
# when this user owns it, it is a regular file and not a symlink, and nobody
# else can write it; and the path it names must be a pipeline log. Anything
# else is warned about and the line dropped - never written somewhere a file
# we do not control told us to write.
_plog_line="$1|$2|$3"
_plog_untrusted() {
  echo "plog.sh: WARNING $1 - line dropped: $_plog_line" >&2
  exit 0
}
_plog_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
if [ -z "${LOG_FILE:-}" ] && [ -n "${TICKET_ID:-}" ]; then
  [[ "$TICKET_ID" =~ ^[A-Za-z0-9_-]+$ ]] || _plog_untrusted "invalid TICKET_ID '$TICKET_ID'"
  # Same fixed path spawn_agent_pre writes (lib/spawn-helper.sh).
  _plog_meta="/tmp/ticket-auto-${TICKET_ID}-spawn-meta.txt"
  if [ -e "$_plog_meta" ] || [ -L "$_plog_meta" ]; then
    if [ -L "$_plog_meta" ] || [ ! -f "$_plog_meta" ] || [ ! -O "$_plog_meta" ]; then
      _plog_untrusted "untrusted spawn-meta $_plog_meta (symlink, not a regular file, or not owned by this user)"
    fi
    _plog_m=$(_plog_mode "$_plog_meta")
    case "$_plog_m" in
    '' | *[!0-7]*) _plog_untrusted "cannot read the mode of $_plog_meta" ;;
    esac
    if (((8#$_plog_m & 8#022) != 0)); then
      _plog_untrusted "untrusted spawn-meta $_plog_meta (group/other writable, mode $_plog_m)"
    fi
    LOG_FILE=$(sed -n 's/^LOG_FILE=//p' "$_plog_meta" 2>/dev/null | head -1)
    case "$LOG_FILE" in "{"*"}") LOG_FILE="" ;; esac
    case "$LOG_FILE" in
    '' | *-pipeline.log) ;;
    *) _plog_untrusted "spawn-meta LOG_FILE '$LOG_FILE' is not a *-pipeline.log" ;;
    esac
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
