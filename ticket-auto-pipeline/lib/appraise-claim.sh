#!/usr/bin/env bash
# appraise-claim.sh — ticket-appraise Step 4: claim the ticket if nobody has,
# and record the complexity score as its own fact (GitHub #767).
#
# Usage:
#   appraise-claim.sh [--log-file F] <TICKET-ID> --complexity simple|complex
#
# Why this exists: Step 4 used to fire `appraise-start` unconditionally. Under
# /ticket-auto the router has already fired it before the appraise agent was
# spawned (dispatch-table.json STEP_1 pre_dispatch, complexity=simple as a
# placeholder), so every appraisal wrote two `appraise-started` records for
# one fact. flow.sh emits one event per invocation by design, so the fix is
# here, at the second caller.
#
#   1. Claim. The ticket is already claimed when its manifest stage is `Todo`
#      — the stage `appraise-start` itself sets. Only otherwise (standalone
#      /ticket-appraise: no stage yet, Backlog, ...) does this fire
#      `flow-run.sh <TID> appraise-start --data complexity=<C>`. A flow
#      failure is logged by flow-run.sh and is non-fatal, as before.
#   2. Score. Always emits `complexity-scored {complexity}` to the outbox.
#      This is the authoritative complexity: `appraise-started.complexity` is
#      only what was known at claim time. Idempotency key
#      `{tid}:complexity-scored:{rev}:{complexity}`, rev being the manifest's
#      transition counter: re-running Step 4 inside one appraisal is a no-op,
#      a corrected score or a later re-appraisal (rev has moved) emits again.
#
# Prints CLAIMED=fired|already|failed and SCORED=emitted|failed.
# Exit codes: 0 done (flow / emit failures are non-fatal), 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_AC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ac_usage() {
  echo "Usage: appraise-claim.sh [--log-file F] <TICKET-ID> --complexity simple|complex" >&2
  return 2
}

_ac_main() {
  local tid="" complexity="" log="${LOG_FILE:-${TAP_LOG:-}}"
  while [ $# -gt 0 ]; do
    case "$1" in
    --log-file | --complexity)
      [ $# -ge 2 ] || return 2
      case "$1" in
      --log-file)
        # An unsubstituted skill placeholder is not a path (flow-run.sh rule).
        case "$2" in "" | "{"*"}") ;; *) log="$2" ;; esac
        ;;
      --complexity) complexity="$2" ;;
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
  [[ "$tid" =~ ^[A-Z]+-[0-9]+$ ]] || return 2
  case "$complexity" in simple | complex) ;; *) return 2 ;; esac

  declare -f get_ticket_manifest_field >/dev/null 2>&1 ||
    source "$_AC_DIR/manifest-read.sh" 2>/dev/null || true

  local stage=""
  if declare -f get_ticket_manifest_field >/dev/null 2>&1; then
    stage=$(get_ticket_manifest_field "$tid" stage 2>/dev/null) || stage=""
  fi

  local claimed="already"
  if [ "$stage" != "Todo" ]; then
    claimed="fired"
    if [ -n "$log" ]; then
      bash "$_AC_DIR/flow-run.sh" --log-file "$log" "$tid" appraise-start \
        --data "complexity=$complexity" >/dev/null || claimed="failed"
    else
      bash "$_AC_DIR/flow-run.sh" "$tid" appraise-start \
        --data "complexity=$complexity" >/dev/null || claimed="failed"
    fi
  fi

  local rev=""
  if declare -f get_ticket_manifest_field >/dev/null 2>&1; then
    rev=$(get_ticket_manifest_field "$tid" rev 2>/dev/null) || rev=""
  fi
  [[ "$rev" =~ ^[0-9]+$ ]] || rev=0

  local scored="failed"
  declare -f emit_event >/dev/null 2>&1 || source "$_AC_DIR/events.sh" 2>/dev/null || true
  if declare -f emit_event >/dev/null 2>&1 &&
    emit_event --idem "${tid}:complexity-scored:${rev}:${complexity}" "$tid" complexity-scored \
      "$(jq -nc --arg c "$complexity" '{complexity: $c}')" >/dev/null; then
    scored="emitted"
  fi

  echo "CLAIMED=$claimed"
  echo "SCORED=$scored"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _ac_main "$@"
  _ac_rc=$?
  [ "$_ac_rc" -ne 2 ] || _ac_usage
  exit "$_ac_rc"
fi
