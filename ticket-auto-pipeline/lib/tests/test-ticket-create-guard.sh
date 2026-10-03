#!/usr/bin/env bash
# test-ticket-create-guard.sh — unit tests for hooks/ticket-create-guard.sh
# (ticket-create-skill). Feeds PreToolUse payloads on stdin.
# Usage: bash test-ticket-create-guard.sh [filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$(cd "$SCRIPT_DIR/../.." && pwd)/hooks/ticket-create-guard.sh"

PASS=0
FAIL=0

# _guard <payload> — prints the hook's stdout; the hook must always exit 0.
_guard() {
  printf '%s' "$1" | TICKET_CREATE_GUARD="${GUARD_ENV:-on}" bash "$GUARD"
}

_bash_payload() { jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }

_denied() {
  local out
  out=$(_guard "$1") || return 1
  echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains("/ticket-create"))' >/dev/null 2>&1
}

_allowed() {
  local out
  out=$(_guard "$1") || return 1
  [ -z "$out" ]
}

test_mcp_create_denied() {
  _denied '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"title":"x","team":"WIL"}}'
}

test_mcp_create_issue_tool_denied() {
  _denied '{"tool_name":"mcp__claude_ai_Linear__create_issue","tool_input":{"title":"x"}}'
}

test_mcp_update_allowed() {
  _allowed '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"id":"WIL-5","description":"y"}}'
}

test_mcp_empty_id_denied() {
  _denied '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"id":"","title":"x"}}'
}

test_curl_issue_create_denied() {
  _denied "$(_bash_payload 'curl -s https://api.linear.app/graphql -d '"'"'{"query":"mutation { issueCreate(input: {title: \"x\"}) { success } }"}'"'")"
}

test_lib_create_issue_denied() {
  _denied "$(_bash_payload 'source ~/.claude/skills/lib/linear-api.sh; create_issue "$TEAM" "Title" "Body"')"
}

test_lib_create_issue_newline_denied() {
  _denied "$(_bash_payload $'source lib/linear-api.sh\ncreate_issue t x y')"
}

test_planner_path_allowed() {
  _allowed "$(_bash_payload 'source ticket-planner/lib/planner-linear.sh && planner_linear_create_issue "$TEAM" "$TITLE" "$BODY"')"
}

# TicketGen's real block shape: issueCreate appears in a jq path and a
# message alongside the planner's own create call.
test_planner_block_with_issue_create_text_allowed() {
  _allowed "$(_bash_payload $'source ~/.claude/skills/lib/linear-api.sh\nR=$(planner_linear_create_issue "$T" "$X" "$D") || echo "issueCreate failed"\necho "$R" | jq -r .data.issueCreate.issue.identifier')"
}

test_create_sh_allowed() {
  _allowed "$(_bash_payload 'bash ~/.claude/skills/ticket-create/create.sh --type bug --kind business --title x --body-file /tmp/b.md')"
}

test_unrelated_bash_allowed() {
  _allowed "$(_bash_payload 'ls -la && git status')"
}

# Reading or grepping code that mentions the function must never be denied.
test_grep_create_issue_allowed() {
  _allowed "$(_bash_payload 'grep -n create_issue lib/linear-api.sh')"
}

test_grep_issue_create_allowed() {
  _allowed "$(_bash_payload 'grep -rn issueCreate lib/')"
}

test_other_tool_allowed() {
  _allowed '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
}

test_non_json_allowed() {
  _allowed 'this is not json {'
}

test_guard_off_allowed() {
  GUARD_ENV=off _allowed '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"title":"x"}}'
}

FILTER="${1:-}"
for fn in \
  test_mcp_create_denied \
  test_mcp_create_issue_tool_denied \
  test_mcp_update_allowed \
  test_mcp_empty_id_denied \
  test_curl_issue_create_denied \
  test_lib_create_issue_denied \
  test_lib_create_issue_newline_denied \
  test_planner_path_allowed \
  test_planner_block_with_issue_create_text_allowed \
  test_create_sh_allowed \
  test_unrelated_bash_allowed \
  test_grep_create_issue_allowed \
  test_grep_issue_create_allowed \
  test_other_tool_allowed \
  test_non_json_allowed \
  test_guard_off_allowed; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  if "$fn"; then
    echo "PASS: $fn"
    ((PASS++)) || true
  else
    echo "FAIL: $fn"
    ((FAIL++)) || true
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
