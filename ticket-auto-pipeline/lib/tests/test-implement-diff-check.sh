#!/usr/bin/env bash
# test-implement-diff-check.sh — unit tests for lib/implement-diff-check.sh
# (review finding DET-IP-9: nothing wrote IMPLEMENT|commit-push|skip, so
# ticket-pr-review's no-diff exemption could never fire). Uses temp git repos.
# Usage: bash test-implement-diff-check.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
IDC="$LIB_DIR/implement-diff-check.sh"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

_ws=""
_setup() {
  _ws=$(mktemp -d)
  git init -q -b develop "$_ws/repo"
  echo base >"$_ws/repo/a.txt"
  echo 'ignored.log' >"$_ws/repo/.gitignore"
  git -C "$_ws/repo" add -A
  git -C "$_ws/repo" commit -q -m base
  git -C "$_ws/repo" checkout -q -b feat/t-1
  : >"$_ws/log"
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

_rc=0
_idc() {
  _rc=0
  bash "$IDC" --base-ref develop --log-file "$_ws/log" "$@" >/dev/null 2>&1 || _rc=$?
}

test_clean_worktree_writes_skip() {
  _setup
  _idc "$_ws/repo"
  local ok=1
  [ "$_rc" = 4 ] && grep -q '|IMPLEMENT|commit-push|skip|' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_skip_line_matches_pr_review_exemption() {
  # Contract: the exact grep ticket-pr-review's no-diff exemption uses.
  _setup
  _idc "$_ws/repo"
  local pattern ok=1
  pattern=$(grep -o "grep -q '|IMPLEMENT|commit-push|skip|'" "$PLUGIN_DIR/skills/ticket-pr-review/SKILL.md" | head -1)
  [ -n "$pattern" ] && grep -q '|IMPLEMENT|commit-push|skip|' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_uncommitted_change_is_a_diff() {
  _setup
  echo change >>"$_ws/repo/a.txt"
  _idc "$_ws/repo"
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/log" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_untracked_file_is_a_diff() {
  _setup
  echo new >"$_ws/repo/b.txt"
  _idc "$_ws/repo"
  local ok=1
  [ "$_rc" = 0 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_ignored_file_is_not_a_diff() {
  _setup
  echo noise >"$_ws/repo/ignored.log"
  _idc "$_ws/repo"
  local ok=1
  [ "$_rc" = 4 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_committed_unpushed_is_a_diff() {
  _setup
  echo change >>"$_ws/repo/a.txt"
  git -C "$_ws/repo" commit -q -am change
  _idc "$_ws/repo"
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/log" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_any_repo_with_diff_suppresses_skip() {
  _setup
  git init -q -b develop "$_ws/repo2"
  echo x >"$_ws/repo2/x.txt"
  git -C "$_ws/repo2" add -A
  git -C "$_ws/repo2" commit -q -m base
  echo y >"$_ws/repo2/y.txt"
  _idc "$_ws/repo" "$_ws/repo2"
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/log" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_unresolvable_ref_never_skips() {
  _setup
  _rc=0
  bash "$IDC" --base-ref origin/nope --log-file "$_ws/log" "$_ws/repo" >/dev/null 2>&1 || _rc=$?
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/log" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_not_a_checkout_rc2() {
  _setup
  mkdir "$_ws/plain"
  _idc "$_ws/plain"
  local ok=1
  [ "$_rc" = 2 ] && [ ! -s "$_ws/log" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_usage_rc2() {
  local rc=0
  bash "$IDC" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

test_implement_skill_calls_writer() {
  grep -q 'implement-diff-check.sh' "$PLUGIN_DIR/skills/ticket-implement/SKILL.md"
}

_run "clean worktree writes commit-push|skip (rc 4)" test_clean_worktree_writes_skip
_run "skip line matches pr-review exemption grep" test_skip_line_matches_pr_review_exemption
_run "uncommitted change is a diff" test_uncommitted_change_is_a_diff
_run "untracked file is a diff" test_untracked_file_is_a_diff
_run "gitignored file is not a diff" test_ignored_file_is_not_a_diff
_run "committed-but-unpushed is a diff" test_committed_unpushed_is_a_diff
_run "any repo with a diff suppresses skip" test_any_repo_with_diff_suppresses_skip
_run "unresolvable base ref never skips" test_unresolvable_ref_never_skips
_run "non-checkout path rc 2" test_not_a_checkout_rc2
_run "usage error rc 2" test_usage_rc2
_run "ticket-implement calls the writer" test_implement_skill_calls_writer

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
