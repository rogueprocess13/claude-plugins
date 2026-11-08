#!/usr/bin/env bash
# gitnexus-refresh.sh — best-effort GitNexus re-index after a ticket's PR
# (GitHub #609).
#
# gitnexus_verify_branch (gitnexus-preflight.sh) detects a stale index, but
# nothing refreshed it: every later ticket on the same repo fell back to grep,
# and the lag grew with each merge. The router runs this script in MAINTENANCE
# (STEP_5), after the PR review, so the analyze cost stays off the review path.
#
# Usage:
#   gitnexus-refresh.sh [--repo OWNER/NAME] [--base BRANCH] [--env-file FILE]
#                       <TICKET-ID> <LOG-FILE>
#
# Inputs:
#   repo  --repo, else the `repo` of the ticket's META|pr-created record
#         (ticket_pipeline_pr_ref, manifest-read.sh).
#   base  --base, else the PR's baseRefName (`gh pr view`), else
#         INTEGRATION_BRANCH, else BASE_BRANCH from the agent env file
#         (/tmp/ticket-auto-<TID>-env.sh, or --env-file).
#   The indexed clones come from the GitNexus registry (GITNEXUS_REGISTRY,
#   default ~/.gitnexus/registry.json): every entry whose remoteUrl names
#   OWNER/NAME.
#
# For each indexed clone, under a per-clone lock (flock -n, else mkdir), it:
#   1. skips unless the clone has <base> checked out (never switches branches
#      in a shared clone; a detached HEAD is skipped too),
#   2. skips a dirty clone (tracked changes outside .gitnexus/),
#   3. fast-forwards it from origin/<base> (`git pull --ff-only`; never
#      resets, so a tracked .gitnexus/ is left alone),
#   4. skips when the registry's lastCommit already equals HEAD,
#   5. runs `timeout GITNEXUS_REFRESH_TIMEOUT gitnexus analyze --skip-agents-md
#      <path>` (default 300 s). --skip-agents-md keeps analyze from editing
#      AGENTS.md / CLAUDE.md in the shared clone.
#   The merge does not have to have landed yet (`gh pr merge --auto` merges
#   later): the step catches the clone up to whatever is on <base>, so the next
#   ticket's MAINTENANCE picks up a merge this one missed.
#
# Log lines (one per indexed clone, or one for the whole run when nothing is
# indexed). They are META lines on purpose: detect-resume.sh reads
# MAINTENANCE|*|done lines as resume points.
#   META|gitnexus-refresh|done|<name> <old7>→<new7>
#   META|gitnexus-refresh|skip|<name>: <reason>
#   META|gitnexus-refresh|warn|<name>: <failure> — run: gitnexus analyze <path>
#
# Never fails the pipeline: exit 0 on every refresh outcome, 2 on bad usage.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -o pipefail

_GR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GR_LOG=""

_gr_usage() {
  echo "Usage: gitnexus-refresh.sh [--repo OWNER/NAME] [--base BRANCH] [--env-file FILE] <TICKET-ID> <LOG-FILE>" >&2
  exit 2
}

_gr_log() {
  [ -n "$_GR_LOG" ] || return 0
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gitnexus-refresh|$1|$2" >>"$_GR_LOG" 2>/dev/null || true
}

# _gr_slug <url> — owner/name of a git remote URL, lower-cased.
_gr_slug() {
  local u="${1%/}"
  u="${u%.git}"
  u="${u##*:}" # git@host:owner/name → owner/name (and drops an https scheme's host)
  printf '%s\n' "$u" | awk -F/ 'NF>=2 {print tolower($(NF-1) "/" $NF)}'
}

_gr_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=30 "$@"
  else
    shift
    "$@"
  fi
}

# _gr_refresh_one <name> <path> <indexed_commit> <base>
_gr_refresh_one() {
  local name="$1" path="$2" old="$3" base="$4"
  local lock_dir="${GITNEXUS_REFRESH_LOCK_DIR:-/tmp}" key lock fd="" branch new rc

  if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _gr_log skip "${name}: ${path} is not a git work tree"
    return 0
  fi

  key="$(printf '%s' "$path" | cksum | cut -d' ' -f1)"
  lock="${lock_dir}/gitnexus-refresh-${key}.lock"
  if command -v flock >/dev/null 2>&1; then
    exec {fd}>"$lock" || {
      _gr_log skip "${name}: cannot open lock ${lock}"
      return 0
    }
    if ! flock -n "$fd"; then
      exec {fd}>&-
      _gr_log skip "${name}: another refresh of ${path} is running"
      return 0
    fi
  elif ! mkdir "${lock}.d" 2>/dev/null; then
    _gr_log skip "${name}: another refresh of ${path} is running"
    return 0
  fi

  _gr_refresh_locked "$name" "$path" "$old" "$base"

  if [ -n "$fd" ]; then
    exec {fd}>&-
  else
    rmdir "${lock}.d" 2>/dev/null || true
  fi
  return 0
}

_gr_refresh_locked() {
  local name="$1" path="$2" old="$3" base="$4" branch new rc=0

  branch=$(git -C "$path" symbolic-ref --short -q HEAD 2>/dev/null) || branch=""
  if [ -z "$branch" ]; then
    _gr_log skip "${name}: detached HEAD in ${path}, not refreshing"
    return 0
  fi
  if [ "$branch" != "$base" ]; then
    _gr_log skip "${name}: clone is on ${branch}, not ${base}"
    return 0
  fi
  if [ -n "$(git -C "$path" status --porcelain --untracked-files=no -- . ':(exclude).gitnexus' 2>/dev/null)" ]; then
    _gr_log skip "${name}: dirty clone ${path}"
    return 0
  fi
  if ! _gr_timeout 120 git -C "$path" pull --ff-only --quiet origin "$base" >/dev/null 2>&1; then
    _gr_log skip "${name}: git pull --ff-only origin ${base} failed in ${path}"
    return 0
  fi

  new=$(git -C "$path" rev-parse HEAD 2>/dev/null) || new=""
  if [ -n "$old" ] && [ "$old" = "$new" ]; then
    _gr_log skip "${name}: index already at ${new:0:7}"
    return 0
  fi

  local t="${GITNEXUS_REFRESH_TIMEOUT:-300}"
  _gr_timeout "$t" "${GITNEXUS_BIN:-gitnexus}" analyze --skip-agents-md "$path" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    _gr_log "done" "${name} ${old:0:7}→${new:0:7}"
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    _gr_log warn "${name}: analyze timed out after ${t}s — run: gitnexus analyze ${path}"
  else
    _gr_log warn "${name}: analyze exited ${rc} — run: gitnexus analyze ${path}"
  fi
  return 0
}

main() {
  local repo="" base="" env_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --repo | --base | --env-file)
      [ $# -ge 2 ] || _gr_usage
      case "$1" in
      --repo) repo="$2" ;;
      --base) base="$2" ;;
      --env-file) env_file="$2" ;;
      esac
      shift 2
      ;;
    --) shift && break ;;
    -*) _gr_usage ;;
    *) break ;;
    esac
  done
  [ $# -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || _gr_usage
  local tid="$1"
  _GR_LOG="$2"

  local pr=""
  if [ -z "$repo" ] || [ -z "$base" ]; then
    if ! declare -f ticket_pipeline_pr_ref >/dev/null 2>&1; then
      # shellcheck source=manifest-read.sh
      source "$_GR_DIR/manifest-read.sh" 2>/dev/null || true
    fi
    if declare -f ticket_pipeline_pr_ref >/dev/null 2>&1; then
      local ref
      ref=$(ticket_pipeline_pr_ref "$_GR_LOG") || ref=""
      pr=$(printf '%s\n' "$ref" | cut -f2)
      [ -n "$repo" ] || repo=$(printf '%s\n' "$ref" | cut -f3)
    fi
  fi
  if [ -z "$repo" ]; then
    _gr_log skip "no PR repo recorded for ${tid}"
    return 0
  fi

  if [ -z "$base" ] && [ -n "$pr" ] && command -v gh >/dev/null 2>&1; then
    base=$(_gr_timeout 30 gh pr view "$pr" --repo "$repo" --json baseRefName --jq '.baseRefName' 2>/dev/null) || base=""
  fi
  if [ -z "$base" ]; then
    [ -n "$env_file" ] || env_file="/tmp/ticket-auto-${tid}-env.sh"
    if [ -f "$env_file" ]; then
      # shellcheck disable=SC1090
      base=$(
        source "$env_file" >/dev/null 2>&1 || true
        printf '%s' "${INTEGRATION_BRANCH:-${BASE_BRANCH:-}}"
      )
    fi
  fi
  if [ -z "$base" ]; then
    _gr_log skip "${repo}: base branch unknown"
    return 0
  fi

  if ! command -v "${GITNEXUS_BIN:-gitnexus}" >/dev/null 2>&1; then
    _gr_log skip "${repo}: gitnexus CLI not installed"
    return 0
  fi
  local registry="${GITNEXUS_REGISTRY:-$HOME/.gitnexus/registry.json}"
  if [ ! -f "$registry" ]; then
    _gr_log skip "${repo}: no GitNexus registry at ${registry}"
    return 0
  fi

  local want entries="" name path last url found=0
  want=$(printf '%s\n' "$repo" | tr '[:upper:]' '[:lower:]')
  entries=$(jq -r '(if type == "array" then . else (.repos // []) end)[]
    | [(.name // ""), (.path // ""), (.lastCommit // ""), (.remoteUrl // "")] | @tsv' \
    "$registry" 2>/dev/null) || entries=""
  while IFS=$'\t' read -r name path last url; do
    [ -n "$path" ] && [ -n "$url" ] || continue
    [ "$(_gr_slug "$url")" = "$want" ] || continue
    found=1
    _gr_refresh_one "${name:-$want}" "$path" "$last" "$base"
  done <<<"$entries"
  [ "$found" = 1 ] || _gr_log skip "${repo}: not indexed by GitNexus"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit 0
fi
