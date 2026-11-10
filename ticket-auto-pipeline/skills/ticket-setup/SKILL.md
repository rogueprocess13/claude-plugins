---
name: ticket-setup
description: Creates the local workspace for a Linear ticket — fetches issue data, derives the directory path, creates the directory structure, and writes context.md and a minimal notes.md. Returns the ticket dir path and key issue fields for the calling skill to continue. Used internally by ticket-appraise and ticket-reproduce. Also callable directly if you just want to scaffold a ticket workspace.
---

# Ticket Setup

Creates the local workspace for a Linear ticket — fetches issue data, derives the directory path, creates the directory structure, and writes `context.md` and a minimal `notes.md`.

## Usage

```
/ticket-setup <TICKET-ID>
```

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=none, FROM_FLAG=none, HAS_LINEAR_ACCESS=false, HAS_GUARD=false, HAS_PROJECT_CONTEXT=false, HAS_LOGGING=false, HAS_HEARTBEAT=false, HAS_STEP_DISPATCH=false, HAS_TASK_TRACKER=false

## Step 0 — Project Readiness

Before scaffolding the ticket workspace, ensure the environment is valid and the project has CLAUDE.md and GitNexus indexing. This step is skipped when called with `--from-auto` (the orchestrator handles project readiness separately via `ticket-env-check`).

### Step 0.1 — Validate environment

Run `bash ~/.claude/skills/lib/env-check.sh --mode=validate` to confirm all required env vars, MCP servers, and CLI tools are available. If validation fails, surface the missing fields to the user and stop — nothing downstream works without a valid environment.

### Step 0.2 — Detect project root

Walk up from the current working directory to find the project root. A project root is the first parent directory that contains:
- A `.git` directory, OR
- A `CLAUDE.md` file, OR
- Is listed in `REPOS_ROOT` (if REPOS_ROOT is set)

If no project root is found, use the current working directory as the project root.

### Step 0.3 — Check CLAUDE.md

Check if `CLAUDE.md` exists at the project root. If it does:
- Skip to Step 0.5 (GitNexus check)
- The existing CLAUDE.md is authoritative — do not modify it

### Step 0.4 — Initialize CLAUDE.md (if missing)

Only if `CLAUDE.md` is missing: run `bash ~/.claude/skills/lib/skill-ref.sh ticket-setup references/project-init.md`, read the printed path in full and follow it (0.4a GitNexus, 0.4b existing code, 0.4c empty project), then continue to Step 0.5. If `skill-ref.sh` exits non-zero, report the missing reference and stop: never initialize CLAUDE.md from memory.

### Step 0.5 — GitNexus indexing and analysis

After CLAUDE.md is confirmed to exist (either pre-existing or newly created):

1. **Check indexing status**: Call `mcp__gitnexus__list_repos`. If no repos are listed, or the project repo is missing:
   - Run the `gitnexus-guide` skill or `/gitnexus-guide` to index the repository
   - Wait for indexing to complete before continuing

2. **Verify freshness**: Call `mcp__gitnexus__detect_changes` with `scope: "all"`. If changes are detected and the index is stale, re-index.

3. **Capture architecture context**: Call `mcp__gitnexus__query` with `query: "{TITLE} {DESCRIPTION}"` to get relevant execution flows. Save the summary for the appraise phase.

4. **Heartbeat**: Log the project readiness outcome:
   ```
   heartbeat|project-init|ok|project ready|{"claude_md":"existing|created|empty-seeded","gitnexus":"indexed|newly-indexed|unavailable","project":"{PROJECT_NAME}"}
   ```

---

## Execution

Once project readiness is confirmed (Step 0), scaffold the ticket workspace.

This skill is a thin wrapper around `setup.sh`. All Linear API calls, directory creation, and file generation are handled deterministically by the script.

```bash
bash ~/.claude/skills/ticket-setup/setup.sh "<TICKET-ID>"
```

The script emits a JSON summary to stdout with keys: `ticket_dir`, `url`, `title`, `status`, `project`, `epic`, `existing`.

**Post-script workspace verify** — after the script exits 0, confirm the workspace is complete:

```bash
_ticket_dir=$(echo "$_SETUP_JSON" | jq -r '.ticket_dir // ""')
if [ -z "$_ticket_dir" ] || [ ! -f "$_ticket_dir/notes.md" ] || [ ! -f "$_ticket_dir/context.md" ]; then
  echo "ticket-setup produced incomplete workspace — notes.md or context.md missing at ${_ticket_dir:-<unknown>}"
  exit 1
fi
```

If either file is missing, stop immediately — a silent API failure or partial write has left the workspace unusable. Do not proceed to `ticket-appraise`.

Callers read the JSON output to determine the ticket directory path and whether the workspace already existed.
