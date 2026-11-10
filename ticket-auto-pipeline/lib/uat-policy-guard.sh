#!/usr/bin/env bash
# uat-policy-guard.sh — ticket-verify Step 1b4 (skill-deterministic-extraction 4).
#
#   uat_policy_guard <TICKET-ID> <local|uat>
#   uat-policy-guard.sh <TICKET-ID> --env local|uat
#
# Refuses a UAT verification run for a child whose resolved UAT policy is
# `epic`: the epic branch is not deployed to the UAT environment until the
# epic's integration PRs merge, so a UAT result for one child is meaningless
# whichever way it lands. Without this guard `uat-pass` would close the child
# straight to Done, bypassing the policy resolved at PR review (the second
# UAT decision site).
#
# Policy: $UAT_POLICY when set, else resolve_uat_policy (branch-resolve.sh,
# manifest-only, never fails), else per-ticket.
#
# Exit codes:
#   0  proceed — local verification (policy never consulted), or a UAT run
#      under per-ticket policy
#   3  refused — explanation on stderr; writes META|uat-policy|info|epic and
#      VERIFY|uat-policy-guard|skip|refused --env uat under epic policy
#      through plog.sh. Never fires a trigger: the ticket is left as it was.
#   2  usage
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_UPG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uat_policy_guard() {
  local tid="${1:-}" env="${2:-}" policy
  case "$env" in
  local) return 0 ;;
  uat) ;;
  *)
    echo "uat_policy_guard: env must be local or uat, got '${env}'" >&2
    return 2
    ;;
  esac
  [ -n "$tid" ] || {
    echo "uat_policy_guard: ticket id required" >&2
    return 2
  }
  if ! declare -f resolve_uat_policy >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_UPG_DIR/branch-resolve.sh" 2>/dev/null || true
  fi
  policy="${UAT_POLICY:-}"
  if [ -z "$policy" ] && declare -f resolve_uat_policy >/dev/null 2>&1; then
    policy=$(resolve_uat_policy "$tid" 2>/dev/null)
  fi
  policy="${policy:-per-ticket}"

  [ "$policy" = "epic" ] || return 0
  echo "ticket-verify: refusing --env uat for ${tid} — its epic declares 'UAT Policy: epic'." >&2
  echo "The epic branch is not deployed to the UAT environment until the epic's integration PRs" >&2
  echo "are merged, so a UAT result for one child cannot be valid. Acceptance for this ticket" >&2
  echo "happens at the epic level. Use --env local to verify the code change itself." >&2
  bash "$_UPG_DIR/plog.sh" META uat-policy info "${policy}"
  bash "$_UPG_DIR/plog.sh" VERIFY uat-policy-guard skip "refused --env uat under epic policy"
  return 3
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _upg_tid="" _upg_env=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --env)
      [ $# -ge 2 ] || {
        echo "usage: uat-policy-guard.sh <TICKET-ID> --env local|uat" >&2
        exit 2
      }
      _upg_env="$2"
      shift 2
      ;;
    *)
      _upg_tid="$1"
      shift
      ;;
    esac
  done
  uat_policy_guard "$_upg_tid" "$_upg_env"
  exit $?
fi
