#!/usr/bin/env bash
# test-manifest-write.sh — unit tests for lib/manifest-write.sh
# Usage: bash test-manifest-write.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/manifest-write.sh"

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

# ── write_ticket_manifest + initiative index ────────────────────────────────

write_ticket_manifest "TEST-1" "INIT-1" "bug" '["TEST-0"]'
[ "$(get_ticket_manifest_field TEST-1 type)" = "bug" ] && _pass "write_ticket_manifest: type field" ||
  _fail "write_ticket_manifest: type field"
[ "$(get_ticket_manifest_field TEST-1 initiative)" = "INIT-1" ] && _pass "write_ticket_manifest: initiative field" ||
  _fail "write_ticket_manifest: initiative field"
[ "$(get_ticket_manifest_field TEST-1 blocked_by)" = '["TEST-0"]' ] && _pass "write_ticket_manifest: blocked_by field" ||
  _fail "write_ticket_manifest: blocked_by field"
[ "$(get_ticket_manifest_field TEST-1 dispatch)" = "false" ] && _pass "write_ticket_manifest: dispatch starts false" ||
  _fail "write_ticket_manifest: dispatch should start false"
[ -f "$REPOS_ROOT/.ticket-auto/initiatives/_index/TEST-1.initiative" ] && _pass "write_ticket_manifest: initiative index written" ||
  _fail "write_ticket_manifest: initiative index should be written"
[ "$(cat "$REPOS_ROOT/.ticket-auto/initiatives/_index/TEST-1.initiative")" = "INIT-1" ] && _pass "write_ticket_manifest: initiative index content" ||
  _fail "write_ticket_manifest: initiative index content"

rc=0
write_ticket_manifest "TEST-2" "INIT-1" "bug" 'not-an-array' 2>/dev/null || rc=$?
[ "$rc" = "3" ] && _pass "write_ticket_manifest: rejects non-array blocked_by" ||
  _fail "write_ticket_manifest: should reject non-array blocked_by (got $rc)"

# ── write_epic_manifest ─────────────────────────────────────────────────────

write_epic_manifest "INIT-1" "epic/init-1" "epic" "manual" '[]'
[ "$(get_epic_manifest_field INIT-1 branch)" = "epic/init-1" ] && _pass "write_epic_manifest: branch field" ||
  _fail "write_epic_manifest: branch field"
[ "$(get_epic_manifest_field INIT-1 uat_policy)" = "epic" ] && _pass "write_epic_manifest: uat_policy field" ||
  _fail "write_epic_manifest: uat_policy field"
[ "$(get_epic_manifest_field INIT-1 merge_policy)" = "manual" ] && _pass "write_epic_manifest: merge_policy field" ||
  _fail "write_epic_manifest: merge_policy field"

# Refresh without children arg preserves existing children (drift-refresh use case)
add_epic_manifest_child "INIT-1" "TEST-1"
write_epic_manifest "INIT-1" "epic/init-1-renamed" "per-ticket" "on-all-children-done"
children=$(get_epic_manifest_field INIT-1 children)
[ "$(echo "$children" | jq 'length')" = "1" ] && _pass "write_epic_manifest: refresh preserves children when omitted" ||
  _fail "write_epic_manifest: refresh should preserve children (got '$children')"
[ "$(get_epic_manifest_field INIT-1 branch)" = "epic/init-1-renamed" ] && _pass "write_epic_manifest: refresh updates branch" ||
  _fail "write_epic_manifest: refresh should update branch"

# ── add_epic_manifest_child idempotency ─────────────────────────────────────

add_epic_manifest_child "INIT-1" "TEST-1"
add_epic_manifest_child "INIT-1" "TEST-2"
children=$(get_epic_manifest_field INIT-1 children)
[ "$(echo "$children" | jq 'length')" = "2" ] && _pass "add_epic_manifest_child: dedups repeats, adds new" ||
  _fail "add_epic_manifest_child: expected 2 unique children (got '$children')"

rc=0
add_epic_manifest_child "NOPE-EPIC" "TEST-1" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && _pass "add_epic_manifest_child: no-op on missing epic manifest" ||
  _fail "add_epic_manifest_child: should exit 1 on missing manifest (got $rc)"

# ── stamp_ticket_dispatch: one-way ──────────────────────────────────────────

stamp_ticket_dispatch "TEST-1"
[ "$(get_ticket_manifest_field TEST-1 dispatch)" = "true" ] && _pass "stamp_ticket_dispatch: sets true" ||
  _fail "stamp_ticket_dispatch: should set true"

# Directly attempting to revert must not be possible via the public API —
# calling stamp again is idempotent and stays true (there is no "unstamp").
stamp_ticket_dispatch "TEST-1"
[ "$(get_ticket_manifest_field TEST-1 dispatch)" = "true" ] && _pass "stamp_ticket_dispatch: repeat call stays true" ||
  _fail "stamp_ticket_dispatch: repeat call should stay true"

rc=0
stamp_ticket_dispatch "NOPE-1" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && _pass "stamp_ticket_dispatch: no-op on missing manifest" ||
  _fail "stamp_ticket_dispatch: should exit 1 on missing manifest (got $rc)"

# ── stamp_epic_dispatch ──────────────────────────────────────────────────────

stamp_epic_dispatch "INIT-1"
[ "$(get_epic_manifest_field INIT-1 dispatch)" = "true" ] && _pass "stamp_epic_dispatch: sets true" ||
  _fail "stamp_epic_dispatch: should set true"

# ── write_ticket_outcome_label ───────────────────────────────────────────────

write_ticket_outcome_label "TEST-1" "Smooth"
[ "$(get_ticket_manifest_field TEST-1 outcome_label)" = "Smooth" ] && _pass "write_ticket_outcome_label: writes value" ||
  _fail "write_ticket_outcome_label: should write value"

rc=0
write_ticket_outcome_label "TEST-1" "Bogus" 2>/dev/null || rc=$?
[ "$rc" = "3" ] && _pass "write_ticket_outcome_label: rejects invalid value" ||
  _fail "write_ticket_outcome_label: should reject invalid value (got $rc)"

rc=0
write_ticket_outcome_label "NOPE-1" "Smooth" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && _pass "write_ticket_outcome_label: no-op on missing manifest" ||
  _fail "write_ticket_outcome_label: should exit 1 on missing manifest (got $rc)"

# ── set_ticket_approval (tracker-inbound-approval) ───────────────────────────

set_ticket_approval "TEST-1" "true" "human"
[ "$(get_ticket_manifest_field TEST-1 approved)" = "true" ] && _pass "set_ticket_approval: writes approved=true" ||
  _fail "set_ticket_approval: should write approved=true"
[ "$(get_ticket_manifest_field TEST-1 approval_provenance)" = "human" ] && _pass "set_ticket_approval: writes provenance" ||
  _fail "set_ticket_approval: should write approval_provenance"

set_ticket_approval "TEST-1" "true" "policy"
[ "$(get_ticket_manifest_field TEST-1 approval_provenance)" = "policy" ] && _pass "set_ticket_approval: overwrites provenance in place" ||
  _fail "set_ticket_approval: should overwrite provenance"

set_ticket_approval "TEST-1" "false"
cleared=$(get_ticket_manifest_field TEST-1 approved)
prov_after_clear=$(get_ticket_manifest_field TEST-1 approval_provenance)
[ -z "$cleared" ] && _pass "set_ticket_approval: clearing removes approved" ||
  _fail "set_ticket_approval: approved should be absent after clear (got '$cleared')"
[ -z "$prov_after_clear" ] && _pass "set_ticket_approval: clearing removes provenance" ||
  _fail "set_ticket_approval: approval_provenance should be absent after clear (got '$prov_after_clear')"

rc=0
set_ticket_approval "TEST-1" "true" "bogus" 2>/dev/null || rc=$?
[ "$rc" = "3" ] && _pass "set_ticket_approval: rejects invalid provenance" ||
  _fail "set_ticket_approval: should reject invalid provenance (got $rc)"

rc=0
set_ticket_approval "NOPE-1" "true" "human" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && _pass "set_ticket_approval: no-op on missing manifest" ||
  _fail "set_ticket_approval: should exit 1 on missing manifest (got $rc)"

# ── set_ticket_stage / set_epic_stage (tracker-approval-by-script) ──────────

set_ticket_stage "TEST-1" "Ready"
[ "$(get_ticket_manifest_field TEST-1 stage)" = "Ready" ] && _pass "set_ticket_stage: writes stage" ||
  _fail "set_ticket_stage: should write stage"

set_ticket_stage "TEST-1" "Review"
[ "$(get_ticket_manifest_field TEST-1 stage)" = "Review" ] && _pass "set_ticket_stage: overwrites stage in place" ||
  _fail "set_ticket_stage: should overwrite stage"

rc=0
set_ticket_stage "NOPE-1" "Ready" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && _pass "set_ticket_stage: no-op on missing manifest" ||
  _fail "set_ticket_stage: should exit 1 on missing manifest (got $rc)"

set_epic_stage "INIT-1" "Review"
[ "$(get_epic_manifest_field INIT-1 stage)" = "Review" ] && _pass "set_epic_stage: writes stage" ||
  _fail "set_epic_stage: should write stage"

rc=0
set_epic_stage "NOPE-1" "Review" 2>/dev/null || rc=$?
[ "$rc" = "1" ] && _pass "set_epic_stage: no-op on missing manifest" ||
  _fail "set_epic_stage: should exit 1 on missing manifest (got $rc)"

# ── ensure_ticket_manifest (tracker-approval-by-script) ──────────────────────

ensure_ticket_manifest "TEST-1"
[ "$(get_ticket_manifest_field TEST-1 stage)" = "Review" ] && _pass "ensure_ticket_manifest: no-op on an existing manifest" ||
  _fail "ensure_ticket_manifest: should not touch an existing manifest"

ensure_ticket_manifest "ADHOC-1"
[ "$(cat "$REPOS_ROOT/.ticket-auto/initiatives/_index/ADHOC-1.initiative")" = "_adhoc" ] && _pass "ensure_ticket_manifest: reserves _adhoc initiative" ||
  _fail "ensure_ticket_manifest: should reserve _adhoc initiative for a ticket with no index entry"
[ -f "$REPOS_ROOT/.ticket-auto/initiatives/_adhoc/tickets/ADHOC-1/planner/manifest.json" ] && _pass "ensure_ticket_manifest: creates a minimal manifest" ||
  _fail "ensure_ticket_manifest: should create a manifest file"
[ "$(get_ticket_manifest_field ADHOC-1 dispatch)" = "false" ] && _pass "ensure_ticket_manifest: minimal manifest has dispatch=false" ||
  _fail "ensure_ticket_manifest: minimal manifest should have dispatch=false"
[ "$(get_ticket_manifest_field ADHOC-1 type)" = "null" ] && _pass "ensure_ticket_manifest: minimal manifest has type=null" ||
  _fail "ensure_ticket_manifest: minimal manifest should have type=null"

set_ticket_approval "ADHOC-1" "true" "human"
ensure_ticket_manifest "ADHOC-1"
[ "$(get_ticket_manifest_field ADHOC-1 approved)" = "true" ] && _pass "ensure_ticket_manifest: second call on ad-hoc ticket is idempotent" ||
  _fail "ensure_ticket_manifest: second call should not clobber existing fields"

rc=0
ensure_ticket_manifest "" 2>/dev/null || rc=$?
[ "$rc" = "3" ] && _pass "ensure_ticket_manifest: rejects invalid ticket ID" ||
  _fail "ensure_ticket_manifest: should reject invalid ticket ID (got $rc)"

# ── set_ticket_transition / clear_pending_event (tracker-flow-projection-cutover) ──

write_ticket_manifest "TRANS-1" "INIT-1" "bug" '[]'
set_ticket_transition "TRANS-1" "Todo" '["needs-info","needs-adr"]' '{"event":"appraise-start","data":{}}'
[ "$(get_ticket_manifest_field TRANS-1 stage)" = "Todo" ] && _pass "set_ticket_transition: stage written" ||
  _fail "set_ticket_transition: stage should be written"
[ "$(get_ticket_manifest_field TRANS-1 flags)" = '["needs-adr","needs-info"]' ] && _pass "set_ticket_transition: flags sorted on write" ||
  _fail "set_ticket_transition: flags should be sorted"
[ "$(get_ticket_manifest_field TRANS-1 rev)" = "1" ] && _pass "set_ticket_transition: rev starts at 1" ||
  _fail "set_ticket_transition: rev should start at 1"
[ "$(get_ticket_manifest_field TRANS-1 pending_event)" = '{"event":"appraise-start","data":{}}' ] && _pass "set_ticket_transition: pending_event set" ||
  _fail "set_ticket_transition: pending_event should be set"

# all four fields land in one write — assert via a single snapshot read
snapshot=$(cat "$(get_ticket_manifest_path TRANS-1)")
echo "$snapshot" | jq -e '.stage == "Todo" and .flags == ["needs-adr","needs-info"] and .rev == 1 and (.pending_event != null)' >/dev/null 2>&1 &&
  _pass "set_ticket_transition: all four fields land in one snapshot" ||
  _fail "set_ticket_transition: fields should all be visible in one snapshot"

set_ticket_transition "TRANS-1" "Approve" '["needs-info"]'
[ "$(get_ticket_manifest_field TRANS-1 rev)" = "2" ] && _pass "set_ticket_transition: rev increments by exactly one" ||
  _fail "set_ticket_transition: rev should increment by exactly one"
[ -z "$(get_ticket_manifest_field TRANS-1 pending_event)" ] && _pass "set_ticket_transition: empty pending clears the field" ||
  _fail "set_ticket_transition: empty pending_event should clear the field"

clear_pending_event "TRANS-1"
set_ticket_transition "TRANS-1" "Ready" '[]' '{"event":"human-approve","data":{}}'
clear_pending_event "TRANS-1"
[ -z "$(get_ticket_manifest_field TRANS-1 pending_event)" ] && _pass "clear_pending_event: field removed" ||
  _fail "clear_pending_event: pending_event should be removed"

rc=0
set_ticket_transition "NOPE-1" "Todo" '[]' '' 2>/dev/null || rc=$?
[ "$rc" = "1" ] && _pass "set_ticket_transition: no-op on missing manifest" ||
  _fail "set_ticket_transition: should exit 1 on missing manifest (got $rc)"

rc=0
set_ticket_transition "TRANS-1" "Todo" 'not-an-array' '' 2>/dev/null || rc=$?
[ "$rc" = "3" ] && _pass "set_ticket_transition: rejects non-array flags" ||
  _fail "set_ticket_transition: should reject non-array flags (got $rc)"

# An empty stage means "leave stage as it currently is" — a to:null
# trigger on a ticket with no stage yet (or an already-staged ticket) must
# not be forced to invent or clear one.
write_ticket_manifest "TRANS-2" "INIT-1" "bug" '[]'
set_ticket_transition "TRANS-2" "" '[]' ''
[ "$(get_ticket_manifest_field TRANS-2 rev)" = "1" ] && _pass "set_ticket_transition: empty stage still advances rev" ||
  _fail "set_ticket_transition: empty stage should still advance rev"
[ -z "$(get_ticket_manifest_field TRANS-2 stage)" ] && _pass "set_ticket_transition: empty stage leaves stage absent" ||
  _fail "set_ticket_transition: empty stage should leave stage absent when never set"

set_ticket_transition "TRANS-2" "Todo" '[]' ''
set_ticket_transition "TRANS-2" "" '[]' ''
[ "$(get_ticket_manifest_field TRANS-2 stage)" = "Todo" ] && _pass "set_ticket_transition: empty stage preserves an existing value" ||
  _fail "set_ticket_transition: empty stage should preserve an existing value"

# ── epic variants ────────────────────────────────────────────────────────────

write_epic_manifest "TRANS-EPIC" "epic/trans" "epic" "manual" '[]'
set_epic_transition "TRANS-EPIC" "Review" '["reviewed"]' '{"event":"epic-integration-open","data":{}}'
[ "$(get_epic_manifest_field TRANS-EPIC stage)" = "Review" ] && _pass "set_epic_transition: stage written" ||
  _fail "set_epic_transition: stage should be written"
[ "$(get_epic_manifest_field TRANS-EPIC rev)" = "1" ] && _pass "set_epic_transition: rev starts at 1" ||
  _fail "set_epic_transition: rev should start at 1"
[ "$(get_epic_manifest_field TRANS-EPIC pending_event)" = '{"event":"epic-integration-open","data":{}}' ] && _pass "set_epic_transition: pending_event set" ||
  _fail "set_epic_transition: pending_event should be set"

clear_epic_pending_event "TRANS-EPIC"
[ -z "$(get_epic_manifest_field TRANS-EPIC pending_event)" ] && _pass "clear_epic_pending_event: field removed" ||
  _fail "clear_epic_pending_event: pending_event should be removed"

# ── atomic write leaves no .tmp artifacts ────────────────────────────────────

leftover=$(find "$REPOS_ROOT/.ticket-auto" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
[ "$leftover" = "0" ] && _pass "atomic write: no leftover .tmp files" ||
  _fail "atomic write: found $leftover leftover .tmp files"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
