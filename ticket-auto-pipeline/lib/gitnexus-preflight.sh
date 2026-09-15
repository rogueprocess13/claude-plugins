#!/usr/bin/env bash
# gitnexus-preflight.sh — deterministic GitNexus branch/result verification
# (GITNEXUS_PREFLIGHT_BRANCH_UNVERIFIED, GH issue #359).
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling).
#
# GitNexus's own `list_repos` staleness figure (`staleness.commitsBehind`) is
# computed against whatever branch the *indexed clone* currently has checked
# out (`git rev-list --count <indexed-commit>..HEAD` inside the indexed repo
# path) — not against the branch a caller actually cares about (a PR's head,
# or a ticket worktree's branch). Reachability (`list_repos` succeeds) and
# `commitsBehind == 0` can both read healthy while the indexed clone sits on
# a branch completely unrelated to the one being reviewed/implemented — that
# is exactly what produced the confidently-wrong diffs recorded against
# WIL-75, WIL-77, and WIL-82.
#
# This library adds the two checks GitNexus's MCP surface doesn't provide.
# Both are pure bash/git — no MCP call happens here. Callers (ticket-pr-review
# Step 4.5, ticket-implement Step 5's pre-push check) make the
# `list_repos`/`detect_changes` MCP calls themselves and pass the resulting
# commit SHA / file lists in.
#
# Usage:
#   source lib/gitnexus-preflight.sh
#   gitnexus_verify_branch "$WORKTREE_PATH" "$INDEXED_LAST_COMMIT" "origin/$HEAD_REF"
#   gitnexus_check_result_subset "$RETURNED_FILES" "$KNOWN_PR_FILES"

# Default ceiling for how many commits the indexed clone may lag the branch
# being asked about before its answer is treated as too stale to trust.
# Override per-call (4th arg) or globally via GITNEXUS_MAX_COMMITS_BEHIND.
GITNEXUS_MAX_COMMITS_BEHIND="${GITNEXUS_MAX_COMMITS_BEHIND:-20}"

# ── Public API ──────────────────────────────────────────────────────────────

# gitnexus_verify_branch <repo_git_dir> <indexed_commit> <expected_ref> [max_commits_behind]
#
# Verifies the GitNexus-indexed commit is actually positioned to answer a
# question about <expected_ref>: it must be reachable as an ancestor of (or
# equal to) <expected_ref> inside the repo at <repo_git_dir>, and within
# <max_commits_behind> commits of it.
#
# Prints exactly one line to stdout:
#   ok <n>              — verified; indexed commit is <n> commits behind expected_ref
#   wrong-branch         — indexed commit is not an ancestor of expected_ref at all
#   stale <n>            — an ancestor, but more than max_commits_behind behind
#   unresolvable <reason> — could not evaluate (bad path, unknown ref, etc.)
#
# Exit code: 0 = verified/usable, 1 = unverified (caller must fall back),
# 2 = usage/resolution error (caller must also fall back — a repo/ref that
# can't be resolved is never treated as "verified").
gitnexus_verify_branch() {
  local repo_dir="$1"
  local indexed_commit="$2"
  local expected_ref="$3"
  local max_behind="${4:-$GITNEXUS_MAX_COMMITS_BEHIND}"

  if [ -z "$repo_dir" ] || [ ! -d "$repo_dir" ]; then
    echo "unresolvable not-a-directory"
    return 2
  fi
  if [ -z "$indexed_commit" ]; then
    echo "unresolvable empty-indexed-commit"
    return 2
  fi
  if [ -z "$expected_ref" ]; then
    echo "unresolvable empty-expected-ref"
    return 2
  fi

  local indexed_sha expected_sha
  indexed_sha=$(git -C "$repo_dir" rev-parse --verify "${indexed_commit}^{commit}" 2>/dev/null) || {
    echo "unresolvable indexed-commit-not-found"
    return 2
  }
  expected_sha=$(git -C "$repo_dir" rev-parse --verify "${expected_ref}^{commit}" 2>/dev/null) || {
    echo "unresolvable expected-ref-not-found"
    return 2
  }

  if [ "$indexed_sha" = "$expected_sha" ]; then
    echo "ok 0"
    return 0
  fi

  if ! git -C "$repo_dir" merge-base --is-ancestor "$indexed_sha" "$expected_sha" 2>/dev/null; then
    echo "wrong-branch"
    return 1
  fi

  local behind
  behind=$(git -C "$repo_dir" rev-list --count "${indexed_sha}..${expected_sha}" 2>/dev/null)
  behind="${behind:-0}"

  if [ "$behind" -gt "$max_behind" ]; then
    echo "stale $behind"
    return 1
  fi

  echo "ok $behind"
  return 0
}

# gitnexus_check_result_subset <returned_files_list> <known_files_list>
#
# Sanity-checks a `detect_changes` result against ground truth: each argument
# is a path to a file with one repo-relative path per line (the affected
# files GitNexus returned, and the real PR/branch diff's changed-file list,
# respectively). Verifies every line in <returned_files_list> also appears in
# <known_files_list> — a structurally-wrong (e.g. wrong-branch) result
# typically names files nowhere in the real diff.
#
# Prints the offending (extra) files, one per line, if any.
# Exit code: 0 = subset (reliable), 1 = not a subset (unreliable — discard the
# result and fall back), 2 = usage error.
gitnexus_check_result_subset() {
  local returned_file="$1"
  local known_file="$2"

  if [ -z "$returned_file" ] || [ ! -f "$returned_file" ]; then
    echo "unresolvable returned-file-missing"
    return 2
  fi
  if [ -z "$known_file" ] || [ ! -f "$known_file" ]; then
    echo "unresolvable known-file-missing"
    return 2
  fi

  local extra
  extra=$(grep -Fxv -f "$known_file" "$returned_file" 2>/dev/null | grep -v '^[[:space:]]*$' || true)

  if [ -n "$extra" ]; then
    echo "$extra"
    return 1
  fi

  return 0
}

# ── CLI entrypoint (standalone use / testing) ───────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  verify-branch)
    shift
    gitnexus_verify_branch "$@"
    ;;
  check-subset)
    shift
    gitnexus_check_result_subset "$@"
    ;;
  *)
    echo "Usage: gitnexus-preflight.sh {verify-branch <repo_dir> <indexed_commit> <expected_ref> [max_behind]|check-subset <returned_files> <known_files>}" >&2
    exit 2
    ;;
  esac
fi
