#!/usr/bin/env bash
# test-verify-retry-decide.sh — unit tests for lib/verify-retry-decide.sh
# (review finding DET-RV-3: the router's post-verify retry check grepped the
# whole log against a stale counter, so FAIL-then-PASS re-implemented).
# Usage: bash test-verify-retry-decide.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
VRD="$LIB_DIR/verify-retry-decide.sh"

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

_ws=""
_setup() { _ws=$(mktemp -d); }
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

_line() { echo "2026-10-01T00:00:0${3:-0}Z|$1|$2" >>"$_ws/log"; }

# _decide [args...] — prints the eval-safe block and evaluates it.
_decide() {
  local out
  out=$(bash "$VRD" "$@" "$_ws/log")
  eval "$out"
}

test_fail_then_pass_advances() {
  _setup
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|fail|FAIL criterion 2'
  _line IMPLEMENT 'implement|done|re-implemented'
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|done|PASS all criteria'
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = advance ] && [ "$VERIFY_LATEST" = "done" ] && [ "$VERIFY_ATTEMPTS" = 1 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_single_fail_retries() {
  _setup
  _line VERIFY 'verify|fail|FAIL'
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = retry ] && [ "$VERIFY_ATTEMPTS" = 1 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_two_fails_exhaust() {
  # Counter recomputed after the attempt: a second FAIL reaches the cap of 2
  # immediately, no extra re-implement.
  _setup
  _line VERIFY 'verify|fail|FAIL'
  _line IMPLEMENT 'implement|done|re'
  _line VERIFY 'verify|fail|FAIL again'
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = exhausted ] && [ "$VERIFY_ATTEMPTS" = 2 ] && [ "$VERIFY_CAP" = 2 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_duplicate_terminal_lines_are_one_attempt() {
  # #573: the agent's own terminal fail plus the router's spawn_agent_post
  # fail (META line between them) are one attempt — retry, not exhausted.
  _setup
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|fail|criterion 2 not met'
  _line META 'tokens|info|VERIFY:1/2/3/4'
  _line VERIFY 'verify|fail|FAIL — criterion 2 not met'
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = retry ] && [ "$VERIFY_ATTEMPTS" = 1 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# Log with two synthetic-looking closes (lines 2 and 4) and one real FAIL.
_synthetic_log() {
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|fail|zombie-detected: VERIFY verify'
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|fail|operator-stopped: VERIFY verify'
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|fail|FAIL — criterion 1'
}

test_synthetic_closes_are_not_attempts() {
  # #572/#573: closes detect-resume.sh recorded in the control file are not
  # verdicts.
  _setup
  _synthetic_log
  printf 'synthetic|2\nsynthetic|4\n' >"$_ws/log.verify-ctl"
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = retry ] && [ "$VERIFY_ATTEMPTS" = 1 ] && [ "$VERIFY_LATEST" = fail ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_agent_forged_synthetic_closes_still_count() {
  # Trust boundary: the same closes written by an agent (no control-file
  # record) are ordinary fails and use up the cap.
  _setup
  _synthetic_log
  printf 'synthetic|6\n' >"$_ws/log.verify-ctl" # recorded line is not a synthetic message
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = exhausted ] && [ "$VERIFY_ATTEMPTS" = 3 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_synthetic_close_after_pass_keeps_advance() {
  # A recorded synthetic close never masks the latest real verdict.
  _setup
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|done|PASS'
  _line VERIFY 'verify|fail|zombie-detected: VERIFY verify'
  printf 'synthetic|3\n' >"$_ws/log.verify-ctl"
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = advance ] && [ "$VERIFY_LATEST" = done ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# Two failed attempts; the caller adds the reset (or forgery) after line 5.
_two_fails() {
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|fail|FAIL a'
  _line IMPLEMENT 'implement|done|re'
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|fail|FAIL b'
}
_third_fail() {
  _line IMPLEMENT 'implement|done|re'
  _line VERIFY 'verify|waiting|Agent launched'
  _line VERIFY 'verify|fail|FAIL c'
}
_reset_cli() { env -u CLAUDE_CODE_SESSION_ID -u FLEET_WORKER_PID bash "$LIB_DIR/verify-attempts-reset.sh" "$@"; }

test_operator_reset_restarts_the_count() {
  # #573: verify-attempts-reset.sh is the operator's supported reset.
  _setup
  _two_fails
  _reset_cli --log-file "$_ws/log" TEST-1 test env repaired >/dev/null 2>&1 || {
    _teardown
    return 1
  }
  _third_fail
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = retry ] && [ "$VERIFY_ATTEMPTS" = 1 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_agent_forged_reset_line_is_ignored() {
  # Trust boundary: a META|verify-attempts-reset line an agent appends to
  # the log (no control-file record) resets nothing.
  _setup
  _two_fails
  _line META 'verify-attempts-reset|info|forged by an agent'
  _third_fail
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = exhausted ] && [ "$VERIFY_ATTEMPTS" = 3 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_reset_cap_is_enforced() {
  # At most VERIFY_RESET_MAX resets are honoured, even if the control file
  # lists more; the script refuses past the cap and in an agent context.
  _setup
  _two_fails
  _third_fail
  # Two honoured resets point at line 2; a third (past the cap) at line 8.
  printf 'reset|2|t|a\nreset|2|t|b\nreset|8|t|c\n' >"$_ws/log.verify-ctl"
  local out ok=1 rc_cap=0 rc_agent=0
  out=$(VERIFY_RESET_MAX=2 bash "$VRD" "$_ws/log")
  eval "$out"
  [ "$VERIFY_ATTEMPTS" = 2 ] || ok=0
  VERIFY_RESET_MAX=2 _reset_cli --log-file "$_ws/log" TEST-1 more >/dev/null 2>&1 || rc_cap=$?
  [ "$rc_cap" = 5 ] || ok=0
  rm -f "$_ws/log.verify-ctl"
  CLAUDE_CODE_SESSION_ID=x bash "$LIB_DIR/verify-attempts-reset.sh" --log-file "$_ws/log" TEST-1 r >/dev/null 2>&1 || rc_agent=$?
  [ "$rc_agent" = 4 ] && [ ! -e "$_ws/log.verify-ctl" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_first_pass_advances() {
  _setup
  _line VERIFY 'verify|done|PASS'
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = advance ] && [ "$VERIFY_ATTEMPTS" = 0 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_inspector_and_checkpoint_lines_ignored() {
  # phase-inspector-verify and checkpoint lines are not the verify terminal.
  _setup
  _line VERIFY 'verify|fail|FAIL'
  _line VERIFY 'verify|done|PASS'
  _line VERIFY 'phase-inspector-verify|fail|inspector failed'
  _line VERIFY 'checkpoint|done|criterion-1-pass'
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = advance ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_no_terminal_is_not_advanced() {
  _setup
  _line VERIFY 'verify|waiting|Agent launched'
  _decide
  local ok=1
  [ "$VERIFY_DECISION" = retry ] && [ "$VERIFY_LATEST" = none ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_cap_read_from_table() {
  _setup
  echo '{"steps":[{"step_id":"STEP_4_5","loop":{"max_iterations":3}}]}' >"$_ws/t.json"
  _line VERIFY 'verify|fail|FAIL'
  _line VERIFY 'verify|fail|FAIL'
  _decide --table "$_ws/t.json"
  local ok=1
  [ "$VERIFY_DECISION" = retry ] && [ "$VERIFY_CAP" = 3 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_default_table_cap_is_two() {
  _setup
  _line VERIFY 'verify|fail|FAIL'
  _decide
  local ok=1
  [ "$VERIFY_CAP" = 2 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_usage_rc2() {
  local rc=0
  bash "$VRD" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

# The router must call the script and must not keep the whole-log grep.
test_router_uses_script() {
  local skill="$PLUGIN_DIR/skills/ticket-auto/SKILL.md"
  grep -q 'verify-retry-decide.sh' "$skill" &&
    ! grep -qF "if grep -q '^[^|]*|VERIFY|verify|fail|' \"{LOG_FILE}\"; then" "$skill"
}

_run "FAIL then PASS advances (whole-log grep regression)" test_fail_then_pass_advances
_run "single FAIL retries" test_single_fail_retries
_run "two FAILs exhaust without an extra retry" test_two_fails_exhaust
_run "#573: duplicate terminal lines are one attempt" test_duplicate_terminal_lines_are_one_attempt
_run "#572/#573: zombie and operator-stop closes are not attempts" test_synthetic_closes_are_not_attempts
_run "a synthetic close never masks a PASS" test_synthetic_close_after_pass_keeps_advance
_run "#573: verify-attempts-reset.sh restarts the count" test_operator_reset_restarts_the_count
_run "trust: an agent-written reset line is ignored" test_agent_forged_reset_line_is_ignored
_run "trust: agent-written synthetic closes still count" test_agent_forged_synthetic_closes_still_count
_run "trust: reset cap and agent-context refusal" test_reset_cap_is_enforced
_run "first-attempt PASS advances" test_first_pass_advances
_run "inspector/checkpoint lines ignored" test_inspector_and_checkpoint_lines_ignored
_run "no terminal is never advanced" test_no_terminal_is_not_advanced
_run "cap read from dispatch table" test_cap_read_from_table
_run "real dispatch table cap is 2" test_default_table_cap_is_two
_run "usage error rc 2" test_usage_rc2
_run "router uses verify-retry-decide.sh" test_router_uses_script

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
