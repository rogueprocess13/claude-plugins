#!/usr/bin/env bash
# test-fleet-detect-attention.sh — PO-5: gate-stopped, exhausted and
# dead-lettered pipelines must stay visible in fleet_detect_all output and on
# the dashboard/report ("Needs attention"), with their reason. Completed and
# held pipelines must not be listed there.
# Usage: bash test-fleet-detect-attention.sh
# -u (nounset) intentionally omitted, same as test-fleet-detect.sh.
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

_line() {
  local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6"
  local iso="${7:-2026-06-02T10:00:00Z}"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
}

# A workspace with one ticket per terminal shape. FLEET_STORE_ENABLE=false
# and an isolated FLEET_STATE_DIR keep the detectors on the log files.
_build_workspace() {
  local ws="$1"
  _line "$ws" "CRE-1" "EXEC" "exec" "fail" "no artifact"
  _line "$ws" "CRE-1" "META" "gate-stop" "fail" "EXEC_NO_ARTIFACT"
  _line "$ws" "CRE-1" "META" "outcome" "info" "stopped: gate-stop EXEC_NO_ARTIFACT"

  _line "$ws" "CRE-2" "VERIFY" "verify" "fail" "VERIFY_EXHAUSTED"
  _line "$ws" "CRE-2" "META" "outcome" "info" "stopped: VERIFY_EXHAUSTED"

  _line "$ws" "CRE-3" "IMPLEMENT" "implement" "waiting" "agent launched"
  _line "$ws" "CRE-3" "META" "dead-letter" "warn" "reason=orphaned-after-max-restarts"

  _line "$ws" "CRE-4" "META" "outcome" "info" "completed: STEP_6"

  _line "$ws" "CRE-5" "GATE" "gate" "fail" "held: complex ticket"
  _line "$ws" "CRE-5" "META" "outcome" "info" "held: gate"
}

_detect_json() {
  local ws="$1"
  (
    export FLEET_STATE_DIR="$ws" FLEET_STORE_ENABLE=false
    source "$LIB_DIR/fleet-detect.sh" 2>/dev/null
    fleet_detect_all "$ws" 2>/dev/null
  )
}

test_detect_all_lists_stopped_and_dead_lettered() {
  local ws json rc=0
  ws=$(mktemp -d)
  _build_workspace "$ws"
  json=$(_detect_json "$ws")
  rm -rf "$ws"
  echo "$json" | jq -e '(.attention | map(.tid) | sort) == ["CRE-1","CRE-2","CRE-3"]' >/dev/null || {
    echo "attention tids wrong: $(echo "$json" | jq -c '.attention')" >&2
    rc=1
  }
  echo "$json" | jq -e '.attention[] | select(.tid=="CRE-1") | .kind=="stopped" and (.reason | contains("EXEC_NO_ARTIFACT"))' >/dev/null || {
    echo "gate-stop reason missing" >&2
    rc=1
  }
  echo "$json" | jq -e '.attention[] | select(.tid=="CRE-2") | .reason=="VERIFY_EXHAUSTED"' >/dev/null || {
    echo "exhausted reason missing" >&2
    rc=1
  }
  echo "$json" | jq -e '.attention[] | select(.tid=="CRE-3") | .kind=="dead-letter" and .reason=="orphaned-after-max-restarts" and (.age_secs > 0)' >/dev/null || {
    echo "dead-letter entry wrong" >&2
    rc=1
  }
  # Stopped pipelines still stay out of the health table and counts.
  echo "$json" | jq -e '[.pipelines[].tid] | index("CRE-1") == null' >/dev/null || rc=1
  return "$rc"
}

test_detect_all_missing_workspace_has_empty_attention() {
  local json
  json=$(_detect_json "/nonexistent/fleet-attention-$$")
  echo "$json" | jq -e '.attention == []' >/dev/null
}

test_dashboard_and_report_show_needs_attention() {
  local ws json out rc=0
  ws=$(mktemp -d)
  _build_workspace "$ws"
  json=$(_detect_json "$ws")
  out=$(
    export FLEET_STATE_DIR="$ws" FLEET_STORE_ENABLE=false
    source "$LIB_DIR/fleet-dashboard.sh" 2>/dev/null
    fleet_render_dashboard_from_data "$json" "$ws" 2>/dev/null
    fleet_write_report_from_data "$json" "$ws" 2>/dev/null
  )
  echo "$out" | grep -q "Needs Attention" || {
    echo "dashboard has no Needs Attention section: $out" >&2
    rc=1
  }
  echo "$out" | grep -q "CRE-1  stopped: gate-stop EXEC_NO_ARTIFACT" || {
    echo "dashboard missing gate-stop line: $out" >&2
    rc=1
  }
  echo "$out" | grep -q "CRE-3  dead-letter: orphaned-after-max-restarts" || {
    echo "dashboard missing dead-letter line" >&2
    rc=1
  }
  if echo "$out" | grep -qE "^  CRE-(4|5) "; then
    echo "completed/held ticket listed under Needs Attention" >&2
    rc=1
  fi
  local report="$ws/reports/fleet-dashboard.md"
  grep -q "## Needs Attention" "$report" 2>/dev/null || {
    echo "report has no Needs Attention section" >&2
    rc=1
  }
  grep -q "| CRE-2 | stopped | VERIFY_EXHAUSTED |" "$report" 2>/dev/null || {
    echo "report missing exhausted row: $(cat "$report" 2>/dev/null)" >&2
    rc=1
  }
  rm -rf "$ws"
  return "$rc"
}

_run "detect_all_lists_stopped_and_dead_lettered" test_detect_all_lists_stopped_and_dead_lettered
_run "detect_all_missing_workspace_has_empty_attention" test_detect_all_missing_workspace_has_empty_attention
_run "dashboard_and_report_show_needs_attention" test_dashboard_and_report_show_needs_attention

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
