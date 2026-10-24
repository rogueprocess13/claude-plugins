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
  echo "$section" | grep -qi 'implement' || {
    echo "STEP_4 not associated with implement"
    return 1
  }
}

test_router_step_4_6_is_pr_review() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_4_6/,/^### /p' "$skill_md" 2>/dev/null)
  echo "$section" | grep -qiE 'pr.review|PR Review' || {
    echo "STEP_4_6 not associated with PR review"
    return 1
  }
}

test_router_step_5_is_document_wiki() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_5 —\|### STEP_5$/,/^### /p' "$skill_md" 2>/dev/null)
  echo "$section" | grep -qiE 'document|wiki|maintenance' || {
    echo "STEP_5 not associated with document/wiki"
    return 1
  }
}

test_router_step_6_is_report() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_6/,/^---/p' "$skill_md" 2>/dev/null)
  echo "$section" | grep -qiE 'retro|report|outcome' || {
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

test_router_team_resolution_query_failure_message() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local preflight
  preflight=$(sed -n '/Step 0.4 — Preflight/,/^## /p' "$skill_md" 2>/dev/null)
  echo "$preflight" | grep -qE '\^\[0-9\]\+\$' || {
    echo "team_count numeric-format guard not found (query-failure detection)"
    return 1
  }
  echo "$preflight" | grep -qi 'teams query failed' || {
    echo "distinct query-failure message not found"
    return 1
  }
}

test_router_team_resolution_multi_team_message_unchanged() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'Multiple Linear teams — set LINEAR_TEAM_ID' "$skill_md" || {
    echo "genuine multi-team message missing or changed"
    return 1
  }
}

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
  grep -q 'source /tmp/ticket-auto' "$skill_md" && grep -q 'env.sh' "$skill_md" || {
    echo "gate-reconcile missing env.sh context loading"
    return 1
  }
}

# The openspec plan artifact lives at the tickets-repo root (cwd — where
# ticket-appraise-exec writes it), never under TICKET_DIR, and must be THIS
# ticket's change — not whichever dir `ls | head -1` lists first. Executes the
# skill's real resolution block against fixture trees.
_gate_reconcile_artifact_code() {
  sed -n '/^Resolve the plan artifact/,/^## Step 2/p' "$SKILLS_DIR/ticket-gate-reconcile/SKILL.md" |
    sed -n '/^```bash$/,/^```$/p' | sed '1d;$d'
}

_gate_reconcile_resolve() {
  # $1 = cwd, $2 = ARTIFACT_TYPE, $3 = ticket id; echoes ARTIFACT_PATH
  local code
  code=$(_gate_reconcile_artifact_code)
  [ -n "$code" ] || return 3
  code=${code//\{TICKET-ID\}/$3}
  # The block logs through the synced ~/.claude/skills/lib/plog.sh; point it
  # at this checkout's lib (CI has no synced copy).
  code=${code//\~\/.claude\/skills\/lib\//$LIB_DIR/}
  (
    cd "$1" || exit 3
    # Step 1's load block sources ticket-dir.sh before this block runs; the
    # resolution block calls its resolve_plan_artifact. Step 1 also exports
    # LOG_FILE, which plog.sh reads from the environment.
    source "$LIB_DIR/ticket-dir.sh"
    export LOG_FILE="$1/logs/pipeline.log"
    TICKET_DIR="$1/TEST-7--ticket-dir"
    ARTIFACT_TYPE="$2"
    eval "$code"
    echo "$ARTIFACT_PATH"
  )
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
  grep -q '|GATE|reconcile|fail|.*TEST-7' "$tmp/logs/pipeline.log" 2>/dev/null || {
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
  [ "$out" = "$tmp/TEST-7--ticket-dir/simple-fix.md" ] || {
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
  echo "$block" | grep -q 'flow-run\.sh --log-file "{LOG_FILE}" "{TICKET_ID}" implement-complete' || {
    echo "implement-complete is not fired through lib/flow-run.sh"
    return 1
  }
  echo "$block" | grep -q 'installPath' && {
    echo "implement-complete still carries an inline flow.sh resolver"
    return 1
  }
  echo "$block" | grep -q '|| true' && {
    echo "implement-complete flow.sh resolution still swallows failure with || true"
    return 1
  }
  return 0
}

test_router_prescan_success_judged_by_content() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/spawn_capture TICKET_ID={TICKET-ID} PHASE=MAINTENANCE/,/flock -u/p' "$skill_md")
  # Success must be judged by the agent's returned CONTENT, not by spawn_capture's
  # exit code. The return now arrives as a file (RESULT_FILE=, quoted heredoc) rather
  # than an interpolated "$AGENT_RESULT" argument, so the content check greps the file.
  echo "$block" | grep -q 'grep -q "\$slug: scanned" /tmp/ticket-auto-{TICKET-ID}-agent-return.txt' || {
    echo "prescan success no longer judged by the agent's returned content"
    return 1
  }
  echo "$block" | grep -qE '\bif \[ \$\? -eq 0 \]' && {
    echo "prescan success still judged by spawn_capture exit code"
    return 1
  }
  return 0
}

test_router_retro_condition_2_uses_success_markers() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/Condition 2: did the ticket NOT reach/,/^fi/p' "$skill_md")
  echo "$block" | grep -q 'VERIFY|verify|done|PASS' || {
    echo "retro condition 2 does not check verify PASS marker"
    return 1
  }
  # PR-REVIEW's own Verdict tokens are OK/WARN/BLOCK, never PASS (that's
  # VERIFY-only) — GitHub #149. N/A is also a legitimate success marker
  # (verification-only ticket, no PR to review) — GitHub #318.
  echo "$block" | grep -qF 'PR-REVIEW\|pr-review\|done\|(OK|N/A)' || {
    echo "retro condition 2 does not check PR-review OK/N-A marker"
    return 1
  }
  echo "$block" | grep -q 'PR-REVIEW|pr-review|done|PASS' && {
    echo "retro condition 2 still checks the non-existent PR-review PASS token"
    return 1
  }
  echo "$block" | grep -q 'META|outcome|info|completed:' && {
    echo "retro condition 2 still tests the tautological outcome marker"
    return 1
  }
  return 0
}

# GitHub #318 — a verification-only ticket (IMPLEMENT made no source diff) has
# no PR to review, so ticket-pr-review writes `done|N/A` directly instead of a
# false "no PR found" stop. STEP_6's Condition 2 must not flag that as
# retro-worthy. These tests eval the *actual* extracted condition against a
# synthetic log — not just a string match on the SKILL.md prose — so a future
# edit that reintroduces the #149-style false positive is caught here too.
_extract_retro_condition_2() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  sed -n '/Condition 2: did the ticket NOT reach/,/^fi/p' "$skill_md" | grep -v '^#'
}

test_router_retro_condition_2_accepts_n_a_marker() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local cond
  cond="$(_extract_retro_condition_2)"
  [ -n "$cond" ] || return 1

  local log
  log=$(mktemp)
  printf '%s\n' \
    '2026-09-07T19:50:00Z|VERIFY|verify|done|PASS' \
    '2026-09-07T19:54:53Z|PR-REVIEW|pr-review|done|N/A — no PR (verification-only ticket, no source diff produced by IMPLEMENT)' \
    >"$log"

  local NEEDS_RETRO=false
  eval "${cond//\{LOG_FILE\}/$log}"
  rm -f "$log"

  [ "$NEEDS_RETRO" = "false" ] || {
    echo "retro condition 2 flags a clean N/A (no-diff) outcome as retro-worthy"
    return 1
  }
}

test_router_retro_condition_2_still_flags_missing_pr_review() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local cond
  cond="$(_extract_retro_condition_2)"
  [ -n "$cond" ] || return 1

  local log
  log=$(mktemp)
  printf '%s\n' \
    '2026-09-07T19:50:00Z|VERIFY|verify|done|PASS' \
    >"$log"

  local NEEDS_RETRO=false
  eval "${cond//\{LOG_FILE\}/$log}"
  rm -f "$log"

  [ "$NEEDS_RETRO" = "true" ] || {
    echo "retro condition 2 no longer flags a ticket with no PR-REVIEW outcome at all"
    return 1
  }
}

test_router_verify_dispatch_uses_verdict_tokens() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_5 —/,/### STEP_4_6 —/p' "$skill_md")
  echo "$block" | grep -q 'VERDICT=PASS' || {
    echo "STEP_4_5 does not pass VERDICT=PASS on verify success"
    return 1
  }
  echo "$block" | grep -q 'VERDICT=FAIL' || {
    echo "STEP_4_5 does not pass VERDICT=FAIL on verify failure"
    return 1
  }
}

test_router_verify_checks_verify_last_before_dispatch() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_5 —/,/### STEP_4_6 —/p' "$skill_md")
  echo "$block" | grep -q '{VERIFY_LAST}' || {
    echo "STEP_4_5 does not branch on VERIFY_LAST"
    return 1
  }
  echo "$block" | grep -qi 're-implement' || {
    echo "STEP_4_5 does not dispatch re-implement when VERIFY_LAST=fail"
    return 1
  }
}

test_router_pr_review_dispatch_uses_verdict_tokens() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_6 —/,/### Auto-merge logic/p' "$skill_md")
  echo "$block" | grep -q 'VERDICT=OK' || {
    echo "STEP_4_6 does not map ✅ to VERDICT=OK"
    return 1
  }
  echo "$block" | grep -q 'VERDICT=WARN' || {
    echo "STEP_4_6 does not map ⚠️ to VERDICT=WARN"
    return 1
  }
  echo "$block" | grep -q 'VERDICT=BLOCK' || {
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
  echo "$block" | grep -q 'META|outcome-label|info|' || {
    echo "auto-merge does not read the authoritative outcome-label META line"
    return 1
  }
  echo "$block" | grep -q "IMPLEMENT|implement|done|" && {
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

test_router_retro_conditions_1_and_3_unchanged() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q "META|gate-stop|fail|" "$skill_md" || {
    echo "retro condition 1 (gate-stop) missing"
    return 1
  }
  grep -q "grep -q '|fallback|' \"{HB_LOG_FILE}\"" "$skill_md" || {
    echo "retro condition 3 (heartbeat fallback) missing or changed"
    return 1
  }
}

# ── Increment F — hygiene batch (R10, R11, R12, R13) ──────────────────────────

test_router_pr_feedback_cycle_caps_at_3() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_5_5 —/,/^### STEP_6/p' "$skill_md")
  echo "$block" | grep -q '{PR_FEEDBACK_CYCLE}" -ge 3' || {
    echo "STEP_5_5 does not cap PR_FEEDBACK_CYCLE at 3"
    return 1
  }
  echo "$block" | grep -q 'PR_FEEDBACK_EXHAUSTED' || {
    echo "STEP_5_5 does not gate-stop with PR_FEEDBACK_EXHAUSTED"
    return 1
  }
}

test_router_pr_reconcile_emits_cycle_marker() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_5_5 —/,/^### STEP_6/p' "$skill_md")
  echo "$block" | grep -q 'MSG="cycle#' || {
    echo "STEP_5_5 does not emit a cycle# marker for PR_FEEDBACK_CYCLE to count"
    return 1
  }
}

test_router_reconcile_cycle_caps_at_3() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_3_5 —/,/^### STEP_4/p' "$skill_md")
  echo "$block" | grep -q '{RECONCILE_CYCLE}" -ge 3' || {
    echo "STEP_3_5 does not cap RECONCILE_CYCLE at 3"
    return 1
  }
  echo "$block" | grep -q 'RECONCILE_EXHAUSTED' || {
    echo "STEP_3_5 does not gate-stop with RECONCILE_EXHAUSTED"
    return 1
  }
}

test_router_prescan_skipped_on_late_resume() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/## Prescan gate/,/### Identify affected repos/p' "$skill_md")
  echo "$block" | grep -q 'Skip on late resume' || {
    echo "prescan gate missing late-resume skip section"
    return 1
  }
  echo "$block" | grep -qE 'STEP_4 \| STEP_4_5 \| STEP_4_6' || {
    echo "prescan gate does not skip STEP_4+ resume steps"
    return 1
  }
}

# Issue #411 — a decayed/missing repo needs /ticket-prescan's Path A (an Agent
# fan-out), which the headless ticket-prescan-agent cannot run (no Agent tool).
# The router must only spawn for `stale` and log an actionable skip otherwise.
# Executes the gate's real case block from SKILL.md for each status.
test_router_prescan_spawns_only_for_stale() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local code
  code=$(sed -n '/^Branch on status:/,/^### Acquire lock and spawn/p' "$skill_md" |
    sed -n '/^```bash$/,/^```$/p' | sed '1d;$d')
  [ -n "$code" ] || {
    echo "prescan gate has no executable status-branch bash block"
    return 1
  }
  local tmp log
  tmp=$(mktemp -d)
  log="$tmp/pipeline.log"
  : >"$log"
  code=${code//\{LOG_FILE\}/$log}
  # The block logs through the synced ~/.claude/skills/lib/plog.sh; point it at
  # the checkout's lib (CI and dev hosts may have no synced copy).
  code=${code//\~\/.claude\/skills\/lib\//$LIB_DIR/}
  local reached
  reached=$(
    slug=repo-x
    repo=/r/repo-x
    for PRESCAN_STATUS in fresh stale decayed missing bogus; do
      eval "$code"
      echo "$PRESCAN_STATUS"
    done
  )
  local rc=0
  [ "$reached" = "stale" ] || {
    echo "spawn reached for statuses: $(echo "$reached" | tr '\n' ' ')(want: stale)"
    rc=1
  }
  grep -q '|MAINTENANCE|prescan|skip|repo-x decayed .*interactive /ticket-prescan' "$log" || {
    echo "decayed repo not logged as an actionable skip"
    rc=1
  }
  grep -q '|MAINTENANCE|prescan|skip|repo-x missing .*interactive /ticket-prescan' "$log" || {
    echo "missing repo not logged as an actionable skip"
    rc=1
  }
  grep -qE 'repo-x (fresh|stale)' "$log" && {
    echo "fresh/stale repo wrongly logged as a skip"
    rc=1
  }
  rm -rf "$tmp"
  return $rc
}

test_router_autonomy_write_is_guarded() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/Log the resolved autonomy mode/,/hb-wrap.sh gate "phase-transition"/p' "$skill_md")
  echo "$block" | grep -q '_recorded_autonomy' || {
    echo "autonomy write is not guarded by a recorded-value check"
    return 1
  }
  echo "$block" | grep -q 'mode-change' || {
    echo "autonomy write does not log an explicit mode-change event"
    return 1
  }
}

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
  grep -q 'dashboard.py --fleet' "$skill_md" || {
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
  echo "$block" | grep -q '\[needs-human\]' || {
    echo "Step 5 comment template does not mention [needs-human] gating"
    return 1
  }
  echo "$block" | grep -qi "before running \`/ticket-approve\`" || {
    echo "Step 5 comment template does not warn to answer before approving"
    return 1
  }
  echo "$block" | grep -qi 'gate-reconcile' || {
    echo "Step 5 comment template does not mention the extra gate-reconcile hold cycle"
    return 1
  }
  # Must be explicitly conditioned on the tag being present — a blanket line
  # would fire even on tickets with no open questions at all.
  echo "$block" | grep -qi 'omit the warning' || {
    echo "Step 5 does not gate the warning line on [needs-human] presence"
    return 1
  }
}

test_router_gate_held_message_mentions_open_questions() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_2_5 — Gate Check/,/^### STEP_3/p' "$skill_md")
  echo "$block" | grep -qi 'Open Questions' || {
    echo "STEP_2_5 gate-held message does not mention Open Questions"
    return 1
  }
  echo "$block" | grep -qi 'approved' || {
    echo "STEP_2_5 gate-held message does not mention the approved label"
    return 1
  }
  echo "$block" | grep -qi 'gate-reconcile\|hold' || {
    echo "STEP_2_5 gate-held message does not warn about a re-hold on next resume"
    return 1
  }
}

test_router_run_identity_stamp_reference() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'run-identity\.sh stamp' "$skill_md" || {
    echo "run-identity.sh stamp not referenced"
    return 1
  }
  grep -q -- '--new' "$skill_md" || {
    echo "router does not pass --new to run-identity.sh stamp"
    return 1
  }
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
  echo "$block" | grep -q '_pr_url="\$existing_pr"' || {
    echo "existing-PR branch does not set _pr_url for pr-created capture"
    return 1
  }
  echo "$block" | grep -q '_pr_url=\$(cd' || {
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
  echo "$item" | grep -q 'flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} implement-complete' || {
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
  echo "$block" | grep -q 'PR_LIST=\$(gh pr list --repo "\$GH_REPO"' || {
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
  echo "$block" | grep -q 'Cannot resolve the code repo' || {
    echo "no unresolvable-repo stop message found in Step 3"
    return 1
  }
}

# ── issue #365: PR_REVIEW_CHECKS_JSON_SCHEMA ────────────────────────────────

# `gh pr checks --json` on gh 2.x only accepts `bucket, completedAt, description,
# event, link, name, startedAt, state, workflow` — there is no `status` or
# `conclusion` field. Requesting them fails the command outright with
# `Unknown JSON field: "status"`, so Step 6b's CI gate must request the real
# field names.
test_ticket_pr_review_checks_uses_real_json_fields() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^\*\*If `_merge_blocked_reason` is empty\*\*/,/^\*\*If the array is empty/p' "$skill_md")
  echo "$block" | grep -q 'gh pr checks {number} --repo {owner}/{repo} --json name,state,bucket' || {
    echo "Step 6b gh pr checks does not request --json name,state,bucket"
    return 1
  }
}

# Regression guard: the non-existent `status`/`conclusion` fields must not
# reappear anywhere in the skill (the exact shape of the original bug).
test_ticket_pr_review_no_stale_status_conclusion_fields() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  if grep -qE -- '--json name,status,conclusion' "$skill_md"; then
    echo "found gh pr checks --json requesting the non-existent status,conclusion fields"
    return 1
  fi
}

# `gh pr checks --json ...` does NOT emit `[]` for a PR with zero configured
# checks — it exits non-zero with the plain-text stderr message
# "no checks reported on the '<branch>' branch" (populateStatusChecks in gh's
# own pkg/cmd/pr/checks/checks.go returns before any JSON is written). A
# blanket "non-zero exit = hard block" guard would therefore merge-block a
# legitimately checkless PR forever — exactly the case the issue's own
# Verification Checklist required excluded. These tests extract the actual
# `_checks_none` detection snippet from SKILL.md and eval it against
# simulated `gh` output, rather than grepping prose, so a future edit that
# reintroduces the regression is caught functionally.
_extract_checks_none_snippet() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  sed -n '/^if \[ "\$_checks_rc" -ne 0 \] && echo "\$_checks_json"/,/^fi$/p' "$skill_md"
}

test_ticket_pr_review_checks_none_snippet_exists() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local snippet
  snippet="$(_extract_checks_none_snippet)"
  [ -n "$snippet" ] || {
    echo "could not locate the _checks_none detection snippet in SKILL.md"
    return 1
  }
}

test_ticket_pr_review_no_checks_reported_is_not_blocked() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local snippet
  snippet="$(_extract_checks_none_snippet)"
  [ -n "$snippet" ] || return 1

  local _checks_json="no checks reported on the 'feature/foo' branch"
  local _checks_rc=8
  local _checks_none
  eval "$snippet"

  [ "$_checks_none" = "true" ] || {
    echo "gh's 'no checks reported' stderr is not recognized as a checkless PR (would merge-block forever)"
    return 1
  }
}

test_ticket_pr_review_other_command_failure_still_blocks() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local snippet
  snippet="$(_extract_checks_none_snippet)"
  [ -n "$snippet" ] || return 1

  local _checks_json="error connecting to api.github.com"
  local _checks_rc=1
  local _checks_none
  eval "$snippet"

  [ "$_checks_none" = "false" ] || {
    echo "an unrelated gh failure is being misclassified as a checkless PR (would silently merge)"
    return 1
  }
}

# The checkless-PR detection must run BEFORE the generic non-zero-exit hard
# block, or it can never fire — this is the whole point of the fix.
test_ticket_pr_review_checks_none_evaluated_before_hard_block() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^\*\*If `_merge_blocked_reason` is empty\*\*/,/^\*\*If the array is empty/p' "$skill_md")
  local none_line hard_block_line
  none_line=$(echo "$block" | grep -n '_checks_none=true' | head -1 | cut -d: -f1)
  hard_block_line=$(echo "$block" | grep -n 'treat this as a hard block' | head -1 | cut -d: -f1)
  [ -n "$none_line" ] && [ -n "$hard_block_line" ] || {
    echo "could not locate both the checkless-PR branch and the generic hard-block branch"
    return 1
  }
  [ "$none_line" -lt "$hard_block_line" ] || {
    echo "checkless-PR detection does not run before the generic hard-block guard"
    return 1
  }
}

# Step 6b must have an explicit guard for the checks command itself failing
# (non-zero exit or unparseable JSON) — the bug report's core complaint was
# that no such branch existed, so a command failure fell through to "no
# blocking checks found" and merged anyway.
test_ticket_pr_review_checks_command_failure_is_guarded() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^\*\*If `_merge_blocked_reason` is empty\*\*/,/^\*\*If the array is empty/p' "$skill_md")
  echo "$block" | grep -qi 'exited non-zero' || {
    echo "Step 6b does not guard against gh pr checks exiting non-zero"
    return 1
  }
  echo "$block" | grep -qi 'not valid JSON' || {
    echo "Step 6b does not guard against unparseable JSON output"
    return 1
  }
  echo "$block" | tr '\n' ' ' | grep -qi 'never as "no blocking checks' || {
    echo "Step 6b does not explicitly say a checks-command failure is a hard block, not a pass"
    return 1
  }
}

# The gate must be pinned to `bucket` (gh's stable rollup), block on
# fail/cancel/pending, and treat a legitimately empty checks array as
# not-a-failure — all three are explicit constraints in the issue's handover
# package.
test_ticket_pr_review_checks_bucket_evaluation() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^\*\*If `_merge_blocked_reason` is empty\*\*/,/^\*\*If the array is empty/p' "$skill_md")
  echo "$block" | grep -q '`fail`, `cancel`.*hard block' || {
    echo "Step 6b does not treat fail/cancel bucket as a hard block"
    return 1
  }
  echo "$block" | grep -q '`pending`.*blocks the merge' || {
    echo "Step 6b does not treat pending bucket as blocking (still running)"
    return 1
  }
  echo "$block" | grep -qi 'no configured.*checks.*not a failure\|legitimately not a failure' || {
    echo "Step 6b does not tolerate a legitimately empty checks array"
    return 1
  }
}

test_ticket_pr_review_checks_report_table_uses_state_bucket() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^\*\*If any check has a blocking bucket/,/^Post the same message as a PR comment\./p' "$skill_md")
  echo "$block" | grep -q '| Check | State | Bucket |' || {
    echo "failing-checks report table no longer reports State/Bucket columns"
    return 1
  }
}

# ── GitHub #412: merge authorization before the Review transition ───────────

# Step 6a must evaluate merge authorization (merge_blocked_reason) and pass
# --merge-pending to uat_decide_trigger BEFORE /ticket-flow fires the trigger —
# otherwise a PR left for a human merge closes the ticket to Done first.
test_ticket_pr_review_step6a_merge_pending_before_transition() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^### Step 6a/,/^### Step 6b/p' "$skill_md")
  local reason_ln trigger_ln flow_ln
  reason_ln=$(echo "$block" | grep -n 'merge_blocked_reason "{TICKET-ID}"' | head -1 | cut -d: -f1)
  trigger_ln=$(echo "$block" | grep -n 'uat_decide_trigger --policy "$policy" ${_merge_pending_flag}' | head -1 | cut -d: -f1)
  flow_ln=$(echo "$block" | grep -n 'flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} "$trigger"' | head -1 | cut -d: -f1)
  [ -n "$reason_ln" ] && [ -n "$trigger_ln" ] && [ -n "$flow_ln" ] || {
    echo "Step 6a missing merge_blocked_reason / --merge-pending / trigger call"
    return 1
  }
  [ "$reason_ln" -lt "$trigger_ln" ] && [ "$trigger_ln" -lt "$flow_ln" ] || {
    echo "Step 6a computes merge authorization after the transition fires"
    return 1
  }
}

# Step 6b must use the same shared function rather than a second inline copy
# of the rule, so the two steps cannot disagree.
test_ticket_pr_review_step6b_uses_shared_merge_rule() {
  local skill_md="$SKILLS_DIR/ticket-pr-review/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/^### Step 6b/,/^\*\*If `_merge_blocked_reason` is non-empty/p' "$skill_md")
  echo "$block" | grep -q '_merge_blocked_reason=$(merge_blocked_reason "{TICKET-ID}")' || {
    echo "Step 6b does not call merge_blocked_reason"
    return 1
  }
}

# ── dispatcher ─────────────────────────────────────────────────────────────────

filter="${1:-}"

for func in $(declare -F | grep '^declare -f test_' | sed 's/declare -f //'); do
  if [ -z "$filter" ] || echo "$func" | grep -q "$filter"; then
    _run "$func" "$func"
  fi
done

echo "---"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
