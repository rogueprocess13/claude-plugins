#!/usr/bin/env bash
# test-router-step.sh — unit tests for lib/router-step.sh (post-spawn,
# inspector, inspector-done, retro-check), skill-deterministic-extraction 3.
#
# The expected outputs in fixtures/router-step/ were produced by running the
# pre-extraction ticket-auto SKILL.md blocks (main @ 3f64658) against the
# workspaces the _case_* functions below build — never by this script.
# Timestamps are masked to TS and the workspace path to $WS.
#
# Also carries the behavioural replacements for the STEP_6 retro-condition
# prose tests that lived in test-pipeline-phases.sh (#149, #318).
#
# Usage: bash test-router-step.sh [test_name_filter]
# With ROUTER_STEP_TEST_LIB_ONLY=1 the file only defines its helpers (the
# fixture generator sources it that way).
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

RS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS_LIB_DIR="$(cd "$RS_TEST_DIR/.." && pwd)"
RS="$RS_LIB_DIR/router-step.sh"
RS_FX="$RS_TEST_DIR/fixtures/router-step"
TID="T-1"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE AUTONOMY REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION

# _ws_new — a fresh workspace; exports WS, HOME, TICKET_TMP_DIR, CLAUDE_SKILLS_LIB, LOG.
_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/logs" "$WS/home" "$WS/repos/app/.git" "$WS/ticket"
  mkdir -m 700 "$WS/scratch"
  export WS HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" CLAUDE_SKILLS_LIB="$RS_LIB_DIR"
  LOG="$WS/logs/$TID-pipeline.log"
  printf '%s\n' '2026-11-10T10:00:00Z|META|schema|info|1' >"$LOG"
}

_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }

# _mask FILE — timestamps → TS, workspace path → $WS.
_mask() {
  sed -e "s|$WS|\$WS|g" \
    -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g' "$1"
}

_return_file() { # PHASE VERDICT
  local v
  case "$1" in IMPLEMENT) v=implement_tests ;; VERIFY) v=playwright_uat ;; *) v=pr_review ;; esac
  cat >"$WS/logs/$TID-agent-return.txt" <<EOF
Work done. A \$HOME and a "quote" and \`tick\` survive verbatim.
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: $1
VERIFIER: $v
VERDICT: $2
CRITERIA_MET: 2
CRITERIA_TOTAL: 3
ATTEMPT: 1
EVIDENCE: checked
UNADDRESSED:
=== END PHASE_RESULT ===
EOF
}

_tasks() { # CHECKED UNCHECKED
  local d="$WS/repos/app/openspec/changes/t-1-thing" i
  mkdir -p "$d"
  : >"$d/tasks.md"
  for ((i = 0; i < $1; i++)); do echo "- [x] done $i" >>"$d/tasks.md"; done
  for ((i = 0; i < $2; i++)); do echo "- [ ] open $i" >>"$d/tasks.md"; done
}

_vr() { # PHASE VERIFIER VERDICT
  printf '2026-11-10T10:01:00Z|META|verifier-result|info|{"phase":"%s","verifier":"%s","verdict":"%s","criteria_met":1,"criteria_total":1,"attempt":1,"detail":"a|b"}\n' \
    "$1" "$2" "$3" >>"$LOG"
}

# ── cases (inputs only; the same for the old blocks and the script) ─────────
_case_post_impl_incomplete() {
  _return_file IMPLEMENT PASS
  _tasks 1 1
}
_case_post_impl_complete() {
  _return_file IMPLEMENT PASS
  _tasks 2 0
}
_case_post_verify_attempt2() {
  printf -- '--- Attempt 1 ---\nfirst attempt\n' >"$WS/logs/$TID-verify-agent.log"
  printf '%s\n' '2026-11-10T10:02:00Z|VERIFY|verify|waiting|Agent launched — Run Playwright UAT verification' >>"$LOG"
  _return_file VERIFY FAIL
}
_case_post_pr_review() { _return_file PR-REVIEW PASS; }
_case_insp_implement_skip() { :; }
_case_insp_verify_ready() {
  _vr IMPLEMENT return_completeness PASS
  _vr VERIFY playwright_uat PASS
  _vr PR-REVIEW pr_review PASS
}
_case_insp_pr_ready() { _case_insp_verify_ready; }
_case_insp_done_verify() {
  printf -- '--- Attempt 1 ---\nverify said PASS\n' >"$WS/logs/$TID-verify-agent.log"
  printf 'inspector return\n' >"$WS/logs/$TID-agent-return.txt"
  (
    source "$RS_LIB_DIR/spawn-helper.sh"
    spawn_agent_pre PHASE=VERIFY STEP=phase-inspector-verify TICKET_ID=$TID \
      LOG_FILE="$LOG" SKILL=/ticket-auto-pipeline:guidance-extractor \
      AGENT_TYPE=ticket-auto-pipeline:guidance-extractor-agent \
      DESCRIPTION="Phase inspector for VERIFY" INSTRUCTIONS=x >/dev/null 2>&1
  ) || true
}

# Retro cases: the log body after the schema line; HB is the heartbeat log.
_case_retro_clean() {
  printf '%s\n' '2026-11-10T10:00:01Z|VERIFY|verify|done|PASS — 3/3' \
    '2026-11-10T10:00:02Z|PR-REVIEW|pr-review|done|OK — Verdict: ✅' >>"$LOG"
}
_case_retro_n_a() {
  printf '%s\n' '2026-09-07T19:50:00Z|VERIFY|verify|done|PASS' \
    '2026-09-07T19:54:53Z|PR-REVIEW|pr-review|done|N/A — no PR (verification-only ticket, no source diff produced by IMPLEMENT)' >>"$LOG"
}
_case_retro_no_pr_review() {
  printf '%s\n' '2026-09-07T19:50:00Z|VERIFY|verify|done|PASS' >>"$LOG"
}
_case_retro_pr_pass_token() {
  printf '%s\n' '2026-11-10T10:00:01Z|VERIFY|verify|done|PASS' \
    '2026-11-10T10:00:02Z|PR-REVIEW|pr-review|done|PASS' >>"$LOG"
}
_case_retro_gate_stop() {
  _case_retro_clean
  printf '%s\n' '2026-11-10T10:00:03Z|META|gate-stop|fail|RECONCILE_EXHAUSTED' >>"$LOG"
}
_case_retro_fallback() {
  _case_retro_clean
  printf '%s\n' '2026-11-10T10:00:00Z|fallback|playwright|warn|no mcp|' >"$WS/hb.log"
}
_case_retro_verify_exhausted() {
  _case_retro_clean
  printf '%s\n' '2026-11-10T10:00:03Z|VERIFY|retry|info|VERIFY_EXHAUSTED seen in a sub-shell' >>"$LOG"
}
_case_retro_verify_fail() {
  printf '%s\n' '2026-11-10T10:00:01Z|VERIFY|verify|fail|FAIL — 1/3' >>"$LOG"
  _case_retro_clean
}
RS_RETRO_CASES="clean n_a no_pr_review pr_pass_token gate_stop fallback verify_exhausted verify_fail"
RS_POST_CASES="impl_incomplete impl_complete verify_attempt2 pr_review"
RS_INSP_CASES="implement_skip verify_ready pr_ready"

# ── new-script runners ───────────────────────────────────────────────────────
_new_post() {
  case "$1" in
  impl_incomplete | impl_complete)
    bash "$RS" post-spawn IMPLEMENT $TID --log-file "$LOG" --repos-root "$WS/repos"
    ;;
  verify_attempt2)
    bash "$RS" post-spawn VERIFY $TID --log-file "$LOG" --attempt 2 --ticket-dir "$WS/ticket"
    ;;
  pr_review)
    bash "$RS" post-spawn PR-REVIEW $TID --log-file "$LOG" --attempt 1
    ;;
  esac
}
_new_insp() {
  case "$1" in
  implement_skip) bash "$RS" inspector IMPLEMENT $TID --log-file "$LOG" ;;
  verify_ready) bash "$RS" inspector VERIFY $TID --log-file "$LOG" ;;
  pr_ready) bash "$RS" inspector PR-REVIEW $TID --log-file "$LOG" ;;
  esac
}

[ "${ROUTER_STEP_TEST_LIB_ONLY:-}" = 1 ] && return 0

# ── harness ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
FILTER="${1:-}"
_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# _same FIXTURE ACTUAL_FILE — masked ACTUAL must equal the fixture.
_same() {
  local want="$RS_FX/$1" got
  got=$(_mask "$2")
  if [ "$got" != "$(cat "$want")" ]; then
    echo "  mismatch vs fixtures/router-step/$1:" >&2
    diff <(cat "$want") <(printf '%s\n' "$got") >&2 || true
    return 1
  fi
}

test_post_spawn() { # CASE
  local c="$1" rc=0 out
  _ws_new
  (
    cd "$WS"
    "_case_post_$c"
    _new_post "$c" >"$WS/stdout" 2>/dev/null
  ) || rc=1
  [ $rc -eq 0 ] || {
    _ws_rm
    return 1
  }
  local phase
  case "$c" in impl_*) phase=implement ;; verify_*) phase=verify ;; *) phase=pr-review ;; esac
  _same "post-$c.log" "$LOG" && _same "post-$c.capture" "$WS/logs/$TID-$phase-agent.log" || rc=1
  case "$c" in
  impl_incomplete) grep -qx 'RETURN_COMPLETENESS_STATUS=incomplete' "$WS/stdout" || rc=1 ;;
  impl_complete) grep -qx 'RETURN_COMPLETENESS_STATUS=complete' "$WS/stdout" || rc=1 ;;
  *) [ ! -s "$WS/stdout" ] || rc=1 ;;
  esac
  _ws_rm
  return $rc
}

test_inspector() { # CASE
  local c="$1" rc=0
  _ws_new
  (
    cd "$WS"
    "_case_insp_$c"
    _new_insp "$c" >"$WS/stdout" 2>/dev/null
  ) || rc=1
  _same "insp-$c.log" "$LOG" || rc=1
  local ready
  ready=$(grep '^PHASE_INSPECTOR_READY=' "$WS/stdout" || true)
  [ "$ready" = "$(cat "$RS_FX/insp-$c.ready")" ] || {
    echo "  ready: got '$ready'" >&2
    rc=1
  }
  if [ -f "$RS_FX/insp-$c.instructions" ]; then
    local f
    f=$(sed -n 's/^INSPECTOR_INSTRUCTIONS_FILE=//p' "$WS/stdout")
    [ -n "$f" ] && [ -f "$WS/$f" ] || [ -f "$f" ] || rc=1
    [ -f "$f" ] || f="$WS/$f"
    _same "insp-$c.instructions" "$f" || rc=1
  else
    grep -q '^INSPECTOR_INSTRUCTIONS_FILE=' "$WS/stdout" && rc=1
  fi
  _ws_rm
  return $rc
}

test_inspector_done() {
  local rc=0
  _ws_new
  (
    cd "$WS"
    _case_insp_done_verify
    bash "$RS" inspector-done VERIFY $TID >/dev/null 2>&1
  ) || rc=1
  _same insp-done-verify.log "$LOG" &&
    _same insp-done-verify.capture "$WS/logs/$TID-verify-agent.log" || rc=1
  _ws_rm
  return $rc
}

test_retro() { # CASE
  local c="$1" rc=0 out
  _ws_new
  "_case_retro_$c"
  out=$(bash "$RS" retro-check --log-file "$LOG" --hb-log-file "$WS/hb.log")
  local needs
  needs=$(sed -n 's/^NEEDS_RETRO=//p' <<<"$out")
  [ "$needs" = "$(cat "$RS_FX/retro-$c.needs")" ] || {
    echo "  NEEDS_RETRO=$needs, want $(cat "$RS_FX/retro-$c.needs")" >&2
    rc=1
  }
  _same "retro-$c.log" "$LOG" || rc=1
  # Output is eval-safe and complete.
  (
    eval "$out"
    [ -n "$NEEDS_RETRO" ] && [ -n "$DRIFT" ]
  ) || rc=1
  _ws_rm
  return $rc
}

# #318 / #149 as behaviour (were prose greps on STEP_6 Condition 2).
test_retro_n_a_is_clean() {
  _ws_new
  _case_retro_n_a
  local out
  out=$(bash "$RS" retro-check --log-file "$LOG")
  _ws_rm
  grep -qx 'NEEDS_RETRO=false' <<<"$out"
}
test_retro_pr_pass_token_is_not_success() {
  _ws_new
  _case_retro_pr_pass_token
  local out
  out=$(bash "$RS" retro-check --log-file "$LOG")
  _ws_rm
  grep -qx 'NEEDS_RETRO=true' <<<"$out"
}

test_retro_reasons_and_drift() {
  _ws_new
  _case_retro_fallback
  printf '%s\n' '2026-11-10T10:00:04Z|META|gate-stop|fail|VERIFY_EXHAUSTED' >>"$LOG"
  local out NEEDS_RETRO DRIFT RETRO_REASONS
  out=$(bash "$RS" retro-check --log-file "$LOG" --hb-log-file "$WS/hb.log" --no-drift-log)
  eval "$out"
  local lines
  lines=$(grep -c '|META|drift|' "$LOG" || true)
  _ws_rm
  [ "$NEEDS_RETRO" = true ] && [ "$DRIFT" = true ] && [ "$lines" = 0 ] &&
    [ "$RETRO_REASONS" = "gate-stop fired,heartbeat fallback event,VERIFY exhaustion code present" ]
}

test_retro_missing_log_and_unfilled_hb() {
  local out
  out=$(bash "$RS" retro-check --log-file /nonexistent/x.log --hb-log-file "{HB_LOG_FILE}")
  grep -qx 'NEEDS_RETRO=true' <<<"$out" && grep -qx 'DRIFT=false' <<<"$out"
}

# The inspector is advisory: a missing/broken phase-inspector.sh never fails.
test_inspector_failure_is_non_blocking() {
  _ws_new
  local d="$WS/lib" rc=0 out
  cp -r "$RS_LIB_DIR/." "$d"
  printf 'spawn_phase_inspector() { return 7; }\n' >"$d/phase-inspector.sh"
  out=$(cd "$WS" && bash "$d/router-step.sh" inspector IMPLEMENT $TID --log-file "$LOG") || rc=$?
  printf 'exit 9\n' >"$d/phase-inspector.sh"
  out="$out
$(cd "$WS" && bash "$d/router-step.sh" inspector VERIFY $TID --log-file "$LOG")" || rc=$?
  _ws_rm
  [ $rc -eq 0 ] && [ "$(grep -c '^PHASE_INSPECTOR_READY=skip$' <<<"$out")" = 2 ]
}

test_post_spawn_tolerates_missing_return_file() {
  _ws_new
  local rc=0
  (cd "$WS" && bash "$RS" post-spawn PR-REVIEW $TID --log-file "$LOG" >/dev/null 2>&1) || rc=$?
  _ws_rm
  [ $rc -eq 0 ]
}

test_usage() {
  local rc=0
  bash "$RS" >/dev/null 2>&1 || rc=$?
  [ $rc = 2 ] || return 1
  rc=0
  bash "$RS" bogus >/dev/null 2>&1 || rc=$?
  [ $rc = 2 ] || return 1
  rc=0
  bash "$RS" post-spawn IMPLEMENT "{TICKET_ID}" --log-file x >/dev/null 2>&1 || rc=$?
  [ $rc = 2 ] || return 1
  rc=0
  bash "$RS" retro-check --log-file "{LOG_FILE}" >/dev/null 2>&1 || rc=$?
  [ $rc = 2 ]
}

# The router calls the script; the old inline blocks are gone.
test_skill_uses_router_step() {
  local skill="$RS_LIB_DIR/../skills/ticket-auto/SKILL.md"
  grep -q 'router-step.sh retro-check' "$skill" &&
    grep -q 'router-step.sh post-spawn IMPLEMENT' "$skill" &&
    grep -q 'router-step.sh post-spawn VERIFY' "$skill" &&
    grep -q 'router-step.sh post-spawn PR-REVIEW' "$skill" &&
    grep -q 'router-step.sh inspector IMPLEMENT' "$skill" &&
    grep -q 'router-step.sh inspector VERIFY' "$skill" &&
    grep -q 'router-step.sh inspector PR-REVIEW' "$skill" &&
    grep -q 'router-step.sh inspector-done' "$skill" &&
    ! grep -q 'Condition 2: did the ticket NOT reach' "$skill" &&
    ! grep -q '_pi_out=\$(assemble_inspector_context' "$skill" &&
    ! grep -q 'phase-result-parse.sh"' "$skill"
}

for c in $RS_POST_CASES; do _run "post-spawn $c matches the pre-extraction block" test_post_spawn "$c"; done
for c in $RS_INSP_CASES; do _run "inspector $c matches the pre-extraction block" test_inspector "$c"; done
_run "inspector-done matches the pre-extraction block" test_inspector_done
for c in $RS_RETRO_CASES; do _run "retro-check $c matches the pre-extraction block" test_retro "$c"; done
_run "#318: PR-REVIEW N/A is a clean outcome" test_retro_n_a_is_clean
_run "#149: PR-REVIEW PASS is not a success marker" test_retro_pr_pass_token_is_not_success
_run "retro-check reasons, drift flag, --no-drift-log" test_retro_reasons_and_drift
_run "retro-check: missing log, unfilled HB placeholder" test_retro_missing_log_and_unfilled_hb
_run "inspector failure is non-blocking (exit 0, skip)" test_inspector_failure_is_non_blocking
_run "post-spawn tolerates a missing return file" test_post_spawn_tolerates_missing_return_file
_run "usage errors exit 2" test_usage
_run "ticket-auto SKILL.md calls router-step.sh" test_skill_uses_router_step

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
