#!/usr/bin/env bash
# linear-shapes.sh — shared fixtures for the tracker client's declared
# response shape (tracker-client-consolidation, design D3).
#
# Every test that stubs get_issue()/get_epics_by_label() output must build
# its stub from these functions rather than hand-rolling a shape — that is
# what makes a future shape change break every dependent test at once
# instead of one silently drifting out of sync and passing against a
# payload no production caller actually receives (the exact bug this
# change fixes in fleet-feedback.sh).
#
# Sourceable only — no shebang execution, no side effects.

# fixture_issue_json <id> <identifier> [label_csv] [state_name]
# Canonical unwrapped get_issue() shape — no .data.issue prefix.
fixture_issue_json() {
  local id="$1" identifier="$2" label_csv="${3:-}" state_name="${4:-Backlog}"
  local labels_json="[]"
  if [ -n "$label_csv" ]; then
    labels_json=$(echo "$label_csv" | tr ',' '\n' | jq -R '{name: .}' | jq -sc '.')
  fi
  jq -nc \
    --arg id "$id" \
    --arg identifier "$identifier" \
    --arg state "$state_name" \
    --argjson labels "$labels_json" \
    '{id: $id, identifier: $identifier, state: {name: $state}, labels: {nodes: $labels}}'
}

# fixture_epics_by_label_json <epic_identifier> [children_json_array] [label_csv]
# Canonical unwrapped get_epics_by_label() shape — a bare JSON array, no
# .data.issues.nodes prefix.
fixture_epics_by_label_json() {
  local epic_identifier="$1"
  local children_json="${2:-[]}"
  local label_csv="${3:-state:execution}"
  local labels_json
  labels_json=$(echo "$label_csv" | tr ',' '\n' | jq -R '{name: .}' | jq -sc '.')
  jq -nc \
    --arg id "$epic_identifier" \
    --argjson labels "$labels_json" \
    --argjson children "$children_json" \
    '[{id: $id, identifier: $id, title: "Test Epic", labels: {nodes: $labels}, children: {nodes: $children}}]'
}

# fixture_child_json <identifier> [state_name] [label_csv] [priority]
# One child node in the shape get_epics_by_label()'s children carry.
fixture_child_json() {
  local identifier="$1" state_name="${2:-Backlog}" label_csv="${3:-planned}" priority="${4:-0}"
  local labels_json
  labels_json=$(echo "$label_csv" | tr ',' '\n' | jq -R '{name: .}' | jq -sc '.')
  jq -nc \
    --arg id "$identifier" \
    --arg state "$state_name" \
    --argjson labels "$labels_json" \
    --argjson priority "$priority" \
    '{id: $id, identifier: $id, title: "Test Child", state: {name: $state}, labels: {nodes: $labels}, priority: $priority}'
}
