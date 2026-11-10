# ticket-implement — verify rework

Read only under the condition in SKILL.md "Reference files (load condition)": a rework entry, where Step 2.5 finds more `### {date} — Verification FAIL` entries in notes.md than `## Verification #` sections in the plan, or a `--from-step` resume while a rework is open. The counts and the branch that sends you here stay in SKILL.md Step 2.5.

## Contents

- Step 2.5 — integrity check and failure processing
- Part B — Extract REMEDIATION_BRIEF from the Verification section

## Step 2.5 — integrity check and failure processing

Before reading the section, assert the closing marker:

**REMEDIATION_BRIEF integrity check** (`PLAN` from the Step 2.5 call):
```bash
bash ~/.claude/skills/lib/remediation-check.sh integrity "{TICKET-ID}" --plan "{PLAN}"
```
Exit 1 means the last `## Verification #` section does not end with `<!-- /REMEDIATION_BRIEF -->` and `META|gate-stop|fail|REMEDIATION_BRIEF_TRUNCATED — marker missing in: {PLAN}` is logged. Stop. Report: `{TICKET-ID} pipeline halted: REMEDIATION_BRIEF closing marker missing in {PLAN}. The verify step may have been interrupted mid-write. Re-run ticket-verify to regenerate the brief.`

On marker present proceed to process the failures:
1. Count existing `## Verification #` sections in the plan to determine N (0 if none)
2. Extract from notes.md: env, failed step, expected, observed, console errors
3. Append to the plan artifact (`simple-fix.md` or `openspec tasks.md`):

```markdown
## Verification #{N+1}

**Date:** {date from notes.md}
**Environment:** {env}
**Failed at step:** {N} — {step description}

### Gaps
| # | Expected | Observed |
|---|----------|----------|
| 1 | {expected} | {observed} |

### Diagnostics
**Console errors:** {count or "none"}
```

4. Append to `notes.md`:
```markdown
### {today's date} — verification re-run #{N+1}
- Addressing verification failures from {date}. Plan updated.
```

When implementing, the `## Verification #N` section is treated the same as `## PR Review #N` — each gap must be resolved before the implementation round is complete.

### Part B — Extract REMEDIATION_BRIEF from the Verification section

After appending the Gaps table, read the `## Verification #{N+1}` section from the plan artifact. If additional REMEDIATION_BRIEF fields are present (written by `ticket-verify` Step 7c5), extract them into the implementation context.

**Debugger overlay for the rework.** A verify FAIL is a defect whatever the ticket type, so re-run the selector with `--remediation` (same prefix, repo and layer as Step 2; add `--type {PERSONA_TYPE}` only if Step 2 printed a non-empty one) and keep only the two debug keys — Step 2's base, specializer and other overlays stay as they were:
```bash
eval "$(TICKET_TEXT_FILE="{ticket-dir}/context.md" bash ~/.claude/skills/lib/persona-select.sh --repo <repo> --layer <FE|BE> --phase implement --remediation | grep '^PERSONA_DEBUG')"
echo "PERSONA_DEBUG=${PERSONA_DEBUG:-}"; echo "PERSONA_DEBUG_SPECIALIZER=${PERSONA_DEBUG_SPECIALIZER:-}"
```
Read `$PERSONA_DEBUG` and, when set, `$PERSONA_DEBUG_SPECIALIZER`. The `## PR Review #N` rework path never passes `--remediation`: a PR-review gap is a review finding, not a runtime failure.

**Rework rule — this is the last rework before `VERIFY_EXHAUSTED`.** The router caps verify at 2 attempts, so this rework runs once; a failed attempt 2 ends the pipeline. It applies in gaps-only mode too:
1. Treat the Suggested Fix (or, in gaps-only mode, your own reading of the gaps) as a **hypothesis**, not an instruction.
2. Confirm it with evidence: reproduce the failing criterion, then trace from the console error or failed step back to the source line that causes it. Write down "X because Y" with the file:line that shows it.
3. Write a failing test that reproduces the verify failure **before** editing any code.
4. Make one change. Run the failing test, then the full suite.
5. If the evidence disproves the hypothesis, or the failing test cannot be made to pass with one change, do not stack a second patch. Append to `notes.md` a `### {today's date} — rework hold: why attempt 1 failed` entry (what attempt 1 assumed, what the evidence showed, what is still unknown), then emit the `=== HUMAN_HOLD ===` block from the preamble § 7 with `REASON: SCOPE_UNDEFINED`, `BLOCKS: {plan path}#Verification #{N+1}`, and a question stating the disproved hypothesis and the decision you need.

Parse these headings from the `## Verification #{N+1}` section:

| Heading in plan | Source |
|-----------------|--------|
| `### Suggested Fix` | SUGGESTED_FIX — verifier's hypothesis about root cause |
| `### Expected` | WHAT_WAS_EXPECTED |
| `### Observed` | WHAT_FAILED |
| `### Diagnostics` | CURRENT_URL, CONSOLE_ERRORS, SNAPSHOT_EXCERPT |
| `### Context Files` | CONTEXT_FILES |

**If the section contains only a Gaps table** (pre-Change-2 format): the richer context is not available. Proceed with gaps-only mode as before.

**If REMEDIATION_BRIEF fields are present**, emit this context block:

```
## UAT Rework Context — {TICKET-ID}

**Suggested Fix (from ticket-verify):**
{SUGGESTED_FIX}

**What was expected:**
{WHAT_WAS_EXPECTED}

**What failed:**
{WHAT_FAILED}

**Console errors:** {CONSOLE_ERRORS}
**URL at failure:** {CURRENT_URL}

**Context files:** {CONTEXT_FILES}

This is the last rework before VERIFY_EXHAUSTED. The Suggested Fix is a hypothesis: confirm it
with evidence, write a failing test that reproduces the verify failure before editing, make one
change. If the hypothesis is disproved or the test cannot pass, record why attempt 1 failed and
emit === HUMAN_HOLD === instead of a second patch. Cross-reference with the original plan and any
PR Review gaps.
```

The SUGGESTED_FIX is the verifier's hypothesis about the root cause — a starting point for the investigation in the rework rule above, not a fix to apply unchecked. The `## Verification #N` gaps must still be resolved alongside any `## PR Review #N` gaps. These are treated identically — each must be addressed before the implementation round is complete.
