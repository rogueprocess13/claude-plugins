#!/usr/bin/env bash
# test-fleet-feedback.sh — unit tests for fleet-feedback.sh
# Tests feedback aggregation with mock pipeline logs.
# Usage: bash test-fleet-feedback.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAP_LIB_DIR="$(cd "$LIB_DIR/../../ticket-auto-pipeline/lib" && pwd)"

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

# ── Mock helpers ─────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

_test_plog() {
  local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6"
  local iso="${7:-2026-07-07T10:00:00Z}"
  mkdir -p "$dir"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
}

source "$LIB_DIR/fleet-feedback.sh"

# ── Tests ───────────────────────────────────────────────────────────────────────

test_feedback_no_logs() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(fleet_aggregate_feedback "$ws" 2>&1 || true)
  # A fresh workspace with no pipeline logs → should report "no feedback"
  echo "$output" | grep -q "does not exist\|no pipeline logs\|no feedback" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_feedback_no_entries() {
  local ws
  ws=$(_setup_workspace)
  _test_plog "$ws" "CRE-101" "IMPLEMENT" "implement" "done" "implemented fix"
  _test_plog "$ws" "CRE-101" "META" "outcome" "info" "completed: success"

  local output
  output=$(fleet_aggregate_feedback "$ws" 2>&1 || true)
  echo "$output" | grep -q "no feedback to aggregate" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_feedback_malformed_json_skipped() {
  local ws
  ws=$(_setup_workspace)
  _test_plog "$ws" "CRE-101" "META" "planner-feedback" "info" "not-valid-json-at-all"

  local output
  output=$(fleet_aggregate_feedback "$ws" 2>&1 || true)
  # With no initiative labels, it should skip or report no feedback
  echo "$output" | grep -q "no feedback\|skipping" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_feedback_dry_run_flag_accepted() {
  local ws
  ws=$(_setup_workspace)
  # Test that --dry-run flag is accepted as argument
  local output
  output=$(FLEET_DRY_RUN=true REPOS_ROOT="$ws" fleet_aggregate_feedback "$ws" --dry-run 2>&1 || true)
  # Should still say "no feedback" (no entries) but not crash
  echo "$output" | grep -q "no feedback" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_feedback_empty_workspace() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(fleet_aggregate_feedback "$ws" 2>&1 || true)
  # Workspace exists but has no pipeline logs
  echo "$output" | grep -q "no pipeline logs\|no feedback\|does not exist" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_drift_none_label() {
  local result
  result=$(_drift_label "0.0" 2>/dev/null)
  [ "$result" = "none" ] || {
    echo "expected 'none', got '$result'"
    return 1
  }
}

test_drift_minor_label() {
  local result
  result=$(_drift_label "-0.15" 2>/dev/null)
  [ "$result" = "minor" ] || {
    echo "expected 'minor', got '$result'"
    return 1
  }
}

test_drift_major_label() {
  local result
  result=$(_drift_label "-0.25" 2>/dev/null)
  [ "$result" = "major" ] || {
    echo "expected 'major', got '$result'"
    return 1
  }
}

test_parse_feedback_payload_valid() {
  local line="2026-07-07T10:00:00Z|META|planner-feedback|info|{\"decision_drift\":\"none\"}"
  local payload
  payload=$(_parse_feedback_payload "$line" 2>/dev/null || echo "FAIL")
  [ "$payload" != "FAIL" ] || {
    echo "failed to parse valid payload"
    return 1
  }
  echo "$payload" | jq -e '.decision_drift == "none"' >/dev/null 2>&1 || {
    echo "wrong decision_drift"
    return 1
  }
}

test_parse_feedback_payload_invalid() {
  local line="2026-07-07T10:00:00Z|META|planner-feedback|info|{broken"
  if _parse_feedback_payload "$line" 2>/dev/null; then
    echo "expected failure for invalid JSON"
    return 1
  fi
  return 0
}

# ── _get_ticket_initiative (tracker-planner-and-fallback-cutover, 4.6) ─────
# Manifest-only — renamed from _get_initiative_labels, which read a live
# INIT-* label. No get_issue stub is defined in any of these — a live
# fallback would fail them.

test_get_ticket_initiative_reads_manifest() {
  local repos_root
  repos_root=$(mktemp -d)
  (
    source "$TAP_LIB_DIR/manifest-write.sh"
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-101" "INIT-42" "feature" '[]' >/dev/null
  )
  local result
  result=$(REPOS_ROOT="$repos_root" _get_ticket_initiative "CRE-101" 2>/dev/null)
  rm -rf "$repos_root"
  [ "$result" = "INIT-42" ] || {
    echo "expected 'INIT-42', got '$result'"
    return 1
  }
}

test_get_ticket_initiative_no_manifest_yields_nothing() {
  local repos_root
  repos_root=$(mktemp -d)
  local result
  result=$(REPOS_ROOT="$repos_root" _get_ticket_initiative "CRE-102" 2>/dev/null)
  rm -rf "$repos_root"
  [ -z "$result" ] || {
    echo "expected empty with no manifest, got '$result'"
    return 1
  }
}

# ── Feedback writer end-to-end (design R2) ──────────────────────────────────
# Exercises fleet_aggregate_feedback with a two-initiative fixture and
# confirms separate per-initiative feedback files are produced — the
# observable proof that the 4.1 fix actually reaches production behaviour,
# not just the unit-level extraction.

test_feedback_writer_groups_by_initiative_end_to_end() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(_setup_workspace)

  _test_plog "$ws" "CRE-201" "META" "planner-feedback" "info" '{"confidence_actual":0.8}'
  _test_plog "$ws" "CRE-301" "META" "planner-feedback" "info" '{"confidence_actual":0.6}'

  (
    source "$TAP_LIB_DIR/manifest-write.sh"
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-201" "INIT-42" "feature" '[]' >/dev/null
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-301" "INIT-43" "feature" '[]' >/dev/null
  )

  REPOS_ROOT="$repos_root" fleet_aggregate_feedback "$ws" >/dev/null 2>&1

  local rundate f42 f43
  rundate=$(date +%Y-%m-%d)
  f42="${repos_root}/.ticket-auto/initiatives/INIT-42/feedback/${rundate}.json"
  f43="${repos_root}/.ticket-auto/initiatives/INIT-43/feedback/${rundate}.json"

  [ -f "$f42" ] || {
    echo "expected INIT-42 feedback file at $f42"
    rm -rf "$ws" "$repos_root"
    return 1
  }
  [ -f "$f43" ] || {
    echo "expected INIT-43 feedback file at $f43"
    rm -rf "$ws" "$repos_root"
    return 1
  }
  jq -e '.tickets | length == 1 and .[0].source_tid == "CRE-201"' "$f42" >/dev/null 2>&1 || {
    echo "INIT-42 file did not carry CRE-201: $(cat "$f42")"
    rm -rf "$ws" "$repos_root"
    return 1
  }
  jq -e '.tickets | length == 1 and .[0].source_tid == "CRE-301"' "$f43" >/dev/null 2>&1 || {
    echo "INIT-43 file did not carry CRE-301: $(cat "$f43")"
    rm -rf "$ws" "$repos_root"
    return 1
  }
  rm -rf "$ws" "$repos_root"
  return 0
}

# ── Readiness-gap aggregation (readiness-feedback-loop) ─────────────────────
#
# gate-check.sh:838 writes META|gate-stop|fail|TICKET_NOT_READY — <codes>;
# ticket-verify's Step 1.7a writes VERIFY|pre-flight|fail|No test user found.
# Both are scanned independently of whether the same ticket ever wrote a
# META|planner-feedback| entry.

test_readiness_gap_ticket_with_no_planner_feedback_is_scanned() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(_setup_workspace)

  _test_plog "$ws" "CRE-401" "META" "gate-stop" "fail" "TICKET_NOT_READY — SCOPE_MISSING"
  (
    source "$TAP_LIB_DIR/manifest-write.sh"
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-401" "INIT-77" "feature" '[]' >/dev/null
  )

  REPOS_ROOT="$repos_root" fleet_aggregate_feedback "$ws" >/dev/null 2>&1

  local rundate f77 exists content
  rundate=$(date +%Y-%m-%d)
  f77="${repos_root}/.ticket-auto/initiatives/INIT-77/feedback/${rundate}.json"
  exists="false"
  [ -f "$f77" ] && exists="true"
  content=$(cat "$f77" 2>/dev/null)
  rm -rf "$ws" "$repos_root"

  [ "$exists" = "true" ] || {
    echo "expected INIT-77 feedback file even with zero planner-feedback entries"
    return 1
  }
  echo "$content" | jq -e '.summary.readiness_gaps.gate_stop_count == 1
    and .summary.readiness_gaps.gate_stop_codes.SCOPE_MISSING == 1
    and (.summary.readiness_gaps.affected_tickets | index("CRE-401")) != null' >/dev/null 2>&1
}

test_readiness_gap_only_initiative_has_zeroed_feedback_fields() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(_setup_workspace)

  _test_plog "$ws" "CRE-402" "META" "gate-stop" "fail" "TICKET_NOT_READY — TEST_USER_MISSING"
  (
    source "$TAP_LIB_DIR/manifest-write.sh"
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-402" "INIT-78" "feature" '[]' >/dev/null
  )

  REPOS_ROOT="$repos_root" fleet_aggregate_feedback "$ws" >/dev/null 2>&1

  local rundate f78
  rundate=$(date +%Y-%m-%d)
  f78="${repos_root}/.ticket-auto/initiatives/INIT-78/feedback/${rundate}.json"
  local content
  content=$(cat "$f78" 2>/dev/null)
  rm -rf "$ws" "$repos_root"

  # The empty-entries arithmetic path (task 2.6's guard) — total_tickets=0,
  # avg_confidence_actual=0 (not a jq division error), tickets=[].
  echo "$content" | jq -e '.summary.total_tickets == 0
    and .summary.avg_confidence_actual == 0
    and (.tickets | length == 0)' >/dev/null 2>&1
}

test_readiness_gap_multiple_codes_multiple_tickets_break_down_per_code() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(_setup_workspace)

  _test_plog "$ws" "CRE-403" "META" "gate-stop" "fail" "TICKET_NOT_READY — SCOPE_MISSING"
  _test_plog "$ws" "CRE-404" "META" "gate-stop" "fail" "TICKET_NOT_READY — TEST_USER_MISSING"
  _test_plog "$ws" "CRE-405" "META" "gate-stop" "fail" "TICKET_NOT_READY — TEST_USER_MISSING"
  (
    source "$TAP_LIB_DIR/manifest-write.sh"
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-403" "INIT-79" "feature" '[]' >/dev/null
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-404" "INIT-79" "feature" '[]' >/dev/null
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-405" "INIT-79" "feature" '[]' >/dev/null
  )

  REPOS_ROOT="$repos_root" fleet_aggregate_feedback "$ws" >/dev/null 2>&1

  local rundate f79 content
  rundate=$(date +%Y-%m-%d)
  f79="${repos_root}/.ticket-auto/initiatives/INIT-79/feedback/${rundate}.json"
  content=$(cat "$f79" 2>/dev/null)
  rm -rf "$ws" "$repos_root"

  echo "$content" | jq -e '.summary.readiness_gaps.gate_stop_codes.SCOPE_MISSING == 1
    and .summary.readiness_gaps.gate_stop_codes.TEST_USER_MISSING == 2
    and (.summary.readiness_gaps.affected_tickets | length) == 3' >/dev/null 2>&1
}

test_readiness_gap_recurrence_counts_occurrences_not_distinct_tickets() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(_setup_workspace)

  # Same ticket, 3 separate resume attempts, each still gate-stopping.
  _test_plog "$ws" "CRE-406" "META" "gate-stop" "fail" "TICKET_NOT_READY — SCOPE_MISSING" "2026-07-07T10:00:00Z"
  _test_plog "$ws" "CRE-406" "META" "gate-stop" "fail" "TICKET_NOT_READY — SCOPE_MISSING" "2026-07-07T11:00:00Z"
  _test_plog "$ws" "CRE-406" "META" "gate-stop" "fail" "TICKET_NOT_READY — SCOPE_MISSING" "2026-07-07T12:00:00Z"
  (
    source "$TAP_LIB_DIR/manifest-write.sh"
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-406" "INIT-80" "feature" '[]' >/dev/null
  )

  REPOS_ROOT="$repos_root" fleet_aggregate_feedback "$ws" >/dev/null 2>&1

  local rundate f80 content
  rundate=$(date +%Y-%m-%d)
  f80="${repos_root}/.ticket-auto/initiatives/INIT-80/feedback/${rundate}.json"
  content=$(cat "$f80" 2>/dev/null)
  rm -rf "$ws" "$repos_root"

  echo "$content" | jq -e '.summary.readiness_gaps.gate_stop_count == 3
    and (.summary.readiness_gaps.affected_tickets | length) == 1' >/dev/null 2>&1
}

test_readiness_gap_verify_no_test_user_is_scanned() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(_setup_workspace)

  _test_plog "$ws" "CRE-407" "VERIFY" "pre-flight" "fail" "No test user found"
  (
    source "$TAP_LIB_DIR/manifest-write.sh"
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-407" "INIT-81" "feature" '[]' >/dev/null
  )

  REPOS_ROOT="$repos_root" fleet_aggregate_feedback "$ws" >/dev/null 2>&1

  local rundate f81 content
  rundate=$(date +%Y-%m-%d)
  f81="${repos_root}/.ticket-auto/initiatives/INIT-81/feedback/${rundate}.json"
  content=$(cat "$f81" 2>/dev/null)
  rm -rf "$ws" "$repos_root"

  echo "$content" | jq -e '.summary.readiness_gaps.verify_no_test_user_count == 1' >/dev/null 2>&1
}

test_readiness_gap_clean_initiative_reports_empty_not_absent() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(_setup_workspace)

  _test_plog "$ws" "CRE-408" "META" "planner-feedback" "info" '{"confidence_actual":0.9}'
  (
    source "$TAP_LIB_DIR/manifest-write.sh"
    REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-408" "INIT-82" "feature" '[]' >/dev/null
  )

  REPOS_ROOT="$repos_root" fleet_aggregate_feedback "$ws" >/dev/null 2>&1

  local rundate f82 content
  rundate=$(date +%Y-%m-%d)
  f82="${repos_root}/.ticket-auto/initiatives/INIT-82/feedback/${rundate}.json"
  content=$(cat "$f82" 2>/dev/null)
  rm -rf "$ws" "$repos_root"

  # readiness_gaps key present and empty (not absent) — regression guard for
  # a planner-feedback-only initiative gaining exactly one new key.
  echo "$content" | jq -e '.summary | has("readiness_gaps")
    and .readiness_gaps.gate_stop_count == 0
    and .readiness_gaps.verify_no_test_user_count == 0
    and (.readiness_gaps.affected_tickets | length) == 0
    and (.total_tickets == 1)' >/dev/null 2>&1
}

test_readiness_gap_log_marker_literals_have_not_drifted() {
  # Cross-file tripwire (design.md Risks): fails loudly if either owning
  # file's exact log-line literal ever changes, instead of this scan
  # silently stopping to match.
  local gate_check_file="$LIB_DIR/../../ticket-auto-pipeline/lib/gate-check.sh"
  local verify_skill_file="$LIB_DIR/../../ticket-auto-pipeline/skills/ticket-verify/SKILL.md"

  grep -qF 'TICKET_NOT_READY — ' "$gate_check_file" 2>/dev/null || {
    echo "gate-check.sh no longer contains the literal 'TICKET_NOT_READY — ' substring"
    return 1
  }
  grep -qF 'No test user found' "$verify_skill_file" 2>/dev/null || {
    echo "ticket-verify/SKILL.md no longer contains the literal 'No test user found' substring"
    return 1
  }
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

# Skip integration tests that need linear-api (just test internal helpers + dry paths)
_run "feedback_no_logs" test_feedback_no_logs
_run "feedback_no_entries" test_feedback_no_entries
_run "feedback_malformed_json_skipped" test_feedback_malformed_json_skipped
_run "feedback_dry_run_flag_accepted" test_feedback_dry_run_flag_accepted
_run "feedback_empty_workspace" test_feedback_empty_workspace
_run "drift_none" test_drift_none_label
_run "drift_minor" test_drift_minor_label
_run "drift_major" test_drift_major_label
_run "parse_feedback_payload_valid" test_parse_feedback_payload_valid
_run "parse_feedback_payload_invalid" test_parse_feedback_payload_invalid
_run "get_ticket_initiative_reads_manifest" test_get_ticket_initiative_reads_manifest
_run "get_ticket_initiative_no_manifest_yields_nothing" test_get_ticket_initiative_no_manifest_yields_nothing
_run "feedback_writer_groups_by_initiative_end_to_end" test_feedback_writer_groups_by_initiative_end_to_end
_run "readiness_gap_ticket_with_no_planner_feedback_is_scanned" test_readiness_gap_ticket_with_no_planner_feedback_is_scanned
_run "readiness_gap_only_initiative_has_zeroed_feedback_fields" test_readiness_gap_only_initiative_has_zeroed_feedback_fields
_run "readiness_gap_multiple_codes_multiple_tickets_break_down_per_code" test_readiness_gap_multiple_codes_multiple_tickets_break_down_per_code
_run "readiness_gap_recurrence_counts_occurrences_not_distinct_tickets" test_readiness_gap_recurrence_counts_occurrences_not_distinct_tickets
_run "readiness_gap_verify_no_test_user_is_scanned" test_readiness_gap_verify_no_test_user_is_scanned
_run "readiness_gap_clean_initiative_reports_empty_not_absent" test_readiness_gap_clean_initiative_reports_empty_not_absent
_run "readiness_gap_log_marker_literals_have_not_drifted" test_readiness_gap_log_marker_literals_have_not_drifted

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
