#!/usr/bin/env bash
# test-gate-check.sh — unit tests for lib/gate-check.sh
# Usage: bash test-gate-check.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# ── Mock framework ──────────────────────────────────────────────────────────────

_ws=""       # workspace dir
_tid=""      # ticket ID
_flow_log="" # tracks flow.sh calls
_fake_issue='{"id":"CRE-47","identifier":"CRE-47","title":"Test","labels":{"nodes":[]}}'
_fake_complexity="simple"

_setup() {
  _ws=$(mktemp -d)
  _tid="CRE-47"
  _flow_log="${_ws}/flow-calls.log"
  touch "$_flow_log"
  _fake_issue='{"id":"CRE-47","identifier":"CRE-47","title":"Test","labels":{"nodes":[]}}'
  _fake_complexity="simple"
  _fake_manifest_exists_override=""

  LOG_FILE="${_ws}/${_tid}-pipeline.log"
  HB_LOG_FILE="${_ws}/${_tid}-heartbeat.log"
  TICKET_ID="$_tid"

  # Reset mocked functions after sourcing
  _install_mocks
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# ── Scaffold pipeline log ──────────────────────────────────────────────────────

_plog_raw() {
  local phase="$1" step="$2" status="$3" msg="$4"
  local iso="${5:-2026-06-05T10:00:00Z}"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"$LOG_FILE"
}

# ── Mock overrides (installed AFTER sourcing gate-check.sh) ─────────────────────

_install_mocks() {
  # Override get_issue to return configured fake response
  get_issue() { echo "$_fake_issue"; }

  # Override get_complexity to return configured fake value
  get_complexity() { echo "$_fake_complexity"; }

  # Override flow.sh resolution — never find real flow.sh
  _resolve_flow_sh() { echo "${_ws}/mock-flow.sh"; }
  FLOW_SH="${_ws}/mock-flow.sh"

  # Create a stub flow.sh that records calls
  cat >"${_ws}/mock-flow.sh" <<FLOWEOF
#!/usr/bin/env bash
echo "flow-sh-called|\$*" >> "${_ws}/flow-calls.log"
exit 0
FLOWEOF
  chmod +x "${_ws}/mock-flow.sh"

  # Override resolve_ticket_dir
  resolve_ticket_dir() { echo "${_ws}/${1}--test"; }

  # Override emit_event to record calls instead of writing real outbox
  # files (tracker-inbound-approval) — gate-check.sh sources the real
  # events.sh, so without this override _gate_emit_held/_gate_emit_released
  # would attempt genuine outbox writes under FLEET_PIPELINE_LOG_DIR.
  emit_event() {
    echo "emit_event|$1|$2|$3" >>"${_ws}/emit-calls.log"
  }
}

# Scaffold default context.md and notes.md so checks 2.5a (ZERO_AC) and
# 2.5b (BUG_NO_REPRO) get sane defaults. Specific tests override these
# via _scaffold_context_md / _scaffold_critique after calling this helper.
_scaffold_default_ticket_files() {
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true

  # Default context.md: 2 ACs, feature label, has repro steps
  cat >"${td}/context.md" <<'CTXEOF'
# Test Ticket

**Labels:** feature

## Description
1. Test acceptance criterion 1
2. Test acceptance criterion 2

## Steps to Reproduce
1. Go to /handover/
2. Click Send button
3. See error message
CTXEOF

  # Default notes.md: complexity only, no critique section
  cat >"${td}/notes.md" <<'NOTESEOF'
## Complexity
**Score:** simple
NOTESEOF
}

# Scaffold exec-done pipeline log with configurable params
_scaffold_exec_done() {
  local complexity="${1:-simple}"
  local autonomy="${2:-auto}"
  local artifact_type="${3:-simple-fix}"
  local artifact_path="${4:-${_ws}/simple-fix.md}"

  _fake_complexity="$complexity"

  # Schema header
  _plog_raw "META" "schema" "info" "1"
  # Title
  _plog_raw "META" "title" "info" "ID:${_tid} -- Test Ticket"
  # Autonomy
  _plog_raw "META" "autonomy" "info" "${autonomy}"
  # Appraise done
  _plog_raw "APPRAISE" "appraise" "done" "complexity=${complexity}"
  # Artifact path
  if [ -n "$artifact_path" ]; then
    _plog_raw "META" "artifact" "info" "plan:${artifact_path}"
  fi
  # Exec done with artifact type (canonical EXEC|create-artifact|done| token)
  _plog_raw "EXEC" "create-artifact" "done" "${artifact_type}"

  # Create artifact file if path is set and not "none"
  if [ -n "$artifact_path" ] && [ "$artifact_path" != "none" ]; then
    mkdir -p "$(dirname "$artifact_path")" 2>/dev/null || true
    touch "$artifact_path" 2>/dev/null || true
  fi

  # Default ticket files for structural gate checks (2.5a, 2.5b)
  _scaffold_default_ticket_files
}

# Like _scaffold_exec_done but omits META|artifact|info|plan: and writes
# EXEC|create-artifact|done| instead of EXEC|exec|done| — matching the actual
# ticket-appraise-exec log format. Exercises the fallback path in _get_artifact_path.
_scaffold_no_meta_artifact() {
  local complexity="${1:-simple}"
  local autonomy="${2:-auto}"
  local artifact_type="${3:-simple-fix}"

  _fake_complexity="$complexity"

  _plog_raw "META" "schema" "info" "1"
  _plog_raw "META" "title" "info" "ID:${_tid} -- Test Ticket"
  _plog_raw "META" "autonomy" "info" "${autonomy}"
  _plog_raw "APPRAISE" "appraise" "done" "complexity=${complexity}"
  # No META|artifact|info|plan: — forces fallback to EXEC|create-artifact|done|
  _plog_raw "EXEC" "create-artifact" "done" "${artifact_type}"

  # Default ticket files for structural gate checks (2.5a, 2.5b)
  _scaffold_default_ticket_files
}

# ── Source gate-check.sh (its main is guarded, functions load into this shell) ──

# Ensure gate-check.sh sources its dependencies from the local dev lib,
# not from ~/.claude/skills/lib (which may lack newer functions).
export CLAUDE_SKILLS_LIB="$LIB_DIR"

source "$LIB_DIR/gate-check.sh"
source "$LIB_DIR/manifest-write.sh"

# Captured once, before any test-local override — used by the "stale
# manifest" guard tests below to force Check 2.7's planned-ticket branch
# onto its live-label path (no "planned" label in _fake_issue) while
# get_ticket_manifest_field/set_ticket_approval still read/write the real
# manifest file underneath. Only Check 2.7 (gate-check.sh:619,642) ever
# calls ticket_manifest_exists, so this override is scoped to exactly the
# behavior those tests need to bypass.
eval "$(declare -f ticket_manifest_exists | sed '1s/^ticket_manifest_exists ()/_real_ticket_manifest_exists()/')"
_fake_manifest_exists_override=""
ticket_manifest_exists() {
  [ "$_fake_manifest_exists_override" = "false" ] && return 1
  _real_ticket_manifest_exists "$@"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Entry mode tests (core: 12, Check 2.5: 5, Check 2.5a: 2, Check 2.5b: 3,
# Check 2.6: 7, Cross-val: 4, Tightened regex: 2)
# ═══════════════════════════════════════════════════════════════════════════════

# 1. Artifact file missing → gate-stop EXEC_NO_ARTIFACT (exit 2)
test_entry_artifact_missing_gate_stop() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/nonexistent.md"
  # Remove the scaffolded file (scaffolding creates it)
  rm -f "${_ws}/nonexistent.md" 2>/dev/null || true

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
}

# 2. Complexity mismatch (complex complexity + simple-fix artifact) → gate-stop
test_entry_complexity_artifact_mismatch() {
  _setup
  _scaffold_exec_done "complex" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'COMPLEXITY_ARTIFACT_MISMATCH' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected COMPLEXITY_ARTIFACT_MISMATCH gate-stop in log"
    return 1
  }
}

# 3. Simple + auto mode → calls flow.sh human-approve (exit 0)
test_entry_simple_auto_calls_flow_human_approve() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local flow_calls
  flow_calls=$(cat "$_flow_log" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$flow_calls" | grep -q "human-approve" || {
    echo "flow.sh human-approve not called"
    return 1
  }
}

# 4. Simple + semi-auto mode → calls flow.sh human-approve (exit 0)
test_entry_simple_semi_auto_calls_flow_human_approve() {
  _setup
  _scaffold_exec_done "simple" "semi-auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local flow_calls
  flow_calls=$(cat "$_flow_log" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$flow_calls" | grep -q "human-approve" || {
    echo "flow.sh human-approve not called"
    return 1
  }
}

# 5. Simple + manual → held (exit 1)
test_entry_simple_manual_held() {
  _setup
  _scaffold_exec_done "simple" "manual" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1, got $rc"
    return 1
  }
}

# 6. Complex → held regardless of autonomy (exit 1)
test_entry_complex_held() {
  _setup
  _scaffold_exec_done "complex" "auto" "openspec" "${_ws}/openspec-change.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1, got $rc"
    return 1
  }
}

# 7. Gate start event written
test_entry_gate_start_event_written() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry

  local has_start
  has_start=$(grep -c '|GATE|gate|start|' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "${has_start:-0}" -ge 1 ] || {
    echo "gate start event not found"
    return 1
  }
}

# 8. Autonomy from pipeline log (crash recovery — detects auto correctly)
test_entry_autonomy_from_log() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 for auto mode, got $rc"
    return 1
  }
}

# 9. Complexity from notes.md
test_entry_complexity_from_notes() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 for simple, got $rc"
    return 1
  }
}

# 10. Artifact path from log
test_entry_artifact_path_from_log() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  # Artifact file exists → check passes
  [ -f "${_ws}/simple-fix.md" ] || {
    echo "artifact file not scaffolded"
    _teardown
    return 1
  }

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
}

# 10b. Artifact path fallback — only EXEC|create-artifact|done|, no META|artifact
test_entry_artifact_path_fallback_from_create_artifact() {
  _setup
  # Scaffold WITHOUT the META|artifact entry — only EXEC|create-artifact|done|
  _scaffold_no_meta_artifact "simple" "auto" "simple-fix"

  # Create the artifact file at the ticket dir path that resolve_ticket_dir returns
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  touch "$td/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
}

# 11. Fleet-detect format: held log entry matches |GATE|gate|fail|held:
test_entry_fleet_detect_format() {
  _setup
  _scaffold_exec_done "complex" "auto" "openspec" "${_ws}/openspec-change.md"

  _gate_entry

  local held_line
  held_line=$(grep '|GATE|gate|fail|held:' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ -n "$held_line" ] || {
    echo "no gate-held line with held: prefix"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Reapprove mode tests (4)
# ═══════════════════════════════════════════════════════════════════════════════

# 12. Manifest approved=true + stage=Ready → passes (exit 0). No live
# tracker read at all (tracker-approval-by-script) — _fake_issue is
# deliberately left at its "not approved" default to prove that.
test_reapprove_approved_and_ready_passes() {
  _setup
  local repos_root
  repos_root=$(mktemp -d)
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_approval "$_tid" "true" "human" >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_stage "$_tid" "Ready" >/dev/null

  REPOS_ROOT="$repos_root" _gate_reapprove
  local rc=$?

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
}

# 13. Manifest exists but approved is absent → APPROVAL_REVOKED (exit 2)
test_reapprove_label_missing_gate_stop() {
  _setup
  local repos_root
  repos_root=$(mktemp -d)
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_stage "$_tid" "Ready" >/dev/null

  REPOS_ROOT="$repos_root" _gate_reapprove
  local rc=$?

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
}

# 14. Manifest approved=true but wrong stage → APPROVAL_REVOKED (exit 2)
test_reapprove_wrong_state_gate_stop() {
  _setup
  local repos_root
  repos_root=$(mktemp -d)
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_approval "$_tid" "true" "human" >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_stage "$_tid" "In Progress" >/dev/null

  REPOS_ROOT="$repos_root" _gate_reapprove
  local rc=$?

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
}

# 15. Both approved-absent and no stage — single gate-stop entry
test_reapprove_both_wrong_single_gate_stop() {
  _setup
  local repos_root
  repos_root=$(mktemp -d)
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null

  REPOS_ROOT="$repos_root" _gate_reapprove
  local rc=$?

  local gate_stop_count
  gate_stop_count=$(grep -c 'APPROVAL_REVOKED' "$LOG_FILE" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
  [ "${gate_stop_count:-0}" -eq 1 ] || {
    echo "expected 1 APPROVAL_REVOKED, got ${gate_stop_count:-0}"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Verification plan extraction tests (Check 2.6) — exercises the new
# ## Verification Plan → per-criterion table → fallback chain
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: scaffold notes.md with critique section (unlocks Check 2.6)
_scaffold_critique() {
  local score="${1:-75}"
  local status="${2:-PASS}"
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >"${td}/notes.md" <<NOTESEOF
## Complexity
**Score:** simple

## Readiness Critique
**Score:** ${score}
**Status:** ${status}
NOTESEOF
}

# Helper: append a verification plan with a populated per-criterion table to notes.md
_scaffold_verify_plan_full() {
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  # Ensure critique section exists first
  if ! grep -q '## Readiness Critique' "${td}/notes.md" 2>/dev/null; then
    _scaffold_critique 75 PASS
  fi
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** global

### Role Scope Assessment

| Feature area | Affected roles | Scope type | Confidence | Basis |
|-------------|---------------|-----------|-----------|-------|
| handover | all | global | low | heuristic |

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Attorney clicks Send to create handover | global | /handover/ | none | Handover created and visible in list | ✓ |
| 2 | Admin views all handovers | role: admin | /admin/ | seed data: 3 handovers | All handovers displayed in admin table | ✓ |
PLANEOF
}

# Helper: append a verification plan with an empty per-criterion table (all columns blank)
_scaffold_verify_plan_empty() {
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  if ! grep -q '## Readiness Critique' "${td}/notes.md" 2>/dev/null; then
    _scaffold_critique 75 PASS
  fi
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** unknown

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Vague criterion |  |  |  |  | ✗ |
PLANEOF
}

# Helper: append a verification plan heading WITHOUT the per-criterion subsection
_scaffold_verify_plan_no_table() {
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  if ! grep -q '## Readiness Critique' "${td}/notes.md" 2>/dev/null; then
    _scaffold_critique 75 PASS
  fi
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** global
PLANEOF
}

# Helper: create an artifact file with verification prerequisites
_scaffold_artifact_with_prereqs() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Test fix with verification prerequisites.

**User:** test@example.com

## How to implement
1. Navigate to /handover/
2. Click Send button
3. Verify handover created

## Expected Behavior
- Handover appears in list after creation
- Admin can view all handovers at /admin/

## Setup
- Seed data: 3 test handovers
ARTEOF
}

# Helper: create a bare artifact file with NO verification prerequisites
_scaffold_artifact_bare() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Fix the thing.

## How to implement
Change line 42 of foo.js.
ARTEOF
}

# 16. Verification plan with populated table → all 4 prereqs found → auto-approve
test_verify_plan_full_table_auto_approves() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_full

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold with full verification plan table"
    return 1
  }
}

# 17. Empty verification plan table → falls back to artifact scan → prereqs found in artifact → auto-approve
test_verify_plan_empty_table_falls_back_to_artifact() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_empty
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve via artifact fallback), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: artifact should have had prereqs"
    return 1
  }
}

# 18. Empty table AND bare artifact → Check 2.6 holds with 2+ missing
test_verify_plan_empty_table_and_bare_artifact_holds() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_empty
  _scaffold_artifact_bare "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held), got $rc"
    return 1
  }
  [ -n "$held_line" ] || {
    echo "expected Check 2.6 hold, but no 'held: plan missing' in log"
    return 1
  }
}

# 19. No verification plan section → falls back to artifact (backward compat)
test_no_verify_plan_falls_back_to_artifact() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  # No _scaffold_verify_plan — notes.md has critique but no verification plan
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: artifact had prereqs via fallback"
    return 1
  }
}

# 20. Verification plan heading without per-criterion table → falls back
test_verify_plan_heading_without_table_falls_back() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_no_table
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve via fallback), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: should have fallen back to artifact"
    return 1
  }
}

# 21. No critique section → Check 2.6 skipped entirely (old ticket backward compat)
test_no_critique_skips_readiness_check() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  # No critique section — old ticket without critique. Write notes.md directly
  # to avoid _scaffold_verify_plan_empty's auto-critique behavior.
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >"${td}/notes.md" <<'NOTESEOF'
## Complexity
**Score:** simple

## Verification Plan
stuff but no per-criterion table
NOTESEOF
  _scaffold_artifact_bare "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve, check skipped), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: should have been skipped (no critique)"
    return 1
  }
}

# 22. Verification plan with partial data — one column populated, three empty → fallback
test_verify_plan_partial_data_falls_back() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS

  # Create a verification plan where only the nav path column has content
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-24

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Some criterion |  | /handover/ |  |  | ✗ |
PLANEOF

  # Artifact also bare — so fallback should still fail
  _scaffold_artifact_bare "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  # nav_path=1, but test_user=0 → OR fallback triggers → artifact scan
  # artifact is bare → 0 prereqs found → Check 2.6 holds (2+ missing)
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held — fallback to bare artifact), got $rc"
    return 1
  }
  [ -n "$held_line" ] || {
    echo "expected Check 2.6 hold after fallback to bare artifact"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Check 2.5a — Zero-AC structural gate
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: scaffold context.md with configurable AC count and ticket type
_scaffold_context_md() {
  local ac_count="${1:-2}"
  local labels="${2:-feature}"
  local has_repro="${3:-true}"
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true

  # Build AC lines
  local ac_lines=""
  local i
  for ((i = 1; i <= ac_count; i++)); do
    ac_lines+="${i}. Test acceptance criterion ${i}"$'\n'
  done

  # Build repro steps if requested
  local repro_section=""
  if [ "$has_repro" = "true" ]; then
    repro_section="## Steps to Reproduce
1. Go to /handover/
2. Click Send button
3. See error message"
  fi

  cat >"${td}/context.md" <<CTXEOF
# ${TICKET_ID} — Test Ticket

**Labels:** ${labels}

## Description
${ac_lines}

${repro_section}
CTXEOF
}

# Helper: scaffold critique with specific findings (for cross-validation tests)
_scaffold_critique_with_findings() {
  local score="${1:-75}"
  local status="${2:-PASS}"
  local findings="${3:-}"
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >"${td}/notes.md" <<NOTESEOF
## Complexity
**Score:** simple

## Readiness Critique
**Date:** 2026-06-25
**Status:** ${status}
**Score:** ${score}
**WARNING count:** 0
**BLOCKER count:** 1

### Findings
${findings}
NOTESEOF
}

# Helper: append a verification plan with nav path populated (used for cross-val tests
# where the LLM derived nav info from code/nav-hints despite critique gap)
_scaffold_verify_plan_with_nav() {
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-25
**Overall role scope:** global

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Test criterion | global | /handover/ | none | Handover created | ✓ |
PLANEOF
}

# 23. Zero acceptance criteria → gate-stop regardless of score
test_zero_ac_gate_stop() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 0 "feature" "true"
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"
  # Even with critique score 90, zero AC should be a hard stop
  _scaffold_critique 90 PASS

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'ZERO_AC' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected ZERO_AC gate-stop in log"
    return 1
  }
}

# 24. Zero AC without critique — still gate-stops (reads context.md directly)
test_zero_ac_no_critique_still_stops() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 0 "feature" "true"
  # No critique section at all — Check 2.5a runs independently
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >"${td}/notes.md" <<'NOTESEOF'
## Complexity
**Score:** simple
NOTESEOF
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'ZERO_AC' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected ZERO_AC gate-stop even without critique"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Check 2.5b — Bug repro structural gate
# ═══════════════════════════════════════════════════════════════════════════════

# 25. Bug ticket without reproduction steps → gate-stop
test_bug_no_repro_gate_stop() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "bug" "false" # bug label, no repro steps
  _scaffold_critique 75 PASS
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'BUG_NO_REPRO' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected BUG_NO_REPRO gate-stop in log"
    return 1
  }
}

# 26. Bug ticket WITH reproduction steps → passes Check 2.5b
test_bug_with_repro_passes() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "bug" "true" # bug label WITH repro steps
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_full
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'BUG_NO_REPRO' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve), got $rc"
    return 1
  }
  [ -z "$gate_stop" ] || {
    echo "unexpected BUG_NO_REPRO gate-stop: repro steps present"
    return 1
  }
}

# 27. Bug ticket without repro, good score — still gate-stops (structural, not score-based)
test_bug_no_repro_high_score_still_stops() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 3 "bug" "false" # 3 AC, bug, no repro
  _scaffold_critique 75 PASS           # score 75 would normally clear
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'BUG_NO_REPRO' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc — score 75 should not override structural gate"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected BUG_NO_REPRO gate-stop even with score 75"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Check 2.5 — Critique score/status gates (previously untested)
# ═══════════════════════════════════════════════════════════════════════════════

# 28. Critique status BLOCKED → gate-stop (exit 2)
test_critique_blocked_gate_stop() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique_with_findings 35 "BLOCKED" "- [BLOCKER] No acceptance criteria: ticket has zero verifiable outcomes listed."
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'CRITIQUE_BLOCKED' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected CRITIQUE_BLOCKED gate-stop in log"
    return 1
  }
}

# 29. Critique score below 40 → held (exit 1)
test_critique_score_below_40_held() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique 35 "WARNINGS" # score 35 < 40
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: content quality score' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held), got $rc"
    return 1
  }
  [ -n "$held_line" ] || {
    echo "expected 'held: content quality score' in log"
    return 1
  }
}

# 30. Score implausibility: 2 BLOCKERs but score > 50 → gate-stop
test_critique_score_implausible_2_blockers() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  # 2 BLOCKERs → max plausible score = 50. Score 72 exceeds that.
  _scaffold_critique_with_findings 72 "WARNINGS" "- [BLOCKER] No test user or role specified.
- [BLOCKER] No acceptance criteria: ticket has zero verifiable outcomes listed."
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'CRITIQUE_SCORE_IMPLAUSIBLE' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected CRITIQUE_SCORE_IMPLAUSIBLE gate-stop for 2 BLOCKERs + score 72"
    return 1
  }
}

# 31. Score implausibility: 1 BLOCKER but score > 70 → gate-stop
test_critique_score_implausible_1_blocker() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  # 1 BLOCKER → max plausible score = 75. Score 82 exceeds that.
  _scaffold_critique_with_findings 82 "WARNINGS" "- [BLOCKER] No test user or role specified."
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local gate_stop
  gate_stop=$(grep 'CRITIQUE_SCORE_IMPLAUSIBLE' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected CRITIQUE_SCORE_IMPLAUSIBLE gate-stop for 1 BLOCKER + score 82"
    return 1
  }
}

# 32. Score plausibility: 1 BLOCKER with score 65 → passes (max 75, 65 ≤ 75)
test_critique_score_plausible_1_blocker_passes() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique_with_findings 65 "WARNINGS" "- [BLOCKER] No test user or role specified."
  _scaffold_verify_plan_full
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local implausible
  implausible=$(grep 'CRITIQUE_SCORE_IMPLAUSIBLE' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve), got $rc"
    return 1
  }
  [ -z "$implausible" ] || {
    echo "unexpected CRITIQUE_SCORE_IMPLAUSIBLE: 1 BLOCKER with score 65 is plausible"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Cross-validation — critique findings vs. verification plan
# ═══════════════════════════════════════════════════════════════════════════════

# 33. Critique flagged nav gap + plan also has no nav → held
test_cross_val_nav_gap_unresolved_held() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique_with_findings 65 "WARNINGS" "- [WARNING] No navigation path specified. Verifier will need to discover the feature location from code."
  # Verification plan exists but nav column is empty (empty table scaffold)
  _scaffold_verify_plan_empty
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'cross-validation failed' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held), got $rc"
    return 1
  }
  [ -n "$held_line" ] || {
    echo "expected cross-validation hold: nav gap flagged by critique AND unresolved in plan"
    return 1
  }
}

# 34. Critique flagged nav gap + plan resolved it (LLM derived from nav-hints) → passes
test_cross_val_nav_gap_resolved_passes() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique_with_findings 65 "WARNINGS" "- [WARNING] No navigation path specified. Verifier will need to discover the feature location from code."
  # LLM derived nav path from nav-hints → plan has nav column populated
  _scaffold_verify_plan_with_nav
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'cross-validation failed' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve), got $rc — LLM resolved nav gap so cross-val should pass"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected cross-validation hold: nav was resolved in the plan"
    return 1
  }
}

# 35. Critique flagged repro gap → always held (cannot be derived by LLM)
test_cross_val_repro_gap_always_held() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "bug" "false" # bug with no repro
  _scaffold_critique_with_findings 65 "WARNINGS" "- [BLOCKER] Bug without repro steps: no numbered steps to reproduce the issue."
  _scaffold_verify_plan_with_nav # has nav and user, but repro gap is structural
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'cross-validation failed' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  # Check 2.5b should catch this first (BUG_NO_REPRO gate-stop, exit 2).
  # If 2.5b somehow misses it, cross-validation catches repro gap.
  [ "$rc" -ne 0 ] || {
    echo "expected non-zero exit (held or gate-stop), got $rc"
    return 1
  }
}

# 36. No critique → cross-validation skipped (backward compat)
test_cross_val_skipped_without_critique() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  # No critique section — cross-validation should be skipped
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >"${td}/notes.md" <<'NOTESEOF'
## Complexity
**Score:** simple
NOTESEOF
  _scaffold_verify_plan_empty
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local cross_val
  cross_val=$(grep 'cross-validation' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  # Without critique, Check 2.6 is skipped entirely → goes to auto-approve
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve, no critique), got $rc"
    return 1
  }
  [ -z "$cross_val" ] || {
    echo "unexpected cross-validation: no critique section exists"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Tightened fallback regex — false-positive avoidance
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: artifact with incidental matches that SHOULD NOT count as verification prereqs
_scaffold_artifact_false_positives() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Fix the thing. You should update the dependency first.
The setup for your IDE is straightforward.

## How to implement
The /handover/ API endpoint was changed — update the client.
Change line 42 of foo.js.
You should also check the tests pass.
ARTEOF
}

# 37. Tightened regex: bare "should" without AC context → not counted as expected behavior
test_tightened_regex_bare_should_not_counted() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique 75 PASS
  _scaffold_artifact_false_positives "${_ws}/simple-fix.md"
  # No verification plan → fallback triggers. Artifact has "should" but no AC context.

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  # Bare "should" + URL without nav verb → artifact fails all 4 prereqs → 2+ missing → held
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held), got $rc — bare 'should' and bare URL must not count"
    return 1
  }
  [ -n "$held_line" ] || {
    echo "expected 'held: plan missing' — bare patterns should not match tightened regex"
    return 1
  }
}

# 38. Tightened regex: artifact with proper context → counted
test_tightened_regex_proper_context_counted() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique 75 PASS
  # This artifact has the proper context for all 4 prereqs per tightened patterns
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: artifact has proper verification context"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Increment C — set -e safety: one missing prereq must not abort _gate_entry
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: artifact with exactly 3 of 4 prereqs (nav path missing)
_scaffold_artifact_three_prereqs() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Fix the thing.

**User:** test@example.com

## How to implement
Change line 42 of foo.js.

## Expected Behavior
- Result appears after save

## Setup
- Seed data: test fixture needed
ARTEOF
}

# 39. One missing prerequisite (nav path) → does NOT abort, evaluates below 2-missing threshold
test_entry_one_missing_prereq_no_abort() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  # No verification plan → fallback to artifact scan
  _scaffold_artifact_three_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  # With 3 of 4 prereqs found, missing_count=1 < 2 → auto-approve
  # If set -e fired on ((missing_count++)), _gate_entry would abort before
  # reaching the 2-missing threshold check.
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve — 1 missing prereq not threshold), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: 1 missing prereq should not trigger 2+ threshold"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Check 2.8c: manual-mode complex + approved override (issue #186)
# ═══════════════════════════════════════════════════════════════════════════════

# 40. Complex + manual + approved label + Ready state → Check 2.8c overrides Check 3 (exit 0)
test_entry_complex_manual_approved_ready_passes() {
  _setup
  _scaffold_exec_done "complex" "manual" "openspec" "${_ws}/openspec-change.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  _fake_manifest_exists_override="false"
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_approval "$_tid" "true" "human" >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_stage "$_tid" "Ready" >/dev/null

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  local overridden_line
  overridden_line=$(grep 'manual mode overridden' "$LOG_FILE" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (Check 2.8c override), got $rc"
    return 1
  }
  [ -n "$overridden_line" ] || {
    echo "expected Check 2.8c override log entry"
    return 1
  }
}

# 41. Complex + manual + NOT approved → still held on Check 3 (regression guard)
test_entry_complex_manual_not_approved_still_held() {
  _setup
  _scaffold_exec_done "complex" "manual" "openspec" "${_ws}/openspec-change.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held: complex ticket), got $rc"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Cross-validation browser-mode guard (issue #186)
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: build-only artifact — build command + BUILD SUCCESS outcome, no browser signals
_scaffold_artifact_build_only() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Migrate circuit breaker library from Hystrix to Resilience4j.

## How to implement
1. Run `mvn clean install`
2. Confirm BUILD SUCCESS in CI logs
ARTEOF
}

# 42. Build-only ticket + critique flags nav gap → cross-val skipped (nav path is meaningless, no UI exists)
test_cross_val_build_only_nav_gap_not_held() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique_with_findings 65 "WARNINGS" "- [WARNING] No navigation path specified. Verifier will need to discover the feature location from code."
  _scaffold_artifact_build_only "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'cross-validation failed' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (build-only ticket, nav gap not applicable), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected cross-validation hold: nav path is meaningless for build-only tickets"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Cross-validation infra-dashboard guard (issue #316)
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: artifact with a real test user but only infra-dashboard nav targets
# (Eureka, a bare host:port) — no feature-recognized path.
_scaffold_artifact_infra_dashboard() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Phase A smoke test across 5 microservices.

## How to implement
1. Open http://localhost:9000 (gateway UI)
2. Log in as gerhard.steyn at http://localhost:8761 (Eureka dashboard)
3. Confirm all services registered

## Expected Behavior
- All 5 services show as UP in Eureka

## Setup
- Seed data: test users pre-provisioned
ARTEOF
}

# 43. Real test user + infra-dashboard-only nav target → reclassified out of
# browser mode, so critique's nav gap finding no longer false-holds it.
test_cross_val_infra_dashboard_nav_gap_not_held() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique_with_findings 65 "WARNINGS" "- [WARNING] No navigation path specified. Verifier will need to discover the feature location from code."
  _scaffold_artifact_infra_dashboard "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line missing_line
  held_line=$(grep 'cross-validation failed' "$LOG_FILE" 2>/dev/null || true)
  missing_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (infra-only ticket, nav gap not applicable), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected cross-validation hold: nav path is meaningless for infra-dashboard-only tickets"
    return 1
  }
  [ -z "$missing_line" ] || {
    echo "unexpected missing-prerequisite hold: infra-only mode should only require expected behavior + env prereqs"
    return 1
  }
}

# 44. No nav path AND no test user (genuine gap, browser signals present) →
# still holds — the pre-existing has_nav_path=0 && has_test_user=0 block is untouched.
test_cross_val_missing_nav_and_user_still_held() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique_with_findings 65 "WARNINGS" "- [WARNING] No navigation path specified. Verifier will need to discover the feature location from code."
  cat >"${_ws}/simple-fix.md" <<'ARTEOF'
# Simple Fix — Test

## Summary
Fix a UI bug in the dashboard.

## How to implement
1. Open the browser and click around to reproduce.
2. Take a screenshot of the broken state.

## Expected Behavior
- The dashboard should render without errors

## Setup
- Seed data: pre-existing dashboard state
ARTEOF

  _gate_entry
  local rc=$?

  local mode_line
  mode_line=$(grep -E 'mode=(infra-only|api-only)' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -ne 0 ] || {
    echo "expected non-zero exit (held): no nav path and no test user is a genuine gap"
    return 1
  }
  [ -z "$mode_line" ] || {
    echo "unexpected reclassification away from browser mode: neither nav path nor test user was found"
    return 1
  }
}

# 45. Real test user AND a real feature-path nav target → unaffected, stays
# in browser mode, all 4 prerequisites still required.
test_browser_mode_unaffected_with_feature_path_and_user() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique 75 PASS
  cat >"${_ws}/simple-fix.md" <<'ARTEOF'
# Simple Fix — Test

## Summary
Fix handover UI bug.

**User:** test@example.com

## How to implement
1. Navigate to /handover/
2. Click Send button
ARTEOF

  _gate_entry
  local rc=$?

  local missing_line
  missing_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held: 2/4 prerequisites missing in browser mode), got $rc"
    return 1
  }
  echo "$missing_line" | grep -q 'missing 2/4' || {
    echo "expected browser mode to still require all 4 prerequisites, got: $missing_line"
    return 1
  }
  echo "$missing_line" | grep -q 'mode=browser' || {
    echo "expected ticket to stay in browser mode (real feature path + real test user present), got: $missing_line"
    return 1
  }
}

# Helper: artifact with a real test user, a real (but unlisted-route) feature
# path, and an incidental bare localhost:PORT mention in a Setup line — no
# named infra keyword (Eureka/Zipkin/actuator/registry/discovery/config-server)
# anywhere in the artifact.
_scaffold_artifact_bare_hostport_no_infra_keyword() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Fix the CSV export on the Invoices report.

**User:** test@example.com

## How to implement
1. Click the Export button on the Invoices tab within /reports/
2. Confirm the downloaded CSV includes every visible row

## Expected Behavior
- The exported CSV should include every visible invoice row

## Setup
- Local URL: http://localhost:4200
- Seed data: 12 invoices pre-loaded for the test tenant
ARTEOF
}

# 46. Real test user + real (unlisted) feature path + incidental bare
# localhost:PORT mention in a Setup section, with NO named infra keyword
# anywhere → must stay in browser mode, NOT be reclassified to infra-only.
# This project's own LOCAL_URL convention is almost always a bare
# localhost:PORT value, and it's routine for a plan's Setup/Environment line
# to state it separately from the step-by-step nav instructions — a bare
# host:port alone must never be sufficient to flag infra on its own. The
# critique's "No navigation path" finding is still genuinely unresolved by
# the plan here, so the nav_gap cross-validation must still fire — proving
# the hold path wasn't silently bypassed by a false infra-only
# reclassification (which would drop required prerequisites from 4 to 2 and
# skip this exact cross-validation).
test_cross_val_bare_hostport_alone_stays_browser_mode() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_context_md 2 "feature" "true"
  _scaffold_critique_with_findings 65 "WARNINGS" "- [WARNING] No navigation path specified. Verifier will need to discover the feature location from code."
  _scaffold_artifact_bare_hostport_no_infra_keyword "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local cross_val_line infra_mode_line
  cross_val_line=$(grep 'cross-validation failed' "$LOG_FILE" 2>/dev/null || true)
  infra_mode_line=$(grep 'mode=infra-only' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held: browser-mode nav_gap cross-validation still applies), got $rc"
    return 1
  }
  [ -n "$cross_val_line" ] || {
    echo "expected cross-validation hold: a bare localhost:PORT mention must not reclassify this real browser ticket to infra-only and skip nav_gap validation"
    return 1
  }
  [ -z "$infra_mode_line" ] || {
    echo "unexpected infra-only reclassification: bare host:port alone (no named infra keyword) must not trigger it"
    return 1
  }
}

# ── Commercial Evidence MVP (Branch B): META|complexity single-writer ──────────

# META|complexity is written exactly once per ticket, on the standard route.
test_complexity_line_written_once() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry >/dev/null 2>&1 || true

  local count value
  count=$(grep -c '|META|complexity|info|' "$LOG_FILE" 2>/dev/null || echo 0)
  value=$(grep '|META|complexity|info|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5-)

  _teardown
  [ "$count" -eq 1 ] || {
    echo "expected exactly 1 META|complexity line, got $count"
    return 1
  }
  [ "$value" = "simple" ] || {
    echo "expected complexity value 'simple', got '$value'"
    return 1
  }
}

# A second gate-check invocation for the same ticket (e.g. reapprove mode
# re-entering _gate_entry) must not duplicate the line.
test_complexity_line_not_duplicated_on_second_entry() {
  _setup
  _scaffold_exec_done "simple" "manual" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry >/dev/null 2>&1 || true
  _gate_entry >/dev/null 2>&1 || true

  local count
  count=$(grep -c '|META|complexity|info|' "$LOG_FILE" 2>/dev/null || echo 0)

  _teardown
  [ "$count" -eq 1 ] || {
    echo "expected exactly 1 META|complexity line after two _gate_entry calls, got $count"
    return 1
  }
}

# The fast-path (planned tickets skipping full investigation) flows through
# the same _gate_entry function — there is no separate code path — so the
# complexity line is written there too. A planned-labeled issue exercises
# Check 2.7 without changing the assertion under test.
test_complexity_line_written_on_planned_fast_path() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _fake_issue='{"description":"## Planner Context\n**Confidence:** 0.9\n","labels":{"nodes":[{"name":"planned"},{"name":"feature"}]}}'

  _gate_entry >/dev/null 2>&1 || true

  local count
  count=$(grep -c '|META|complexity|info|' "$LOG_FILE" 2>/dev/null || echo 0)

  _teardown
  [ "$count" -eq 1 ] || {
    echo "expected exactly 1 META|complexity line on planned fast-path, got $count"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Issue #362 (LINEAR_GET_ISSUE_NULL_CONTINUES) — get_issue fetch failures must
# never fall through to a decision made against null.
#
# tracker-read-failure-policy section 6 changed the entry-gate consequence
# from an immediate gate-stop to a retryable hold: the first
# GATE_FETCH_MAX_ATTEMPTS-1 failures hold (exit 1, "held: linear fetch
# failed"), riding the same resumable-hold path a complex-ticket or
# manual-mode hold already uses, and only the Nth consecutive failure
# gate-stops (exit 2, LINEAR_FETCH_FAILED) — see gate-check.sh's
# _gate_fetch_issue_fail. reapprove-gate context is unaffected (still an
# immediate gate-stop; see the regression guard below).
# ═══════════════════════════════════════════════════════════════════════════════

# 42. get_issue fetch failure at Check 2.7 holds (exit 1) on the first two
# attempts, then gate-stops (exit 2, LINEAR_FETCH_FAILED) on the third —
# never a silent "not planned" fallthrough on any attempt.
test_entry_get_issue_fetch_failure_gate_stops() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  get_issue() { return 1; }

  local rc1 rc2 rc3
  _gate_entry >/dev/null 2>&1
  rc1=$?
  _gate_entry >/dev/null 2>&1
  rc2=$?
  _gate_entry >/dev/null 2>&1
  rc3=$?

  local gate_stop held_count
  gate_stop=$(grep 'LINEAR_FETCH_FAILED' "$LOG_FILE" 2>/dev/null || true)
  held_count=$(grep -c 'held: linear fetch failed' "$LOG_FILE" 2>/dev/null || echo 0)

  _teardown
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$rc3" -eq 2 ] || {
    echo "expected hold, hold, gate-stop (1, 1, 2); got ($rc1, $rc2, $rc3)"
    return 1
  }
  [ "$held_count" -eq 2 ] || {
    echo "expected 2 held lines before the gate-stop, got $held_count"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected LINEAR_FETCH_FAILED gate-stop in log after retries exhausted"
    return 1
  }
}

# 43. get_issue returns unparseable/malformed JSON at Check 2.7 → same
# hold-then-gate-stop shape, never a jq crash and never treated as "zero
# labels".
test_entry_get_issue_malformed_payload_gate_stops() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  get_issue() { echo 'not-json'; }

  local rc1 rc2 rc3
  _gate_entry >/dev/null 2>&1
  rc1=$?
  _gate_entry >/dev/null 2>&1
  rc2=$?
  _gate_entry >/dev/null 2>&1
  rc3=$?

  local gate_stop
  gate_stop=$(grep 'LINEAR_FETCH_FAILED' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$rc3" -eq 2 ] || {
    echo "expected hold, hold, gate-stop (1, 1, 2); got ($rc1, $rc2, $rc3)"
    return 1
  }
  [ -n "$gate_stop" ] || {
    echo "expected LINEAR_FETCH_FAILED gate-stop in log for malformed payload after retries exhausted"
    return 1
  }
}

# 42c. Design task 6.7: a gate re-evaluated after a fetch-failure hold
# applies IDENTICAL approval criteria once the fetch recovers — the prior
# failure must never be treated as, or bleed into, an approval decision.
# A complex ticket that recovers to a readable-but-unapproved state must
# still hold on Check 3 ("complex ticket"), not pass because attempt
# tracking happened to be in flight.
test_entry_fetch_recovery_applies_same_criteria_not_a_pass() {
  _setup
  _scaffold_exec_done "complex" "auto" "openspec" "${_ws}/openspec-change.md"
  get_issue() { return 1; }

  _gate_entry >/dev/null 2>&1
  local rc1=$?

  # Fetch recovers, but the ticket is still unapproved — Check 3 must still
  # hold it, not treat the recovered read as approval.
  get_issue() { echo '{"id":"CRE-47","identifier":"CRE-47","labels":{"nodes":[]}}'; }
  _gate_entry >/dev/null 2>&1
  local rc2=$?

  local complex_held fetch_gate_stop
  complex_held=$(grep '|GATE|gate|fail|held: complex ticket' "$LOG_FILE" 2>/dev/null || true)
  fetch_gate_stop=$(grep 'LINEAR_FETCH_FAILED' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] || {
    echo "expected both calls to hold (1, 1); got ($rc1, $rc2)"
    return 1
  }
  [ -n "$complex_held" ] || {
    echo "expected the recovered call to hold on Check 3 (complex ticket), not pass"
    return 1
  }
  [ -z "$fetch_gate_stop" ] || {
    echo "a single fetch-failure attempt must never gate-stop"
    return 1
  }
}

# 42b. A held fetch failure never gate-stops before the cap, and rides the
# same "held: " GATE/gate/fail shape every other entry-gate hold uses, so
# it resumes via the existing hold machinery with zero new resume-side code.
test_entry_get_issue_fetch_failure_holds_before_cap() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  get_issue() { return 1; }

  _gate_entry >/dev/null 2>&1
  local rc=$?

  local held_line
  held_line=$(grep '|GATE|gate|fail|held: linear fetch failed' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held) on the first failure, got $rc"
    return 1
  }
  [ -n "$held_line" ] || {
    echo "expected a GATE|gate|fail|held: linear fetch failed line, got none"
    return 1
  }
}

# 44. tracker-approval-by-script: _gate_reapprove no longer fetches the
# tracker at all — a missing manifest is a distinct migration/provisioning
# gap (D3), not conflated with an ordinary "not approved" APPROVAL_REVOKED.
# Both still gate-stop (the ticket cannot resume without a considered
# approval), but the log must say which happened.
test_reapprove_missing_manifest_not_conflated_with_revoked() {
  _setup
  local repos_root
  repos_root=$(mktemp -d)
  # No manifest written at all for $_tid.

  REPOS_ROOT="$repos_root" _gate_reapprove
  local rc=$?

  local manifest_missing revoked
  manifest_missing=$(grep 'MANIFEST_MISSING' "$LOG_FILE" 2>/dev/null || true)
  revoked=$(grep 'APPROVAL_REVOKED' "$LOG_FILE" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc"
    return 1
  }
  [ -n "$manifest_missing" ] || {
    echo "expected META|manifest|warn|MANIFEST_MISSING in log"
    return 1
  }
  [ -n "$revoked" ] || {
    echo "expected APPROVAL_REVOKED gate-stop even for a missing manifest"
    return 1
  }
}

# 45. Manifest exists, approved=true, but stage doesn't match Ready — the
# two-factor check (D1) must reject it, and this is a plain hold, not a
# missing-manifest warning.
test_reapprove_manifest_wrong_stage_gate_stops() {
  _setup
  local repos_root
  repos_root=$(mktemp -d)
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_approval "$_tid" "true" "human" >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_stage "$_tid" "Review" >/dev/null

  REPOS_ROOT="$repos_root" _gate_reapprove
  local rc=$?

  local manifest_missing revoked
  manifest_missing=$(grep 'MANIFEST_MISSING' "$LOG_FILE" 2>/dev/null || true)
  revoked=$(grep 'APPROVAL_REVOKED' "$LOG_FILE" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2 (gate-stop), got $rc"
    return 1
  }
  [ -n "$revoked" ] || {
    echo "expected APPROVAL_REVOKED gate-stop for approved-but-wrong-stage"
    return 1
  }
  [ -z "$manifest_missing" ] || {
    echo "a manifest that exists but has the wrong stage must not warn MANIFEST_MISSING"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Outbox release-pairing (tracker-inbound-approval, Track B Phase B4)
# gate-hold-intake spec: "Every approval-type hold-clearing path emits a
# matching release event" — Check 5's policy auto-approve and Check
# 2.8c/4's manual-mode override must call _gate_emit_released with the
# correct provenance, matching the reapprove path's pre-existing behavior.
# ═══════════════════════════════════════════════════════════════════════════════

# 42. Check 5 (simple + auto) auto-approve emits gate-released with policy provenance
test_check5_auto_approve_emits_released_policy() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local emit_calls
  emit_calls=$(cat "${_ws}/emit-calls.log" 2>/dev/null || true)
  local flow_calls
  flow_calls=$(cat "$_flow_log" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$emit_calls" | grep -q 'emit_event|.*|gate-released|{"provenance":"policy"}' || {
    echo "expected emit_event gate-released with policy provenance, got: $emit_calls"
    return 1
  }
  echo "$flow_calls" | grep -q -- "--provenance policy" || {
    echo "expected flow.sh human-approve called with --provenance policy, got: $flow_calls"
    return 1
  }
}

# 43. Check 2.8c (complex + manual + manifest approved+staged) override emits gate-released with human provenance
test_check28c_manual_override_emits_released_human() {
  _setup
  _scaffold_exec_done "complex" "manual" "openspec" "${_ws}/openspec-change.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  _fake_manifest_exists_override="false"
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_approval "$_tid" "true" "human" >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_stage "$_tid" "Ready" >/dev/null

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  local emit_calls
  emit_calls=$(cat "${_ws}/emit-calls.log" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$emit_calls" | grep -q 'emit_event|.*|gate-released|{"provenance":"human"}' || {
    echo "expected emit_event gate-released with human provenance, got: $emit_calls"
    return 1
  }
}

# 44. Check 4 (simple + manual + manifest approved+staged) override emits gate-released with human provenance
test_check4_manual_override_emits_released_human() {
  _setup
  _scaffold_exec_done "simple" "manual" "simple-fix" "${_ws}/simple-fix.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  _fake_manifest_exists_override="false"
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_approval "$_tid" "true" "human" >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_stage "$_tid" "Ready" >/dev/null

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  local emit_calls
  emit_calls=$(cat "${_ws}/emit-calls.log" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$emit_calls" | grep -q 'emit_event|.*|gate-released|{"provenance":"human"}' || {
    echo "expected emit_event gate-released with human provenance, got: $emit_calls"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Approval decision reads are manifest-only, no tracker fallback
# (tracker-approval-by-script). Supersedes the B4-era "approval-decision
# reads stay live" pin below — that was this exact guard's opposite: B4
# deliberately left Checks 2.8b/2.8c/4/reapprove on a live Linear read and
# pinned a test proving a manifest approved=true could never override it.
# This change flips the authority: the manifest is the sole approval
# decision (local-approval-authority spec), so these tests now pin the two-
# factor check (D1: approved AND staged) and the missing-manifest-vs-
# field-absent distinction (D3) instead.
# ═══════════════════════════════════════════════════════════════════════════════

_scaffold_approved_no_stage_manifest() {
  local repos_root="$1"
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_approval "$_tid" "true" "human" >/dev/null
  # Force Check 2.7's planned-ticket branch onto its live-label path (no
  # "planned" label in _fake_issue here) — this manifest exists only to
  # probe approval-decision reads, not to exercise the planned-ticket flow.
  _fake_manifest_exists_override="false"
}

# 45. Check 2.8b: approved=true + stage=Ready → passes, no live tracker read
# (the default _fake_issue below carries no "approved" label at all).
test_check28b_manifest_approved_and_staged_passes() {
  _setup
  _scaffold_exec_done "complex" "auto" "openspec" "${_ws}/openspec-change.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  _fake_manifest_exists_override="false"
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_approval "$_tid" "true" "human" >/dev/null
  REPOS_ROOT="$repos_root" set_ticket_stage "$_tid" "Ready" >/dev/null

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (Check 2.8b auto-approve from manifest alone), got $rc"
    return 1
  }
}

# 46. Check 2.8b: approved=true but no stage → two-factor check holds (D1)
test_check28b_approved_without_stage_holds() {
  _setup
  _scaffold_exec_done "complex" "auto" "openspec" "${_ws}/openspec-change.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  _scaffold_approved_no_stage_manifest "$repos_root"

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  local manifest_missing
  manifest_missing=$(grep 'MANIFEST_MISSING' "$LOG_FILE" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held: complex ticket) — approved without a matching stage must hold (Check 2.8b), got $rc"
    return 1
  }
  [ -z "$manifest_missing" ] || {
    echo "a manifest that exists but lacks a matching stage must not warn MANIFEST_MISSING"
    return 1
  }
}

# 47. Check 2.8c: approved=true but no stage → holds
test_check28c_approved_without_stage_holds() {
  _setup
  _scaffold_exec_done "complex" "manual" "openspec" "${_ws}/openspec-change.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  _scaffold_approved_no_stage_manifest "$repos_root"

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held: complex ticket) — approved without a matching stage must hold (Check 2.8c), got $rc"
    return 1
  }
}

# 48. Check 4: approved=true but no stage → holds
test_check4_approved_without_stage_holds() {
  _setup
  _scaffold_exec_done "simple" "manual" "simple-fix" "${_ws}/simple-fix.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  _scaffold_approved_no_stage_manifest "$repos_root"

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held: manual mode) — approved without a matching stage must hold (Check 4), got $rc"
    return 1
  }
}

# 49. Check 2.8b: a hand-applied live "approved" label with no manifest at
# all does not approve (local-approval-authority spec: "A hand-applied
# tracker label does not approve") — and the missing manifest warns.
test_check28b_live_label_ignored_manifest_missing_warns() {
  _setup
  _scaffold_exec_done "complex" "auto" "openspec" "${_ws}/openspec-change.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Ready"},"labels":{"nodes":[{"name":"approved"},{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  # No manifest written at all.

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  local manifest_missing
  manifest_missing=$(grep 'MANIFEST_MISSING' "$LOG_FILE" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held: complex ticket) — a hand-applied live label must not approve, got $rc"
    return 1
  }
  [ -n "$manifest_missing" ] || {
    echo "expected META|manifest|warn|MANIFEST_MISSING when no manifest exists"
    return 1
  }
}

# 50. Check 4: manifest exists but the approved field is plain absent (not
# missing manifest) — holds silently, no MANIFEST_MISSING warning (D3).
test_check4_field_absent_holds_without_warning() {
  _setup
  _scaffold_exec_done "simple" "manual" "simple-fix" "${_ws}/simple-fix.md"
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  REPOS_ROOT="$repos_root" write_ticket_manifest "$_tid" "INIT-1" "feature" '[]' >/dev/null
  _fake_manifest_exists_override="false"

  REPOS_ROOT="$repos_root" _gate_entry
  local rc=$?

  local manifest_missing
  manifest_missing=$(grep 'MANIFEST_MISSING' "$LOG_FILE" 2>/dev/null || true)

  rm -rf "$repos_root"
  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held: manual mode) — an existing manifest with no approved field must hold, got $rc"
    return 1
  }
  [ -z "$manifest_missing" ] || {
    echo "an existing manifest with an absent field must hold silently, without MANIFEST_MISSING"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatcher
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"

# tracker-local-facts-read-migration (task 5.1): a local ticket manifest
# alone must be sufficient to drive Check 2.7, even when the live issue
# carries no "planned" label at all.
test_manifest_only_drives_check_2_7() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _fake_issue='{"id":"CRE-47","identifier":"CRE-47","title":"Test","description":"## Planner Context\n**Confidence:** 0.9\n","labels":{"nodes":[{"name":"feature"}]}}'

  local repos_root
  repos_root=$(mktemp -d)
  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-47" "INIT-1" "feature" '[]' >/dev/null

  REPOS_ROOT="$repos_root" _gate_entry >/dev/null 2>&1 || true

  local planned_check_lines
  planned_check_lines=$(grep -c '|GATE|planned-check|' "$LOG_FILE" 2>/dev/null || echo 0)

  rm -rf "$repos_root"
  _teardown
  [ "$planned_check_lines" -ge 1 ] || {
    echo "expected Check 2.7 to run from manifest presence alone (no live planned label), got $planned_check_lines planned-check lines"
    return 1
  }
}

# tracker-local-facts-read-migration (task 5.12): manifest's type field
# drives template resolution even when the live labels carry no type label
# at all.
test_manifest_type_field_drives_template_resolution() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _fake_issue='{"id":"CRE-47","identifier":"CRE-47","title":"Test","description":"## Planner Context\n**Confidence:** 0.9\n","labels":{"nodes":[]}}'

  local repos_root
  repos_root=$(mktemp -d)
  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-47" "INIT-1" "feature" '[]' >/dev/null

  REPOS_ROOT="$repos_root" _gate_entry >/dev/null 2>&1 || true

  # grep -c already prints "0" (with exit 1) on zero matches — an `|| echo 0`
  # fallback here would duplicate it into a two-line value.
  local resolved
  resolved=$(grep -c 'template resolved:' "$LOG_FILE" 2>/dev/null)
  local no_template
  no_template=$(grep -c 'NO_TEMPLATE_FOR_TYPE' "$LOG_FILE" 2>/dev/null)

  rm -rf "$repos_root"
  _teardown
  [ "$resolved" -ge 1 ] && [ "$no_template" -eq 0 ] || {
    echo "expected template resolved from manifest type (no live type label present), got resolved=$resolved no_template=$no_template"
    return 1
  }
}

for fn in \
  test_entry_artifact_missing_gate_stop \
  test_entry_complexity_artifact_mismatch \
  test_entry_simple_auto_calls_flow_human_approve \
  test_entry_simple_semi_auto_calls_flow_human_approve \
  test_entry_simple_manual_held \
  test_entry_complex_held \
  test_entry_gate_start_event_written \
  test_entry_autonomy_from_log \
  test_entry_complexity_from_notes \
  test_entry_artifact_path_from_log \
  test_entry_artifact_path_fallback_from_create_artifact \
  test_entry_fleet_detect_format \
  test_reapprove_approved_and_ready_passes \
  test_reapprove_label_missing_gate_stop \
  test_reapprove_wrong_state_gate_stop \
  test_reapprove_both_wrong_single_gate_stop \
  test_verify_plan_full_table_auto_approves \
  test_verify_plan_empty_table_falls_back_to_artifact \
  test_verify_plan_empty_table_and_bare_artifact_holds \
  test_no_verify_plan_falls_back_to_artifact \
  test_verify_plan_heading_without_table_falls_back \
  test_no_critique_skips_readiness_check \
  test_verify_plan_partial_data_falls_back \
  test_zero_ac_gate_stop \
  test_zero_ac_no_critique_still_stops \
  test_bug_no_repro_gate_stop \
  test_bug_with_repro_passes \
  test_bug_no_repro_high_score_still_stops \
  test_critique_blocked_gate_stop \
  test_critique_score_below_40_held \
  test_critique_score_implausible_2_blockers \
  test_critique_score_implausible_1_blocker \
  test_critique_score_plausible_1_blocker_passes \
  test_cross_val_nav_gap_unresolved_held \
  test_cross_val_nav_gap_resolved_passes \
  test_cross_val_repro_gap_always_held \
  test_cross_val_skipped_without_critique \
  test_tightened_regex_bare_should_not_counted \
  test_tightened_regex_proper_context_counted \
  test_entry_one_missing_prereq_no_abort \
  test_entry_complex_manual_approved_ready_passes \
  test_entry_complex_manual_not_approved_still_held \
  test_cross_val_build_only_nav_gap_not_held \
  test_cross_val_infra_dashboard_nav_gap_not_held \
  test_cross_val_missing_nav_and_user_still_held \
  test_browser_mode_unaffected_with_feature_path_and_user \
  test_cross_val_bare_hostport_alone_stays_browser_mode \
  test_complexity_line_written_once \
  test_complexity_line_not_duplicated_on_second_entry \
  test_complexity_line_written_on_planned_fast_path \
  test_entry_get_issue_fetch_failure_gate_stops \
  test_entry_get_issue_fetch_failure_holds_before_cap \
  test_entry_fetch_recovery_applies_same_criteria_not_a_pass \
  test_entry_get_issue_malformed_payload_gate_stops \
  test_reapprove_missing_manifest_not_conflated_with_revoked \
  test_reapprove_manifest_wrong_stage_gate_stops \
  test_manifest_only_drives_check_2_7 \
  test_manifest_type_field_drives_template_resolution \
  test_check5_auto_approve_emits_released_policy \
  test_check28c_manual_override_emits_released_human \
  test_check4_manual_override_emits_released_human \
  test_check28b_manifest_approved_and_staged_passes \
  test_check28b_approved_without_stage_holds \
  test_check28c_approved_without_stage_holds \
  test_check4_approved_without_stage_holds \
  test_check28b_live_label_ignored_manifest_missing_warns \
  test_check4_field_absent_holds_without_warning; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
