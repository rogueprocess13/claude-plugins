#!/usr/bin/env bash
# test-verify-worktree.sh — unit tests for lib/verify-worktree.sh
# Creates a real git repo fixture (with a bare "origin" remote, since
# ensure_verify_worktree only ever checks out branches that already exist
# on origin — it never creates one) and tests create/reuse-resync/
# wrong-branch-guard/release/GC.
# Usage: bash test-verify-worktree.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ─────────────────────────────────────────────────
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi

source "$LIB_DIR/config.sh"
source "$LIB_DIR/verify-worktree.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# ── Fixture ──────────────────────────────────────────────────────────────────

# Each test gets a fresh git repo + bare "origin" remote under REPOS_ROOT.
# FIXTURE_REPO is the local clone verify would call ensure_verify_worktree
# against; FIXTURE_REMOTE is the bare repo standing in for the real origin.
# Cleanup via trap on FIXTURE_DIR.
_setup_fixture() {
  FIXTURE_DIR=$(mktemp -d)
  export REPOS_ROOT="$FIXTURE_DIR/repos"

  FIXTURE_REPO="$REPOS_ROOT/my-service"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -b main 2>/dev/null || git -C "$FIXTURE_REPO" init
  git -C "$FIXTURE_REPO" config user.email "test@test.com"
  git -C "$FIXTURE_REPO" config user.name "Test"
  echo "hello" >"$FIXTURE_REPO/README.md"
  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -m "initial" --no-gpg-sign

  FIXTURE_REMOTE="$FIXTURE_DIR/origin.git"
  git init --bare "$FIXTURE_REMOTE" >/dev/null 2>&1
  git -C "$FIXTURE_REPO" remote add origin "$FIXTURE_REMOTE"
  git -C "$FIXTURE_REPO" push origin main >/dev/null 2>&1

  git -C "$FIXTURE_REPO" checkout -b feat/CRE-1-fix >/dev/null 2>&1
  echo "change1" >"$FIXTURE_REPO/file.txt"
  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -m "change1" --no-gpg-sign >/dev/null 2>&1
  git -C "$FIXTURE_REPO" push origin feat/CRE-1-fix >/dev/null 2>&1
  git -C "$FIXTURE_REPO" checkout main >/dev/null 2>&1
}

# Pushes a new commit to feat/CRE-1-fix from a throwaway clone — the branch
# is checked out in the verify worktree by the time reuse tests run, so the
# fixture repo itself can no longer check it out again (worktree exclusivity).
_push_second_commit() {
  local scratch
  scratch=$(mktemp -d)
  git clone -q "$FIXTURE_REMOTE" "$scratch"
  git -C "$scratch" config user.email "test@test.com"
  git -C "$scratch" config user.name "Test"
  git -C "$scratch" checkout -q feat/CRE-1-fix
  echo "change2" >"$scratch/file2.txt"
  git -C "$scratch" add -A
  git -C "$scratch" commit -q -m "change2" --no-gpg-sign
  git -C "$scratch" push -q origin feat/CRE-1-fix
  rm -rf "$scratch"
}

echo "=== Core tests ==="
echo ""

# ── Create case ──────────────────────────────────────────────────────────────

test_create_worktree() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>&1) || return 1

  [ -d "$wt_path" ] || {
    echo "  worktree not at $wt_path" >&2
    return 1
  }
  [ -f "$wt_path/file.txt" ] || {
    echo "  file.txt missing in worktree" >&2
    return 1
  }
  local actual_branch
  actual_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD)
  [ "$actual_branch" = "feat/CRE-1-fix" ] || {
    echo "  expected branch feat/CRE-1-fix, got $actual_branch" >&2
    return 1
  }
  return 0
}
_run "create worktree at expected repo/ticket path on expected branch" test_create_worktree

# ── Path formula (deliberately repo/ticket, not ticket/repo) ─────────────────

test_path_formula() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>&1) || return 1
  local expected="$REPOS_ROOT/.verify-worktrees/my-service/CRE-1"
  [ "$wt_path" = "$expected" ] || {
    echo "  expected $expected, got $wt_path" >&2
    return 1
  }
  return 0
}
_run "path is REPOS_ROOT/.verify-worktrees/{repo}/{ticket}" test_path_formula

# ── Reuse always re-syncs to the remote tip ───────────────────────────────────

test_reuse_resyncs_to_remote_tip() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  _push_second_commit

  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>&1) || return 1
  [ -f "$wt_path/file2.txt" ] || {
    echo "  reuse did not pick up the new remote commit (stale checkout)" >&2
    return 1
  }
  return 0
}
_run "reuse re-syncs to origin's current branch tip" test_reuse_resyncs_to_remote_tip

test_reuse_discards_local_scratch() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>&1) || return 1
  # Simulate leftover build/scratch output from a previous verify attempt.
  echo "leftover" >"$wt_path/scratch.tmp"

  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  [ ! -f "$wt_path/scratch.tmp" ] || {
    echo "  reuse left stale untracked scratch output in place" >&2
    return 1
  }
  return 0
}
_run "reuse discards untracked scratch output (git clean)" test_reuse_discards_local_scratch

# ── Wrong-branch guard ─────────────────────────────────────────────────────

test_wrong_branch_guard() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1

  local actual=0
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "main" >/dev/null 2>/dev/null || actual=$?
  [ "$actual" -ne 0 ] || {
    echo "  should have exited non-zero on wrong branch" >&2
    return 1
  }
  return 0
}
_run "wrong branch guard exits non-zero" test_wrong_branch_guard

# ── Never creates a branch that doesn't exist on origin ─────────────────────

test_missing_branch_fails() {
  _setup_fixture
  local actual=0
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "does/not-exist" >/dev/null 2>/dev/null || actual=$?
  [ "$actual" -ne 0 ] || {
    echo "  should have failed for a branch absent locally and on origin" >&2
    return 1
  }
  return 0
}
_run "missing branch (not local, not on origin) fails rather than creating one" test_missing_branch_fails

# ── Path purity ──────────────────────────────────────────────────────────────

test_worktree_path_purity() {
  _setup_fixture
  local before_count
  before_count=$(git -C "$FIXTURE_REPO" worktree list 2>/dev/null | wc -l)

  local path
  path=$(verify_worktree_path "my-service" "CRE-999") 2>&1
  [ ! -d "$path" ] || {
    echo "  verify_worktree_path created a directory!" >&2
    return 1
  }
  local after_count
  after_count=$(git -C "$FIXTURE_REPO" worktree list 2>/dev/null | wc -l)
  [ "$before_count" = "$after_count" ] || {
    echo "  worktree count changed" >&2
    return 1
  }
  return 0
}
_run "verify_worktree_path creates nothing" test_worktree_path_purity

echo ""
echo "=== Release tests ==="
echo ""

test_release_removes_worktree() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  local wt_path
  wt_path=$(verify_worktree_path "my-service" "CRE-1")

  release_verify_worktree "CRE-1" >/dev/null 2>&1 || return 1
  [ ! -d "$wt_path" ] || {
    echo "  worktree dir still exists after release" >&2
    return 1
  }
  return 0
}
_run "release removes worktree" test_release_removes_worktree

test_repeat_release_idempotent() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  release_verify_worktree "CRE-1" >/dev/null 2>&1 || return 1

  local actual=0
  release_verify_worktree "CRE-1" >/dev/null 2>&1 || actual=$?
  [ "$actual" -eq 0 ] || {
    echo "  second release_verify_worktree exited $actual" >&2
    return 1
  }
  return 0
}
_run "repeat release exits 0" test_repeat_release_idempotent

test_release_leaves_other_tickets_alone() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  git -C "$FIXTURE_REPO" checkout -b feat/CRE-2-fix >/dev/null 2>&1
  git -C "$FIXTURE_REPO" push origin feat/CRE-2-fix >/dev/null 2>&1
  git -C "$FIXTURE_REPO" checkout main >/dev/null 2>&1
  ensure_verify_worktree "CRE-2" "$FIXTURE_REPO" "feat/CRE-2-fix" >/dev/null 2>&1 || return 1

  release_verify_worktree "CRE-1" >/dev/null 2>&1 || return 1

  local wt2
  wt2=$(verify_worktree_path "my-service" "CRE-2")
  [ -d "$wt2" ] || {
    echo "  unrelated ticket's worktree was also removed" >&2
    return 1
  }
  return 0
}
_run "release only touches the named ticket's worktree" test_release_leaves_other_tickets_alone

echo ""
echo "=== GC tests ==="
echo ""

test_gc_removes_stale_worktree() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  local wt_path
  wt_path=$(verify_worktree_path "my-service" "CRE-1")

  # Backdate the worktree dir's mtime well past a 1h TTL.
  local old_ts
  old_ts=$(($(date +%s) - 100000))
  touch -d "@$old_ts" "$wt_path" 2>/dev/null || touch -t 202001010000 "$wt_path" 2>/dev/null || return 1

  VERIFY_WORKTREE_TTL_HOURS=1 verify_worktree_gc >/dev/null 2>&1

  [ ! -d "$wt_path" ] || {
    echo "  stale worktree survived GC" >&2
    return 1
  }
  return 0
}
_run "GC removes worktrees past the TTL" test_gc_removes_stale_worktree

test_gc_preserves_fresh_worktree() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  local wt_path
  wt_path=$(verify_worktree_path "my-service" "CRE-1")

  VERIFY_WORKTREE_TTL_HOURS=24 verify_worktree_gc >/dev/null 2>&1

  [ -d "$wt_path" ] || {
    echo "  fresh worktree was incorrectly GC'd" >&2
    return 1
  }
  return 0
}
_run "GC preserves worktrees within the TTL" test_gc_preserves_fresh_worktree

test_gc_no_worktrees() {
  _setup_fixture
  local actual=0
  verify_worktree_gc >/dev/null 2>&1 || actual=$?
  [ "$actual" -eq 0 ] || {
    echo "  GC with no worktrees should exit 0" >&2
    return 1
  }
  return 0
}
_run "GC with no worktrees exits 0" test_gc_no_worktrees

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
