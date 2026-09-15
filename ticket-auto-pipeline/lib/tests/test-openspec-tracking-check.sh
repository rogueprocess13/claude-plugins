#!/usr/bin/env bash
# test-openspec-tracking-check.sh — tests for lib/openspec-tracking-check.sh
# Covers the durability guard for openspec plan artifacts (issue #363,
# OPENSPEC_ARTIFACTS_UNTRACKED): commit (idempotent git add -f + commit),
# assert (close-out warn check), and audit (one-off sweep).
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
CHECK="$LIB_DIR/openspec-tracking-check.sh"

PASS=0
FAIL=0

_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

_ws=""

_setup() {
  _ws="$(mktemp -d)"
  git init -q "$_ws"
  git -C "$_ws" config user.email t@t.com
  git -C "$_ws" config user.name Test
  git -C "$_ws" commit -q --allow-empty -m init
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# Seeds a blanket `openspec/` ignore rule in the mock tickets repo, mirroring
# the real-world convention that predates this durability requirement.
_seed_gitignore() {
  echo "openspec/" >"$_ws/.gitignore"
  git -C "$_ws" add .gitignore
  git -C "$_ws" commit -q -m "ignore openspec"
}

_write_change() {
  local ticket_lower="$1"
  mkdir -p "$_ws/openspec/changes/${ticket_lower}--fix-thing"
  printf '# tasks\n- [ ] do it\n' >"$_ws/openspec/changes/${ticket_lower}--fix-thing/tasks.md"
}

# ── commit ────────────────────────────────────────────────────────────────

test_commit_force_adds_gitignored_dir() {
  _setup
  _seed_gitignore
  _write_change "wil-1"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-1--fix-thing/" WIL-1) || rc=$?
  local tracked
  tracked=$(git -C "$_ws" ls-files -- openspec/changes/wil-1--fix-thing/ | wc -l | tr -d ' ')
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_COMMIT_STATUS=committed' && [ "$tracked" -eq 1 ]
}

test_commit_is_idempotent_noop_on_rerun() {
  _setup
  _seed_gitignore
  _write_change "wil-2"
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-2--fix-thing/" WIL-2 >/dev/null)
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-2--fix-thing/" WIL-2) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_COMMIT_STATUS=noop'
}

test_commit_picks_up_regenerated_content() {
  _setup
  _seed_gitignore
  _write_change "wil-3"
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-3--fix-thing/" WIL-3 >/dev/null)
  echo "- [ ] a second task" >>"$_ws/openspec/changes/wil-3--fix-thing/tasks.md"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-3--fix-thing/" WIL-3) || rc=$?
  local log_count
  log_count=$(git -C "$_ws" log --oneline -- openspec/changes/wil-3--fix-thing/ | wc -l | tr -d ' ')
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_COMMIT_STATUS=committed' && [ "$log_count" -eq 2 ]
}

test_commit_errors_on_missing_dir() {
  _setup
  local rc=0
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/nope--x/" WIL-4) >/dev/null 2>&1 || rc=$?
  _teardown
  [ "$rc" -eq 2 ]
}

test_commit_errors_outside_git_repo() {
  local nogit
  nogit="$(mktemp -d)"
  mkdir -p "$nogit/openspec/changes/wil-5--x"
  echo x >"$nogit/openspec/changes/wil-5--x/tasks.md"
  local rc=0
  (cd "$nogit" && bash "$CHECK" commit "openspec/changes/wil-5--x/" WIL-5) >/dev/null 2>&1 || rc=$?
  rm -rf "$nogit"
  [ "$rc" -eq 2 ]
}

# ── assert ────────────────────────────────────────────────────────────────

test_assert_reports_gitignored_before_commit() {
  _setup
  _seed_gitignore
  _write_change "wil-6"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-6) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_STATUS=gitignored'
}

test_assert_reports_tracked_after_commit() {
  _setup
  _seed_gitignore
  _write_change "wil-7"
  (cd "$_ws" && bash "$CHECK" commit "openspec/changes/wil-7--fix-thing/" WIL-7 >/dev/null)
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-7) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_STATUS=tracked'
}

test_assert_no_change_dir_without_expect_is_not_applicable() {
  _setup
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-8) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_STATUS=not-applicable'
}

test_assert_no_change_dir_with_expect_is_missing() {
  _setup
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-9 --expect) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_STATUS=missing'
}

test_assert_untracked_but_not_ignored() {
  _setup
  _write_change "wil-10"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-10) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_STATUS=untracked'
}

test_assert_partial_when_some_files_committed_some_not() {
  _setup
  _write_change "wil-11"
  git -C "$_ws" add openspec/changes/wil-11--fix-thing/tasks.md
  git -C "$_ws" commit -q -m "partial commit"
  echo "extra" >"$_ws/openspec/changes/wil-11--fix-thing/design.md"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert WIL-11) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_STATUS=partial'
}

test_assert_is_case_insensitive_on_ticket_id() {
  _setup
  _write_change "wil-12"
  git -C "$_ws" add -f openspec/changes/wil-12--fix-thing/
  git -C "$_ws" commit -q -m "commit"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" assert wil-12) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_STATUS=tracked'
}

# ── audit ─────────────────────────────────────────────────────────────────

test_audit_reports_all_clean() {
  _setup
  _write_change "wil-13"
  git -C "$_ws" add -f openspec/changes/wil-13--fix-thing/
  git -C "$_ws" commit -q -m "commit"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" audit) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_SUMMARY|total=1|issues=0'
}

test_audit_detects_existing_untracked_changes() {
  _setup
  _seed_gitignore
  _write_change "wil-14"
  _write_change "wil-15"
  git -C "$_ws" add -f openspec/changes/wil-15--fix-thing/
  git -C "$_ws" commit -q -m "commit one of two"
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" audit) || rc=$?
  _teardown
  [ "$rc" -eq 1 ] &&
    echo "$out" | grep -q 'wil-14--fix-thing.*gitignored' &&
    echo "$out" | grep -q 'wil-15--fix-thing.*tracked' &&
    echo "$out" | grep -q 'OPENSPEC_TRACK_SUMMARY|total=2|issues=1'
}

test_audit_with_explicit_root() {
  _setup
  _write_change "wil-16"
  git -C "$_ws" add -f openspec/changes/wil-16--fix-thing/
  git -C "$_ws" commit -q -m "commit"
  local out rc=0
  out=$(bash "$CHECK" audit --root "$_ws") || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_SUMMARY|total=1|issues=0'
}

test_audit_no_changes_is_clean() {
  _setup
  local out rc=0
  out=$(cd "$_ws" && bash "$CHECK" audit) || rc=$?
  _teardown
  [ "$rc" -eq 0 ] && echo "$out" | grep -q 'OPENSPEC_TRACK_SUMMARY|total=0|issues=0'
}

test_usage_exits_2_with_no_args() {
  local rc=0
  bash "$CHECK" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

# ── Runner ───────────────────────────────────────────────────────────────────

for t in test_commit_force_adds_gitignored_dir test_commit_is_idempotent_noop_on_rerun \
  test_commit_picks_up_regenerated_content test_commit_errors_on_missing_dir \
  test_commit_errors_outside_git_repo test_assert_reports_gitignored_before_commit \
  test_assert_reports_tracked_after_commit test_assert_no_change_dir_without_expect_is_not_applicable \
  test_assert_no_change_dir_with_expect_is_missing test_assert_untracked_but_not_ignored \
  test_assert_partial_when_some_files_committed_some_not test_assert_is_case_insensitive_on_ticket_id \
  test_audit_reports_all_clean test_audit_detects_existing_untracked_changes \
  test_audit_with_explicit_root test_audit_no_changes_is_clean test_usage_exits_2_with_no_args; do
  if "$t"; then
    _pass "$t"
  else
    _fail "$t"
  fi
done

echo ""
echo "=== test-openspec-tracking-check.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
