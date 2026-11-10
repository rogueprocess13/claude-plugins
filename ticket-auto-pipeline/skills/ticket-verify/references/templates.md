# ticket-verify — report and comment templates

Read only under the condition in SKILL.md Step 5 ("Report templates"), before the Step 6 pass report or the Step 7b failure report. Each section names the SKILL.md step that uses it. The REMEDIATION_BRIEF (7c), the notes.md records, the PR body and the plan-artifact `## Verification #` section stay in SKILL.md.

## Contents

- Pass report — Step 6, printed to the user
- Local PASS comment — Step 6, `--env local`, item 6
- UAT BLOCKED comment — Step 6, `--env uat`, `_rc` 11
- UAT PASS comment — Step 6, `--env uat`, otherwise
- Failure report — Step 7b, printed to the user
- VERIFY_EXHAUSTED comment — Step 7d
- FAIL comment — Step 7e

---

## Pass report

```
## ✅ {TICKET-ID} — VERIFIED PASS

**Ticket:** {Linear URL}
**Environment:** {env} ({base URL})
**Tested as:** {--user}

### Criteria
| Criterion | Result |
|---|---|
| {criterion} | ✅ Pass |

### Carry-over checks (do not affect the verdict)
| Check | Result |
|---|---|
| carry-over — {behaviour} | ✅ Pass / ❌ Fail — {what was observed} |

### Evidence
- Step {N}: {brief description of what was observed confirming the fix}
- Screenshots: {ticket-dir}/artifacts/verify-{TICKET-ID}-c{N}-pass.png, … (browser mode; none in build-only/live-backend mode)

**Recommendation:** Ready to merge / promote.
```

## Local PASS comment

```
✅ ticket-verify PASS — local

**Tested as:** {--user}
**Date:** {today}

| Criterion | Result |
|---|---|
| {criterion} | ✅ Pass |

All acceptance criteria confirmed. PR {URL} opened against $BASE_BRANCH.
```

## UAT BLOCKED comment

```
⏸️ ticket-verify PASS, but Done transition BLOCKED — uat

**Tested as:** {--user}
**Date:** {today}

| Criterion | Result |
|---|---|
| {criterion} | ✅ Pass |

All acceptance criteria confirmed — this run's own verification passed. The ticket could
**not** move to Done: `flow.sh` found a trailing FAIL/BLOCK verifier-result still on record
for a different check on this ticket, with no later PASS/WARN superseding it
(`VERDICT_FAIL_NOT_ENFORCED` guard, issue #368). A human needs to review the other check's
failure and either fix it (a later PASS clears the block automatically) or re-run
`/ticket-flow {TICKET-ID} uat-pass --override <reason>` once satisfied it's safe to close.
```

## UAT PASS comment

```
✅ ticket-verify PASS — uat

**Tested as:** {--user}
**Date:** {today}

| Criterion | Result |
|---|---|
| {criterion} | ✅ Pass |

All acceptance criteria confirmed. Ticket moved to Done.
```

## Failure report

```
## ❌ {TICKET-ID} — VERIFICATION FAILED

**Ticket:** {Linear URL}
**Environment:** {env} ({base URL})
**Tested as:** {--user}
**Failed at step:** {N} — {step description}

### Criteria result
| Criterion | Result |
|---|---|
| {passing criterion} | ✅ Pass |
| {failing criterion} | ❌ FAIL |

### Carry-over checks (do not affect the verdict)
| Check | Result |
|---|---|
| carry-over — {behaviour} | ✅ Pass / ❌ Fail — {what was observed} |

### What happened
**Expected:** {expected behaviour from pass criterion}
**Observed:** {what was actually seen — quote element labels and states verbatim}

### Diagnostics
**URL at failure:** {url}
**Screenshot at failure:** {ticket-dir}/artifacts/verify-{TICKET-ID}-c{N}-fail.png (browser mode)
**Console errors:**
{list, or "none"}

**Snapshot at failure (relevant excerpt):**
{10–20 most relevant lines of the accessibility tree YAML, focused on the component under test}
```

## VERIFY_EXHAUSTED comment

```
❌ Verify exhausted — {PASSED_N}/{TOTAL_N} criteria passed after 2 attempts

**Passed criteria:**
{list of passing criteria, or "none"}

**Failed criteria:**
{list of failing criteria with brief reason for each}

**Last failure diagnostics:**
- Failed at step: {N} — {description}
- URL at failure: {url}
- Console errors: {count or "none"}
- Tested as: {user} on {env}
- Date: {today}

The REMEDIATION_BRIEF below contains structured fix guidance for /ticket-implement.
```

## FAIL comment

```
❌ ticket-verify FAIL — {env}

**Tested as:** {--user}
**Date:** {today}
**Failed at step:** {N} — {step description}

| Criterion | Result |
|---|---|
| {passing criterion} | ✅ Pass |
| {failing criterion} | ❌ FAIL |

**Expected:** {expected behaviour}
**Observed:** {observed behaviour — verbatim element labels/states}

**Console errors:** {list or "none"}
```
