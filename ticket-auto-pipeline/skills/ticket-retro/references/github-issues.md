# ticket-retro — GitHub Issues (`--post-to-github` only)

Read only when `/ticket-retro` runs with `--post-to-github`, per the condition in SKILL.md Step 4 (Section: GitHub Issues). A run without the flag reads neither part.

## Contents

- Step 4 — Section: GitHub Issues (the proposal subsection)
- Step 5.5 — Post to GitHub (5.5a auth, 5.5b issue files, 5.5c state machine, 5.5d report)

## Step 4 — Section: GitHub Issues

If `--post-to-github` was used and GitHub operations completed, include this section:

```markdown
## GitHub Issues

| Failure Code | Action | Issue |
|-------------|--------|-------|
| EXEC_NO_ARTIFACT | Created | [willard-pro/claude-plugins#99](https://github.com/willard-pro/claude-plugins/issues/99) |
| APPROVAL_REVOKED | Updated | [willard-pro/claude-plugins#85](https://github.com/willard-pro/claude-plugins/issues/85) |
```

If no failure codes met the count ≥ 2 threshold:
```markdown
## GitHub Issues

No new issues — all failure codes below the count ≥ 2 threshold.
```

If `--post-to-github` was used but auth failed:
```markdown
## GitHub Issues

GitHub posting skipped — `gh` CLI not authenticated. Run `gh auth login` and re-run retro with `--post-to-github`.
```

## Step 5.5 — Post to GitHub

If `--post-to-github` is present:

### 5.5a — Auth and library check

`retro.sh --github-post` (5.5c) sources `lib/github-issues.sh` and checks `gh` auth itself. When
either fails it prints `GITHUB_STATUS=skipped-lib` or `skipped-auth`, posts nothing, and the
proposal is still written.

### 5.5b — Generate issue body and comment files

For each failure code in `{FAILURE_HISTOGRAM}` where count ≥ 2:

1. **Map severity** using the table in Step 3b.5 (the authoritative mapping is the bash `github_retro_map_severity` function — the table is documentation)

2. **Fill the issue body template** (`lib/github-issue-body.template.md`) with placeholders from the pattern analysis in Step 3:
   - `{FAILURE_CODE}`, `{PATTERN_SUMMARY}`, `{PATTERN_DESCRIPTION}`, `{EXPECTED_BEHAVIOR}`, `{STEPS}`, `{ROOT_CAUSE}`, `{FILES}`, `{FIX_APPROACH}`, `{CONSTRAINTS}`, `{VERIFICATION_CHECKLIST}`, `{RELATED}`, `{WINDOW}`, `{COUNT}`
   - Write the filled body to a temp file: `{RETRO_TMP}/issue-body-{CODE}.md`

3. **Prepare the evidence comment** (used if an existing open issue is found):
   ```markdown
   ## New evidence — window: {WINDOW}, occurrences: {COUNT}
   
   **Date:** {YYYY-MM-DD}
   
   Additional occurrence(s) of this failure pattern detected in the current retro window.
   See proposal at `~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md` for updated analysis.
   ```
   - Write to a temp file: `{RETRO_TMP}/evidence-{CODE}.md`

4. **Build the input JSON** for `github_retro_process`:
   ```json
   {
     "codes": {
       "EXEC_NO_ARTIFACT": {
         "count": 4,
         "title": "Fix EXEC_NO_ARTIFACT — artifact not found after exec phase",
         "body_file": "{RETRO_TMP}/issue-body-EXEC_NO_ARTIFACT.md",
         "comment_file": "{RETRO_TMP}/evidence-EXEC_NO_ARTIFACT.md"
       }
     }
   }
   ```
   The `title` format is: `Fix {FAILURE_CODE} — {PATTERN_SUMMARY}`

5. **Write the input JSON** to `{RETRO_TMP}/retro-input.json`.

### 5.5c — Execute deterministic state machine

```bash
bash ~/.claude/skills/ticket-retro/retro.sh --github-post "{RETRO_TMP}"
```

One call runs `github_retro_process` over `{RETRO_TMP}/retro-input.json`, which handles all
deterministic mechanics: the count ≥ 2 threshold, the state file
(`~/.claude/state/ticket-retro/github-issues.json`), severity labels from
`github_retro_map_severity` (no AI interpretation), the open-issue check, create vs. comment, and
the atomic state update after each operation. It then removes the 5.5b files and prints
`GITHUB_STATUS=posted|skipped-auth|skipped-lib`, `GITHUB_CREATED`, `GITHUB_UPDATED` and the result
JSON (`{"created":[{"code","url"}],"updated":[…],"skipped":[codes]}`).

### 5.5d — Report

Emit `GitHub issues: {GITHUB_CREATED} created, {GITHUB_UPDATED} updated` (or the skipped line for
`skipped-*`), and keep both counts for the proposal GitHub Issues subsection and the completion
summary.
