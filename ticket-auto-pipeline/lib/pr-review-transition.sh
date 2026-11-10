#!/usr/bin/env bash
# pr-review-transition.sh — ticket-pr-review Step 6a: fire the one Review
# transition a review verdict calls for (skill-deterministic-extraction 2).
#
# Usage:
#   pr-review-transition.sh [--log-file F] --verdict pass|gaps <TICKET-ID>
#
# Replaces the Step 6a prose block:
#   gaps → flow-run.sh pr-review-fail (no verdict gate, so never exit 11).
#   pass → the trigger comes from uat_decide_trigger (lib/branch-resolve.sh),
#          the single UAT-vs-Done decision site, evaluated policy-first:
#            policy = $UAT_POLICY → resolve_uat_policy <TID> → per-ticket
#          and merge authorization is checked BEFORE the transition (#412): a
#          non-empty merge_blocked_reason passes --merge-pending, so a PR left
#          for a human merge never closes a per-ticket ticket to Done.
#          Under `epic` the trigger is pr-review-pass-done regardless.
# flow-run.sh is called exactly once.
#
# Environment: UAT_POLICY / AUTONOMY / MERGE_POLICY as the ticket env file
# exports them (source ticket-env.sh first); each falls back to standalone
# resolution, exactly as the prose did.
#
# Log lines (pass only; byte-identical to the prose):
#   META|uat-policy|info|<policy>
#   META|uat-decision|info|trigger=<trigger>; merge pending: <reason>   (merge pending only)
# flow-run.sh writes its own failure records (META|flow-error, or
# META|gate-stop|fail|VERDICT_GATE_BLOCKED on exit 11).
#
# Stdout: TRIGGER=<trigger>, FLOW_RC=<rc>, GATE_BLOCKED=true|false.
# Exit codes: 11 the verdict gate refused the transition (Step 6b must not
# merge; Step 8 reports BLOCK); 0 otherwise — any other flow failure is
# already logged and non-fatal, as before; 2 usage.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_PRT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_prt_usage() {
  echo "Usage: pr-review-transition.sh [--log-file F] --verdict pass|gaps <TICKET-ID>" >&2
  exit 2
}

_prt_log_file="${LOG_FILE:-${TAP_LOG:-}}"
_prt_verdict="" _prt_tid=""
while [ $# -gt 0 ]; do
  case "$1" in
  --log-file | --verdict)
    [ $# -ge 2 ] || _prt_usage
    if [ "$1" = --verdict ]; then
      _prt_verdict="$2"
    else
      case "$2" in "" | "{"*"}") ;; *) _prt_log_file="$2" ;; esac
    fi
    shift 2
    ;;
  -*) _prt_usage ;;
  *)
    [ -z "$_prt_tid" ] || _prt_usage
    _prt_tid="$1"
    shift
    ;;
  esac
done
[ -n "$_prt_tid" ] || _prt_usage
case "$_prt_verdict" in pass | gaps) ;; *) _prt_usage ;; esac

_prt_plog() {
  if [ -n "$_prt_log_file" ]; then
    bash "$_PRT_DIR/plog.sh" --log-file "$_prt_log_file" "$@" || true
  else
    bash "$_PRT_DIR/plog.sh" "$@" || true
  fi
}

if [ "$_prt_verdict" = gaps ]; then
  _prt_trigger=pr-review-fail
else
  # shellcheck source=branch-resolve.sh
  declare -f uat_decide_trigger >/dev/null 2>&1 || source "$_PRT_DIR/branch-resolve.sh"

  _prt_policy="${UAT_POLICY:-}"
  [ -n "$_prt_policy" ] || _prt_policy=$(resolve_uat_policy "$_prt_tid" 2>/dev/null) || _prt_policy=""
  _prt_policy="${_prt_policy:-per-ticket}"

  _prt_pending=()
  _prt_reason=$(merge_blocked_reason "$_prt_tid") || _prt_reason=""
  [ -z "$_prt_reason" ] || _prt_pending=(--merge-pending)

  _prt_trigger=$(uat_decide_trigger --policy "$_prt_policy" "${_prt_pending[@]}")

  # Record the decision so any Done reached without an individual UAT step is
  # explainable from the log alone.
  _prt_plog META uat-policy info "$_prt_policy"
  if [ -n "$_prt_reason" ]; then
    _prt_plog META uat-decision info "trigger=${_prt_trigger}; merge pending: ${_prt_reason}"
  fi
fi

_prt_rc=0
bash "$_PRT_DIR/flow-run.sh" --log-file "${_prt_log_file:-}" "$_prt_tid" "$_prt_trigger" >&2 || _prt_rc=$?

_prt_blocked=false
[ "$_prt_rc" -ne 11 ] || _prt_blocked=true
echo "TRIGGER=$_prt_trigger"
echo "FLOW_RC=$_prt_rc"
echo "GATE_BLOCKED=$_prt_blocked"
[ "$_prt_blocked" = false ] || exit 11
exit 0
