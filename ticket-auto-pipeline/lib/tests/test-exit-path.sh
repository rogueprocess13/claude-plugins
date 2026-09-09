#!/usr/bin/env bash
# test-exit-path.sh — tests for lib/exit-path.sh
# (run-failure-classification, langfuse-evidence-layer Phase 5).
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_tmp_log() {
  local tmp
  tmp=$(mktemp -d)
  printf '%s' "$tmp/T.log"
}

# ── Sourcing has no side effects (task 10.4) ────────────────────────────────────

test_sourcing_alone_has_no_side_effects() {
  local tmp before after
  tmp=$(mktemp -d)
  before=$(find "$tmp" -type f | wc -l)
  (cd "$tmp" && bash -c "source '$LIB_DIR/exit-path.sh'")
  after=$(find "$tmp" -type f | wc -l)
  local ok
  [ "$before" -eq 0 ] && [ "$after" -eq 0 ]
  ok=$?
  rm -rf "$tmp"
  return $ok
}

test_sourcing_defines_functions_only() {
  bash -c "source '$LIB_DIR/exit-path.sh'; declare -f derive_failure_class >/dev/null && declare -f derive_failure_phase >/dev/null && declare -f _derive_exit_path >/dev/null"
}

# ── derive_failure_class: one case per vocabulary branch (task 10.7) ───────────

test_class_human_intervention() {
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|META|run-id|info|{"run_id":"T-1-2026-01-01T00:00:00Z-1"}
2026-01-01T00:01:00Z|META|human-hold|waiting|{"reason":"needs-decision"}
2026-01-01T00:01:01Z|META|outcome|info|held: human
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "human_intervention" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_approval_gate_via_held_outcome() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|outcome|info|held: gate' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "approval_gate" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_approval_gate_via_revoked() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|APPROVAL_REVOKED' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "approval_gate" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_verification_failure() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|VERIFY_EXHAUSTED' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "verification_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_review_failure_via_exhaustion() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|PR_REVIEW_EXHAUSTED' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "review_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_review_failure_via_unparseable_verdict() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|PR_REVIEW_VERDICT_UNPARSEABLE' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "review_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_review_failure_via_blocked_adversarial() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|ADVERSARIAL_BLOCKED' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "review_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_test_failure() {
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|VERIFY|verify|waiting|attempt 1
2026-01-01T00:00:10Z|META|verifier-result|info|{"verifier":"playwright_uat","verdict":"FAIL","phase":"VERIFY"}
2026-01-01T00:00:11Z|VERIFY|verify|fail|FAIL criterion 2
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "test_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_orchestration_failure_via_router_error() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|router-error|fail|dispatch table load failed' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "orchestration_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_orchestration_failure_via_named_gate_stop() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|EXEC_NO_ARTIFACT' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "orchestration_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_orchestration_failure_via_unnamed_gate_stop_catchall() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|ZERO_AC' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "orchestration_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_timeout_on_stall_kill() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|outcome|info|stopped: fleet-kill (SIGTERM); auto-kill: stall(S2)' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "timeout" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_infrastructure_failure_on_non_stall_kill() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|outcome|info|stopped: fleet-kill (SIGTERM); auto-kill: tool-errors(S2)' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "infrastructure_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_a_pre_c0_kill_with_bare_auto_kill_string_classifies_infrastructure_failure() {
  # task 10.9 — historical replay must not change meaning: a log written
  # before the anomaly was threaded into the reason still classifies
  # infrastructure_failure exactly as it always did.
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|outcome|info|stopped: fleet-kill (SIGTERM); auto-kill' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "infrastructure_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_infrastructure_failure_on_worker_api_error() {
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|IMPLEMENT|implement|waiting|x
2026-01-01T00:00:10Z|META|worker-api-error|warn|
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; EXIT_CODE=1 derive_failure_class '$log'")" = "infrastructure_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_agent_failure_fallback() {
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|APPRAISE|complexity-sweep|waiting|x
2026-01-01T00:00:10Z|META|verifier-result|info|{"verifier":"gate_check","verdict":"FAIL","phase":"GATE"}
2026-01-01T00:00:11Z|APPRAISE|complexity-sweep|fail|gate check failed
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "agent_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_class_agent_failure_via_phase_inspector() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:00:10Z|META|phase-inspector|info|{"phase":"IMPLEMENT","verdict":"FAIL","signals":1}' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "agent_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

# ── Clean-run and repeatability guarantees (task 10.8) ─────────────────────────

test_clean_run_classifies_none_with_none_phase() {
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|IMPLEMENT|implement|waiting|x
2026-01-01T00:00:10Z|IMPLEMENT|implement|done|ok
2026-01-01T00:00:11Z|META|outcome|info|complete
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "none" ] &&
    [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_phase '$log'")" = "none" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_a_resolved_return_incomplete_warning_does_not_override_a_completed_run() {
  # Found replaying real archived logs (task 10.10): a run held mid-retry on
  # RETURN_INCOMPLETE, then resolved it and completed cleanly on a later
  # attempt. The stale warning must not make an otherwise-clean run classify
  # as orchestration_failure.
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|IMPLEMENT|implement|waiting|x
2026-01-01T00:00:05Z|META|gate-warn|info|RETURN_INCOMPLETE — UNCHECKED_BOXES (unchecked=2/5, artifact=openspec)
2026-01-01T00:00:06Z|IMPLEMENT|implement|fail|IMPLEMENT_RETRY
2026-01-01T00:00:10Z|IMPLEMENT|implement|waiting|retry
2026-01-01T00:00:20Z|IMPLEMENT|implement|done|ok
2026-01-01T00:00:21Z|META|outcome|info|completed: STEP_6
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "none" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_an_unresolved_return_incomplete_warning_still_classifies_orchestration_failure() {
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|IMPLEMENT|implement|waiting|x
2026-01-01T00:00:05Z|META|gate-warn|info|RETURN_INCOMPLETE — UNCHECKED_BOXES (unchecked=2/5, artifact=openspec)
2026-01-01T00:00:06Z|IMPLEMENT|implement|fail|IMPLEMENT_RETRY
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; EXIT_CODE=1 derive_failure_class '$log'")" = "orchestration_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_review_failure_matches_a_code_with_trailing_detail_text() {
  # Also found by replay: real gate-stop lines carry trailing detail after
  # the bare code (e.g. "ADVERSARIAL_BLOCKED — <description>"), which
  # `_derive_exit_path`'s exact-string branches never match — the classifier
  # must match by prefix, not exact string, against the raw gate-stop shape.
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|ADVERSARIAL_BLOCKED — WIL-77 adversarial review found blocking issues' >"$log"
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")" = "review_failure" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_classification_is_repeatable() {
  local log
  log=$(_tmp_log)
  echo '2026-01-01T00:01:01Z|META|gate-stop|fail|VERIFY_EXHAUSTED' >"$log"
  local a b ok
  a=$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")
  b=$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_class '$log'")
  [ "$a" = "$b" ] && [ -n "$a" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_no_model_is_invoked() {
  # No `claude` binary call anywhere in the classifier's implementation.
  ! grep -qE '\bclaude\b' "$LIB_DIR/exit-path.sh"
}

# ── derive_failure_phase ─────────────────────────────────────────────────────────

test_phase_reports_last_failing_verifier_phase() {
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|VERIFY|verify|waiting|attempt 1
2026-01-01T00:00:10Z|META|verifier-result|info|{"verifier":"playwright_uat","verdict":"FAIL","phase":"VERIFY"}
2026-01-01T00:00:11Z|VERIFY|verify|fail|FAIL criterion 2
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_phase '$log'")" = "VERIFY" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

test_phase_falls_back_to_last_running_phase_for_a_gate_stop() {
  local log
  log=$(_tmp_log)
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|IMPLEMENT|implement|waiting|x
2026-01-01T00:00:10Z|IMPLEMENT|implement|done|ok
2026-01-01T00:00:11Z|META|gate-stop|fail|EXEC_NO_ARTIFACT
EOF
  local ok
  [ "$(bash -c "source '$LIB_DIR/exit-path.sh'; derive_failure_phase '$log'")" = "IMPLEMENT" ]
  ok=$?
  rm -rf "$(dirname "$log")"
  return $ok
}

_run "sourcing alone has no side effects" test_sourcing_alone_has_no_side_effects
_run "sourcing defines functions only" test_sourcing_defines_functions_only
_run "class: human_intervention" test_class_human_intervention
_run "class: approval_gate via held outcome" test_class_approval_gate_via_held_outcome
_run "class: approval_gate via revoked approval" test_class_approval_gate_via_revoked
_run "class: verification_failure" test_class_verification_failure
_run "class: review_failure via exhaustion" test_class_review_failure_via_exhaustion
_run "class: review_failure via unparseable verdict" test_class_review_failure_via_unparseable_verdict
_run "class: review_failure via blocked adversarial review" test_class_review_failure_via_blocked_adversarial
_run "class: test_failure" test_class_test_failure
_run "class: orchestration_failure via router error" test_class_orchestration_failure_via_router_error
_run "class: orchestration_failure via named gate-stop" test_class_orchestration_failure_via_named_gate_stop
_run "class: orchestration_failure via unnamed gate-stop catch-all" test_class_orchestration_failure_via_unnamed_gate_stop_catchall
_run "class: timeout on stall kill" test_class_timeout_on_stall_kill
_run "class: infrastructure_failure on non-stall kill" test_class_infrastructure_failure_on_non_stall_kill
_run "pre-C0 bare auto-kill string classifies infrastructure_failure" test_a_pre_c0_kill_with_bare_auto_kill_string_classifies_infrastructure_failure
_run "class: infrastructure_failure on worker API error" test_class_infrastructure_failure_on_worker_api_error
_run "class: agent_failure fallback" test_class_agent_failure_fallback
_run "class: agent_failure via phase-inspector" test_class_agent_failure_via_phase_inspector
_run "clean run classifies none/none" test_clean_run_classifies_none_with_none_phase
_run "a resolved RETURN_INCOMPLETE warning does not override a completed run" test_a_resolved_return_incomplete_warning_does_not_override_a_completed_run
_run "an unresolved RETURN_INCOMPLETE warning still classifies orchestration_failure" test_an_unresolved_return_incomplete_warning_still_classifies_orchestration_failure
_run "review_failure matches a code with trailing detail text" test_review_failure_matches_a_code_with_trailing_detail_text
_run "classification is repeatable" test_classification_is_repeatable
_run "no model is invoked" test_no_model_is_invoked
_run "phase: reports last failing verifier's phase" test_phase_reports_last_failing_verifier_phase
_run "phase: falls back to last running phase for a gate-stop" test_phase_falls_back_to_last_running_phase_for_a_gate_stop

echo ""
echo "exit-path: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
