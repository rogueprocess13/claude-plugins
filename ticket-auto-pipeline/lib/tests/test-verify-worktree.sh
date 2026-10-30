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
# verify-worktree.sh lazily sources verify-lock.sh itself for GC's
# lock-aware guard; source it explicitly too so tests can call
# verify_lock_acquire/verify_lock_release directly without relying on that
# lazy pull-in.
source "$LIB_DIR/verify-lock.sh"
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
  # Isolated per-fixture lock namespace: verify_worktree_gc's lock-aware
  # guard must never see ambient state from the real default
  # (/tmp/ticket-verify.lock) or from an unrelated test run.
  export VERIFY_LOCK_FILE="$FIXTURE_DIR/verify-lock-for-gc-guard.lock"
  export VERIFY_LOCK_TIMEOUT_SECS=3
  export VERIFY_LOCK_MAX_HOLD_SECS=8

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
  # Detached at origin's tip (#591), never attached to the branch itself.
  local head_ref head_sha origin_sha
  head_ref=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD)
  [ "$head_ref" = "HEAD" ] || {
    echo "  expected a detached HEAD, got branch $head_ref" >&2
    return 1
  }
  head_sha=$(git -C "$wt_path" rev-parse HEAD)
  origin_sha=$(git -C "$FIXTURE_REPO" rev-parse origin/feat/CRE-1-fix)
  [ "$head_sha" = "$origin_sha" ] || {
    echo "  HEAD $head_sha is not origin/feat/CRE-1-fix ($origin_sha)" >&2
    return 1
  }
  return 0
}
_run "create worktree at expected repo/ticket path, detached at origin/<branch>" test_create_worktree

# ── #591: branch already checked out in another (implement) worktree ────────

test_create_when_branch_checked_out_elsewhere() {
  _setup_fixture
  # Stand-in for implement's worktree, which still holds the ticket branch.
  local impl_wt="$FIXTURE_DIR/impl-wt"
  git -C "$FIXTURE_REPO" worktree add "$impl_wt" feat/CRE-1-fix >/dev/null 2>&1 || return 1

  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>/dev/null) || {
    echo "  create failed while the branch is checked out in another worktree" >&2
    return 1
  }
  [ "$(git -C "$wt_path" rev-parse HEAD)" = "$(git -C "$FIXTURE_REPO" rev-parse origin/feat/CRE-1-fix)" ] || return 1

  # Reuse (detached HEAD is the normal state now) must also succeed.
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || {
    echo "  reuse of a detached verify worktree failed" >&2
    return 1
  }
  # The implement worktree is untouched and still on its branch.
  [ "$(git -C "$impl_wt" rev-parse --abbrev-ref HEAD)" = "feat/CRE-1-fix" ]
}
_run "#591: create + reuse succeed while implement's worktree holds the branch" test_create_when_branch_checked_out_elsewhere

test_create_from_local_only_branch() {
  _setup_fixture
  git -C "$FIXTURE_REPO" branch feat/CRE-1-local main >/dev/null 2>&1 || return 1
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-local" 2>/dev/null) || return 1
  [ "$(git -C "$wt_path" rev-parse HEAD)" = "$(git -C "$FIXTURE_REPO" rev-parse feat/CRE-1-local)" ] || return 1
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-local" >/dev/null 2>&1
}
_run "#591: a never-pushed branch is created detached from the local branch, and reused" test_create_from_local_only_branch

test_adopts_manual_detached_recovery() {
  _setup_fixture
  # An operator's manual recovery: detached worktree at the expected path,
  # with no recorded branch.
  local wt_path
  wt_path=$(verify_worktree_path "my-service" "CRE-1")
  mkdir -p "$(dirname "$wt_path")"
  git -C "$FIXTURE_REPO" worktree add --detach "$wt_path" origin/feat/CRE-1-fix >/dev/null 2>&1 || return 1
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  # Adopted: a later call for another branch is refused by the recorded identity.
  local rc=0
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "main" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}
_run "#591: an unrecorded detached worktree is adopted, then guarded" test_adopts_manual_detached_recovery

test_reuses_legacy_attached_worktree() {
  # A verify worktree created before #591 is attached to the branch; it is
  # still reused and re-synced, not refused.
  _setup_fixture
  local wt_path
  wt_path=$(verify_worktree_path "my-service" "CRE-1")
  mkdir -p "$(dirname "$wt_path")"
  git -C "$FIXTURE_REPO" worktree add "$wt_path" feat/CRE-1-fix >/dev/null 2>&1 || return 1
  _push_second_commit
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  [ -f "$wt_path/file2.txt" ]
}
_run "#591: a legacy attached verify worktree is still reused and re-synced" test_reuses_legacy_attached_worktree

# ── #577: deleted-but-still-registered worktree ─────────────────────────────

test_recreate_after_rm_rf() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>/dev/null) || return 1
  rm -rf "$wt_path"
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || {
    echo "  re-create after rm -rf failed (stale registration not pruned)" >&2
    return 1
  }
  [ -e "$wt_path/.git" ]
}
_run "#577: re-create succeeds after the worktree dir was rm -rf'd" test_recreate_after_rm_rf

test_recreate_after_rm_rf_locked() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>/dev/null) || return 1
  git -C "$FIXTURE_REPO" worktree lock "$wt_path" >/dev/null 2>&1 || return 1
  rm -rf "$wt_path"
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || {
    echo "  re-create after rm -rf of a locked worktree failed" >&2
    return 1
  }
  [ -e "$wt_path/.git" ]
}
_run "#577: re-create succeeds when the stale registration is locked" test_recreate_after_rm_rf_locked

test_create_failure_reports_git_error() {
  _setup_fixture
  local wt_path err
  wt_path=$(verify_worktree_path "my-service" "CRE-1")
  # A plain file where the worktree dir should go makes `worktree add` fail.
  mkdir -p "$(dirname "$wt_path")"
  echo "not a dir" >"$wt_path"
  err=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>&1 >/dev/null) && return 1
  # git's own reason follows the generic prefix.
  printf '%s' "$err" | grep -q "failed to create worktree for origin/feat/CRE-1-fix in .*: ." || {
    echo "  stderr lacks git's error: $err" >&2
    return 1
  }
}
_run "#577: a failed worktree add reports git's own error" test_create_failure_reports_git_error

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

test_reuse_refreshes_last_used_marker_without_new_commits() {
  # Regression (Finding 2, adversarial review of PR #338): a linked
  # worktree's own directory mtime isn't reliably advanced by `git reset
  # --hard`/`clean -fdx` when there's nothing new to reset to — git's
  # bookkeeping for the worktree lives under the main repo's
  # .git/worktrees/<name>/, not the worktree root. ensure_verify_worktree
  # must mark the worktree "just used" itself, independent of whatever git
  # did or didn't touch, or a ticket reused past VERIFY_WORKTREE_TTL_HOURS
  # with no new pushes in between would look idle to verify_worktree_gc
  # while being legitimately, repeatedly reused.
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  local wt_path
  wt_path=$(verify_worktree_path "my-service" "CRE-1")

  local old_ts
  old_ts=$(($(date +%s) - 100000))
  touch -d "@$old_ts" "$wt_path" 2>/dev/null || touch -t 202001010000 "$wt_path" 2>/dev/null || return 1

  # Reuse with no new commits pushed in between.
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1

  local mtime now
  mtime=$(stat -c %Y "$wt_path" 2>/dev/null || stat -f %m "$wt_path" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ "$((now - mtime))" -lt 30 ] || {
    echo "  worktree root mtime was not refreshed on reuse (mtime=$mtime, now=$now) — GC would wrongly treat it as idle" >&2
    return 1
  }
  return 0
}
_run "reuse refreshes the worktree's last-used marker even with no new commits" test_reuse_refreshes_last_used_marker_without_new_commits

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

test_gc_prunes_the_worktrees_repo_not_cwd() {
  # #577: a verify worktree dir that lost its .git (only rm -rf runs on it)
  # must still leave no registration behind in its repo — the prune targets
  # the repo behind the slug, not the caller's working directory.
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" 2>/dev/null) || return 1
  rm -rf "$wt_path"
  mkdir -p "$wt_path"
  local old_ts
  old_ts=$(($(date +%s) - 100000))
  touch -d "@$old_ts" "$wt_path" 2>/dev/null || touch -t 202001010000 "$wt_path" 2>/dev/null || return 1
  (cd / && VERIFY_WORKTREE_TTL_HOURS=1 verify_worktree_gc >/dev/null 2>&1)
  local n
  n=$(git -C "$FIXTURE_REPO" worktree list --porcelain | grep -c '^worktree ')
  [ "$n" -eq 1 ] || {
    echo "  $n worktrees still registered after GC (expected only the main checkout)" >&2
    return 1
  }
}
_run "#577: GC prunes the worktree's own repo, from any cwd" test_gc_prunes_the_worktrees_repo_not_cwd

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

test_gc_skips_while_lock_held() {
  # Regression (Finding 2, adversarial review of PR #338): a stale worktree
  # must never be reaped while the verify lock is held — the lock is a
  # single global flight, so "held" is the only signal available here about
  # whether SOME verify run's app stack might currently be serving files
  # out of a worktree under this same root.
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null 2>&1 || return 1
  local wt_path
  wt_path=$(verify_worktree_path "my-service" "CRE-1")

  local old_ts
  old_ts=$(($(date +%s) - 100000))
  touch -d "@$old_ts" "$wt_path" 2>/dev/null || touch -t 202001010000 "$wt_path" 2>/dev/null || return 1

  verify_lock_acquire "SOME-OTHER-TICKET" >/dev/null 2>&1 || {
    echo "  could not acquire the lock to set up this test" >&2
    return 1
  }

  VERIFY_WORKTREE_TTL_HOURS=1 verify_worktree_gc >/dev/null 2>&1

  [ -d "$wt_path" ] || {
    echo "  GC removed a stale worktree while the verify lock was held" >&2
    verify_lock_release
    return 1
  }

  # Once released, the same stale worktree is fair game again.
  verify_lock_release
  VERIFY_WORKTREE_TTL_HOURS=1 verify_worktree_gc >/dev/null 2>&1
  [ ! -d "$wt_path" ] || {
    echo "  GC still did not remove the stale worktree after the lock was released" >&2
    return 1
  }
  return 0
}
_run "GC skips the sweep entirely while the verify lock is held" test_gc_skips_while_lock_held

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
echo "=== env-start.sh contract + served-checkout check (#419) ==="
echo ""

# The dev stack used to be started with nothing telling it which checkout to
# serve, so it kept serving the primary clone — possibly another ticket's
# branch — while VERIFY reported on it as if it were this ticket's code.

test_exports_name_every_verify_worktree() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix") || return 1
  local out
  out=$(verify_worktree_exports "CRE-1") || return 1
  (
    unset VERIFY_REPO_PATH_MY_SERVICE VERIFY_TICKET_ID
    eval "$out"
    [ "${VERIFY_TICKET_ID:-}" = "CRE-1" ] || {
      echo "  VERIFY_TICKET_ID not exported: $out" >&2
      exit 1
    }
    [ "${VERIFY_REPO_PATH_MY_SERVICE:-}" = "$wt_path" ] || {
      echo "  VERIFY_REPO_PATH_MY_SERVICE='${VERIFY_REPO_PATH_MY_SERVICE:-}', expected $wt_path" >&2
      exit 1
    }
  )
}
_run "verify_worktree_exports re-derives VERIFY_REPO_PATH_<REPO> for env-start.sh" test_exports_name_every_verify_worktree

test_exports_ignore_other_tickets() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null || return 1
  local out
  out=$(verify_worktree_exports "CRE-2")
  if printf '%s' "$out" | grep -q VERIFY_REPO_PATH_; then
    echo "  exports for CRE-2 leaked CRE-1's worktree: $out" >&2
    return 1
  fi
  return 0
}
_run "verify_worktree_exports names only the requested ticket's worktrees" test_exports_ignore_other_tickets

test_env_files_mirrored_on_create_and_reuse() {
  _setup_fixture
  echo ".env" >>"$FIXTURE_REPO/.git/info/exclude"
  mkdir -p "$FIXTURE_REPO/worker"
  printf 'LOCAL_STORAGE_DIR=./data\nAPI_KEY=x\n' >"$FIXTURE_REPO/worker/.env"
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix") || return 1
  [ -f "$wt_path/worker/.env" ] || {
    echo "  worker/.env not mirrored on create" >&2
    return 1
  }
  grep -q "^LOCAL_STORAGE_DIR=$FIXTURE_REPO/worker/data$" "$wt_path/worker/.env" || {
    echo "  relative *_DIR not pinned to the primary checkout (#408): $(cat "$wt_path/worker/.env")" >&2
    return 1
  }
  # Reuse runs clean -fdx, which deletes ignored files — they must come back.
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null || return 1
  [ -f "$wt_path/worker/.env" ] || {
    echo "  worker/.env lost after reuse resync" >&2
    return 1
  }
  return 0
}
_run "gitignored env files are mirrored into the verify worktree (create + reuse)" test_env_files_mirrored_on_create_and_reuse

test_url_port() {
  [ "$(verify_url_port http://localhost:3000)" = "3000" ] || return 1
  [ "$(verify_url_port http://localhost:3000/app?x=1)" = "3000" ] || return 1
  [ "$(verify_url_port https://example.test)" = "443" ] || return 1
  [ "$(verify_url_port http://example.test/)" = "80" ] || return 1
  ! verify_url_port "not-a-url" >/dev/null || return 1
  return 0
}
_run "verify_url_port resolves explicit and default ports" test_url_port

# Starts a real listener with the given cwd and waits until it is bound.
# Sets SERVE_PID and SERVE_PORT.
_serve_from() {
  local dir="$1" i
  SERVE_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  (cd "$dir" && exec python3 -m http.server "$SERVE_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  SERVE_PID=$!
  for i in $(seq 1 50); do
    [ -n "$(_verify_listening_pids "$SERVE_PORT")" ] && return 0
    sleep 0.1
  done
  echo "  listener on :$SERVE_PORT never came up" >&2
  return 1
}
_serve_stop() {
  [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null
  wait "$SERVE_PID" 2>/dev/null || true
  SERVE_PID=""
}

_served_rc() {
  local rc=0
  verify_served_worktree_check "CRE-1" "$SERVE_PORT" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

test_served_primary_checkout_on_other_branch_is_mismatch() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null || return 1
  # The bug: the primary clone (on main here — could be any other ticket's
  # branch) is what the dev server actually serves.
  _serve_from "$FIXTURE_REPO" || return 1
  local rc
  rc=$(_served_rc)
  _serve_stop
  [ "$rc" = "1" ] || {
    echo "  expected rc 1 (wrong checkout served), got $rc" >&2
    return 1
  }
  return 0
}
_run "served from primary checkout on another commit -> mismatch (rc 1)" test_served_primary_checkout_on_other_branch_is_mismatch

test_served_from_verify_worktree_matches() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix") || return 1
  mkdir -p "$wt_path/fe"
  _serve_from "$wt_path/fe" || return 1
  local rc
  rc=$(_served_rc)
  _serve_stop
  [ "$rc" = "0" ] || {
    echo "  expected rc 0 (served from the verify worktree subdir), got $rc" >&2
    return 1
  }
  return 0
}
_run "served from the verify worktree (subdir cwd) -> match (rc 0)" test_served_from_verify_worktree_matches

test_served_other_checkout_same_commit_matches() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null || return 1
  git -C "$FIXTURE_REPO" checkout -q --detach origin/feat/CRE-1-fix || return 1
  _serve_from "$FIXTURE_REPO" || return 1
  local rc
  rc=$(_served_rc)
  _serve_stop
  [ "$rc" = "0" ] || {
    echo "  expected rc 0 (clean checkout at the same commit), got $rc" >&2
    return 1
  }
  return 0
}
_run "served from another clean checkout at the same commit -> match (rc 0)" test_served_other_checkout_same_commit_matches

test_served_dirty_same_commit_is_mismatch() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null || return 1
  git -C "$FIXTURE_REPO" checkout -q --detach origin/feat/CRE-1-fix || return 1
  echo "local edit" >>"$FIXTURE_REPO/file.txt"
  _serve_from "$FIXTURE_REPO" || return 1
  local rc
  rc=$(_served_rc)
  _serve_stop
  [ "$rc" = "1" ] || {
    echo "  expected rc 1 (same commit but tracked changes), got $rc" >&2
    return 1
  }
  return 0
}
_run "served from same commit with uncommitted tracked edits -> mismatch (rc 1)" test_served_dirty_same_commit_is_mismatch

test_served_unrelated_dir_is_undeterminable() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null || return 1
  mkdir -p "$FIXTURE_DIR/not-a-repo"
  _serve_from "$FIXTURE_DIR/not-a-repo" || return 1
  local rc
  rc=$(_served_rc)
  _serve_stop
  [ "$rc" = "3" ] || {
    echo "  expected rc 3 (not a checkout of a repo under test), got $rc" >&2
    return 1
  }
  return 0
}
_run "served from a non-git dir -> undeterminable (rc 3), never a false mismatch" test_served_unrelated_dir_is_undeterminable

test_served_no_listener_is_undeterminable() {
  _setup_fixture
  ensure_verify_worktree "CRE-1" "$FIXTURE_REPO" "feat/CRE-1-fix" >/dev/null || return 1
  SERVE_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  local rc
  rc=$(_served_rc)
  [ "$rc" = "3" ] || {
    echo "  expected rc 3 (no listener), got $rc" >&2
    return 1
  }
  return 0
}
_run "no listener on the port -> undeterminable (rc 3)" test_served_no_listener_is_undeterminable

test_skill_md_env_start_gets_worktree_contract() {
  # The env-start.sh invocation must re-derive the worktree exports in its
  # own block (an export in Step 1.6a4's block never reaches it) and must be
  # followed by the served-checkout check.
  local skill_md="$LIB_DIR/../skills/ticket-verify/SKILL.md"
  local section
  section=$(awk '/^### 1\.6b /{f=1} /^## Step 1\.7/{f=0} f' "$skill_md")
  [ -n "$section" ] || {
    echo "  Step 1.6b section not found" >&2
    return 1
  }
  printf '%s' "$section" | grep -q 'eval "$(verify_worktree_exports "{TICKET-ID}")"' || {
    echo "  Step 1.6b does not eval verify_worktree_exports before env-start.sh" >&2
    return 1
  }
  printf '%s' "$section" | grep -q 'verify_served_check_ports "{TICKET-ID}"' || {
    echo "  Step 1.6b does not run verify_served_check_ports" >&2
    return 1
  }
  printf '%s' "$section" | grep -q 'VERIFY_SERVED_WRONG_WORKTREE' || {
    echo "  Step 1.6b does not gate-stop on a wrong served checkout" >&2
    return 1
  }
  # Every block that derives worktree paths must resolve REPOS_ROOT itself:
  # each env-start.sh block and the served-checkout block.
  local blocks inits
  blocks=$(printf '%s\n' "$section" | grep -c '^```bash' || true)
  inits=$(printf '%s\n' "$section" | grep -c '^verify_env_init "{TICKET-ID}"' || true)
  [ "$inits" -ge 3 ] || {
    echo "  Step 1.6b: verify_env_init appears $inits time(s) across $blocks blocks, expected >= 3" >&2
    return 1
  }
  # Every env-start.sh call is preceded, in its block, by verify_env_init and
  # the exports eval — in that order.
  local bad
  bad=$(printf '%s\n' "$section" | awk '
    /^```bash/ { inb=1; init=0; ev=0; next }
    /^```/     { inb=0; next }
    inb && /^verify_env_init / { init=1 }
    inb && /verify_worktree_exports/ { if (!init) print "exports before init"; ev=1 }
    inb && /^bash .*env-start\.sh/ { if (!init || !ev) print "env-start without init+exports: " $0 }
  ')
  [ -z "$bad" ] || {
    echo "  Step 1.6b: $bad" >&2
    return 1
  }
  return 0
}
_run "SKILL.md Step 1.6b passes the worktree contract and checks the served checkout" test_skill_md_env_start_gets_worktree_contract

test_skill_md_worktree_setup_resolves_repos_root() {
  # Step 1.6a4 used to rely on an inherited REPOS_ROOT; unset, every repo was
  # skipped and the step still logged "worktrees ready".
  local skill_md="$LIB_DIR/../skills/ticket-verify/SKILL.md"
  local section
  section=$(awk '/^### 1\.6a4 /{f=1} /^### 1\.6b /{f=0} f' "$skill_md")
  [ -n "$section" ] || return 1
  local init_line ensure_line
  init_line=$(printf '%s\n' "$section" | grep -n '^verify_env_init "{TICKET-ID}"' | head -1 | cut -d: -f1)
  ensure_line=$(printf '%s\n' "$section" | grep -n 'ensure_verify_worktree "{TICKET-ID}"' | head -1 | cut -d: -f1)
  [ -n "$init_line" ] && [ -n "$ensure_line" ] && [ "$init_line" -lt "$ensure_line" ] || {
    echo "  Step 1.6a4 does not call verify_env_init before ensure_verify_worktree" >&2
    return 1
  }
  printf '%s' "$section" | grep -q 'VERIFY_WORKTREE_NONE' || {
    echo "  Step 1.6a4 does not warn when no worktree was created" >&2
    return 1
  }
  printf '%s' "$section" | grep -q 'verify_worktree_env_var' || {
    echo "  Step 1.6a4 names the export without verify_worktree_env_var" >&2
    return 1
  }
  return 0
}
_run "SKILL.md Step 1.6a4 resolves REPOS_ROOT before creating worktrees" test_skill_md_worktree_setup_resolves_repos_root

echo ""
echo "=== REPOS_ROOT resolution, multi-port check, served report (#419) ==="
echo ""

test_served_no_verify_worktrees_is_rc4() {
  _setup_fixture
  _serve_from "$FIXTURE_REPO" || return 1
  local rc
  rc=$(_served_rc)
  _serve_stop
  [ "$rc" = "4" ] || {
    echo "  expected rc 4 (no verify worktrees to compare), got $rc" >&2
    return 1
  }
  return 0
}
_run "no verify worktree for the ticket -> rc 4, not a quiet rc 3" test_served_no_verify_worktrees_is_rc4

test_env_init_keeps_set_repos_root() {
  _setup_fixture
  (
    cd "$FIXTURE_DIR" || exit 1
    printf 'REPOS_ROOT = /nonexistent/elsewhere\n' >CLAUDE.md
    verify_env_init "TICKET-1" ./CLAUDE.md 2>/dev/null || exit 1
    [ "$REPOS_ROOT" = "$FIXTURE_DIR/repos" ]
  )
}
_run "verify_env_init keeps an already-set REPOS_ROOT" test_env_init_keeps_set_repos_root

test_env_init_reads_ticket_env_file() {
  _setup_fixture
  local tid="TESTENV$$" env_file
  env_file="/tmp/ticket-auto-${tid}-env.sh"
  printf 'export TICKET_ID="%s"\nexport REPOS_ROOT="%s"\nexport LOCAL_URL="http://x:1"\n' "$tid" "$REPOS_ROOT" >"$env_file"
  local rc=0
  (
    unset REPOS_ROOT LOCAL_URL
    cd "$FIXTURE_DIR" || exit 1
    verify_env_init "$tid" ./no-such-CLAUDE.md 2>/dev/null || exit 1
    [ "$REPOS_ROOT" = "$FIXTURE_DIR/repos" ] || exit 1
    # Read, never sourced: nothing else from the env file leaks in.
    [ -z "${LOCAL_URL:-}" ] || exit 1
  ) || rc=$?
  rm -f "$env_file"
  [ "$rc" -eq 0 ]
}
_run "verify_env_init reads REPOS_ROOT from the ticket env file without sourcing it" test_env_init_reads_ticket_env_file

# spawn_write_env escapes \ " $ ` inside the quotes (BE-4); the reader must
# undo it so a REPOS_ROOT with such characters resolves to the real directory.
test_env_init_unescapes_spawn_write_env_value() {
  _setup_fixture
  local tid="TESTENVQ$$" env_file odd rc=0
  odd="$FIXTURE_DIR/re\$po\"s"
  mkdir -p "$odd"
  env_file="/tmp/ticket-auto-${tid}-env.sh"
  (
    unset LINEAR_API_KEY
    source "$LIB_DIR/spawn-helper.sh"
    spawn_write_env TICKET_ID="$tid" REPOS_ROOT="$odd" ISSUE_PREFIX=T BE_SERVICES=s >/dev/null 2>&1
  ) || rc=$?
  (
    unset REPOS_ROOT
    cd "$FIXTURE_DIR" || exit 1
    verify_env_init "$tid" ./no-such-CLAUDE.md 2>/dev/null || exit 1
    [ "$REPOS_ROOT" = "$odd" ]
  ) || rc=$?
  rm -f "$env_file"
  [ "$rc" -eq 0 ]
}
_run "verify_env_init unescapes a spawn_write_env-quoted REPOS_ROOT" test_env_init_unescapes_spawn_write_env_value

test_env_init_reads_claude_md() {
  _setup_fixture
  (
    unset REPOS_ROOT VERIFY_SERVED_PORTS
    cd "$FIXTURE_DIR" || exit 1
    printf '`REPOS_ROOT` = %s\n`VERIFY_SERVED_PORTS` = 8080, http://localhost:9000\n' "$FIXTURE_DIR/repos" >CLAUDE.md
    verify_env_init "NO-ENV-FILE" ./CLAUDE.md 2>/dev/null || exit 1
    [ "$REPOS_ROOT" = "$FIXTURE_DIR/repos" ] || exit 1
    [ "$VERIFY_SERVED_PORTS" = "8080, http://localhost:9000" ] || exit 1
  )
}
_run "verify_env_init falls back to CLAUDE.md for REPOS_ROOT and VERIFY_SERVED_PORTS" test_env_init_reads_claude_md

test_env_init_env_overrides_served_ports_field() {
  _setup_fixture
  (
    cd "$FIXTURE_DIR" || exit 1
    printf 'VERIFY_SERVED_PORTS = 8080\n' >CLAUDE.md
    VERIFY_SERVED_PORTS=7070
    verify_env_init "TICKET-1" ./CLAUDE.md 2>/dev/null || exit 1
    [ "$VERIFY_SERVED_PORTS" = "7070" ]
  )
}
_run "VERIFY_SERVED_PORTS in the environment overrides the CLAUDE.md field" test_env_init_env_overrides_served_ports_field

test_env_init_fails_when_unresolvable() {
  _setup_fixture
  (
    unset REPOS_ROOT
    cd "$FIXTURE_DIR" || exit 1
    ! verify_env_init "NO-ENV-FILE" ./no-such-CLAUDE.md 2>/dev/null
  ) || return 1
  (
    REPOS_ROOT="$FIXTURE_DIR/does-not-exist"
    ! verify_env_init "TICKET-1" ./no-such-CLAUDE.md 2>/dev/null
  )
}
_run "verify_env_init fails when REPOS_ROOT is unset or not a directory" test_env_init_fails_when_unresolvable

test_exports_after_env_init_in_fresh_shell() {
  # The bug class: a fresh shell with no REPOS_ROOT produced exports with no
  # VERIFY_REPO_PATH_* at all, so env-start.sh served the primary checkout.
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "TICKET-1" "$FIXTURE_REPO" "feat/CRE-1-fix") || return 1
  (
    unset REPOS_ROOT
    cd "$FIXTURE_DIR" || exit 1
    printf 'REPOS_ROOT=%s\n' "$FIXTURE_DIR/repos" >CLAUDE.md
    verify_env_init "NO-ENV-FILE" ./CLAUDE.md 2>/dev/null || exit 1
    out=$(verify_worktree_exports "TICKET-1")
    unset VERIFY_REPO_PATH_MY_SERVICE
    eval "$out"
    [ "${VERIFY_REPO_PATH_MY_SERVICE:-}" = "$wt_path" ]
  )
}
_run "verify_env_init + verify_worktree_exports in a fresh shell name the worktree" test_exports_after_env_init_in_fresh_shell

test_served_ports_parsing() {
  local out
  out=$(verify_served_ports "http://localhost:3000" "8080, http://127.0.0.1:9000/x 3000" 2>/dev/null)
  [ "$out" = "3000 8080 9000" ] || {
    echo "  got '$out'" >&2
    return 1
  }
  out=$(verify_served_ports "http://localhost:3000" "" 2>/dev/null)
  [ "$out" = "3000" ] || return 1
  out=$(verify_served_ports "bogus" "4000" 2>/dev/null)
  [ "$out" = "4000" ] || return 1
  verify_served_ports "bogus" 2>&1 >/dev/null | grep -q "unparseable" || return 1
  return 0
}
_run "verify_served_ports normalises, dedupes and drops bad items" test_served_ports_parsing

# Second listener, independent of SERVE_PID/SERVE_PORT.
_serve2_from() {
  local dir="$1" i
  SERVE2_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  (cd "$dir" && exec python3 -m http.server "$SERVE2_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  SERVE2_PID=$!
  for i in $(seq 1 50); do
    [ -n "$(_verify_listening_pids "$SERVE2_PORT")" ] && return 0
    sleep 0.1
  done
  return 1
}
_serve2_stop() {
  [ -n "${SERVE2_PID:-}" ] && kill "$SERVE2_PID" 2>/dev/null
  wait "$SERVE2_PID" 2>/dev/null || true
  SERVE2_PID=""
}

test_check_ports_any_wrong_wins() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "TICKET-1" "$FIXTURE_REPO" "feat/CRE-1-fix") || return 1
  _serve_from "$wt_path" || return 1
  _serve2_from "$FIXTURE_REPO" || {
    _serve_stop
    return 1
  }
  local rc=0 out
  out=$(verify_served_check_ports "TICKET-1" "$SERVE_PORT" "$SERVE2_PORT" 2>/dev/null) || rc=$?
  _serve_stop
  _serve2_stop
  [ "$rc" = "1" ] || {
    echo "  expected rc 1 (one port serves the primary checkout), got $rc: $out" >&2
    return 1
  }
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || {
    echo "  summary is not one line: $out" >&2
    return 1
  }
  printf '%s' "$out" | grep -q ":$SERVE_PORT ok" && printf '%s' "$out" | grep -q ":$SERVE2_PORT wrong"
}
_run "multi-port check: ok on one port + wrong on another -> rc 1, one-line summary" test_check_ports_any_wrong_wins

test_check_ports_ok_plus_undetermined() {
  _setup_fixture
  local wt_path free_port
  wt_path=$(ensure_verify_worktree "TICKET-1" "$FIXTURE_REPO" "feat/CRE-1-fix") || return 1
  _serve_from "$wt_path" || return 1
  free_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  local rc=0
  verify_served_check_ports "TICKET-1" "$SERVE_PORT" "$free_port" >/dev/null 2>&1 || rc=$?
  _serve_stop
  [ "$rc" = "0" ] || {
    echo "  expected rc 0, got $rc" >&2
    return 1
  }
  rc=0
  verify_served_check_ports "TICKET-1" "$free_port" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "3" ] || {
    echo "  expected rc 3 for only undeterminable ports, got $rc" >&2
    return 1
  }
  rc=0
  verify_served_check_ports "TICKET-1" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "3" ]
}
_run "multi-port check: primary ok + extra undetermined -> 0; only undetermined or none -> 3" test_check_ports_ok_plus_undetermined

test_check_ports_extra_ok_does_not_cover_primary() {
  # The primary port (LOCAL_URL's — what the browser hits) undecided while an
  # extra port is fine must not pass: the extra says nothing about the primary.
  _setup_fixture
  local wt_path free_port
  wt_path=$(ensure_verify_worktree "TICKET-1" "$FIXTURE_REPO" "feat/CRE-1-fix") || return 1
  _serve_from "$wt_path" || return 1
  free_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  local rc=0
  verify_served_check_ports "TICKET-1" "$free_port" "$SERVE_PORT" >/dev/null 2>&1 || rc=$?
  _serve_stop
  [ "$rc" = "3" ] || {
    echo "  expected rc 3 (primary undetermined, extra ok), got $rc" >&2
    return 1
  }
  return 0
}
_run "multi-port check: primary undetermined + extra ok -> 3, never 0" test_check_ports_extra_ok_does_not_cover_primary

test_url_port_fragment_and_query() {
  [ "$(verify_url_port 'http://localhost:3000#frag')" = "3000" ] || return 1
  [ "$(verify_url_port 'http://localhost#frag')" = "80" ] || return 1
  [ "$(verify_url_port 'https://localhost:8443?a=b#c')" = "8443" ] || return 1
  [ "$(verify_url_port 'http://user@host.test:4000/p')" = "4000" ] || return 1
  return 0
}
_run "verify_url_port handles '#' fragments and queries" test_url_port_fragment_and_query

test_skill_md_gc_resolves_repos_root() {
  local skill_md="$LIB_DIR/../skills/ticket-verify/SKILL.md"
  local section
  section=$(awk '/^### 1\.6a2 /{f=1} /^### 1\.6a2b /{f=0} f' "$skill_md")
  [ -n "$section" ] || return 1
  printf '%s\n' "$section" | grep -q '^verify_env_init "{TICKET-ID}" ./CLAUDE.md && verify_worktree_gc' || {
    echo "  Step 1.6a2 does not resolve REPOS_ROOT before verify_worktree_gc" >&2
    return 1
  }
  # No bare GC call that would run with an unresolved REPOS_ROOT.
  ! printf '%s\n' "$section" | grep -q '^verify_worktree_gc'
}
_run "SKILL.md Step 1.6a2 resolves REPOS_ROOT before the GC sweep" test_skill_md_gc_resolves_repos_root

test_skill_md_undecided_is_a_gate_warn() {
  # rc 3 used to be a quiet `served-worktree|skip`; it must be a visible warn.
  local skill_md="$LIB_DIR/../skills/ticket-verify/SKILL.md"
  local section
  section=$(awk '/^### 1\.6b /{f=1} /^## Step 1\.7/{f=0} f' "$skill_md")
  [ -n "$section" ] || return 1
  if printf '%s' "$section" | grep -qE 'served-worktree\|skip|VERIFY served-worktree skip'; then
    echo "  Step 1.6b still logs an undecided check as a quiet skip" >&2
    return 1
  fi
  local warns
  warns=$(printf '%s\n' "$section" | grep -c 'plog.sh META gate-warn warn "VERIFY_SERVED_UNVERIFIED' || true)
  [ "$warns" -ge 2 ] || {
    echo "  expected VERIFY_SERVED_UNVERIFIED gate-warns for rc 3 and rc 4, found $warns" >&2
    return 1
  }
  printf '%s' "$section" | grep -q 'env-start.sh with --restart' || {
    echo "  wrong-worktree message does not tell the operator how to recover" >&2
    return 1
  }
  return 0
}
_run "SKILL.md Step 1.6b writes undecided checks as a VERIFY_SERVED_UNVERIFIED gate-warn" test_skill_md_undecided_is_a_gate_warn

test_served_report_and_cli() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_verify_worktree "TICKET-1" "$FIXTURE_REPO" "feat/CRE-1-fix") || return 1
  _serve_from "$wt_path" || return 1
  local report rc=0
  report=$(bash "$LIB_DIR/verify-worktree.sh" served "http://127.0.0.1:$SERVE_PORT" 2>/dev/null)
  bash "$LIB_DIR/verify-worktree.sh" check TICKET-1 "$SERVE_PORT" </dev/null >/dev/null 2>&1 || rc=$?
  _serve_stop
  printf '%s' "$report" | grep -q "checkout=$(cd "$wt_path" && pwd -P)" &&
    printf '%s' "$report" | grep -q "branch=feat/CRE-1-fix" || {
    echo "  report missing checkout/branch: $report" >&2
    return 1
  }
  [ "$rc" = "0" ] || {
    echo "  CLI check expected rc 0, got $rc" >&2
    return 1
  }
  local usage_rc=0
  bash "$LIB_DIR/verify-worktree.sh" bogus </dev/null >/dev/null 2>&1 || usage_rc=$?
  [ "$usage_rc" = "2" ]
}
_run "served report + CLI (served/check/usage) for a project's env-status.sh" test_served_report_and_cli

echo ""
echo "=== SKILL.md step ordering ==="
echo ""

test_skill_md_acquires_lock_before_worktree_resync() {
  # Regression (Finding 3, adversarial review of PR #338): the destructive
  # worktree resync (`ensure_verify_worktree`, which resets/cleans on
  # reuse) must be procedurally gated behind the single-flight lock — see
  # the 1.6 preamble and Step 1.6a4 in SKILL.md. This isn't something a
  # bash unit test can exercise directly (it's a step-ordering contract in
  # a markdown procedure, not a function call), so assert the ordering
  # itself: the "Acquire the single-flight verify lock" heading (1.6a3)
  # must appear, by line number, before both the "Resolve isolated
  # worktrees" heading (1.6a4) and the first `ensure_verify_worktree` call
  # inside it. A future edit that moves the resync back above the lock (or
  # renames the sections without moving the content) trips this.
  local skill_md="$LIB_DIR/../skills/ticket-verify/SKILL.md"
  [ -f "$skill_md" ] || {
    echo "  SKILL.md not found at $skill_md" >&2
    return 1
  }

  local lock_line worktree_heading_line first_ensure_call_line
  lock_line=$(grep -n '^### 1\.6a3 — Acquire the single-flight verify lock' "$skill_md" | head -1 | cut -d: -f1)
  worktree_heading_line=$(grep -n '^### 1\.6a4 — Resolve isolated worktrees' "$skill_md" | head -1 | cut -d: -f1)
  first_ensure_call_line=$(grep -n 'ensure_verify_worktree "{TICKET-ID}"' "$skill_md" | head -1 | cut -d: -f1)

  [ -n "$lock_line" ] || {
    echo "  could not find the 'Acquire the single-flight verify lock' heading" >&2
    return 1
  }
  [ -n "$worktree_heading_line" ] || {
    echo "  could not find the 'Resolve isolated worktrees' heading" >&2
    return 1
  }
  [ -n "$first_ensure_call_line" ] || {
    echo "  could not find an ensure_verify_worktree call in SKILL.md" >&2
    return 1
  }

  [ "$lock_line" -lt "$worktree_heading_line" ] || {
    echo "  lock-acquire heading (line $lock_line) is not before the worktree-resync heading (line $worktree_heading_line)" >&2
    return 1
  }
  [ "$lock_line" -lt "$first_ensure_call_line" ] || {
    echo "  lock-acquire heading (line $lock_line) is not before the first ensure_verify_worktree call (line $first_ensure_call_line)" >&2
    return 1
  }
  return 0
}
_run "SKILL.md acquires the verify lock before the worktree resync" test_skill_md_acquires_lock_before_worktree_resync

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
