#!/usr/bin/env bash
# test-ticket-approve.sh — unit tests for skills/ticket-approve/approve.sh
# and skills/ticket-reject/reject.sh (tracker-approval-by-script).
# Usage: bash test-ticket-approve.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$LIB_DIR/.."
APPROVE_SH="$PLUGIN_DIR/skills/ticket-approve/approve.sh"
REJECT_SH="$PLUGIN_DIR/skills/ticket-reject/reject.sh"
FLOW_SH_REAL="$PLUGIN_DIR/skills/ticket-flow/flow.sh"

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

# ── stub environment builders ────────────────────────────────────────────────

_stub_lib_dir() {
  # $1 dir, $2 marker file, $3 pre-mutation state (id,name), $4 post-mutation
  # state (id,name), $5 pre-mutation labels JSON, $6 post-mutation labels JSON
  local dir="$1" marker="$2"
  local from_id="$3" from_name="$4" to_id="$5" to_name="$6"
  local from_labels="$7" to_labels="$8"
  mkdir -p "$dir"
  cp "$LIB_DIR/heartbeat.sh" "$LIB_DIR/epic-precondition.sh" "$LIB_DIR/manifest-write.sh" "$LIB_DIR/manifest-read.sh" "$dir/"
  cat >"$dir/linear-api.sh" <<STUBEOF
get_issue() {
  if [ -f "$marker" ]; then
    jq -n '{id:"issue-1",identifier:"WIL-1",team:{id:"team-1",name:"Test"},state:{id:"$to_id",name:"$to_name"},labels:{nodes:$to_labels},project:null,parent:null}'
  else
    jq -n '{id:"issue-1",identifier:"WIL-1",team:{id:"team-1",name:"Test"},state:{id:"$from_id",name:"$from_name"},labels:{nodes:$from_labels},project:null,parent:null}'
  fi
}
get_team() {
  jq -n '{states:[{id:"$from_id",name:"$from_name"},{id:"$to_id",name:"$to_name"}],labels:[{id:"lbl-approved",name:"approved"},{id:"lbl-rejected",name:"rejected"},{id:"lbl-pre-approved",name:"pre-approved"}]}'
}
update_issue() {
  touch "$marker"
  jq -n '{success:true,issue:{id:"issue-1",identifier:"WIL-1"}}'
}
get_me() { jq -n '{id:"me-1",name:"Test"}'; }
STUBEOF
}

_seed_manifest() {
  local repos_root="$1" tid="$2" init="${3:-INIT-1}" extra="${4:-}"
  mkdir -p "$repos_root/.ticket-auto/initiatives/_index" \
    "$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner"
  echo "$init" >"$repos_root/.ticket-auto/initiatives/_index/${tid}.initiative"
  local content='{"type":"bug","initiative":"'"$init"'","blocked_by":[],"dispatch":false}'
  [ -n "$extra" ] && content=$(echo "$content" | jq -c ". + $extra")
  echo "$content" >"$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner/manifest.json"
}

# ── approve: planned ticket ──────────────────────────────────────────────────

test_approve_planned_ticket() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib" "$tmpdir/repos"
  local marker="$tmpdir/mutated.marker"
  _stub_lib_dir "$tmpdir/lib" "$marker" state-approve Approve state-ready Ready '[]' '[{"id":"lbl-approved","name":"approved"}]'
  _seed_manifest "$tmpdir/repos" WIL-1

  local out rc=0
  out=$(FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" FLOW_SH="$FLOW_SH_REAL" \
    bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?

  local manifest="$tmpdir/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json"
  local approved stage
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && [ "$approved" = "true" ] && [ "$stage" = "Ready" ] &&
    echo "$out" | grep -q "approved=true" && echo "$out" | grep -q "approval_provenance=human"; then
    _pass "approve.sh: approves a planned ticket, prints manifest fields"
  else
    _fail "approve.sh: should approve a planned ticket (rc=$rc approved=$approved stage=$stage out=$out)"
  fi
}

# ── approve: ad-hoc ticket (no pre-existing manifest) ────────────────────────

test_approve_adhoc_ticket() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib" "$tmpdir/repos"
  local marker="$tmpdir/mutated.marker"
  _stub_lib_dir "$tmpdir/lib" "$marker" state-approve Approve state-ready Ready '[]' '[{"id":"lbl-approved","name":"approved"}]'
  # Deliberately no _seed_manifest call.

  local rc=0
  FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" FLOW_SH="$FLOW_SH_REAL" \
    bash "$APPROVE_SH" WIL-1 >/dev/null 2>&1 || rc=$?

  local init manifest approved
  init=$(cat "$tmpdir/repos/.ticket-auto/initiatives/_index/WIL-1.initiative" 2>/dev/null)
  manifest="$tmpdir/repos/.ticket-auto/initiatives/_adhoc/tickets/WIL-1/planner/manifest.json"
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"

  [ "$rc" -eq 0 ] && [ "$init" = "_adhoc" ] && [ "$approved" = "true" ] &&
    _pass "approve.sh: approves an ad-hoc ticket, does not silently no-op" ||
    _fail "approve.sh: should approve an ad-hoc ticket (rc=$rc init=$init approved=$approved)"
}

# ── reject: clears both fields on a previously approved ticket ──────────────

test_reject_clears_approval() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib" "$tmpdir/repos"
  local marker="$tmpdir/mutated.marker"
  _stub_lib_dir "$tmpdir/lib" "$marker" state-approve Approve state-todo Todo \
    '[{"id":"lbl-pre-approved","name":"pre-approved"}]' '[]'
  _seed_manifest "$tmpdir/repos" WIL-1 INIT-1 '{"approved":true,"approval_provenance":"human","stage":"Ready"}'

  local out rc=0
  out=$(FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" FLOW_SH="$FLOW_SH_REAL" \
    bash "$REJECT_SH" WIL-1 2>&1) || rc=$?

  local manifest="$tmpdir/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json"
  local approved provenance
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  provenance=$(jq -r '.approval_provenance // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && [ -z "$approved" ] && [ -z "$provenance" ] && echo "$out" | grep -q "approved=false"; then
    _pass "reject.sh: clears approved and approval_provenance"
  else
    _fail "reject.sh: should clear both fields (rc=$rc approved=$approved provenance=$provenance out=$out)"
  fi
}

# ── approve: a well-formed ticket ID with no tracker presence still succeeds ──
# tracker-flow-projection-cutover: flow.sh performs no tracker I/O at all, so
# it has no way to learn that a ticket ID has no corresponding Linear issue —
# "A transition succeeds with the tracker unreachable" is the explicit spec
# requirement (flow-local-transitions). This test used to pin the opposite
# (a stubbed get_issue failure propagating to a non-zero approve.sh exit),
# which is now a structurally impossible outcome: nothing in the approve
# path reads the tracker any more. Repurposed to pin the new, correct
# behavior — ensure_ticket_manifest ad-hoc-provisions the ticket and the
# approval succeeds — rather than deleted outright, since "approve an
# untracked ticket ID" is still a real, exercised path (the ad-hoc-manifest
# test below covers the identical shape; this one is kept for the explicit
# non-existent-ticket framing a future reader would otherwise wonder about).
test_approve_well_formed_ticket_with_no_tracker_presence_succeeds() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/repos"

  local rc=0 out
  out=$(FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$LIB_DIR" LOG_FILE="$tmpdir/logs/NOPE-1-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" FLOW_SH="$FLOW_SH_REAL" \
    bash "$APPROVE_SH" NOPE-1 2>&1) || rc=$?
  local manifest="$tmpdir/repos/.ticket-auto/initiatives/_adhoc/tickets/NOPE-1/planner/manifest.json"
  local approved
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && [ "$approved" = "true" ] && echo "$out" | grep -q "approved=true"; then
    _pass "approve.sh: a ticket ID absent from the tracker still approves (ad-hoc manifest)"
  else
    _fail "approve.sh: should ad-hoc-approve regardless of tracker presence (rc=$rc approved=$approved out=$out)"
  fi
}

test_approve_usage_error_on_missing_arg() {
  local rc=0
  bash "$APPROVE_SH" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] &&
    _pass "approve.sh: usage error (exit 1) with no ticket ID" ||
    _fail "approve.sh: should exit 1 with no ticket ID (got rc=$rc)"
}

# ── run ───────────────────────────────────────────────────────────────────────

test_approve_planned_ticket
test_approve_adhoc_ticket
test_reject_clears_approval
test_approve_well_formed_ticket_with_no_tracker_presence_succeeds
test_approve_usage_error_on_missing_arg

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
