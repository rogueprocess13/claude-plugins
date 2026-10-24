#!/usr/bin/env bash
# test-planner-base-branch.sh — planner-base-branch-config group 2:
# planner_base_branch_resolve's detection order (develop → origin/HEAD → main →
# master) on temporary git repos, the explicit-base check, the failure codes,
# the no-repo-ref default, reuse of a persisted detection, and the
# argument-parsing check/persist pair.
#
# Run: bash ticket-planner/lib/tests/test-planner-base-branch.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck-repo-ref.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "'$3' not in '$2'" ;; esac
}

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# _repo <name> <branch...> — a repo whose local branches are the given names.
_repo() {
  local name="$1" dir="${REPOS_ROOT}/$1" b
  shift
  git init -q -b "$1" "$dir"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  for b in "${@:2}"; do git -C "$dir" branch -q "$b"; done
}

# _origin_head <name> <branch> — origin/HEAD → origin/<branch>, without a remote.
_origin_head() {
  local dir="${REPOS_ROOT}/$1"
  git -C "$dir" update-ref "refs/remotes/origin/$2" HEAD
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$2"
}

# _init <init> <repo...> — a state log with one Discovery repo-ref per repo.
_init() {
  local init="$1" r
  shift
  planner_state_init "$init" "an idea" >/dev/null
  for r in "$@"; do
    planner_state_write "$init" "META" "discovery" "repo-ref" "${r}@HEAD@0000000" >/dev/null
  done
}

_log() { cat "$(planner_state_log "$1")"; }

echo "--- detection order ---"
_repo main-only main
_init INIT-MAIN main-only
assert_eq "main-only repo → main" "$(planner_base_branch_resolve INIT-MAIN)" "main"
assert_contains "detected source line" "$(_log INIT-MAIN)" "|META|base-branch-source|done|detected:main-only=main"
assert_eq "detection persisted as base-branch" "$(planner_config_get INIT-MAIN base-branch)" "main"
assert_eq "second call reuses the persisted value" "$(planner_base_branch_resolve INIT-MAIN)" "main"
assert_eq "second call writes no second source line" \
  "$(_log INIT-MAIN | grep -c '|META|base-branch-source|done|')" "1"

_repo dev-and-main main develop
_origin_head dev-and-main main
_init INIT-DEV dev-and-main
assert_eq "develop beats origin/HEAD=main" "$(planner_base_branch_resolve INIT-DEV)" "develop"

_repo head-only trunk
_origin_head head-only trunk
_init INIT-HEAD head-only
assert_eq "origin/HEAD target when no develop" "$(planner_base_branch_resolve INIT-HEAD)" "trunk"

_repo master-only master
_init INIT-MASTER master-only
assert_eq "master last" "$(planner_base_branch_resolve INIT-MASTER)" "master"

_repo remote-develop main
git -C "${REPOS_ROOT}/remote-develop" update-ref refs/remotes/origin/develop HEAD
_init INIT-RDEV remote-develop
assert_eq "origin/develop counts" "$(planner_base_branch_resolve INIT-RDEV)" "develop"

echo "--- failures ---"
_init INIT-AMB dev-and-main main-only
out=$(planner_base_branch_resolve INIT-AMB 2>&1)
rc=$?
assert_eq "disagreeing repos → rc 1" "$rc" "1"
assert_contains "ambiguous names each repo" "$out" "BASE_BRANCH_AMBIGUOUS: pinned repos disagree on the base branch (dev-and-main=develop,main-only=main)"
assert_contains "ambiguous names the fix" "$out" "--base-branch"
assert_contains "ambiguous fail line" "$(_log INIT-AMB)" "|META|base-branch-source|fail|BASE_BRANCH_AMBIGUOUS"
assert_eq "nothing persisted on failure" "$(planner_config_get INIT-AMB base-branch)" ""

_repo odd-only feature-x
_init INIT-NONE odd-only
out=$(planner_base_branch_resolve INIT-NONE 2>&1)
assert_eq "no candidate branch → rc 1" "$?" "1"
assert_contains "unresolved code" "$out" "BASE_BRANCH_UNRESOLVED: no base branch for odd-only=none"

_init INIT-GONE missing-repo
out=$(planner_base_branch_resolve INIT-GONE 2>&1)
assert_eq "pinned repo with no checkout → rc 1" "$?" "1"
assert_contains "no-checkout named" "$out" "missing-repo=no-checkout"

echo "--- explicit ---"
_init INIT-EXP main-only dev-and-main
planner_config_set INIT-EXP base-branch main >/dev/null
assert_eq "explicit present in every repo" "$(planner_base_branch_resolve INIT-EXP)" "main"
assert_eq "explicit writes no source line" "$(_log INIT-EXP | grep -c 'base-branch-source')" "0"

_init INIT-EXPM main-only
planner_config_set INIT-EXPM base-branch release >/dev/null
out=$(planner_base_branch_resolve INIT-EXPM 2>&1)
assert_eq "explicit missing → rc 1" "$?" "1"
assert_contains "explicit missing names the repo" "$out" "BASE_BRANCH_UNRESOLVED: no base branch for main-only=no-release"

_init INIT-EXPBAD main-only
planner_config_set INIT-EXPBAD base-branch 'x"; rm -rf /' >/dev/null
out=$(planner_base_branch_resolve INIT-EXPBAD 2>&1)
assert_eq "unsafe explicit → rc 1" "$?" "1"
assert_contains "unsafe explicit code" "$out" "BASE_BRANCH_INVALID"

echo "--- no repo-refs ---"
_init INIT-NOREF
assert_eq "no repo-ref → develop" "$(planner_base_branch_resolve INIT-NOREF)" "develop"
assert_contains "default source line" "$(_log INIT-NOREF)" "|META|base-branch-source|done|default"
assert_eq "default is not persisted as config" "$(planner_config_get INIT-NOREF base-branch)" ""

echo "--- name validation ---"
for good in main develop release/1.2 feat_x-y; do
  planner_base_branch_name_valid "$good" && pass "valid: $good" || fail "valid: $good" "rejected"
done
for bad in "" -main 'a b' 'a$b' "a'b" 'a`b' a..b a/ a.lock; do
  planner_base_branch_name_valid "$bad" && fail "invalid: '$bad'" "accepted" || pass "invalid: '$bad'"
done

echo "--- argument parsing check/persist ---"
planner_directive_config_check "main" && pass "check accepts a plain base" || fail "check accepts a plain base" "rc $?"
planner_directive_config_check "a b" 2>/dev/null && fail "check rejects a bad base" "rc 0" || pass "check rejects a bad base"
PLANNER_MERGE_POLICY=sometimes planner_directive_config_check "" 2>/dev/null &&
  fail "check rejects a bad merge policy" "rc 0" || pass "check rejects a bad merge policy"
PLANNER_SYNC_POLICY=always planner_directive_config_check "" 2>/dev/null &&
  fail "check rejects a bad sync policy" "rc 0" || pass "check rejects a bad sync policy"

_init INIT-PERSIST
PLANNER_MERGE_POLICY=on-all-children-done PLANNER_SYNC_POLICY=none \
  planner_directive_config_persist INIT-PERSIST release >/dev/null
assert_eq "persist base" "$(planner_config_get INIT-PERSIST base-branch)" "release"
assert_eq "persist merge" "$(planner_config_get INIT-PERSIST merge-policy)" "on-all-children-done"
assert_eq "persist sync none as no-sync (none is the clear marker)" "$(planner_config_get INIT-PERSIST sync-policy)" "no-sync"
_init INIT-EMPTY
env -u PLANNER_MERGE_POLICY -u PLANNER_SYNC_POLICY bash -c \
  'source "$1/planner-crosscheck-repo-ref.sh"; planner_directive_config_persist INIT-EMPTY ""' _ "$LIB_DIR"
assert_eq "empty values write nothing" \
  "$(_log INIT-EMPTY | grep -cE '\|META\|(base-branch|merge-policy|sync-policy)\|')" "0"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
