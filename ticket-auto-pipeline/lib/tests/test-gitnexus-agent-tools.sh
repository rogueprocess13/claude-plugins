#!/usr/bin/env bash
# test-gitnexus-agent-tools.sh — structural regression guard for the
# GITNEXUS_PREFLIGHT_BRANCH_UNVERIFIED fix (issue #359).
#
# lib/gitnexus-preflight.sh and its SKILL.md integration points are useless
# in production unless the named agents the router actually spawns for
# PR-REVIEW and IMPLEMENT are granted `mcp__gitnexus__list_repos` in their
# `tools:` frontmatter allowlist — per CLAUDE.md's "Sub-agent isolation"
# section, that allowlist is an explicit per-tool grant (no wildcards) that
# actually restricts what a spawned agent can call. Both SKILL.md pre-flight
# steps call `mcp__gitnexus__list_repos` before `detect_changes`; without the
# grant, the reachability check always fails and the whole verification
# mechanism this fix added never executes.
#
# This is a plain grep-based structural check, matching this repo's existing
# style for assertions against generated/hand-written prose files (see
# lib/tests/test-pipeline-phases.sh).
#
# Usage: bash test-gitnexus-agent-tools.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/../../agents" && pwd)"

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

# _agent_tools_line <agent_file> — extracts the `tools:` frontmatter line.
_agent_tools_line() {
  local agent_file="$1"
  grep -m1 '^tools:' "$agent_file"
}

test_pr_review_agent_grants_list_repos() {
  local agent_file="$AGENTS_DIR/ticket-pr-review-agent.md"
  [ -f "$agent_file" ] || {
    echo "  $agent_file not found" >&2
    return 1
  }
  local tools_line
  tools_line=$(_agent_tools_line "$agent_file")
  echo "$tools_line" | grep -qF 'mcp__gitnexus__list_repos' || {
    echo "  ticket-pr-review-agent.md tools: line is missing mcp__gitnexus__list_repos: $tools_line" >&2
    return 1
  }
  return 0
}
_run "ticket-pr-review-agent grants mcp__gitnexus__list_repos" test_pr_review_agent_grants_list_repos

test_pr_review_agent_still_grants_detect_changes() {
  local agent_file="$AGENTS_DIR/ticket-pr-review-agent.md"
  _agent_tools_line "$agent_file" | grep -qF 'mcp__gitnexus__detect_changes'
}
_run "ticket-pr-review-agent still grants mcp__gitnexus__detect_changes" test_pr_review_agent_still_grants_detect_changes

test_implement_agent_grants_list_repos() {
  local agent_file="$AGENTS_DIR/ticket-implement-agent.md"
  [ -f "$agent_file" ] || {
    echo "  $agent_file not found" >&2
    return 1
  }
  local tools_line
  tools_line=$(_agent_tools_line "$agent_file")
  echo "$tools_line" | grep -qF 'mcp__gitnexus__list_repos' || {
    echo "  ticket-implement-agent.md tools: line is missing mcp__gitnexus__list_repos: $tools_line" >&2
    return 1
  }
  return 0
}
_run "ticket-implement-agent grants mcp__gitnexus__list_repos" test_implement_agent_grants_list_repos

test_implement_agent_still_grants_detect_changes_and_impact() {
  local agent_file="$AGENTS_DIR/ticket-implement-agent.md"
  local tools_line
  tools_line=$(_agent_tools_line "$agent_file")
  echo "$tools_line" | grep -qF 'mcp__gitnexus__detect_changes' || {
    echo "  missing mcp__gitnexus__detect_changes: $tools_line" >&2
    return 1
  }
  echo "$tools_line" | grep -qF 'mcp__gitnexus__impact' || {
    echo "  missing mcp__gitnexus__impact: $tools_line" >&2
    return 1
  }
  return 0
}
_run "ticket-implement-agent still grants mcp__gitnexus__detect_changes and mcp__gitnexus__impact" test_implement_agent_still_grants_detect_changes_and_impact

# Every SKILL.md pre-flight step that instructs an agent to call
# mcp__gitnexus__list_repos must dispatch to an agent that is actually
# granted the tool — this pins the two known call sites (#359) so a future
# tool-list edit that drops the grant fails loudly here instead of silently
# degrading the pre-flight to "always unreachable" in production.
test_skill_md_preflight_callers_match_granted_agents() {
  local skills_dir
  skills_dir="$(cd "$SCRIPT_DIR/../../skills" && pwd)"
  local pr_review_skill="$skills_dir/ticket-pr-review/SKILL.md"
  local implement_skill="$skills_dir/ticket-implement/SKILL.md"

  grep -qF 'mcp__gitnexus__list_repos' "$pr_review_skill" || {
    echo "  ticket-pr-review/SKILL.md no longer calls mcp__gitnexus__list_repos" >&2
    return 1
  }
  grep -qF 'mcp__gitnexus__list_repos' "$implement_skill" || {
    echo "  ticket-implement/SKILL.md no longer calls mcp__gitnexus__list_repos" >&2
    return 1
  }
  return 0
}
_run "SKILL.md pre-flight callers for list_repos still present (paired with the agent grant tests above)" test_skill_md_preflight_callers_match_granted_agents

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
