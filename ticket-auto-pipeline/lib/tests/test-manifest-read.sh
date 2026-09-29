#!/usr/bin/env bash
# test-manifest-read.sh — unit tests for lib/manifest-read.sh
# Usage: bash test-manifest-read.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/manifest-read.sh"

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

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

_reset() {
  rm -rf "$REPOS_ROOT/.ticket-auto"
  mkdir -p "$REPOS_ROOT/.ticket-auto/initiatives/_index"
  mkdir -p "$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner"
  mkdir -p "$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/epic"
  echo "INIT-1" >"$REPOS_ROOT/.ticket-auto/initiatives/_index/TEST-1.initiative"
}
_reset

# ── get_ticket_manifest_field ────────────────────────────────────────────

echo '{"type":"bug","initiative":"INIT-1","blocked_by":["TEST-0"],"dispatch":false}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"

actual=$(get_ticket_manifest_field TEST-1 type)
[ "$actual" = "bug" ] && _pass "get_ticket_manifest_field: scalar string field" ||
  _fail "get_ticket_manifest_field: scalar string field (got '$actual')"

actual=$(get_ticket_manifest_field TEST-1 dispatch)
[ "$actual" = "false" ] && _pass "get_ticket_manifest_field: explicit false is not coerced to empty" ||
  _fail "get_ticket_manifest_field: explicit false should print 'false' (got '$actual')"

actual=$(get_ticket_manifest_field TEST-1 blocked_by)
[ "$actual" = '["TEST-0"]' ] && _pass "get_ticket_manifest_field: array field round-trips as compact JSON" ||
  _fail "get_ticket_manifest_field: array field (got '$actual')"

rc=0
actual=$(get_ticket_manifest_field TEST-1 outcome_label) || rc=$?
[ "$rc" = "0" ] && [ -z "$actual" ] && _pass "get_ticket_manifest_field: absent field is exit 0 with empty output" ||
  _fail "get_ticket_manifest_field: absent field should be exit 0/empty (rc=$rc, got '$actual')"

# ── missing manifest / malformed JSON — non-silent per spec ──────────────

rc=0
get_ticket_manifest_field NOPE-1 type >/dev/null 2>&1 || rc=$?
[ "$rc" = "1" ] && _pass "get_ticket_manifest_field: missing manifest is exit 1" ||
  _fail "get_ticket_manifest_field: missing manifest should be exit 1 (got $rc)"

echo 'not json' >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
rc=0
get_ticket_manifest_field TEST-1 type >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] && _pass "get_ticket_manifest_field: malformed JSON is exit 2" ||
  _fail "get_ticket_manifest_field: malformed JSON should be exit 2 (got $rc)"
_reset

# ── get_epic_manifest_field ───────────────────────────────────────────────

echo '{"branch":"epic/init-1","uat_policy":"epic","merge_policy":"manual","children":["TEST-1"]}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/epic/manifest.json"

actual=$(get_epic_manifest_field INIT-1 branch)
[ "$actual" = "epic/init-1" ] && _pass "get_epic_manifest_field: scalar field" ||
  _fail "get_epic_manifest_field: scalar field (got '$actual')"

actual=$(get_epic_manifest_field INIT-1 children)
[ "$actual" = '["TEST-1"]' ] && _pass "get_epic_manifest_field: array field" ||
  _fail "get_epic_manifest_field: array field (got '$actual')"

rc=0
get_epic_manifest_field NOPE-EPIC branch >/dev/null 2>&1 || rc=$?
[ "$rc" = "1" ] && _pass "get_epic_manifest_field: missing manifest is exit 1" ||
  _fail "get_epic_manifest_field: missing manifest should be exit 1 (got $rc)"

# ── existence helpers ──────────────────────────────────────────────────────

echo '{"type":"bug"}' >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"

ticket_manifest_exists TEST-1 && _pass "ticket_manifest_exists: true when present" ||
  _fail "ticket_manifest_exists: should be true when present"

rc=0
ticket_manifest_exists NOPE-1 || rc=$?
[ "$rc" != "0" ] && _pass "ticket_manifest_exists: false when absent" ||
  _fail "ticket_manifest_exists: should be false when absent"

epic_manifest_exists INIT-1 && _pass "epic_manifest_exists: true when present" ||
  _fail "epic_manifest_exists: should be true when present"

# ── ticket_is_ready ──────────────────────────────────────────────────────────

_reset
echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"

rc=0
ticket_is_ready TEST-1 || rc=$?
[ "$rc" = "1" ] && _pass "ticket_is_ready: absent ready field reads not ready" ||
  _fail "ticket_is_ready: absent ready field should read not ready (got $rc)"

echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false,"ready":{"status":"ready","missing":[],"advisory":[],"waived":{}}}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
ticket_is_ready TEST-1 && _pass "ticket_is_ready: ready status reads ready" ||
  _fail "ticket_is_ready: ready status should read ready"

echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false,"ready":{"status":"not-ready","missing":["AC_VAGUE"],"advisory":[],"waived":{}}}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
rc=0
ticket_is_ready TEST-1 || rc=$?
[ "$rc" = "1" ] && _pass "ticket_is_ready: not-ready status reads not ready" ||
  _fail "ticket_is_ready: not-ready status should read not ready (got $rc)"

rc=0
ticket_is_ready NOPE-1 >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] && _pass "ticket_is_ready: missing manifest is distinct code" ||
  _fail "ticket_is_ready: missing manifest should be a distinct code from not-ready (got $rc)"

# ── ticket_is_planned ────────────────────────────────────────────────────────

_reset
echo '{"type":null,"initiative":null,"blocked_by":[],"dispatch":false}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
rc=0
ticket_is_planned TEST-1 || rc=$?
[ "$rc" = "1" ] && _pass "ticket_is_planned: _adhoc-shaped (null initiative) manifest is not planned" ||
  _fail "ticket_is_planned: null initiative should not be planned (got $rc)"

echo '{"type":"bug","initiative":"_adhoc","blocked_by":[],"dispatch":false}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
rc=0
ticket_is_planned TEST-1 || rc=$?
[ "$rc" = "1" ] && _pass "ticket_is_planned: literal _adhoc initiative is not planned" ||
  _fail "ticket_is_planned: literal _adhoc initiative should not be planned (got $rc)"

echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
ticket_is_planned TEST-1 && _pass "ticket_is_planned: real initiative is planned" ||
  _fail "ticket_is_planned: real initiative should be planned"

# ── ticket_dispatch_blocked_by_flags ─────────────────────────────────────────

_reset
echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false,"flags":["needs-info"],"ready":{"status":"ready","missing":[],"advisory":[],"waived":{}}}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
ticket_dispatch_blocked_by_flags TEST-1 &&
  _pass "ticket_dispatch_blocked_by_flags: detected even with a stale-ready cached readiness" ||
  _fail "ticket_dispatch_blocked_by_flags: should detect needs-info regardless of cached readiness"

echo '{"type":"bug","initiative":"INIT-1","blocked_by":[],"dispatch":false,"flags":[]}' \
  >"$REPOS_ROOT/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner/manifest.json"
rc=0
ticket_dispatch_blocked_by_flags TEST-1 || rc=$?
[ "$rc" = "1" ] && _pass "ticket_dispatch_blocked_by_flags: absent from empty flags" ||
  _fail "ticket_dispatch_blocked_by_flags: should be absent from empty flags (got $rc)"

_reset

# ── REPOS_ROOT unset ────────────────────────────────────────────────────────

saved_root="$REPOS_ROOT"
unset REPOS_ROOT
rc=0
get_ticket_manifest_field TEST-1 type >/dev/null 2>&1 || rc=$?
[ "$rc" = "3" ] && _pass "get_ticket_manifest_field: REPOS_ROOT unset is exit 3" ||
  _fail "get_ticket_manifest_field: REPOS_ROOT unset should be exit 3 (got $rc)"
export REPOS_ROOT="$saved_root"

# ── invalid ID / path traversal rejected ───────────────────────────────────

rc=0
get_ticket_manifest_field "../../etc" type >/dev/null 2>&1 || rc=$?
[ "$rc" = "3" ] && _pass "get_ticket_manifest_field: traversal in ticket ID rejected" ||
  _fail "get_ticket_manifest_field: traversal in ticket ID should be rejected (got $rc)"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
