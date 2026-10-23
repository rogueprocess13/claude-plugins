#!/usr/bin/env bash
# implement-diff-check.sh — the writer of the `IMPLEMENT|commit-push|skip|`
# contract (review finding DET-IP-9).
#
# Usage: implement-diff-check.sh --base-ref <REF> [--log-file <LOG>] <WORKTREE>...
#
# ticket-pr-review's no-diff exemption keys on `IMPLEMENT|commit-push|skip|`
# (a verification-only ticket legitimately produces no PR), but nothing ever
# wrote that line, so such a ticket fell into pr-review's "No open PR found"
# error path. ticket-implement Step 5 runs this before committing.
#
# A worktree "has a diff" when either holds:
#   * `git status --porcelain` is non-empty (uncommitted or untracked,
#     non-ignored changes), or
#   * HEAD has commits not in <REF> (`git rev-list --count <REF>..HEAD` > 0 —
#     e.g. committed on an earlier, crashed attempt but not yet pushed).
# A ref that cannot be resolved counts as a diff: the skip line is only ever
# written on positive evidence of "nothing to ship", never on a git error.
#
# Exit codes: 0 at least one worktree has a diff (commit and push as usual);
#             4 no worktree has a diff — `IMPLEMENT|commit-push|skip|...`
#               written to --log-file (or $LOG_FILE), nothing to commit;
#             2 usage error or a worktree path that is not a git checkout.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_idc_usage() {
  echo "Usage: implement-diff-check.sh --base-ref <REF> [--log-file <LOG>] <WORKTREE>..." >&2
  exit 2
}

# _idc_has_diff <worktree> <ref> — rc 0 diff present, 1 clean.
_idc_has_diff() {
  local wt="$1" ref="$2" status ahead
  status=$(git -C "$wt" status --porcelain 2>/dev/null) || return 0
  [ -z "$status" ] || return 0
  git -C "$wt" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 || return 0
  ahead=$(git -C "$wt" rev-list --count "${ref}..HEAD" 2>/dev/null) || return 0
  [ "${ahead:-0}" -gt 0 ] && return 0
  return 1
}

implement_diff_check() {
  local base_ref="" log="${LOG_FILE:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
    --base-ref | --log-file)
      [ $# -ge 2 ] || _idc_usage
      if [ "$1" = "--base-ref" ]; then base_ref="$2"; else log="$2"; fi
      shift 2
      ;;
    -*) _idc_usage ;;
    *) break ;;
    esac
  done
  [ -n "$base_ref" ] && [ $# -ge 1 ] || _idc_usage

  local wt
  for wt in "$@"; do
    if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "implement-diff-check: not a git checkout: $wt" >&2
      return 2
    fi
  done
  for wt in "$@"; do
    if _idc_has_diff "$wt" "$base_ref"; then
      echo "IMPLEMENT_DIFF=present"
      return 0
    fi
  done

  echo "IMPLEMENT_DIFF=none"
  if [ -n "$log" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|commit-push|skip|no source diff against ${base_ref} — verification-only ticket, nothing to commit or push" >>"$log"
  fi
  return 4
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rc=0
  implement_diff_check "$@" || rc=$?
  exit "$rc"
fi
