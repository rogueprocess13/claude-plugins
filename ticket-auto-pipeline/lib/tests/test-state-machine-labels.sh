#!/usr/bin/env bash
# test-state-machine-labels.sh — verify planner labels in workflow.json
# Usage: bash test-state-machine-labels.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM="${SCRIPT_DIR}/../../skills/ticket-flow/workflow.json"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the executor's own precondition evaluator. These tests previously
# re-implemented the condition inline and asserted on their own local variable,
# which is why an always-true discriminator survived with a green suite.
source "$LIB_DIR/planned-ticket-check.sh" 2>/dev/null || true
source "$LIB_DIR/branch-directive-check.sh" 2>/dev/null || true
source "$LIB_DIR/epic-precondition.sh"

# Issue payloads in the shape get_issue returns.
EPIC_BY_LABEL_JSON='{"identifier":"INIT-42","description":"An initiative epic.","labels":{"nodes":[{"name":"epic"},{"name":"planned"}]}}'
EPIC_BY_DIRECTIVE_JSON='{"identifier":"INIT-43","description":"## Branch Directive\n**Schema-Version:** 1\n**Branch:** epic/phase-a\n**Base:** develop\n**Merge Policy:** manual\n**Sync Policy:** none\n**Created:** 2026-07-25T10:00:00Z","labels":{"nodes":[]}}'
CHILD_BUG_JSON='{"identifier":"CRE-9","description":"Fix the auth bug.","labels":{"nodes":[{"name":"bug"},{"name":"planned"}]}}'
CHILD_TASK_JSON='{"identifier":"CRE-10","description":"A task.","labels":{"nodes":[{"name":"chore"}]}}'

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

echo "=== workflow.json planner labels tests ==="
echo ""

# ── Test: workflow.json exists and is valid JSON ──────────────────────

test_valid_json() {
  jq '.' "$SM" >/dev/null 2>&1
}

# tracker-planner-and-fallback-cutover (4.7): the planner_labels section
# these tests used to check (planned, INIT-*, pre-approved, blocked-by:*,
# state:execution, and the 5 type labels) is removed from workflow.json —
# the planner writes no labels at all now, so there is nothing left to
# assert about a section that no longer exists. must_be_epic enforcement is
# exercised directly via check_precondition below (test_precondition_epic_passes
# and friends), independent of any workflow.json label declaration.

test_planner_labels_section_removed() {
  jq -e '.planner_labels' "$SM" >/dev/null 2>&1 && return 1
  return 0
}

# ── Test: well_known_labels reflects only genuinely required labels ────────

test_well_known_labels_no_retired_planner_labels() {
  local labels
  labels=$(jq -r '.well_known_labels | join(",")' "$SM")
  echo "$labels" | grep -qw "bug" && return 1
  echo "$labels" | grep -qw "feature" && return 1
  return 0
}

# ── Test: existing triggers intact ──────────────────────────────────────────

test_triggers_intact() {
  local count
  count=$(jq -r '.triggers | keys | length' "$SM")
  [ "$count" -ge 15 ]
}

# ── Test: pre-approved label removed by human-reject trigger ────────────────

test_human_reject_removes_pre_approved() {
  local removes
  removes=$(jq -r '.triggers."human-reject".removes | join(",")' "$SM")
  echo "$removes" | grep -q "pre-approved"
}

# ── Test: pre-approved label removed by re-claim trigger ────────────────────

test_re_claim_removes_pre_approved() {
  local removes
  removes=$(jq -r '.triggers."re-claim".removes | join(",")' "$SM")
  echo "$removes" | grep -q "pre-approved"
}

# ── Precondition evaluation (exercises the executor's real code path) ───────

test_precondition_epic_passes() {
  # must_be_epic is a literal here, not read from workflow.json's
  # planner_labels — tracker-flow-projection-cutover removed that field
  # (state:execution is applied directly by the planner, never through a
  # flow.sh trigger, so no trigger ever needed it there). These tests
  # exercise check_precondition/epic-precondition.sh's generic behavior,
  # not workflow.json structure.
  local precondition="must_be_epic" rc=0
  check_precondition "$precondition" "state:execution" "$EPIC_BY_LABEL_JSON" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "  epic carrying the marker label was rejected (rc=$rc)" >&2
    return 1
  }
  return 0
}

test_precondition_epic_by_directive_passes() {
  local precondition="must_be_epic" rc=0
  check_precondition "$precondition" "state:execution" "$EPIC_BY_DIRECTIVE_JSON" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "  epic identified by a valid Branch Directive was rejected (rc=$rc)" >&2
    return 1
  }
  return 0
}

test_precondition_bug_rejected() {
  local precondition="must_be_epic" rc=0
  check_precondition "$precondition" "state:execution" "$CHILD_BUG_JSON" 2>/dev/null || rc=$?
  [ "$rc" -eq 8 ] || {
    echo "  expected rejection (8) for a non-epic bug, got rc=$rc" >&2
    return 1
  }
  return 0
}

test_precondition_task_rejected() {
  local precondition="must_be_epic" rc=0
  check_precondition "$precondition" "state:execution" "$CHILD_TASK_JSON" 2>/dev/null || rc=$?
  [ "$rc" -eq 8 ] || {
    echo "  expected rejection (8) for a non-epic task, got rc=$rc" >&2
    return 1
  }
  return 0
}

# ── Bidirectional guard ─────────────────────────────────────────────────────

test_epic_trigger_rejected_on_child() {
  local precondition rc=0
  precondition=$(jq -r '.triggers."epic-uat-pass".precondition // empty' "$SM")
  [ "$precondition" = "must_be_epic" ] || {
    echo "  epic-uat-pass is missing its must_be_epic precondition" >&2
    return 1
  }
  check_precondition "$precondition" "epic-uat-pass" "$CHILD_BUG_JSON" 2>/dev/null || rc=$?
  [ "$rc" -eq 8 ] || {
    echo "  epic trigger accepted on a child ticket (rc=$rc)" >&2
    return 1
  }
  return 0
}

test_epic_trigger_accepted_on_epic() {
  local precondition rc=0
  precondition=$(jq -r '.triggers."epic-integration-open".precondition // empty' "$SM")
  check_precondition "$precondition" "epic-integration-open" "$EPIC_BY_LABEL_JSON" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "  epic trigger rejected on an epic (rc=$rc)" >&2
    return 1
  }
  return 0
}

test_child_trigger_rejected_on_epic() {
  # Without this inverse, an epic pushed through the ticket pipeline would take
  # the child pass-to-Done trigger and close itself.
  local precondition rc=0
  precondition=$(jq -r '.triggers."pr-review-pass-done".precondition // empty' "$SM")
  [ "$precondition" = "must_not_be_epic" ] || {
    echo "  pr-review-pass-done is missing its must_not_be_epic precondition" >&2
    return 1
  }
  check_precondition "$precondition" "pr-review-pass-done" "$EPIC_BY_LABEL_JSON" 2>/dev/null || rc=$?
  [ "$rc" -eq 8 ] || {
    echo "  child trigger accepted on an epic (rc=$rc)" >&2
    return 1
  }
  return 0
}

test_child_trigger_accepted_on_child() {
  local precondition rc=0
  precondition=$(jq -r '.triggers."pr-review-pass-done".precondition // empty' "$SM")
  check_precondition "$precondition" "pr-review-pass-done" "$CHILD_BUG_JSON" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "  child trigger rejected on a child ticket (rc=$rc)" >&2
    return 1
  }
  return 0
}

test_unknown_precondition_is_refused() {
  local rc=0
  check_precondition "must_be_purple" "some-trigger" "$CHILD_BUG_JSON" 2>/dev/null || rc=$?
  [ "$rc" -eq 9 ] || {
    echo "  unknown precondition should be refused with 9, got rc=$rc" >&2
    return 1
  }
  return 0
}

# ── Epic acceptance triggers ────────────────────────────────────────────────

test_epic_triggers_registered() {
  local t
  for t in epic-integration-open epic-uat-start epic-uat-pass; do
    jq -e --arg t "$t" '.triggers[$t]' "$SM" >/dev/null 2>&1 || {
      echo "  missing trigger: $t" >&2
      return 1
    }
  done
  return 0
}

test_epic_triggers_add_no_labels() {
  # Empty label sets keep the post-transition assertion a pure state check, so
  # no label needs to exist in the workspace.
  local t adds removes
  for t in epic-integration-open epic-uat-start epic-uat-pass; do
    adds=$(jq -r --arg t "$t" '.triggers[$t].adds | length' "$SM")
    removes=$(jq -r --arg t "$t" '.triggers[$t].removes | length' "$SM")
    [ "$adds" = "0" ] && [ "$removes" = "0" ] || {
      echo "  $t must add/remove no labels (adds=$adds removes=$removes)" >&2
      return 1
    }
  done
  return 0
}

test_epic_triggers_have_scalar_from() {
  # A multi-valued source renders as a multi-line string, truncating the
  # pipeline log entry and producing invalid telemetry JSON.
  local t
  for t in epic-integration-open epic-uat-start epic-uat-pass; do
    jq -e --arg t "$t" '.triggers[$t].from | type == "string"' "$SM" >/dev/null 2>&1 || {
      echo "  $t must declare a single-valued from" >&2
      return 1
    }
  done
  return 0
}

test_epic_triggers_use_existing_states() {
  local known t to from
  known=$(jq -r '[(.triggers | to_entries[] | .value | (.from, .to) | select(. != null) | if type == "array" then .[] else . end), (.well_known_states[]? // empty)] | unique | join(",")' "$SM")
  for t in epic-integration-open epic-uat-start epic-uat-pass; do
    from=$(jq -r --arg t "$t" '.triggers[$t].from' "$SM")
    to=$(jq -r --arg t "$t" '.triggers[$t].to' "$SM")
    echo "$known" | tr ',' '\n' | grep -qx "$from" || {
      echo "  $t references unknown from-state $from" >&2
      return 1
    }
    echo "$known" | tr ',' '\n' | grep -qx "$to" || {
      echo "  $t references unknown to-state $to" >&2
      return 1
    }
  done
  return 0
}

# ── Run tests ──────────────────────────────────────────────────────────────

_run "valid JSON" test_valid_json
_run "planner_labels section removed" test_planner_labels_section_removed
_run "well_known_labels has no retired planner labels" test_well_known_labels_no_retired_planner_labels
_run "existing triggers intact" test_triggers_intact
_run "human-reject trigger removes pre-approved" test_human_reject_removes_pre_approved
_run "re-claim trigger removes pre-approved" test_re_claim_removes_pre_approved
_run "precondition logic: Epic passes" test_precondition_epic_passes
_run "precondition logic: Epic identified by Branch Directive passes" test_precondition_epic_by_directive_passes
_run "bidirectional guard: epic trigger rejected on child" test_epic_trigger_rejected_on_child
_run "bidirectional guard: epic trigger accepted on epic" test_epic_trigger_accepted_on_epic
_run "bidirectional guard: child trigger rejected on epic" test_child_trigger_rejected_on_epic
_run "bidirectional guard: child trigger accepted on child" test_child_trigger_accepted_on_child
_run "unknown precondition is refused" test_unknown_precondition_is_refused
_run "epic acceptance triggers registered" test_epic_triggers_registered
_run "epic triggers add no labels" test_epic_triggers_add_no_labels
_run "epic triggers declare scalar from" test_epic_triggers_have_scalar_from
_run "epic triggers reference existing states only" test_epic_triggers_use_existing_states
_run "precondition logic: Bug rejected" test_precondition_bug_rejected
_run "precondition logic: Task rejected" test_precondition_task_rejected

echo ""
echo "=== $((PASS + FAIL)) tests: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ] || exit 1
