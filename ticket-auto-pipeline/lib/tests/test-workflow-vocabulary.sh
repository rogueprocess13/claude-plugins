#!/usr/bin/env bash
# test-workflow-vocabulary.sh — structural coherence tests for
# skills/ticket-flow/workflow.json's vocabulary section
# (tracker-event-vocabulary-and-emitter). These protect the exact invariants
# flow.sh's generic dual-write lookup (Section 6) and emit_event's closed-
# vocabulary check (Section 3.5) depend on — a fast, mock-free complement to
# task 6.2's "flow.sh transition produces a matching outbox record" claim,
# which lib/tests/test-events.sh and lib/tests/test-branch-resolve.sh already
# exercise at the emit_event/uat_decide_trigger level.
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
WF="$LIB_DIR/../skills/ticket-flow/workflow.json"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

test_workflow_json_is_valid() {
  jq empty "$WF"
}

test_every_trigger_except_uat_pair_has_exactly_one_event() {
  local trigger mapped_count
  while IFS= read -r trigger; do
    case "$trigger" in
    pr-review-pass-done | pr-review-pass-uat)
      mapped_count=$(jq --arg t "$trigger" \
        '[.vocabulary | to_entries[] | select(.value.trigger == $t)] | length' "$WF")
      [ "$mapped_count" -eq 0 ] || {
        echo "  $trigger: expected 0 generic vocabulary mappings (handled by uat_decide_trigger), got $mapped_count" >&2
        return 1
      }
      ;;
    *)
      mapped_count=$(jq --arg t "$trigger" \
        '[.vocabulary | to_entries[] | select(.value.trigger == $t)] | length' "$WF")
      [ "$mapped_count" -eq 1 ] || {
        echo "  $trigger: expected exactly 1 vocabulary mapping, got $mapped_count" >&2
        return 1
      }
      ;;
    esac
  done < <(jq -r '.triggers | keys[]' "$WF")
  return 0
}

test_every_vocabulary_trigger_field_names_a_real_trigger() {
  local ev
  while IFS= read -r ev; do
    local t exists
    t=$(jq -r --arg e "$ev" '.vocabulary[$e].trigger' "$WF")
    [ "$t" = "null" ] && continue
    exists=$(jq --arg t "$t" '.triggers | has($t)' "$WF")
    [ "$exists" = "true" ] || {
      echo "  vocabulary.$ev.trigger='$t' does not name a real trigger" >&2
      return 1
    }
  done < <(jq -r '.vocabulary | keys[]' "$WF")
  return 0
}

test_no_event_name_is_a_linear_state_or_label_verbatim() {
  local states labels ev
  states=$(jq -r '[(.triggers | to_entries[] | .value | (.from, .to) | select(. != null) | if type == "array" then .[] else . end), (.well_known_states[]? // empty)] | unique | .[]' "$WF")
  labels=$(jq -r '[(.triggers | to_entries[] | .value | (.adds[]?, .removes[]?) | select(. != null)), (.well_known_labels[]? // empty)] | unique | .[]' "$WF" | grep -v '{')
  while IFS= read -r ev; do
    if grep -qxF "$ev" <<<"$states"; then
      echo "  event '$ev' is a Linear state name verbatim" >&2
      return 1
    fi
    if grep -qxF "$ev" <<<"$labels"; then
      echo "  event '$ev' is a Linear label name verbatim" >&2
      return 1
    fi
  done < <(jq -r '.vocabulary | keys[]' "$WF")
  return 0
}

test_pr_review_passed_declared_with_bool_payload() {
  local uat_required_type
  uat_required_type=$(jq -r '.vocabulary["pr-review-passed"].payload.uat_required' "$WF")
  [ "$uat_required_type" = "bool" ]
}

test_ten_new_facts_all_declared() {
  local ev
  for ev in gate-held gate-released human-hold-requested human-hold-released \
    pr-opened pr-merged verify-failed-retrying ticket-killed blocked unblocked; do
    jq -e --arg e "$ev" '.vocabulary[$e] != null' "$WF" >/dev/null || {
      echo "  missing vocabulary entry: $ev" >&2
      return 1
    }
  done
  return 0
}

test_board_drivers_linear_is_registered_with_no_mappings() {
  # B2 (tracker-event-board-pusher) populates board_drivers.linear as {} —
  # driver registered, no active event mappings yet, distinct from the
  # field not existing at all. This replaces the B1-era assertion that
  # board_drivers equalled {} at the top level.
  local exists v
  exists=$(jq -r '.board_drivers.linear != null' "$WF")
  [ "$exists" = "true" ] || {
    echo "  board_drivers.linear does not exist" >&2
    return 1
  }
  v=$(jq -c '.board_drivers.linear' "$WF")
  [ "$v" = "{}" ]
}

_run "workflow.json is valid JSON" test_workflow_json_is_valid
_run "every trigger maps to exactly one vocabulary event (UAT pair maps to zero)" test_every_trigger_except_uat_pair_has_exactly_one_event
_run "every vocabulary 'trigger' field names a real trigger" test_every_vocabulary_trigger_field_names_a_real_trigger
_run "no event name is a Linear state/label name verbatim" test_no_event_name_is_a_linear_state_or_label_verbatim
_run "pr-review-passed declares uat_required as bool" test_pr_review_passed_declared_with_bool_payload
_run "all ten new (non-trigger) facts are declared" test_ten_new_facts_all_declared
_run "board_drivers.linear is registered with no mappings yet (B2)" test_board_drivers_linear_is_registered_with_no_mappings

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
