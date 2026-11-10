---
name: ticket-document
description: Generates ai-context.md after successful implementation. Diffs the branch against the base branch, reads notes.md for context, classifies significance, and writes structured AI-optimized context to the ticket directory. Called by ticket-auto orchestrator after implement completes.
---

# Ticket Document — Post-Implement Context Generator

You are documenting a completed implementation for future AI agents. Your input is the ticket's `notes.md` and the git history of the implemented branch. Your output is `ai-context.md` in the ticket directory — a terse, structured file optimized for AI consumption.

## Logging (--from-auto)

If `$TAP_LOG` is set (passed by the `ticket-auto` orchestrator): read `~/.claude/skills/pipeline-log-format.md`. Write progress entries at step boundaries. Phase is `MAINTENANCE`.

## Heartbeat (--from-auto)

If `$HB_LOG_FILE` is set (passed by the orchestrator): call `~/.claude/skills/lib/hb-wrap.sh` then write heartbeat entries at these points:
- **Classification decision**: after significance classification, write `hb-wrap.sh decision "significance-classification" "fired" "{trivial|non-trivial}" '{"reason":"{summary}"}'`
- **Document written / failed**: written by `ai-context-finalize.sh` (Step 5).

---

## Step 0 — Load context, branch and diff

The orchestrator passes the ticket directory, and usually the worktree path and branch, in the
spawn instruction. One call loads the rest (fill `{worktree}`/`{branch}` from the instruction,
or leave them empty):

```bash
bash ~/.claude/skills/lib/ai-context-prep.sh {TICKET_ID} --ticket-dir "{ticket-dir}" --worktree "{worktree}" --branch "{branch}"
```

It sources the ticket env file, logs `document start`, prints `CORRECTION_COUNT` and each
correction's fields, `WORKTREE_PATH`/`BRANCH` (from the flags, else notes.md's
pre-implementation checkpoint, else the worktree's checkout) and then the branch's `git log` and
`git diff` against the base's **remote** ref after a fetch (a stale local epic ref would
attribute a previous ticket's commits to this one). Exit 3: worktree or branch not found — find
them (`worktree_path` in `lib/worktree.sh`, or `git branch -a | grep {TICKET-ID}`) and re-run
with the flags.

Read `notes.md` from the ticket directory. Extract:
- `{COMPLEXITY}` — from the `## Complexity` section (simple or complex)
- `{AFFECTED_REPOS}` — from `## Initial Investigation` (which services were touched)
- `{KEY_FINDINGS}` — the main bullet points from Initial Investigation
- `{PLAN_PATH}` — from `## Next Steps` or `## Plan` (path to simple-fix.md or openspec change directory)

---

## Step 3 — Classify significance

Inspect the diff output. Classify the change as **trivial** or **non-trivial**:

**Trivial** (all changes fall into these categories only):
- Config file changes (properties files, env vars, YAML config values)
- Typo fixes (no logic change, only text corrections)
- Version bumps (package.json, pom.xml, build.gradle version numbers only)
- Whitespace or formatting-only changes
- Comment-only changes

**Non-trivial** (any other change):
- Any logic change in source code
- New files added (beyond config or version bumps)
- Test additions or modifications
- Database migration changes
- API contract changes
- Dependency additions or upgrades

**Classification audit log entry** — write to the pipeline log regardless of classification:

```bash
bash ~/.claude/skills/lib/plog.sh MAINTENANCE document info "significance={trivial|non-trivial} reason={one-sentence summary of what the diff contains}"
```

---

## Step 4 — Generate ai-context.md

### Step 4a — Non-trivial changes (full context)

Write `ai-context.md` to the ticket directory with this structure:

```markdown
# AI Context — {ISSUE-ID}

**Date:** {today's date — ISO 8601 format: YYYY-MM-DD}
**Branch:** {branch name}
**Complexity:** {simple|complex}
**Outcome:** {Smooth|Rough|Hard}

## What changed
{for each changed file: `- {file}: {one-line summary of change and purpose}`}

## Patterns used
{concrete coding conventions applied — error handling patterns, repeated code structures, why a specific convention is followed. Each entry anchored with a file path. Skip if no notable patterns.}

## Key files for future agents
- {entry point or core logic file}: {one-line role description}
- {config or infrastructure file}: {one-line role description}

## Watch out for
{non-obvious gotchas a future AI agent would miss — hidden coupling between modules, undocumented invariants, standards governing how things work that aren't obvious from reading the code, struggle areas encountered. Skip if none.}

## Decisions
{non-trivial choices made during implementation with one-line rationale. Only include when a real trade-off was evaluated. Skip if none.}

## Corrections from Implementation
{if CORRECTION_COUNT > 0, list each correction as: `- [{source}] {fact} — {corrected}`; if CORRECTION_COUNT = 0, omit this section entirely}
```

**Content guidelines:**
- **What changed**: Derive from `git diff` and `git log`. Group related file changes. Each entry is one file + one line.
- **Patterns used**: Pull from `notes.md` Key findings and your own read of the diff. Look for repeated structures — error handling conventions, null checks, transaction boundaries, logging patterns. Not abstract GoF patterns; concrete, file-anchored conventions.
- **Key files**: Entry points (controllers, main service classes), core logic files (where the actual fix lives), config files touched. Each with a one-line role description.
- **Watch out for**: Extract from notes.md struggle areas, your own read of the diff for hidden coupling (e.g., "changing X affects Y because they share Z"), undocumented invariants the code assumes. This is the highest-signal section for future agents — prioritize it.
- **Decisions**: Only include if a real trade-off was evaluated during implementation. Format: `- {decision}: {one-line rationale}`. Skip if all choices were straightforward.

### Step 4b — Trivial changes (minimal context)

Write `ai-context.md` to the ticket directory with only:

```markdown
# AI Context — {ISSUE-ID}

**Date:** {today's date — ISO 8601 format: YYYY-MM-DD}
**Branch:** {branch name}
**Complexity:** {simple|complex}
**Outcome:** {Smooth|Rough|Hard}

Trivial change — no architectural impact.
```

---

## Step 5 — Record the result

After writing `ai-context.md` (or failing to), run:

```bash
bash ~/.claude/skills/lib/ai-context-finalize.sh {TICKET_ID} --ticket-dir "{ticket-dir}"
```

It counts the Patterns used and Decisions entries, appends `- ai-context.md written ({N}
patterns, {N} decisions, {C} corrections)` to the notes.md Session Log, logs `document done`
(or `document fail` with exit 1 when the file is missing), records the `ticket_document`
verifier result (PASS when all five sections have content or the change is trivial, else WARN;
FAIL when missing) and the heartbeat, and prints the `DOCUMENT_RESULT` block. End your output
with that block, verbatim.
