#!/usr/bin/env bash
# pr-merge-gate.sh — ticket-pr-review Step 6b: decide whether this run may
# merge the PR, and merge it (skill-deterministic-extraction 2).
#
# Usage:
#   pr-merge-gate.sh [--log-file F] [--skip skipped|gate-blocked]
#                    --repo OWNER/REPO --pr N --base REF --head REF
#                    --worktree PATH <TICKET-ID>
#
# Replaces the Step 6b prose block. The decision order is unchanged, and every
# step fails closed (no merge):
#   0. --skip: the caller already knows this run must not merge (a ⚠️/❌
#      verdict or a blocking ADR verdict → `skipped`; Step 6a's verdict gate
#      refused the transition → `gate-blocked`). No gh call is made.
#   1. merge_blocked_reason (lib/branch-resolve.sh) non-empty → the PR is left
#      for a human (pipeline autonomy, or any epic Merge Policy). The same
#      function Step 6a and auto-merge.sh use, so the three cannot disagree.
#      AUTONOMY / MERGE_POLICY come from the caller's environment (source the
#      ticket env file first); an empty AUTONOMY does not block (unchanged).
#   2. `gh pr checks --json name,state,bucket` (#365: there is no status or
#      conclusion field). A checkless PR exits non-zero with "no checks
#      reported" — that alone is not a failure. Any other non-zero exit, output
#      that is not a JSON array, or an element without a known bucket is a hard
#      block, never "no blocking checks found".
#      Buckets: pass/skipping do not block; pending/fail/cancel block.
#   3. conflict-marker-scan.sh over `git diff origin/BASE...origin/HEAD` in
#      the worktree. Any non-zero scan exit (markers found, unreadable input,
#      or a failed git diff) blocks.
#   4. REST merge (`gh api .../pulls/N/merge -X PUT`, squash) — not
#      `gh pr merge`, whose GraphQL view lags on a new PR. Never forced.
#
# Each refusal message is printed after the result lines and posted as a PR
# comment (REST, best-effort: a failed comment post never turns a block into
# a merge).
#
# Log lines (byte-identical to the Step 6b prose it replaces):
#   PR-REVIEW|merge-decision|start|Merge decision
#   then one of
#   PR-REVIEW|merge-decision|done|skipped | gate-blocked
#   PR-REVIEW|merge-decision|done|skipped: <merge_blocked_reason>
#   PR-REVIEW|merge-decision|done|blocked: checks command failed
#   PR-REVIEW|merge-decision|done|blocked: failing checks
#   PR-REVIEW|merge-decision|done|blocked: conflict markers
#   PR-REVIEW|merge-decision|fail|gh api merge failed for PR #N
#   PR-REVIEW|merge-decision|done|merged
# `done|merged` is what manifest-read.sh and run-summary.sh read as a merge.
#
# Stdout: MERGE_RESULT=merged|skipped|blocked|failed, MERGE_REASON=..., then
# the user-facing message (if any).
# Exit codes: 0 merged; 3 not merged (skip or block); 4 the merge call
# failed; 2 usage.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_PMG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_pmg_usage() {
  echo "Usage: pr-merge-gate.sh [--log-file F] [--skip skipped|gate-blocked] --repo OWNER/REPO --pr N --base REF --head REF --worktree PATH <TICKET-ID>" >&2
  exit 2
}

_pmg_log_file="${LOG_FILE:-${TAP_LOG:-}}"
_pmg_set_log() {
  case "$1" in
  "" | "{"*"}") ;;
  *) _pmg_log_file="$1" ;;
  esac
}

_pmg_log() {
  local status="$1" msg="$2"
  if [ -n "$_pmg_log_file" ]; then
    bash "$_PMG_DIR/plog.sh" --log-file "$_pmg_log_file" PR-REVIEW merge-decision "$status" "$msg" || true
  else
    bash "$_PMG_DIR/plog.sh" PR-REVIEW merge-decision "$status" "$msg" || true
  fi
}

# _pmg_finish <result> <reason> <log-status> <log-msg> <rc> [message]
_pmg_finish() {
  local result="$1" reason="$2" status="$3" msg="$4" rc="$5" message="${6:-}"
  _pmg_log "$status" "$msg"
  echo "MERGE_RESULT=$result"
  echo "MERGE_REASON=$reason"
  if [ -n "$message" ]; then
    echo
    printf '%s\n' "$message"
    gh api "repos/${_pmg_repo}/issues/${_pmg_pr}/comments" -f body="$message" >/dev/null 2>&1 ||
      echo "pr-merge-gate: could not post the PR comment (merge is still blocked)" >&2
  fi
  exit "$rc"
}

_pmg_skip="" _pmg_repo="" _pmg_pr="" _pmg_base="" _pmg_head="" _pmg_wt="" _pmg_tid=""
while [ $# -gt 0 ]; do
  case "$1" in
  --log-file | --skip | --repo | --pr | --base | --head | --worktree)
    [ $# -ge 2 ] || _pmg_usage
    case "$1" in
    --log-file) _pmg_set_log "$2" ;;
    --skip) _pmg_skip="$2" ;;
    --repo) _pmg_repo="$2" ;;
    --pr) _pmg_pr="$2" ;;
    --base) _pmg_base="$2" ;;
    --head) _pmg_head="$2" ;;
    --worktree) _pmg_wt="$2" ;;
    esac
    shift 2
    ;;
  -*) _pmg_usage ;;
  *)
    [ -z "$_pmg_tid" ] || _pmg_usage
    _pmg_tid="$1"
    shift
    ;;
  esac
done
[ -n "$_pmg_tid" ] || _pmg_usage
case "$_pmg_skip" in "" | skipped | gate-blocked) ;; *) _pmg_usage ;; esac

# Inputs the gh calls depend on; checked before anything is logged.
if [ -z "$_pmg_skip" ]; then
  if ! [[ "$_pmg_pr" =~ ^[0-9]+$ ]] || ! [[ "$_pmg_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    [ -z "$_pmg_base" ] || [ -z "$_pmg_head" ] || [ -z "$_pmg_wt" ]; then
    _pmg_usage
  fi
fi

_pmg_log start "Merge decision"

if [ -n "$_pmg_skip" ]; then
  echo "MERGE_RESULT=skipped"
  echo "MERGE_REASON=$_pmg_skip"
  _pmg_log done "$_pmg_skip"
  exit 3
fi

# 1. Merge authorization.
# shellcheck source=branch-resolve.sh
declare -f merge_blocked_reason >/dev/null 2>&1 || source "$_PMG_DIR/branch-resolve.sh" 2>/dev/null || true
if ! declare -f merge_blocked_reason >/dev/null 2>&1; then
  _pmg_finish skipped "merge_blocked_reason unavailable" done \
    "skipped: merge_blocked_reason unavailable" 3
fi
_pmg_reason=$(merge_blocked_reason "$_pmg_tid") || _pmg_reason="merge authorization could not be determined"
if [ -n "$_pmg_reason" ]; then
  _pmg_finish skipped "$_pmg_reason" done "skipped: $_pmg_reason" 3 \
    "✅ PR #${_pmg_pr} passed review and is ready to merge, but requires a human: ${_pmg_reason}.

Merge it yourself once you're ready:
gh pr merge ${_pmg_pr} --repo ${_pmg_repo} --squash"
fi

# 2. CI checks.
_pmg_checks_rc=0
_pmg_checks_json=$(gh pr checks "$_pmg_pr" --repo "$_pmg_repo" --json name,state,bucket 2>&1) || _pmg_checks_rc=$?
_pmg_checks_none=false
if [ "$_pmg_checks_rc" -ne 0 ] && grep -qi "no checks reported" <<<"$_pmg_checks_json"; then
  _pmg_checks_none=true
fi

if [ "$_pmg_checks_none" = false ]; then
  if [ "$_pmg_checks_rc" -ne 0 ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$_pmg_checks_json"; then
    _pmg_finish blocked "checks command failed" done "blocked: checks command failed" 3 \
      "⛔ PR #${_pmg_pr} — could not read CI check status, merge blocked.

\`gh pr checks\` failed or returned unparseable output:
${_pmg_checks_json}

Investigate the checks command failure and re-run \`/ticket-pr-review ${_pmg_tid}\` or merge
manually once you've confirmed checks are green."
  fi
  # Anything but pass/skipping blocks — including an unknown or missing bucket.
  _pmg_blocking=$(jq -r '[.[] | select(((.bucket // "") | IN("pass", "skipping")) | not)] | length' \
    <<<"$_pmg_checks_json" 2>/dev/null) || _pmg_blocking="unknown"
  if [ "$_pmg_blocking" != "0" ]; then
    _pmg_rows=$(jq -r '.[] | "| \(.name // "?") | \(.state // "?") | \(.bucket // "?") |"' \
      <<<"$_pmg_checks_json" 2>/dev/null) || _pmg_rows="| ? | ? | ? |"
    _pmg_finish blocked "failing checks" done "blocked: failing checks" 3 \
      "⛔ PR #${_pmg_pr} has failing or pending build checks — merge blocked.

| Check | State | Bucket |
|-------|-------|--------|
${_pmg_rows}

Fix the failing checks and re-run \`/ticket-pr-review ${_pmg_tid}\` or merge manually once they pass."
  fi
fi

# 3. Conflict markers (a setext `=======` underline never blocks).
_pmg_cms_rc=0
_pmg_cms_out=$(
  set -o pipefail
  git -C "$_pmg_wt" diff "origin/${_pmg_base}...origin/${_pmg_head}" 2>/dev/null |
    bash "$_PMG_DIR/conflict-marker-scan.sh"
) || _pmg_cms_rc=$?
if [ "$_pmg_cms_rc" -ne 0 ]; then
  [ -n "$_pmg_cms_out" ] || _pmg_cms_out="(scan could not run: exit ${_pmg_cms_rc})"
  _pmg_finish blocked "conflict markers" done "blocked: conflict markers" 3 \
    "⛔ PR #${_pmg_pr} contains conflict markers — merge blocked.

Lines with conflict markers:
${_pmg_cms_out}

Resolve the conflicts on the branch and re-run \`/ticket-pr-review ${_pmg_tid}\`."
fi

# 4. Merge.
if ! gh api "repos/${_pmg_repo}/pulls/${_pmg_pr}/merge" -X PUT -f merge_method=squash >/dev/null 2>&1; then
  echo "ERROR: REST API merge failed for PR #${_pmg_pr}" >&2
  bash "$_PMG_DIR/hb-wrap.sh" retry "pr-merge" "fail" "REST API merge failed for PR #${_pmg_pr}" \
    "{\"pr_number\":\"${_pmg_pr}\",\"owner\":\"${_pmg_repo%%/*}\",\"repo\":\"${_pmg_repo#*/}\"}" >/dev/null 2>&1 || true
  _pmg_log fail "gh api merge failed for PR #${_pmg_pr}"
  echo "MERGE_RESULT=failed"
  echo "MERGE_REASON=gh api merge failed"
  exit 4
fi
_pmg_finish merged "" done "merged" 0
