#!/usr/bin/env bash
# auto-merge.sh — the router's post-PR-review auto-merge decision and merge.
#
# Usage:
#   auto-merge.sh [--complexity simple|complex] [--autonomy MODE]
#                 [--merge-policy POLICY] [--integration-branch BRANCH]
#                 [--env-file FILE] [--dry-run] <TICKET-ID> <LOG-FILE>
#
# Replaces the inline "Auto-merge logic" block in ticket-auto/SKILL.md, which
# (a) never consulted MERGE_POLICY — an epic declaring `Merge Policy: manual`
# still had its child PRs `gh pr merge --auto`-ed by the router — and (b)
# failed OPEN on a `gh pr view` error: an unreadable head ref was read as
# "not the integration branch" and the PR merged. fleetd's
# orchestration.run_auto_merge applies the same rules (it mirrors this file;
# see its docstring).
#
# Decision order (first match wins; every skip is fail-closed):
#   1. merge_blocked_reason (lib/branch-resolve.sh) non-empty → skip. That is
#      the same merge-authorization rule ticket-pr-review Step 6b applies:
#      AUTONOMY other than auto/semi-auto, or any epic MERGE_POLICY, requires
#      a human merge. AUTONOMY must additionally be auto or semi-auto here —
#      an unset AUTONOMY never auto-merges from the router.
#   2. COMPLEXITY must be `simple`.
#   3. The latest META|outcome-label|info| must read `Smooth`.
#   4. A PR number must be recorded (PR-REVIEW|checkout-pr|done|<n>).
#   5. With INTEGRATION_BRANCH set, the PR head ref must be readable AND
#      differ from it (an unreadable head ref skips — never merges).
#   6. gh pr merge <n> --squash --auto.
#
# Inputs: flags win over the agent env file (/tmp/ticket-auto-<TID>-env.sh,
# or --env-file), which wins over the process environment. COMPLEXITY is not
# in the env file — the router passes detect-resume's value via --complexity.
#
# Output (stdout): AUTO_MERGE=merged|skipped|failed and AUTO_MERGE_REASON=...
# Exit codes: 0 merged (or would merge, with --dry-run); 3 skipped;
#             4 `gh pr merge` failed (soft — the caller continues); 2 usage.
#
# Log lines written: META|pr-auto-merge|skip|<reason> for the policy skip,
# the integration guard and the unreadable head ref; META|pr-auto-merge|done|<n>
# on a merge. Plain eligibility skips (complexity, outcome, no PR) are silent,
# as they were before.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_AM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_am_usage() {
  echo "Usage: auto-merge.sh [--complexity C] [--autonomy A] [--merge-policy P] [--integration-branch B] [--env-file F] [--dry-run] <TICKET-ID> <LOG-FILE>" >&2
  exit 2
}

_am_log() {
  [ -n "$_AM_LOG" ] || return 0
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|pr-auto-merge|$1|$2" >>"$_AM_LOG" 2>/dev/null || true
}

_am_out() {
  echo "AUTO_MERGE=$1"
  echo "AUTO_MERGE_REASON=$2"
}

# _am_last_msg <log> <prefix> — field 5.. of the last line containing prefix.
_am_last_msg() {
  grep -F -- "$2" "$1" 2>/dev/null | tail -1 |
    awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' || true
}

main() {
  local f_complexity="" f_autonomy="" f_policy="" f_integration="" env_file="" dry_run=0
  local set_c=0 set_a=0 set_p=0 set_i=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --complexity | --autonomy | --merge-policy | --integration-branch | --env-file)
      [ $# -ge 2 ] || _am_usage
      case "$1" in
      --complexity) f_complexity="$2" set_c=1 ;;
      --autonomy) f_autonomy="$2" set_a=1 ;;
      --merge-policy) f_policy="$2" set_p=1 ;;
      --integration-branch) f_integration="$2" set_i=1 ;;
      --env-file) env_file="$2" ;;
      esac
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*) _am_usage ;;
    *) break ;;
    esac
  done
  [ $# -eq 2 ] || _am_usage
  local tid="$1"
  _AM_LOG="$2"
  [ -n "$tid" ] && [ -n "$_AM_LOG" ] || _am_usage

  # Precedence: process env < env file < flags.
  [ -n "$env_file" ] || env_file="/tmp/ticket-auto-${tid}-env.sh"
  if [ -f "$env_file" ]; then
    # shellcheck disable=SC1090
    source "$env_file" 2>/dev/null || true
  fi
  [ "$set_c" = 1 ] && COMPLEXITY="$f_complexity"
  [ "$set_a" = 1 ] && AUTONOMY="$f_autonomy"
  [ "$set_p" = 1 ] && MERGE_POLICY="$f_policy"
  [ "$set_i" = 1 ] && INTEGRATION_BRANCH="$f_integration"

  # shellcheck source=branch-resolve.sh
  source "$_AM_DIR/branch-resolve.sh" 2>/dev/null || true
  if ! declare -f merge_blocked_reason >/dev/null 2>&1; then
    _am_out skipped "merge_blocked_reason unavailable"
    return 3
  fi

  # 1. Merge authorization — the shared rule.
  local blocked
  blocked=$(AUTONOMY="${AUTONOMY:-}" MERGE_POLICY="${MERGE_POLICY:-}" merge_blocked_reason "$tid") || blocked=""
  if [ -n "$blocked" ]; then
    _am_log skip "MERGE_AUTHORIZATION: ${blocked}"
    _am_out skipped "$blocked"
    return 3
  fi
  case "${AUTONOMY:-}" in
  auto | semi-auto) ;;
  *)
    _am_out skipped "autonomy=${AUTONOMY:-unset}"
    return 3
    ;;
  esac

  # 2. Complexity.
  if [ "${COMPLEXITY:-}" != "simple" ]; then
    _am_out skipped "complexity=${COMPLEXITY:-unset}"
    return 3
  fi

  # 3. Outcome label (never the IMPLEMENT terminal line).
  local outcome
  outcome=$(_am_last_msg "$_AM_LOG" '|META|outcome-label|info|')
  if [ "$outcome" != "Smooth" ]; then
    _am_out skipped "outcome=${outcome:-unrecorded}"
    return 3
  fi

  # 4. PR number — resolved BEFORE the integration guard.
  local pr_num
  pr_num=$(_am_last_msg "$_AM_LOG" '|PR-REVIEW|checkout-pr|done|' | grep -oE '[0-9]+' | head -1) || pr_num=""
  if [ -z "$pr_num" ]; then
    _am_out skipped "no PR number recorded"
    return 3
  fi

  # Repo scope: the META|pr-created record for this same PR, when there is one.
  local repo_args=() ref ref_pr ref_repo
  if declare -f ticket_pipeline_pr_ref >/dev/null 2>&1; then
    ref=$(ticket_pipeline_pr_ref "$_AM_LOG") || ref=""
    ref_pr=$(printf '%s\n' "$ref" | cut -f2)
    ref_repo=$(printf '%s\n' "$ref" | cut -f3)
    if [ -n "$ref_repo" ] && [ "$ref_pr" = "$pr_num" ]; then
      repo_args=(--repo "$ref_repo")
    fi
  fi

  # 5. Integration-PR guard — fail closed.
  if [ -n "${INTEGRATION_BRANCH:-}" ]; then
    local head rc=0
    head=$(gh pr view "$pr_num" "${repo_args[@]}" --json headRefName --jq '.headRefName' 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$head" ]; then
      _am_log skip "PR_HEAD_UNREADABLE: could not read PR ${pr_num} head ref, not auto-merging"
      _am_out skipped "could not read PR ${pr_num} head ref"
      return 3
    fi
    if [ "$head" = "$INTEGRATION_BRANCH" ]; then
      _am_log skip "INTEGRATION_PR_GUARD: ${pr_num} is integration PR, not auto-merging"
      _am_out skipped "${pr_num} is an integration PR"
      return 3
    fi
  fi

  if [ "$dry_run" = 1 ]; then
    _am_out merged "dry-run: would merge ${pr_num}"
    return 0
  fi

  # 6. Merge (soft failure).
  if gh pr merge "$pr_num" "${repo_args[@]}" --squash --auto >/dev/null 2>&1; then
    _am_log "done" "$pr_num"
    _am_out merged "merged ${pr_num}"
    return 0
  fi
  _am_out failed "gh pr merge ${pr_num} failed"
  return 4
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _AM_LOG=""
  rc=0
  main "$@" || rc=$?
  exit "$rc"
fi
