#!/usr/bin/env bash
# test-pipeline-phases.sh — structural tests for thin router dispatch
# Usage: bash test-pipeline-phases.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$(cd "$LIB_DIR/../skills" && pwd)"

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

# ── mocks ──────────────────────────────────────────────────────────────────────

hb_init() { return 0; }
hb_heartbeat() { return 0; }
hb_gate() { return 0; }
hb_decision() { return 0; }
hb_retry() { return 0; }
hb_api() { return 0; }
hb_source() { return 0; }
get_issue() { echo '{"id":"TEST-1","labels":{"nodes":[{"name":"bug"}]}}'; }
get_comments() { echo '[]'; }
resolve_ticket_dir() { echo "/tmp/TEST-1--test"; }
get_complexity() { echo "simple"; }

# ── detect-resume.sh tests ─────────────────────────────────────────────────────

test_detect_resume_step_table() {
  local detect_sh="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
  [ -f "$detect_sh" ] || {
    echo "detect-resume.sh not found"
    return 1
  }
  grep -q 'STEP_6' "$detect_sh" || {
    echo "STEP_6 not in detect-resume.sh"
    return 1
  }
  grep -q 'STEP_4_6' "$detect_sh" || {
    echo "STEP_4_6 not in detect-resume.sh"
    return 1
  }
  grep -q 'STEP_2_5' "$detect_sh" || {
    echo "STEP_2_5 not in detect-resume.sh"
    return 1
  }
  grep -q 'STEP_3_5' "$detect_sh" || {
    echo "STEP_3_5 not in detect-resume.sh"
    return 1
  }
  grep -q 'AUTONOMY' "$detect_sh" || {
    echo "AUTONOMY extraction missing"
    return 1
  }
}

test_detect_resume_all_key_steps() {
  local detect_sh="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
  [ -f "$detect_sh" ] || return 1
  local steps=("STEP_1" "STEP_1_5" "STEP_2" "STEP_2_5" "STEP_3_5" "STEP_4" "STEP_4_5" "STEP_4_6" "STEP_5" "STEP_5_5" "STEP_6")
  local missing=""
  for step in "${steps[@]}"; do
    if ! grep -q "$step" "$detect_sh"; then missing="$missing $step"; fi
  done
  [ -z "$missing" ] || {
    echo "Missing step references:$missing"
    return 1
  }
}

# ── Router structural tests ────────────────────────────────────────────────────

test_router_gate_check_reference() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'gate-check\.sh' "$skill_md" || {
    echo "gate-check.sh not referenced"
    return 1
  }
}

test_router_outcome_label_check_reference() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'outcome-label-check\.sh' "$skill_md" || {
    echo "outcome-label-check.sh not referenced"
    return 1
  }
}

test_router_detect_resume_direct_bash() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'detect-resume\.sh' "$skill_md" || {
    echo "detect-resume.sh not referenced"
    return 1
  }
}

test_router_verify_attempts_usage() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'VERIFY_ATTEMPTS' "$skill_md" || {
    echo "VERIFY_ATTEMPTS not found"
    return 1
  }
}

test_router_iteration_usage() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'ITERATION' "$skill_md" || {
    echo "ITERATION not found"
    return 1
  }
}

test_router_gate_reconcile_reference() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'ticket-gate-reconcile' "$skill_md" || {
    echo "ticket-gate-reconcile not referenced"
    return 1
  }
}

test_router_auto_merge_check() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'gh pr merge' "$skill_md" || {
    echo "gh pr merge not found"
    return 1
  }
}

test_router_step_2_5_is_gate() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local step25
  step25=$(grep 'STEP_2_5' "$skill_md" | grep -i 'gate' || true)
  [ -n "$step25" ] || {
    echo "STEP_2_5 not associated with gate"
    return 1
  }
}

test_router_step_3_5_is_reconcile() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'STEP_3_5' "$skill_md" || {
    echo "STEP_3_5 not in dispatch table"
    return 1
  }
}

test_router_step_4_is_implement() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_4 —\|### STEP_4$/,/^### /p' "$skill_md" 2>/dev/null)
  grep -qi 'implement' <<<"$section" || {
    echo "STEP_4 not associated with implement"
    return 1
  }
}

test_router_step_4_6_is_pr_review() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_4_6/,/^### /p' "$skill_md" 2>/dev/null)
  grep -qiE 'pr.review|PR Review' <<<"$section" || {
    echo "STEP_4_6 not associated with PR review"
    return 1
  }
}

test_router_step_5_is_document_wiki() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_5 —\|### STEP_5$/,/^### /p' "$skill_md" 2>/dev/null)
  grep -qiE 'document|wiki|maintenance' <<<"$section" || {
    echo "STEP_5 not associated with document/wiki"
    return 1
  }
}

test_router_step_6_is_report() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_6/,/^---/p' "$skill_md" 2>/dev/null)
  grep -qiE 'retro|report|outcome' <<<"$section" || {
    echo "STEP_6 not associated with report"
    return 1
  }
}

test_router_dispatch_table_covers_all_steps() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local count
  count=$(grep -cE 'STEP_[0-9]' "$skill_md" || true)
  [ "$count" -ge 8 ] || {
    echo "Only $count STEP references (need >=8)"
    return 1
  }
}

test_router_spawn_pattern_documented() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'spawn_agent_pre\|spawn_capture\|spawn_agent_post' "$skill_md" || {
    echo "3-step spawn pattern not documented"
    return 1
  }
}

test_router_default_case_present() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -qi 'unknown\|default\|unrecognized.*RESUME_STEP' "$skill_md" || {
    echo "Default case for unknown RESUME_STEP not found"
    return 1
  }
}

test_router_zero_inline_llm_invariant() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'zero inline LLM\|no inline LLM\|No inline LLM' "$skill_md" || {
    echo "Zero inline LLM invariant not declared"
    return 1
  }
}

# test_router_team_resolution_query_failure_message and
# test_router_team_resolution_multi_team_message_unchanged pinned Step 0.4's
# preflight prose, which moved into lib/ticket-preamble.sh (skill-glue-collapse).
# Covered by test-ticket-preamble.sh: test_preflight_teams_query_failure_has_its_own_message,
# test_preflight_numeric_guard_is_in_the_script and
# test_preflight_multiple_teams_asks_for_linear_team_id.

# ── Gate-check.sh tests ────────────────────────────────────────────────────────

test_gate_check_has_artifact_guard() {
  local gate_check="$LIB_DIR/gate-check.sh"
  [ -f "$gate_check" ] || {
    echo "gate-check.sh not found"
    return 1
  }
  grep -q 'EXEC_NO_ARTIFACT' "$gate_check" || {
    echo "gate-check.sh missing artifact guard"
    return 1
  }
}

test_gate_check_has_entry_mode() {
  local gate_check="$LIB_DIR/gate-check.sh"
  [ -f "$gate_check" ] || return 1
  grep -q '_gate_entry' "$gate_check" || {
    echo "gate-check.sh missing entry mode"
    return 1
  }
}

test_gate_check_has_reapprove_mode() {
  local gate_check="$LIB_DIR/gate-check.sh"
  [ -f "$gate_check" ] || return 1
  grep -q '_gate_reapprove' "$gate_check" || {
    echo "gate-check.sh missing reapprove mode"
    return 1
  }
}

# ── Outcome-label-check.sh tests ────────────────────────────────────────────────

test_outcome_check_exists() {
  [ -f "$LIB_DIR/outcome-label-check.sh" ] || {
    echo "outcome-label-check.sh not found"
    return 1
  }
}

test_outcome_check_has_label_detection() {
  local oc="$LIB_DIR/outcome-label-check.sh"
  [ -f "$oc" ] || return 1
  grep -q 'Smooth\|Rough\|Hard' "$oc" || {
    echo "outcome-label-check.sh missing label detection"
    return 1
  }
}

# ── Gate reconcile ─────────────────────────────────────────────────────────────

test_gate_reconcile_skill_exists() {
  [ -f "$SKILLS_DIR/ticket-gate-reconcile/SKILL.md" ] || {
    echo "ticket-gate-reconcile skill not found"
    return 1
  }
}

test_gate_reconcile_has_context_loading() {
  local skill_md="$SKILLS_DIR/ticket-gate-reconcile/SKILL.md"
  [ -f "$skill_md" ] || return 1
  # Context loading moved into lib/gate-reconcile-prep.sh
  # (skill-deterministic-extraction 6a), which sources the env file.
  grep -q 'lib/gate-reconcile-prep.sh {TICKET-ID}' "$skill_md" &&
    grep -q 'source "$_GR_DIR/ticket-env.sh" "$TID"' "$LIB_DIR/gate-reconcile-prep.sh" || {
    echo "gate-reconcile missing env.sh context loading"
    return 1
  }
}

# The openspec plan artifact lives at the tickets-repo root (cwd — where
# ticket-appraise-exec writes it), never under TICKET_DIR, and must be THIS
# ticket's change — not whichever dir `ls | head -1` lists first. Runs the
# resolution for real: lib/gate-reconcile-prep.sh, which replaced the skill's
# Step 1 block (skill-deterministic-extraction 6a), against fixture trees.
_gate_reconcile_resolve() {
  # $1 = cwd, $2 = ARTIFACT_TYPE, $3 = ticket id; echoes ARTIFACT_PATH
  mkdir -p "$1/logs" && mkdir -p -m 700 "$1/.scratch"
  echo "2026-01-01T00:00:00Z|EXEC|create-artifact|done|$2" >>"$1/logs/$3-pipeline.log"
  echo '[]' >"$1/.comments.json"
  (cd "$1" && env -u LINEAR_API_KEY -u LOG_FILE -u TAP_LOG HOME="$1" TICKET_TMP_DIR="$1/.scratch" \
    bash "$LIB_DIR/gate-reconcile-prep.sh" "$3" --comments-file .comments.json) | sed -n 's/^ARTIFACT_PATH=//p'
  return "${PIPESTATUS[0]}"
}

test_gate_reconcile_artifact_resolves_own_change_at_repo_root() {
  local tmp out rc=0
  tmp=$(mktemp -d)
  mkdir -p "$tmp/logs" "$tmp/TEST-7--ticket-dir/openspec/changes/aaa-wrong" \
    "$tmp/openspec/changes/aaa-other-change" "$tmp/openspec/changes/test-77-not-me" \
    "$tmp/openspec/changes/test-7-fix-thing"
  touch "$tmp/openspec/changes/test-7-fix-thing/tasks.md" \
    "$tmp/openspec/changes/aaa-other-change/tasks.md" \
    "$tmp/openspec/changes/test-77-not-me/tasks.md"
  out=$(_gate_reconcile_resolve "$tmp" openspec TEST-7) || rc=1
  [ "$out" = "openspec/changes/test-7-fix-thing/tasks.md" ] || {
    echo "resolved '$out' (want openspec/changes/test-7-fix-thing/tasks.md)"
    rc=1
  }
  rm -rf "$tmp"
  return $rc
}

test_gate_reconcile_artifact_missing_change_fails_loudly() {
  local tmp rc=0
  tmp=$(mktemp -d)
  mkdir -p "$tmp/logs" "$tmp/openspec/changes/aaa-other-change"
  touch "$tmp/openspec/changes/aaa-other-change/tasks.md"
  if _gate_reconcile_resolve "$tmp" openspec TEST-7 >/dev/null 2>&1; then
    echo "resolution succeeded with no change for the ticket"
    rc=1
  fi
  grep -q '|GATE|reconcile|fail|.*TEST-7' "$tmp/logs/TEST-7-pipeline.log" 2>/dev/null || {
    echo "no GATE|reconcile|fail line logged"
    rc=1
  }
  rm -rf "$tmp"
  return $rc
}

test_gate_reconcile_artifact_simple_fix_unchanged() {
  local tmp out rc=0
  tmp=$(mktemp -d)
  mkdir -p "$tmp/logs" "$tmp/TEST-7--ticket-dir"
  touch "$tmp/TEST-7--ticket-dir/simple-fix.md"
  out=$(_gate_reconcile_resolve "$tmp" simple-fix TEST-7) || rc=1
  [ "$out" = "./TEST-7--ticket-dir/simple-fix.md" ] || {
    echo "resolved '$out'"
    rc=1
  }
  rm -rf "$tmp"
  return $rc
}

# hb_write rejects any status outside heartbeat.sh's _HB_STATUSES enum and
# writes nothing, so a skill calling `hb-wrap.sh gate X start ...` silently
# loses the entry. Scan every literal hb-wrap.sh call in skills/agents (the
# `heartbeat` category ignores its status slot, so it is exempt).
test_hb_wrap_callers_use_valid_statuses() {
  local valid
  valid=$(sed -n 's/^_HB_STATUSES="\(.*\)"$/\1/p' "$LIB_DIR/heartbeat.sh")
  [ -n "$valid" ] || {
    echo "could not read _HB_STATUSES from heartbeat.sh"
    return 1
  }
  local bad=""
  local hit file cat status
  while IFS= read -r hit; do
    file=${hit%%:*}
    cat=$(echo "$hit" | sed -E 's/.*hb-wrap\.sh +"?([a-z]+)"? .*/\1/')
    status=$(echo "$hit" | sed -E 's/.*hb-wrap\.sh +"?[a-z]+"? +"?[^" ]+"? +"?([a-z]+)"?.*/\1/')
    [ "$cat" = "heartbeat" ] && continue
    case " $valid " in
    *" $status "*) ;;
    *) bad="$bad $file:$cat:$status" ;;
    esac
  done < <(grep -rhoE --with-filename 'hb-wrap\.sh +"?[a-z]+"? +"?[^" ]+"? +"?[a-z]+"?' \
    "$SKILLS_DIR" "$LIB_DIR/../agents" 2>/dev/null)
  [ -z "$bad" ] || {
    echo "hb-wrap.sh called with invalid status:$bad (valid: $valid)"
    return 1
  }
}

# ── Increment B — silent-skip & false-done fixes (R3, R9, R2) ─────────────────

# skill-glue-collapse: the pasted resolver became a flow-run.sh call. flow-run.sh
# owns the plugin-cache fallback (tap_cache_find) and the failure record
# (META|flow-error + retry heartbeat, incl. 127 for flow.sh not found) — both
# pinned by test-flow-run.sh. Here: the block delegates and adds no swallow.
test_router_implement_complete_has_plugin_cache_fallback() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/Then transition from Ready/,/^```$/p' "$skill_md")
  grep -q 'flow-run\.sh --log-file "{LOG_FILE}" "{TICKET_ID}" implement-complete' <<<"$block" || {
    echo "implement-complete is not fired through lib/flow-run.sh"
    return 1
  }
  grep -q 'installPath' <<<"$block" && {
    echo "implement-complete still carries an inline flow.sh resolver"
    return 1
  }
  grep -q '|| true' <<<"$block" && {
    echo "implement-complete flow.sh resolution still swallows failure with || true"
    return 1
  }
  return 0
}

# The prescan gate and STEP_6 retro-trigger prose tests (#149, #318, #411,
# late-resume skip, success judged by returned content) moved with the code:
# lib/tests/test-prescan-run.sh and lib/tests/test-router-step.sh assert the
# behaviour of lib/prescan-run.sh and `router-step.sh retro-check` against
# fixtures lifted from the pre-extraction SKILL.md (skill-deterministic-extraction 3).

test_router_verify_dispatch_uses_verdict_tokens() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_5 —/,/### STEP_4_6 —/p' "$skill_md")
  grep -q 'VERDICT=PASS' <<<"$block" || {
    echo "STEP_4_5 does not pass VERDICT=PASS on verify success"
    return 1
  }
  grep -q 'VERDICT=FAIL' <<<"$block" || {
    echo "STEP_4_5 does not pass VERDICT=FAIL on verify failure"
    return 1
  }
}

test_router_verify_checks_verify_last_before_dispatch() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_5 —/,/### STEP_4_6 —/p' "$skill_md")
  grep -q '{VERIFY_LAST}' <<<"$block" || {
    echo "STEP_4_5 does not branch on VERIFY_LAST"
    return 1
  }
  grep -qi 're-implement' <<<"$block" || {
    echo "STEP_4_5 does not dispatch re-implement when VERIFY_LAST=fail"
    return 1
  }
}

test_router_pr_review_dispatch_uses_verdict_tokens() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_6 —/,/### Auto-merge logic/p' "$skill_md")
  grep -q 'VERDICT=OK' <<<"$block" || {
    echo "STEP_4_6 does not map ✅ to VERDICT=OK"
    return 1
  }
  grep -q 'VERDICT=WARN' <<<"$block" || {
    echo "STEP_4_6 does not map ⚠️ to VERDICT=WARN"
    return 1
  }
  grep -q 'VERDICT=BLOCK' <<<"$block" || {
    echo "STEP_4_6 does not map ❌ to VERDICT=BLOCK"
    return 1
  }
}

test_detect_resume_iteration_uses_warn_token() {
  local src="$LIB_DIR/../skills/ticket-detect-resume/detect-resume.sh"
  [ -f "$src" ] || return 1
  grep -q "PR-REVIEW|pr-review|done|WARN" "$src" || {
    echo "ITERATION no longer counts the WARN verdict token"
    return 1
  }
  grep -q 'Verdict.\*⚠️' "$src" && {
    echo "ITERATION still coupled to byte-exact emoji match"
    return 1
  }
  return 0
}

test_detect_resume_outputs_verify_last() {
  local src="$LIB_DIR/../skills/ticket-detect-resume/detect-resume.sh"
  [ -f "$src" ] || return 1
  grep -q 'VERIFY_LAST:' "$src" || {
    echo "detect-resume.sh does not emit VERIFY_LAST"
    return 1
  }
}

# The router's auto-merge decision lives in lib/auto-merge.sh (DET-RV-4); its
# behaviour is pinned by test-auto-merge.sh. These two keep the source-level
# guards they always were, pointed at where the logic now lives.
test_router_auto_merge_covers_auto_and_semi_auto() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md" src="$LIB_DIR/auto-merge.sh"
  [ -f "$skill_md" ] && [ -f "$src" ] || return 1
  sed -n '/### Auto-merge logic/,/^### STEP_5/p' "$skill_md" | grep -q 'auto-merge.sh' || {
    echo "router auto-merge does not delegate to lib/auto-merge.sh"
    return 1
  }
  grep -qE '^ *auto \| semi-auto\)' "$src" || {
    echo "auto-merge.sh no longer covers AUTONOMY=auto and semi-auto"
    return 1
  }
}

test_router_auto_merge_reads_outcome_label_not_implement_line() {
  local src="$LIB_DIR/auto-merge.sh"
  [ -f "$src" ] || return 1
  local block
  block=$(cat "$src")
  grep -q 'META|outcome-label|info|' <<<"$block" || {
    echo "auto-merge does not read the authoritative outcome-label META line"
    return 1
  }
  grep -q "IMPLEMENT|implement|done|" <<<"$block" && {
    echo "auto-merge still reads OUTCOME from the implement terminal line"
    return 1
  }
  return 0
}

test_outcome_label_check_writes_meta_line() {
  local src="$LIB_DIR/outcome-label-check.sh"
  [ -f "$src" ] || return 1
  grep -q 'META" "outcome-label" "info"' "$src" || {
    echo "outcome-label-check.sh does not write META|outcome-label"
    return 1
  }
}

# ── Increment F — hygiene batch (R10, R11, R12, R13) ──────────────────────────

test_router_pr_feedback_cycle_caps_at_3() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_5_5 —/,/^### STEP_6/p' "$skill_md")
  grep -q '{PR_FEEDBACK_CYCLE}" -ge 3' <<<"$block" || {
    echo "STEP_5_5 does not cap PR_FEEDBACK_CYCLE at 3"
    return 1
  }
  grep -q 'PR_FEEDBACK_EXHAUSTED' <<<"$block" || {
    echo "STEP_5_5 does not gate-stop with PR_FEEDBACK_EXHAUSTED"
    return 1
  }
}

test_router_pr_reconcile_emits_cycle_marker() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_5_5 —/,/^### STEP_6/p' "$skill_md")
  grep -q 'MSG="cycle#' <<<"$block" || {
    echo "STEP_5_5 does not emit a cycle# marker for PR_FEEDBACK_CYCLE to count"
    return 1
  }
}

test_router_reconcile_cycle_caps_at_3() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_3_5 —/,/^### STEP_4/p' "$skill_md")
  grep -q '{RECONCILE_CYCLE}" -ge 3' <<<"$block" || {
    echo "STEP_3_5 does not cap RECONCILE_CYCLE at 3"
    return 1
  }
  grep -q 'RECONCILE_EXHAUSTED' <<<"$block" || {
    echo "STEP_3_5 does not gate-stop with RECONCILE_EXHAUSTED"
    return 1
  }
}

# test_router_autonomy_write_is_guarded pinned Step 0.6's inline META|autonomy
# write; the guarded write (mode-change instead of a re-append) now lives in
# lib/ticket-preamble.sh and is covered by test-ticket-preamble.sh's
# test_autonomy_change_is_logged_not_overwritten.

# Replaces test_router_dashboard_pane_not_duplicated. The router no longer
# spawns a dashboard pane at all (fleetd-phase-supervisor task 7.4), so the
# duplicate-pane guard it used to assert on has nothing left to guard: the
# guard only existed because every resume spawned another pane. What matters
# now is that the spawn does not come back — under fleetd that was one tmux
# pane per ticket, each showing a single ticket.
test_router_does_not_spawn_a_dashboard_pane() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  # A blunt literal search, which is why the prose above it in SKILL.md is
  # worded to avoid the command: the guard is only useful if it cannot be
  # satisfied by a passing mention.
  grep -q 'tmux split-window' "$skill_md" && {
    echo "router still spawns a tmux dashboard pane"
    return 1
  }
  # It must still tell the operator how to open one, including the fleet view.
  # The command text comes from the preamble's DASHBOARD_CMD_FLEET field
  # (value pinned by test-ticket-preamble.sh test_dashboard_fields_only_in_new_run_mode).
  grep -q 'DASHBOARD_CMD_FLEET' "$skill_md" || {
    echo "router does not surface the --fleet dashboard command"
    return 1
  }
}

# ── Issue #293 — approve-gate open-questions messaging ────────────────────────

test_appraise_exec_comment_warns_on_needs_human_questions() {
  local skill_md="$SKILLS_DIR/ticket-appraise-exec/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^## Step 5 — Post a Linear comment/,/^## Step 6/p' "$skill_md")
  grep -q '\[needs-human\]' <<<"$block" || {
    echo "Step 5 comment template does not mention [needs-human] gating"
    return 1
  }
  grep -qi "before running \`/ticket-approve\`" <<<"$block" || {
    echo "Step 5 comment template does not warn to answer before approving"
    return 1
  }
  grep -qi 'gate-reconcile' <<<"$block" || {
    echo "Step 5 comment template does not mention the extra gate-reconcile hold cycle"
    return 1
  }
  # Must be explicitly conditioned on the tag being present — a blanket line
  # would fire even on tickets with no open questions at all.
  grep -qi 'omit the warning' <<<"$block" || {
    echo "Step 5 does not gate the warning line on [needs-human] presence"
    return 1
  }
}

test_router_gate_held_message_mentions_open_questions() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_2_5 — Gate Check/,/^### STEP_3/p' "$skill_md")
  grep -qi 'Open Questions' <<<"$block" || {
    echo "STEP_2_5 gate-held message does not mention Open Questions"
    return 1
  }
  grep -qi 'approved' <<<"$block" || {
    echo "STEP_2_5 gate-held message does not mention the approved label"
    return 1
  }
  grep -qi 'gate-reconcile\|hold' <<<"$block" || {
    echo "STEP_2_5 gate-held message does not warn about a re-hold on next resume"
    return 1
  }
}

# Steps 0.1–0.6 are one ticket-preamble.sh call (spec: router-preamble-manual-mode,
# "Skill contains one preamble invocation"). NEW_RUN=true is what makes the
# preamble stamp run identity with --new (replaces
# test_router_run_identity_stamp_reference; the --new behaviour itself is
# test-ticket-preamble.sh test_new_run_opens_a_run_where_the_default_rehydrates).
test_router_step0_is_one_preamble_call_with_new_run() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local calls
  calls=$(grep -c 'bash ~/.claude/skills/lib/ticket-preamble.sh ' "$skill_md")
  [ "$calls" -eq 1 ] || {
    echo "expected exactly one ticket-preamble.sh invocation, found $calls"
    return 1
  }
  grep 'bash ~/.claude/skills/lib/ticket-preamble.sh ' "$skill_md" |
    grep -q 'TICKET_ARG="{TICKET_ARG}" NEW_RUN=true ANNOUNCE_START=true' || {
    echo "preamble call does not pass TICKET_ARG, NEW_RUN=true and ANNOUNCE_START=true"
    return 1
  }
  # The steps it replaces must not come back as inline bash.
  if grep -qE 'run-identity\.sh stamp|resolve_branch_context \$|validate-linear-config\.sh" "\$TEAM_ID"|\|META\|autonomy\|info\|\{AUTONOMY\}' "$skill_md"; then
    echo "SKILL.md restates a step the preamble owns"
    return 1
  fi
  # Every preamble exit code is handled.
  local code
  for code in 2 3 4 5 6; do
    grep -qE "^\| $code \|" "$skill_md" || {
      echo "exit code $code not documented"
      return 1
    }
  done
}

# ── Commercial Evidence MVP (Branch B): pr-created capture ──────────────────

test_ticket_verify_captures_pr_created() {
  local skill_md="$SKILLS_DIR/ticket-verify/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'record_pr_created' "$skill_md" || {
    echo "ticket-verify SKILL.md does not capture META|pr-created"
    return 1
  }
}

# Both the new-PR (gh pr create) and existing-PR (gh pr list) branches must
# feed the same _pr_url capture — a single downstream META|pr-created append
# covering both, per the runs-jsonl-evidence spec's two scenarios.
test_ticket_verify_pr_created_covers_both_branches() {
  local skill_md="$SKILLS_DIR/ticket-verify/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/existing_pr=\$(cd/,/record_pr_created --new/p' "$skill_md")
  grep -q '_pr_url="\$existing_pr"' <<<"$block" || {
    echo "existing-PR branch does not set _pr_url for pr-created capture"
    return 1
  }
  grep -q '_pr_url=\$(cd' <<<"$block" || {
    echo "new-PR branch does not set _pr_url for pr-created capture"
    return 1
  }
}

# ── issue #415: verify re-fires implement-complete under --from-auto ────────

# ticket-auto's router fires implement-complete itself after every IMPLEMENT
# (STEP_4's post-dispatch flow_trigger). ticket-verify's local close-out used
# to fire it again unconditionally, so every --from-auto run logged a spurious
# ILLEGAL_TRANSITION from Review and emitted a duplicate implement-completed
# event. The close-out item must be gated off under --from-auto, and the agent
# definition must not mandate the call unconditionally.
test_ticket_verify_local_closeout_skips_implement_complete_under_from_auto() {
  local skill_md="$SKILLS_DIR/ticket-verify/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local item
  # Item 4 of the local close-out: from its "4." line up to item 5.
  item=$(sed -n '/^### If `--env local`: Open PR and close out/,/^### If `--env uat`/p' "$skill_md" |
    sed -n '/^4\. /,/^5\. /p')
  grep -q 'flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} implement-complete' <<<"$item" || {
    echo "local close-out item 4 no longer fires implement-complete (test anchor drifted)"
    return 1
  }
  echo "$item" | head -1 | grep -q 'If `--from-auto` is present: skip this item' || {
    echo "local close-out item 4 fires implement-complete without a --from-auto skip"
    return 1
  }
  local agent_md="$SKILLS_DIR/../agents/ticket-verify-agent.md"
  [ -f "$agent_md" ] || return 1
  grep 'implement-complete' "$agent_md" | grep -q 'only on a standalone run' || {
    echo "ticket-verify-agent.md mandates implement-complete without excluding --from-auto"
    return 1
  }
}

# The other half of the contract: the trigger verify now defers to must still
# be fired by the router's STEP_4 post-dispatch chain, or skipping it in verify
# would strand a --from-auto ticket in Ready.
test_router_owns_implement_complete_after_implement() {
  local dt="$SKILLS_DIR/ticket-flow/dispatch-table.json"
  [ -f "$dt" ] || return 1
  jq -e '.steps[] | select(.step_id == "STEP_4") | .post_dispatch[]
    | select(.kind == "flow_trigger" and .trigger == "implement-complete")' "$dt" >/dev/null || {
    echo "dispatch-table STEP_4 no longer fires implement-complete"
    return 1
  }
}

# ── issue #366: PR_REVIEW_REPO_UNSCOPED ─────────────────────────────────────

# Step 3's gh pr list must carry an explicit --repo. Without it, gh falls back
# to cwd-based repo resolution — and the shared preamble guard forces cwd to
# the `tickets` workspace, a repo with no code PRs, so the search always
# returned [] regardless of whether a PR existed.
test_ticket_pr_review_gh_pr_list_scoped_to_repo() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^## Step 3 /,/^## Step 4 /p' "$skill_md")
  grep -q 'PR_LIST=\$(gh pr list --repo "\$GH_REPO"' <<<"$block" || {
    echo "Step 3 gh pr list is not scoped with --repo \$GH_REPO"
    return 1
  }
}

# Regression guard: no bare, unscoped `gh pr list --search ... in:head` should
# remain anywhere in the skill (the exact shape of the original bug).
test_ticket_pr_review_no_bare_unscoped_pr_list() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  if grep -qE '^PR_LIST=\$\(gh pr list --search' "$skill_md"; then
    echo "found a bare gh pr list with no --repo flag"
    return 1
  fi
}

# GH_REPO must be resolved (worktree, with a notes.md checkpoint fallback)
# before the PR search runs, not after — this was the whole bug: repo
# resolution existed in the skill already but ran too late to be useful.
test_ticket_pr_review_resolves_repo_before_search() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^## Step 3 /,/^## Step 4 /p' "$skill_md")
  local worktree_line search_line
  worktree_line=$(echo "$block" | grep -n 'WORKTREE_PATH=\$(worktree_path' | head -1 | cut -d: -f1)
  search_line=$(echo "$block" | grep -n 'PR_LIST=\$(gh pr list' | head -1 | cut -d: -f1)
  [ -n "$worktree_line" ] && [ -n "$search_line" ] || {
    echo "could not locate both worktree resolution and PR search lines"
    return 1
  }
  [ "$worktree_line" -lt "$search_line" ] || {
    echo "worktree/repo resolution does not run before the PR search"
    return 1
  }
}

# Missing-repo case must still stop cleanly with a user-facing message,
# per the issue's verification checklist ("still stops correctly when the
# PR genuinely does not exist").
test_ticket_pr_review_unresolvable_repo_stops() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^## Step 3 /,/^## Step 4 /p' "$skill_md")
  grep -q 'Cannot resolve the code repo' <<<"$block" || {
    echo "no unresolvable-repo stop message found in Step 3"
    return 1
  }
}

# ── issue #365 / GitHub #412: Step 6a/6b ───────────────────────────────────
# The Step 6a transition and the Step 6b merge gate are scripts now
# (skill-deterministic-extraction 2). Their prose-grep tests became behavioural
# tests with a mocked gh / flow.sh: test-pr-merge-gate.sh (checks JSON schema,
# checkless PR, fail-closed checks command, bucket evaluation, State/Bucket
# report table, shared merge rule) and test-pr-review-transition.sh (merge
# authorization before the transition, --merge-pending, epic policy).

# ── dispatcher ─────────────────────────────────────────────────────────────────

filter="${1:-}"

for func in $(declare -F | grep '^declare -f test_' | sed 's/declare -f //'); do
  if [ -z "$filter" ] || grep -q "$filter" <<<"$func"; then
    _run "$func" "$func"
  fi
done

echo "---"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
