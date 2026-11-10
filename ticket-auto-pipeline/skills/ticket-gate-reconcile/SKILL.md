---
name: ticket-gate-reconcile
description: Post-gate-hold comment reconciliation agent. Spawned when a held ticket is re-approved. Fetches Linear comments, evaluates open questions, incorporates user guidance into the plan artifact, and either passes clean or re-holds with an amendment cycle. Extracted from ticket-auto Step 3.5.
---

# Ticket Gate Reconcile

**Entry condition:** `RESUME_STEP=STEP_3_5` — gate was held, `/ticket-approve` has been run.

## Steps 1–4 — Load context, comments and open questions (agent starts cold)

Run from the tickets repo root:

```bash
bash ~/.claude/skills/lib/gate-reconcile-prep.sh {TICKET-ID}
```

It sources the env file, resolves the ticket dir, `COMPLEXITY`, the artifact type and **this**
ticket's plan artifact (`ARTIFACT_PATH`: its openspec change under the tickets repo's
`openspec/changes/`, never `$TICKET_DIR`), writes the start heartbeat, computes `RECONCILE_N`
(this cycle), fetches and normalizes the Linear comments, saves the tracker description for Step 8
and prints the `reconcile-comments.sh` output (`LAST_RECONCILE_AT`, `APPRAISAL_COMMENT_AT` and
`UNPROCESSED_COMMENTS`: the user comments, `timestamp|user|body`, after the latest marked
appraisal/amendment comment) and the unstruck `- [needs-human]` bullets of `## Open Questions`
(`[agent-resolvable]` ones are closed by ticket-appraise Step 3.5). Exit 1: no unique openspec
change, already logged; stop and report it, and never amend another change's `tasks.md`. Exit 4:
`LINEAR_API_KEY` is unset; save `mcp__linear-server__list_comments` output to a file, re-run with
`--comments-file <file>`, and write the issue description to
`{ticket-dir}/artifacts/tracker-description.md` yourself.

If the open questions are empty or only placeholder text ("None", "—"), skip the
unanswered-questions check in Step 5.

## Step 5 — Judge answers and comments

**Questions:** for each bullet in `{OPEN_QUESTIONS_LIST}`, scan `{UNPROCESSED_COMMENTS}` and all post-appraisal comments for a concrete answer — one that resolves, decides, or explicitly dismisses it. Vague replies ("we'll see", "TBD", "maybe") are not answers.

**Comments:** classify each unprocessed comment. **answer-only**: it answers open questions and asks for nothing else (any plan edit it implies is the one the question already proposed). **new-input**: anything else — a new requirement, a scope change, a disagreement with the plan, a question back. An answer that adds behaviour, a field, a role or an AC is new-input. Set `NEW_INPUT_N` to the new-input count and `COMMENTS_N` to the total.

If there are no unprocessed comments and no answered-but-unstruck question, skip Step 6.

## Step 6 — Amendment logic

Incorporate the comments and answers into the plan artifact.

Read the current plan artifact from `$ARTIFACT_PATH`. Append an `## Amendment #N` section (where N = `{RECONCILE_N}`) that:
1. Summarizes the user comments being incorporated
2. Lists concrete changes to the plan required by the feedback
3. Notes any design decisions made during reconciliation

Update `## Open Questions` in notes.md:
- Strike resolved `[needs-human]` questions, tag inside the strike (`- ~~[needs-human] …~~`); never delete them. Step 7 counts every unstruck one as open.
- If new unresolvable questions arise from amendment, append them as new `- [needs-human]` bullets

## Step 7 — Decide, post amendment, re-claim, hold

Bash decides (#599): `decide` runs `reconcile-decide.sh`, which holds on any unstruck `[needs-human]` bullet or new-input comment, never on answers alone.

```bash
bash ~/.claude/skills/lib/gate-reconcile-finish.sh {TICKET-ID} decide --comments {COMMENTS_N} --new-input {NEW_INPUT_N}
```

`clean` → Step 8. `clean-recorded` → post the amendment comment below (moving the next boundary past the answers) without `re-claim` or the held entry, then Step 8. `hold` → all of this step.

Post an amendment comment to Linear summarizing what changed and what's still open:

```bash
AMENDMENT_BODY="**Amendment cycle #${RECONCILE_N}**

## Changes incorporated
{summary of incorporated user comments and plan changes}

## Open questions remaining
{list of still-unanswered questions, or 'None — all questions resolved'}

## New questions raised by this cycle
{list of new questions, or 'None'}"
```

Run `AMENDMENT_BODY` through the `simple-english` skill (embedded mode, Plain) before posting (users find the open-questions list hardest to read). Leave code blocks, identifiers, and file paths untouched. Then append `<!-- ticket-auto:amendment -->` verbatim as the last line: reconcile finds the comment by it.

Use the Linear access strategy to post the comment (bash `save_comment` when `LINEAR_API_KEY` is set, MCP fallback otherwise).

Then clear the approval fact (`re-claim`, which also removes the `pre-approved` label; non-fatal)
and write the held log entry and heartbeat:

```bash
bash ~/.claude/skills/lib/gate-reconcile-finish.sh {TICKET-ID} hold --reason "{HOLD_REASON}"
```

Stop with a user-facing report:

```
## {TICKET-ID} — amendment cycle #{RECONCILE_N}

**Hold reason:** {HOLD_REASON}

### Incorporated
{summary of what was incorporated into the plan}

### Open questions
{list of still-unanswered questions}

### Next step
Review the amendment comment in Linear, then run `/ticket-approve {TICKET-ID}` and re-run `/ticket-auto {TICKET-ID} --auto`.
```

## Step 8 — Clean pass

One call compares the tracker's ACs, which the operator may have edited during the hold, with the
workspace (#604: `ac-drift.sh ... --refresh --tag GATE`), then writes the clean log entry and
heartbeats:

```bash
bash ~/.claude/skills/lib/gate-reconcile-finish.sh {TICKET-ID} clean
```

On drift it refreshes `context.md` and prints `AC_ADDED_n`: add a notes.md Verification Plan row
(same columns, next number) for each, and for any AC still without one, and note it in the
Session Log. The router then detects the gate event and proceeds to STEP_4.
