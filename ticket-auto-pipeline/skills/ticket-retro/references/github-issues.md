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

### 5.5a — Source library and check auth

```bash
GITHUB_ISSUES_LIB="$HOME/.claude/skills/lib/github-issues.sh"
if [ -f "$GITHUB_ISSUES_LIB" ]; then
  source "$GITHUB_ISSUES_LIB"
else
  echo "WARN: github-issues.sh not found at $GITHUB_ISSUES_LIB — skipping GitHub post"
fi

if ! declare -f github_check_auth >/dev/null 2>&1; then
  echo "WARN: github_check_auth not available — skipping GitHub post"
elif ! github_check_auth; then
  echo "WARN: gh CLI not authenticated — skipping GitHub post (proposal still written)"
fi
```

If `github_check_auth` fails or the library is unavailable, skip all GitHub operations. The proposal is still written.

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
GITHUB_RETRO_LIB="$HOME/.claude/skills/lib/github-issue-retro.sh"
if [ -f "$GITHUB_RETRO_LIB" ]; then
  source "$GITHUB_RETRO_LIB"
  RESULT=$(github_retro_process "{RETRO_TMP}/retro-input.json")
  echo "$RESULT"
else
  echo "WARN: github-issue-retro.sh not found — skipping GitHub post"
fi
```

This single call handles ALL deterministic mechanics:
- Threshold check (count ≥ 2 → gate, <2 → skip)
- State file read (`~/.claude/state/ticket-retro/github-issues.json`)
- Severity mapping (bash case statement — no AI interpretation)
- Open-issue check (`github_issue_lookup` → OPEN, CLOSED, or NOT_FOUND)
- Create vs. comment decision
- State file update (atomic, JSON-validated, after each successful operation)

The result JSON has the shape:
```json
{
  "created": [{"code": "EXEC_NO_ARTIFACT", "url": "https://..."}],
  "updated": [{"code": "APPROVAL_REVOKED", "url": "https://..."}],
  "skipped": ["RETURN_INCOMPLETE"]
}
```

### 5.5d — Report

Extract counts from the result:
```bash
GITHUB_CREATED=$(echo "$RESULT" | jq '.created | length')
GITHUB_UPDATED=$(echo "$RESULT" | jq '.updated | length')
```

Emit summary:
```
GitHub issues: {GITHUB_CREATED} created, {GITHUB_UPDATED} updated
```

Store `{GITHUB_CREATED}` and `{GITHUB_UPDATED}` for the proposal GitHub Issues subsection and the completion summary.

Clean up temp files:
```bash
cd "{RETRO_TMP}" && rm -f retro-input.json issue-body-*.md evidence-*.md
```
