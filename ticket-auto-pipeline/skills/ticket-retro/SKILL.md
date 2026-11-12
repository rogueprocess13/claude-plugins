---
name: ticket-retro
description: Post-pipeline retrospection — aggregates pipeline log failures and produces a dated proposal with unified diffs for skill-file fixes. Use when the user says "/ticket-retro", "/ticket-retro --window 7d", "run retro", or "retrospect the pipeline".
---

# Ticket Retro — Pipeline Retrospection & Fix Proposals

You are the `/ticket-retro` skill. Your job is to aggregate pipeline log failures, classify patterns, propose minimal diffs for implicated skill files, and write a dated proposal report. You NEVER modify skill files directly — you only write to `~/.claude/state/ticket-retro/proposals/`.

## Invocation

```
/ticket-retro [--window Nd] [--post-to-linear] [--post-to-github] [--force]
```

- `--window Nd`: days of log history to scan (default: `7d`)
- `--post-to-linear`: if present, post a summary comment to the Linear retro issue configured in `RETRO_LINEAR_ISSUE`
- `--post-to-github`: if present, auto-create GitHub issues for recurring failure patterns (count ≥ 2) with severity labels
- `--force`: re-scan all logs even if unchanged since last retro (bypasses the cursor deduplication)

## Guard — Ensure state directory

```bash
mkdir -p ~/.claude/state/ticket-retro/proposals
```

This is user state, not skill-bundle state. It survives plugin upgrades.

---

## Step 1 — Aggregate logs via retro.sh

Invoke `retro.sh` with the window flag (add `--force` to bypass cursor-based deduplication). It saves the JSON in the private scratch dir; note the printed `RETRO_JSON` path for Step 4:

```bash
R="$(bash ~/.claude/skills/lib/ticket-tmp.sh)/retro.json" && bash ~/.claude/skills/ticket-retro/retro.sh --window {WINDOW} >"$R" && cat "$R" && echo "RETRO_JSON=$R"
```

`retro.sh` maintains a cursor file at `~/.claude/state/ticket-retro/retro-cursor.json` that records the last-scanned mtime for each log. On subsequent runs, logs whose mtime hasn't changed are skipped. This prevents re-reporting failures from logs that were already analyzed in a prior retro run. Use `--force` to re-scan all logs regardless.

If `retro.sh` exits non-zero, report the stderr message and stop — no logs were found in the window.

Parse the JSON output into the following variables:
- `{FAILURE_HISTOGRAM}` — object, keyed by error code, values are counts
- `{GATE_STOP_TOTAL}` — total gate-stop events
- `{GATE_WARN_TOTAL}` — total gate-warn events (e.g. `RETURN_INCOMPLETE` in Phase 1 warn-only mode); tracked separately since these never halt the pipeline — used to measure false-positive rate before a warn-only gate flips to enforce
- `{COMPLEXITY_PREDICTIONS}` — array of `{ticket, declared, actual, actual_source}`
- `{COMPLEXITY_CALIBRATION}` — the `complexity_calibration` object (complexity-classifier-calibration; replaced `complexity_accuracy` and its companion fields). Computed over **every** ticket-auto log in the window — deliberately independent of the failure-dedup cursor ([#367](https://github.com/willard-pro/claude-plugins/issues/367): RETRO_CURSOR_METRIC_SKEW). Fields:
  - `matrix` — `{simple: {Smooth, Rough, Hard}, complex: {Smooth, Rough, Hard}}` counts.
  - `false_simple_rate` — `(simple×Rough + simple×Hard) / simple row`, a value to **minimise**. Read from the `declared=simple` row only. `null` when `suppressed`.
  - `simple_row_n`, `min_n`, `suppressed` — the simple row's size, the floor (default `3`, override via `COMPLEXITY_CALIBRATION_MIN_N`), and whether the rate was withheld for being below it. Always report `simple_row_n` alongside the rate.
  - `false_simple_tickets` — `[{ticket, outcome}]` for every `declared=simple` ticket that went `Rough`/`Hard`. The actionable list: each one skipped the human gate and the delegated investigation.
  - `unscoreable` — `{missing_declared, missing_outcome}`: logs missing one half of the pair, counted rather than dropped so a shrinking denominator stays visible.
  - `confounded_rows` / `confounded_reason` — `["declared=complex"]` and why. A `complex` classification changes the treatment (delegated investigation, openspec plan, human gate), so `complex`+`Smooth` may be the treatment working. **Never compute an overall accuracy from the matrix, and never report `complex`+`Smooth` as a misprediction.**
- `{LOGS_SCANNED}`, `{LOGS_SKIPPED}`, `{LOGS_WITH_FAILURES}` — counts. `LOGS_SCANNED` counts only newly-scanned logs (not cursor-skipped). `LOGS_SKIPPED` counts logs that were skipped because their mtime matched the cursor. This cursor dedup applies to the failure histogram only — it does not gate `{COMPLEXITY_CALIBRATION}` (see above).
- `{LOGS_BY_SOURCE}` — object `{"ticket-auto": {scanned, skipped, with_failures}, "planner": {scanned, skipped, with_failures}}`. `ticket-auto` scans `./logs/*-pipeline.log`; `planner` scans `${REPOS_ROOT}/.ticket-auto/initiatives/*/state.log` ([#177](https://github.com/willard-pro/claude-plugins/issues/177)). Both sources feed the same `{FAILURE_HISTOGRAM}` — this field is purely for reporting where each count came from. `planner` counts are `0` when `REPOS_ROOT` is unset or no initiatives exist; nothing else about ticket-auto scanning changes in that case.
- `{ERROR_DIAGNOSTICS}` — object with `total_errors`, `errors_by_ticket`, `error_category_histogram` (from heartbeat structured error events)
- `{FAILURE_CONTEXT}` — `failure_context`, `{CODE: [{ticket, errors, transcripts}]}`: who produced each code (single-occurrence notes name it)

---

## Step 1.6 — Complexity calibration corrections

`{COMPLEXITY_CALIBRATION}` names the false-simples but not *why* a prediction missed.
`ticket-implement` Step 4c writes that gap as a `source=appraise` (complexity sweep) or
`source=exec` (plan artifact) CORRECTIONS block in the ticket's notes.md; it is scoring feedback
for `ticket-appraise`, so it surfaces here, not in the wiki (`wiki-maintenance` Step 2.6 skips
`source=appraise`). Step 4's `--render-sections` reads those blocks itself
(`retro_calibration_notes` in `retro.sh`) for every false-simple, and for each `declared=complex`
`actual=Smooth` ticket as confounded context only — never an argument for loosening the
classifier. It runs whether or not the window had failures; a ticket dir it cannot resolve from
the tickets root is skipped.

---

If `{FAILURE_HISTOGRAM}` is empty (no failures), skip to Step 4 to write a short "clean window" report.

---

## Step 1.5 — Scan Claude log for failure signals and improvement hints

Scan `$CLAUDE_LOG_FILE` (if set and present) for failure signals, `★ Insight` blocks and
`RETRO|hint` entries. Note the printed `RETRO_TMP` (private scratch dir) as `{RETRO_TMP}` for
Steps 4 and 5.5:

```bash
bash ~/.claude/skills/ticket-retro/retro.sh --claude-scan
```

It writes `claude-log-{failures,insights,hints,correlated}.txt` there (read them for Step 3
context) and prints `claude-log-scan: done` or `skipped` (no log: all Claude log sections are
omitted from the proposal).

---

## Step 2 — Load prior proposal context

Check for a prior proposal to avoid re-proposing already-submitted fixes:

```bash
ls -t ~/.claude/state/ticket-retro/proposals/*-retro.md 2>/dev/null | head -1
```

If a file exists, read it and extract:
- The failure codes that already had diffs proposed (look for `### <CODE>` subsections under "Pattern Analysis")
- Any "previously proposed — verify if applied" annotations

Store as `{PRIOR_PROPOSAL_CONTEXT}` — used in Step 3 to annotate repeated proposals.

---

## Step 3 — Generate per-failure-class diff proposals

For each failure code in `{FAILURE_HISTOGRAM}` where count ≥ 2:

### 3a — Load the template

```bash
TEMPLATE="~/.claude/skills/ticket-retro/templates/{CODE}.md"
```

If the template file exists, read it. If not, use the generic fallback: "Investigate the skill file that produces or handles `{CODE}` events. Look for the log-write site and the decision logic that leads to this failure."

### 3a.5 — Extract heartbeat error context for this failure code

`{FAILURE_CONTEXT}[CODE]` lists each ticket (planner: initiative) behind this code, with its heartbeat `errors` (catalogue: `retro.sh` header) and existing `transcripts`. Never guess tickets. Store it as `{ERROR_CONTEXT}` for 3b/3c; cite transcripts in Step 4 by path only, never grep them.

### 3b — Read the implicated skill file

The template identifies which skill file(s) to inspect. Read the relevant sections of that skill file. For gate-stop codes the mapping is:

| Code | Primary Skill File |
|------|-------------------|
| `EXEC_NO_ARTIFACT` | `ticket-appraise-exec/SKILL.md` |
| `COMPLEXITY_ARTIFACT_MISMATCH` | `ticket-appraise-exec/SKILL.md` |
| `APPROVAL_REVOKED` | `ticket-auto/SKILL.md` (Step 5d), `ticket-pr-iterate/SKILL.md` |
| `REMEDIATION_BRIEF_TRUNCATED` | `ticket-verify/SKILL.md`, `ticket-implement/SKILL.md` |
| `PR_REVIEW_VERDICT_UNPARSEABLE` | `ticket-pr-review/SKILL.md` |
| `RETURN_INCOMPLETE` | `ticket-auto/SKILL.md` (STEP_4), `lib/return-completeness-check.sh` |

For the `complexity-drift` meta-code (`{COMPLEXITY_CALIBRATION}.false_simple_tickets` non-empty and `suppressed` is `false`): inspect `ticket-appraise/SKILL.md` Step 2.5 and `lib/appraise-fast-path.sh` — see `templates/complexity-drift.md`. Never raise it from `complex`+`Smooth` counts.

**Planner Crosscheck findings** (`{FAILURE_HISTOGRAM}` entries surfaced from a `ticket-planner`-sourced log, [#177](https://github.com/willard-pro/claude-plugins/issues/177)): these are findings about the planner's own artifacts, so the implicated file is always in the **`ticket-planner`** plugin — never a `ticket-auto-pipeline` skill file, even though this SKILL.md lives in `ticket-auto-pipeline`.

| Code | Primary File (in `ticket-planner`) |
|------|-------------------|
| `CITATION_UNRESOLVED` | `lib/planner-crosscheck-citations.sh`; root cause usually traces to the Specify prompt in `lib/planner-phase-prompts.sh` (`planner_prompt_specify`) |
| `CITATION_LINE_OUT_OF_RANGE` | `lib/planner-crosscheck-citations.sh`; root cause usually traces to `lib/planner-phase-prompts.sh` (`planner_prompt_specify`) |
| `CITATION_SYMBOL_MISMATCH` | `lib/planner-crosscheck-citations.sh`; root cause usually traces to `lib/planner-phase-prompts.sh` (`planner_prompt_specify`) |
| `RESOLUTION_NOT_PROPAGATED` | `lib/planner-crosscheck-propagation.sh`; root cause usually traces to `lib/planner-phase-prompts.sh` (`planner_prompt_consensus`) |
| `FORWARD_REF_UNFULFILLED` | `lib/planner-crosscheck-propagation.sh`; root cause usually traces to `lib/planner-phase-prompts.sh` (`planner_prompt_specify`) |
| `CARVE_SCOPE_LOST` | `lib/planner-crosscheck-propagation.sh`; root cause usually traces to `lib/planner-phase-prompts.sh` (`planner_prompt_specify`) |

Every diff proposed for one of these codes must target a `ticket-planner/...` path, not a `ticket-auto-pipeline/skills/...` one.

### 3b.5 — GitHub severity mapping (for --post-to-github)

When `--post-to-github` is active, `github_retro_map_severity()` in `lib/github-issue-retro.sh` maps each failure code to its `{type},{severity}` label string (e.g. `bug,P0`); its case statement is the only mapping.

### 3c — Generate a unified diff

Produce a minimal unified diff that would fix the recurring failure. The diff should:
- Target the specific section of the skill file where the failure originates
- Be minimal — one focused change, not a rewrite
- Be presented in a fenced `diff` code block
- Where `{ERROR_CONTEXT}` provides structured detail (e.g. `error_snippet`, `error_type`, `exit_code`), use those specific values to inform the proposed fix rather than making assumptions about the root cause

If the same diff was proposed in `{PRIOR_PROPOSAL_CONTEXT}`, note "Previously proposed on {date} — verify if applied" instead of repeating the full diff.

Collect all diffs into `{ALL_DIFFS}` for Step 4.

---

## Step 4 — Write the proposal

Write `~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md` with these sections in order:

### Sections: Failure Histogram through Agent Improvement Hints

These five sections are rendered, not written by hand. Start the proposal with the output of:

```bash
bash ~/.claude/skills/ticket-retro/retro.sh --render-sections "{RETRO_JSON}" --scan-dir "{RETRO_TMP}" --tickets-root .
```

It prints, in order: **Failure Histogram** (codes by count, plus the per-source line when planner
logs were in play); **Complexity Calibration** (the declared × outcome matrix, the false-simple
rate from the `declared=simple` row only with its `n` — or `suppressed` below the floor — the
named false-simples and unscoreable counts; the complex row is marked confounded and never
scored); **Complexity Calibration Notes** (Step 1.6, omitted when empty); and, only when the
Step 1.5 scan ran, **Claude Log Failures** and **Agent Improvement Hints**. Never compute an
overall accuracy from the matrix, and never report `complex`+`Smooth` as a misprediction.

### Section: Pattern Analysis

One subsection per failure code with count ≥ 2:

```markdown
## Pattern Analysis

### EXEC_NO_ARTIFACT (4 occurrences)

**Pattern:** <description from template>

**Implicated:** `ticket-appraise-exec/SKILL.md`

**Diagnostic context** (from heartbeat error events, if available):
- Event: `<event name>` — `<message>`
- Detail: `<key: value>` pairs from DETAIL JSON (e.g. `expected: ./tickets/ABC-47--slug/simple-fix.md`, `artifact_type: simple-fix`)
- (If no heartbeat error events for this failure code: "No structured diagnostic data — error capture may predate this run.")

**Transcript** (for manual investigation, if available):
`./logs/{TICKET-ID}-{phase}-agent.log`

**Proposed fix:**

` ``diff
--- a/skills/ticket-appraise-exec/SKILL.md
+++ b/skills/ticket-appraise-exec/SKILL.md
@@ -X,Y +X,Y @@
 ...
` ``

### APPROVAL_REVOKED (2 occurrences)

...
```

If a diff was previously proposed (from Step 2 context), add: `> ⚠️ Previously proposed on {date} — verify if applied.`

### Section: Single-occurrence Notes

Brief notes on codes that appeared exactly once:

```markdown
## Single-occurrence Notes

- **PR_REVIEW_VERDICT_UNPARSEABLE** (1 occurrence, ABC-49): isolated incident — monitor in next window before proposing a diff.
```

### Section: Apply Instructions

```markdown
## Apply Instructions

To apply all proposed diffs:

` ``bash
cd ~/.claude/skills
git apply < ~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md
` ``

Review each diff before applying. The `--reject` flag saves rejected hunks as `*.rej` files for manual resolution.
```

If no diffs were proposed (empty Pattern Analysis):

```markdown
## Apply Instructions

No diffs proposed — review single-occurrence notes above. Re-run with a wider window (`--window 30d`) if patterns haven't emerged yet.
```

### Section: GitHub Issues (if --post-to-github)

Only with `--post-to-github`: run `bash ~/.claude/skills/lib/skill-ref.sh ticket-retro references/github-issues.md`, read the printed path in full and follow it for this section and Step 5.5. Without the flag, omit this section and skip Step 5.5. If `skill-ref.sh` exits non-zero, warn and skip all GitHub operations (the proposal is still written): never post issues from memory.

**Proposal verify** — confirm the file was written before reporting success:

```bash
_proposal_file="$HOME/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md"
if [ ! -f "$_proposal_file" ]; then
  echo "retro: proposal file not written at ${_proposal_file}" >&2
  exit 1
fi
```

If missing, stop — do not proceed to Step 5 or report the retro as complete.

---

## Step 5 — Post to Linear (if --post-to-linear)

If `--post-to-linear` is present:

Check `RETRO_LINEAR_ISSUE`:
```bash
if [ -z "$RETRO_LINEAR_ISSUE" ]; then
  echo "WARN: RETRO_LINEAR_ISSUE not set — skipping Linear post"
else
  # Post a summary comment
fi
```

If set, run the summary body through the `simple-english` skill (embedded mode, Plain) before posting, then post it to that Linear issue using `mcp__linear-server__save_comment`:

```markdown
## Retro — {YYYY-MM-DD} (window: {WINDOW})

**Logs scanned:** {LOGS_SCANNED} | **With failures:** {LOGS_WITH_FAILURES}

### Failure Histogram
| Code | Count |
|------|-------|
...

### False-simple rate: {false_simple_rate} (n={simple_row_n}) — {count} false-simple(s)

Full proposal: `~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md`
```

When `{COMPLEXITY_CALIBRATION}.suppressed` is `true`, render that line as
`### False-simple rate: suppressed (n={simple_row_n}, floor={min_n}) — {count} false-simple(s)` instead.

If `RETRO_LINEAR_ISSUE` is unset, log the warning and skip — the proposal is still written.

---

## Step 5.5 — Post to GitHub (if --post-to-github)

Moved to `references/github-issues.md` (5.5a–5.5d), read per the Step 4 GitHub Issues condition.

---

## Completion

**G1 — RLVR Phase 0**: Before reporting, record the retro verdict as a verifier-result:
```bash
source ~/.claude/skills/lib/verifier-result.sh
write_verifier_result \
  verifier=ticket_retro verdict=<PASS|WARN|FAIL> \
  criteria_met=<fixes-found> criteria_total=<failure-classes> \
  phase=MAINTENANCE
```
Choose verdict: PASS if no failure classes found, WARN if failures found but diffs generated, FAIL if diffs could not be generated for critical classes.

Report to the user:

```
## Ticket Retro Complete

**Window:** {WINDOW}
**Logs scanned:** {LOGS_SCANNED}
**Logs with failures:** {LOGS_WITH_FAILURES}
**Gate-stop events:** {GATE_STOP_TOTAL}
**Gate-warn events:** {GATE_WARN_TOTAL}
**False-simple rate:** {false_simple_rate | suppressed} (n={simple_row_n}, lower is better)

**Proposal written:** ~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md
{Diff count} diff proposals generated.
{GitHub summary line}

Apply with:
  cd ~/.claude/skills && git apply < ~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md
```

The `{GitHub summary line}` is:
- If `--post-to-github` was used and succeeded: `**GitHub issues:** {GITHUB_CREATED} created, {GITHUB_UPDATED} updated`
- If `--post-to-github` was used but auth failed: `**GitHub issues:** skipped — gh not authenticated`
- If `--post-to-github` was not used: omitted entirely
