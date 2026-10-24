#!/usr/bin/env bash
# test-verify-agent-guard.sh — structural guards for the VERIFY phase prose
# and its pre-spawn check.
#
#   (a) Every `mcp__playwright__*` tool that ticket-verify/SKILL.md or the
#       agent's own body tells it to use is granted in
#       agents/ticket-verify-agent.md's `tools:` allowlist. The allowlist is an
#       explicit per-tool grant (no wildcards), so a tool the skill names but
#       the agent lacks fails at run time as a false FAIL or a DOM-hack PASS.
#   (b) No hard-coded credential in the verify/reproduce prose or agent, and
#       no built-in UAT password default in lib/config.sh.
#   (c) No bash block in ticket-auto/SKILL.md invokes an MCP tool name as a
#       shell command (they always fail with "command not found"), and
#       lib/verify-preflight.sh's config check behaves as documented.
#
# Usage: bash test-verify-agent-guard.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_MD="$PLUGIN_DIR/agents/ticket-verify-agent.md"
VERIFY_SKILL="$PLUGIN_DIR/skills/ticket-verify/SKILL.md"
AUTO_SKILL="$PLUGIN_DIR/skills/ticket-auto/SKILL.md"
PREFLIGHT="$PLUGIN_DIR/lib/verify-preflight.sh"

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

# ── (a) tool allowlist covers every referenced Playwright tool ──────────────

test_agent_grants_every_referenced_playwright_tool() {
  local tools_line missing=0 t
  tools_line=$(grep -m1 '^tools:' "$AGENT_MD")
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! echo "$tools_line" | tr -d ' ' | tr ',' '\n' | grep -qxF "$t"; then
      echo "  ticket-verify-agent.md tools: is missing $t" >&2
      missing=1
    fi
  done < <(grep -ohE 'mcp__playwright__[a-z_]+' "$VERIFY_SKILL" "$AGENT_MD" | sort -u)
  [ "$missing" -eq 0 ]
}
_run "(a) verify agent grants every mcp__playwright__* tool its skill/agent prose names" \
  test_agent_grants_every_referenced_playwright_tool

test_skill_does_not_call_skill_tool_for_nav_hints() {
  # The verify agent has no Skill tool; a `/nav-hints` slash invocation in a
  # code block would silently do nothing.
  if grep -qE '^/nav-hints( |$)' "$VERIFY_SKILL"; then
    echo "  ticket-verify/SKILL.md invokes /nav-hints as a slash command; the agent has no Skill tool" >&2
    return 1
  fi
}
_run "(a) ticket-verify does not invoke /nav-hints (agent has no Skill tool)" \
  test_skill_does_not_call_skill_tool_for_nav_hints

# ── (b) no hard-coded credentials ───────────────────────────────────────────

test_no_hardcoded_password() {
  local f hits=0
  for f in "$VERIFY_SKILL" "$AGENT_MD" \
    "$PLUGIN_DIR/skills/ticket-batch-verify/SKILL.md" \
    "$PLUGIN_DIR/skills/ticket-reproduce/SKILL.md"; do
    if grep -niE 'password.{0,40}\badmin\b|\badmin\b.{0,20}password' "$f" >&2; then
      echo "  ^ hard-coded credential in ${f#"$PLUGIN_DIR"/}" >&2
      hits=1
    fi
  done
  [ "$hits" -eq 0 ]
}
_run "(b) verify/reproduce prose and agent carry no hard-coded password" test_no_hardcoded_password

test_config_has_no_default_password() {
  local v
  v=$(env -u UAT_TEST_PASSWORD bash -c "source '$PLUGIN_DIR/lib/config.sh'; printf '%s' \"\$UAT_TEST_PASSWORD\"")
  if [ -n "$v" ]; then
    echo "  lib/config.sh defaults UAT_TEST_PASSWORD to a non-empty value" >&2
    return 1
  fi
}
_run "(b) lib/config.sh ships no default UAT_TEST_PASSWORD" test_config_has_no_default_password

# ── (c) pre-flight never runs MCP tool names as shell commands ──────────────

test_no_mcp_name_in_bash_blocks() {
  local hits
  hits=$(awk '/^```(bash|sh)/{b=1;next} /^```/{b=0} b && /^[[:space:]]*mcp__/{print NR": "$0}' "$AUTO_SKILL")
  if [ -n "$hits" ]; then
    echo "  ticket-auto/SKILL.md bash blocks call MCP tools as commands:" >&2
    echo "$hits" >&2
    return 1
  fi
}
_run "(c) ticket-auto/SKILL.md bash blocks never invoke mcp__* as a command" test_no_mcp_name_in_bash_blocks

test_router_calls_verify_preflight() {
  grep -qF 'verify-preflight.sh' "$AUTO_SKILL" || {
    echo "  ticket-auto/SKILL.md STEP_4_5 no longer calls verify-preflight.sh" >&2
    return 1
  }
}
_run "(c) router pre-flight uses lib/verify-preflight.sh" test_router_calls_verify_preflight

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

test_preflight_fails_without_playwright_config() {
  [ -f "$PREFLIGHT" ] || return 1
  local home="$_tmp/h1" proj="$_tmp/p1" log="$_tmp/l1.log" out
  mkdir -p "$home/.claude" "$proj"
  echo '{"mcpServers":{"linear-server":{}}}' >"$home/.claude.json"
  out=$(HOME="$home" bash "$PREFLIGHT" "$log" "$proj")
  [ "$(wc -l <"$log")" -eq 1 ] || return 1
  grep -qF '|META|preflight|fail|VERIFY_PREFLIGHT_FAILED' "$log" || return 1
  echo "$out" | grep -qF "no MCP server named 'playwright'"
}
_run "(c) verify-preflight.sh logs one honest fail line when no playwright server is configured" \
  test_preflight_fails_without_playwright_config

test_preflight_done_with_user_scope_config() {
  [ -f "$PREFLIGHT" ] || return 1
  local home="$_tmp/h2" proj="$_tmp/p2" log="$_tmp/l2.log"
  mkdir -p "$home/.claude" "$proj"
  echo '{"mcpServers":{"playwright":{"command":"npx"}}}' >"$home/.claude.json"
  HOME="$home" bash "$PREFLIGHT" "$log" "$proj" >/dev/null
  [ "$(wc -l <"$log")" -eq 1 ] && grep -qF '|META|preflight|done|playwright MCP server configured' "$log"
}
_run "(c) verify-preflight.sh logs done for a user-scope playwright server" \
  test_preflight_done_with_user_scope_config

test_preflight_done_with_project_and_local_scope() {
  [ -f "$PREFLIGHT" ] || return 1
  local home="$_tmp/h3" proj="$_tmp/p3" proj2="$_tmp/p4" log="$_tmp/l3.log"
  mkdir -p "$home/.claude" "$proj" "$proj2"
  echo '{"mcpServers":{"playwright":{}}}' >"$proj/.mcp.json"
  printf '{"projects":{"%s":{"mcpServers":{"playwright":{}}}}}' "$proj2" >"$home/.claude.json"
  HOME="$home" bash "$PREFLIGHT" "$log" "$proj" >/dev/null
  HOME="$home" bash "$PREFLIGHT" "$log" "$proj2" >/dev/null
  [ "$(grep -c '|META|preflight|done|' "$log")" -eq 2 ]
}
_run "(c) verify-preflight.sh finds project (.mcp.json) and local (~/.claude.json projects) scope" \
  test_preflight_done_with_project_and_local_scope

test_preflight_plugin_server_does_not_count() {
  [ -f "$PREFLIGHT" ] || return 1
  # A plugin-provided server exposes mcp__plugin_*__ names, not the
  # mcp__playwright__* names the agent is granted.
  local home="$_tmp/h5" proj="$_tmp/p5" log="$_tmp/l5.log"
  mkdir -p "$home/.claude" "$proj"
  echo '{"mcpServers":{"playwright-extra":{}}}' >"$home/.claude.json"
  HOME="$home" bash "$PREFLIGHT" "$log" "$proj" >/dev/null
  grep -qF '|META|preflight|fail|' "$log"
}
_run "(c) verify-preflight.sh only accepts a server keyed exactly 'playwright'" \
  test_preflight_plugin_server_does_not_count

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
