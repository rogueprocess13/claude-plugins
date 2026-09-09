#!/usr/bin/env bash
# verify-worktree.sh — git worktree isolation for ticket-verify.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling — mirrors lib/worktree.sh's convention).
#
# ticket-verify previously ran services and browser checks directly against
# the shared repo clones under REPOS_ROOT — whatever branch happened to be
# checked out there at verify time is what actually got exercised, with
# nothing tying a verify run to the ticket branch it was meant to test. This
# library gives ticket-verify its own per-ticket, per-repo worktree, deliberately
# separate from lib/worktree.sh's implement-phase worktrees
# (REPOS_ROOT/.ticket-auto/worktrees/{TICKET_ID}/{repo-slug}): verify must
# never read a directory implement might still be actively writing to, and
# a verify worktree always re-syncs to the branch's current remote tip on
# every reuse (see ensure_verify_worktree), where an implement worktree
# deliberately preserves local working-tree state between reuses.
#
# Path formula: $REPOS_ROOT/.verify-worktrees/{repo-slug}/{TICKET_ID}
#
# Dependencies: config.sh (for $REPOS_ROOT, $VERIFY_WORKTREE_TTL_HOURS).
# Best-effort dependency on lib/verify-lock.sh for verify_worktree_gc's
# lock-aware guard (see below) — sourced lazily if verify_lock_status isn't
# already defined, and the guard simply no-ops if it still can't be found.
#
# Usage:
#   source lib/verify-worktree.sh
#   verify_worktree_gc                                          # opportunistic TTL sweep
#   path=$(ensure_verify_worktree "CRE-123" "/path/to/repo" "feat/CRE-123-fix")
#   release_verify_worktree "CRE-123"
#   verify_worktree_gc

if ! declare -f verify_lock_status >/dev/null 2>&1; then
  _verify_worktree_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -n "$_verify_worktree_lib_dir" ] && [ -f "$_verify_worktree_lib_dir/verify-lock.sh" ]; then
    # shellcheck disable=SC1091
    source "$_verify_worktree_lib_dir/verify-lock.sh" 2>/dev/null || true
  fi
  unset _verify_worktree_lib_dir
fi

# ── Internal helpers ─────────────────────────────────────────────────────────

# Portable mtime (seconds since epoch) — GNU stat then BSD/macOS stat.
_verify_worktree_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Marks a worktree as "just used" independent of whatever git itself did or
# didn't touch on disk. `git reset --hard`/`clean -fdx` (ensure_verify_worktree's
# reuse path) mutate files inside the worktree, but git's own bookkeeping for
# a linked worktree lives under the main repo's .git/worktrees/<name>/, not
# under the worktree root itself — so unless a reset happens to rewrite a
# file directly at the worktree's top level (uncommon), the worktree root
# directory's own mtime can sit frozen at its original `git worktree add`
# creation time no matter how many times it's legitimately reused. A ticket
# iterated across more than VERIFY_WORKTREE_TTL_HOURS (ordinary for one
# gated on human review/PR feedback) would then look idle to
# verify_worktree_gc while being actively reused. Called at the top of
# every ensure_verify_worktree success path, so "last used" always reflects
# reality regardless of git's incidental side effects.
_verify_worktree_touch() {
  touch "$1" 2>/dev/null || true
}

# Removes a single worktree directory: detaches it from its origin repo via
# `git worktree remove` when possible, then deletes the directory outright.
# Non-fatal — failures warn but never exit non-zero (cleanup, not a
# correctness requirement).
_verify_worktree_remove_one() {
  local wt_dir="$1"
  [ -d "$wt_dir" ] || return 0

  if [ -f "$wt_dir/.git" ] || [ -d "$wt_dir/.git" ]; then
    local repo_path
    repo_path=$(git -C "$wt_dir" rev-parse --git-common-dir 2>/dev/null | sed 's|/.git/worktrees/.*||' || true)
    if [ -n "$repo_path" ] && [ -d "$repo_path" ]; then
      git -C "$repo_path" worktree remove "$wt_dir" --force 2>/dev/null || {
        echo "verify-worktree: failed to remove $wt_dir — continuing" >&2
      }
    fi
  fi

  rm -rf "$wt_dir" 2>/dev/null || true
  return 0
}

# ── Public API ──────────────────────────────────────────────────────────────

# verify_worktree_path <repo_slug> <TICKET_ID>
# Pure path computation — no side effects, no git calls.
# Returns $REPOS_ROOT/.verify-worktrees/{repo-slug}/{TICKET_ID}
verify_worktree_path() {
  local repo_slug="$1"
  local ticket_id="$2"
  echo "${REPOS_ROOT:-.}/.verify-worktrees/${repo_slug}/${ticket_id}"
}

# ensure_verify_worktree <TICKET_ID> <repo_path> <branch>
# Ensures a git worktree exists at the computed path, checked out on <branch>.
# Creates it when absent. Unlike implement's ensure_worktree, a verify
# worktree never brings a branch into existence — verify only ever checks
# out a branch ticket-implement has already pushed, so there is no <base>
# parameter. On reuse (same branch), always fetches and hard-resets to
# origin/<branch> — a verify run must see the latest pushed commits, not
# whatever an earlier attempt happened to leave checked out, since
# ticket-implement can push new commits to the same branch between retries.
# Exits non-zero when present on a different branch (identity guard,
# mirrors implement's worktree — release_verify_worktree first to retarget).
# Prints the resolved worktree path on stdout.
ensure_verify_worktree() {
  local ticket_id="$1"
  local repo_path="$2"
  local branch="$3"

  if [ -z "$ticket_id" ] || [ -z "$repo_path" ] || [ -z "$branch" ]; then
    echo "ensure_verify_worktree: usage: ensure_verify_worktree <TICKET_ID> <repo_path> <branch>" >&2
    return 1
  fi
  if [ ! -d "$repo_path/.git" ] && [ ! -f "$repo_path/.git" ]; then
    echo "ensure_verify_worktree: $repo_path is not a git repo" >&2
    return 1
  fi

  local repo_slug
  repo_slug=$(basename "$repo_path")
  local wt_path
  wt_path=$(verify_worktree_path "$repo_slug" "$ticket_id")

  # Fetch first so both the "reuse" and "create" branches below see the
  # branch's current remote tip.
  git -C "$repo_path" fetch origin "$branch" 2>/dev/null || true

  if [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; then
    local current_branch
    current_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    if [ "$current_branch" != "$branch" ]; then
      echo "verify-worktree: $wt_path exists on branch '$current_branch', expected '$branch' — refusing to reuse; release it first" >&2
      return 2
    fi

    # Reuse: always re-sync to the remote tip. A stale local checkout would
    # silently re-verify an earlier, already-superseded attempt.
    if git -C "$wt_path" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
      git -C "$wt_path" reset --hard "origin/$branch" >/dev/null 2>&1 || {
        echo "verify-worktree: failed to sync $wt_path to origin/$branch" >&2
        return 3
      }
      git -C "$wt_path" clean -fdx >/dev/null 2>&1 || true
    fi

    _verify_worktree_touch "$wt_path"
    echo "$wt_path"
    return 0
  fi

  # Doesn't exist — create it. Never brands a new branch: the branch must
  # already exist (locally or on origin) for there to be anything to verify.
  if git -C "$repo_path" rev-parse --verify "$branch" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$wt_path")"
    git -C "$repo_path" worktree add "$wt_path" "$branch" >/dev/null 2>&1 || {
      echo "verify-worktree: failed to create worktree for $branch in $repo_path" >&2
      return 1
    }
  elif git -C "$repo_path" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$wt_path")"
    git -C "$repo_path" worktree add -b "$branch" "$wt_path" "origin/$branch" >/dev/null 2>&1 || {
      echo "verify-worktree: failed to create worktree for origin/$branch in $repo_path" >&2
      return 1
    }
  else
    echo "verify-worktree: branch '$branch' not found locally or on origin for $repo_path — nothing to verify" >&2
    return 1
  fi

  _verify_worktree_touch "$wt_path"
  echo "$wt_path"
  return 0
}

# release_verify_worktree <TICKET_ID>
# Removes all verify worktrees for a ticket, across every repo. Idempotent —
# safe to call multiple times. Not called automatically after a normal
# verify run (worktrees are left in place for debugging/reuse and reaped by
# verify_worktree_gc's TTL instead) — this is for explicit/manual cleanup.
release_verify_worktree() {
  local ticket_id="$1"
  local root="${REPOS_ROOT:-.}/.verify-worktrees"

  [ -n "$ticket_id" ] || return 0
  [ -d "$root" ] || return 0

  for repo_dir in "$root"/*/; do
    [ -d "$repo_dir" ] || continue
    local wt_dir="${repo_dir}${ticket_id}"
    [ -d "$wt_dir" ] || continue
    _verify_worktree_remove_one "$wt_dir"
    rmdir "$repo_dir" 2>/dev/null || true
  done

  git worktree prune 2>/dev/null || true
  return 0
}

# verify_worktree_gc
# Age-based sweep of $REPOS_ROOT/.verify-worktrees — removes any
# {repo-slug}/{TICKET_ID} directory whose mtime exceeds
# VERIFY_WORKTREE_TTL_HOURS (default 24, matching the pipeline's other
# scratch-file TTL default). Mirrors hooks/tmp-sweep.sh's age-based
# approach rather than querying Linear ticket state, so it stays a cheap,
# zero-network, zero-LLM opportunistic call ticket-verify can make on every
# invocation (see SKILL.md Step 1.6a2) instead of a separate scheduled hook.
# `ensure_verify_worktree` touching the worktree root on every successful
# use (see _verify_worktree_touch) is what makes the TTL a reliable signal
# in the first place — git's own reset/clean side effects don't reliably
# advance a linked worktree's own directory mtime. As a second, independent
# guard: if the single-flight verify lock is currently held by ANYONE, skip
# the whole sweep rather than remove anything. There's no way to tell from
# here which specific ticket's worktree a live holder might be serving
# files from — the lock is one global flight, not per-ticket — so the safe
# rule under contention is to touch nothing at all this pass; the next
# opportunistic call (the very next verify run) tries again.
verify_worktree_gc() {
  if declare -f verify_lock_status >/dev/null 2>&1 && verify_lock_status >/dev/null 2>&1; then
    echo "verify-worktree: skipping GC sweep — the verify lock is currently held" >&2
    return 0
  fi

  local root="${REPOS_ROOT:-.}/.verify-worktrees"
  [ -d "$root" ] || return 0

  local ttl_hours="${VERIFY_WORKTREE_TTL_HOURS:-24}"
  case "$ttl_hours" in
  '' | *[!0-9]*) ttl_hours=24 ;;
  esac
  local cutoff
  cutoff=$(($(date +%s) - ttl_hours * 3600))

  local removed=0
  for repo_dir in "$root"/*/; do
    [ -d "$repo_dir" ] || continue
    for wt_dir in "$repo_dir"*/; do
      [ -d "$wt_dir" ] || continue
      local mtime
      mtime=$(_verify_worktree_mtime "$wt_dir")
      if [ "$mtime" -lt "$cutoff" ]; then
        _verify_worktree_remove_one "$wt_dir"
        removed=$((removed + 1))
      fi
    done
    rmdir "$repo_dir" 2>/dev/null || true
  done

  git worktree prune 2>/dev/null || true

  [ "$removed" -gt 0 ] && echo "verify-worktree: swept $removed stale worktree(s) older than ${ttl_hours}h" >&2
  return 0
}
