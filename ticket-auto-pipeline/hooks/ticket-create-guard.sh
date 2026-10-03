#!/usr/bin/env bash
# ticket-create-guard.sh — PreToolUse hook (ticket-create-skill, design D5).
# Denies direct Linear issue creation so every new ticket goes through
# /ticket-create (skills/ticket-create/create.sh): template layout, readiness
# check, duplicate check, _adhoc manifest.
#
# Denied:
#   - Linear MCP save_issue/create_issue with no tool_input.id (a create)
#   - Bash that calls create_issue (command position, not the planner's
#     planner_linear_create_issue) or sends an issueCreate mutation over the
#     network (curl/wget/linear_graphql/api.linear.app)
# Allowed: create.sh itself, the planner path, MCP updates (id present),
# everything else, and every call when TICKET_CREATE_GUARD=off.
#
# Fails open: missing jq or a payload that does not parse exits 0 silently —
# a broken guard must never block unrelated work. Matching is deliberately
# narrow (call position / network signal) so reading or grepping code that
# mentions create_issue is never denied. This guards against drift off the
# standard path; it is not a defence against a determined bypass.

[ "${TICKET_CREATE_GUARD:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ -n "$tool" ] || exit 0

deny() {
  jq -cn '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
    permissionDecisionReason: "Direct ticket creation is disabled — use the /ticket-create skill (bash ~/.claude/skills/ticket-create/create.sh …) so the ticket gets the standard template, readiness check and duplicate check. Set TICKET_CREATE_GUARD=off to bypass."}}'
  exit 0
}

if [[ "$tool" =~ ^mcp__.*[Ll]inear.*__(save_issue|create_issue)$ ]]; then
  id=$(printf '%s' "$payload" | jq -r '.tool_input.id // empty' 2>/dev/null) || exit 0
  [ -z "$id" ] && deny
  exit 0
fi

if [ "$tool" = "Bash" ]; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
  [ -n "$cmd" ] || exit 0
  [[ "$cmd" == *"ticket-create/create.sh"* ]] && exit 0
  # EpicGen/TicketGen: the planner runs its own pre-create validation and
  # Refinement DoR. Its blocks mention issueCreate in jq paths and messages.
  [[ "$cmd" == *planner_linear_create_issue* ]] && exit 0

  # create_issue in command position: start of line or after ; & | ( { ` $(
  if printf '%s\n' "$cmd" | grep -qE '(^|[;&|({`]|\$\()[[:space:]]*create_issue([[:space:]]|$|;)'; then
    deny
  fi
  # A raw issueCreate mutation actually being sent somewhere.
  if [[ "$cmd" == *issueCreate* ]] &&
    printf '%s\n' "$cmd" | grep -qE 'curl|wget|linear_graphql|api\.linear\.app'; then
    deny
  fi
fi

exit 0
