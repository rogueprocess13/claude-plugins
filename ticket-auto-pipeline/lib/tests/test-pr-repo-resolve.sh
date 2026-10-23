#!/usr/bin/env bash
# test-pr-repo-resolve.sh — unit tests for lib/pr-repo-resolve.sh plus the
# ticket-pr-iterate regression guard (review finding DET-IP-4: pr-iterate's
# `gh pr list`/`gh pr view` had no --repo, issue #366 again).
# Usage: bash test-pr-repo-resolve.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
PRR="$LIB_DIR/pr-repo-resolve.sh"

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

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

_ws=""
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/root/.ticket-auto/worktrees/T-1" "$_ws/tdir"
  : >"$_ws/log"
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

# _repo <path> <origin-url>
_repo() {
  git init -q "$1"
  git -C "$1" remote add origin "$2"
}

_rc=0
_out=""
_prr() {
  _rc=0
  _out=$(REPOS_ROOT="$_ws/root" bash "$PRR" T-1 --log-file "$_ws/log" --ticket-dir "$_ws/tdir" 2>/dev/null) || _rc=$?
}

test_pr_created_record_wins() {
  _setup
  _repo "$_ws/root/.ticket-auto/worktrees/T-1/app" "git@github.com:other/app.git"
  echo '2026-10-01T00:00:00Z|META|pr-created|info|{"pr":7,"url":"https://github.com/acme/app/pull/7","repo":"acme/app"}' >"$_ws/log"
  _prr
  local ok=1
  [ "$_rc" = 0 ] && [ "$_out" = "acme/app" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_single_worktree_origin() {
  _setup
  _repo "$_ws/root/.ticket-auto/worktrees/T-1/app" "https://github.com/acme/app.git"
  _prr
  local ok=1
  [ "$_rc" = 0 ] && [ "$_out" = "acme/app" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_slug_forms() {
  local url ok=1
  for url in "git@github.com:o/r.git" "https://github.com/o/r" "ssh://git@github.com/o/r.git"; do
    _setup
    _repo "$_ws/root/.ticket-auto/worktrees/T-1/r" "$url"
    _prr
    { [ "$_rc" = 0 ] && [ "$_out" = "o/r" ]; } || ok=0
    _teardown
  done
  [ "$ok" = 1 ]
}

test_two_repos_is_ambiguous() {
  _setup
  _repo "$_ws/root/.ticket-auto/worktrees/T-1/app" "https://github.com/acme/app"
  _repo "$_ws/root/.ticket-auto/worktrees/T-1/api" "https://github.com/acme/api"
  _prr
  local ok=1
  [ "$_rc" = 3 ] && [ -z "$_out" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_notes_checkpoint_fallback() {
  _setup
  _repo "$_ws/elsewhere" "https://github.com/acme/legacy"
  printf '### 2026-10-01 — pre-implementation checkpoint\n- Worktree: %s\n' "$_ws/elsewhere" >"$_ws/tdir/notes.md"
  _prr
  local ok=1
  [ "$_rc" = 0 ] && [ "$_out" = "acme/legacy" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_non_github_remote_unresolvable() {
  _setup
  _repo "$_ws/root/.ticket-auto/worktrees/T-1/app" "https://gitlab.com/acme/app.git"
  _prr
  local ok=1
  [ "$_rc" = 1 ] && [ -z "$_out" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_nothing_unresolvable() {
  _setup
  _prr
  local ok=1
  [ "$_rc" = 1 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_usage_rc2() {
  local rc=0
  bash "$PRR" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

# Regression guard for #366: every `gh pr list` / `gh pr view` command in
# ticket-pr-iterate's bash blocks must carry --repo.
test_pr_iterate_gh_calls_are_repo_scoped() {
  local skill="$PLUGIN_DIR/skills/ticket-pr-iterate/SKILL.md" calls unscoped
  # Only lines inside ```bash fences are commands; prose and JSON strings
  # (e.g. a heartbeat detail naming "gh pr view") are not.
  calls=$(awk '/^```bash/{f=1;next} /^```/{f=0} f' "$skill" |
    grep -E 'gh pr (list|view)' | grep -vF 'command\":' || true)
  [ -n "$calls" ] || return 1
  unscoped=$(echo "$calls" | grep -v -- '--repo' || true)
  [ -z "$unscoped" ] && grep -q 'pr-repo-resolve.sh' "$skill"
}

_run "META|pr-created record wins" test_pr_created_record_wins
_run "single worktree origin" test_single_worktree_origin
_run "https / scp / ssh slug forms" test_slug_forms
_run "worktrees in two repos are ambiguous (rc 3)" test_two_repos_is_ambiguous
_run "notes.md Worktree checkpoint fallback" test_notes_checkpoint_fallback
_run "non-GitHub remote is unresolvable" test_non_github_remote_unresolvable
_run "nothing to go on is unresolvable" test_nothing_unresolvable
_run "usage error rc 2" test_usage_rc2
_run "pr-iterate gh pr calls carry --repo (#366)" test_pr_iterate_gh_calls_are_repo_scoped

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
