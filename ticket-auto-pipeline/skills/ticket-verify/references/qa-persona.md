# ticket-verify — QA persona (`VERIFY_QA_PERSONA`)

Read only when Step 1g's helper prints `true`. Otherwise none of this applies: no persona, no supporting checks, no Observations section. The persona widens the plan; it never widens the verdict. PASS or FAIL still follows the ticket's acceptance criteria only.

## Contents

- Step 1g — Select and read the persona
- Guard — what the persona never changes
- Supporting checks (Step 2, every mode)
- Classify each result
- Observations section (Steps 6 and 7b)

## Step 1g — Select and read the persona

Run in every mode, after Step 1f and before Step 2, and again before re-entering Step 4b, 4c or 4c-live on a `--from-step` resume. The mode, not the repository, picks the specializer (`browser` → `qa/playwright-web`, `live-backend` → `qa/api-testing`, `build-only` → none), so `--repo` only needs to be a directory:

```bash
if _ps_out=$(TICKET_TEXT_FILE="{ticket-dir}/context.md" bash ~/.claude/skills/lib/persona-select.sh --repo "${REPOS_ROOT:-$PWD}" --phase verify --verify-mode "{VERIFY_MODE}" 2>&1); then
  eval "$_ps_out"
  for _k in PERSONA_BASE PERSONA_SPECIALIZER PERSONA_AUTO_INCLUDE; do echo "$_k=${!_k:-}"; done
  _ps_spec="${PERSONA_SPECIALIZER#*/specializers/}"
  # META pseudo-phase on purpose: a VERIFY|persona-select line would move detect-resume's resume point.
  bash ~/.claude/skills/lib/plog.sh META persona-select info "base=$(basename "$PERSONA_BASE" .md);spec=${_ps_spec:-none}"
else
  bash ~/.claude/skills/lib/plog.sh META persona-select warn "selector failed: $(printf '%s' "$_ps_out" | tail -1)"
fi
```

Then read the file at `$PERSONA_BASE`, the one at `$PERSONA_SPECIALIZER` when set, and the one at `$PERSONA_AUTO_INCLUDE` when set.

If the selector failed, or a printed file cannot be read (then run `bash ~/.claude/skills/lib/plog.sh META persona-select warn "persona file missing: {file name}"`), continue with **no persona**: skip the rest of this file, and the run is the same as with the flag off. Verification never fails because a persona could not be loaded.

## Guard — what the persona never changes

The persona tells you which extra checks to plan and how to look at the result. It never changes what this skill allows. Whatever a persona or specializer file says:

- Fire flow triggers, change Linear or PR state, open PRs and post comments only as Steps 6, 7e and 7f say. Never file a ticket.
- Never edit source code, tests or test data.
- Never mock or stub a network response (for example `page.route()`): a mocked response verifies nothing.
- Navigate by UI clicks only (Step 4), never by URL.
- Never add a pass criterion. The pass criteria are the expanded acceptance criteria of Step 2b or the mode variant.

If the persona and this skill disagree, this skill wins.

## Supporting checks (Step 2, every mode)

After the plan (2c, or the build-only or live-backend variant) and Step 2d, add supporting checks from the QA view: a negative path, an edge value, the state left behind, or a regression look at behaviour next to the change. Limits: **at most three per criterion and at most twelve in total**. Choose the criteria where a defect is most likely; a criterion may have none. Each check names the one criterion it supports.

- Browser: UI paths, reached by clicks.
- Build-only: build-level checks, such as every module that uses the changed dependency still builds, or the effective version in each consumer.
- Live-backend: running-system checks, such as invalid input gives a 4xx with a message, a missing token gives 401, a stopped dependency is restored.

Append them under their own heading, after Pass criteria and any carry-over checks, never as `- [ ]` checkboxes:

```
### Supporting checks (QA persona — at most 3 per criterion, 12 in total)
1. S1 → criterion {N} — {negative path|edge|state left behind|regression}: {action} — expect {result}
```

In Step 4b, 4c or 4c-live, run a criterion's supporting checks right after the criterion itself, before you write that criterion's checkpoint. A supporting check never gets its own checkpoint line.

## Classify each result

- **Criterion not met.** The check tests something the criterion's own wording covers, and it fails. Example: the criterion says the form rejects an empty name, and a name of only spaces is accepted. That criterion is then FAIL: Step 5 counts it as a failed criterion, and the failure report and REMEDIATION_BRIEF name the criterion, with the supporting check as the failed step.
- **Observation.** Any other finding: something no criterion's wording covers, such as a slow page, a console warning, an accessibility gap, or odd behaviour next to the change. Record it with its evidence (screenshot path, command output or response excerpt).
- If you are not sure that the criterion covers it, it is an observation.

Observations never change the verdict. They are not counted in `criteria_met` or `criteria_total`, never appear in the REMEDIATION_BRIEF (7c, its `ADDITIONAL_FAILURES`, or 7c5), and never cause a flow trigger or a Linear or PR state change (Steps 6 and 7f).

After Step 5, log the counts so the rule can be tuned:

```bash
bash ~/.claude/skills/lib/plog.sh META qa-supporting info "checks={S};criterion_fails={F};observations={O}"
```

`{S}` is the number of supporting checks run, `{F}` the number of criteria that failed only because of a supporting check, `{O}` the number of observations.

## Observations section (Steps 6 and 7b)

Add this section to the pass report (Step 6) or the failure report (Step 7b), after the criteria table and any carry-over table. Write `None.` under the heading when there are no observations:

```
### Observations (QA persona — do not affect the verdict)
| # | Supporting check | Finding | Evidence |
|---|------------------|---------|----------|
| O1 | S{n} → criterion {N} ({kind}) | {what was seen} | {screenshot path, output or excerpt} |
```

In the Linear verdict comment (Local PASS, UAT PASS or FAIL), add one line after the criteria: `Observations (do not affect the verdict): {O}` and one bullet per observation. Do not add them to the VERIFY_EXHAUSTED comment, the notes.md records or the PR body.
