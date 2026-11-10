---
name: kc-import
description: Import knowledge items from external sources — openspec changes, plan files, and Linear tickets. Idempotent: re-running updates existing items matched by source field rather than creating duplicates. Use "/kc-import" or "import knowledge items".
---

# Knowledge Import

Import durable knowledge items from three external sources. All ingesters are idempotent — match/update on the `source` field, never create duplicates on re-run.

## Step 1 — Choose import source

The user may specify one or more sources. If none specified, import all three:

| Flag | Source | Item type | Source format |
|------|--------|-----------|---------------|
| `--openspec` | `openspec/changes/*` | `proposal` | `openspec:<change>` |
| `--plans` | `~/.claude/plans/*.md` | `proposal` | `plan:<slug>` |
| `--linear` | Linear tickets | `reference` | `linear:<ID>` |

## Step 2 — Openspec ingester

List every change in `openspec/changes/` with its title, task completion and matching item:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-ingest.sh" audit
```

It prints one tab-separated line per change (`archive/` skipped): `name status done total existing title`. `status` is `done` when every task is checked, else `active`. `existing` is the item already carrying `source: openspec:<name>`: update its `status`, `updated` and task completion when set, otherwise create one (summary from `proposal.md`).

Item template for openspec:
```yaml
---
id: KC-NNNN
type: proposal
title: "<title from proposal.md>"
status: <active|done>
priority: p2
project: <repo-slug>
created: <now>
updated: <now>
source: openspec:<change-name>
why: "<one-line rationale, from proposal.md ## Why>"
tags: [openspec, <from proposal keywords>]
relates: []
---
# <title>

**Source**: openspec change `<change-name>`
**Status**: <done>/<total> tasks complete

<summary from proposal.md ## What Changes>
```

## Step 3 — Plan-file ingester

For each `.md` file in `~/.claude/plans/`:

1. Title: `bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-ingest.sh" title "$plan_file"` (first `# ` heading, else first `## `, else the slug)
2. Check for existing item with `source: plan:<slug>`
3. Derive project from referenced paths/content
4. Create or update

```bash
for plan_file in ~/.claude/plans/*.md; do
  [ -f "$plan_file" ] || continue
  slug=$(basename "$plan_file" .md)
  existing=$(grep -l "source: plan:${slug}" knowledge/KC-*.md 2>/dev/null | head -1)
  # ... create or update
done
```

## Step 4 — Linear ingester (READ-ONLY)

**Critical: This is read-only. Zero mutation calls to Linear.**

Use existing `lib/linear-api.sh` patterns or MCP Linear tools to fetch tickets assigned to/created by the user. For each ticket:

1. Fetch issue metadata (id, title, state, priority)
2. Check for existing item with `source: linear:<ID>`
3. Create `reference` items with last-known status

```yaml
---
id: KC-NNNN
type: reference
title: "<Linear ticket title>"
status: active
priority: <derived from Linear priority>
project: <repo-slug>
created: <now>
updated: <now>
source: linear:<TICKET-ID>
why: "<one-line rationale, from ticket description or title>"
tags: [linear, <ticket labels>]
relates: []
---
# <title>

**Linear**: [<TICKET-ID>](https://linear.app/...)
**State**: <Linear state>
**Last synced**: <now>

<description excerpt>
```

**Idempotency**: Re-running updates the `updated` timestamp and Linear state — does NOT create a duplicate. Never mutates Linear issue state.

**Planner-created tickets carry no Linear labels**, so their imported tags are `[linear]` alone; this importer does not read the local ticket manifest.

## Step 5 — Regenerate index

After all imports:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-index.sh" knowledge/
```

Report summary: "Imported: N new, M updated. 0 duplicates."
