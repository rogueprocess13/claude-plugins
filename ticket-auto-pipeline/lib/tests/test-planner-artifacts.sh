#!/usr/bin/env bash
# test-planner-artifacts.sh — unit tests for lib/planner-artifacts.sh
# Usage: bash test-planner-artifacts.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ───────────────────────────────────────────────────
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() { echo '{"description":"","labels":{"nodes":[]}}'; }
fi
if ! declare -f _plog >/dev/null 2>&1; then _plog() { :; }; fi
if ! declare -f hb_gate >/dev/null 2>&1; then hb_gate() { :; }; fi

export REPOS_ROOT="${REPOS_ROOT:-/tmp/test-repos-root}"

source "$LIB_DIR/planner-artifacts.sh"

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

# Exit-code-safe runner: captures $? via || rc=$? which suppresses errexit
_run_exit() {
  local name="$1" expected="$2" rc=0
  shift 2
  "$@" 2>/dev/null || rc=$?
  if [ "$rc" = "$expected" ]; then
    _pass "$name"
  else
    _fail "$name (expected exit $expected, got $rc)"
  fi
}

# ── Test data ─────────────────────────────────────────────────────────────────

PLANNER_DESC='## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-42
**Epic:** EPIC-1
**Confidence:** 0.92
**Strategy:** Conservative
**Decision:** Refactor collector
**Affected Services:** collector
**Target Symbols:** DebtCollector.collect:src/collector.ts:42
**Pre-approved:** true
**Generated:** 2026-07-01T12:00:00Z
**Regenerate:** false'

NO_INITIATIVE_DESC='## Planner Context
**Schema-Version:** 1
**Confidence:** 0.50'

# ── Setup ─────────────────────────────────────────────────────────────────────

TEST_DIR="$REPOS_ROOT/.ticket-auto/initiatives/INIT-42/tickets/TEST-1/planner"
rm -rf "$REPOS_ROOT/.ticket-auto"
mkdir -p "$TEST_DIR"
touch "$TEST_DIR/body.md"

# ── Tests ─────────────────────────────────────────────────────────────────────
# tracker-planner-and-fallback-cutover (3.3): resolve_planner_dir no longer
# fetches or parses a live description at all — {INIT} resolves from the
# local initiative index alone. Every case below seeds (or deliberately
# omits) an `_index/{TID}.initiative` file rather than relying on an inline
# description/has_planned_label argument, which is now ignored entirely.
_seed_index() {
  local tid="$1" init="$2"
  mkdir -p "$REPOS_ROOT/.ticket-auto/initiatives/_index"
  echo "$init" >"$REPOS_ROOT/.ticket-auto/initiatives/_index/${tid}.initiative"
}

# 1. Present dir → exit 0, correct path (index-resolved, not description-parsed)
_seed_index "TEST-1" "INIT-42"
rc=0
actual=$(resolve_planner_dir "TEST-1" "$PLANNER_DESC" "true" 2>/dev/null) || rc=$?
if [ "$rc" = "0" ] && echo "$actual" | grep -q "INIT-42"; then
  _pass "resolve_planner_dir: present dir → exit 0"
else
  _fail "resolve_planner_dir: expected exit 0 with INIT-42 path, got rc=$rc path='$actual'"
fi

# 2. Index entry present but its directory was never created → exit 1
_seed_index "TEST-2" "INIT-99"
rc=0
actual=$(resolve_planner_dir "TEST-2" "$PLANNER_DESC" "true" 2>/dev/null) || rc=$?
if [ "$rc" = "1" ]; then
  _pass "resolve_planner_dir: missing dir → exit 1"
else
  _fail "resolve_planner_dir: expected exit 1 for missing dir, got rc=$rc"
fi

# 3. No index entry at all → exit 1, reported rather than falling back to a
# live description fetch (the deleted fallback's exit-2 "no Initiative
# field" outcome no longer exists — there is no description parsing left to
# produce it). A description/label argument is passed here specifically to
# prove it changes nothing.
rc=0
actual=$(resolve_planner_dir "TEST-3-NO-INDEX" "$NO_INITIATIVE_DESC" "true" 2>/dev/null) || rc=$?
if [ "$rc" = "1" ]; then
  _pass "resolve_planner_dir: no index entry → exit 1 (reported, no live fetch)"
else
  _fail "resolve_planner_dir: expected exit 1 for no index entry, got rc=$rc"
fi

# 4a. Path traversal in the index file's own content → exit 1 (rejected).
# The traversal-shaped value now has to come from the index itself — an
# inline description's Initiative field is never read.
_seed_index "TEST-TRAV" "../../../etc"
rc=0
actual=$(resolve_planner_dir "TEST-TRAV" 2>/dev/null) || rc=$?
if [ "$rc" = "1" ]; then
  _pass "resolve_planner_dir: path traversal rejected → exit 1"
else
  _fail "resolve_planner_dir: expected exit 1 for path traversal, got rc=$rc"
fi

# 4b. Path traversal in ticket ID → exit 1 (rejected). Seeds a valid
# initiative at the exact path _manifest_initiative_for_ticket resolves to
# for this traversal-shaped ticket ID, so the call reaches (and is caught
# by) resolve_planner_dir's own ticket-ID character validation rather than
# short-circuiting earlier on "no index entry".
mkdir -p "$REPOS_ROOT/.ticket-auto"
echo "INIT-42" >"$REPOS_ROOT/.ticket-auto/etc.initiative"
rc=0
actual=$(resolve_planner_dir "../../etc" 2>/dev/null) || rc=$?
if [ "$rc" = "1" ]; then
  _pass "resolve_planner_dir: path traversal in ticket ID → exit 1"
else
  _fail "resolve_planner_dir: expected exit 1 for ticket ID traversal, got rc=$rc"
fi
rm -f "$REPOS_ROOT/.ticket-auto/etc.initiative"

# 5. has_planner_body true
if has_planner_body "TEST-1" 2>/dev/null; then
  _pass "has_planner_body: true when body.md exists"
else
  _fail "has_planner_body: expected true when body.md exists"
fi

# 6. has_planner_body false
rm -f "$TEST_DIR/body.md"
rc=0
has_planner_body "TEST-1" 2>/dev/null || rc=$?
if [ "$rc" != "0" ]; then
  _pass "has_planner_body: false when body.md missing"
else
  _fail "has_planner_body: expected false when body.md missing"
fi

# 7. has_planner_proposal true
touch "$TEST_DIR/proposal.md"
if has_planner_proposal "TEST-1" 2>/dev/null; then
  _pass "has_planner_proposal: true when proposal.md exists"
else
  _fail "has_planner_proposal: expected true when proposal.md exists"
fi

# 8. Initiative index fast path: no description/label fetch needed when an
#    index entry exists (tracker-local-facts-read-migration, task 1.5).
mkdir -p "$REPOS_ROOT/.ticket-auto/initiatives/_index"
mkdir -p "$REPOS_ROOT/.ticket-auto/initiatives/INIT-77/tickets/TEST-IDX/planner"
echo "INIT-77" >"$REPOS_ROOT/.ticket-auto/initiatives/_index/TEST-IDX.initiative"
rc=0
actual=$(resolve_planner_dir "TEST-IDX" 2>/dev/null) || rc=$?
if [ "$rc" = "0" ] && echo "$actual" | grep -q "INIT-77"; then
  _pass "resolve_planner_dir: index fast path resolves without description/label args"
else
  _fail "resolve_planner_dir: expected index fast path to resolve INIT-77, got rc=$rc path='$actual'"
fi

# 9. Index takes precedence over a stale/mismatched inline description.
rc=0
actual=$(resolve_planner_dir "TEST-IDX" "some unrelated description" "false" 2>/dev/null) || rc=$?
if [ "$rc" = "0" ] && echo "$actual" | grep -q "INIT-77"; then
  _pass "resolve_planner_dir: index takes precedence over inline description/label"
else
  _fail "resolve_planner_dir: expected index to win over inline args, got rc=$rc path='$actual'"
fi

# Cleanup
rm -rf "$REPOS_ROOT/.ticket-auto"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
