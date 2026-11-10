---
name: ticket-pr-review
description: Reviews a pull request by extracting requirements from its Linear ticket, validating the changed code against those requirements, and posting findings to the PR. Use when the user says "/ticket-pr-review {TICKET-ID}", "review PR for {TICKET-ID}", or "verify {TICKET-ID} against ticket".
---

# Ticket PR Review

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the full review sequence below in order.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=PR-REVIEW, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_LOGGING=true, HAS_HEARTBEAT=true, EMITS_PHASE_RESULT=true, PHASE_RESULT_TIER=1, PHASE_RESULT_VERIFIER=pr_review, PHASE_RESULT_ATTEMPT=<the `PHASE_RESULT_ATTEMPT=` value in your spawn INSTRUCTIONS; omit the ATTEMPT field entirely if you were not given one>. Before starting, source the project context: `source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=PR-REVIEW, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=ISSUE_PREFIX,REPOS_ROOT, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
- **Requirement extraction**: after extracting requirements from the ticket, write `hb-wrap.sh decision "requirement-extraction" "ok" "extracted N requirements" '{"count":"N"}'`
- **CI checks**: after checking CI status, write `hb-wrap.sh gate "ci-checks" "ok|fail" "CI status: <state>" '{"state":"<passing|failing>"}'`
- **Merge decision**: after rendering verdict, write `hb-wrap.sh decision "merge-decision" "fired" "verdict" '{"verdict":"<✅|⚠️|❌>"}'`

### Step dispatch
| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `fetch-ticket` | Step 2 (extract requirements) | ticket data already cached; re-fetch if needed |
| `extract-requirements` | Step 3 (find PR) | requirements log entry or re-extract from ticket |
| `find-pr` | Step 4 (get changed code) | PR number from log `find-pr\|done` entry |
| `validate-diff` | Step 5.5 (ADR gate check) | validation results from notes or re-run — never straight to 6: Step 5.6 must record the verdict before 6a's gated trigger (#368) |
| `post-findings` | Step 6b (merge decision) | verdict from log `post-findings\|done` entry |
| `merge-decision` | End — skill already complete | — |

---

## Step 0.6 — Create task tracker

Create a TaskCreate for every remaining step (Steps 1 through 7). Each task subject = the step heading. After each step is fully done, mark it completed with TaskUpdate. At session end, write a trace file to the ticket directory:

```bash
cat > {ticket-dir}/pr-review-session.md << 'TRACE'
# pr-review session — {ISSUE-ID}
**Date:** {today}
**PR:** {PR URL}
**Verdict:** {pass|gaps found}
**Merged:** {yes|no|skipped}

## Step trace
- [x] Step 1: Fetch ticket — done
- [x] Step 2: Extract requirements — {N} requirements
- [x] Step 3: Find PR — #{number}
- [x] Step 4: Get changed code — {N} files
- [x] Step 5: Validate requirements — {pass/fail count}
- [x] Step 6: Post findings + label — done
- [x] Step 6a: Update Linear label — {reviewed|rejected}
- [x] Step 6b: CI check gate — {all green|blocked: {check names}|skipped (gaps)}
- [x] Step 6b-merge: Merge — {merged|skipped|failed: reason}
- [x] Step 7: Report — done
TRACE
```

---

## Step 1 — Fetch the Linear ticket

bash ~/.claude/skills/lib/plog.sh PR-REVIEW fetch-ticket start "Fetching ticket"

Call the Linear access strategy to fetch the ticket (bash `get_issue` when `LINEAR_API_KEY` is set, MCP `get_issue` fallback otherwise).

Capture:
- `title`, `description` (requirements source)
- `labels`, `status`, `url`

bash ~/.claude/skills/lib/plog.sh PR-REVIEW fetch-ticket done "Fetched"

**Resolve the ticket workspace directory** created at appraise time (never recompute a slug
from the title or branch):

```bash
find . -type d -name "{TICKET-ID}*"
```

This is `{ticket-dir}` for the rest of this skill (Step 0.6's trace file, and any
build-output log in Step 4). If not found, fall back to `resolve_ticket_dir` in
`~/.claude/skills/lib/ticket-dir.sh`.

---

## Step 2 — Extract requirements

Activate the analyzer persona:
```bash
# --ticket-dir derives the type (manifest `type`, else `bug` from context.md's Labels line, else none)
# and passes it as the selector's --type; it also feeds the selector the ticket text.
eval "$(TICKET_ID="{TICKET-ID}" TICKET_TEXT_FILE="{ticket-dir}/context.md" bash ~/.claude/skills/lib/persona-select.sh --repo <repo> --phase review --ticket-dir "{ticket-dir}")"
for _k in PERSONA_BASE PERSONA_AUTO_INCLUDE PERSONA_TESTDATA PERSONA_DEBUG; do echo "$_k=${!_k:-}"; done
```
Read the persona file at `$PERSONA_BASE`. Inject its content as role context for this step. If `$PERSONA_AUTO_INCLUDE` is non-empty, read it too. If `$PERSONA_TESTDATA` is non-empty, read it too and check the diff's seeds and fixtures for idempotency, namespaced keys, referential integrity and production personal data.

If `$PERSONA_DEBUG` is non-empty (a bug ticket), append two requirements to the checklist below, each verified against the diff in Step 5 like any other:
- **Fix at the root cause** — the change addresses the root cause stated in `notes.md` (`### Root cause hypothesis`, or the implementer's recorded cause), not only the symptom site where the failure showed up.
- **Regression test** — a regression test exists in the diff that fails without the fix and passes with it.

bash ~/.claude/skills/lib/plog.sh PR-REVIEW extract-requirements start "Extracting requirements"

Parse the ticket description into a numbered requirements checklist. Each item must be a concrete, verifiable statement — not a paraphrase of intent. If acceptance criteria are explicitly listed, use those verbatim. If not, derive them from the description.

Record the checklist — it drives the validation in Step 5.

bash ~/.claude/skills/lib/plog.sh PR-REVIEW extract-requirements done "{N} requirements"

---

## Step 3 — Find the PR and branch

bash ~/.claude/skills/lib/plog.sh PR-REVIEW find-pr start "Finding PR"

**Resolve the code repo before searching** (#366: cwd is the `tickets` repo, so an unscoped
`gh pr list` always returns `[]`). Derive `owner/repo` from the worktree's remote, never cwd:

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
source "$HOME/.claude/skills/lib/worktree.sh"
WORKTREE_PATH=$(worktree_path "$TICKET_ID" "{repo-slug}")
if [ ! -d "$WORKTREE_PATH/.git" ] && [ ! -f "$WORKTREE_PATH/.git" ]; then
  # Worktree missing (e.g. GC'd) — fall back to the checkpoint notes.md recorded at
  # implement time (`### ... — pre-implementation checkpoint`, `Worktree:` field).
  WORKTREE_PATH=$(grep "Worktree:" {ticket-dir}/notes.md 2>/dev/null | tail -1 | sed -n 's/.*Worktree: \([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//')
fi
GH_REPO=$(git -C "$WORKTREE_PATH" remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
if [ -z "$GH_REPO" ]; then
  echo "Cannot resolve the code repo for {TICKET-ID} — no worktree and no checkpoint entry in notes.md." >&2
  exit 1
fi
PR_LIST=$(gh pr list --repo "$GH_REPO" --search "{TICKET-ID} in:head" --json number,headRefName,baseRefName,url)
```

If `$GH_REPO` cannot be resolved, stop and tell the user:
> "Cannot resolve the code repo for {TICKET-ID} — no worktree and no checkpoint entry in notes.md. Re-run /ticket-implement or specify the repo manually."

**No-diff exemption:** if IMPLEMENT logged `commit-push|skip` (verification-only ticket) and
the search returned nothing, write the terminal marker and stop — there is no code to review:

```bash
if [ -n "$TAP_LOG" ] && grep -q '|IMPLEMENT|commit-push|skip|' "$TAP_LOG" && [ "$(echo "$PR_LIST" | jq 'length')" = "0" ]; then
  bash ~/.claude/skills/lib/plog.sh PR-REVIEW pr-review done "N/A — no PR (verification-only ticket, no source diff produced by IMPLEMENT)"
  exit 0
fi
```

Otherwise, if no PR is found → stop and tell the user:
> "No open PR found for {TICKET-ID}. Open a PR first, then re-run."

Capture: `number`, `headRefName`, `baseRefName`, `url` (from `$PR_LIST`).
Extract `owner` and `repo` from the PR URL (`https://github.com/{owner}/{repo}/pull/{number}`) for the REST calls below — the URL wins over `$GH_REPO`.

bash ~/.claude/skills/lib/plog.sh PR-REVIEW find-pr done "PR #{number}"
# Write PR number to pipeline log for detect-resume.sh (primary lookup, not fallback)
bash ~/.claude/skills/lib/plog.sh PR-REVIEW checkout-pr done "{number}"

---

## Step 4 — Get changed code

Resolve the worktree path from `notes.md` pre-implementation checkpoint or the env file, then:

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
source "$HOME/.claude/skills/lib/worktree.sh"
WORKTREE_PATH=$(worktree_path "$TICKET_ID" "{repo-slug}")
git -C "$WORKTREE_PATH" fetch origin
git -C "$WORKTREE_PATH" diff origin/{baseRefName}...origin/{headRefName}
```

This produces the full set of changes introduced by the branch relative to its base.

---

## Step 4.5 — Structural impact analysis (GitNexus)

bash ~/.claude/skills/lib/plog.sh PR-REVIEW gitnexus-impact start "Running detect_changes"

**Pre-flight: GitNexus reachability + branch verification (#359)** — a reachable index may sit on an unrelated branch. Verify both:

1. **Reachability:** call `mcp__gitnexus__list_repos`. If the call fails or times out after 5 seconds, GitNexus is unavailable — skip to the fallback below. Log: `gitnexus-health|fail|unreachable` in the heartbeat.
2. **Branch verification:** from the `list_repos` result, find the entry for this repo and read its `lastCommit`. Then run:
   ```bash
   source "$HOME/.claude/skills/lib/gitnexus-preflight.sh"
   gitnexus_verify_branch "$WORKTREE_PATH" "{lastCommit}" "origin/{headRefName}"
   ```
   (`$WORKTREE_PATH` is from Step 4, `origin` fetched.) `ok <n>` (exit 0) means verified — proceed. Exit 1 (`wrong-branch`, `ahead <n>`, `stale <n>`) or 2 (`unresolvable <reason>`) means **unverified** — log `gitnexus-health|fail|stale-or-wrong-branch` in the heartbeat and skip to the fallback below.

Only once both checks pass: call `mcp__gitnexus__detect_changes` with `scope: "compare"` and `base_ref: "{baseRefName}"`. This maps the full PR diff against the knowledge graph.

**If results are returned:**
- **Sanity-check the result set (#359):** compare `detect_changes`' affected-file list against the real PR diff already obtained in Step 4 (`git diff --name-only origin/{baseRefName}...origin/{headRefName}`). Write both file lists (one path per line) and run:
  ```bash
  gitnexus_check_result_subset "$RETURNED_FILES" "$KNOWN_PR_FILES"
  ```
  Exit 1 (files outside the real PR diff) means the result is unreliable: discard it, log `gitnexus-health|fail|stale-or-wrong-branch`, and fall back below.
- Record each affected execution flow with its risk level
- **Constructor DI filter:** a HIGH or CRITICAL flow whose change is only constructor parameter additions (new DI params, no logic change) is downgraded to LOW. Log: `gitnexus-filter|info|constructor-DI downgrade: {flow-name} HIGH→LOW`
- If any non-DI flow remains at HIGH or CRITICAL risk, flag it prominently in the findings

**If zero results, GitNexus unavailable, branch unverified, or the result set failed the subset check:**
- Note that changed files have no indexed execution flows (shell scripts, config, docs — expected for some repos), or that the index could not be verified/trusted for this branch
- Log a warning and proceed — never block on GitNexus availability

**If GitNexus's structural diff is unreliable for this repo** (branch verification failed, or the result failed the subset sanity check above) and you fall back to running the project's own test command directly as manual verification: redirect that command's stdout/stderr to `{ticket-dir}/pr-review-build-{repo-slug}.log`, never to `$TAP_LOG`. `$TAP_LOG` gets one summary line only (its parsers expect strict `ISO|PHASE|STEP|STATUS|MSG` rows), e.g. `bash ~/.claude/skills/lib/plog.sh PR-REVIEW manual-verify done "{repo}: {pass|fail}, {N} tests"`.

bash ~/.claude/skills/lib/plog.sh PR-REVIEW gitnexus-impact done "{N} affected flows, risk: {highest-risk}"

---

## Step 5 — Validate requirements against diff

bash ~/.claude/skills/lib/plog.sh PR-REVIEW validate-diff start "Validating against requirements"

For each requirement from Step 2, evaluate whether the diff contains code that directly addresses it:

- **✅ Addressed** — the diff contains code that directly implements or fixes it
- **⚠️ Partial** — some but not all of the requirement is visible in the diff
- **❌ Missing** — no corresponding change found in the diff

Build a requirements coverage table:

| # | Requirement | Status |
|---|---|---|
| 1 | {requirement} | ✅ / ⚠️ / ❌ |

bash ~/.claude/skills/lib/plog.sh PR-REVIEW validate-diff done "Coverage: {pass}/{total}"

---

## Step 5.5 — ADR gate check

If the diff as a whole introduces an architectural decision (a cross-cutting constraint other
components or future work must follow) with no governing ADR cited in the PR or commits, invoke
the gate now per preamble § 8, **before** Step 6. A `CONFLICT`, `CREATED_PROPOSED` or
`SUPERSEDE_REQUIRED` verdict means Step 6b MUST NOT merge, regardless of requirements coverage.

Otherwise go to **Step 5.6** — never straight to Step 6 (#368).

---

## Step 5.6 — Record verifier result (Phase 0 RLVR)

**Before Step 6** — Step 6a's `pr-review-pass-*` triggers are verdict-gated
([§ Verdict gate](../ticket-flow/SKILL.md#verdict-gate)), so this run's verdict must be on the
log first or an earlier BLOCK would refuse a now-valid transition (#368).

Map ✅ → `PASS`, ⚠️ → `WARN`, and a blocking Step 5.5 ADR verdict → `BLOCK` regardless of coverage:
```bash
source ~/.claude/skills/lib/verifier-result.sh
write_verifier_result verifier=pr_review verdict=<PASS|WARN|BLOCK> criteria_met=<met> criteria_total=<total> attempt=1 phase=PR-REVIEW
```

---

## Step 6 — Post findings to PR + update Linear

bash ~/.claude/skills/lib/plog.sh PR-REVIEW post-findings start "Posting review findings"

Write the Step 5 table as tab-separated lines to `{ticket-dir}/pr-review-rows.tsv`
(`N<TAB>requirement<TAB>✅|⚠️|❌`), any Step 4.5 flows to `pr-review-impact.tsv`
(`flow<TAB>risk`), and on gaps one suggested next step per line ("Add a commit addressing X" or
"Confirm with the team if X was intentionally descoped") to `pr-review-steps.txt`. The script
renders the comment ticket-pr-iterate parses back, verdict included (✅ only when every row is ✅).
Post with REST, not `gh pr comment` (GraphQL lags on a new PR):

```bash
_lib="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
gh api "repos/{owner}/{repo}/issues/{number}/comments" -f body="$(bash "$_lib/pr-review-comment.sh" render \
  --ticket "{TICKET-ID}" --url "{Linear URL}" --rows "{ticket-dir}/pr-review-rows.tsv" \
  --impact "{ticket-dir}/pr-review-impact.tsv" --next-steps "{ticket-dir}/pr-review-steps.txt")"
```

Leave out `--impact` / `--next-steps` when you wrote no such file.

### Step 6a — Update Linear label

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
bash ~/.claude/skills/lib/pr-review-transition.sh --log-file "{LOG_FILE}" --verdict {pass|gaps} {TICKET-ID}
```

`--verdict gaps` (⚠️) fires `pr-review-fail` (no verdict gate). `--verdict pass` (✅) fires the
trigger `uat_decide_trigger` picks, after `merge_blocked_reason` (#412): under `UAT Policy: epic`
it is `pr-review-pass-done`, so the child closes and its `blocked-by` dependents are released.
Under `per-ticket` (the default) a passing review goes to `UAT` when a UAT target is configured
**or** the PR is left for a human merge (autonomy `manual`, or any epic `Merge Policy`), and to
`Done` only when this run may merge the PR in Step 6b. A ticket parked in `UAT` for a pending
merge stays there until a human merges the PR and fires `uat-pass`.

Exit `11` (it prints `GATE_BLOCKED=true`) means the verdict gate refused the transition: another
verifier's FAIL/BLOCK is still latest. `_gate_blocked=true` carries into Steps 6b/7/8. Any
other flow failure is already logged and non-fatal.

bash ~/.claude/skills/lib/plog.sh PR-REVIEW post-findings done "Verdict: {✅|⚠️}"

### Step 6b — Merge PR if all requirements addressed

One script makes the whole merge decision and fails closed on every `gh`/git error:
`merge_blocked_reason` first (the same rule as Step 6a), then `gh pr checks` buckets (only
`pass`/`skipping` pass; a checkless PR is fine), then `conflict-marker-scan.sh` over the Step 4
diff, then a REST squash merge — never forced. It logs `merge-decision` and posts any refusal as
a PR comment itself.

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
bash ~/.claude/skills/lib/pr-merge-gate.sh --log-file "{LOG_FILE}" {SKIP} --repo {owner}/{repo} --pr {number} \
  --base {baseRefName} --head {headRefName} --worktree "{Step 4 WORKTREE_PATH}" {TICKET-ID}
```

`{SKIP}` is `--skip gate-blocked` when `_gate_blocked=true`, `--skip skipped` on ⚠️/❌ or a
blocking Step 5.5 ADR verdict, otherwise empty. Exit 0 merged,
3 not merged, 4 the merge call failed. On 3 or 4 report the printed message (after the
`MERGE_RESULT`/`MERGE_REASON` lines) to the user. Never merge any other way.

---

## Step 7 — Report to user

**If `_gate_blocked=true`** (Step 6a's trigger came back `exit 11`), report this instead —
this run's own review passed but the Linear transition was refused:

```
## {TICKET-ID} — PR alignment review complete, Done/UAT transition BLOCKED

**PR:** {PR URL}
**Verdict:** ✅ All requirements addressed — this run's own review passed.

The ticket could **not** move to Done/UAT: another check's FAIL/BLOCK verifier-result is
still the latest on record (#368). The PR was **not merged**. Fix that check (a later PASS
clears the block) or re-run `/ticket-flow {TICKET-ID} {trigger} --override <reason>`.

Findings posted to PR #{number}.
```

**Otherwise**, report normally:

```
## {TICKET-ID} — PR alignment review complete

**PR:** {PR URL}
**Verdict:** {✅ All requirements addressed | ⚠️ Gaps found}

Findings posted to PR #{number}.
```

---

## Step 8 — Emit the PHASE_RESULT block (--from-auto only)

End your return with the `=== PHASE_RESULT ===` block described in **§ 6 Phase
result emission** of the auto preamble, with `PHASE: PR-REVIEW` and
`VERIFIER: pr_review`.

**If `_gate_blocked=true`**: `VERDICT: BLOCK`, regardless of the ✅/⚠️ requirements verdict —
never `PASS`, which would read as an unblocked completion.

**Otherwise**, map `VERDICT` from the emoji verdict exactly as the `write_verifier_result`
call in Step 5.6 does: ✅ → `PASS`, ⚠️ → `WARN`, ❌ → `BLOCK`. Do not emit the emoji itself
and do not invent a value — anything outside the four-value enum is rejected outright and
your verdict is then recorded as `UNKNOWN`.

Set `CRITERIA_MET`/`CRITERIA_TOTAL` to the requirement counts from Step 5, `EVIDENCE` to
what you actually reviewed (files, diff size, checks run), and `UNADDRESSED` to any
requirement you could not evaluate (on the gate-blocked path, name the transition that was
refused). Nothing goes after the closing marker.
