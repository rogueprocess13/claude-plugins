#!/usr/bin/env bash
# log-dir.sh — the one resolver for a ticket's per-ticket state directory
# (state-root-anchor, review ARCH-5).
#
# The manifest resolves from $REPOS_ROOT. The outbox, its lock, the origin
# sidecar, the board cursors and the pipeline log used to resolve from
# ${FLEET_PIPELINE_LOG_DIR:-./logs}, that is from the caller's cwd, so a
# /ticket-approve run from a repo subdirectory wrote its event into a stray
# ./logs that no pusher reads. This file gives every writer one answer that
# depends on $REPOS_ROOT only.
#
# Resolution (ticket_log_dir; fleetd/log_dir.py resolve_log_dir mirrors it,
# and lib/tests/fixtures/log-dir-cases.tsv holds both to the same table):
#   1. FLEET_PIPELINE_LOG_DIR when it starts with "/"
#   2. the first line of $REPOS_ROOT/.ticket-auto/log-dir, when it starts
#      with "/" (the anchor)
#   3. unresolved: return 1
# A relative FLEET_PIPELINE_LOG_DIR is ignored at step 1: config.sh used to
# set ./logs for everyone, so its presence carries no intent.
# STATE_ROOT_LOG=1 prints the winning step on stderr, for debugging.
#
# The anchor records where state already is; nothing moves. It is written
# once (ticket_log_dir_anchor_write) by the router preamble, fleetd at boot
# or /ticket-env-check. flow.sh, emit_event and the drains never write it:
# their cwd is the input that may be wrong.
#
# Sourced API:
#   ticket_log_dir                    print the dir; return 1 when unresolved
#   ticket_log_dir_anchor_file        print the anchor path; 1 if no REPOS_ROOT
#   ticket_log_dir_anchor_write PATH  write-once; print the value now anchored
#                                     (the winner's on a race); 2 usage, 1 I/O
#   ticket_log_dir_or_legacy          print the dir; unresolved and
#                                     STATE_ROOT_STRICT=true -> message, 13;
#                                     unresolved otherwise -> warning, legacy
#   ticket_log_dir_or_legacy_set      same, but sets TICKET_LOG_DIR_RESOLVED in
#                                     the current shell and warns once per shell
#   ticket_log_dir_note_stray TID DIR one META|state-root-stray|warn line per
#                                     (TID, stray outbox) in DIR's pipeline log
# Resolving creates nothing; the caller makes the directory.
#
# Sourceable library: no shell flags set here (see events.sh's note).

TICKET_LOG_DIR_STRICT_MSG="log dir unresolvable: set FLEET_PIPELINE_LOG_DIR (absolute) or run /ticket-env-check"

_tld_debug() {
  [ "${STATE_ROOT_LOG:-}" = "1" ] || return 0
  echo "ticket_log_dir: $*" >&2
}

ticket_log_dir_anchor_file() {
  [ -n "${REPOS_ROOT:-}" ] || return 1
  printf '%s/.ticket-auto/log-dir\n' "${REPOS_ROOT%/}"
}

# _tld_anchor_read <file> -> first line when it is absolute, else return 1.
# `read` returns 1 on a last line with no newline but still sets the line.
_tld_anchor_read() {
  local file="$1" line=""
  [ -f "$file" ] || return 1
  IFS= read -r line <"$file" || [ -n "$line" ] || return 1
  case "$line" in
  /*)
    printf '%s\n' "$line"
    return 0
    ;;
  esac
  return 1
}

ticket_log_dir() {
  case "${FLEET_PIPELINE_LOG_DIR:-}" in
  /*)
    _tld_debug "env FLEET_PIPELINE_LOG_DIR=${FLEET_PIPELINE_LOG_DIR}"
    printf '%s\n' "$FLEET_PIPELINE_LOG_DIR"
    return 0
    ;;
  esac
  local anchor value
  if anchor=$(ticket_log_dir_anchor_file) && value=$(_tld_anchor_read "$anchor"); then
    _tld_debug "anchor ${anchor} -> ${value}"
    printf '%s\n' "$value"
    return 0
  fi
  _tld_debug "unresolved"
  return 1
}

# ticket_log_dir_anchor_write <abs-path>
#
# Write-once: the value goes to a process-unique tmp file under noclobber,
# then is hard-linked into place (link(2) never replaces an existing file),
# with `mv -n` as the fallback for a filesystem without hard links. The loser
# of a race leaves the winner's value in place and prints it, so every
# writer ends up using the same directory.
ticket_log_dir_anchor_write() {
  local path="${1:-}" anchor dir tmp value
  case "$path" in
  /*) ;;
  *)
    echo "ticket_log_dir_anchor_write: an absolute path is required (got '${path}')" >&2
    return 2
    ;;
  esac
  if ! anchor=$(ticket_log_dir_anchor_file); then
    echo "ticket_log_dir_anchor_write: REPOS_ROOT is not set" >&2
    return 2
  fi
  if value=$(_tld_anchor_read "$anchor"); then
    printf '%s\n' "$value"
    return 0
  fi
  dir=$(dirname "$anchor")
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "ticket_log_dir_anchor_write: cannot create ${dir}" >&2
    return 1
  fi
  tmp="${anchor}.tmp.$$.${RANDOM}"
  if ! (set -o noclobber && printf '%s\n' "$path" >"$tmp") 2>/dev/null; then
    echo "ticket_log_dir_anchor_write: cannot write ${tmp}" >&2
    return 1
  fi
  # A present but unusable anchor (relative or empty line) is not replaced
  # here: link and mv -n both refuse, and the read below reports it.
  ln "$tmp" "$anchor" 2>/dev/null || mv -n "$tmp" "$anchor" 2>/dev/null || true
  rm -f "$tmp" 2>/dev/null || true
  if value=$(_tld_anchor_read "$anchor"); then
    printf '%s\n' "$value"
    return 0
  fi
  echo "ticket_log_dir_anchor_write: ${anchor} does not hold an absolute path" >&2
  return 1
}

# ticket_log_dir_or_legacy_set
#
# Sets TICKET_LOG_DIR_RESOLVED in the calling shell (no subshell, so the
# legacy warning is printed once per shell, not once per lookup).
#   resolved                      -> the resolved dir, return 0
#   unresolved, STATE_ROOT_STRICT=true -> message on stderr, return 13
#   unresolved otherwise          -> warning on stderr, today's
#                                    ${FLEET_PIPELINE_LOG_DIR:-./logs}, return 0
# The legacy value keeps a relative FLEET_PIPELINE_LOG_DIR as it was, so a
# host with no anchor behaves exactly as before this change.
ticket_log_dir_or_legacy_set() {
  TICKET_LOG_DIR_RESOLVED=""
  local dir
  if dir=$(ticket_log_dir); then
    TICKET_LOG_DIR_RESOLVED="$dir"
    return 0
  fi
  if [ "${STATE_ROOT_STRICT:-false}" = "true" ]; then
    echo "$TICKET_LOG_DIR_STRICT_MSG" >&2
    return 13
  fi
  TICKET_LOG_DIR_RESOLVED="${FLEET_PIPELINE_LOG_DIR:-./logs}"
  if [ -z "${_TLD_LEGACY_WARNED:-}" ]; then
    echo "log dir not anchored; using ${TICKET_LOG_DIR_RESOLVED} (legacy)" >&2
    _TLD_LEGACY_WARNED=1
  fi
  return 0
}

ticket_log_dir_or_legacy() {
  local _rc=0
  ticket_log_dir_or_legacy_set || _rc=$?
  [ "$_rc" -eq 0 ] || return "$_rc"
  printf '%s\n' "$TICKET_LOG_DIR_RESOLVED"
}

# ticket_log_dir_note_stray <tid> <resolved-dir>
#
# A writer that resolved <resolved-dir> but finds ./logs/<tid>-outbox.jsonl in
# a different directory appends META|state-root-stray|warn|path=<stray> to
# <resolved-dir>/<tid>-pipeline.log, once per (tid, stray path). The paths
# already noted are listed in <resolved-dir>/.<tid>-stray-noted. Strays are
# re-projected by hand (design Open Question 4); this never moves them.
# Best-effort: always returns 0. emit_event calls it under its outbox lock.
ticket_log_dir_note_stray() {
  local tid="${1:-}" dir="${2:-}"
  [ -n "$tid" ] && [ -n "$dir" ] || return 0
  [ -f "./logs/${tid}-outbox.jsonl" ] || return 0
  local here there stray marker log ts
  here=$(cd ./logs 2>/dev/null && pwd -P) || return 0
  there=$(cd "$dir" 2>/dev/null && pwd -P) || there="$dir"
  [ "$here" != "$there" ] || return 0
  stray="${here}/${tid}-outbox.jsonl"
  marker="${dir}/.${tid}-stray-noted"
  if [ -f "$marker" ] && grep -Fxq -- "$stray" "$marker" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null || return 0
  log="${dir}/${tid}-pipeline.log"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ ! -s "$log" ]; then
    printf '%s|META|schema|info|1\n' "$ts" >>"$log" 2>/dev/null || return 0
  fi
  local msg="path=${stray}"
  msg=${msg//|/ }
  msg=${msg//$'\n'/ }
  printf '%s|META|state-root-stray|warn|%s\n' "$ts" "$msg" >>"$log" 2>/dev/null || return 0
  printf '%s\n' "$stray" >>"$marker" 2>/dev/null || true
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  resolve) ticket_log_dir ;;
  or-legacy) ticket_log_dir_or_legacy ;;
  anchor-write)
    shift
    ticket_log_dir_anchor_write "$@"
    ;;
  *)
    echo "Usage: log-dir.sh {resolve|or-legacy|anchor-write <abs-path>}" >&2
    exit 2
    ;;
  esac
fi
