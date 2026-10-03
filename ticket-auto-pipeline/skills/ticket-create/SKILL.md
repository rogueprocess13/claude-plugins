---
name: ticket-create
description: Logs a single new ticket through the standard path — template-shaped body, readiness check, duplicate check, ad-hoc manifest. The only sanctioned way to create a Linear ticket outside the planner; direct MCP `save_issue` creates are blocked. Use when the user or an agent says "log a ticket", "file a ticket", "raise a ticket", "create a ticket", "open a ticket", "this should be a ticket", "found a bug while working on X", "track this", "follow-up ticket", or "/ticket-create".
---

# Ticket Create

Logs one piece of work as one ticket. You write the title and body; `create.sh` decides whether they are good enough and does every write. Do not call the Linear MCP `save_issue` tool or `create_issue` yourself to create an issue — a `PreToolUse` guard denies it and sends you here.

## 1. Route the request first

Decide where the request belongs before you write anything:

| What it is | Where it goes |
|---|---|
| Actionable work in a product repository (a bug, a feature, an improvement, a security fix, a chore) | A Linear ticket, through `create.sh` (this skill) |
| A defect or improvement in **this plugin marketplace's own code** (`ticket-auto-pipeline`, `ticket-planner`, `fleet-controller`, `knowledge-curator`, `grill-me`) | A GitHub issue. Render the body with `github_issue_body_template` and create it with `github_issue_create` (`~/.claude/skills/lib/github-issues.sh`). No ticket IDs or user data — the repo is public. |
| Knowledge, not work — a lesson, a decision, a fact you learned, a discovery with no concrete change attached | The `kc-capture` skill (knowledge-curator). No ticket. |
| An idea that needs several tickets, an epic, or an initiative | `/ticket-planner` (or `/grill-me` first if the idea is still vague). This skill creates exactly one ticket. |

There is no "discovery" ticket. A finding becomes a ticket only when it names concrete work. If you cannot say what should change, capture it as knowledge instead.

## 2. Choose type and kind

- **Type** — `bug` | `feature` | `improvement` | `security` | `chore`. A refactor is an `improvement`.
- **Kind**
  - `business` — a user or business actor experiences the change directly ("Accountants can lock completed financial periods").
  - `enabler` — technical work that makes a capability possible, removes risk, or meets a platform requirement ("Add an index on documents(account_id, created_at) for search latency"). Never write a fake user story ("As a developer, I want…") for an enabler.

## 3. Write the body

Read the template for the type: `~/.claude/skills/ticket-create/templates/<type>.md`. Keep the template's own headings unchanged — the checks look for them. Arrange the body business-first:

1. `## Summary` — what this ticket does, in plain language.
2. `## Outcome` (business) with `**Who:**`, `**Need:**`, `**Outcome:**` — no implementation detail in these fields. **Or** `## Enables` (enabler) — what the technical work makes possible, or the technical reason for it.
3. The why/outcome sections the readiness check reads (`INTENT_MISSING` otherwise):
   - bug: `## Expected Behaviour` and `## Actual Behaviour`.
   - every other type: one **why** heading — `## Background / Motivation`, `## Motivation`, `## Problem`, `## Why` or `## Context` — and one **outcome** heading — `## Proposed Behaviour`, `## Proposed Changes`, `## Desired Outcome` or `## Goal`. The `improvement` template's `## Desired Behaviour` and the `security` template's sections do not count on their own: add a `## Proposed Changes` section (and a `## Background / Motivation` for security).
4. `## Technical Context` — files, symbols, routes, the approach. Implementation detail lives here and nowhere above.
5. The template's remaining sections: `## Acceptance Criteria` (`- [ ]` items, observable and testable), `## Scope` table, `## Test User` and `## Navigation Path` (UI work only), `## Steps to Reproduce` and `## Test Data Prerequisites` (bugs), `## Related Tickets`.

**Title rules**
- Business: `<Actor> can <capability>` or a short outcome statement, at most ~80 characters, readable without repository knowledge. No file paths, routes, code symbols, phase codes or process terms.
- Enabler: may be technical ("Migrate BOM microservice to Java 17").

**Do not invent.** No made-up actors, business value, metrics, ROI, customer commitments or regulatory requirements. If you do not know who needs the change or why, say so plainly in the body (`Who: not established — <the question a human must answer>`) rather than guessing. Do not add a `## Planner Context` block — this ticket is not planned.

## 4. Dry run, then create

Write the body to a scratch file, then run the dry run first:

```bash
bash ~/.claude/skills/ticket-create/create.sh \
  --type <type> --kind <business|enabler> \
  --title "<title>" --body-file <scratch>/body.md \
  [--team <key|name|uuid>] [--parent <ID>] --dry-run
```

`--team` defaults to `LINEAR_TEAM_ID` (or the only visible team). `--parent` makes the new ticket a sub-issue. `REPOS_ROOT` must be set (env or the project `CLAUDE.md`).

When the dry run exits 0, run the same command without `--dry-run`. On success it prints one JSON line — `{identifier, id, url, type, kind, manifest}` — report the identifier and URL.

## 5. Exit codes — what to do next

| Exit | Meaning | Next step |
|---|---|---|
| 0 | Created (or dry run passed) | Report the identifier and URL. |
| 1 | Usage or configuration error | Read stderr; fix the argument, team or `REPOS_ROOT`. |
| 2 | Body or readiness check failed | `BODY_CHECK_MISSING=` lists missing sections; `DOR_MISSING=` lists hard readiness codes (e.g. `INTENT_MISSING`, `AC_VAGUE`, `NAV_PATH_MISSING`). Fill them from the template and retry. `DOR_ADVISORY=` codes are informational and never block. |
| 3 | Possible duplicate | Each `DUPLICATE\|<ID>\|<score>\|<title>` line is an open issue with a similar title. Read them. If one covers the work, do not create — comment on it or report it. If the work is genuinely different, rerun with `--duplicate-ok "<why it is different>"`; the reason is recorded in the body under `## Related Tickets`. |
| 4 | Linear API failure | Nothing was created. Retry once; if it fails again, report the error. |
| 5 | Created, but the manifest write failed | The issue **exists** (the JSON is still printed). Do NOT retry creation. Report the identifier and the manifest error. |

The duplicate threshold is `TICKET_CREATE_DUP_THRESHOLD` (default 60, Jaccard over significant title terms). A created ticket is not dispatched automatically — it waits for a human or `/ticket-auto <ID>` like any other ad-hoc ticket.
