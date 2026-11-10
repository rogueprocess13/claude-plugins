#!/usr/bin/env bash
# implement-feedback.sh — ticket-implement Step 4c's deterministic tail
# (skill-deterministic-extraction 5).
#
# Usage:
#   implement-feedback.sh record <TICKET-ID> --ticket-dir D --outcome O
#                         --verdict PASS|FAIL [--corrections N] [--log-file F]
#   implement-feedback.sh wiki-ok [--log-file F]
#   implement-feedback.sh correction --ticket-dir D --source S --fact T --detail T
#
# record: fires `flow-run.sh <TID> implement-outcome --data outcome=O` (flow.sh
#   writes the IMPLEMENT|implement-outcome|info| line outcome-label-check.sh
#   reads; a flow failure is already logged by flow-run.sh and is non-fatal),
#   then write_verifier_result verifier=implement_tests ... phase=IMPLEMENT,
#   then prints the two decisions the rest of Step 4c branches on:
#     PREDICTED=<simple|complex|>  (get_complexity on notes.md)
#     MISMATCH=true|false          (simple + Rough/Hard, or complex + Smooth)
#     WIKI_CONSULTED=true|false    (notes.md has a `Wiki bootstrap:` line)
# wiki-ok: writes META|wiki-check|info|wiki consulted, no gap found.
# correction: append_correction on D/notes.md; a failed write logs
#   META|corrections-error|warn|append_correction failed (`... wiki failed`
#   for --source wiki) and still exits 0 — it never halts the phase.
#
# The log is --log-file, else LOG_FILE, else TAP_LOG (plog.sh's own
# fallbacks apply when none is set: the line is dropped, exit 0).
# Exit codes: 0 done (any flow/verifier/correction failure is non-fatal),
# 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_IF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_if_usage() {
  sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  return 2
}

_if_log() { # PHASE STEP STATUS MSG
  if [ -n "${LOG_FILE:-}" ]; then
    bash "$_IF_DIR/plog.sh" --log-file "$LOG_FILE" "$@" || true
  else
    bash "$_IF_DIR/plog.sh" "$@" || true
  fi
}

_if_record() {
  local tid="" td="" outcome="" verdict="" corrections=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --ticket-dir | --outcome | --verdict | --corrections | --log-file)
      [ $# -ge 2 ] || return 2
      case "$1" in
      --ticket-dir) td="$2" ;;
      --outcome) outcome="$2" ;;
      --verdict) verdict="$2" ;;
      --corrections) corrections="$2" ;;
      --log-file) LOG_FILE="$2" ;;
      esac
      shift 2
      ;;
    -*) return 2 ;;
    *)
      [ -z "$tid" ] || return 2
      tid="$1"
      shift
      ;;
    esac
  done
  [ -n "$tid" ] && [ -n "$td" ] || return 2
  case "$outcome" in Smooth | Rough | Hard) ;; *) return 2 ;; esac
  case "$verdict" in PASS | FAIL) ;; *) return 2 ;; esac
  [[ "$corrections" =~ ^[0-9]+$ ]] || return 2

  if [ -n "${LOG_FILE:-}" ]; then
    bash "$_IF_DIR/flow-run.sh" --log-file "$LOG_FILE" "$tid" implement-outcome --data "outcome=$outcome" >/dev/null || true
  else
    bash "$_IF_DIR/flow-run.sh" "$tid" implement-outcome --data "outcome=$outcome" >/dev/null || true
  fi
  (
    # shellcheck source=/dev/null
    source "$_IF_DIR/verifier-result.sh"
    write_verifier_result verifier=implement_tests "verdict=$verdict" "outcome=$outcome" \
      "corrections=$corrections" phase=IMPLEMENT
  ) || true

  local predicted mismatch=false wiki=false
  predicted=$(bash -c 'source "$1/notes-parse.sh"; get_complexity "$2"' _ "$_IF_DIR" "$td" 2>/dev/null) || predicted=""
  case "$predicted:$outcome" in
  simple:Rough | simple:Hard | complex:Smooth) mismatch=true ;;
  esac
  grep -q 'Wiki bootstrap:' "$td/notes.md" 2>/dev/null && wiki=true
  echo "PREDICTED=$predicted"
  echo "MISMATCH=$mismatch"
  echo "WIKI_CONSULTED=$wiki"
}

_if_correction() {
  local td="" source="" fact="" detail=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || return 2
    case "$1" in
    --ticket-dir) td="$2" ;;
    --source) source="$2" ;;
    --fact) fact="$2" ;;
    --detail) detail="$2" ;;
    --log-file) LOG_FILE="$2" ;;
    *) return 2 ;;
    esac
    shift 2
  done
  [ -n "$td" ] && [ -n "$source" ] && [ -n "$fact" ] && [ -n "$detail" ] || return 2
  case "$source" in appraise | exec | wiki) ;; *) return 2 ;; esac
  local msg="append_correction failed"
  [ "$source" = wiki ] && msg="append_correction wiki failed"
  if ! (
    # shellcheck source=/dev/null
    source "$_IF_DIR/corrections-parse.sh"
    append_correction "$td/notes.md" "$fact" "$source" "$detail"
  ); then
    _if_log META corrections-error warn "$msg"
  fi
  return 0
}

implement_feedback_main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  local rc=0
  case "$cmd" in
  record) _if_record "$@" || rc=$? ;;
  correction) _if_correction "$@" || rc=$? ;;
  wiki-ok)
    if [ "${1:-}" = --log-file ] && [ -n "${2:-}" ]; then
      LOG_FILE="$2"
    elif [ $# -gt 0 ]; then
      rc=2
    fi
    [ "$rc" = 2 ] || _if_log META wiki-check info "wiki consulted, no gap found"
    ;;
  *) rc=2 ;;
  esac
  [ "$rc" = 2 ] && _if_usage
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  implement_feedback_main "$@"
  exit $?
fi
