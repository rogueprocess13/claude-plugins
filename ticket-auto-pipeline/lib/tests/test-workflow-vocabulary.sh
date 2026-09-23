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

# ── tracker-flow-projection-cutover (Change 2): the projection table ───────

test_every_vocabulary_event_has_board_drivers_entry() {
  local ev has
  while IFS= read -r ev; do
    has=$(jq -r --arg e "$ev" '.board_drivers.linear.events | has($e)' "$WF")
    [ "$has" = "true" ] || {
      echo "  vocabulary event '$ev' has no board_drivers.linear.events entry (object or explicit null)" >&2
      return 1
    }
  done < <(jq -r '.vocabulary | keys[]' "$WF")
  return 0
}

test_board_drivers_labels_confined_to_projected_set() {
  local bad
  bad=$(jq -r '
    .board_drivers.linear.projected_labels as $p
    | .board_drivers.linear.events
    | to_entries[]
    | select(.value != null)
    | .key as $ev
    | (.value.add[]?, .value.remove[]?)
    | select(. as $l | $p | index($l) | not)
    | "\($ev): \(.)"
  ' "$WF")
  [ -z "$bad" ] || {
    echo "  labels outside projected_labels found in board_drivers.linear.events: $bad" >&2
    return 1
  }
  return 0
}

test_board_drivers_agrees_with_single_trigger_label_delta() {
  local ev triggers_producing count t_adds t_removes projected entry_add entry_remove expected_add expected_remove
  while IFS= read -r ev; do
    triggers_producing=$(jq -r --arg e "$ev" '[.triggers | to_entries[] | select(.value.emits.event == $e) | .key]' "$WF")
    count=$(echo "$triggers_producing" | jq 'length')
    [ "$count" -eq 1 ] || continue
    t=$(echo "$triggers_producing" | jq -r '.[0]')
    projected=$(jq -c '.board_drivers.linear.projected_labels' "$WF")
    expected_add=$(jq -c --arg t "$t" --argjson p "$projected" \
      '(.triggers[$t].adds // []) as $a | [$a[] | select(. as $x | $p | index($x))] | sort' "$WF")
    expected_remove=$(jq -c --arg t "$t" --argjson p "$projected" \
      '(.triggers[$t].removes // []) as $r | [$r[] | select(. as $x | $p | index($x))] | sort' "$WF")
    entry_add=$(jq -c --arg e "$ev" '(.board_drivers.linear.events[$e].add // []) | sort' "$WF")
    entry_remove=$(jq -c --arg e "$ev" '(.board_drivers.linear.events[$e].remove // []) | sort' "$WF")
    [ "$entry_add" = "$expected_add" ] || {
      echo "  $ev (trigger $t): board_drivers add $entry_add != trigger adds ∩ projected_labels $expected_add" >&2
      return 1
    }
    [ "$entry_remove" = "$expected_remove" ] || {
      echo "  $ev (trigger $t): board_drivers remove $entry_remove != trigger removes ∩ projected_labels $expected_remove" >&2
      return 1
    }
  done < <(jq -r '.vocabulary | keys[]' "$WF")
  return 0
}

test_every_emits_names_a_declared_vocabulary_event() {
  local t ev exists
  while IFS= read -r t; do
    ev=$(jq -r --arg t "$t" '.triggers[$t].emits.event // empty' "$WF")
    [ -z "$ev" ] && continue
    exists=$(jq --arg e "$ev" '.vocabulary | has($e)' "$WF")
    [ "$exists" = "true" ] || {
      echo "  trigger '$t' emits undeclared event '$ev'" >&2
      return 1
    }
  done < <(jq -r '.triggers | keys[]' "$WF")
  return 0
}

# ── 3.6a namespace assertion: board_drivers.<board_id> is the only place a
# board's own column/label-projection shape (the keys "column"/"add"/
# "remove"/"assignee") may appear. A closed key-schema on `triggers[*]` and
# `vocabulary[*]` is what actually enforces this — it is what would catch a
# regression that moves a column mapping out of board_drivers into either
# section, which is exactly what the fixture test below proves.
_ALLOWED_TRIGGER_KEYS='["from","to","adds","removes","description","precondition","verdict_gate","emits"]'
_ALLOWED_VOCAB_KEYS='["trigger","data_from","payload","description","emitted_by"]'

_workflow_namespace_check() {
  local wf="$1"
  local bad
  bad=$(jq -r --argjson allowed "$_ALLOWED_TRIGGER_KEYS" '
    .triggers | to_entries[] | .key as $t | (.value | keys) as $k
    | ($k - $allowed) | select(length > 0) | "trigger \($t): \(.)"
  ' "$wf")
  [ -z "$bad" ] || {
    echo "  stray keys on triggers (board vocabulary leaked outside board_drivers): $bad" >&2
    return 1
  }
  bad=$(jq -r --argjson allowed "$_ALLOWED_VOCAB_KEYS" '
    .vocabulary | to_entries[] | .key as $e | (.value | keys) as $k
    | ($k - $allowed) | select(length > 0) | "vocabulary \($e): \(.)"
  ' "$wf")
  [ -z "$bad" ] || {
    echo "  stray keys on vocabulary (board vocabulary leaked outside board_drivers): $bad" >&2
    return 1
  }
  return 0
}

test_namespace_check_passes_on_real_workflow_json() {
  _workflow_namespace_check "$WF"
}

# Proof required by task 3.6a: the assertion fails when a column name is
# moved from a board_drivers entry into a trigger definition — demonstrated
# against a deliberately-broken fixture, not by inspection.
test_namespace_check_fails_on_broken_fixture() {
  local fixture rc=0
  fixture=$(mktemp)
  jq '.triggers["appraise-complete"].column = "Done"' "$WF" >"$fixture"
  _workflow_namespace_check "$fixture" 2>/dev/null || rc=$?
  rm -f "$fixture"
  [ "$rc" -eq 1 ]
}

_run "workflow.json is valid JSON" test_workflow_json_is_valid
_run "every trigger maps to exactly one vocabulary event (UAT pair maps to zero)" test_every_trigger_except_uat_pair_has_exactly_one_event
_run "every vocabulary 'trigger' field names a real trigger" test_every_vocabulary_trigger_field_names_a_real_trigger
_run "no event name is a Linear state/label name verbatim" test_no_event_name_is_a_linear_state_or_label_verbatim
_run "pr-review-passed declares uat_required as bool" test_pr_review_passed_declared_with_bool_payload
_run "all ten new (non-trigger) facts are declared" test_ten_new_facts_all_declared
_run "every vocabulary event has a board_drivers.linear.events entry" test_every_vocabulary_event_has_board_drivers_entry
_run "board_drivers labels are confined to projected_labels" test_board_drivers_labels_confined_to_projected_set
_run "board_drivers agrees with the single trigger it mirrors" test_board_drivers_agrees_with_single_trigger_label_delta
_run "every trigger emits declaration names a declared vocabulary event" test_every_emits_names_a_declared_vocabulary_event
_run "namespace check passes on the real workflow.json" test_namespace_check_passes_on_real_workflow_json
_run "namespace check fails on a deliberately-broken fixture" test_namespace_check_fails_on_broken_fixture

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
