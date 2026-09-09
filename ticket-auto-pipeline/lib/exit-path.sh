#!/usr/bin/env bash
# exit-path.sh — deterministic reduction of a finished run to one exit path,
# and the failure classification built on top of it
# (run-failure-classification, langfuse-evidence-layer Phase 5).
#
# `_derive_exit_path` is extracted **verbatim** from `pipeline-postmortem.sh`
# (SC1): the post-mortem sources this file in place of its own inline
# definition, so there is exactly one implementation shared by both callers
# rather than two copies that will eventually drift. It is unmodified from
# its original form — same globals ($LOG_FILE, $EXIT_CODE), same behaviour.
#
# `derive_failure_class`/`derive_failure_phase` are new: a closed, ordered
# failure vocabulary derived from evidence the pipeline already writes (the
# pipeline log's own `META` lines), with no new evidence and no model
# invocation (run-failure-classification spec). Colocated here rather than
# in a third file because classification is built directly on the exit-path
# reduction above and on the same log-reading conventions.
#
# Sourcing this file alone has no side effects: it defines functions only,
# runs no analysis, writes no log entry, files no issue, and creates no
# temporary directory or state (task 10.1's acceptance test). No top-level
# execution, no `set` flags of its own — the caller's shell options apply.

# ── Exit-path derivation (SC1 — verbatim from pipeline-postmortem.sh) ──────────

_derive_exit_path() {
  local tmp="$1"

  # Gate-stop takes priority, but detect exhaustion wrapped as gate-stop
  # (F15: production writes exhaustion as META|gate-stop|fail|VERIFY_EXHAUSTED)
  if grep -q '|META|gate-stop|fail|' "$LOG_FILE" 2>/dev/null; then
    local _code
    _code=$(grep '|META|gate-stop|fail|' "$LOG_FILE" | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}')
    case "$_code" in
    VERIFY_EXHAUSTED) echo "verify-exhausted" ;;
    PR_FEEDBACK_EXHAUSTED) echo "pr-feedback-exhausted" ;;
    PR_REVIEW_EXHAUSTED) echo "pr-review-exhausted" ;;
    *) echo "gate-stop:${_code}" ;;
    esac
    return
  fi

  # Router error
  if grep -q '|META|router-error|' "$LOG_FILE" 2>/dev/null; then
    echo "router-error"
    return
  fi

  # Fleet kill
  if grep -q 'stopped: fleet-kill' "$LOG_FILE" 2>/dev/null; then
    echo "fleet-kill"
    return
  fi

  # Non-zero exit code with no clear signal
  if [ "${EXIT_CODE:-0}" -ne 0 ]; then
    echo "interrupted:exit-code-${EXIT_CODE}"
    return
  fi

  # Default: reached STEP_6
  echo "completed"
}

# ── Failure classification (run-failure-classification) ────────────────────────

#: Verifiers whose FAIL verdict means an actual test/build/UAT run failed,
#: as opposed to a review-shaped verifier (gate_check, critique,
#: adversarial_review, pr_review, audit, regression_guard).
_FAILURE_TEST_VERIFIERS=" implement_tests playwright_uat build_only live_backend "

# Reads the JSON payload (fields 5+) of one `META|<key>|` line, joined with
# the awk pattern every consumer of these lines uses (never `cut -f5` — see
# pipeline-log-format.md's MSG-parsing rule; a `|` inside the JSON silently
# truncates under `cut`).
_exitpath_json_field() {
  echo "$1" | awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}'
}

# _failure_has_test_verifier_fail LOG_FILE
# A FAIL verdict from one of the test-running verifiers (test_failure, ahead
# of the generic gate-stop/orchestration branches — SC6's precedence is fixed
# regardless of what shape the exit path itself took).
_failure_has_test_verifier_fail() {
  local log_file="$1" line json verifier verdict
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    json=$(_exitpath_json_field "$line")
    verdict=$(echo "$json" | jq -r '.verdict // empty' 2>/dev/null)
    [ "$verdict" = "FAIL" ] || continue
    verifier=$(echo "$json" | jq -r '.verifier // empty' 2>/dev/null)
    case "$_FAILURE_TEST_VERIFIERS" in
    *" ${verifier} "*) return 0 ;;
    esac
  done < <(grep '|META|verifier-result|' "$log_file" 2>/dev/null)
  return 1
}

# _failure_has_any_fail_verdict LOG_FILE
# The agent_failure fallback's evidence: any other failing verifier result,
# or a failing phase-inspector verdict.
_failure_has_any_fail_verdict() {
  local log_file="$1" line json verdict
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    json=$(_exitpath_json_field "$line")
    verdict=$(echo "$json" | jq -r '.verdict // empty' 2>/dev/null)
    [ "$verdict" = "FAIL" ] || [ "$verdict" = "BLOCK" ] && return 0
  done < <(grep '|META|verifier-result|' "$log_file" 2>/dev/null)

  local inspector_line inspector_json
  inspector_line=$(grep '|META|phase-inspector|' "$log_file" 2>/dev/null | tail -1)
  if [ -n "$inspector_line" ]; then
    inspector_json=$(_exitpath_json_field "$inspector_line")
    verdict=$(echo "$inspector_json" | jq -r '.verdict // empty' 2>/dev/null)
    [ "$verdict" = "FAIL" ] && return 0
  fi
  return 1
}

# derive_failure_class LOG_FILE
# Exactly one class from the closed vocabulary, by first match in a fixed
# precedence order. `EXIT_CODE`/`LOG_FILE` are set for the `_derive_exit_path`
# sub-call the same way pipeline-postmortem.sh's own argument parsing sets
# them — a caller with neither available passes EXIT_CODE=0 (the "no signal"
# default `_derive_exit_path` itself already treats as unremarkable).
derive_failure_class() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo "none"
    return
  }

  # META|outcome's MSG is a bare string (not JSON) for every branch this
  # classifier reads.
  local outcome
  outcome=$(grep '|META|outcome|info|' "$log_file" 2>/dev/null | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}')

  # 1. human_intervention — a hold with no corresponding release entry. A
  #    released hold never leaves `held: human` as the *final* outcome line
  #    (pipeline-finalize.sh only ever writes it for an unreleased request).
  if echo "$outcome" | grep -q '^held: human'; then
    echo "human_intervention"
    return
  fi

  # 2. approval_gate — a revoked approval, or held at the gate with no resume.
  if echo "$outcome" | grep -q '^held: gate'; then
    echo "approval_gate"
    return
  fi
  if grep -q '|META|gate-stop|fail|APPROVAL_REVOKED' "$log_file" 2>/dev/null; then
    echo "approval_gate"
    return
  fi

  local exit_path
  exit_path=$(LOG_FILE="$log_file" EXIT_CODE="${EXIT_CODE:-0}" _derive_exit_path "")

  # 3. verification_failure — verify-retry exhaustion. `_derive_exit_path`
  #    normally reduces this to the bare "verify-exhausted" string, but real
  #    logs were found (task 10.10 replay) carrying trailing detail after the
  #    code (e.g. "ADVERSARIAL_BLOCKED — <description>"), which defeats that
  #    exact-string reduction and leaves the raw `gate-stop:VERIFY_EXHAUSTED…`
  #    shape instead — matched here too so the same real-world code shape
  #    that broke review_failure below cannot silently misclassify this one.
  case "$exit_path" in
  verify-exhausted | gate-stop:VERIFY_EXHAUSTED*)
    echo "verification_failure"
    return
    ;;
  esac

  # 4. review_failure — review/review-feedback exhaustion, an unparseable
  #    review verdict, or a blocked adversarial review. `CRITIQUE_BLOCKED` is
  #    accepted alongside `ADVERSARIAL_BLOCKED` — the two names for the same
  #    gate-stop have drifted across docs; both mean the same event. Matched
  #    by prefix, not exact string — see the task-10.10 finding above.
  case "$exit_path" in
  pr-feedback-exhausted | pr-review-exhausted | \
    gate-stop:PR_FEEDBACK_EXHAUSTED* | gate-stop:PR_REVIEW_EXHAUSTED* | \
    gate-stop:PR_REVIEW_VERDICT_UNPARSEABLE* | gate-stop:ADVERSARIAL_BLOCKED* | gate-stop:CRITIQUE_BLOCKED*)
    echo "review_failure"
    return
    ;;
  esac

  # 5. test_failure — a failing test-running verifier, no higher-precedence
  #    branch matched.
  if _failure_has_test_verifier_fail "$log_file"; then
    echo "test_failure"
    return
  fi

  # 6. orchestration_failure — a router error, or any structural gate-stop.
  #    Every gate-stop code not already peeled off by a more specific branch
  #    above is, by construction, an orchestration-level halt: the pipeline's
  #    own dispatcher stopped it, not an external test/review/timeout/infra
  #    signal. Named codes are listed for readability; the trailing `gate-stop:*`
  #    case is the actual catch-all so a code added later is not silently
  #    left unclassified.
  if [ "$exit_path" = "router-error" ]; then
    echo "orchestration_failure"
    return
  fi
  case "$exit_path" in
  gate-stop:EXEC_NO_ARTIFACT* | gate-stop:COMPLEXITY_ARTIFACT_MISMATCH* | \
    gate-stop:BRANCH_DIRECTIVE_INVALID* | gate-stop:REMEDIATION_BRIEF_TRUNCATED* | \
    gate-stop:RECONCILE_EXHAUSTED*)
    echo "orchestration_failure"
    return
    ;;
  gate-stop:*)
    echo "orchestration_failure"
    return
    ;;
  esac
  # RETURN_INCOMPLETE only counts when the run did not go on to complete —
  # task 10.10's replay found real runs held mid-IMPLEMENT_RETRY that
  # resolved the incompleteness and finished cleanly on a later attempt; a
  # stale, already-resolved warning must not override "completed" (SC6: a
  # clean run is classified none, not left carrying an earlier attempt's scar).
  if [ "$exit_path" != "completed" ] &&
    grep -q '|META|gate-warn|info|RETURN_INCOMPLETE' "$log_file" 2>/dev/null; then
    echo "orchestration_failure"
    return
  fi

  # 7. timeout — a fleet-kill whose recorded reason names a stall or
  #    watchdog anomaly (run-failure-classification SC7; the anomaly reaches
  #    this outcome line via fleet-monitor.sh's kill-reason threading).
  if [ "$exit_path" = "fleet-kill" ] && echo "$outcome" | grep -qiE 'stall|watchdog'; then
    echo "timeout"
    return
  fi

  # 8. infrastructure_failure — any other fleet-kill, a worker API error, or
  #    a non-zero exit with no clearer signal.
  if [ "$exit_path" = "fleet-kill" ]; then
    echo "infrastructure_failure"
    return
  fi
  if grep -q '|META|worker-api-error|' "$log_file" 2>/dev/null; then
    echo "infrastructure_failure"
    return
  fi
  case "$exit_path" in
  interrupted:exit-code-*)
    echo "infrastructure_failure"
    return
    ;;
  esac

  # 9. agent_failure — a failing phase-inspector verdict or another failing
  #    verifier result, no higher-precedence branch matched.
  if _failure_has_any_fail_verdict "$log_file"; then
    echo "agent_failure"
    return
  fi

  # 10. none — a clean run.
  echo "none"
}

# derive_failure_phase LOG_FILE
# The phase of the last failing entry, or the phase associated with the
# gate-stop that ended the run. `none` for a clean run.
derive_failure_phase() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo "none"
    return
  }

  if [ "$(derive_failure_class "$log_file")" = "none" ]; then
    echo "none"
    return
  fi

  # Most specific: the phase recorded on the last failing/blocked
  # verifier-result line.
  local last_fail_line last_fail_json phase
  last_fail_line=$(grep '|META|verifier-result|' "$log_file" 2>/dev/null | tac | while IFS= read -r line; do
    last_fail_json=$(_exitpath_json_field "$line")
    verdict=$(echo "$last_fail_json" | jq -r '.verdict // empty' 2>/dev/null)
    if [ "$verdict" = "FAIL" ] || [ "$verdict" = "BLOCK" ]; then
      echo "$line"
      break
    fi
  done)
  if [ -n "$last_fail_line" ]; then
    phase=$(echo "$(_exitpath_json_field "$last_fail_line")" | jq -r '.phase // empty' 2>/dev/null)
    if [ -n "$phase" ]; then
      echo "$phase"
      return
    fi
  fi

  # Next: the phase of the log's most recent `|fail|` bracket terminal.
  local last_bracket_fail
  last_bracket_fail=$(grep -E '^[^|]*\|[A-Za-z-]+\|[^|]*\|fail\|' "$log_file" 2>/dev/null | grep -v '|META|' | tail -1)
  if [ -n "$last_bracket_fail" ]; then
    echo "$last_bracket_fail" | awk -F'|' '{print $2}'
    return
  fi

  # Gate-stop and fleet-kill both name no phase field of their own — fall
  # back to the phase of the log's last non-META line before the halt, which
  # is the phase that was actually running when it happened.
  phase=$(grep -v '|META|' "$log_file" 2>/dev/null | tail -1 | awk -F'|' '{print $2}')
  if [ -n "$phase" ]; then
    echo "$phase"
    return
  fi

  echo "none"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  class)
    derive_failure_class "$2"
    ;;
  phase)
    derive_failure_phase "$2"
    ;;
  *)
    echo "Usage: exit-path.sh class|phase LOG_FILE" >&2
    exit 1
    ;;
  esac
fi
