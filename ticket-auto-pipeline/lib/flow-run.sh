#!/usr/bin/env bash
# flow-run.sh — the one shell entry point skills and agents use to fire a
# ticket-flow trigger (review finding DET-IP-1 / DET-RV-20).
#
# Why this exists
# ───────────────
# Skills used to carry ~12 hand-copied blocks of the form
#
#   /ticket-flow {TICKET-ID} <trigger>
#   _rc=$?
#   if [ "$_rc" -ne 0 ]; then hb-wrap.sh retry ...; echo "...|META|flow-error|..." >> LOG; fi
#
# `/ticket-flow` is a slash command, not a shell command: run in Bash it is
# "command not found" (rc 127), and invoked as a Skill there is no `$?` to
# read. Phase agents (appraise, implement, verify, pr-review) have no Skill
# tool at all. So the rc branching — including the exit-11 verdict-gate
# branch, which only 2 of the copies had — was whatever the model made of it.
# The other copies pasted the flow.sh path resolver inline even though
# lib/plugin-cache.sh's tap_cache_find already implements it (#468).
#
# This script resolves flow.sh, runs it, records any failure in the pipeline
# log and heartbeat the same way at every call site, and exits with flow.sh's
# own exit code so the caller can branch on it with a real `$?`.
#
# Usage
# ─────
#   bash ~/.claude/skills/lib/flow-run.sh [--log-file FILE] <TICKET-ID> <TRIGGER> [flow.sh args...]
#
#   --log-file FILE   Pipeline log to record failures in. May appear anywhere in
#                     the argument list; it is consumed here and never passed to
#                     flow.sh. An empty value, or an unsubstituted
#                     placeholder like "{LOG_FILE}", falls back to $LOG_FILE, then
#                     $TAP_LOG (the name phase agents export, #575). The
#                     resolved path is exported to flow.sh as LOG_FILE, so the
#                     verdict gate and flow.sh's own log lines see the same log.
#   Every other argument (--data k=v, --provenance X, --override "reason",
#   --generation N, --state-dir D, --dry-run) is passed to flow.sh verbatim,
#   one argv element each — spaces and quotes inside a value are preserved.
#
# flow.sh resolution
# ──────────────────
#   1. $FLOW_RUN_FLOW_SH (explicit override; tests, dev checkouts)
#   2. ~/.claude/skills/ticket-flow/flow.sh (dev-mode synced copy)
#   3. tap_cache_find ticket-auto-pipeline skills/ticket-flow/flow.sh
#      (installed version, then newest cached version by version order)
#
# Exit-code contract (flow.sh's own codes are passed through unchanged)
# ────────────────────────────────────────────────────────────────────
#   0    transition applied (or a warn-only no-op such as ILLEGAL_TRANSITION)
#   1    usage / invalid ticket id / unreadable workflow.json / manifest write
#        failed / other flow.sh error
#   3    unknown trigger
#   8    precondition rejected
#   9    fence guard — missing generation token for a fenced ticket
#   10   fence guard — caller's generation is superseded
#   11   VERDICT GATE BLOCKED — a verdict-gated trigger (uat-pass,
#        pr-review-pass-done, pr-review-pass-uat) was refused because a trailing
#        FAIL/BLOCK verifier-result is still on record. Not a transient error:
#        do not retry, do not report the step as passed. A human resolves it or
#        re-runs with --override "<reason>".
#   12   an earlier pending event could not be replayed; nothing applied, retry
#   13   REPOS_ROOT unset — the ticket manifest cannot be resolved; nothing
#        applied. Source the ticket env file (or export REPOS_ROOT) and retry
#   42   another flow.sh run for this ticket holds the lock
#   127  flow.sh could not be resolved (nothing was run)
#   any other non-zero code is flow.sh's and is passed through as-is
#
# Side effects on failure (none on exit 0)
#   11:      LOG  <ts>|META|gate-stop|fail|VERDICT_GATE_BLOCKED — <trigger> refused, see flow.sh stderr
#            HB   gate verdict-gate fail
#   127:     LOG  <ts>|META|flow-error|fail|flow.sh not found: <trigger>
#            HB   retry flow-sh fail (error_type=not_found)
#   other:   LOG  <ts>|META|flow-error|fail|exit <rc>: <trigger>[ — <flow.sh stderr snippet>]
#            HB   retry flow-sh fail (error_type=<usage|unknown_trigger|precondition|fence|emit_replay|env|lock|flow_error>,
#                 error_snippet=<last stderr lines, sanitised, max 240 chars>)
#            Exit 1 is error_type=usage only when flow.sh's stderr is one of
#            its usage messages; otherwise flow_error.
# Log lines are skipped when no log file is known; heartbeats are a no-op when
# HB_LOG_FILE is unset (hb-wrap.sh contract).
#
# Stdout: flow.sh's own output, then three machine-readable lines:
#   FLOW_TRIGGER=<trigger>
#   FLOW_RC=<rc>
#   FLOW_GATE_BLOCKED=true|false

FLOW_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_fr_usage() {
  echo "Usage: flow-run.sh [--log-file FILE] <TICKET-ID> <TRIGGER> [flow.sh args...]" >&2
}

_fr_log_file="${LOG_FILE:-${TAP_LOG:-}}"
_fr_pos=()
_fr_pass=()
# A --log-file value is used only when it is non-empty and not an
# unsubstituted skill placeholder such as "{LOG_FILE}" — writing to a file
# literally named that would hide the failure record.
_fr_set_log() {
  case "$1" in
  "" | "{"*"}") ;;
  *) _fr_log_file="$1" ;;
  esac
}
while [ $# -gt 0 ]; do
  case "$1" in
  --log-file)
    _fr_set_log "${2:-}"
    shift 2 || shift $#
    continue
    ;;
  --log-file=*)
    _fr_set_log "${1#--log-file=}"
    ;;
  *)
    if [ "${#_fr_pos[@]}" -lt 2 ]; then
      _fr_pos+=("$1")
    else
      _fr_pass+=("$1")
    fi
    ;;
  esac
  shift
done

if [ "${#_fr_pos[@]}" -lt 2 ]; then
  _fr_usage
  exit 1
fi
_fr_tid="${_fr_pos[0]}"
_fr_trigger="${_fr_pos[1]}"
# The trigger lands in a pipe-delimited log line and a JSON detail field.
_fr_trigger_safe="${_fr_trigger//|/ }"
_fr_trigger_safe="${_fr_trigger_safe//\"/}"
_fr_trigger_safe="${_fr_trigger_safe//\\/}"

_fr_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_fr_log() {
  [ -n "$_fr_log_file" ] || return 0
  printf '%s|%s\n' "$(_fr_ts)" "$1" >>"$_fr_log_file" 2>/dev/null || true
}

_fr_hb() {
  [ -f "${FLOW_RUN_DIR}/hb-wrap.sh" ] || return 0
  bash "${FLOW_RUN_DIR}/hb-wrap.sh" "$@" >/dev/null 2>&1 || true
}

_fr_report() {
  echo "FLOW_TRIGGER=${_fr_trigger}"
  echo "FLOW_RC=$1"
  echo "FLOW_GATE_BLOCKED=$2"
}

# ── Resolve flow.sh ──────────────────────────────────────────────────────────
_fr_flow_sh="${FLOW_RUN_FLOW_SH:-}"
if [ -z "$_fr_flow_sh" ] || [ ! -f "$_fr_flow_sh" ]; then
  _fr_flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
  if [ ! -f "$_fr_flow_sh" ]; then
    _fr_flow_sh=""
    if [ -f "${FLOW_RUN_DIR}/plugin-cache.sh" ]; then
      # shellcheck source=plugin-cache.sh
      source "${FLOW_RUN_DIR}/plugin-cache.sh"
      _fr_flow_sh=$(tap_cache_find ticket-auto-pipeline skills/ticket-flow/flow.sh)
    fi
  fi
fi

if [ -z "$_fr_flow_sh" ] || [ ! -f "$_fr_flow_sh" ]; then
  echo "flow-run.sh: flow.sh not found (looked in ~/.claude/skills/ticket-flow and the plugin cache)" >&2
  _fr_log "META|flow-error|fail|flow.sh not found: ${_fr_trigger_safe}"
  _fr_hb retry "flow-sh" "fail" "flow.sh not found for ${_fr_trigger_safe}" \
    "{\"trigger\":\"${_fr_trigger_safe}\",\"exit_code\":\"127\",\"ticket\":\"${_fr_tid}\",\"error_type\":\"not_found\"}"
  _fr_report 127 false
  exit 127
fi

# ── Run it ───────────────────────────────────────────────────────────────────
# flow.sh's stderr is captured (and replayed to our own stderr afterwards) so
# the failure record can carry its message: without it every exit 1 looked
# the same in the log and the heartbeat (GitHub #606).
_fr_rc=0
_fr_err=$(mktemp "${TMPDIR:-/tmp}/flow-run-err.XXXXXX" 2>/dev/null) || _fr_err=/dev/null
if [ -n "$_fr_log_file" ]; then
  LOG_FILE="$_fr_log_file" bash "$_fr_flow_sh" "$_fr_tid" "$_fr_trigger" "${_fr_pass[@]}" 2>"$_fr_err" || _fr_rc=$?
else
  bash "$_fr_flow_sh" "$_fr_tid" "$_fr_trigger" "${_fr_pass[@]}" 2>"$_fr_err" || _fr_rc=$?
fi
_fr_snip=""
if [ "$_fr_err" != /dev/null ]; then
  cat "$_fr_err" >&2 2>/dev/null || true
  # Last non-blank stderr lines, one line, no pipes/quotes/backslashes/control
  # characters (it lands in a pipe-delimited log line and a JSON field).
  _fr_snip=$(grep -v '^[[:space:]]*$' "$_fr_err" 2>/dev/null | tail -3 | tr '\n\r\t|"\\' '      ' |
    tr -d '[:cntrl:]' | tr -s ' ' | cut -c1-240 || true)
  _fr_snip="${_fr_snip% }"
  rm -f "$_fr_err"
fi

# ── Record the outcome ───────────────────────────────────────────────────────
case "$_fr_rc" in
0)
  _fr_report 0 false
  ;;
11)
  _fr_log "META|gate-stop|fail|VERDICT_GATE_BLOCKED — ${_fr_trigger_safe} refused, see flow.sh stderr"
  _fr_hb gate "verdict-gate" "fail" "${_fr_trigger_safe} blocked by trailing FAIL/BLOCK verifier-result" \
    "{\"trigger\":\"${_fr_trigger_safe}\",\"ticket\":\"${_fr_tid}\"}"
  _fr_report 11 true
  ;;
*)
  case "$_fr_rc" in
  1)
    # flow.sh exits 1 for usage errors and for runtime failures alike
    # (unreadable workflow.json, manifest write failed). Only its own usage
    # messages make it a usage error (GitHub #606).
    case "$_fr_snip" in
    *"Usage:"* | *"unknown argument"* | *"requires a value"* | *"expects key=value"* | *"Invalid TICKET_ID"* | *"invalid generation token"*)
      _fr_type=usage
      ;;
    *) _fr_type=flow_error ;;
    esac
    ;;
  3) _fr_type=unknown_trigger ;;
  8) _fr_type=precondition ;;
  9 | 10) _fr_type=fence ;;
  12) _fr_type=emit_replay ;;
  13) _fr_type=env ;;
  42) _fr_type=lock ;;
  *) _fr_type=flow_error ;;
  esac
  _fr_log "META|flow-error|fail|exit ${_fr_rc}: ${_fr_trigger_safe}${_fr_snip:+ — ${_fr_snip}}"
  _fr_hb retry "flow-sh" "fail" "flow.sh ${_fr_trigger_safe} failed (exit ${_fr_rc})" \
    "{\"trigger\":\"${_fr_trigger_safe}\",\"exit_code\":\"${_fr_rc}\",\"ticket\":\"${_fr_tid}\",\"error_type\":\"${_fr_type}\",\"error_snippet\":\"${_fr_snip}\"}"
  _fr_report "$_fr_rc" false
  ;;
esac

exit "$_fr_rc"
