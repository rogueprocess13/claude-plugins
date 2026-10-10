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
  printf '%s' "$section" | grep -q 'verify_served_worktree_check "{TICKET-ID}"' || {
    echo "  Step 1.6b does not run verify_served_worktree_check" >&2
    return 1
  }
  printf '%s' "$section" | grep -q 'VERIFY_SERVED_WRONG_WORKTREE' || {
    echo "  Step 1.6b does not gate-stop on a wrong served checkout" >&2
    return 1
  }
  return 0
}
_run "SKILL.md Step 1.6b passes the worktree contract and checks the served checkout" test_skill_md_env_start_gets_worktree_contract

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
