---
name: ticket-gate-reconcile
description: Post-gate-hold comment reconciliation agent. Spawned when a held ticket is re-approved. Fetches Linear comments, evaluates open questions, incorporates user guidance into the plan artifact, and either passes clean or re-holds with an amendment cycle. Extracted from ticket-auto Step 3.5.
---

# Ticket Gate Reconcile

**Entry condition:** `RESUME_STEP=STEP_3_5` — gate was held, `/ticket-approve` has been run.

## Step 1 — Load context (agent starts cold)

Source the project environment file and extract ticket metadata:

```bash
source /tmp/ticket-auto-{TICKET-ID}-env.sh

# Read pipeline log for gate state
export LOG_FILE="$PWD/logs/{TICKET-ID}-pipeline.log"
export HB_LOG_FILE="$PWD/logs/{TICKET-ID}-heartbeat.log"

~/.claude/skills/lib/hb-wrap.sh
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
ARTIFACT_TYPE=$(resolve_artifact_type "$LOG_FILE" "$NOTES_PATH")
ARTIFACT_TYPE="${ARTIFACT_TYPE:-simple-fix}"
```

Resolve the plan artifact. An openspec change lives at the tickets-repo root
(the current directory — the same `openspec/changes/` that
`ticket-appraise-exec` writes to), never under `$TICKET_DIR`, and it must be
**this** ticket's change, matched by ticket id. If it cannot be found, the
block logs a `GATE|reconcile|fail` line and exits non-zero — stop there and
report the error; never amend some other change's `tasks.md`:

```bash
# The one plan-artifact resolver (lib/ticket-dir.sh): whole-id match, so
# TEST-7 never picks up test-77-...; exit 2 when two change dirs match.
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
RECONCILE_N=$(grep -o '^[^|]*|GATE|reconcile|done|cycle#[0-9]*' "$LOG_FILE" 2>/dev/null |
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
```

## Step 3 — Run comment reconciliation

```bash
RECONCILE_OUTPUT=$(echo "$COMMENTS_JSON" | bash ~/.claude/skills/lib/reconcile-comments.sh "{TICKET-ID}" "$LOG_FILE")
echo "$RECONCILE_OUTPUT"
```

Parse the output to set `{LAST_RECONCILE_AT}`, `{APPRAISAL_COMMENT_AT}`, and `{UNPROCESSED_COMMENTS}`.

**How it works:** `lib/reconcile-comments.sh` finds the appraisal and amendment comments by their `<!-- ticket-auto:... -->` markers. `LAST_RECONCILE_AT` is the later of the two; `UNPROCESSED_COMMENTS` holds only user comments after it, as `timestamp|user|body`.

## Step 4 — Read open questions from notes.md

```bash
RAW_SECTION=$(sed -n '/^## Open Questions/,/^## /p' "$NOTES_PATH")
if echo "$RAW_SECTION" | grep -q '^## '; then
  RAW_SECTION=$(echo "$RAW_SECTION" | sed '/^## Open Questions$/!{/^## /q}')
fi
# Only [needs-human] bullets reach the gate. [agent-resolvable] questions are
# resolved inline by ticket-appraise Step 3.5 (with a mandatory path:line
# citation, verified by the claim-verifier agent) and never left open — the
# gate has no business re-litigating a self-closed factual lookup. This also
# retires strikethrough as a signal here: it was never a reliable one, since
# ticket-appraise's own inline resolutions use the same `~~...~~` marker this
# gate writes at Step 6, with no way to tell which producer wrote which.
OPEN_QUESTIONS_LIST=$(echo "$RAW_SECTION" | grep '^\- \[needs-human\]' || true)
```

If `{OPEN_QUESTIONS_LIST}` is empty or contains only placeholder text ("None", "—"), skip the unanswered-questions check in Step 5.

## Step 5 — Evaluate hold conditions

Two independent conditions. If either triggers, the pipeline holds (proceed to Step 6).

**Condition 1 — Unanswered open questions:**

For each bullet in `{OPEN_QUESTIONS_LIST}`, scan `{UNPROCESSED_COMMENTS}` and all post-appraisal comments for a concrete answer. Use semantic judgment:
- A concrete answer resolves, decides, or explicitly dismisses the question
- Vague replies ("we'll see", "TBD", "maybe", "I'll think about it") do NOT count as answers
- If ANY question lacks a concrete answer → set `HOLD_REASON=unanswered_questions`

**Condition 2 — Unprocessed user comments:**

If `{UNPROCESSED_COMMENTS}` is non-empty → set `HOLD_REASON=unprocessed_comments` (combine with condition 1 if both apply: `HOLD_REASON=unanswered_questions+unprocessed_comments`).

**If neither condition triggers** → skip to Step 8 (clean pass).

## Step 6 — Amendment logic

When a hold condition is active, incorporate user feedback into the plan artifact before re-claiming.

Read the current plan artifact from `$ARTIFACT_PATH`. Append an `## Amendment #N` section (where N = `{RECONCILE_N}`) that:
1. Summarizes the user comments being incorporated
2. Lists concrete changes to the plan required by the feedback
3. Notes any design decisions made during reconciliation

Update `## Open Questions` in notes.md:
- Mark resolved `[needs-human]` questions with `~~strikethrough~~`, tag included inside the strike (do NOT delete them — preserve history). Strikethrough is presentation only now — provenance and gate-relevance both live in the `[needs-human]`/`[agent-resolvable]` tag (Step 4), not in whether a bullet is struck.
- If new unresolvable questions arise from amendment, append them as new `- [needs-human]` bullets

## Step 7 — Post amendment, re-claim, hold

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
_rc=$?
# flow-run.sh has already logged any non-zero exit (META|flow-error + heartbeat).
# re-claim carries no verdict_gate, so exit 11 cannot occur; a failure is non-fatal — continue.
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

No hold conditions active. All open questions are answered and no unprocessed user comments exist. Write the clean log entry:

```bash
bash ~/.claude/skills/lib/plog.sh GATE reconcile done "clean"
hb-wrap.sh decision "reconcile-result" "fired" "clean pass — no unprocessed comments or unanswered questions" "{\"cycle\":\"${RECONCILE_N}\"}"
hb-wrap.sh gate "reconcile" "ok" "clean pass — proceeding to implement"
hb-wrap.sh gate "phase-transition" "ok" "GATE → IMPLEMENT"
```

The router will detect this gate event and proceed to STEP_4.
