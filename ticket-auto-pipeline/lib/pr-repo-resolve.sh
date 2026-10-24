#!/usr/bin/env bash
# pr-repo-resolve.sh — resolve the GitHub `owner/repo` a ticket's PR lives in,
# so every `gh pr` call can carry `--repo` (review finding DET-IP-4, a
# regression of GitHub #366 / PR_REVIEW_REPO_UNSCOPED).
#
# Usage: pr-repo-resolve.sh <TICKET-ID> [--log-file <LOG>] [--ticket-dir <DIR>]
#
# Skills run with cwd forced to the `tickets` workspace — itself a git repo
# with no code PRs — so a bare `gh pr list`/`gh pr view` resolves against the
# wrong repo and silently returns nothing. Resolution order (first hit wins):
#   1. The latest `META|pr-created` record's `repo` in the pipeline log
#      (lib/manifest-read.sh's ticket_pipeline_pr_ref).
#   2. The `origin` remote of the ticket's worktrees under
#      $REPOS_ROOT/.ticket-auto/worktrees/<TID>/*. Exactly one distinct slug
#      is required; more than one is ambiguous (exit 3).
#   3. The `origin` remote of the last `Worktree:` path in <DIR>/notes.md
#      (ticket-implement's pre-implementation checkpoint).
# Remote URLs are parsed by pr-evidence.sh's strict `_pe_origin_slug`
# (https, scp-style and ssh:// GitHub forms; anything else is no slug).
#
# Output: the slug on stdout. Exit 0 resolved; 1 unresolvable; 3 ambiguous;
# 2 usage error.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.

_PRR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pr-evidence.sh
declare -f _pe_origin_slug >/dev/null 2>&1 || source "$_PRR_DIR/pr-evidence.sh" 2>/dev/null || true
# shellcheck source=manifest-read.sh
declare -f ticket_pipeline_pr_ref >/dev/null 2>&1 || source "$_PRR_DIR/manifest-read.sh" 2>/dev/null || true

pr_repo_resolve() {
  local tid="" log="${LOG_FILE:-}" tdir=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --log-file | --ticket-dir)
      [ $# -ge 2 ] || return 2
      if [ "$1" = "--log-file" ]; then log="$2"; else tdir="$2"; fi
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
  [ -n "$tid" ] || return 2

  # 1. META|pr-created
  local ref repo
  if [ -n "$log" ] && [ -f "$log" ] && declare -f ticket_pipeline_pr_ref >/dev/null 2>&1; then
    ref=$(ticket_pipeline_pr_ref "$log" 2>/dev/null) || ref=""
    repo=$(printf '%s\n' "$ref" | cut -f3)
    if [[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
      echo "$repo"
      return 0
    fi
  fi

  declare -f _pe_origin_slug >/dev/null 2>&1 || return 1

  # 2. The ticket's worktrees
  local wt slug slugs=""
  if [ -n "${REPOS_ROOT:-}" ] && [ -d "$REPOS_ROOT/.ticket-auto/worktrees/$tid" ]; then
    for wt in "$REPOS_ROOT/.ticket-auto/worktrees/$tid"/*/; do
      [ -d "$wt" ] || continue
      slug=$(_pe_origin_slug "${wt%/}" 2>/dev/null) || slug=""
      [ -n "$slug" ] && slugs="${slugs}${slug}"$'\n'
    done
  fi
  slugs=$(printf '%s' "$slugs" | sed '/^$/d' | sort -u)
  local n
  n=$(printf '%s' "$slugs" | grep -c . || true)
  if [ "${n:-0}" -gt 1 ]; then
    echo "pr-repo-resolve: $tid has worktrees in several repos: $(echo "$slugs" | tr '\n' ' ')" >&2
    return 3
  fi
  if [ "${n:-0}" -eq 1 ]; then
    echo "$slugs"
    return 0
  fi

  # 3. notes.md checkpoint
  if [ -n "$tdir" ] && [ -f "$tdir/notes.md" ]; then
    wt=$(grep "Worktree:" "$tdir/notes.md" 2>/dev/null | tail -1 |
      sed -n 's/.*Worktree: \([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//; s/^`//; s/`$//')
    if [ -n "$wt" ]; then
      slug=$(_pe_origin_slug "$wt" 2>/dev/null) || slug=""
      if [ -n "$slug" ]; then
        echo "$slug"
        return 0
      fi
    fi
  fi
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rc=0
  pr_repo_resolve "$@" || rc=$?
  [ "$rc" = 2 ] && echo "Usage: pr-repo-resolve.sh <TICKET-ID> [--log-file <LOG>] [--ticket-dir <DIR>]" >&2
  exit "$rc"
fi
