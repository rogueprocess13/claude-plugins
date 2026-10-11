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

# ── ticket_pipeline_merge_state / ticket_pipeline_terminal_done (#412) ─────
# A completed run is only terminal for a dependent once its PR (if any) is
# merged. Each case: seed a pipeline log (+ optional runs.jsonl), then assert
# the state word and the terminal_done exit code together.

MS_WS="$TMP_ROOT/ms-ws"
_ms_reset() {
  rm -rf "$MS_WS"
  mkdir -p "$MS_WS"
}
# _ms_log <tid> <line>... — append pipeline-log lines verbatim
_ms_log() {
  local tid="$1"
  shift
  local l
  for l in "$@"; do echo "$l" >>"$MS_WS/${tid}-pipeline.log"; done
}
_ms_runs() { echo "$1" >>"$MS_WS/runs.jsonl"; }
_MS_PR='2026-01-01T00:00:01Z|META|pr-created|info|{"pr":42,"url":"https://github.com/acme/repo/pull/42","repo":"acme/repo"}'
_MS_DONE='2026-01-01T00:00:09Z|META|outcome|info|completed: STEP_6'
_MS_CTX='2026-01-01T00:00:00Z|META|branch-context|info|base=develop;integration=;source=default;ticket=feat/x;uat-policy=per-ticket;merge-policy='
_MS_SKIP='2026-01-01T00:00:05Z|PR-REVIEW|merge-decision|done|skipped: pipeline autonomy=manual requires human merge'

# _ms_expect <name> <tid> <want_state> <want_rc>
_ms_expect() {
  local name="$1" tid="$2" want_state="$3" want_rc="$4" got rc=0 trc=0
  got=$(ticket_pipeline_merge_state "$tid" "$MS_WS") || rc=$?
  ticket_pipeline_terminal_done "$tid" "$MS_WS" || trc=$?
  if [ "$got" = "$want_state" ] && [ "$rc" = "$want_rc" ] && [ "$trc" = "$want_rc" ]; then
    _pass "merge-aware terminal: $name"
  else
    _fail "merge-aware terminal: $name (state='$got' rc=$rc terminal_done_rc=$trc; want '$want_state' rc=$want_rc)"
  fi
}

_ms_reset
_ms_log T-1 "$_MS_CTX" "$_MS_PR" "$_MS_SKIP" "$_MS_DONE"
_ms_runs '{"kind":"run","tid":"T-1","pr":{"pr":42,"url":null,"repo":"acme/repo"}}'
_ms_runs '{"kind":"merge","tid":"T-1","pr":42,"repo":"acme/repo","state":"open","base":"develop"}'
_ms_expect "completed + PR still open -> blocked" T-1 open 1

_ms_runs '{"kind":"merge","tid":"T-1","pr":42,"repo":"acme/repo","state":"merged","base":"develop"}'
_ms_expect "completed + merge-poll recorded merged (human merged later) -> released" T-1 merged 0

_ms_reset
_ms_log T-2 "$_MS_CTX" "$_MS_PR" "$_MS_SKIP" "$_MS_DONE"
_ms_runs '{"kind":"merge","tid":"T-2","pr":42,"repo":"acme/repo","state":"closed","base":"develop"}'
_ms_expect "completed + PR closed unmerged -> blocked" T-2 closed 1

_ms_reset
_ms_log T-3 "$_MS_CTX" "$_MS_DONE"
_ms_expect "completed + no PR at all (no-code ticket) -> released" T-3 no-pr 0

_ms_reset
_ms_log T-4 "$_MS_CTX" "$_MS_PR" "$_MS_SKIP" "$_MS_DONE"
_ms_expect "completed + PR, no runs.jsonl at all -> unknown, blocked" T-4 unknown 1
_ms_runs 'this is not json'
_ms_runs '{"kind":"merge","tid":"T-4","pr":42,"repo":"acme/repo","state":"stale"}'
_ms_runs '{"kind":"merge","tid":"T-4","pr":42,"repo":null,"state":"unknown-repo"}'
_ms_runs '{"kind":"merge","tid":"T-4","pr":42,"repo":"acme/repo","state":"unknown"}'
_ms_expect "completed + PR, only stale/unknown evidence + a malformed line -> unknown, blocked" T-4 unknown 1
_ms_runs '{"kind":"merge","tid":"OTHER-1","pr":42,"repo":"acme/repo","state":"merged"}'
_ms_runs '{"kind":"merge","tid":"T-4","pr":7,"repo":"acme/repo","state":"merged"}'
_ms_expect "a merged event for another tid or another PR number is not evidence" T-4 unknown 1

_ms_reset
_ms_log T-5 "$_MS_CTX" "$_MS_PR" \
  '2026-01-01T00:00:05Z|PR-REVIEW|merge-decision|done|merged' "$_MS_DONE"
_ms_expect "completed + pipeline merged the PR itself, no poll yet -> released" T-5 merged 0
_ms_runs '{"kind":"merge","tid":"T-5","pr":42,"repo":"acme/repo","state":"open"}'
_ms_expect "a gh 'open' observation outranks the log's own merge claim" T-5 open 1

_ms_reset
_ms_log T-6 "$_MS_CTX" "$_MS_PR" "$_MS_SKIP" "$_MS_DONE" \
  '2026-01-01T00:01:00Z|META|manual-merge|info|PR#42 merged, human-initiated'
_ms_expect "a human META|manual-merge annotation after the PR counts as merged" T-6 merged 0

_ms_reset
_ms_log T-7 "$_MS_CTX" '2026-01-01T00:00:04Z|PR-REVIEW|checkout-pr|done|42' "$_MS_SKIP" "$_MS_DONE"
_ms_expect "a checkout-pr-only reference is still a PR (no evidence -> blocked)" T-7 unknown 1
_ms_runs '{"kind":"merge","tid":"T-7","pr":42,"repo":"acme/repo","state":"merged"}'
_ms_expect "checkout-pr reference + merged event (no base recorded) -> released" T-7 merged 0

# Epic child: the PR's base is the epic branch. Merged into it releases;
# merged anywhere else does not.
_MS_EPIC_CTX='2026-01-01T00:00:00Z|META|branch-context|info|base=epic/foo;integration=epic/foo;source=epic-directive;ticket=feat/y;uat-policy=epic;merge-policy=manual'
_ms_reset
_ms_log T-8 "$_MS_EPIC_CTX" "$_MS_PR" \
  '2026-01-01T00:00:05Z|PR-REVIEW|merge-decision|done|skipped: epic Branch Directive Merge Policy: manual requires human merge' "$_MS_DONE"
_ms_runs '{"kind":"merge","tid":"T-8","pr":42,"repo":"acme/repo","state":"open","base":"epic/foo"}'
_ms_expect "epic child, PR into the epic branch still open -> blocked" T-8 open 1
_ms_runs '{"kind":"merge","tid":"T-8","pr":42,"repo":"acme/repo","state":"merged","base":"epic/foo"}'
_ms_expect "epic child, PR merged into the epic branch -> released" T-8 merged 0
_ms_reset
_ms_log T-9 "$_MS_EPIC_CTX" "$_MS_PR" "$_MS_DONE"
_ms_runs '{"kind":"merge","tid":"T-9","pr":42,"repo":"acme/repo","state":"merged","base":"develop"}'
_ms_expect "epic child, PR merged into a different branch -> blocked" T-9 merged-other-base 1

_ms_reset
_ms_log T-10 "$_MS_CTX" "$_MS_PR" '2026-01-01T00:00:09Z|META|outcome|info|held: gate'
_ms_runs '{"kind":"merge","tid":"T-10","pr":42,"repo":"acme/repo","state":"merged"}'
_ms_expect "a non-completed outcome stays blocked even with a merged PR" T-10 not-complete 1
_ms_expect "no pipeline log at all -> blocked" T-NOLOG not-complete 1

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
