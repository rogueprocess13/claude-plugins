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
#   0  line written, or no log file configured (LOG_FILE empty: a no-op, like
#      `_plog` itself) — safe as the last statement under `set -e`
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

if [ -z "${LOG_FILE:-}" ]; then
  exit 0
fi

if ! _plog "$LOG_FILE" "$1" "$2" "$3" "${4:-}" 2>/dev/null; then
  echo "plog.sh: could not append to $LOG_FILE" >&2
  exit 1
fi
exit 0
