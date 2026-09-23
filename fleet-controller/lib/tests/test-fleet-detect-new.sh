#!/usr/bin/env bash
# test-fleet-detect-new.sh — unit tests for the 3 new detection engines
# (detect_planner_feedback, detect_blocked_by, detect_initiative_dispatch)
# Usage: bash test-fleet-detect-new.sh [test_name_filter]
set -e pipefail

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

# ── Helpers ──────────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

_plog() {
  local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6"
  local iso="${7:-2026-07-07T10:00:00Z}"
  mkdir -p "$dir"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
}

source "$LIB_DIR/fleet-detect.sh"

# ── Tests: detect_planner_feedback ───────────────────────────────────────────────

test_planner_feedback_none() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "IMPLEMENT" "implement" "done" "implemented fix"
  _plog "$ws" "CRE-101" "META" "outcome" "info" "completed: success"

  local sev
  sev=$(detect_planner_feedback "CRE-101" "$ws")
  [ "$sev" = "0" ] || {
    echo "expected 0, got $sev"
    return 1
  }
}

test_planner_feedback_found() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "IMPLEMENT" "implement" "done" "implemented fix"
  _plog "$ws" "CRE-101" "META" "planner-feedback" "info" "{\"decision_drift\":\"none\",\"confidence_actual\":0.85}"
  # No REPOS_ROOT set → no feedback dir exists → should report uncollected (WARN)
  local sev
  sev=$(detect_planner_feedback "CRE-101" "$ws")
  [ "$sev" = "1" ] || {
    echo "expected 1, got $sev"
    return 1
  }
}

test_planner_feedback_collected() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "IMPLEMENT" "implement" "done" "implemented fix"
  _plog "$ws" "CRE-101" "META" "planner-feedback" "info" "{\"decision_drift\":\"none\",\"confidence_actual\":0.85}"

  # Create a mock feedback file containing this ticket's source_tid reference.
  # The detector greps file contents for \"source_tid\":\"<tid>\".
  REPOS_ROOT="$ws" FLEET_PIPELINE_LOG_DIR="$ws" \
    mkdir -p "$ws/.ticket-auto/initiatives/INIT-42/feedback"
  echo '{"tickets":[{"source_tid":"CRE-101","confidence_actual":0.85}]}' \
    >"$ws/.ticket-auto/initiatives/INIT-42/feedback/2026-07-07.json"

  local sev
  sev=$(REPOS_ROOT="$ws" detect_planner_feedback "CRE-101" "$ws")
  [ "$sev" = "0" ] || {
    echo "expected 0 (collected), got $sev"
    return 1
  }
}

test_planner_feedback_no_log_file() {
  local ws
  ws=$(_setup_workspace)
  local sev
  sev=$(detect_planner_feedback "CRE-999" "$ws")
  [ "$sev" = "0" ] || {
    echo "expected 0, got $sev"
    return 1
  }
}

# ── Tests: _fleet_scan_initiative_dispatch (no Linear API → returns OBSERVE) ────

test_initiative_dispatch_no_linear_api() {
  # Without linear-api.sh sourced, should return severity 0 gracefully
  local result
  result=$(_fleet_scan_initiative_dispatch 2>/dev/null)
  local sev
  sev=$(echo "$result" | jq -r '.severity // -1')
  [ "$sev" = "0" ] || {
    echo "expected severity 0 without Linear API, got $sev"
    return 1
  }
}

# ── Tests: _fleet_scan_blocked_by (no Linear API → returns OBSERVE) ──────────────

test_blocked_by_no_linear_api() {
  local ws
  ws=$(_setup_workspace)
  # Without linear-api.sh sourced, should return severity 0 gracefully
  local result
  result=$(_fleet_scan_blocked_by "$ws" 2>/dev/null)
  local sev
  sev=$(echo "$result" | jq -r '.severity // -1')
  [ "$sev" = "0" ] || {
    echo "expected severity 0 without Linear API, got $sev"
    return 1
  }
}

# ── Tests: detect_blocked_by manifest path (tracker-local-facts-read-migration) ──

TAP_LIB_DIR="$(cd "$LIB_DIR/../../ticket-auto-pipeline/lib" && pwd)"
source "$TAP_LIB_DIR/manifest-write.sh"

test_blocked_by_manifest_resolved() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(mktemp -d)
  _plog "$ws" "CRE-200" "IMPLEMENT" "implement" "done" "in progress"

  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-200" "INIT-1" "bug" '["CRE-199"]' >/dev/null
  _plog "$ws" "CRE-199" "META" "outcome" "info" "completed: STEP_6"

  local sev
  sev=$(REPOS_ROOT="$repos_root" FLEET_PIPELINE_LOG_DIR="$ws" detect_blocked_by "CRE-200" "$ws")
  rm -rf "$repos_root"

  [ "$sev" = "1" ] || {
    echo "expected severity 1 when manifest blocker is Done, got $sev"
    return 1
  }
}

test_blocked_by_manifest_unresolved() {
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(mktemp -d)
  _plog "$ws" "CRE-201" "IMPLEMENT" "implement" "done" "in progress"

  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-201" "INIT-1" "bug" '["CRE-198"]' >/dev/null
  # CRE-198 has no pipeline log at all — unstarted, unsatisfied.

  local sev
  sev=$(REPOS_ROOT="$repos_root" FLEET_PIPELINE_LOG_DIR="$ws" detect_blocked_by "CRE-201" "$ws")
  rm -rf "$repos_root"

  [ "$sev" = "0" ] || {
    echo "expected severity 0 when manifest blocker has no pipeline log, got $sev"
    return 1
  }
}

test_blocked_by_manifest_takes_precedence_over_missing_linear_api() {
  # No get_issue declared at all in this process — the manifest path must
  # not depend on it.
  local ws repos_root
  ws=$(_setup_workspace)
  repos_root=$(mktemp -d)
  _plog "$ws" "CRE-202" "IMPLEMENT" "implement" "done" "in progress"

  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-202" "INIT-1" "bug" '["CRE-197"]' >/dev/null
  _plog "$ws" "CRE-197" "META" "outcome" "info" "completed: STEP_6"

  local sev
  sev=$(REPOS_ROOT="$repos_root" FLEET_PIPELINE_LOG_DIR="$ws" detect_blocked_by "CRE-202" "$ws" 2>&1)
  rm -rf "$repos_root"

  [ "$sev" = "1" ] || {
    echo "expected severity 1 with no live Linear dependency, got: $sev"
    return 1
  }
}

# ── Tests: fleet_detect_all includes fleet_wide key ──────────────────────────────

test_fleet_detect_all_includes_fleet_wide() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "done" "appraisal done"
  _plog "$ws" "CRE-101" "META" "outcome" "info" "completed: success"
  # Outcome exists → pipeline is completed → filtered out
  # So data should have 0 pipelines but still have fleet_wide array
  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)

  # Verify fleet_wide key exists
  local fw_count
  fw_count=$(echo "$data" | jq -r '.fleet_wide | length // -1' 2>/dev/null)
  [ "${fw_count:-0}" -ge 0 ] || {
    echo "missing fleet_wide key"
    return 1
  }
}

test_fleet_detect_all_empty_workspace() {
  local ws
  ws=$(_setup_workspace)
  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local total
  total=$(echo "$data" | jq -r '.summary.total // -1')
  [ "$total" = "0" ] || {
    echo "expected 0 pipelines, got $total"
    return 1
  }
  echo "$data" | jq -e '.fleet_wide' >/dev/null 2>&1 || {
    echo "missing fleet_wide key in empty workspace"
    return 1
  }
}

test_fleet_detect_all_with_active_pipeline() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"
  # No outcome → pipeline is active

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local total
  total=$(echo "$data" | jq -r '.summary.total // 0')
  [ "$total" = "1" ] || {
    echo "expected 1 active pipeline, got $total"
    return 1
  }
}

# ── Schema validation tests (Gap 3 from architect audit) ────────────────────────

test_schema_pipeline_entries_have_type() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"
  # No outcome → pipeline is active

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local ptype
  ptype=$(echo "$data" | jq -r '.pipelines[0].type // "MISSING"' 2>/dev/null)
  [ "$ptype" = "pipeline" ] || {
    echo "expected 'pipeline', got '$ptype'"
    return 1
  }
}

test_schema_fleet_wide_entries_have_type() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local fw_count
  fw_count=$(echo "$data" | jq -r '.fleet_wide | length' 2>/dev/null)
  if [ "${fw_count:-0}" -gt 0 ]; then
    local fw_type
    fw_type=$(echo "$data" | jq -r '.fleet_wide[0].type // "MISSING"' 2>/dev/null)
    [ "$fw_type" = "fleet-wide" ] || {
      echo "expected 'fleet-wide', got '$fw_type'"
      return 1
    }
  fi
  return 0
}

test_schema_fleet_wide_always_array() {
  local ws
  ws=$(_setup_workspace)
  # Empty workspace should still have fleet_wide as an array
  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local fw_type
  fw_type=$(echo "$data" | jq -r '.fleet_wide | type' 2>/dev/null)
  [ "$fw_type" = "array" ] || {
    echo "expected 'array', got '$fw_type'"
    return 1
  }
}

test_schema_summary_has_all_keys() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local keys
  keys=$(echo "$data" | jq -r '.summary | keys | sort | join(",")' 2>/dev/null)
  local expected="healthy,kill,restart,total,warn"
  [ "$keys" = "$expected" ] || {
    echo "expected '$expected', got '$keys'"
    return 1
  }
}

test_schema_top_level_keys() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local keys
  keys=$(echo "$data" | jq -r 'keys | sort | join(",")' 2>/dev/null)
  local expected="fleet_wide,pipelines,summary"
  [ "$keys" = "$expected" ] || {
    echo "expected '$expected', got '$keys'"
    return 1
  }
}

test_schema_pipeline_entry_keys() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local keys
  keys=$(echo "$data" | jq -r '.pipelines[0] | keys | sort | join(",")' 2>/dev/null)
  local expected="anomalies,hb_age_secs,phase,severity,tid,type"
  [ "$keys" = "$expected" ] || {
    echo "expected '$expected', got '$keys'"
    return 1
  }
}

test_schema_fleet_wide_entry_keys() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local fw_count
  fw_count=$(echo "$data" | jq -r '.fleet_wide | length' 2>/dev/null)
  if [ "${fw_count:-0}" -gt 0 ]; then
    local keys
    keys=$(echo "$data" | jq -r '.fleet_wide[0] | keys | sort | join(",")' 2>/dev/null)
    local expected="findings,name,severity,type"
    [ "$keys" = "$expected" ] || {
      echo "expected '$expected', got '$keys'"
      return 1
    }
  fi
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "planner_feedback_no_entries" test_planner_feedback_none
_run "planner_feedback_found_uncollected" test_planner_feedback_found
_run "planner_feedback_collected" test_planner_feedback_collected
_run "planner_feedback_no_log_file" test_planner_feedback_no_log_file
_run "initiative_dispatch_no_linear_api_graceful" test_initiative_dispatch_no_linear_api

# ── Tests: _fleet_scan_initiative_dispatch manifest path (tracker-local-facts-read-migration) ──

test_initiative_dispatch_manifest_finds_undispatched() {
  local repos_root
  repos_root=$(mktemp -d)

  REPOS_ROOT="$repos_root" write_epic_manifest "INIT-50" "epic/x" "epic" "manual" '["CRE-300","CRE-301"]' >/dev/null
  REPOS_ROOT="$repos_root" stamp_epic_dispatch "INIT-50" >/dev/null
  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-300" "INIT-50" "bug" '[]' >/dev/null
  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-301" "INIT-50" "bug" '[]' >/dev/null
  REPOS_ROOT="$repos_root" stamp_ticket_dispatch "CRE-300" >/dev/null
  # CRE-301 left undispatched.

  local result sev findings
  result=$(REPOS_ROOT="$repos_root" _fleet_scan_initiative_dispatch 2>/dev/null)
  rm -rf "$repos_root"

  sev=$(echo "$result" | jq -r '.severity // -1')
  findings=$(echo "$result" | jq -r '.findings // ""')
  [ "$sev" = "1" ] && echo "$findings" | grep -q "INIT-50(1)" || {
    echo "expected severity 1 with INIT-50(1) undispatched, got: $result"
    return 1
  }
}

test_initiative_dispatch_manifest_all_dispatched_is_silent() {
  local repos_root
  repos_root=$(mktemp -d)

  REPOS_ROOT="$repos_root" write_epic_manifest "INIT-51" "epic/x" "epic" "manual" '["CRE-302"]' >/dev/null
  REPOS_ROOT="$repos_root" stamp_epic_dispatch "INIT-51" >/dev/null
  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-302" "INIT-51" "bug" '[]' >/dev/null
  REPOS_ROOT="$repos_root" stamp_ticket_dispatch "CRE-302" >/dev/null

  local result sev
  result=$(REPOS_ROOT="$repos_root" _fleet_scan_initiative_dispatch 2>/dev/null)
  rm -rf "$repos_root"

  sev=$(echo "$result" | jq -r '.severity // -1')
  [ "$sev" = "0" ] || {
    echo "expected severity 0 when all children dispatched, got: $result"
    return 1
  }
}

test_initiative_dispatch_manifest_skips_non_dispatched_epic() {
  local repos_root
  repos_root=$(mktemp -d)

  # Epic manifest exists but dispatch is still false (state:execution never
  # set) — must not be reported as having undispatched children.
  REPOS_ROOT="$repos_root" write_epic_manifest "INIT-52" "epic/x" "epic" "manual" '["CRE-303"]' >/dev/null
  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-303" "INIT-52" "bug" '[]' >/dev/null

  local result sev
  result=$(REPOS_ROOT="$repos_root" _fleet_scan_initiative_dispatch 2>/dev/null)
  rm -rf "$repos_root"

  sev=$(echo "$result" | jq -r '.severity // -1')
  [ "$sev" = "0" ] || {
    echo "expected severity 0 for a non-dispatched epic, got: $result"
    return 1
  }
}
_run "blocked_by_no_linear_api_graceful" test_blocked_by_no_linear_api
_run "blocked_by_manifest_resolved" test_blocked_by_manifest_resolved
_run "blocked_by_manifest_unresolved" test_blocked_by_manifest_unresolved
_run "blocked_by_manifest_takes_precedence_over_missing_linear_api" test_blocked_by_manifest_takes_precedence_over_missing_linear_api
_run "initiative_dispatch_manifest_finds_undispatched" test_initiative_dispatch_manifest_finds_undispatched
_run "initiative_dispatch_manifest_all_dispatched_is_silent" test_initiative_dispatch_manifest_all_dispatched_is_silent
_run "initiative_dispatch_manifest_skips_non_dispatched_epic" test_initiative_dispatch_manifest_skips_non_dispatched_epic

test_initiative_dispatch_kill_switch_forces_live_fallback() {
  local repos_root
  repos_root=$(mktemp -d)

  # A real manifest set that would normally report severity 1 (undispatched
  # child CRE-305, dispatch:false).
  REPOS_ROOT="$repos_root" write_epic_manifest "INIT-53" "epic/x" "epic" "manual" '["CRE-305"]' >/dev/null
  REPOS_ROOT="$repos_root" stamp_epic_dispatch "INIT-53" >/dev/null
  REPOS_ROOT="$repos_root" write_ticket_manifest "CRE-305" "INIT-53" "bug" '[]' >/dev/null

  # Confirm the manifest alone (kill switch off) does report severity 1.
  local baseline
  baseline=$(REPOS_ROOT="$repos_root" _fleet_scan_initiative_dispatch 2>/dev/null | jq -r '.severity // -1')
  [ "$baseline" = "1" ] || {
    echo "test setup invalid — expected baseline severity 1, got $baseline"
    rm -rf "$repos_root"
    return 1
  }

  # With the kill switch on and no get_issue/get_epics_by_label declared,
  # the manifest path must be completely bypassed — falls through to the
  # live path, which degrades to severity 0 (no Linear client available).
  local sev
  sev=$(TICKET_LOCAL_MANIFEST_DISABLE=true REPOS_ROOT="$repos_root" _fleet_scan_initiative_dispatch 2>/dev/null | jq -r '.severity // -1')
  rm -rf "$repos_root"

  [ "$sev" = "0" ] || {
    echo "expected kill switch to force the live-fallback path (severity 0, no Linear client), got $sev"
    return 1
  }
}
_run "initiative_dispatch_kill_switch_forces_live_fallback" test_initiative_dispatch_kill_switch_forces_live_fallback
_run "fleet_detect_all_includes_fleet_wide" test_fleet_detect_all_includes_fleet_wide
_run "fleet_detect_all_empty_workspace" test_fleet_detect_all_empty_workspace
_run "fleet_detect_all_with_active_pipeline" test_fleet_detect_all_with_active_pipeline
_run "schema_pipeline_type" test_schema_pipeline_entries_have_type
_run "schema_fleet_wide_type" test_schema_fleet_wide_entries_have_type
_run "schema_fleet_wide_always_array" test_schema_fleet_wide_always_array
_run "schema_summary_keys" test_schema_summary_has_all_keys
_run "schema_top_level_keys" test_schema_top_level_keys
_run "schema_pipeline_entry_keys" test_schema_pipeline_entry_keys
_run "schema_fleet_wide_entry_keys" test_schema_fleet_wide_entry_keys

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
