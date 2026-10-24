#!/usr/bin/env bash
# test-planner-uat-policy.sh — planner-ac-coverage-and-epic-uat group 1:
# planner_uat_policy_resolve's order (explicit → not shared → TD spec → sibling
# edge → none), sibling-only edges (external ids and unresolved tokens do not
# count), and that the explicit check never reads REPOS_ROOT.
#
# Run: bash ticket-planner/lib/tests/test-planner-uat-policy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-deps-check.sh"

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

# _spec <init> <slug> [labels]
_spec() {
  local d="${REPOS_ROOT}/.ticket-auto/initiatives/$1/artifacts/specs"
  mkdir -p "$d"
  printf '# %s\n\n## Labels\n\nfeature%s\n' "$2" "${3:+, $3}" >"${d}/$2.md"
}

echo "--- explicit, before REPOS_ROOT ---"
got=$(env -u REPOS_ROOT bash -c 'source "$1/planner-state.sh"; source "$1/planner-deps-check.sh"
  planner_uat_policy_resolve INIT-X true per-ticket' _ "$LIB_DIR")
assert_eq "explicit wins with REPOS_ROOT unset" "$got" $'per-ticket\texplicit'

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

echo "--- not shared ---"
_spec INIT-NS a-one
_spec INIT-NS b-two "blocked-by:a-one"
assert_eq "chain without a shared branch → empty" "$(planner_uat_policy_resolve INIT-NS false "")" $'\tnot-shared'

echo "--- chain ---"
_spec INIT-CH a-store
_spec INIT-CH b-auth "blocked-by:a-store"
_spec INIT-CH c-articles "blocked-by:b-auth"
assert_eq "sibling chain → epic" "$(planner_uat_policy_resolve INIT-CH true "")" $'epic\tchain'
assert_eq "explicit per-ticket beats a chain" "$(planner_uat_policy_resolve INIT-CH true per-ticket)" $'per-ticket\texplicit'

_spec INIT-PF a-store
_spec INIT-PF b-auth "blocked-by:a"
assert_eq "short-form sibling prefix counts" "$(planner_uat_policy_resolve INIT-PF true "")" $'epic\tchain'

echo "--- flat, external, unresolved ---"
_spec INIT-FLAT a-one
_spec INIT-FLAT b-two
_spec INIT-FLAT c-three
assert_eq "flat set under --shared-branch → none" "$(planner_uat_policy_resolve INIT-FLAT true "")" $'\tnone'

_spec INIT-EXT a-one "blocked-by:WIL-83"
_spec INIT-EXT b-two
assert_eq "external prerequisite only → none" "$(planner_uat_policy_resolve INIT-EXT true "")" $'\tnone'

_spec INIT-UNR a-one "blocked-by:nothing-here"
_spec INIT-UNR b-two
assert_eq "unresolved token only → none" "$(planner_uat_policy_resolve INIT-UNR true "")" $'\tnone'

assert_eq "no specs dir → none" "$(planner_uat_policy_resolve INIT-EMPTY true "")" $'\tnone'

echo "--- TD spec ---"
_spec INIT-TD a-one
mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/INIT-TD/artifacts"
echo '{"version":1,"td_specs":[{"slug":"a-one-test-data","kind":"single"}],"overrides":[],"edges":[]}' \
  >"${REPOS_ROOT}/.ticket-auto/initiatives/INIT-TD/artifacts/testdata-synth.json"
assert_eq "TD spec → epic (td-spec)" "$(planner_uat_policy_resolve INIT-TD true "")" $'epic\ttd-spec'

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
