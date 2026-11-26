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
  _seed_plan "$(dirname "$repos_root")" "$tid"
}

# _seed_plan <tickets-root> <tid> — the ticket's plan, simple-fix.md in its
# ticket dir: a person approves a specific plan (lib/plan-binding.sh).
_seed_plan() {
  mkdir -p "$1/$2--test"
  [ -f "$1/$2--test/simple-fix.md" ] || printf '# Fix\n- [ ] change it\n' >"$1/$2--test/simple-fix.md"
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
  out=$(cd "$tmpdir" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
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

# ── approve: ad-hoc ticket (the _adhoc manifest flow.sh wrote on its way) ───

test_approve_adhoc_ticket() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib" "$tmpdir/repos"
  local marker="$tmpdir/mutated.marker"
  _stub_lib_dir "$tmpdir/lib" "$marker" state-approve Approve state-ready Ready '[]' '[{"id":"lbl-approved","name":"approved"}]'
  # An ad-hoc ticket held at the gate: flow.sh created its _adhoc manifest.
  (REPOS_ROOT="$tmpdir/repos" && export REPOS_ROOT && source "$LIB_DIR/manifest-write.sh" &&
    ensure_ticket_manifest WIL-1) >/dev/null 2>&1
  _seed_plan "$tmpdir" WIL-1

  local rc=0
  (cd "$tmpdir" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" FLOW_SH="$FLOW_SH_REAL" \
    human_pty WIL-1 bash "$APPROVE_SH" WIL-1) >/dev/null 2>&1 || rc=$?

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
  out=$(cd "$tmpdir" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
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

# ── approve: no manifest under the resolved root is refused (GitHub #818) ────
# A ticket held at the entry gate always has a manifest: flow.sh wrote it on
# the way there. So approve.sh no longer creates one: a missing manifest means
# REPOS_ROOT names the wrong project, and creating a fresh _adhoc manifest
# there recorded the approval where the ticket's own pipeline never looks.
test_approve_refused_without_manifest() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/repos"
  _seed_plan "$tmpdir" NOPE-1

  local rc=0 out
  out=$(cd "$tmpdir" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$LIB_DIR" LOG_FILE="$tmpdir/logs/NOPE-1-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" FLOW_SH="$FLOW_SH_REAL" \
    human_pty NOPE-1 bash "$APPROVE_SH" NOPE-1 2>&1) || rc=$?
  local created=false
  [ ! -e "$tmpdir/repos/.ticket-auto" ] || created=true
  rm -rf "$tmpdir"

  if [ "$rc" -eq 3 ] && [ "$created" = "false" ] && grep -q "no manifest under REPOS_ROOT=" <<<"$out" &&
    ! grep -q "approved=true" <<<"$out"; then
    _pass "approve.sh: a ticket with no manifest under REPOS_ROOT is refused, nothing created"
  else
    _fail "approve.sh: should refuse a ticket with no manifest (rc=$rc created=$created out=$out)"
  fi
}

# ── approve: an exported REPOS_ROOT that disagrees with ./CLAUDE.md (#818) ───
# The person runs the command from project A's tickets root while their shell
# still exports project B's REPOS_ROOT. Both projects hold a manifest for the
# ticket. Nothing may be written to either; both roots are named.
test_approve_refused_on_repos_root_mismatch() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/A/tickets/logs" "$tmpdir/A/repos" "$tmpdir/B/repos"
  _seed_manifest "$tmpdir/A/repos" WIL-1
  _seed_manifest "$tmpdir/B/repos" WIL-1
  _seed_plan "$tmpdir/A/tickets" WIL-1
  printf '# Project A\n\n`REPOS_ROOT` = `%s`\n' "$tmpdir/A/repos" >"$tmpdir/A/tickets/CLAUDE.md"
  local before_a before_b
  before_a=$(cat "$tmpdir/A/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json")
  before_b=$(cat "$tmpdir/B/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json")

  local rc=0 out
  out=$(cd "$tmpdir/A/tickets" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$LIB_DIR" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/A/tickets/logs" REPOS_ROOT="$tmpdir/B/repos" FLOW_SH="$FLOW_SH_REAL" \
    human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  local after_a after_b
  after_a=$(cat "$tmpdir/A/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json")
  after_b=$(cat "$tmpdir/B/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json")
  local a_root="$tmpdir/A/repos" b_root="$tmpdir/B/repos"
  rm -rf "$tmpdir"

  if [ "$rc" -eq 3 ] && [ "$before_a" = "$after_a" ] && [ "$before_b" = "$after_b" ] &&
    grep -qF "environment: $b_root" <<<"$out" && grep -qF "CLAUDE.md: $a_root" <<<"$out" &&
    ! grep -q "approved=true" <<<"$out"; then
    _pass "approve.sh: an exported REPOS_ROOT that disagrees with ./CLAUDE.md is refused, both named"
  else
    _fail "approve.sh: should refuse a REPOS_ROOT mismatch (rc=$rc out=$out)"
  fi
}

# ── approve: a REPOS_ROOT that is not plain text is refused, never shown ─────
# The root and the manifest path are printed beside the prompt; an escape
# sequence in them could rewrite what the person reads (#818 review).
test_approve_refused_on_non_plain_repos_root() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local root="$tmpdir/r"$'\e[2J\e[H'"Approve WIL-1"
  mkdir -p "$root"
  _seed_manifest "$root" WIL-1
  _seed_plan "$tmpdir" WIL-1

  local rc=0 out
  out=$(cd "$tmpdir" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$LIB_DIR" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$root" FLOW_SH="$FLOW_SH_REAL" \
    human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  local approved
  approved=$(jq -r '.approved // empty' "$root/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json" 2>/dev/null)
  rm -rf "$tmpdir"

  if [ "$rc" -eq 3 ] && [ -z "$approved" ] && [[ "$out" != *$'\e'* ]] &&
    grep -q "is not plain text" <<<"$out"; then
    _pass "approve.sh: a REPOS_ROOT holding an escape sequence is refused and never printed"
  else
    _fail "approve.sh: should refuse a non-plain REPOS_ROOT (rc=$rc approved=$approved out=$(cat -v <<<"$out"))"
  fi
}

# ── approve: the prompt names the manifest before the id is typed (#818) ─────
# REPOS_ROOT from ./CLAUDE.md alone (nothing exported), and an exported one
# that names the same directory (trailing slash) is not a mismatch.
test_approve_prompt_names_target_manifest() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/tickets/logs" "$tmpdir/repos"
  _seed_manifest "$tmpdir/repos" WIL-1
  _seed_plan "$tmpdir/tickets" WIL-1
  printf 'REPOS_ROOT = %s\n' "$tmpdir/repos" >"$tmpdir/tickets/CLAUDE.md"
  local manifest="$tmpdir/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json"

  local rc=0 out rc2=0 out2
  out=$(cd "$tmpdir/tickets" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$LIB_DIR" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/tickets/logs" FLOW_SH="$FLOW_SH_REAL" TICKET_TMP_DIR="$tmpdir/scratch" \
    human_pty WIL-1 env -u REPOS_ROOT bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  local approved
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  # Same directory, spelled with a trailing slash: agrees, already approved.
  out2=$(cd "$tmpdir/tickets" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$LIB_DIR" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/tickets/logs" REPOS_ROOT="$tmpdir/repos/" FLOW_SH="$FLOW_SH_REAL" \
    human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc2=$?
  rm -rf "$tmpdir"

  if [ "$rc" -eq 0 ] && [ "$approved" = "true" ] &&
    grep -qF "Recording in: $manifest (REPOS_ROOT from the ./CLAUDE.md)" <<<"$out" &&
    [ "$rc2" -eq 0 ] && grep -q "already_approved=true" <<<"$out2"; then
    _pass "approve.sh: the prompt names the manifest; REPOS_ROOT from ./CLAUDE.md; same dir is no mismatch"
  else
    _fail "approve.sh: prompt should name the target manifest (rc=$rc approved=$approved rc2=$rc2 out=$out out2=$out2)"
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
  out=$(cd "$tmpdir" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
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
  out=$(cd "$tmpdir" && FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$tmpdir/logs/WIL-1-pipeline.log" \
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
# _tenv <tmp> <cmd...> — cmd from the tmp tickets root, in the test env.
_tenv() {
  local t="$1"
  shift
  (cd "$t" && FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none CLAUDE_SKILLS_LIB="$LIB_DIR" \
    LOG_FILE="$t/logs/WIL-1-pipeline.log" FLEET_PIPELINE_LOG_DIR="$t/logs" \
    TICKET_FLOW_LOCK_DIR="$t/logs" REPOS_ROOT="$t/repos" FLOW_SH="$FLOW_SH_REAL" "$@")
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

# ── plan binding (lib/plan-binding.sh) ───────────────────────────────────────

_plan_file() { echo "$1/WIL-1--test/simple-fix.md"; }
_bound_id() { jq -r '.approved_plan.id // empty' "$1/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json" 2>/dev/null; }

test_approve_records_plan_binding() {
  local t out rc=0 files
  t=$(_mk_ticket)
  out=$(_tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  files=$(jq -c '.approved_plan | [.type, (.files | map(.path))]' \
    "$t/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json" 2>/dev/null)
  local id
  id=$(_bound_id "$t")
  if [ "$rc" -eq 0 ] && [ "$files" = '["simple-fix",["simple-fix.md"]]' ] && [[ "$id" =~ ^[0-9a-f]{64}$ ]] &&
    grep -q "Plan: simple-fix ${id:0:12} in .*WIL-1--test, 1 file(s):" <<<"$out" &&
    grep -q '  simple-fix.md (' <<<"$out" && grep -q "plan_id=${id:0:12}" <<<"$out"; then
    _pass "approve.sh: shows the plan's short id and files, records approved_plan with the approval"
  else
    _fail "approve.sh: plan binding not recorded or not shown (rc=$rc files=$files out=$out)"
  fi
  rm -rf "$t"
}

test_approve_refused_without_plan() {
  local t rc=0
  t=$(_mk_ticket)
  rm -rf "$t/WIL-1--test"
  _tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 >"$t/out" 2>&1 || rc=$?
  if [ "$rc" -eq 7 ] && _untouched "$t" && grep -q 'no plan artifact found' "$t/out" &&
    ! grep -q 'anything else aborts' "$t/out"; then
    _pass "approve.sh: no plan artifact is a refusal (exit 7), nothing asked or recorded"
  else
    _fail "approve.sh: approving with no plan must be refused (rc=$rc out=$(cat "$t/out"))"
  fi
  rm -rf "$t"
}

test_approve_refused_for_symlinked_plan() {
  local t rc=0
  t=$(_mk_ticket)
  cp "$(_plan_file "$t")" "$t/copy.md"
  rm "$(_plan_file "$t")"
  ln -s "$t/copy.md" "$(_plan_file "$t")"
  _tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 >"$t/out" 2>&1 || rc=$?
  if [ "$rc" -eq 7 ] && _untouched "$t" && grep -q 'not a regular file' "$t/out"; then
    _pass "approve.sh: a symlinked plan file is refused (exit 7), nothing recorded"
  else
    _fail "approve.sh: a symlinked plan must be refused (rc=$rc out=$(cat "$t/out"))"
  fi
  rm -rf "$t"
}

test_approve_refused_for_non_plain_plan_file_name() {
  local t rc=0
  t=$(_mk_ticket)
  rm -rf "$t/WIL-1--test"
  mkdir -p "$t/openspec/changes/wil-1-fix"
  printf -- '- [ ] task\n' >"$t/openspec/changes/wil-1-fix/tasks.md"
  printf 'x\n' >"$t/openspec/changes/wil-1-fix/"$'evil\033[2Jname.md'
  _tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 >"$t/out" 2>&1 || rc=$?
  if [ "$rc" -eq 7 ] && _untouched "$t" && grep -q 'not plain text' "$t/out" && ! grep -q 'evil' "$t/out"; then
    _pass "approve.sh: a plan file name that is not plain text is refused, never printed"
  else
    _fail "approve.sh: a non-plain plan file name must be refused (rc=$rc out=$(cat -v "$t/out"))"
  fi
  rm -rf "$t"
}

# GitHub #767's shortcut fires nothing only while the recorded binding is the
# plan as it stands; a plan that changed, even by appended bytes, is approved
# again and re-bound.
test_approve_reapprove_rebinds_changed_plan() {
  local t out rc=0 id1 id2 ok=true
  t=$(_mk_ticket)
  _tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 >/dev/null 2>&1 || ok=false
  id1=$(_bound_id "$t")
  # Unchanged: already approved, nothing asked, no second event.
  out=$(_tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'already_approved=true' <<<"$out" && ! grep -q 'anything else aborts' <<<"$out" &&
    [ "$(_events "$t" human-approved)" = "1" ] && [ "$(_bound_id "$t")" = "$id1" ]; } || {
    ok=false
    echo "  unchanged: rc=$rc out=$out"
  }
  # Ticking a checkbox is not a change either.
  sed -i 's/- \[ \] change it/- [x] change it/' "$(_plan_file "$t")"
  rc=0
  out=$(_tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'already_approved=true' <<<"$out"; } || {
    ok=false
    echo "  ticked: rc=$rc out=$out"
  }
  # Appended bytes: a real approval again, new binding.
  printf '\n## Amendment #1\nanswer\n' >>"$(_plan_file "$t")"
  rc=0
  out=$(_tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  id2=$(_bound_id "$t")
  { [ "$rc" -eq 0 ] && grep -q 'already_approved=false' <<<"$out" && grep -q 'anything else aborts' <<<"$out" &&
    [ "$(_events "$t" human-approved)" = "2" ] && [ -n "$id2" ] && [ "$id2" != "$id1" ]; } || {
    ok=false
    echo "  appended: rc=$rc id1=$id1 id2=$id2 out=$out"
  }
  # An approval from before plan binding (no record) is approved again.
  jq 'del(.approved_plan)' "$t/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json" >"$t/m" &&
    mv "$t/m" "$t/repos/.ticket-auto/initiatives/INIT-1/tickets/WIL-1/planner/manifest.json"
  rc=0
  out=$(_tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 2>&1) || rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'already_approved=false' <<<"$out" && [ "$(_bound_id "$t")" = "$id2" ]; } || {
    ok=false
    echo "  legacy: rc=$rc out=$out"
  }
  rm -rf "$t"
  $ok && _pass "approve.sh: the already-approved shortcut holds only for the exact bound plan; a changed or unbound plan is approved again and re-bound" ||
    _fail "approve.sh: re-approval does not follow the plan binding"
}

test_reject_clears_plan_binding() {
  local t rc=0
  t=$(_mk_ticket)
  _tenv "$t" human_pty WIL-1 bash "$APPROVE_SH" WIL-1 >/dev/null 2>&1 || rc=$?
  [ -n "$(_bound_id "$t")" ] || rc=99
  _tenv "$t" human_pty WIL-1 bash "$REJECT_SH" WIL-1 >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$(_bound_id "$t")" ] && [ -z "$(_mf "$t" approved)" ]; then
    _pass "reject.sh: clears approved_plan with the approval"
  else
    _fail "reject.sh: approved_plan must be cleared with the approval (rc=$rc bound=$(_bound_id "$t"))"
  fi
  rm -rf "$t"
}

test_binding_writer_refuses_agents_and_unapproved() {
  local t rc=0 ok=true rec='{"type":"simple-fix","id":"'"$(printf 'a%.0s' {1..64})"'","files":[{"path":"simple-fix.md","size":1,"sha256":"'"$(printf 'b%.0s' {1..64})"'"}]}'
  t=$(_mk_ticket)
  REPOS_ROOT="$t/repos" human_env env CLAUDE_CODE_SESSION_ID=abc bash -c \
    "source '$LIB_DIR/manifest-write.sh'; set_ticket_approved_plan WIL-1 '$rec'" 2>/dev/null || rc=$?
  [ "$rc" -eq 4 ] || ok=false
  rc=0
  REPOS_ROOT="$t/repos" human_env bash -c \
    "source '$LIB_DIR/manifest-write.sh'; set_ticket_approved_plan WIL-1 '$rec'" 2>/dev/null || rc=$?
  [ "$rc" -eq 5 ] || ok=false
  [ -z "$(_bound_id "$t")" ] || ok=false
  rm -rf "$t"
  $ok && _pass "set_ticket_approved_plan: refused in an agent context (4) and with no human approval (5)" ||
    _fail "set_ticket_approved_plan: refusals wrong"
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
test_approve_refused_without_manifest
test_approve_refused_on_repos_root_mismatch
test_approve_prompt_names_target_manifest
test_approve_refused_on_non_plain_repos_root
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
test_approve_records_plan_binding
test_approve_refused_without_plan
test_approve_refused_for_non_plain_plan_file_name
test_approve_refused_for_symlinked_plan
test_approve_reapprove_rebinds_changed_plan
test_reject_clears_plan_binding
test_binding_writer_refuses_agents_and_unapproved
test_operator_text_names_terminal_command

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
