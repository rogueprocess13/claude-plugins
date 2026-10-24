#!/usr/bin/env bash
# verify-preflight.sh — deterministic pre-spawn check for the VERIFY phase.
#
# The verify agent drives the browser through `mcp__playwright__*` tools. Those
# tool names only exist when an MCP server keyed exactly `playwright` is
# configured (a plugin-provided server gets a different prefix,
# `mcp__plugin_<plugin>_<server>__*`, which the agent's allowlist does not
# grant). MCP tools are not shell commands, so reachability cannot be probed
# from bash — and reachability is a property of the agent's own session anyway.
# What bash *can* answer honestly is "is a `playwright` server configured at
# all?", which is the common real failure (fresh host, project moved, config
# lost). That is what this script checks, and its log line says exactly that.
#
# Linear is not checked here: the verify agent reaches Linear through
# lib/linear-api.sh (LINEAR_API_KEY), which the pipeline preamble already
# validates; it never uses a Linear MCP server.
#
# Config sources searched (first hit wins):
#   <project_dir>/.mcp.json                     (project scope)
#   <git toplevel of project_dir>/.mcp.json     (project scope, from a subdir)
#   $HOME/.claude.json  .projects[<dir>].mcpServers  (local scope)
#   $HOME/.claude.json  .mcpServers                  (user scope)
#   $HOME/.claude/settings.json .mcpServers
#
# Usage:
#   bash verify-preflight.sh <LOG_FILE> [project_dir]
#     Appends exactly one META|preflight line to LOG_FILE and prints it.
#     Always exits 0 — the check is advisory: the router proceeds either way,
#     and a real outage still surfaces as a counted verify attempt.
#   source verify-preflight.sh; verify_preflight_playwright_source [project_dir]
#     Prints the config file that declares the server; exits 1 if none does.

# _vp_has_server <json_file> <jq_path_to_mcpServers>
_vp_has_server() {
  local file="$1" path="$2"
  [ -f "$file" ] || return 1
  jq -e --arg d "${3:-}" "${path} | objects | has(\"playwright\")" "$file" >/dev/null 2>&1
}

verify_preflight_playwright_source() {
  local dir="${1:-$PWD}" top="" d
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
  for d in "$dir" "$top"; do
    [ -n "$d" ] || continue
    if _vp_has_server "$d/.mcp.json" '.mcpServers'; then
      echo "$d/.mcp.json"
      return 0
    fi
  done
  for d in "$dir" "$top"; do
    [ -n "$d" ] || continue
    if _vp_has_server "$HOME/.claude.json" '.projects[$d].mcpServers' "$d"; then
      echo "$HOME/.claude.json (project $d)"
      return 0
    fi
  done
  if _vp_has_server "$HOME/.claude.json" '.mcpServers'; then
    echo "$HOME/.claude.json (user)"
    return 0
  fi
  if _vp_has_server "$HOME/.claude/settings.json" '.mcpServers'; then
    echo "$HOME/.claude/settings.json"
    return 0
  fi
  return 1
}

verify_preflight_main() {
  local log_file="${1:-}" dir="${2:-$PWD}" ts src line
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! command -v jq >/dev/null 2>&1; then
    line="${ts}|META|preflight|skip|jq not installed — Playwright MCP config not checked"
  elif src=$(verify_preflight_playwright_source "$dir"); then
    line="${ts}|META|preflight|done|playwright MCP server configured in ${src} (config check only; reachability is tested by the verify agent)"
  else
    line="${ts}|META|preflight|fail|VERIFY_PREFLIGHT_FAILED — no MCP server named 'playwright' in .mcp.json, ~/.claude.json or ~/.claude/settings.json; the verify agent's mcp__playwright__* tools will not exist"
  fi
  [ -n "$log_file" ] && echo "$line" >>"$log_file"
  echo "$line"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  verify_preflight_main "$@"
fi
