#!/usr/bin/env bash
# test-gitnexus-preflight.sh — unit tests for lib/gitnexus-preflight.sh
# (GITNEXUS_PREFLIGHT_BRANCH_UNVERIFIED, GH issue #359).
# Creates a real git repo fixture with diverging branches and exercises
# gitnexus_verify_branch / gitnexus_check_result_subset against it.
# Usage: bash test-gitnexus-preflight.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/gitnexus-preflight.sh"

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
# A repo with:
#   main       — 1 commit (BASE_SHA)
#   feat-a     — main + 2 commits (the "PR branch"; HEAD = FEAT_A_SHA)
#   feat-b     — main + 1 unrelated commit (the "wrong branch" GitNexus is
#                indexed on; HEAD = FEAT_B_SHA, not an ancestor of feat-a)
_setup_fixture() {
  FIXTURE_DIR=$(mktemp -d)
  REPO="$FIXTURE_DIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -b main 2>/dev/null || git -C "$REPO" init
  git -C "$REPO" config user.email "test@test.com"
  git -C "$REPO" config user.name "Test"

  echo "base" >"$REPO/base.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -m "initial" --no-gpg-sign -q
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)

  git -C "$REPO" checkout -b feat-a -q
  echo "a1" >"$REPO/a1.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -m "feat-a: step 1" --no-gpg-sign -q
  FEAT_A_MID_SHA=$(git -C "$REPO" rev-parse HEAD)
  echo "a2" >"$REPO/a2.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -m "feat-a: step 2" --no-gpg-sign -q
  FEAT_A_SHA=$(git -C "$REPO" rev-parse HEAD)

  git -C "$REPO" checkout main -q
  git -C "$REPO" checkout -b feat-b -q
  echo "b1" >"$REPO/b1.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -m "feat-b: unrelated" --no-gpg-sign -q
  FEAT_B_SHA=$(git -C "$REPO" rev-parse HEAD)

  git -C "$REPO" checkout feat-a -q
}

_cleanup_fixture() {
  [ -n "${FIXTURE_DIR:-}" ] && rm -rf "$FIXTURE_DIR"
}

# ── gitnexus_verify_branch ──────────────────────────────────────────────────

test_verify_branch_exact_match() {
  _setup_fixture
  local out rc=0
  out=$(gitnexus_verify_branch "$REPO" "$FEAT_A_SHA" "$FEAT_A_SHA") || rc=$?
  _cleanup_fixture
  [ "$rc" -eq 0 ] || {
    echo "  expected exit 0, got $rc" >&2
    return 1
  }
  [ "$out" = "ok 0" ] || {
    echo "  expected 'ok 0', got '$out'" >&2
    return 1
  }
  return 0
}
_run "verify_branch: indexed commit == expected ref" test_verify_branch_exact_match

test_verify_branch_ancestor_within_threshold() {
  _setup_fixture
  local out rc=0
  out=$(gitnexus_verify_branch "$REPO" "$FEAT_A_MID_SHA" "$FEAT_A_SHA" 20) || rc=$?
  _cleanup_fixture
  [ "$rc" -eq 0 ] || {
    echo "  expected exit 0, got $rc" >&2
    return 1
  }
  [ "$out" = "ok 1" ] || {
    echo "  expected 'ok 1' (1 commit behind), got '$out'" >&2
    return 1
  }
  return 0
}
_run "verify_branch: indexed commit is an ancestor, within threshold" test_verify_branch_ancestor_within_threshold

test_verify_branch_ancestor_beyond_threshold() {
  _setup_fixture
  local out rc=0
  out=$(gitnexus_verify_branch "$REPO" "$FEAT_A_MID_SHA" "$FEAT_A_SHA" 0) || rc=$?
  _cleanup_fixture
  [ "$rc" -eq 1 ] || {
    echo "  expected exit 1 (stale), got $rc" >&2
    return 1
  }
  [ "$out" = "stale 1" ] || {
    echo "  expected 'stale 1', got '$out'" >&2
    return 1
  }
  return 0
}
_run "verify_branch: indexed commit beyond max_commits_behind is stale" test_verify_branch_ancestor_beyond_threshold

test_verify_branch_wrong_branch() {
  _setup_fixture
  local out rc=0
  # GitNexus indexed feat-b's HEAD, but the caller is asking about feat-a —
  # this is the exact WIL-75/77/82 scenario (#359).
  out=$(gitnexus_verify_branch "$REPO" "$FEAT_B_SHA" "$FEAT_A_SHA") || rc=$?
  _cleanup_fixture
  [ "$rc" -eq 1 ] || {
    echo "  expected exit 1 (wrong-branch), got $rc" >&2
    return 1
  }
  [ "$out" = "wrong-branch" ] || {
    echo "  expected 'wrong-branch', got '$out'" >&2
    return 1
  }
  return 0
}
_run "verify_branch: indexed clone on an unrelated branch is rejected" test_verify_branch_wrong_branch

test_verify_branch_ahead() {
  _setup_fixture
  local out rc=0
  # GitNexus indexed feat-a's later commit, but the caller is asking about an
  # earlier point on the same branch (e.g. a rebase/force-push moved the ref
  # backward) — same lineage, wrong direction. Distinct from wrong-branch.
  out=$(gitnexus_verify_branch "$REPO" "$FEAT_A_SHA" "$FEAT_A_MID_SHA") || rc=$?
  _cleanup_fixture
  [ "$rc" -eq 1 ] || {
    echo "  expected exit 1 (ahead), got $rc" >&2
    return 1
  }
  [ "$out" = "ahead 1" ] || {
    echo "  expected 'ahead 1', got '$out'" >&2
    return 1
  }
  return 0
}
_run "verify_branch: indexed commit ahead of expected_ref in same lineage is labeled 'ahead', not 'wrong-branch'" test_verify_branch_ahead

test_verify_branch_unknown_ref() {
  _setup_fixture
  local out rc=0
  out=$(gitnexus_verify_branch "$REPO" "$FEAT_A_SHA" "totally-bogus-ref") || rc=$?
  _cleanup_fixture
  [ "$rc" -eq 2 ] || {
    echo "  expected exit 2 (unresolvable), got $rc" >&2
    return 1
  }
  case "$out" in
  unresolvable*) ;;
  *)
    echo "  expected 'unresolvable ...', got '$out'" >&2
    return 1
    ;;
  esac
  return 0
}
_run "verify_branch: unknown expected_ref is unresolvable, not falsely verified" test_verify_branch_unknown_ref

test_verify_branch_bad_repo_dir() {
  local out rc=0
  out=$(gitnexus_verify_branch "/nonexistent/path/xyz" "deadbeef" "main") || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "  expected exit 2, got $rc" >&2
    return 1
  }
  return 0
}
_run "verify_branch: nonexistent repo dir is unresolvable" test_verify_branch_bad_repo_dir

# ── gitnexus_check_result_subset ────────────────────────────────────────────

test_subset_ok_when_subset() {
  local tmp returned known rc=0
  tmp=$(mktemp -d)
  returned="$tmp/returned.txt"
  known="$tmp/known.txt"
  printf 'src/a.ts\nsrc/b.ts\n' >"$returned"
  printf 'src/a.ts\nsrc/b.ts\nsrc/c.ts\n' >"$known"
  gitnexus_check_result_subset "$returned" "$known" >/dev/null || rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 0 ]
}
_run "check_result_subset: returned files fully covered by known diff" test_subset_ok_when_subset

test_subset_fails_when_extra_files() {
  local tmp returned known out rc=0
  tmp=$(mktemp -d)
  returned="$tmp/returned.txt"
  known="$tmp/known.txt"
  # This mirrors WIL-77: detect_changes named 39 files, the real PR touched 8.
  printf 'src/a.ts\nworker/main.py\n' >"$returned"
  printf 'src/a.ts\n' >"$known"
  out=$(gitnexus_check_result_subset "$returned" "$known") || rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 1 ] || {
    echo "  expected exit 1 (not a subset), got $rc" >&2
    return 1
  }
  echo "$out" | grep -qF "worker/main.py" || {
    echo "  expected offending file 'worker/main.py' in output, got '$out'" >&2
    return 1
  }
  return 0
}
_run "check_result_subset: extra files outside the real diff are flagged" test_subset_fails_when_extra_files

test_subset_empty_returned_is_ok() {
  local tmp returned known rc=0
  tmp=$(mktemp -d)
  returned="$tmp/returned.txt"
  known="$tmp/known.txt"
  : >"$returned"
  printf 'src/a.ts\n' >"$known"
  gitnexus_check_result_subset "$returned" "$known" >/dev/null || rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 0 ]
}
_run "check_result_subset: zero-result detect_changes output is trivially a subset" test_subset_empty_returned_is_ok

test_subset_missing_file_is_usage_error() {
  local rc=0
  gitnexus_check_result_subset "/nonexistent/returned.txt" "/nonexistent/known.txt" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}
_run "check_result_subset: missing input file is a usage error" test_subset_missing_file_is_usage_error

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
