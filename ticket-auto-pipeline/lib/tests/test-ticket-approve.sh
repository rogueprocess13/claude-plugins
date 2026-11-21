#!/usr/bin/env bash
# test-ticket-approve.sh — unit tests for skills/ticket-approve/approve.sh
# and skills/ticket-reject/reject.sh (tracker-approval-by-script).
# Usage: bash test-ticket-approve.sh
# Both are person-only actuators: every positive case runs under a
# pseudo-terminal with the ticket id typed back (lib/tests/human-pty.sh); the
# refusal cases at the end pin what an agent session, a missing terminal and
# a wrong answer do, for the scripts and for flow.sh called directly.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$LIB_DIR/.."
APPROVE_SH="$PLUGIN_DIR/skills/ticket-approve/approve.sh"
REJECT_SH="$PLUGIN_DIR/skills/ticket-reject/reject.sh"
FLOW_SH_REAL="$PLUGIN_DIR/skills/ticket-flow/flow.sh"

# A person runs these scripts at a terminal; so do the tests (human-pty.sh).
# shellcheck source=/dev/null
source "$SCRIPT_DIR/human-pty.sh"
human_pty_init

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
    human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?

  local manifest="$tmpdir/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json"
  local approved stage
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && [ "$approved" = "true" ] && [ "$stage" = "Ready" ] &&
    grep -q "approved=true" <<<"$out" && grep -q "approval_provenance=human" <<<"$out"; then
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
    human_pty WIL-1 bash "$APPROVE_SH" WIL-1 >/dev/null 2>&1 || rc=$?

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
    human_pty WIL-1 bash "$REJECT_SH" WIL-1 2>&1) || rc=$?

  local manifest="$tmpdir/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json"
  local approved provenance
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  provenance=$(jq -r '.approval_provenance // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && [ -z "$approved" ] && [ -z "$provenance" ] && grep -q "approved=false" <<<"$out"; then
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
    human_pty NOPE-1 bash "$APPROVE_SH" NOPE-1 2>&1) || rc=$?
  local manifest="$tmpdir/repos/.ticket-auto/initiatives/_adhoc/tickets/NOPE-1/planner/manifest.json"
  local approved
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && [ "$approved" = "true" ] && grep -q "approved=true" <<<"$out"; then
    _pass "approve.sh: a ticket ID absent from the tracker still approves (ad-hoc manifest)"
  else
    _fail "approve.sh: should ad-hoc-approve regardless of tracker presence (rc=$rc approved=$approved out=$out)"
  fi
}

# ── approve: clears a set needs-info flag (dor-readiness-gate-foundation 6.5) ─

test_approve_clears_needs_info_flag() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib" "$tmpdir/repos"
  local marker="$tmpdir/mutated.marker"
  _stub_lib_dir "$tmpdir/lib" "$marker" state-approve Approve state-ready Ready '[]' '[{"id":"lbl-approved","name":"approved"}]'
  _seed_manifest "$tmpdir/repos" WIL-1 INIT-1 '{"flags":["needs-info"]}'

  local out rc=0
  out=$(FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" FLOW_SH="$FLOW_SH_REAL" \
    human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?

  local manifest="$tmpdir/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json"
  local flags
  flags=$(jq -c '.flags // []' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && [ "$flags" = "[]" ] && grep -q "needs_info_cleared=true" <<<"$out"; then
    _pass "approve.sh: clears a set needs-info flag via needs-info-resolved"
  else
    _fail "approve.sh: should clear needs-info flag (rc=$rc flags=$flags out=$out)"
  fi
}

# ── approve: no-op when needs-info flag is absent ────────────────────────────

test_approve_noop_when_needs_info_absent() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib" "$tmpdir/repos"
  local marker="$tmpdir/mutated.marker"
  _stub_lib_dir "$tmpdir/lib" "$marker" state-approve Approve state-ready Ready '[]' '[{"id":"lbl-approved","name":"approved"}]'
  _seed_manifest "$tmpdir/repos" WIL-1

  local out rc=0
  out=$(FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" FLOW_SH="$FLOW_SH_REAL" \
    human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && grep -q "needs_info_cleared=false" <<<"$out"; then
    _pass "approve.sh: no-op (needs_info_cleared=false) when flag is absent"
  else
    _fail "approve.sh: should report needs_info_cleared=false when flag absent (rc=$rc out=$out)"
  fi
}

test_approve_usage_error_on_missing_arg() {
  local rc=0
  bash "$APPROVE_SH" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] &&
    _pass "approve.sh: usage error (exit 1) with no ticket ID" ||
    _fail "approve.sh: should exit 1 with no ticket ID (got rc=$rc)"
}

# ── person-only: refusals ────────────────────────────────────────────────────

# _mk_ticket — prints a tmp root with a seeded WIL-1 manifest at Approve.
_mk_ticket() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/logs" "$t/repos"
  _seed_manifest "$t/repos" WIL-1 INIT-1 "${1:-{\"stage\":\"Approve\"\}}"
  echo "$t"
}
_tenv() {
  local t="$1"
  shift
  FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" \
    LOG_FILE="$t/logs/WIL-1-pipeline.log" FLEET_PIPELINE_LOG_DIR="$t/logs" \
    TICKET_FLOW_LOCK_DIR="$t/logs" REPOS_ROOT="$t/repos" FLOW_SH="$FLOW_SH_REAL" "$@"
}
_mf() { jq -r --arg f "$2" '.[$f] // empty' "$1/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json" 2>/dev/null; }
_events() {
  local n
  n=$(grep -c "\"event\":\"$2\"" "$1/logs/WIL-1-outbox.jsonl" 2>/dev/null) || n=0
  echo "$n"
}
# _untouched <tmp> — nothing approved, still at Approve, no approval event.
_untouched() {
  [ -z "$(_mf "$1" approved)" ] && [ "$(_mf "$1" stage)" = "Approve" ] &&
    [ "$(_events "$1" human-approved)" = "0" ] && [ "$(_events "$1" human-rejected)" = "0" ]
}

test_approve_refused_in_agent_or_worker_session() {
  local var t rc ok=true
  for var in CLAUDE_CODE_SESSION_ID FLEET_WORKER_PID FLEET_GENERATION; do
    t=$(_mk_ticket)
    rc=0
    # A terminal is present and the right id is typed: the variable alone refuses.
    _tenv "$t" human_pty WIL-1 env "$var=1" bash "$APPROVE_SH" WIL-1 >"$t/out" 2>&1 || rc=$?
    { [ "$rc" -eq 4 ] && _untouched "$t" && grep -q 'agent or fleetd-worker context' "$t/out"; } || {
      ok=false
      echo "  $var: rc=$rc out=$(cat "$t/out")"
    }
    rm -rf "$t"
  done
  $ok && _pass "approve.sh: refused (exit 4) in an agent or fleetd-worker session, nothing recorded" ||
    _fail "approve.sh: an agent or fleetd-worker session must be refused"
}

# setsid drops the controlling terminal a developer's shell may have; the
# right id on stdin must not count.
test_approve_refused_without_terminal() {
  local t rc=0
  t=$(_mk_ticket)
  printf 'WIL-1\n' | _tenv "$t" human_env setsid -w bash "$APPROVE_SH" WIL-1 >"$t/out" 2>&1 || rc=$?
  if [ "$rc" -eq 4 ] && _untouched "$t" && grep -q 'no terminal' "$t/out"; then
    _pass "approve.sh: refused (exit 4) with no terminal, even with the id on stdin"
  else
    _fail "approve.sh: no terminal must be refused (rc=$rc out=$(cat "$t/out"))"
  fi
  rm -rf "$t"
}

test_approve_refused_on_wrong_typed_id() {
  local t rc ok=true answer
  for answer in "WIL-2" "yes" "" "wil-1"; do
    t=$(_mk_ticket)
    rc=0
    _tenv "$t" human_pty "$answer" bash "$APPROVE_SH" WIL-1 >"$t/out" 2>&1 || rc=$?
    { [ "$rc" -eq 6 ] && _untouched "$t"; } || {
      ok=false
      echo "  answer='$answer': rc=$rc out=$(cat "$t/out")"
    }
    rm -rf "$t"
  done
  $ok && _pass "approve.sh: a wrong, empty or generic answer records nothing (exit 6)" ||
    _fail "approve.sh: only the ticket id typed back may approve"
}

test_approve_shows_ticket_and_stage_before_asking() {
  local t out rc=0
  t=$(_mk_ticket)
  out=$(_tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'Approve WIL-1 — current stage: Approve' <<<"$out" &&
    grep -q 'Type WIL-1 to confirm (anything else aborts)' <<<"$out" &&
    [ "$(_mf "$t" approval_provenance)" = "human" ] && [ "$(_events "$t" human-approved)" = "1" ]; then
    _pass "approve.sh: shows the ticket and stage, asks for the id, then records one human approval"
  else
    _fail "approve.sh: prompt or record wrong (rc=$rc out=$out)"
  fi
  rm -rf "$t"
}

test_no_bypass_flag_or_variable() {
  local t rc=0 ok=true f
  t=$(_mk_ticket)
  _tenv "$t" human_env bash "$APPROVE_SH" WIL-1 --yes >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || ok=false
  rc=0
  _tenv "$t" human_env bash "$REJECT_SH" WIL-1 --force >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || ok=false
  _untouched "$t" || ok=false
  rm -rf "$t"
  for f in "$APPROVE_SH" "$REJECT_SH" "$LIB_DIR/human-terminal.sh"; do
    ! grep -qE '(APPROVE|REJECT|HUMAN_TERMINAL)_(SKIP|FORCE|NO_TTY|ASSUME|TEST)|--force|--yes|--no-tty' "$f" || ok=false
  done
  $ok && _pass "approve.sh/reject.sh: no flag or variable skips the terminal check" ||
    _fail "approve.sh/reject.sh: a bypass flag or variable exists"
}

# ── reject: the same refusals ────────────────────────────────────────────────

test_reject_refusals() {
  local t rc ok=true seed='{"approved":true,"approval_provenance":"human","stage":"Ready"}'
  _kept() { [ "$(_mf "$1" approved)" = "true" ] && [ "$(_mf "$1" stage)" = "Ready" ] && [ "$(_events "$1" human-rejected)" = "0" ]; }
  t=$(_mk_ticket "$seed")
  rc=0
  _tenv "$t" human_pty WIL-1 env CLAUDE_CODE_SESSION_ID=abc bash "$REJECT_SH" WIL-1 >/dev/null 2>&1 || rc=$?
  { [ "$rc" -eq 4 ] && _kept "$t"; } || {
    ok=false
    echo "  agent session: rc=$rc"
  }
  rc=0
  printf 'WIL-1\n' | _tenv "$t" human_env setsid -w bash "$REJECT_SH" WIL-1 >/dev/null 2>&1 || rc=$?
  { [ "$rc" -eq 4 ] && _kept "$t"; } || {
    ok=false
    echo "  no terminal: rc=$rc"
  }
  rc=0
  _tenv "$t" human_pty nope bash "$REJECT_SH" WIL-1 >/dev/null 2>&1 || rc=$?
  { [ "$rc" -eq 6 ] && _kept "$t"; } || {
    ok=false
    echo "  wrong id: rc=$rc"
  }
  rm -rf "$t"
  $ok && _pass "reject.sh: refused in an agent session, with no terminal and on a wrong id; approval kept" ||
    _fail "reject.sh: must refuse like approve.sh"
}

# ── flow.sh called directly ──────────────────────────────────────────────────

test_flow_direct_human_triggers_refused_for_agents() {
  local t rc ok=true args
  # human-approve with the provenance named, with none (the default is
  # human), pr-iterate with none, and human-reject.
  for args in "human-approve --provenance human" "human-approve" "pr-iterate" "human-reject"; do
    t=$(_mk_ticket)
    rc=0
    # shellcheck disable=SC2086
    _tenv "$t" human_pty x env CLAUDE_CODE_SESSION_ID=abc bash "$FLOW_SH_REAL" WIL-1 $args >"$t/out" 2>&1 || rc=$?
    { [ "$rc" -eq 15 ] && _untouched "$t" && [ ! -s "$t/logs/WIL-1-pipeline.log" ]; } || {
      ok=false
      echo "  agent session, $args: rc=$rc out=$(cat "$t/out")"
    }
    rc=0
    # shellcheck disable=SC2086
    _tenv "$t" human_env setsid -w bash "$FLOW_SH_REAL" WIL-1 $args >"$t/out" 2>&1 </dev/null || rc=$?
    { [ "$rc" -eq 15 ] && _untouched "$t"; } || {
      ok=false
      echo "  no terminal, $args: rc=$rc out=$(cat "$t/out")"
    }
    rm -rf "$t"
  done
  $ok && _pass "flow.sh: human-approve/pr-iterate (provenance human) and human-reject refused (exit 15) for an agent session and with no terminal" ||
    _fail "flow.sh: a person-only trigger was applied without a person"
}

test_flow_policy_approval_unaffected() {
  local t rc=0
  t=$(_mk_ticket)
  # An agent session with no terminal: what gate-check.sh's auto-approve is.
  _tenv "$t" env CLAUDE_CODE_SESSION_ID=abc FLEET_WORKER_PID=1 setsid -w \
    bash "$FLOW_SH_REAL" WIL-1 human-approve --provenance policy >/dev/null 2>&1 </dev/null || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(_mf "$t" approved)" = "true" ] && [ "$(_mf "$t" approval_provenance)" = "policy" ] &&
    [ "$(_mf "$t" stage)" = "Ready" ] && [ "$(_events "$t" human-approved)" = "1" ]; then
    _pass "flow.sh: a policy approval (the simple-ticket auto-approve) still works from an agent session"
  else
    _fail "flow.sh: policy approval broken (rc=$rc approved=$(_mf "$t" approved) provenance=$(_mf "$t" approval_provenance))"
  fi
  rm -rf "$t"
}

test_flow_invalid_provenance_is_usage_error() {
  local t rc=0
  t=$(_mk_ticket)
  _tenv "$t" bash "$FLOW_SH_REAL" WIL-1 human-approve --provenance operator >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ] && _untouched "$t"; then
    _pass "flow.sh: an unknown provenance is a usage error, nothing applied"
  else
    _fail "flow.sh: unknown provenance (rc=$rc)"
  fi
  rm -rf "$t"
}

test_writer_refuses_human_provenance_for_agents() {
  local t rc=0 ok=true
  t=$(_mk_ticket)
  REPOS_ROOT="$t/repos" human_env env CLAUDE_CODE_SESSION_ID=abc bash -c \
    "source '$LIB_DIR/manifest-write.sh'; set_ticket_approval WIL-1 true human" 2>/dev/null || rc=$?
  { [ "$rc" -eq 4 ] && [ -z "$(_mf "$t" approved)" ]; } || ok=false
  rc=0
  REPOS_ROOT="$t/repos" human_env env FLEET_WORKER_PID=7 bash -c \
    "source '$LIB_DIR/manifest-write.sh'; set_ticket_approval WIL-1 true policy" 2>/dev/null || rc=$?
  { [ "$rc" -eq 0 ] && [ "$(_mf "$t" approval_provenance)" = "policy" ]; } || ok=false
  rm -rf "$t"
  $ok && _pass "set_ticket_approval: human refused (exit 4) in an agent context, policy written" ||
    _fail "set_ticket_approval: provenance refusal wrong (rc=$rc)"
}

# ── operator text names the terminal command ────────────────────────────────
# /ticket-approve and /ticket-reject only print a command, so a message that
# tells a person to "run /ticket-approve <ID>" sends them on a detour. The
# places an operator is told how to approve must name approve.sh itself.
# Each entry: file (repo-relative) | text that must be present.
test_operator_text_names_terminal_command() {
  local repo="$PLUGIN_DIR/.." ok=true entry file want
  local cmd='bash ~/.claude/skills/ticket-approve/approve.sh'
  for entry in \
    "ticket-auto-pipeline/lib/gate-check.sh|$cmd \$TICKET_ID" \
    "ticket-auto-pipeline/lib/manifest-backfill.sh|$cmd <ID>" \
    "ticket-auto-pipeline/skills/ticket-flow/flow.sh|$cmd <ID>" \
    "ticket-auto-pipeline/install.sh|$cmd <ID>" \
    "ticket-auto-pipeline/skills/ticket-auto/SKILL.md|$cmd {TICKET_ID}" \
    "ticket-auto-pipeline/skills/ticket-appraise-exec/SKILL.md|$cmd {TICKET-ID}" \
    "ticket-auto-pipeline/skills/ticket-batch-appraise/SKILL.md|$cmd <ID>" \
    "ticket-auto-pipeline/skills/ticket-gate-reconcile/SKILL.md|$cmd {TICKET-ID}" \
    "ticket-auto-pipeline/README.md|$cmd <id>" \
    "fleet-controller/lib/fleet-notify.sh|$cmd %s" \
    "fleet-controller/README.md|$cmd <ID>" \
    "fleet-controller/features.json|$cmd <ID>" \
    "README.md|$cmd " \
    "docs/ticket-auto-pipeline-diagram.html|$cmd "; do
    file="${entry%%|*}" want="${entry#*|}"
    grep -qF -- "$want" "$repo/$file" 2>/dev/null || {
      echo "    $file does not name: $want"
      ok=false
    }
  done
  # None of them tells a person to run the slash command with a ticket id
  # (the two skills' own Usage blocks and ticket-verify, owned elsewhere,
  # are not operator instructions and are not scanned).
  local hits
  hits=$(cd "$repo" && grep -nE '(run|Run|with|requires|until|via) `?/ticket-(approve|reject)( |`|\.|$)' \
    ticket-auto-pipeline/lib/gate-check.sh ticket-auto-pipeline/lib/manifest-backfill.sh \
    ticket-auto-pipeline/skills/ticket-flow/flow.sh ticket-auto-pipeline/install.sh \
    ticket-auto-pipeline/skills/ticket-auto/SKILL.md ticket-auto-pipeline/skills/ticket-implement/SKILL.md \
    ticket-auto-pipeline/skills/ticket-appraise-exec/SKILL.md ticket-auto-pipeline/skills/ticket-batch-appraise/SKILL.md \
    ticket-auto-pipeline/skills/ticket-gate-reconcile/SKILL.md ticket-auto-pipeline/README.md \
    fleet-controller/lib/fleet-notify.sh fleet-controller/README.md fleet-controller/features.json \
    fleet-controller/CLAUDE.md README.md docs/ticket-auto-pipeline-diagram.html 2>/dev/null) || true
  [ -z "$hits" ] || {
    echo "    still tells a person to run the slash command:"
    echo "$hits" | sed 's/^/      /' | cut -c1-200
    ok=false
  }
  $ok && _pass "operator text names approve.sh as the command to run, not /ticket-approve" ||
    _fail "operator text still points at /ticket-approve"
}

# ── run ───────────────────────────────────────────────────────────────────────

test_approve_planned_ticket
test_approve_adhoc_ticket
test_reject_clears_approval
test_approve_well_formed_ticket_with_no_tracker_presence_succeeds
test_approve_clears_needs_info_flag
test_approve_noop_when_needs_info_absent
test_approve_usage_error_on_missing_arg
test_approve_refused_in_agent_or_worker_session
test_approve_refused_without_terminal
test_approve_refused_on_wrong_typed_id
test_approve_shows_ticket_and_stage_before_asking
test_no_bypass_flag_or_variable
test_reject_refusals
test_flow_direct_human_triggers_refused_for_agents
test_flow_policy_approval_unaffected
test_flow_invalid_provenance_is_usage_error
test_writer_refuses_human_provenance_for_agents
test_operator_text_names_terminal_command

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
