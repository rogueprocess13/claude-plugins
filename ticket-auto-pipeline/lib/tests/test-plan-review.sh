#!/usr/bin/env bash
# test-plan-review.sh — the router's independent plan review, STEP_2_2
# (GitHub #667): lib/plan-review.sh, its routing in detect-resume.sh, the
# dispatch-table step, and the text that turns the inline review off.
#
# No model runs here. The reviewer's result file is written by the test, the
# way ticket-plan-review-agent writes it.
#
# Usage: bash test-plan-review.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

PR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_LIB_DIR="$(cd "$PR_TEST_DIR/.." && pwd)"
PR_PLUGIN_DIR="$(cd "$PR_LIB_DIR/.." && pwd)"
PR="$PR_LIB_DIR/plan-review.sh"
DETECT_SH="$PR_PLUGIN_DIR/skills/ticket-detect-resume/detect-resume.sh"
TABLE="$PR_PLUGIN_DIR/skills/ticket-flow/dispatch-table.json"
TID="T-1"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE AUTONOMY REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION
unset TICKET_ROUTER_PLAN_REVIEW PLAN_REVIEW_TABLE FLEET_PIPELINE_LOG_DIR FLEET_STATE_DIR

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
    return 0
  fi
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# _ws_new [complexity] — a tickets-repo workspace with one ticket dir and a
# plan. Exports WS, HOME, TICKET_TMP_DIR, CLAUDE_SKILLS_LIB; sets LOG, TDIR.
_ws_new() {
  local complexity="${1:-complex}"
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  TDIR="$WS/$TID--thing"
  mkdir -p "$WS/logs" "$WS/home" "$WS/repos/app" "$TDIR"
  mkdir -m 700 "$WS/scratch"
  export WS HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$PR_LIB_DIR"
  LOG="$WS/logs/$TID-pipeline.log"
  printf '%s\n' '2026-11-10T10:00:00Z|META|schema|info|1' >"$LOG"
  printf '# T-1\n\nDo the thing.\n' >"$TDIR/context.md"
  printf '# Notes\n\n## Complexity\n\n**Score:** %s\n**Weighted:** 3\n**Axes:** multi-service\n**Reason:** two services\n\n## Initial Investigation\n\n- found it\n' \
    "$complexity" >"$TDIR/notes.md"
  if [ "$complexity" = complex ]; then
    mkdir -p "$WS/openspec/changes/t-1-thing/specs"
    printf -- '- [ ] 1.1 do it\n' >"$WS/openspec/changes/t-1-thing/tasks.md"
    printf '# Design\n' >"$WS/openspec/changes/t-1-thing/design.md"
  else
    printf '# Simple fix\n' >"$TDIR/simple-fix.md"
  fi
}

_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }

_log() { printf '2026-11-10T10:00:01Z|%s\n' "$@" >>"$LOG"; }

# The log after a router-mode EXEC that wrote the plan.
_exec_done() {
  _log 'META|plan-review|info|router' \
    'EXEC|create-artifact|done|openspec' \
    'EXEC|exec|done|agent done'
}

# _spawn — open the STEP_2_2 bracket the way the router does.
_spawn() {
  (
    cd "$WS"
    source "$PR_LIB_DIR/spawn-helper.sh"
    spawn_agent_pre PHASE=EXEC STEP=plan-review TICKET_ID=$TID LOG_FILE="$LOG" \
      SKILL=/ticket-auto-pipeline:ticket-plan-review \
      AGENT_TYPE=ticket-auto-pipeline:ticket-plan-review-agent \
      DESCRIPTION="Independent plan review" INSTRUCTIONS=x >/dev/null 2>&1
  ) || true
  printf 'PLAN_REVIEW written %s/plan-review.md\n' "$TDIR" >"$WS/logs/$TID-agent-return.txt"
}

# _result <kind> — what the reviewer wrote.
_result() {
  {
    printf '# Plan Review\n\n**Ticket:** %s\n**Round:** 1\n\n## Findings\n\n' "$TID"
    case "$1" in
    pass) printf 'None.\n' ;;
    warn) printf '### F1 — major — no retry on timeout\n**Cites:** design.md\n**Problem:** p\n**Recommendation:** r\n\n### F2 — nit — wording\n**Cites:** tasks.md\n**Problem:** p\n**Recommendation:** r\n' ;;
    block) printf '### F1 — blocker — migration missing\n**Cites:** tasks.md 1.1\n**Problem:** p\n**Recommendation:** r\n\n### F2 - minor - a - title with hyphens\n**Cites:** design.md\n**Problem:** p\n**Recommendation:** r\n' ;;
    badsev) printf '### F1 — critical — not a severity\n**Problem:** p\n' ;;
    empty) : ;;
    both) printf 'None.\n\n### F1 — minor — x\n' ;;
    esac
    printf '\n## Files Read\n\n- tasks.md\n'
  } >"$TDIR/plan-review.md"
}

_prepare() { (cd "$WS" && bash "$PR" prepare $TID --log-file "$LOG" --repos-root "$WS/repos"); }
_done() { (cd "$WS" && bash "$PR" done $TID --log-file "$LOG"); }
_state() { bash "$PR" state "$LOG"; }

# One full review: prepare, spawn, result, done. Prints done's output.
_review() {
  _prepare >/dev/null
  _spawn
  _result "$1"
  _done
}

# ── state ────────────────────────────────────────────────────────────────────
test_state_table() {
  _ws_new
  local ok=0
  [ "$(_state)" = off ] || ok=1
  _log 'META|plan-review|info|inline — fleetd phase dispatch does not run STEP_2_2'
  [ "$(_state)" = off ] || ok=1
  _ws_rm
  _ws_new
  _exec_done
  [ "$(_state)" = review ] || ok=1
  _log 'EXEC|plan-review|waiting|Agent launched'
  [ "$(_state)" = review ] || ok=1
  _log 'EXEC|adversarial-review|done|BLOCKED — independent review round 1: findings=1 blockers=1'
  [ "$(_state)" = revise ] || ok=1
  _log 'EXEC|exec|done|revised'
  [ "$(_state)" = review ] || ok=1
  _log 'EXEC|adversarial-review|done|BLOCKED — independent review round 2: findings=1 blockers=1' \
    'META|gate-stop|fail|ADVERSARIAL_BLOCKED — round 2 — T-1'
  [ "$(_state)" = stopped ] || ok=1
  # A person revised the plan and re-ran: EXEC completes again.
  _log 'EXEC|exec|done|agent done'
  [ "$(_state)" = review ] || ok=1
  _log 'EXEC|adversarial-review|done|WARNINGS — HUMAN OVERRIDE: accepted'
  [ "$(_state)" = resolved ] || ok=1
  _ws_rm
  _ws_new
  _exec_done
  _log 'EXEC|plan-review|skip|complexity=simple'
  [ "$(_state)" = resolved ] || ok=1
  _ws_rm
  return $ok
}

test_mode_reads_the_log_not_the_env() {
  _ws_new
  local ok=0
  [ "$(TICKET_ROUTER_PLAN_REVIEW=true bash "$PR" mode --log-file "$LOG")" = inline ] || ok=1
  _log 'META|plan-review|info|router'
  [ "$(TAP_LOG="$LOG" bash "$PR" mode)" = router ] || ok=1
  [ "$(bash "$PR" mode)" = inline ] || ok=1
  _ws_rm
  return $ok
}

# ── flag off: no step ────────────────────────────────────────────────────────
test_flag_off_prepare_skips_and_writes_nothing() {
  _ws_new
  _log 'EXEC|create-artifact|done|openspec' 'EXEC|exec|done|agent done'
  local before out
  before=$(cat "$LOG")
  out=$(_prepare)
  [ "$out" = "PLAN_REVIEW_READY=skip" ] && [ "$(cat "$LOG")" = "$before" ] &&
    [ ! -e "$WS/logs/$TID-plan-review-instructions.txt" ]
  local ok=$?
  _ws_rm
  return $ok
}

test_flag_off_detect_resume_goes_to_the_gate() {
  _ws_new
  _log 'APPRAISE|appraise|done|ok' 'EXEC|create-artifact|done|openspec' 'EXEC|exec|done|agent done'
  local out
  out=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2_5$' <<<"$out" && grep -q '^  PLAN_REVIEW: *off$' <<<"$out"
  local ok=$?
  _ws_rm
  return $ok
}

# ── flag on: dispatched after the producing phase ────────────────────────────
test_router_mode_detect_resume_routes_to_step_2_2() {
  _ws_new
  _log 'APPRAISE|appraise|done|ok'
  _exec_done
  local out
  out=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2_2$' <<<"$out" && grep -q '^  PLAN_REVIEW: *review$' <<<"$out"
  local ok=$?
  _ws_rm
  return $ok
}

test_router_mode_before_exec_still_runs_exec() {
  _ws_new
  _log 'META|plan-review|info|router' 'APPRAISE|appraise|done|ok'
  local out
  out=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2$' <<<"$out"
  local ok=$?
  _ws_rm
  return $ok
}

test_prepare_simple_ticket_skips_with_a_log_line() {
  _ws_new simple
  _log 'META|plan-review|info|router' 'EXEC|create-artifact|done|simple-fix' 'EXEC|exec|done|agent done'
  local out
  out=$(_prepare)
  [ "$out" = "PLAN_REVIEW_READY=skip" ] &&
    grep -q '|EXEC|plan-review|skip|complexity=simple' "$LOG" &&
    [ "$(_state)" = resolved ] &&
    (cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null) | grep -q '^  RESUME_STEP: *STEP_2_5$'
  local ok=$?
  _ws_rm
  return $ok
}

test_prepare_complex_ticket_writes_reviewer_instructions() {
  _ws_new
  _exec_done
  printf 'stale\n' >"$TDIR/plan-review.md"
  local out f
  out=$(_prepare)
  f="$WS/logs/$TID-plan-review-instructions.txt"
  grep -qx 'PLAN_REVIEW_READY=spawn' <<<"$out" && grep -qx 'PLAN_REVIEW_ROUND=1' <<<"$out" &&
    grep -q '^PLAN_REVIEW_INSTRUCTIONS_FILE=' <<<"$out" &&
    [ ! -e "$TDIR/plan-review.md" ] &&
    grep -qF "Ticket workspace (read context.md and notes.md there): $TDIR" "$f" &&
    grep -qF "Plan artifact under review: $WS/openspec/changes/t-1-thing" "$f" &&
    grep -qF "Repositories root" "$f" && grep -qF "$WS/repos" "$f" &&
    grep -qF "Result file (the only file you write): $TDIR/plan-review.md" "$f" &&
    grep -qF 'You have no Bash tool' "$f" &&
    # The reviewer gets paths, never the producing phase's words.
    ! grep -q 'agent done' "$f"
  local ok=$?
  _ws_rm
  return $ok
}

# ── findings handling ────────────────────────────────────────────────────────
test_pass_advances() {
  _ws_new
  _exec_done
  local out
  out=$(_review pass)
  grep -qx 'PLAN_REVIEW_VERDICT=PASS' <<<"$out" && grep -qx 'PLAN_REVIEW_DECISION=advance' <<<"$out" &&
    grep -q '|EXEC|adversarial-review|done|PASS — independent review round 1: findings=0 blockers=0' "$LOG" &&
    grep -q '|EXEC|plan-review|done|PASS round#1' "$LOG" &&
    grep -q '|META|verifier-result|info|.*"verifier":"adversarial_review".*"verdict":"PASS"' "$LOG" &&
    ! grep -q '|META|gate-stop|' "$LOG" && [ "$(_state)" = resolved ] &&
    (cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null) | grep -q '^  RESUME_STEP: *STEP_2_5$'
  local ok=$?
  _ws_rm
  return $ok
}

test_warnings_advance_and_are_carried_forward() {
  _ws_new
  _exec_done
  local out
  out=$(_review warn)
  grep -qx 'PLAN_REVIEW_VERDICT=WARNINGS' <<<"$out" && grep -qx 'PLAN_REVIEW_DECISION=advance' <<<"$out" &&
    grep -qx 'PLAN_REVIEW_FINDINGS=2' <<<"$out" &&
    grep -q '|EXEC|adversarial-review|done|WARNINGS — ' "$LOG" &&
    grep -q '"verifier":"adversarial_review".*"verdict":"WARN"' "$LOG" &&
    grep -q '^## Adversarial Review$' "$TDIR/notes.md" &&
    grep -q '^\*\*Verdict:\*\* WARNINGS (independent plan review, round 1' "$TDIR/notes.md" &&
    grep -q '^### F1 — major — no retry on timeout$' "$TDIR/notes.md" &&
    grep -q '^## Initial Investigation$' "$TDIR/notes.md" &&
    [ -f "$TDIR/plan-review-r1.md" ] &&
    grep -q 'Attempt plan-review-1' "$WS/logs/$TID-exec-agent.log"
  local ok=$?
  _ws_rm
  return $ok
}

test_blocker_loops_once_then_gate_stops_at_the_cap() {
  _ws_new
  _exec_done
  local out ok=0 dr
  out=$(_review block)
  grep -qx 'PLAN_REVIEW_VERDICT=BLOCKED' <<<"$out" && grep -qx 'PLAN_REVIEW_DECISION=retry' <<<"$out" &&
    grep -qx 'PLAN_REVIEW_BLOCKERS=1' <<<"$out" && grep -qx 'PLAN_REVIEW_FINDINGS=2' <<<"$out" || ok=1
  grep -q '|EXEC|plan-review|done|BLOCKED round#1' "$LOG" || ok=1
  ! grep -q '|META|gate-stop|' "$LOG" || ok=1
  # Resume after the BLOCKED verdict: EXEC again, from create-artifact.
  dr=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2$' <<<"$dr" && grep -q '^  EXEC_FROM: *create-artifact$' <<<"$dr" &&
    grep -q '^  PLAN_REVIEW: *revise$' <<<"$dr" || ok=1
  # The revise instructions name the findings file and the plan.
  out=$(cd "$WS" && bash "$PR" revise $TID --log-file "$LOG")
  grep -q '^PLAN_REVISE_INSTRUCTIONS_FILE=' <<<"$out" &&
    grep -qF "$TDIR/plan-review.md" "$WS/logs/$TID-plan-revise-instructions.txt" &&
    grep -qF 'Plan Review Response (round 1)' "$WS/logs/$TID-plan-revise-instructions.txt" &&
    grep -q '|META|plan-revise|info|round#1' "$LOG" || ok=1
  # EXEC revised the plan and finished: the review runs again.
  _log 'EXEC|exec|waiting|Agent launched' 'EXEC|exec|done|revised'
  dr=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2_2$' <<<"$dr" || ok=1
  out=$(_prepare)
  grep -qx 'PLAN_REVIEW_ROUND=2' <<<"$out" || ok=1
  _spawn
  _result block
  out=$(_done)
  grep -qx 'PLAN_REVIEW_DECISION=exhausted' <<<"$out" && grep -qx 'PLAN_REVIEW_ROUND=2' <<<"$out" || ok=1
  grep -q '|META|gate-stop|fail|ADVERSARIAL_BLOCKED — round 2 — T-1 independent plan review' "$LOG" || ok=1
  grep -q '|EXEC|plan-review|fail|BLOCKED round#2' "$LOG" || ok=1
  [ "$(grep -c '|META|gate-stop|fail|ADVERSARIAL_BLOCKED' "$LOG")" -eq 1 ] || ok=1
  [ "$(_state)" = stopped ] || ok=1
  # The existing recovery: a person revises, the re-run starts at EXEC.
  dr=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2$' <<<"$dr" && grep -q '^  EXEC_FROM: *create-artifact$' <<<"$dr" || ok=1
  # ... and after that EXEC the plan is reviewed again, not looped through EXEC.
  _log 'EXEC|exec|done|agent done'
  dr=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2_2$' <<<"$dr" || ok=1
  # adversarial-rounds.sh (round awareness) counts the stop it always counted.
  [ "$(bash "$PR_LIB_DIR/adversarial-rounds.sh" "$LOG")" = 1 ] || ok=1
  _ws_rm
  return $ok
}

test_a_pass_after_a_revise_advances() {
  _ws_new
  _exec_done
  _review block >/dev/null
  _log 'EXEC|exec|done|revised'
  local out
  out=$(_review pass)
  grep -qx 'PLAN_REVIEW_DECISION=advance' <<<"$out" && grep -qx 'PLAN_REVIEW_ROUND=2' <<<"$out" &&
    ! grep -q '|META|gate-stop|' "$LOG" && [ "$(_state)" = resolved ]
  local ok=$?
  _ws_rm
  return $ok
}

test_missing_or_malformed_result_never_passes() {
  local kind ok=0 out
  for kind in none badsev empty both; do
    _ws_new
    _exec_done
    _prepare >/dev/null
    _spawn
    [ "$kind" = none ] || _result "$kind"
    out=$(_done)
    grep -qx 'PLAN_REVIEW_DECISION=invalid' <<<"$out" && grep -qx 'PLAN_REVIEW_VERDICT=NONE' <<<"$out" || ok=1
    grep -q '|META|gate-stop|fail|PLAN_REVIEW_NO_VERDICT — round 1' "$LOG" || ok=1
    grep -q '|EXEC|plan-review|fail|no verdict round#1' "$LOG" || ok=1
    ! grep -q '|EXEC|adversarial-review|done|' "$LOG" || ok=1
    ! grep -q '^## Adversarial Review' "$TDIR/notes.md" || ok=1
    # No verdict: the next run reviews again.
    [ "$(_state)" = review ] || ok=1
    (cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null) | grep -q '^  RESUME_STEP: *STEP_2_2$' || ok=1
    _ws_rm
  done
  return $ok
}

test_a_stale_result_from_an_earlier_round_is_not_read() {
  _ws_new
  _exec_done
  _result pass
  # prepare removes it; the reviewer then writes nothing.
  _prepare >/dev/null
  _spawn
  local out
  out=$(_done)
  grep -qx 'PLAN_REVIEW_DECISION=invalid' <<<"$out"
  local ok=$?
  _ws_rm
  return $ok
}

# ── resume mid-review ────────────────────────────────────────────────────────
test_resume_mid_review_reruns_the_review() {
  _ws_new
  _log 'APPRAISE|appraise|done|ok'
  _exec_done
  local now old out ok=0
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s|EXEC|plan-review|waiting|Agent launched — Independent plan review\n' "$now" >>"$LOG"
  out=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2_2$' <<<"$out" || ok=1
  _ws_rm
  # A reviewer that died: the zombie close routes to the review, not to EXEC.
  _ws_new
  _log 'APPRAISE|appraise|done|ok'
  _exec_done
  old=$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  printf '%s|EXEC|plan-review|waiting|Agent launched — Independent plan review\n' "$old" >>"$LOG"
  out=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  grep -q '^  RESUME_STEP: *STEP_2_2$' <<<"$out" || ok=1
  grep -q '|EXEC|plan-review|fail|zombie-detected: EXEC plan-review' "$LOG" || ok=1
  _ws_rm
  return $ok
}

test_exec_from_never_names_the_review_step() {
  _ws_new
  _log 'APPRAISE|appraise|done|ok'
  _exec_done
  _log 'EXEC|plan-review|done|PASS round#1 — findings=0'
  local out
  out=$(cd "$WS" && bash "$DETECT_SH" $TID 2>/dev/null)
  ! grep -q '^  EXEC_FROM: *plan-review' <<<"$out"
  local ok=$?
  _ws_rm
  return $ok
}

# ── dispatch table and skill text ────────────────────────────────────────────
test_dispatch_table_step() {
  jq -e '
    (.steps | map(.step_id)) as $ids
    | ($ids | index("STEP_2_2")) == (($ids | index("STEP_2")) + 1)
    and (($ids | index("STEP_2_5")) == (($ids | index("STEP_2_2")) + 1))
    and (.steps[] | select(.step_id == "STEP_2_2")
         | .action == "agent" and .phase_dispatch == "manual-pickup"
           and .spawn.phase == "EXEC" and .spawn.step == "plan-review"
           and .spawn.skill == "/ticket-auto-pipeline:ticket-plan-review"
           and .spawn.agent == "ticket-auto-pipeline:ticket-plan-review-agent"
           and .revise_loop.max_iterations == 2
           and .revise_loop.gate_stop_code == "ADVERSARIAL_BLOCKED"
           and (has("loop") | not))
    and (.prompt_manifests["ticket-plan-review"].files
         == ["plugin:skills/ticket-plan-review/SKILL.md", "plugin:agents/ticket-plan-review-agent.md"])
  ' "$TABLE" >/dev/null || return 1
  local block
  block=$(python3 "$PR_PLUGIN_DIR/skills/ticket-flow/gen-dispatch-table.py")
  grep -q '^| `STEP_2_2` | Independent plan review ' <<<"$block" &&
    grep -qxF '| `/ticket-auto-pipeline:ticket-plan-review` | `ticket-auto-pipeline:ticket-plan-review-agent` |' <<<"$block"
}

test_cap_comes_from_the_table() {
  _ws_new
  local t="$WS/table.json" out
  jq '(.steps[] | select(.step_id == "STEP_2_2") | .revise_loop.max_iterations) = 1' "$TABLE" >"$t"
  _exec_done
  _prepare >/dev/null
  _spawn
  _result block
  out=$(cd "$WS" && PLAN_REVIEW_TABLE="$t" bash "$PR" done $TID --log-file "$LOG")
  grep -qx 'PLAN_REVIEW_DECISION=exhausted' <<<"$out"
  local ok=$?
  _ws_rm
  return $ok
}

test_skill_text_turns_the_inline_review_off() {
  local exec_md="$PR_PLUGIN_DIR/skills/ticket-appraise-exec/SKILL.md"
  local auto_md="$PR_PLUGIN_DIR/skills/ticket-auto/SKILL.md"
  local ref="$PR_PLUGIN_DIR/skills/ticket-auto/references/plan-review.md"
  local sec
  # shellcheck source=skill-text.sh
  source "$PR_TEST_DIR/skill-text.sh"
  sec=$(_section "$exec_md" '^## Step 3[.]6 ' '^## Step 3[.]7 ')
  # The skip condition is read before the round count and the spawn.
  grep -n 'plan-review.sh mode` prints `router`, skip to Step 3.7' <<<"$sec" | head -1 | grep -q '^[1-4]:' || return 1
  # The inline review is still there for flag off.
  grep -qF 'Spawn a `general-purpose` agent' <<<"$sec" || return 1
  grep -qF 'ADVERSARIAL_BLOCKED — round {ADV_ROUND}' <<<"$sec" || return 1
  # The router reads its reference only when the state asks for it.
  grep -F 'references/plan-review.md' "$auto_md" | grep -F 'skill-ref.sh ticket-auto' |
    grep -qF '`{PLAN_REVIEW}` is `review` or `revise`' || return 1
  grep -qF '`{PLAN_REVIEW}`' "$auto_md" || return 1
  grep -qF 'plan-review.sh prepare {TICKET_ID}' "$ref" &&
    grep -qF 'plan-review.sh done {TICKET_ID}' "$ref" &&
    grep -qF 'plan-review.sh revise {TICKET_ID}' "$ref" &&
    grep -qF 'FROM_STEP=create-artifact' "$ref" &&
    grep -qF 'AGENT_TYPE=ticket-auto-pipeline:ticket-plan-review-agent' "$ref"
}

_run "state: off, review, revise, stopped, resolved" test_state_table
_run "mode reads the log, not the env" test_mode_reads_the_log_not_the_env
_run "flag off: prepare skips and writes nothing" test_flag_off_prepare_skips_and_writes_nothing
_run "flag off: detect-resume goes to the gate" test_flag_off_detect_resume_goes_to_the_gate
_run "flag on: detect-resume routes to STEP_2_2 after EXEC" test_router_mode_detect_resume_routes_to_step_2_2
_run "flag on: EXEC still runs first" test_router_mode_before_exec_still_runs_exec
_run "prepare: a simple ticket skips with a log line" test_prepare_simple_ticket_skips_with_a_log_line
_run "prepare: a complex ticket gets reviewer instructions" test_prepare_complex_ticket_writes_reviewer_instructions
_run "done: PASS advances" test_pass_advances
_run "done: WARNINGS advance and are carried forward" test_warnings_advance_and_are_carried_forward
_run "done: a blocker loops once, then gate-stops at the cap" test_blocker_loops_once_then_gate_stops_at_the_cap
_run "done: a pass after a revise advances" test_a_pass_after_a_revise_advances
_run "done: a missing or malformed result never passes" test_missing_or_malformed_result_never_passes
_run "done: a stale result is not read" test_a_stale_result_from_an_earlier_round_is_not_read
_run "resume mid-review re-runs the review" test_resume_mid_review_reruns_the_review
_run "EXEC_FROM never names the review step" test_exec_from_never_names_the_review_step
_run "dispatch table: STEP_2_2 after STEP_2, generated row" test_dispatch_table_step
_run "the cap comes from the dispatch table" test_cap_comes_from_the_table
_run "skill text: inline review off in router mode, kept otherwise" test_skill_text_turns_the_inline_review_off

echo ""
echo "plan-review: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
