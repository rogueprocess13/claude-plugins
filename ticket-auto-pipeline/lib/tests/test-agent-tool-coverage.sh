#!/usr/bin/env bash
# test-agent-tool-coverage.sh — a phase skill may only tell its agent to use
# tools the agent has (GitHub #667).
#
# dispatch-table.json binds each phase skill to an agent definition
# (agents/*.md). That file's `tools:` line is an allowlist on both spawn paths
# (the router's Agent tool `subagent_type`, fleetd's `claude --agent`), so a
# step that says "spawn an agent" or "invoke Skill(...)" cannot run when the
# agent holds neither tool: the agent improvises or skips the step.
#
# For every (skill, agent) pair in the dispatch table this test scans the
# skill's SKILL.md and its references/*.md for instructions that need a tool:
#
#   Agent       "spawn a/an/the ... agent|subagent", `subagent_type`
#   Skill       `Skill(`, or "Run/Invoke [the] `/slash-command`" opening a
#               sentence, list item or clause (not "re-run", "then run", "must
#               run", and not a line that hands the command to "the user":
#               those are handoff prose, not instructions to the agent)
#   TaskCreate, TaskUpdate, TodoWrite, WebFetch, WebSearch   the literal name
#   mcp__*      any `mcp__server__tool` name
#
# and fails when a needed tool is absent from the agent's `tools:` line.
#
# KNOWN_GAPS lists the (skill, tool) pairs that were already broken when the
# test was written. It is a ratchet: a new gap fails, and so does a listed gap
# that no longer exists (delete the line). Never add a line to make a new
# instruction pass: rewrite the step to use a tool the agent has, or grant the
# tool in agents/*.md with a reason.
#
# Usage: bash test-agent-tool-coverage.sh
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TABLE="$PLUGIN_DIR/skills/ticket-flow/dispatch-table.json"

PASS=0
FAIL=0
_ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
_bad() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

# skill<TAB>tool — gaps that predate this test. Remove a line when it is fixed.
KNOWN_GAPS="ticket-appraise	Agent
ticket-appraise	Skill
ticket-appraise	TaskCreate
ticket-appraise	TaskUpdate
ticket-appraise	mcp__plugin_claude-mem_mcp-search__prime_corpus
ticket-appraise	mcp__plugin_claude-mem_mcp-search__query_corpus
ticket-appraise-exec	Agent
ticket-appraise-exec	Skill
ticket-appraise-exec	TaskCreate
ticket-appraise-exec	TaskUpdate
ticket-gate-reconcile	mcp__linear-server__list_comments
ticket-pr-review	TaskCreate
ticket-pr-review	TaskUpdate
ticket-reproduce	Skill
ticket-reproduce	TaskCreate
ticket-reproduce	TaskUpdate
ticket-reproduce	mcp__linear-server__save_comment
ticket-verify	TaskCreate
ticket-verify	TaskUpdate"

# required_tools <file>... — one tool name per line, sorted, unique.
required_tools() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -qiE 'spawn (a|an|the) [^.]*(agent|subagent)|subagent_type' "$f" && echo Agent
    grep -vE '(the|a) user' "$f" |
      grep -qE 'Skill\(|(^|[.:*] |, )([Rr]un|[Ii]nvoke) (the )?`/[a-z]' && echo Skill
    grep -oE '\b(TaskCreate|TaskUpdate|TodoWrite|WebFetch|WebSearch)\b' "$f"
    grep -oE '\bmcp__[A-Za-z0-9_-]+__[A-Za-z0-9_]+' "$f"
  done | sort -u
}

# agent_tools <agent.md> — one tool per line from the frontmatter `tools:` line.
agent_tools() {
  grep -m1 '^tools:' "$1" | sed 's/^tools://' | tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/(.*$//' | grep -v '^$'
}

# skill_gaps <skill> <agent.md> — tools the skill needs and the agent lacks.
skill_gaps() {
  local skill_dir="$PLUGIN_DIR/skills/$1" have
  have=$(agent_tools "$2")
  required_tools "$skill_dir/SKILL.md" "$skill_dir"/references/*.md |
    grep -vxFf <(printf '%s\n' "$have") || true
}

# ── The detector itself ───────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/old.md" <<'EOF'
Spawn a `general-purpose` agent to apply the change.
Apply the change by running `/opsx:apply` in the worktree.
**Invoke `Skill("superpowers:requesting-code-review")`**
1. Run `/commit-commands:commit` from the worktree.
Create a TaskCreate for every remaining step.
Call `mcp__gitnexus__impact` on each target symbol.
EOF
got=$(required_tools "$TMP/old.md" | tr '\n' ' ')
if [ "$got" = "Agent Skill TaskCreate mcp__gitnexus__impact " ]; then
  _ok "detector finds Agent, Skill, TaskCreate and MCP instructions"
else
  _bad "detector on the pre-fix wording returned: $got"
fi

cat >"$TMP/clean.md" <<'EOF'
Apply the change yourself: no agent spawn and no slash command.
If not found, tell the user to run `/ticket-appraise {TICKET-ID}` first.
This agent has no Skill tool. Use bash ~/.claude/skills/lib/flow-run.sh.
Commit with plain git, never a slash command.
EOF
got=$(required_tools "$TMP/clean.md" | tr '\n' ' ')
if [ -z "$got" ]; then
  _ok "detector ignores negations and user-facing handoffs"
else
  _bad "detector flagged clean wording: $got"
fi

printf -- '---\nname: x\ntools: Bash, Read , Agent(Explore), mcp__a__b\n---\n' >"$TMP/agent.md"
got=$(agent_tools "$TMP/agent.md" | tr '\n' ' ')
if [ "$got" = "Bash Read Agent mcp__a__b " ]; then
  _ok "agent_tools splits the tools line and drops a (…) scope"
else
  _bad "agent_tools returned: $got"
fi

# ── Every dispatch-table (skill, agent) pair ─────────────────────────────────
pairs=$(jq -r '
  [.. | objects | select(has("agent") and has("skill") and .agent != null)
   | "\(.skill | sub("^/ticket-auto-pipeline:"; ""))\t\(.agent | sub("^ticket-auto-pipeline:"; ""))"]
  | unique | .[]' "$TABLE")

if [ "$(printf '%s\n' "$pairs" | grep -c .)" -ge 8 ]; then
  _ok "dispatch table yields the phase (skill, agent) pairs"
else
  _bad "dispatch table yielded too few (skill, agent) pairs: $pairs"
fi

found=""
while IFS=$'\t' read -r skill agent; do
  [ -n "$skill" ] || continue
  agent_file="$PLUGIN_DIR/agents/$agent.md"
  if [ ! -f "$agent_file" ] || [ ! -f "$PLUGIN_DIR/skills/$skill/SKILL.md" ]; then
    _bad "$skill → $agent: skill or agent file missing"
    continue
  fi
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    found+="$skill	$tool"$'\n'
  done < <(skill_gaps "$skill" "$agent_file")
done <<<"$pairs"
found=$(printf '%s' "$found" | sort -u)

new=$(grep -vxFf <(printf '%s\n' "$KNOWN_GAPS") <<<"$found" | grep . || true)
if [ -z "$new" ]; then
  _ok "no phase skill needs a tool its agent lacks (beyond KNOWN_GAPS)"
else
  _bad "a skill instructs its agent to use a tool missing from the agent's tools: line (skill<TAB>tool):"
  sed 's/^/  /' <<<"$new"
fi

stale=$(grep -vxFf <(printf '%s\n' "$found") <<<"$KNOWN_GAPS" | grep . || true)
if [ -z "$stale" ]; then
  _ok "every KNOWN_GAPS entry still exists"
else
  _bad "KNOWN_GAPS lists gaps that are fixed; delete these lines:"
  sed 's/^/  /' <<<"$stale"
fi

if grep -q '^ticket-implement	' <<<"$KNOWN_GAPS"; then
  _bad "ticket-implement must not be in KNOWN_GAPS (#667)"
else
  _ok "ticket-implement has no tolerated gap"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
