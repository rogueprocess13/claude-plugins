---
name: ticket-pr-iterate
description: Incorporates PR review findings back into the implementation plan. Reads the ticket-pr-review comment (or pr-review-session.md), parses gap items, appends a versioned PR Review #N section to the plan artifact, and resets Linear state so ticket-implement can pick up the changes. Use when the user says "/ticket-pr-iterate {ID}", "iterate on PR feedback for {ID}", or "fix review gaps for {ID}".
---

# Ticket PR Iterate

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the steps below in order. This skill reads PR review findings and updates the implementation plan so the gaps can be addressed in a new implementation round.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=PR-REVIEW, HAS_LINEAR_ACCESS=false, HAS_LOGGING=true, HAS_HEARTBEAT=true, EMITS_PHASE_RESULT=false.

`EMITS_PHASE_RESULT=false` on purpose: IMPLEMENT → VERIFY → PR-REVIEW re-validate this skill's outcome, and a block from here would be indistinguishable from the real review's. Before starting, source the project context: `source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=PR-REVIEW, FROM_FLAG=none, HAS_LINEAR_ACCESS=false, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT,ISSUE_PREFIX, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
- **Findings source**: after locating review findings, write `hb-wrap.sh decision "findings-source" "info" "findings from {PR|session-file}" '{"source":"{pr|session-file}"}'`
- **Session fallback**: if no PR found and falling back to pr-review-session.md, write `hb-wrap.sh fallback "pr-review-data" "fired" "no PR found, using session file" '{"reason":"gh pr view returned no results"}'
- **Verdict already passing**: if verdict is ✅ (no gaps), write `hb-wrap.sh decision "iteration-skip" "info" "PR review already passed, no iteration needed"`
- **Iteration guard**: if N > 3 (too many iterations), write `hb-wrap.sh gate "iteration-limit" "fail" "iteration #{N} exceeds limit" '{"iterations":"{N}"}'`
- **Gap count**: after parsing gaps, write `hb-wrap.sh decision "gap-count" "fired" "{N} gaps to address" '{"count":"{N}"}'`
- **Artifact updated**: after updating the plan artifact, write `hb-wrap.sh decision "plan-updated" "fired" "appended PR Review #{N} to {ARTIFACT}" '{"artifact":"{ARTIFACT}","iteration":"{N}"}'`

### Step dispatch
| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `iterate-load` | Step 2 (find findings) | workspace already loaded; notes.md and context.md available |
| `iterate-findings` | Step 3 (iteration number) | gaps already parsed; re-run Step 2b to recover them |
| `iterate-plan` | Step 5 (update notes) | plan artifact already updated |
| `iterate-notes` | Step 6 (update Linear) | notes.md already updated |
| `iterate-linear` | End — skill already complete | — |

---

## Step 0.6 — Create task tracker

Per shared preamble § 8, one task per step (Steps 1 through 7). No trace file.

---

## Step 1 — Load ticket workspace

bash ~/.claude/skills/lib/plog.sh PR-REVIEW plan-iterate-start start "Parsing review findings, iteration #{prev+1}"

```bash
find . -type d -name "{TICKET-ID}*"
```

If not found → stop and tell the user to run `/ticket-appraise {TICKET-ID}` first.

Read `context.md` and `notes.md` from the ticket directory.

bash ~/.claude/skills/lib/plog.sh PR-REVIEW iterate-load done "Workspace loaded"

---

## Step 2 — Find and parse PR review findings

### Step 2a — Find the PR

**Scope every `gh` call with `--repo`** (#366: cwd is the `tickets` repo, so an unscoped call
returns `[]`). `lib/pr-repo-resolve.sh` derives the code repo:

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
GH_REPO=$(bash "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/pr-repo-resolve.sh" \
  "{TICKET-ID}" --log-file "$TAP_LOG" --ticket-dir "{ticket-dir}")
echo "GH_REPO=$GH_REPO"
[ -n "$GH_REPO" ] && gh pr list --repo "$GH_REPO" --search "{TICKET-ID} in:head" --json number,headRefName,url
```

If `$GH_REPO` is empty (exit 1 unresolvable, 3 worktrees in several repos), there is no PR
to look up — go to the session-file fallback below.

If a PR is found → capture `{PR_NUMBER}` and `{PR_URL}`, then go to Step 2b.

If no PR is found → check for a local session file:

```bash
find {ticket-dir} -name "pr-review-session.md"
```

- **Found** → read it. Extract the verdict and any gap notes from the step trace. Skip Step 2b and go directly to Step 3.
- **Not found** → stop and tell the user:
  > "No PR or pr-review-session.md found for {TICKET-ID}. Run `/ticket-pr-review {TICKET-ID}` first."

### Step 2b — Fetch and parse the PR review comment

```bash
_lib="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
GH_REPO=$(bash "$_lib/pr-repo-resolve.sh" "{TICKET-ID}" --log-file "$TAP_LOG" --ticket-dir "{ticket-dir}")
gh pr view {PR_NUMBER} --repo "$GH_REPO" --json comments --jq '.comments[] | select(.body | startswith("## Ticket alignment review")) | .body' |
  bash "$_lib/pr-review-comment.sh" parse || hb-wrap.sh retry "jq-parse" "fail" "PR review comment fetch/parse failed" \
  "{\"error_type\":\"jq_parse\",\"command\":\"gh pr view\"}"
```

`pr-review-comment.sh` (the format ticket-pr-review renders) reads the latest review comment and
prints `VERDICT=pass|gaps`, one `ROW<TAB>N<TAB>status<TAB>requirement` per requirement,
`NEXT_STEP<TAB>text` per suggested next step, and `GAPS=<n>`. Exit 1 (no review comment) → fall
back to `pr-review-session.md` as in Step 2a; if that also doesn't exist → stop.

### Step 2c — Collect the gaps

If `VERDICT=pass`, stop and report:
> "{TICKET-ID} PR review already passed — no gaps to iterate on."

Otherwise `{GAPS}` = the `ROW` lines whose status is ⚠️ (Partial) or ❌ (Missing): `number`,
`requirement`, `status`, and `suggested_fix` — the `NEXT_STEP` that names that requirement, if any.

bash ~/.claude/skills/lib/plog.sh PR-REVIEW iterate-findings done "{N} gaps parsed"

---

## Step 3 — Determine iteration number

```bash
bash ~/.claude/skills/lib/plan-append-review.sh next "{TICKET-ID}" --ticket-dir "{ticket-dir}"
```

It resolves the plan artifact with the one resolver (`ticket-dir.sh plan`: `simple-fix.md`, or
the openspec change's `tasks.md`) and prints `PLAN_MODE=`, `PLAN_PATH=`, `ARTIFACT=` and `N=`
(existing `## PR Review #` sections + 1). Exit 4 → the 3-iteration guard fired: stop and report
the printed message. Exit 2 (several change dirs) or 12 (no plan artifact) → stop and report it.

---

## Step 4 — Update the plan artifact

Write the section for `PLAN_MODE` to `{ticket-dir}/pr-review-{N}.md`, then append it.

### If simple-fix.md

```markdown
## PR Review #{N} — {today's date}

**Source:** PR #{PR_NUMBER}
**Verdict:** {N} gap(s) found

{For each gap:}
### Gap {gap.number}: {gap.requirement}

**Status in review:** {gap.status}

{If gap.suggested_fix exists:}
**Suggested fix:** {gap.suggested_fix}

**What needs to change:**
- {Concrete implementation steps — be specific about files, methods, values. Derive from the requirement text and suggested fix. Use the investigation findings in notes.md for file paths and context.}
```

### If openspec tasks.md

```markdown
## PR Review #{N} — {today's date}

**Source:** PR #{PR_NUMBER}
**Verdict:** {N} gap(s) found

{For each gap, create a numbered task with checkbox:}
- [ ] {N}.{gap.number} {gap.requirement}
  - **Status in review:** {gap.status}
  {If gap.suggested_fix exists:} — {gap.suggested_fix}
```

Use `N` as the task group prefix (e.g., iteration 1 tasks are `1.1`, `1.2`, `1.3`).

```bash
bash ~/.claude/skills/lib/plan-append-review.sh append "{TICKET-ID}" --ticket-dir "{ticket-dir}" \
  --log-file "$TAP_LOG" --n {N} --section "{ticket-dir}/pr-review-{N}.md"
```

It appends atomically, verifies the heading landed and logs `iterate-plan` itself. Exit 1 (section
missing after the write) or 3 (file does not open with `## PR Review #{N}`) → stop: a truncated
write would make ticket-implement silently skip every gap.

---

## Step 5 — Update notes.md

Append to `{ticket-dir}/notes.md` session log:

```markdown
### {today's date} — PR review iteration #{N}
- Source: PR #{PR_NUMBER} | Gaps: {N}
- Updated {ARTIFACT} with PR Review #{N} section
- Linear → Ready, `approved` label added
```

bash ~/.claude/skills/lib/plog.sh PR-REVIEW iterate-notes done "notes.md updated"

---

## Step 6 — Update Linear

Delegate to the flow executor:

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} pr-iterate --provenance policy
_rc=$?
# flow-run.sh has already logged any non-zero exit (META|flow-error + heartbeat).
# pr-iterate carries no verdict_gate, so exit 11 cannot occur; a failure is non-fatal — continue.
```

This sets state → `Ready`, adds `approved`, and clears `reviewed`/`rejected`. All other labels (`simple`/`complex`, `Smooth`/`Rough`/`Hard`) are preserved.

bash ~/.claude/skills/lib/plog.sh PR-REVIEW iterate-linear done "Ready + approved"

---

## Step 7 — Report

bash ~/.claude/skills/lib/plog.sh PR-REVIEW plan-iterate-done done "Iteration #{N} ready"

```
## {TICKET-ID} — PR review iteration #{N} ready

**Source:** PR #{PR_NUMBER} ({PR_URL})
**Gaps found:** {N} (see details below)
**Plan updated:** {ARTIFACT} — `## PR Review #{N}` section appended
**Linear:** Ready + `approved`

### Gaps from review

{For each gap:}
- **#{gap.number}** {gap.requirement} → {gap.status}

### Next step

Run `/ticket-implement {TICKET-ID}` to address these gaps.
```
