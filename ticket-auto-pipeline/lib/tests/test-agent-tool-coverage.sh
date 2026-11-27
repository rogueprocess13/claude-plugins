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
# skill's SKILL.md and its references/*.md for instructions that need a tool.
# A skill that follows the shared preamble (its SKILL.md names
# lib/skill-preamble-auto.md) is also scanned through the preamble, and through
# every file the preamble tells the agent to resolve with skill-ref.sh and
# follow inline (§ 8 reads adr-gate's references/gate.md that way):
#
#   Agent       "spawn a/an/the ... agent|subagent", `subagent_type`
#   Skill       `Skill(`, or "[Then] Run/Invoke [the] `/slash-command`" opening
#               a sentence, list item or clause (not "re-run", "then run",
#               "must run", and not a line that hands the command to "the
#               user": those are handoff prose, not instructions to the agent)
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
# Empty since #667 closed the last ones: keep it empty.
KNOWN_GAPS=""

# required_tools <file>... — one tool name per line, sorted, unique.
required_tools() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -qiE 'spawn (a|an|the) [^.]*(agent|subagent)|subagent_type' "$f" && echo Agent
    # No `grep -q` at the end of this pipe: it exits on the first match, the
    # first grep dies of SIGPIPE and pipefail turns a hit into a miss.
    [ -n "$(grep -vE '(the|a) user' "$f" |
      grep -E 'Skill\(|(^|[.:*] |, )(Then )?([Rr]un|[Ii]nvoke) (the )?`/[a-z]')" ] && echo Skill
    grep -oE '\b(TaskCreate|TaskUpdate|TodoWrite|WebFetch|WebSearch)\b' "$f"
    grep -oE '\bmcp__[A-Za-z0-9_-]+__[A-Za-z0-9_]+' "$f"
  done | sort -u
}

# agent_tools <agent.md> — one tool per line from the frontmatter `tools:` line.
agent_tools() {
  grep -m1 '^tools:' "$1" | sed 's/^tools://' | tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/(.*$//' | grep -v '^$'
}

PREAMBLE="$PLUGIN_DIR/lib/skill-preamble-auto.md"

# inline_reads <file> — the plugin files <file> resolves with skill-ref.sh, one
# path per line. An agent follows those inline, so their tool needs are its own.
inline_reads() {
  grep -oE 'skill-ref\.sh [a-z0-9-]+ [A-Za-z0-9._/-]+\.md' "$1" | sort -u |
    while read -r _ s f; do echo "$PLUGIN_DIR/skills/$s/$f"; done
}

# preamble_files <skill> — the preamble and its inline reads, when the skill's
# SKILL.md follows the preamble; nothing otherwise.
preamble_files() {
  grep -qF 'skill-preamble-auto.md' "$PLUGIN_DIR/skills/$1/SKILL.md" || return 0
  echo "$PREAMBLE"
  inline_reads "$PREAMBLE"
}

# skill_gaps <skill> <agent.md> — tools the skill needs and the agent lacks.
skill_gaps() {
  local skill_dir="$PLUGIN_DIR/skills/$1" have pre=()
  have=$(agent_tools "$2")
  mapfile -t pre < <(preamble_files "$1")
  required_tools "$skill_dir/SKILL.md" "$skill_dir"/references/*.md "${pre[@]}" |
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

# The preamble's § 8 wording before #667: the Skill tool, which no agent holds.
cat >"$TMP/old-preamble.md" <<'EOF'
Compose a request file and invoke the gate:

Then invoke `/adr-gate --request-file "$_adr_gate_req" --wiki-root "$WIKI_ROOT" --log-file
"$TAP_LOG"`. Read the `=== ADR_GATE_RESULT ===` block it returns.
EOF
got=$(required_tools "$TMP/old-preamble.md" | tr '\n' ' ')
if [ "$got" = "Skill " ]; then
  _ok "detector finds the pre-fix 'Then invoke /adr-gate' preamble wording"
else
  _bad "detector on the pre-fix preamble wording returned: $got"
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

if [ -z "$KNOWN_GAPS" ]; then
  _ok "KNOWN_GAPS is empty: no phase skill has a tolerated gap (#667)"
else
  _bad "KNOWN_GAPS must stay empty (#667); fix the step instead: $KNOWN_GAPS"
fi

# ── How the #667 gaps were closed ────────────────────────────────────────────
# A scan for tool names cannot tell a removed step from a reworded one, so pin
# each replacement: the setup script instead of /ticket-setup, the openspec CLI
# instead of /opsx:propose, and a logged fallback for each review or search a
# phase agent now does itself.
skill_md() {
  local f
  for f in "$PLUGIN_DIR/skills/$1/SKILL.md" "$PLUGIN_DIR/skills/$1"/references/*.md; do
    [ -f "$f" ] && cat "$f"
  done
  return 0
}
SETUP="$PLUGIN_DIR/skills/ticket-setup/setup.sh"
for s in ticket-appraise ticket-reproduce; do
  if [ -f "$SETUP" ] && skill_md "$s" | grep -qF 'bash ~/.claude/skills/ticket-setup/setup.sh "{TICKET-ID}"' &&
    grep -qF 'skills/ticket-setup/setup.sh' "$PLUGIN_DIR/.claude-plugin/plugin.json"; then
    _ok "$s runs the synced ticket-setup script, not /ticket-setup"
  else
    _bad "$s does not call ~/.claude/skills/ticket-setup/setup.sh, or the hook no longer syncs it"
  fi
done
if skill_md ticket-appraise-exec | grep -qF 'openspec new change "{change-name}"' &&
  skill_md ticket-appraise-exec | grep -qF 'openspec instructions <id> --change "{change-name}" --json'; then
  _ok "ticket-appraise-exec creates the change with the openspec CLI, not /opsx:propose"
else
  _bad "ticket-appraise-exec lost its openspec CLI steps"
fi
for pair in "ticket-appraise CLAIM_VERIFY_SELF_CHECK" "ticket-appraise INVESTIGATION_INLINE" \
  "ticket-appraise PRIOR_ART_NO_CLAUDE_MEM" "ticket-appraise-exec ADVERSARIAL_SELF_REVIEW"; do
  read -r s code <<<"$pair"
  if skill_md "$s" | grep -qE "plog\.sh META gate-warn (warn|info) \"$code"; then
    _ok "$s logs $code when it does the step itself"
  else
    _bad "$s has no logged $code fallback"
  fi
done

# ── The router's independent plan reviewer (STEP_2_2, #667) ──────────────────
# With TICKET_ROUTER_PLAN_REVIEW=false (or under fleetd phase dispatch) Step
# 3.6 is a logged self-review; otherwise that step is skipped and this agent does the review, so it must be
# read-only: it can write its one result file and nothing else, and cannot
# spawn or run a skill.
reviewer="$PLUGIN_DIR/agents/ticket-plan-review-agent.md"
got=$(agent_tools "$reviewer" | sort | tr '\n' ' ')
if [ "$got" = "Glob Grep Read Write " ]; then
  _ok "ticket-plan-review-agent holds exactly Read, Grep, Glob, Write"
else
  _bad "ticket-plan-review-agent tools are not the read-only set: $got"
fi
if grep -q '^/ticket-auto-pipeline:ticket-plan-review	\|^ticket-plan-review	ticket-plan-review-agent$' <<<"$pairs" &&
  [ -z "$(skill_gaps ticket-plan-review "$reviewer")" ] &&
  ! grep -q '^ticket-plan-review	' <<<"$KNOWN_GAPS"; then
  _ok "ticket-plan-review is in the dispatch table and needs no tool its agent lacks"
else
  _bad "ticket-plan-review: missing from the dispatch table, or it needs a tool its agent lacks"
fi
if [ "$(jq -r '.steps[] | select(.step_id == "STEP_2_2") | .spawn.agent' "$TABLE")" = "ticket-auto-pipeline:ticket-plan-review-agent" ] &&
  ! grep -lE '^tools:.*\b(Agent|Skill)\b' "$PLUGIN_DIR"/agents/*.md | grep -q .; then
  _ok "STEP_2_2 spawns the reviewer, and no phase agent was granted Agent or Skill"
else
  _bad "STEP_2_2 does not spawn ticket-plan-review-agent, or an agent now holds Agent/Skill"
fi

# ── The shared preamble and its inline ADR gate (§ 8, #667) ──────────────────
# No phase agent holds the Skill tool, so § 8 has the agent resolve adr-gate's
# references/gate.md with skill-ref.sh and follow it inline. The loop above
# already scans the preamble and that file for every skill that follows the
# preamble; these checks pin the parts a tool-name scan cannot see.
GATE="$PLUGIN_DIR/skills/adr-gate/references/gate.md"
GATE_SKILL="$PLUGIN_DIR/skills/adr-gate/SKILL.md"
sec8=$(awk '/^## 8\. ADR gate/ { on = 1 } on' "$PREAMBLE")
flat=$(tr '\n' ' ' <<<"$sec8")

preamble_skills=""
preamble_agents=""
while IFS=$'\t' read -r skill agent; do
  [ -n "$skill" ] && [ -n "$(preamble_files "$skill")" ] || continue
  preamble_skills+="$skill "
  preamble_agents+="$agent"$'\n'
done <<<"$pairs"
preamble_agents=$(printf '%s' "$preamble_agents" | sort -u)
if [ "$(wc -w <<<"$preamble_skills")" -ge 6 ] &&
  [ "$(inline_reads "$PREAMBLE")" = "$GATE" ] && [ -f "$GATE" ]; then
  _ok "the preamble is scanned for its skills, with adr-gate's references/gate.md as its one inline read"
else
  _bad "preamble scan is empty or its inline reads changed: skills='$preamble_skills' reads='$(inline_reads "$PREAMBLE")'"
fi

# The read line, in the order the root CLAUDE.md prescribes: condition, the
# file, the resolver call, "Read the printed path in full", the hard stop.
if grep -qE 'If you composed a request file, before acting on the decision.*`references/gate\.md`.*`bash ~/\.claude/skills/lib/skill-ref\.sh adr-gate references/gate\.md`.*Read the printed path in full.*If `skill-ref\.sh` exits non-zero.*reference-missing fail "adr-gate/gate\.md"` and stop: never classify from memory' <<<"$flat"; then
  _ok "§ 8 reads the gate through skill-ref.sh: condition, file, resolver, full read, hard stop"
else
  _bad "§ 8 lacks the conditional read line for adr-gate's references/gate.md, or its parts are out of order"
fi
if grep -qF 'never invoke `/adr-gate`' <<<"$flat" &&
  ! grep -qE 'CLAUDE_PLUGIN_ROOT|~/\.claude/skills/adr-gate' "$PREAMBLE"; then
  _ok "§ 8 forbids the slash command and names no plugin-root or skill-dir path"
else
  _bad "§ 8 allows /adr-gate, or reaches the gate through CLAUDE_PLUGIN_ROOT or ~/.claude/skills/adr-gate"
fi

# Followed inline, the gate needs only Bash: the store, the parser and the
# scratch files are Bash calls. An agent with no Read or Write tool reads with
# `cat` and writes the ADR body with a heredoc, and § 8 must say so while such
# an agent exists.
lacking=""
no_write=""
no_read=""
while IFS= read -r agent; do
  [ -n "$agent" ] || continue
  have=$(agent_tools "$PLUGIN_DIR/agents/$agent.md")
  grep -qx Bash <<<"$have" || lacking+="$agent "
  grep -qx Write <<<"$have" || no_write+="$agent "
  grep -qx Read <<<"$have" || no_read+="$agent "
done <<<"$preamble_agents"
if [ -z "$lacking" ]; then
  _ok "every agent that follows the preamble holds Bash"
else
  _bad "agents that follow the preamble but lack Bash: $lacking"
fi
if [ -z "$no_write$no_read" ] || grep -qF 'If you hold no Write or Read tool, use Bash instead: `cat` to read, a heredoc to write the ADR body file' <<<"$flat"; then
  _ok "§ 8 gives agents without Write or Read a Bash fallback (no Write: ${no_write:-none}; no Read: ${no_read:-none})"
else
  _bad "agents without Write ($no_write) or Read ($no_read) follow § 8, which names no Bash fallback"
fi
if grep -q 'ticket-verify-agent' <<<"$no_write" && grep -q 'ticket-pr-review-agent' <<<"$no_write"; then
  _ok "the no-Write fallback is exercised by the verify and pr-review agents"
else
  _bad "expected ticket-verify-agent and ticket-pr-review-agent among the no-Write agents: $no_write"
fi

# The gate's own commands must run from any working directory: the synced lib
# dir, never CLAUDE_PLUGIN_ROOT (unset in a Bash call) or a cwd-relative lib/.
bad_cmd=$(grep -nE 'CLAUDE_PLUGIN_ROOT|(bash|source) "?lib/' "$GATE" || true)
missing=""
for f in $(grep -oE '~/\.claude/skills/lib/[A-Za-z0-9._-]+\.sh' "$GATE" | sort -u); do
  [ -f "$PLUGIN_DIR/lib/${f##*/}" ] || missing+="${f##*/} "
done
if [ -z "$bad_cmd" ] && [ -z "$missing" ] &&
  [ "$(grep -cE '~/\.claude/skills/lib/(wiki-bootstrap|adr-store|adr-gate-parse)\.sh' "$GATE")" -ge 4 ]; then
  _ok "adr-gate's commands use the synced lib dir and every script they name exists"
else
  _bad "adr-gate references/gate.md has a cwd-relative or plugin-root command, or names a missing lib script: $bad_cmd $missing"
fi
# The planner still runs the gate as a plain skill: SKILL.md keeps its
# frontmatter and reads the same reference, which holds the result block the
# parser checks.
if grep -qx 'name: adr-gate' "$GATE_SKILL" && grep -qF '=== END ADR_GATE_RESULT ===' "$GATE" &&
  grep -qF '`bash ~/.claude/skills/lib/skill-ref.sh adr-gate references/gate.md`' "$GATE_SKILL" &&
  ! grep -qF 'ADR_GATE_RESULT' "$GATE_SKILL" &&
  grep -qF '/adr-gate --request-file' "$PLUGIN_DIR/../ticket-planner/lib/planner-phase-prompts.sh"; then
  _ok "adr-gate is still a plain skill the planner invokes, and it reads the same gate file"
else
  _bad "adr-gate lost its frontmatter or its read of references/gate.md, holds a second copy of the gate, or the planner no longer invokes /adr-gate"
fi

# The skill fingerprint covers the gate text a phase follows: every manifest
# that loads the preamble lists the gate file, right after the preamble.
unlisted=$(jq -r '.prompt_manifests | to_entries[] | .value.files as $f
  | ($f | index("lib:skill-preamble-auto.md")) as $i | select($i != null)
  | select($f[$i + 1] != "plugin:skills/adr-gate/references/gate.md") | .key' "$TABLE")
if [ -z "$unlisted" ] && [ "$(jq '[.prompt_manifests[].files | index("lib:skill-preamble-auto.md") | select(. != null)] | length' "$TABLE")" -ge 6 ]; then
  _ok "every manifest that loads the preamble lists adr-gate's references/gate.md after it"
else
  _bad "manifests load the preamble without the gate file right after it: $(tr '\n' ' ' <<<"$unlisted")"
fi

# ── Prohibitions against required actions (GitHub #816) ──────────────────────
# The tools: line is not the only way an agent definition can forbid a step.
# ticket-appraise-agent said "MUST NOT ... commit", "never attempt Linear API
# mutations" and "Write only to the ticket workspace" while ticket-appraise-exec,
# dispatched to it, requires a committing script (Step 3.4), a save_comment
# (Step 5) and a write to {TICKETS_ROOT}/app-knowledge.md (Step 3.7); the agent
# obeyed its definition and skipped them. A blanket prohibition in an agent body
# must name every action of that kind its dispatched skills require, as the
# stated exception.

# A committing call is `~/.claude/skills/lib/X.sh commit ...` for a script X
# that runs `git commit` itself (its commit is a subcommand), or any call of a
# wrapper: a lib script that names such a script and runs a `commit` subcommand.
COMMIT_DIRECT=$(grep -lE '^[^#]*\bgit\b[^#]* commit\b' "$PLUGIN_DIR"/lib/*.sh | xargs -n1 basename | sort -u)
COMMIT_WRAPPERS=$(
  for f in "$PLUGIN_DIR"/lib/*.sh; do
    code=$(grep -vE '^[[:space:]]*#' "$f")
    grep -qE '(\.sh|")"? commit\b' <<<"$code" || continue
    grep -oE '[a-z0-9-]+\.sh' <<<"$code" | grep -vxF "$(basename "$f")" |
      grep -qxFf <(printf '%s\n' "$COMMIT_DIRECT") && basename "$f"
  done | sort -u
)

# committing_calls <file>... — the script name of every committing call.
committing_calls() {
  grep -ohE 'skills/lib/[a-z0-9-]+\.sh"?( [a-z-]+)?' "$@" | sed 's|^skills/lib/||; s/"//' |
    while read -r name word; do
      if grep -qxF "$name" <<<"$COMMIT_WRAPPERS" ||
        { [ "$word" = commit ] && grep -qxF "$name" <<<"$COMMIT_DIRECT"; }; then
        echo "$name"
      fi
    done
}

# agent_body <agent.md> — the system prompt, frontmatter dropped.
agent_body() {
  awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } !fm' "$1"
}

# required_actions <skill> — kind<TAB>name per action the skill requires:
#   commit  a committing lib script it runs (`~/.claude/skills/lib/X.sh`)
#   linear  a non-read op in its preamble LINEAR_OPS
#   write   a `{..._ROOT}/file` it tells the agent to append, write or create
required_actions() {
  local skill_dir="$PLUGIN_DIR/skills/$1" files pre=()
  mapfile -t pre < <(preamble_files "$1")
  files=("$skill_dir/SKILL.md" "${pre[@]}")
  for f in "$skill_dir"/references/*.md; do [ -f "$f" ] && files+=("$f"); done
  {
    committing_calls "${files[@]}" | sed 's/^/commit\t/'
    grep -ohE 'LINEAR_OPS=[a-z_,]+' "$skill_dir/SKILL.md" | sed 's/^LINEAR_OPS=//' |
      tr ',' '\n' | grep -vE '^(get_|$)' | sed 's/^/linear\t/'
    grep -hiE '\b(append|write|create)' "${files[@]}" |
      grep -oE '`\{[A-Z_]*ROOT\}/[^`]+`' | tr -d '`' | sed 's|.*/||; s/^/write\t/'
  } | sort -u
}

# forbids <kind> — reads an agent body on stdin; 0 when it carries a blanket
# prohibition of that kind of action.
forbids() {
  case "$1" in
  commit) grep -qE '(MUST NOT|must not|[Nn]ever)[^.]*\bcommit' ;;
  linear) grep -qE '(MUST NOT|must not|[Nn]ever)[^.]*\bLinear\b[^.]*\b(mutations?|state)\b|All Linear mutations go through' ;;
  write) grep -qE '[Ww]rite only to' ;;
  *) return 1 ;;
  esac
}

# prohibition_conflicts <skill> <agent.md> — kind:name per required action the
# agent forbids without naming it.
prohibition_conflicts() {
  local body kind name
  body=$(agent_body "$2")
  while IFS=$'\t' read -r kind name; do
    [ -n "$kind" ] || continue
    forbids "$kind" <<<"$body" || continue
    grep -qF -- "$name" <<<"$body" || echo "$kind:$name"
  done < <(required_actions "$1")
}

printf '%s\n' 'bash ~/.claude/skills/lib/appraise-exec-coherence.sh "X" "D"' \
  'bash ~/.claude/skills/lib/openspec-tracking-check.sh commit d X' \
  'bash "$HOME/.claude/skills/lib/wiki-lock.sh" acquire --wiki-root W' \
  'bash "$HOME/.claude/skills/lib/wiki-finalize.sh" --wiki-root W' >"$TMP/calls.md"
got=$(committing_calls "$TMP/calls.md" | tr '\n' ' ')
if [ "$got" = "appraise-exec-coherence.sh openspec-tracking-check.sh wiki-finalize.sh " ]; then
  _ok "committing calls: a wrapper always, a direct committer only with its commit subcommand"
else
  _bad "committing_calls returned: $got (wrappers: $(tr '\n' ' ' <<<"$COMMIT_WRAPPERS"))"
fi

# The agent definition as it was before #816.
cat >"$TMP/old-appraise-agent.md" <<'EOF'
---
name: ticket-appraise-agent
tools: Bash, Read, Grep, Glob, Write, mcp__gitnexus__impact
---

You are a ticket appraisal agent in the ticket-auto-pipeline. Your scope is investigation and artifact creation only. You may read any file and search the codebase, but you MUST NOT modify source code, create branches, or commit. Write only to the ticket workspace directory (notes.md, simple-fix.md, OpenSpec artifacts). Failures go to the pipeline log — never attempt Linear API mutations directly.
EOF
got=$(prohibition_conflicts ticket-appraise-exec "$TMP/old-appraise-agent.md" | sort | tr '\n' ' ')
if [ "$got" = "commit:appraise-exec-coherence.sh linear:save_comment write:app-knowledge.md " ]; then
  _ok "detector finds the pre-#816 appraise agent forbidding the commit, the comment and app-knowledge.md"
else
  _bad "detector on the pre-#816 appraise agent returned: $got"
fi

conflicts=""
while IFS=$'\t' read -r skill agent; do
  [ -n "$skill" ] || continue
  agent_file="$PLUGIN_DIR/agents/$agent.md"
  [ -f "$agent_file" ] && [ -f "$PLUGIN_DIR/skills/$skill/SKILL.md" ] || continue
  while IFS= read -r c; do
    [ -n "$c" ] && conflicts+="  $skill → $agent: $c"$'\n'
  done < <(prohibition_conflicts "$skill" "$agent_file")
done <<<"$pairs"
if [ -z "$conflicts" ]; then
  _ok "no agent definition forbids an action its dispatched skill requires"
else
  _bad "an agent definition forbids an action its dispatched skill requires (name it as an exception, or change the step):"
  printf '%s' "$conflicts"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
