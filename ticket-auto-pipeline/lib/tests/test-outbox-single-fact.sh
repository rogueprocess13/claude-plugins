#!/usr/bin/env bash
# test-outbox-single-fact.sh — one fact, one outbox record (GitHub #767).
#
# Runs the real flow.sh, approve.sh, reject.sh and appraise-claim.sh against
# a scratch REPOS_ROOT and counts records in the ticket's outbox:
#   - one appraisal (router claim + ticket-appraise Step 4) → one
#     appraise-started, one complexity-scored
#   - one approval (/ticket-approve run twice) → one human-approved
# and the guards that a legitimate second occurrence still emits (a new
# approval after a reject or a re-hold, a re-appraisal, a corrected score).
#
# Usage: bash test-outbox-single-fact.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$LIB_DIR/.."
# shellcheck source=/dev/null
source "$SCRIPT_DIR/human-pty.sh"
human_pty_init
FLOW_SH_REAL="$PLUGIN_DIR/skills/ticket-flow/flow.sh"
APPROVE_SH="$PLUGIN_DIR/skills/ticket-approve/approve.sh"
REJECT_SH="$PLUGIN_DIR/skills/ticket-reject/reject.sh"
CLAIM_SH="$LIB_DIR/appraise-claim.sh"
TID="TST-1"

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

_root=""
_setup() {
  _root=$(mktemp -d)
  mkdir -p "$_root/logs" "$_root/repos" "$_root/${TID}--test"
  # A person approves a specific plan (lib/plan-binding.sh).
  printf '# Fix\n- [ ] change it\n' >"$_root/${TID}--test/simple-fix.md"
}
_teardown() { rm -rf "$_root"; }

# _run <cmd...> — every script under test sees the same scratch state.
_run() {
  env -u LINEAR_API_KEY -u FLEET_GENERATION -u FLEET_WORKER_PID -u CLAUDE_CODE_SESSION_ID -u TAP_LOG -u FLEET_STATE_DIR \
    FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none \
    CLAUDE_SKILLS_LIB="$LIB_DIR" REPOS_ROOT="$_root/repos" \
    FLEET_PIPELINE_LOG_DIR="$_root/logs" TICKET_FLOW_LOCK_DIR="$_root/logs" \
    LOG_FILE="$_root/logs/${TID}-pipeline.log" \
    FLOW_SH="$FLOW_SH_REAL" FLOW_RUN_FLOW_SH="$FLOW_SH_REAL" \
    "$@"
}
_flow() { _run bash "$FLOW_SH_REAL" "$TID" "$@" >/dev/null 2>&1; }
# A person's decision needs a person: a terminal, and the id typed back
# (lib/tests/human-pty.sh).
_flow_person() { _run python3 "$HUMAN_PTY_DIR/pty_run.py" x bash "$FLOW_SH_REAL" "$TID" "$@" >/dev/null 2>&1; }
_approve() { (cd "$_root" && _run python3 "$HUMAN_PTY_DIR/pty_run.py" "$TID" bash "$APPROVE_SH" "$TID" 2>&1); }
_claim() { _run bash "$CLAIM_SH" "$TID" --complexity "$1" 2>&1; }
# The router's pre-spawn claim (dispatch-table.json STEP_1 pre_dispatch).
_router_claim() { _flow appraise-start --data complexity=simple; }

_count() { # <event> → number of outbox records
  local f="$_root/logs/${TID}-outbox.jsonl"
  [ -f "$f" ] || {
    echo 0
    return 0
  }
  jq -c --arg e "$1" 'select(.event == $e)' "$f" | wc -l | tr -d ' '
}
_field() { # <manifest field>
  jq -r --arg f "$1" '.[$f] // empty' "$_root"/repos/.ticket-auto/initiatives/*/tickets/"$TID"/planner/manifest.json
}

# ── appraise-started ─────────────────────────────────────────────────────────

test_router_appraisal_emits_one_appraise_started() {
  _setup
  _router_claim
  local out
  out=$(_claim complex)
  local started scored complexity
  started=$(_count appraise-started)
  scored=$(_count complexity-scored)
  complexity=$(jq -r 'select(.event == "complexity-scored") | .data.complexity' "$_root/logs/${TID}-outbox.jsonl")
  _teardown
  if [ "$started" = "1" ] && [ "$scored" = "1" ] && [ "$complexity" = "complex" ] &&
    grep -q '^CLAIMED=already$' <<<"$out" && grep -q '^SCORED=emitted$' <<<"$out"; then
    _pass "router claim + Step 4: one appraise-started, one complexity-scored{complex}"
  else
    _fail "router claim + Step 4 (appraise-started=$started complexity-scored=$scored complexity=$complexity out=$out)"
  fi
}

test_standalone_appraisal_claims_once() {
  _setup
  local out
  out=$(_claim complex)
  local started scored stage data
  started=$(_count appraise-started)
  scored=$(_count complexity-scored)
  stage=$(_field stage)
  data=$(jq -r 'select(.event == "appraise-started") | .data.complexity' "$_root/logs/${TID}-outbox.jsonl")
  _teardown
  if [ "$started" = "1" ] && [ "$scored" = "1" ] && [ "$stage" = "Todo" ] && [ "$data" = "complex" ] &&
    grep -q '^CLAIMED=fired$' <<<"$out"; then
    _pass "standalone Step 4: claims (Todo) with one appraise-started, one complexity-scored"
  else
    _fail "standalone Step 4 (appraise-started=$started complexity-scored=$scored stage=$stage data=$data out=$out)"
  fi
}

test_step4_rerun_is_one_score() {
  _setup
  _router_claim
  _claim complex >/dev/null
  _claim complex >/dev/null
  local started scored
  started=$(_count appraise-started)
  scored=$(_count complexity-scored)
  _teardown
  [ "$started" = "1" ] && [ "$scored" = "1" ] &&
    _pass "Step 4 re-run inside one appraisal: still one record each" ||
    _fail "Step 4 re-run (appraise-started=$started complexity-scored=$scored)"
}

# Guard: legitimate repeats still emit.
test_corrected_score_and_reappraisal_emit_again() {
  _setup
  _router_claim
  _claim simple >/dev/null
  _claim complex >/dev/null # the score was corrected: a new fact
  local after_correction
  after_correction=$(_count complexity-scored)
  _flow appraise-complete
  _flow_person human-reject # back to Todo for re-appraisal
  _router_claim             # the router claims the second appraisal
  _claim complex >/dev/null
  local started scored
  started=$(_count appraise-started)
  scored=$(_count complexity-scored)
  _teardown
  [ "$after_correction" = "2" ] && [ "$started" = "2" ] && [ "$scored" = "3" ] &&
    _pass "corrected score and a re-appraisal after reject each emit their own record" ||
    _fail "legit repeats (after_correction=$after_correction appraise-started=$started complexity-scored=$scored)"
}

test_claim_usage_errors() {
  _setup
  local rc1=0 rc2=0 rc3=0
  _run bash "$CLAIM_SH" "$TID" >/dev/null 2>&1 || rc1=$?
  _run bash "$CLAIM_SH" "$TID" --complexity medium >/dev/null 2>&1 || rc2=$?
  _run bash "$CLAIM_SH" --complexity simple >/dev/null 2>&1 || rc3=$?
  local lines
  lines=$(_count appraise-started)
  _teardown
  [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ] && [ "$rc3" -eq 2 ] && [ "$lines" = "0" ] &&
    _pass "appraise-claim.sh: usage errors exit 2 and write nothing" ||
    _fail "appraise-claim.sh usage (rc=$rc1/$rc2/$rc3 records=$lines)"
}

# ── human-approved ───────────────────────────────────────────────────────────

_to_gate() {
  _router_claim
  _flow appraise-complete
}

test_double_approve_emits_one_human_approved() {
  _setup
  _to_gate
  local out1 out2 rc=0
  out1=$(_approve)
  out2=$(_approve) || rc=$?
  local approved rev provenance
  approved=$(_count human-approved)
  provenance=$(_field approval_provenance)
  _teardown
  if [ "$rc" -eq 0 ] && [ "$approved" = "1" ] && [ "$provenance" = "human" ] &&
    grep -q '^already_approved=false$' <<<"$out1" &&
    grep -q '^already_approved=true$' <<<"$out2" && grep -q '^approved=true$' <<<"$out2"; then
    _pass "/ticket-approve twice: one human-approved, second run reports already_approved=true"
  else
    _fail "/ticket-approve twice (human-approved=$approved rc=$rc out2=$out2)"
  fi
}

# Guard: a real second approval — after a reject, and after a re-hold — emits.
test_reapproval_after_reject_and_rehold_emits() {
  _setup
  _to_gate
  _approve >/dev/null
  _run python3 "$HUMAN_PTY_DIR/pty_run.py" "$TID" bash "$REJECT_SH" "$TID" >/dev/null 2>&1
  _to_gate
  _approve >/dev/null
  local after_reject
  after_reject=$(_count human-approved)
  _flow re-claim # gate-reconcile re-hold: clears the approval, stage stays Ready
  _approve >/dev/null
  local after_rehold
  after_rehold=$(_count human-approved)
  _teardown
  [ "$after_reject" = "2" ] && [ "$after_rehold" = "3" ] &&
    _pass "re-approval after a reject and after a re-hold each emit human-approved" ||
    _fail "re-approval (after_reject=$after_reject after_rehold=$after_rehold)"
}

# Guard: a human approving over a policy approval records the new provenance.
test_human_over_policy_still_fires() {
  _setup
  _to_gate
  _flow human-approve --provenance policy
  local out
  out=$(_approve)
  local approved provenance
  approved=$(_count human-approved)
  provenance=$(_field approval_provenance)
  _teardown
  [ "$approved" = "2" ] && [ "$provenance" = "human" ] && grep -q '^already_approved=false$' <<<"$out" &&
    _pass "human /ticket-approve over a policy approval still fires and records human" ||
    _fail "human over policy (human-approved=$approved provenance=$provenance out=$out)"
}

# Guard: the skip never strands a needs-info flag.
test_already_approved_still_clears_needs_info() {
  _setup
  _to_gate
  _approve >/dev/null
  _flow needs-info
  local out
  out=$(_approve)
  local approved flags
  approved=$(_count human-approved)
  flags=$(jq -c '.flags // []' "$_root"/repos/.ticket-auto/initiatives/*/tickets/"$TID"/planner/manifest.json)
  _teardown
  [ "$approved" = "1" ] && [ "$flags" = "[]" ] && grep -q '^needs_info_cleared=true$' <<<"$out" &&
    _pass "already-approved run still clears needs-info" ||
    _fail "already-approved + needs-info (human-approved=$approved flags=$flags out=$out)"
}

# ── vocabulary ───────────────────────────────────────────────────────────────

test_complexity_scored_is_declared_and_projects_nothing() {
  local wf="$PLUGIN_DIR/skills/ticket-flow/workflow.json"
  if jq -e '.vocabulary["complexity-scored"] | (.trigger == null) and (.payload.complexity == "string")' "$wf" >/dev/null &&
    jq -e '.board_drivers.linear.events | has("complexity-scored") and (.["complexity-scored"] == null)' "$wf" >/dev/null; then
    _pass "complexity-scored: declared, trigger-less, explicit null board projection"
  else
    _fail "complexity-scored vocabulary / board_drivers entry"
  fi
}

# ── run ──────────────────────────────────────────────────────────────────────

test_router_appraisal_emits_one_appraise_started
test_standalone_appraisal_claims_once
test_step4_rerun_is_one_score
test_corrected_score_and_reappraisal_emit_again
test_claim_usage_errors
test_double_approve_emits_one_human_approved
test_reapproval_after_reject_and_rehold_emits
test_human_over_policy_still_fires
test_already_approved_still_clears_needs_info
test_complexity_scored_is_declared_and_projects_nothing

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
