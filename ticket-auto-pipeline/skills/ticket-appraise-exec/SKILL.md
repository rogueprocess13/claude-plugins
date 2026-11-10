---
name: ticket-appraise-exec
description: Artifact executor for a Linear ticket that has already been investigated by /ticket-appraise. Reads the complexity score from notes.md, creates either simple-fix.md or an openspec change, assigns the ticket in Linear, posts the appraisal comment, and moves to Approve state. Run after /ticket-appraise has fully populated notes.md.
---

# Ticket Appraise — Executor

You have been given a ticket ID as the argument (e.g. `WIL-42`). The investigation phase (`/ticket-appraise`) must already be complete — notes.md must contain a `## Complexity` section and a populated `## Initial Investigation` section. Execute the steps below in order.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=EXEC, HAS_LINEAR_ACCESS=true, LINEAR_OPS=save_comment, HAS_LOGGING=true, HAS_HEARTBEAT=true. Before starting, source the project context: `source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=EXEC, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=save_comment, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT,ISSUE_PREFIX,BE_SERVICES,BE_TEST_CMD, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
Steps 3.7 and 3.8 write their own heartbeats inline; Step 3.4's script writes its own. Also write (event schema: `pipeline-heartbeat-format.md`):
- after reading complexity: `hb-wrap.sh decision "complexity-read" "info" "complexity: {simple|complex}" '{"score":"{COMPLEXITY}"}'`
- after writing the artifact: `hb-wrap.sh decision "artifact-created" "fired" "created {simple-fix|openspec}" '{"type":"{simple-fix|openspec}"}'`
- after the regression guard: `hb-wrap.sh decision "regression-verdict" "fired" "{CONFLICT|ADJACENT|SUPERSEDES|clear}" '{"verdict":"{CONFLICT|ADJACENT|SUPERSEDES|clear}"}'`
- MCP fallback used to post the comment (LINEAR_API_KEY unset): `hb-wrap.sh fallback "linear-api" "fired" "using MCP Linear tools" '{"reason":"LINEAR_API_KEY unset"}'`
- after the adversarial agent: `hb-wrap.sh decision "adversarial-review" "fired" "{PASS|WARNINGS|BLOCKED}" '{"verdict":"{PASS|WARNINGS|BLOCKED}","issues":"{N}"}'`
- Step 4 skips Steps 5-6: `hb-wrap.sh decision "re-appraisal-skip" "info" "no changes detected, skipping Linear post"`

### Step dispatch
| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `load-workspace` | Step 3 (create artifact) | notes.md `## Complexity` for COMPLEXITY; context.md for ticket metadata |
| `create-artifact` | Step 3.5 (regression guard) | simple-fix.md or openspec change already exists; complex: `references/adversarial-review.md` and `references/verification-plan.md` per the Step 3 condition |
| `regression-guard` | Step 4 (re-appraisal check) | `## ⚠️ Regression Risk` in notes.md if present |
| `verify-plan-derived` | Step 3.7 (derive verification plan) | `## Verification Plan` in notes.md if present; `references/verification-plan.md` per the Step 3 condition |
| `post-linear` | End — skill already complete | — |

---

## Step 1 — Load ticket workspace

Find the local directory (whole-ID match on `{TICKET-ID}--slug`, so `WIL-4` never finds
`WIL-42--...`; exit 2 lists several matches, exit 12 none):
```bash
bash ~/.claude/skills/lib/ticket-dir.sh ticket-dir "{TICKET-ID}" .
```

bash ~/.claude/skills/lib/plog.sh EXEC load-workspace start "Loading ticket workspace"

If not found → tell the user to run `/ticket-appraise {TICKET-ID}` first. Stop here.

Read both files:
- `context.md` — ticket scope, labels, affected areas
- `notes.md` — investigation findings, complexity score, open questions

**Verify notes.md is ready:** It must contain a `## Complexity` heading with `**Score:**` set. If missing, the planner has not completed — stop and tell the user to finish `/ticket-appraise {TICKET-ID}` first.

Extract from notes.md:
- `{COMPLEXITY}` — `simple` or `complex`
- `{AFFECTED_REPOS}` — repos mentioned in Initial Investigation
- `{OPEN_QUESTIONS}` — anything listed under Open Questions
- `{INVESTIGATION_BULLETS}` — 2-4 key bullets from Initial Investigation
- `{BLAST_RADIUS}` — if `## Blast Radius` section exists, extract the table rows (target, risk, d=1/d=2 callers, affected flows); otherwise `none`

bash ~/.claude/skills/lib/plog.sh EXEC load-workspace done "Loaded {COMPLEXITY}"

---

## Step 1.5 — Create task tracker

Create a TaskCreate for every remaining step (Steps 2.5 through 7). Each task subject = the step heading. After each step is fully done, mark it completed with TaskUpdate.

---

## Step 2.5 — ADR gate check

Before drafting `simple-fix.md` or an openspec change, check whether notes.md's `## Initial
Investigation` (populated by `ticket-appraise`) already names a decision candidate that looks
architectural — including one `ticket-appraise` itself flagged but did not resolve at 3a.0b. If
so, invoke the gate now — see § 8 ADR gate in the shared preamble — **before** Step 3 writes the
artifact, so the artifact reflects a verdict rather than an unexamined assumption baked into the
implementation plan. If the request results in a `CREATED_PROPOSED`, `SUPERSEDE_REQUIRED`, or
`CONFLICT` verdict, the resulting hold or gate-stop happens here, before any artifact exists —
there is nothing to roll back if a human's answer changes the approach.

The overwhelmingly common case is nothing to check here — skip straight to Step 3 when notes.md
carries no such candidate.

---

## Step 3 — Create change artifacts

bash ~/.claude/skills/lib/plog.sh EXEC create-artifact start "Creating artifact"

Branch on `{COMPLEXITY}` extracted from notes.md:

### Reference files (load condition)

**If `{COMPLEXITY}` = simple**, run `bash ~/.claude/skills/lib/skill-ref.sh ticket-appraise-exec references/simple-fix-template.md` before Step 3-Simple writes `simple-fix.md`. **If `{COMPLEXITY}` = complex**, run `bash ~/.claude/skills/lib/skill-ref.sh ticket-appraise-exec references/adversarial-review.md` before Step 3.6 spawns the reviewer and `bash ~/.claude/skills/lib/skill-ref.sh ticket-appraise-exec references/verification-plan.md` before Step 3.7 derives the plan, including on a `--from-step` resume (`create-artifact`, `verify-plan-derived`) that skips this step. Read each printed path in full and do not continue until you have read it. If `skill-ref.sh` exits non-zero, run `bash ~/.claude/skills/lib/plog.sh META reference-missing fail "references/<file>.md"` with the file that failed and stop: never write `simple-fix.md`, the reviewer prompt or the verification plan from memory. A simple ticket reads neither complex file; a complex ticket does not read the simple-fix template.

A `--from-step` resume skips Step 1, so take `{COMPLEXITY}` from notes.md `## Complexity` with the Step 3.4 `get_complexity` call. After a context compaction, read the reference again before continuing the step it covers.

---

### Step 3-Simple (complexity = simple)

Create `simple-fix.md` in the ticket directory. Do not run `opsx:propose`.

Moved to `references/simple-fix-template.md` (the Completion Checklist requirement and the `simple-fix.md` template), read per the Step 3 condition.

---

### Step 3-Complex (complexity = complex)

**Planner proposal reuse (planned tickets):** Before running `/opsx:propose`, check whether the ticket has a planner-authored proposal that can be adopted verbatim:

```bash
source ~/.claude/skills/lib/planner-artifacts.sh
source ~/.claude/skills/lib/appraise-exec-planned.sh
adopt_planner_proposal "{TICKET-ID}" "{change-name}" "$TAP_LOG"
case $? in
  0) echo "Planner proposal adopted — skipping /opsx:propose re-derivation" ;;
  1) echo "No planner proposal found — running /opsx:propose to derive plan"
     RUN_OPSX_PROPOSE=true ;;
  2) echo "ERROR: proposal copy failed — aborting" && exit 1 ;;
esac
```

**If RUN_OPSX_PROPOSE is true**, run the `/opsx:propose` skill to create the change artifacts for this ticket.

**Derive the change name:** `{ticket-id-lowercase}-{title-slug}` (e.g. `wil-42-upload-page-scroll`).

Pass the following to the propose skill as context:

- The ticket ID, title, and description
- The affected repos and files from the investigation in notes.md
- Whether any **backend (BE) repos** are involved — use `{BE_SERVICES}` resolved in Step 0.5
- {If BLAST_RADIUS is not "none":} The blast radius table from notes.md — affected communities, execution flows, and high-risk targets

**Unit test requirement (BE only):** After `tasks.md` is generated, check whether it contains a task for writing or updating unit tests. If the ticket touches any BE repo and no such task exists, add one explicitly:

```markdown
### Write unit tests for <service> changes
- Identify the service classes / methods modified in this ticket
- Write or update unit tests covering the new/changed logic
- Run `{BE_TEST_CMD}` in the affected repo and confirm all tests pass
```

Insert this task after the main implementation tasks and before any commit/push tasks.

**After writing the artifact, immediately verify the file exists on disk before logging done:**
```bash
# simple path
[ ! -f "{TICKET_DIR}/simple-fix.md" ] && {
  bash ~/.claude/skills/lib/plog.sh META gate-stop fail "EXEC_NO_ARTIFACT — Write tool returned error or file missing after write"
  echo "ERROR: simple-fix.md was not written to disk. Check for hook blocks (PreToolUse errors) and retry." >&2
  exit 1
}
```

bash ~/.claude/skills/lib/plog.sh META artifact info "plan:{artifact_path}"
bash ~/.claude/skills/lib/plog.sh EXEC create-artifact done "{simple-fix|openspec}"
cl_write RETRO hint info "artifact path derived from TICKET_DIR={TICKET_DIR} — verify path resolution works when WORKSPACE_ROOT differs from default"

---

## Step 3.4 — Complexity-coherence gate

After writing the artifact, check that the declared complexity matches what was produced. Run it from the tickets repo root:
```bash
bash ~/.claude/skills/lib/appraise-exec-coherence.sh "{TICKET-ID}" "{TICKET_DIR}"
```

It reads `**Score:**` under `## Complexity` (`notes-parse.sh`), tests `simple-fix.md` and the openspec change dir (`ticket-dir.sh change-dir`, whole-ID match) on disk, and writes the coherence-check heartbeat. A mismatch is several matching change dirs, no score, `simple` with no `simple-fix.md`, or `complex` with no change dir `tasks.md`: it writes `META|gate-stop|fail|COMPLEXITY_ARTIFACT_MISMATCH — declared=… artifact=…` and exits 1. Then stop with non-zero exit so `ticket-auto` halts the pipeline.

On a `complex` match it commits the change dir into the tickets repo (`openspec-tracking-check.sh commit`, issue #363: the plan of record must not depend on an operator's `git add`), force-adding past any blanket `openspec/` ignore and never touching a code repo. It logs `META|gate-warn|info|OPENSPEC_ARTIFACT_COMMIT — rc=… dir=…` (`warn` on a failed commit) and writes the artifact-persisted heartbeat. A failed commit never halts: `ticket-implement` Step 5.5 re-checks tracking. Exit 0 → proceed to Step 3.5.

---

## Step 3.5 — Regression Guard

bash ~/.claude/skills/lib/plog.sh EXEC regression-guard start "Checking plan against prior art"

Read the `## Prior Art` section of notes.md. If it says "No relevant prior art found." and there are no `[local-ticket]` entries → skip this step entirely, proceed to Step 4.

Otherwise:

**A. Extract affected files from the plan:**
- If `{COMPLEXITY}` = simple: read `simple-fix.md` → collect every file path listed under `## Affected files`
- If `{COMPLEXITY}` = complex: read `openspec/changes/{change-name}/tasks.md` → collect every file path mentioned in implementation tasks

**B. Cross-reference:** For each file path in the plan, check whether any Prior Art hit mentions the same file path, class name, or component name. A match is when the same token appears in both the plan's affected-file list and the prior art hit's **Key finding** or **Incorporate** lines.

**C. For each overlapping file, perform conflict reasoning:**

Read the prior ticket's artifact: check for `simple-fix.md` in the matched ticket directory first, then fall back to the `## Initial Investigation` section of its notes.md. Read the relevant section of the current plan for that same file. Then explicitly reason:

> "The prior fix did X to this file. The current plan does Y. Does Y undo, overwrite, or conflict with X?"

Assign a verdict:
- `CONFLICT` — the current plan would undo or overwrite the prior fix
- `ADJACENT` — same file, different lines/method/section, no direct conflict
- `SUPERSEDES` — current plan intentionally replaces the prior fix (document why)

**D. Write to notes.md** if any overlap exists (regardless of verdict):

```markdown
## ⚠️ Regression Risk

| Plan file | Prior art | Verdict | Detail |
|-----------|-----------|---------|--------|
| `{file}` | {TICKET-ID} [local-ticket\|mem] | CONFLICT\|ADJACENT\|SUPERSEDES | {one sentence} |

**Status:** UNACKNOWLEDGED
→ Edit this file and change Status to `ACKNOWLEDGED` before running `/ticket-implement {TICKET-ID}`.
```

**E. Print to user:**

If any CONFLICT verdict:
```
⚠️  REGRESSION RISK — CONFLICT DETECTED
The implementation plan for {TICKET-ID} conflicts with a prior fix.
See ## Regression Risk in notes.md. Change Status to ACKNOWLEDGED after reviewing before running /ticket-implement.
```

If ADJACENT or SUPERSEDES only (no CONFLICT):
```
ℹ️  Regression check: overlapping files found, no direct conflict (see ## Regression Risk in notes.md).
Acknowledge in notes.md before implementing.
```

If no overlap: write nothing — proceed silently.

bash ~/.claude/skills/lib/plog.sh EXEC regression-guard done "{CONFLICT|ADJACENT|SUPERSEDES|clear}"

### Post regression-guard: Record verifier result (Phase 0 RLVR)
```bash
source ~/.claude/skills/lib/verifier-result.sh
write_verifier_result verifier=regression_guard verdict=<PASS|WARN> criteria_met=<N> criteria_total=<M> attempt=1 phase=EXEC
```
Map: clear → PASS, CONFLICT → WARN, ADJACENT → WARN, SUPERSEDES → PASS.

---

## Step 3.6 — Adversarial Review (complex tickets only)

**Only run this step if `{COMPLEXITY}` = complex.** If simple, skip to Step 4.

**Round awareness (GitHub #203).** Before spawning, count how many consecutive prior rounds of this review came back BLOCKED for this ticket. The count is deterministic bash — never estimate it yourself:

```bash
source ~/.claude/skills/lib/adversarial-rounds.sh
ADV_PRIOR_BLOCKS=$(adversarial_round_count "${TAP_LOG:-}")
ADV_ROUND=$((ADV_PRIOR_BLOCKS + 1))
echo "ADV_PRIOR_BLOCKS=${ADV_PRIOR_BLOCKS} ADV_ROUND=${ADV_ROUND}"
bash ~/.claude/skills/lib/plog.sh EXEC adversarial-review start "Spawning adversarial agent (round ${ADV_ROUND})"
```

`ADV_PRIOR_BLOCKS` counts `META|gate-stop|fail|ADVERSARIAL_BLOCKED` lines since the last PASS/WARNINGS verdict; recovery notes between rounds do not reset it (see `lib/adversarial-rounds.sh`). Shell variables do not survive between Bash calls, so note the two printed values and substitute them wherever `{ADV_PRIOR_BLOCKS}` and `{ADV_ROUND}` appear below.

Spawn a `general-purpose` agent with an adversarial framing. Its sole job is to find what's wrong, missing, or under-specified in the implementation plan — not to confirm it's correct.

**⚠️ MANDATORY — read before spawning:** the `Task` call's return is not the end of this skill. Handle it per **"When the agent returns"**, then continue in the same turn through Steps 3.7 → 3.8 → 4 → 5 → 6 → 7; stopping here leaves the ticket with no Linear comment.

Moved to `references/adversarial-review.md` (the reviewer prompt, plus the Approach review block appended from round 3 on, when `{ADV_PRIOR_BLOCKS}` ≥ 2), read per the Step 3 condition.

**When the agent returns:**

Append its output verbatim to notes.md under the `## Adversarial Review` heading. Do not reinterpret or summarise.

**Then keep going — do not stop here.** Evaluate the verdict below and proceed: Steps 3.7, 3.8, 4, 5 and 6 still run in this session before the ticket is assigned, commented on and moved to Approve.

**Record every verdict, BLOCKED included, before any gate-stop** (`done` line, then verifier result):

```bash
bash ~/.claude/skills/lib/plog.sh EXEC adversarial-review done "{PASS|WARNINGS|BLOCKED}"
```

### Post adversarial-review: Record verifier result (Phase 0 RLVR)
```bash
source ~/.claude/skills/lib/verifier-result.sh
write_verifier_result verifier=adversarial_review verdict=<PASS|WARN|BLOCK> criteria_met=<N> criteria_total=<M> attempt={ADV_ROUND} phase=EXEC
```
Map: PASS → PASS, WARNINGS → WARN, BLOCKED → BLOCK. `attempt` is `{ADV_ROUND}` from the round-awareness block above — not a fixed `1`.

**Gate on BLOCKED:** write the gate-stop **after** the `done` line above. Keep `ADVERSARIAL_BLOCKED` as the first word of the detail: `exit-path.sh`, `detect-resume.sh` and `adversarial-rounds.sh` all match it by prefix.

```bash
bash ~/.claude/skills/lib/plog.sh META gate-stop fail "ADVERSARIAL_BLOCKED — round {ADV_ROUND} — {ISSUE-ID} adversarial review found blocking issues"
```

Stop with non-zero exit so `ticket-auto` halts the pipeline. Tell the user:

```
⛔  ADVERSARIAL REVIEW — BLOCKED (round {ADV_ROUND})

The adversarial review for {TICKET-ID} found blocking issues.
See ## Adversarial Review in notes.md for details.

Fix the plan, then re-run /ticket-appraise-exec {TICKET-ID} --from-step create-artifact.
```

If `{ADV_ROUND}` ≥ 2, add this line to the message: `This plan has now been blocked {ADV_ROUND} times in a row. Before another detail pass, check whether the approach itself is the problem (see ### Approach review from round 3 on).` If the review contains `**Approach:** RECONSIDER`, quote its alternative in the message too.

If WARNINGS or PASS, proceed to Step 3.7 — do NOT skip ahead to Step 4; Steps 3.7 and 3.8 both apply in this same complex-ticket branch and still have to run first.

---

## Step 3.7 — Derive Verification Plan

bash ~/.claude/skills/lib/plog.sh EXEC verify-plan-derived start "Deriving verification plan"

**Only run this step if `{COMPLEXITY}` = complex.** If simple, skip to Step 3.8.

Derive a structured verification plan from the ticket and plan artifact. This step produces the `## Verification Plan` section in notes.md that tells `ticket-verify` exactly what to test, who tests it, and how to navigate there. If derivation fails, the ticket has insufficient information — push back before implementation.

Moved to `references/verification-plan.md` (inputs to read, derivation steps A–E for each criterion, and the push-back triggers with their gate-stop codes and the interactive override), read per the Step 3 condition. Then write the plan below.

### Write verification plan to notes.md

After derivation (full success or partial with override), append a `## Verification Plan` section to notes.md. If a `## Verification Plan` section already exists from a prior run, replace it.

```markdown
## Verification Plan
**Date:** {today}
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** {global | role-specific: {roles} | mixed}

### Role Scope Assessment

| Feature area | Affected roles | Scope type | Confidence | Basis |
|-------------|---------------|-----------|-----------|-------|
| {feature area} | {role list or "all"} | {global|role-specific} | {high|medium|low} | {explicit mention|code path|app-knowledge|heuristic} |

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | {criterion text} | {global|role: {roles}} | {URL path or menu path} | {none|{data description}} | {expected outcome} | {✓|✗} |
| 2 | ... | ... | ... | ... | ... | ... |
```

**Verifiable column:** `✓` if all four dimensions (role scope, nav path, expected behavior, test data) are populated. `✗` if any is missing — but note that missing dimensions trigger push-back above, so this should only appear in interactive override mode.

### Wiki ingestion — Role Scope Registry

After writing the verification plan, append role scope findings to `app-knowledge/SKILL.md` under a `## Role Scope Registry` section. This builds a cumulative knowledge base for future appraisals.

**Entry format:**
```markdown
### {TICKET-ID} — {feature area}
- **Role scope:** {global | role-specific: {roles}}
- **Confidence:** {high|medium|low}
- **Source:** verification plan derivation (ticket-appraise-exec Step 3.7)
- **Date:** {today}
```

**Section creation:** If `app-knowledge/SKILL.md` does not contain a `## Role Scope Registry` section, create it at the end of the file before appending the entry.

**Duplicate handling:** If a prior role scope entry exists for the same ticket ID (re-appraisal), strike through the old entry (`~~...~~`) and append the new entry below it.

**Non-blocking:** Wiki write failure is non-blocking. If `app-knowledge/SKILL.md` cannot be written (permissions, disk full), log a warning and continue:
```bash
bash ~/.claude/skills/lib/plog.sh EXEC verify-plan-derived skip "Wiki write failed: {reason} — continuing"
```

### Heartbeat

After derivation completes:
- **Success (all criteria verifiable):** `hb-wrap.sh gate "verify-plan-derived" "ok" "CLEAR" '{"criteria":"{N}","verifiable":"{M}"}'`
- **Partial with override (interactive only):** `hb-wrap.sh gate "verify-plan-derived" "ok" "OVERRIDE" '{"criteria":"{N}","verifiable":"{M}","override":"true"}'`
- **Push-back (any criterion unverifiable, auto mode):** `hb-wrap.sh gate "verify-plan-derived" "fail" "INSUFFICIENT_INFO" '{"criteria":"{N}","verifiable":"{M}"}'`

bash ~/.claude/skills/lib/plog.sh EXEC verify-plan-derived done "{CLEAR|INSUFFICIENT_INFO}"

Proceed to Step 3.8.

---

## Step 3.8 — Verification-Readiness Gate

bash ~/.claude/skills/lib/plog.sh EXEC verify-readiness start "Checking plan for verification prerequisites"

Check the plan artifact for 4 prerequisites required to verify the ticket:

1. **Test user** — an email, `**User:**` field, role mention, or actual test user from the test user catalog
2. **Navigation target** — a URL path (`/handover/`, `/admin/`), "Navigate to" instruction, or explicit menu path
3. **Expected behavior** — a description of what "working" looks like (from acceptance criteria or a `## Expected Behavior` section)
4. **Environment prerequisites** — any data setup, seed data references, or service dependencies needed before testing

### How to check

**Primary path — read the derived verification plan:**
If `{TICKET_DIR}/notes.md` contains a `## Verification Plan` section with a populated per-criterion table, extract the 4 prerequisites directly from the derived plan's table columns:
1. **Test user** — from the "Role scope" column (if role-specific, the named role is the test user)
2. **Navigation target** — from the "Navigation path" column
3. **Expected behavior** — from the "Expected behavior" column
4. **Environment prerequisites** — from the "Test data needed" column

If any column is empty or missing for a criterion, count that prerequisite as missing for that criterion. If all criteria have the prerequisite populated, count it as found.

**Fallback — scan the plan artifact directly:**
If no `## Verification Plan` section exists in notes.md (backward compat for old tickets), scan the plan artifact:
- If `{COMPLEXITY}` = simple: read `{TICKET_DIR}/simple-fix.md`
- If `{COMPLEXITY}` = complex: find the openspec change dir and read `design.md` and `tasks.md`

For each prerequisite, scan the artifact content:
1. **Test user**: look for an email pattern, `**User:**`, "as an [role]", "log in as", "test as", or a name matching the test user catalog (`test-users.json` — project-local, resolved via `resolve_test_user_catalog`). Also check if the `## Verification Readiness` section from notes.md already has one from a prior run.
2. **Navigation target**: look for URL paths, "Navigate to", "Go to", menu paths, or feature area labels that map to known nav-hints entries.
3. **Expected behavior**: look for acceptance criteria, `## Expected Behavior` sections, or descriptions of observable outcomes. If the artifact references the ticket's AC (e.g., "Verify AC-1: ..."), that counts.
4. **Environment prerequisites**: look for data setup steps, seed data references (`seed-db`, `data.sql`), service dependencies, or pre-existing state descriptions.

### Score

Count how many of the 4 prerequisites are missing:

| Missing | Status |
|---------|--------|
| 0 | CLEAR — all verification prerequisites present |
| 1 | WARNINGS — one prerequisite missing, still verifiable |
| 2+ | INCOMPLETE — too many gaps for reliable verification |

**Backward compat exception:** For tickets without structured plan sections (single-file simple-fix.md with minimal structure), a single missing flag produces WARNINGS, not INCOMPLETE. Only go to INCOMPLETE when 2+ are missing.

### Act on result

**If CLEAR or WARNINGS:**
Proceed to Step 4. Record in the heartbeat:
```
hb-wrap.sh gate "verify-readiness" "ok" "{CLEAR|WARNINGS}" "{\"missing\":\"{N}\"}"
```

**If INCOMPLETE:**

If `--from-auto` is in the arguments:
```bash
bash ~/.claude/skills/lib/plog.sh META gate-stop fail "VERIFY_READINESS_INCOMPLETE — plan missing {N} verification prerequisites: {list}"
```
Stop with non-zero exit.

If interactive (no `--from-auto`):
```
⚠️  VERIFICATION-READINESS — INCOMPLETE

The plan for {TICKET-ID} is missing {N} verification prerequisites:

{list of missing prerequisites}

Please update the plan artifact with these details, then re-run
/ticket-appraise-exec {TICKET-ID} --from-step create-artifact.
```

### Write results to notes.md

Append a `## Verification Readiness` section to notes.md:

```markdown
## Verification Readiness
**Date:** {today}
**Status:** {CLEAR | WARNINGS | INCOMPLETE}

| Prerequisite | Status | Source |
|-------------|--------|--------|
| Test user | {found | missing} | {where found or "not specified"} |
| Navigation target | {found | missing} | {where found or "not specified"} |
| Expected behavior | {found | missing} | {where found or "not specified"} |
| Environment prerequisites | {found | missing} | {where found or "not specified"} |
```

If the section already exists from a prior re-run, replace it.

bash ~/.claude/skills/lib/plog.sh EXEC verify-readiness done "{CLEAR|WARNINGS|INCOMPLETE}"

---

## Step 4 — Check for re-appraisal skip (after Step 3.8)

Read notes.md and look for a `## Re-appraisal` section. If it contains `**Changes detected:** no`, skip Steps 5 and 6 — no new comment or state change needed. Proceed directly to Step 7 (Report).

If no `## Re-appraisal` section exists (first run), or `**Changes detected:** yes`, continue to Step 5.

---

## Step 5 — Post a Linear comment

bash ~/.claude/skills/lib/plog.sh EXEC post-linear start "Posting appraisal comment"

Post a comment via the Linear access strategy (bash `save_comment` when `LINEAR_API_KEY` is set, MCP `save_comment` fallback otherwise) summarising the appraisal. Keep the `<!-- ticket-auto:appraisal -->` marker verbatim: gate reconcile finds the comment by it.

```
**Ticket appraised** — local workspace created. <!-- ticket-auto:appraisal -->

**Initial investigation:**
{2-4 bullets from Initial Investigation in notes.md}

**Open questions:**
{From notes.md Open Questions — or "None"}
{If any Open Questions bullet is tagged `[needs-human]`, append this line directly after the Open Questions block:}
⚠️ Answer the `[needs-human]` question(s) above in a comment before running `/ticket-approve` — approving without answering first will trigger an extra gate-reconcile hold cycle.

**Next step:**
{First concrete action from notes.md Next Steps}
```

If no Open Questions bullet is tagged `[needs-human]`, omit the warning line.

bash ~/.claude/skills/lib/plog.sh EXEC post-linear done "Comment posted"

---

## Step 6 — Set Linear state → Approve

Delegate to the flow executor:

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} appraise-complete
_rc=$?
# flow-run.sh has already logged any non-zero exit (META|flow-error + heartbeat).
# appraise-complete carries no verdict_gate, so exit 11 cannot occur; a failure is non-fatal — continue.
```

This sets state → `Approve`, keeping all existing labels.

---

## Step 7 — Report to the user

bash ~/.claude/skills/lib/plog.sh EXEC handoff start "Writing final report"

```
## {TICKET-ID} appraisal complete

**Local directory:** `{relative path from tickets root}`

**Complexity:** {simple | complex}

**Artifacts created:**
- {simple-fix.md | openspec change: <change-name>}

{If adversarial review ran:}
**Adversarial review:** {PASS | WARNINGS} — {N issues found, or "no issues"}
{If WARNINGS: see ## Adversarial Review in notes.md before implementing}

**Open questions:**
{bullets or "None"}

**Next step:** {first action}

Linear updated — assigned to you, status → Approve + `claimed` (awaiting approval).

> **Full state lifecycle:**
> Todo + `claimed` (appraise) → Approve + `claimed` (end of exec) → Ready, manifest `approved: true` (human approves via `/ticket-approve`) → Review (after PR) → Done

Run `/ticket-implement {TICKET-ID}` once `/ticket-approve {TICKET-ID}` has been run.
```

bash ~/.claude/skills/lib/plog.sh EXEC handoff done "Reported to user"
