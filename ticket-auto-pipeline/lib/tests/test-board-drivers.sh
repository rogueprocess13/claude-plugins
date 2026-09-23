#!/usr/bin/env bash
# test-board-drivers.sh — unit tests for lib/board-drivers/linear.sh's real
# `apply` (tracker-flow-projection-cutover). Stubs linear-api.sh with heredoc
# get_issue/get_team/update_issue/get_me/check_api_key functions (same
# pattern phase1.sh used for flow.sh's now-deleted tracker stub), so these
# tests never touch the network.
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
DRIVER_REL="lib/board-drivers/linear.sh"

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

# _mk_workspace <events_json_fragment> <issue_json> <team_json>
# Builds a tmpdir with a stub lib/, a minimal workflow.json carrying the
# given board_drivers.linear.events fragment, and a copy of the real
# driver script (which resolves both relative to its own BASH_SOURCE).
_mk_workspace() {
  local events_json="$1" issue_json="$2" team_json="$3"
  local ws
  ws=$(mktemp -d)
  mkdir -p "$ws/lib/board-drivers" "$ws/skills/ticket-flow" "$ws/logs"
  cp "$PLUGIN_DIR/$DRIVER_REL" "$ws/lib/board-drivers/linear.sh"
  cp "$PLUGIN_DIR/lib/heartbeat.sh" "$ws/lib/heartbeat.sh"

  cat >"$ws/lib/linear-api.sh" <<STUBEOF
check_api_key() { return "\${STUB_CHECK_API_KEY_RC:-0}"; }
get_issue() {
  [ "\${STUB_GET_ISSUE_RC:-0}" -eq 0 ] || return "\${STUB_GET_ISSUE_RC}"
  cat "$ws/issue.json"
}
get_team() {
  [ "\${STUB_GET_TEAM_RC:-0}" -eq 0 ] || return "\${STUB_GET_TEAM_RC}"
  cat "$ws/team.json"
}
get_me() { echo '{"id":"me-1","name":"Test"}'; }
update_issue() {
  echo "\$@" >>"$ws/update_issue.calls"
  echo "\$3" >>"$ws/update_issue.labels"
  if [ "\${STUB_UPDATE_ISSUE_RC:-0}" -ne 0 ]; then
    return "\${STUB_UPDATE_ISSUE_RC}"
  fi
  jq -n '{success:true,issue:{id:"issue-1"}}'
}
STUBEOF

  printf '%s' "$issue_json" >"$ws/issue.json"
  printf '%s' "$team_json" >"$ws/team.json"

  jq -n --argjson events "$events_json" \
    '{board_drivers: {linear: {projected_labels: ["needs-info","needs-adr","rejected","reviewed"], events: $events}}}' \
    >"$ws/skills/ticket-flow/workflow.json"

  echo "$ws"
}

_apply() {
  local ws="$1" event="$2" seq="$3" data="$4"
  [ -z "$data" ] && data="{}"
  FLEET_PIPELINE_LOG_DIR="$ws/logs" bash "$ws/lib/board-drivers/linear.sh" apply WIL-1 "$event" "$seq" "$data"
}

_call_count() {
  local ws="$1"
  [ -f "$ws/update_issue.calls" ] && wc -l <"$ws/update_issue.calls" | tr -d ' ' || echo 0
}

_issue_with_labels() {
  # _issue_with_labels 'lbl-a:needs-info,lbl-b:bug' state_id state_name
  local labels_spec="$1" state_id="$2" state_name="$3"
  local nodes="[]"
  local pair id name
  IFS=',' read -ra pairs <<<"$labels_spec"
  for pair in "${pairs[@]}"; do
    [ -z "$pair" ] && continue
    id="${pair%%:*}"
    name="${pair#*:}"
    nodes=$(echo "$nodes" | jq -c --arg id "$id" --arg n "$name" '. + [{id:$id,name:$n}]')
  done
  jq -nc --argjson labels "$nodes" --arg sid "$state_id" --arg sname "$state_name" \
    '{id:"issue-1",team:{id:"team-1"},state:{id:$sid,name:$sname},labels:{nodes:$labels},assignee:null}'
}

TEAM_JSON='{"states":[{"id":"s-todo","name":"Todo"},{"id":"s-approve","name":"Approve"},{"id":"s-done","name":"Done"},{"id":"s-uat","name":"UAT"}],"labels":[{"id":"lbl-needs-info","name":"needs-info"},{"id":"lbl-needs-adr","name":"needs-adr"},{"id":"lbl-rejected","name":"rejected"},{"id":"lbl-reviewed","name":"Reviewed"}]}'

# ── column-only move ─────────────────────────────────────────────────────
test_column_only_move() {
  local ws issue
  issue=$(_issue_with_labels "" "s-todo" "Todo")
  ws=$(_mk_workspace '{"appraise-completed":{"column":"Approve"}}' "$issue" "$TEAM_JSON")
  _apply "$ws" appraise-completed 1 >/dev/null
  local state
  state=$(head -1 "$ws/update_issue.calls" | awk '{print $2}')
  rm -rf "$ws"
  [ "$state" = "s-approve" ]
}

# ── label add ─────────────────────────────────────────────────────────────
test_label_add() {
  local ws issue
  issue=$(_issue_with_labels "" "s-todo" "Todo")
  ws=$(_mk_workspace '{"needs-info-requested":{"add":["needs-info"]}}' "$issue" "$TEAM_JSON")
  _apply "$ws" needs-info-requested 1 >/dev/null
  local labels
  labels=$(cat "$ws/update_issue.labels")
  rm -rf "$ws"
  [ "$labels" = '["lbl-needs-info"]' ]
}

# ── label remove ──────────────────────────────────────────────────────────
test_label_remove() {
  local ws issue
  issue=$(_issue_with_labels "lbl-needs-info:needs-info" "s-todo" "Todo")
  ws=$(_mk_workspace '{"needs-info-resolved":{"remove":["needs-info"]}}' "$issue" "$TEAM_JSON")
  _apply "$ws" needs-info-resolved 1 >/dev/null
  local labels
  labels=$(cat "$ws/update_issue.labels")
  rm -rf "$ws"
  [ "$labels" = '[]' ]
}

# ── a non-projected label survives ─────────────────────────────────────────
test_non_projected_label_survives() {
  local ws issue
  issue=$(_issue_with_labels "lbl-bug:bug,lbl-needs-info:needs-info" "s-todo" "Todo")
  ws=$(_mk_workspace '{"needs-info-resolved":{"remove":["needs-info"]}}' "$issue" "$TEAM_JSON")
  local team_with_bug
  team_with_bug=$(echo "$TEAM_JSON" | jq -c '.labels += [{"id":"lbl-bug","name":"bug"}]')
  printf '%s' "$team_with_bug" >"$ws/team.json"
  _apply "$ws" needs-info-resolved 1 >/dev/null
  local labels
  labels=$(cat "$ws/update_issue.labels")
  rm -rf "$ws"
  [ "$labels" = '["lbl-bug"]' ]
}

# ── case-insensitive name match ─────────────────────────────────────────────
test_case_insensitive_label_match() {
  local ws issue
  issue=$(_issue_with_labels "" "s-todo" "Todo")
  ws=$(_mk_workspace '{"pr-review-failed":{"add":["rejected"]}}' "$issue" "$TEAM_JSON")
  # team.json's label is named "needs-info" etc. lowercase already covered;
  # verify against a differently-cased current label for the reviewed case.
  issue=$(_issue_with_labels "lbl-reviewed:REVIEWED" "s-todo" "Todo")
  printf '%s' "$issue" >"$ws/issue.json"
  ws2=$(_mk_workspace '{"uat-passed":{"column":"Done","remove":["reviewed"]}}' "$issue" "$TEAM_JSON")
  _apply "$ws2" uat-passed 1 >/dev/null
  local labels
  labels=$(cat "$ws2/update_issue.labels")
  rm -rf "$ws" "$ws2"
  [ "$labels" = '[]' ]
}

# ── no-change → zero update_issue calls ─────────────────────────────────────
test_no_change_zero_calls() {
  local ws issue
  issue=$(_issue_with_labels "" "s-approve" "Approve")
  ws=$(_mk_workspace '{"appraise-completed":{"column":"Approve"}}' "$issue" "$TEAM_JSON")
  _apply "$ws" appraise-completed 1 >/dev/null
  local count
  count=$(_call_count "$ws")
  rm -rf "$ws"
  [ "$count" -eq 0 ]
}

# ── replay produces no second mutation ──────────────────────────────────────
test_replay_no_second_mutation() {
  local ws issue
  issue=$(_issue_with_labels "" "s-todo" "Todo")
  ws=$(_mk_workspace '{"appraise-completed":{"column":"Approve"}}' "$issue" "$TEAM_JSON")
  _apply "$ws" appraise-completed 1 >/dev/null
  # simulate the issue now reflecting the first mutation
  issue=$(_issue_with_labels "" "s-approve" "Approve")
  printf '%s' "$issue" >"$ws/issue.json"
  _apply "$ws" appraise-completed 1 >/dev/null
  local count
  count=$(_call_count "$ws")
  rm -rf "$ws"
  [ "$count" -eq 1 ]
}

# ── from_data column: true branch ───────────────────────────────────────────
test_from_data_column_true_branch() {
  local ws issue
  issue=$(_issue_with_labels "" "s-todo" "Review")
  ws=$(_mk_workspace '{"pr-review-passed":{"column":{"from_data":"uat_required","true":"UAT","false":"Done"}}}' "$issue" "$TEAM_JSON")
  _apply "$ws" pr-review-passed 1 '{"uat_required":true}' >/dev/null
  local state
  state=$(head -1 "$ws/update_issue.calls" | awk '{print $2}')
  rm -rf "$ws"
  [ "$state" = "s-uat" ]
}

# ── from_data column: false branch ──────────────────────────────────────────
test_from_data_column_false_branch() {
  local ws issue
  issue=$(_issue_with_labels "" "s-todo" "Review")
  ws=$(_mk_workspace '{"pr-review-passed":{"column":{"from_data":"uat_required","true":"UAT","false":"Done"}}}' "$issue" "$TEAM_JSON")
  _apply "$ws" pr-review-passed 1 '{"uat_required":false}' >/dev/null
  local state
  state=$(head -1 "$ws/update_issue.calls" | awk '{print $2}')
  rm -rf "$ws"
  [ "$state" = "s-done" ]
}

# ── assignee resolution ──────────────────────────────────────────────────────
test_assignee_resolution() {
  local ws issue
  issue=$(_issue_with_labels "" "s-todo" "Todo")
  ws=$(_mk_workspace '{"appraise-started":{"column":"Todo","assignee":"me"}}' "$issue" "$TEAM_JSON")
  _apply "$ws" appraise-started 1 >/dev/null
  local assignee
  assignee=$(head -1 "$ws/update_issue.calls" | awk '{print $4}')
  rm -rf "$ws"
  [ "$assignee" = "me-1" ]
}

# ── transient failure → non-zero ────────────────────────────────────────────
test_transient_failure_nonzero() {
  local ws issue rc=0
  issue=$(_issue_with_labels "" "s-todo" "Todo")
  ws=$(_mk_workspace '{"appraise-completed":{"column":"Approve"}}' "$issue" "$TEAM_JSON")
  STUB_UPDATE_ISSUE_RC=1 _apply "$ws" appraise-completed 1 >/dev/null 2>&1 || rc=$?
  rm -rf "$ws"
  [ "$rc" -ne 0 ]
}

# ── permanent failure → META|board-projection|fail and exit 0 ──────────────
test_permanent_failure_logs_and_exits_zero() {
  local ws issue rc=0
  issue=$(_issue_with_labels "" "s-todo" "Todo")
  ws=$(_mk_workspace '{"appraise-completed":{"column":"NoSuchColumn"}}' "$issue" "$TEAM_JSON")
  _apply "$ws" appraise-completed 42 >/dev/null 2>&1 || rc=$?
  local logged=1
  grep -q 'META|board-projection|fail|event=appraise-completed seq=42' "$ws/logs/WIL-1-pipeline.log" 2>/dev/null && logged=0
  rm -rf "$ws"
  [ "$rc" -eq 0 ] && [ "$logged" -eq 0 ]
}

# ── explicit-null entry → no-op ──────────────────────────────────────────────
test_explicit_null_entry_noop() {
  local ws issue rc=0
  issue=$(_issue_with_labels "" "s-todo" "Todo")
  ws=$(_mk_workspace '{"gate-held":null}' "$issue" "$TEAM_JSON")
  _apply "$ws" gate-held 1 >/dev/null 2>&1 || rc=$?
  local count
  count=$(_call_count "$ws")
  rm -rf "$ws"
  [ "$rc" -eq 0 ] && [ "$count" -eq 0 ]
}

_run "column-only move" test_column_only_move
_run "label add" test_label_add
_run "label remove" test_label_remove
_run "non-projected label survives" test_non_projected_label_survives
_run "case-insensitive label match" test_case_insensitive_label_match
_run "no-change -> zero update_issue calls" test_no_change_zero_calls
_run "replay produces no second mutation" test_replay_no_second_mutation
_run "from_data column: true branch" test_from_data_column_true_branch
_run "from_data column: false branch" test_from_data_column_false_branch
_run "assignee resolution" test_assignee_resolution
_run "transient failure -> non-zero" test_transient_failure_nonzero
_run "permanent failure -> META|board-projection|fail, exit 0" test_permanent_failure_logs_and_exits_zero
_run "explicit-null entry -> no-op" test_explicit_null_entry_noop

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
