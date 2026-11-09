---
name: ticket-gate-reconcile
description: Post-gate-hold comment reconciliation agent. Spawned when a held ticket is re-approved. Fetches Linear comments, evaluates open questions, incorporates user guidance into the plan artifact, and either passes clean or re-holds with an amendment cycle. Extracted from ticket-auto Step 3.5.
---

# Ticket Gate Reconcile

**Entry condition:** `RESUME_STEP=STEP_3_5` — gate was held, `/ticket-approve` has been run.

## Step 1 — Load context (agent starts cold)

Load the env file and ticket metadata:

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET-ID}

# Read pipeline log for gate state
export TAP_LOG="$PWD/logs/{TICKET-ID}-pipeline.log"
export HB_LOG_FILE="$PWD/logs/{TICKET-ID}-heartbeat.log"

source ~/.claude/skills/lib/linear-api.sh
source ~/.claude/skills/lib/ticket-dir.sh
source ~/.claude/skills/lib/notes-parse.sh

# Resolve ticket directory and notes.md FIRST — the ARTIFACT_TYPE fallback
# below reads notes.md, so NOTES_PATH must be set before it.
TICKET_DIR=$(resolve_ticket_dir "{TICKET-ID}" "." 2>/dev/null || echo ".")
NOTES_PATH="$TICKET_DIR/notes.md"
if [ -f "$NOTES_PATH" ]; then
  COMPLEXITY=$(get_complexity "$TICKET_DIR" 2>/dev/null || echo "$COMPLEXITY")
fi

# ARTIFACT_TYPE: the EXEC create-artifact line (canonical token), else
# notes.md's "Artifact type:" line, else simple-fix.
ARTIFACT_TYPE=$(resolve_artifact_type "$TAP_LOG" "$NOTES_PATH")
ARTIFACT_TYPE="${ARTIFACT_TYPE:-simple-fix}"
```

Resolve the plan artifact: **this** ticket's openspec change under the tickets-repo root's
`openspec/changes/` (never `$TICKET_DIR`). If the block exits non-zero, stop and report the
error; never amend another change's `tasks.md`:

```bash
PLAN_PATH=""
_plan_rc=0
_plan_out=$(resolve_plan_artifact "{TICKET-ID}" --root . --ticket-dir "$TICKET_DIR" --type "$ARTIFACT_TYPE") || _plan_rc=$?
[ "$_plan_rc" -eq 0 ] && eval "$_plan_out"
if [ "$ARTIFACT_TYPE" = "openspec" ]; then
  ARTIFACT_PATH="$PLAN_PATH"
  if [ "$_plan_rc" -ne 0 ] || [ ! -f "$ARTIFACT_PATH" ]; then
    bash ~/.claude/skills/lib/plog.sh GATE reconcile fail "openspec tasks.md for {TICKET-ID} not found under $PWD/openspec/changes/ (resolver rc=$_plan_rc)"
    echo "ticket-gate-reconcile: no unique openspec change for {TICKET-ID} under $PWD/openspec/changes/ — cannot amend the plan" >&2
    exit 1
  fi
else
  ARTIFACT_PATH="${PLAN_PATH:-$TICKET_DIR/simple-fix.md}"
fi
```

```bash
hb_init
hb-wrap.sh gate "reconcile" "info" "gate-reconcile agent starting" "{\"complexity\":\"$COMPLEXITY\"}"
```

## Step 2 — Resolve gate cycle and fetch comments

Initialize the cycle counter and fetch Linear comments:

```bash
# Distinct cycle numbers, not lines — the router echoes `cycle#N` in its own
# done line, so a line count double-counts (same rule as detect-resume.sh).
RECONCILE_N=$(grep -o '^[^|]*|GATE|reconcile|done|cycle#[0-9]*' "$TAP_LOG" 2>/dev/null |
  sed 's/.*cycle#//' | sort -u | wc -l | tr -d ' ' || true)
RECONCILE_N=${RECONCILE_N:-0}
RECONCILE_N=$((RECONCILE_N + 1))

if [ -n "${LINEAR_API_KEY:-}" ]; then
  COMMENTS_JSON=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_comments '{TICKET-ID}'")
else
  COMMENTS_JSON=$(mcp__linear-server__list_comments id="{TICKET-ID}")
fi

# Normalize to flat array of {createdAt, body, user: {name}} objects
COMMENTS_JSON=$(echo "$COMMENTS_JSON" | bash -c "source ~/.claude/skills/lib/linear-api.sh; normalize_comments")

# For Step 8 (MCP fallback: write the description here).
bash -c "source ~/.claude/skills/lib/linear-api.sh; get_issue '{TICKET-ID}'" | jq -r '.description // ""' >"$TICKET_DIR/artifacts/tracker-description.md"
```

## Step 3 — Run comment reconciliation

```bash
RECONCILE_OUTPUT=$(echo "$COMMENTS_JSON" | bash ~/.claude/skills/lib/reconcile-comments.sh "{TICKET-ID}" "$TAP_LOG")
echo "$RECONCILE_OUTPUT"
```

Parse the output to set `{LAST_RECONCILE_AT}`, `{APPRAISAL_COMMENT_AT}`, and `{UNPROCESSED_COMMENTS}`.

`UNPROCESSED_COMMENTS` holds the user comments (`timestamp|user|body`) after the latest marked appraisal/amendment comment.

## Step 4 — Read open questions from notes.md

```bash
RAW_SECTION=$(sed -n '/^## Open Questions/,/^## /p' "$NOTES_PATH")
if echo "$RAW_SECTION" | grep -q '^## '; then
  RAW_SECTION=$(echo "$RAW_SECTION" | sed '/^## Open Questions$/!{/^## /q}')
fi
# Only unstruck [needs-human] bullets reach the gate; [agent-resolvable] ones
# are closed by ticket-appraise Step 3.5 with a verified path:line citation.
OPEN_QUESTIONS_LIST=$(echo "$RAW_SECTION" | grep '^\- \[needs-human\]' || true)
```

If `{OPEN_QUESTIONS_LIST}` is empty or contains only placeholder text ("None", "—"), skip the unanswered-questions check in Step 5.

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

Bash decides (#599): hold on any unstruck `[needs-human]` bullet or new-input comment, never on answers alone.

```bash
eval "$(bash ~/.claude/skills/lib/reconcile-decide.sh --notes "$NOTES_PATH" --comments "$COMMENTS_N" --new-input "$NEW_INPUT_N")"
echo "$RECONCILE_DECISION $HOLD_REASON"
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

Call `re-claim` to clear the approval fact (and remove the `pre-approved` label):

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "$PWD/logs/{TICKET-ID}-pipeline.log" {TICKET-ID} re-claim
# flow-run.sh logs any failure itself; it is non-fatal — continue.
```

Write the held log entry:

```bash
bash ~/.claude/skills/lib/plog.sh GATE reconcile done "cycle#${RECONCILE_N} held: ${HOLD_REASON}"
hb-wrap.sh decision "reconcile-result" "fired" "held: ${HOLD_REASON}" "{\"cycle\":\"${RECONCILE_N}\",\"reason\":\"${HOLD_REASON}\"}"
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

First compare the tracker's ACs, which the operator may have edited during the hold, with the workspace (#604). On drift (exit 1) the script refreshes `context.md`; add a notes.md Verification Plan row (same columns, next number) for each `AC_ADDED_n` and any AC still without one, and note it in the Session Log:

```bash
bash ~/.claude/skills/lib/ac-drift.sh "$TICKET_DIR" --description-file "$TICKET_DIR/artifacts/tracker-description.md" --refresh --tag GATE --log-file "$TAP_LOG"
```

Write the clean log entry:

```bash
bash ~/.claude/skills/lib/plog.sh GATE reconcile done "clean"
hb-wrap.sh decision "reconcile-result" "fired" "clean pass — no open questions or new input" "{\"cycle\":\"${RECONCILE_N}\"}"
hb-wrap.sh gate "reconcile" "ok" "clean pass — proceeding to implement"
hb-wrap.sh gate "phase-transition" "ok" "GATE → IMPLEMENT"
```

The router will detect this gate event and proceed to STEP_4.
