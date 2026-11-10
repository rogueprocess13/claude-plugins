---
name: ticket-implement
description: Full implementation workflow for a Linear ticket that has been approved. Loads the ticket workspace, moves to Ready, sets up branches on affected repos, runs the implementation (simple-fix or openspec), commits, and pushes. PR creation and close-out are gated by /ticket-verify. Use when the user says "/ticket-implement {ID}", "implement ticket {ID}", "start implementing {ID}", or "work on {ID}" after appraisal/approval is done.
---

# Ticket Implement

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the full implementation sequence below in order.

**BASE BRANCH:** Resolved by the router at Step 0.5 and injected via `$BASE_BRANCH` in the env file. Default is `develop`. Branch from `$BASE_BRANCH`, PR into `$BASE_BRANCH`.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=IMPLEMENT, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_LOGGING=true, HAS_HEARTBEAT=true, EMITS_PHASE_RESULT=true, PHASE_RESULT_TIER=1, PHASE_RESULT_VERIFIER=implement_tests, PHASE_RESULT_ATTEMPT=<the `PHASE_RESULT_ATTEMPT=` value in your spawn INSTRUCTIONS, if any; IMPLEMENT is spawned once per run, so omit the ATTEMPT field entirely when you were not given one>. Before starting, source the project context: `source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=IMPLEMENT, FROM_FLAG=none, EXTRA_GUARD=base-branch, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT,ISSUE_PREFIX,BE_SERVICES,BE_TEST_CMD,BE_TEST_RUNNER,FE_TEST_CMD, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
- **Test command**: if BE_TEST_RUNNER found, write `hb-wrap.sh heartbeat "test-command" "BE_TEST_RUNNER configured" '{"cmd":"<cmd>"}'`; elif BE_TEST_CMD found, write `hb-wrap.sh heartbeat "test-command" "BE_TEST_CMD configured" '{"cmd":"<cmd>"}'`; if absent, write `hb-wrap.sh heartbeat "test-command" "skip" "no BE_TEST_CMD or BE_TEST_RUNNER"`
- **Artifact path**: after detecting the plan artifact, write `hb-wrap.sh decision "artifact-path" "info" "artifact detected" '{"type":"simple-fix|openspec"}'`
- **Implementation mode**: after detect-path, write `hb-wrap.sh decision "implementation-mode" "fired" "simple|openspec" '{"mode":"..."}'`
- **Code-writing progress** ([long-running step](../../pipeline-heartbeat-format.md#long-running-steps-enumerated); advisory, nothing gates on it): after each file (simple-fix) or task (openspec), write `hb-wrap.sh heartbeat "step-progress" "ok" "implement: <file-or-task> (N of M)" '{"step":"implement-changes","done":"N","total":"M"}'`.
- **Plan artifact durability**: after Step 5.5's `openspec-tracking-check.sh assert` call, write `hb-wrap.sh gate "artifact-durability" "ok|warn" "tracked|not-applicable|{status}" '{"ticket":"{TICKET-ID}","status":"{OPENSPEC_TRACK_STATUS}"}'`

### Step dispatch
**Context restoration when skipping early steps:**
- Worktree path: read from notes.md `### ... — pre-implementation checkpoint` entry (`Worktree:` field) or re-derive via `source "$HOME/.claude/skills/lib/worktree.sh" && worktree_path "$TICKET_ID" "{repo-slug}"`.
- Branch name: read from notes.md checkpoint or from `IMPLEMENT|checkout-branch|done|` in `$TAP_LOG`.
- Implementation mode: read from `IMPLEMENT|detect-path|done|` in `$TAP_LOG` (value: `simple-fix` or `openspec`).
- Affected repos: re-derive from notes.md `Initial Investigation` section and CLAUDE.md table.
- `$IMPLEMENT_TICKETS_ROOT`: never restored — captured fresh on every invocation (below).

| `--from-step` value | Skip to | Restore |
|---------------------|---------|---------|
| `check-approval` | Step 2 (detect path) | ticket dir from find; notes.md and context.md |
| `detect-path` | Step 3 (checkout branch) | mode from log `detect-path\|done` entry; `references/rework.md` if a rework is open (load condition below) |
| `checkout-branch` | Step 4 (implement) | branch + worktree from notes.md checkpoint; mode from log; `references/rework.md` if a rework is open |
| `implement` | Step 4b (write tests) | changed files from `git -C "$WORKTREE_PATH" diff --name-only "$BASE_BRANCH"`; `references/rework.md` if a rework is open |
| `run-tests` | Step 4b code-review | — |
| `code-review` | Step 5 (commit/push) | — |
| `commit-push` | Step 5.5 (plan artifact durability check) | mode from log `detect-path\|done` entry |

**Concurrency guard:** if you need to check whether another worker is already implementing this ticket, never grep the process table (`ps`/`pgrep`) for your own prompt or skill name — your own process (and its own `spawn_agent_pre` shell) always matches. Use file-based signals instead: an existing worktree/branch with commits already on it, a lockfile whose PID is not in your own ancestry, or a terminal `IMPLEMENT|implement|done|`/`|fail|` line already present in `$TAP_LOG` for this ticket.

**Capture the tickets repo root — the very first bash action of this session, regardless of `--from-step`.** Every invocation starts at the tickets repo root; Step 4 `cd`s into a code worktree and nothing `cd`s back, so Step 5.5 uses this instead of CWD:

```bash
IMPLEMENT_TICKETS_ROOT="$(pwd)"
```

### Reference files (load condition)

**Rework.** Run `bash ~/.claude/skills/lib/skill-ref.sh ticket-implement references/rework.md` only on a rework entry: Step 2.5 finds `FAIL_COUNT` > `SECTION_COUNT`, or a `--from-step` resume that skips Step 2.5 (`detect-path`, `checkout-branch`, `implement`) while a rework is still open. On such a resume, a rework is open when notes.md's last `— verification re-run #` entry comes after its last `— committed` entry:
```bash
awk '/^### .* — verification re-run #/{r=NR} /^### .* — committed/{c=NR} END{print (r>c)?"REWORK_OPEN=true":"REWORK_OPEN=false"}' "{ticket-dir}/notes.md"
```
A first implementation attempt, and a run whose verify failures are all addressed, does not read it.

**Feedback.** Run `bash ~/.claude/skills/lib/skill-ref.sh ticket-implement references/feedback.md` in Step 4c only when a feedback item exists: a complexity mismatch (predicted `simple` with outcome `Rough`/`Hard`, or predicted `complex` with `Smooth`), or a wiki gap found in Part 3. A run with neither does not read it.

Read each printed path in full and do not continue until you have read it. If `skill-ref.sh` exits non-zero, run `bash ~/.claude/skills/lib/plog.sh META reference-missing fail "references/<file>.md"` with the file that failed and stop: never run the rework, or write the mismatch comment, errata or CORRECTIONS, from memory. After a context compaction, read the reference again before continuing the step it covers.

---

## Step 0.6 — Create task tracker

Per shared preamble § 8, one task per step (Steps 1 through 6, sub-steps included in their parent). No trace file.

---

## Step 1 — Approval guard + load workspace

bash ~/.claude/skills/lib/plog.sh IMPLEMENT check-approval start "Checking authorization"

**Determine authorization** (tracker-approval-by-script: approval is a local manifest fact, not a Linear label — no tracker fetch for this check):

```bash
source ~/.claude/skills/lib/manifest-read.sh 2>/dev/null || true
_ia_approved=""
if declare -f get_ticket_manifest_field >/dev/null 2>&1; then
  _ia_approved=$(get_ticket_manifest_field "{TICKET-ID}" approved 2>/dev/null)
fi
echo "IMPLEMENT_APPROVED=${_ia_approved:-}"
```

- If `IMPLEMENT_APPROVED=true` → authorized. This is a fresh implementation or human-re-approved rework (`/ticket-approve`).
- If not approved, fetch the ticket from Linear (bash `get_issue` when `LINEAR_API_KEY` is set, MCP fallback otherwise) and check the live `rejected` label — still tracker-written, unlike `approved`. If present → authorized for UAT rework. Note: "UAT rework cycle — `rejected` label signals authorization for rework. Proceeding to Step 2 which will read the REMEDIATION_BRIEF from the plan."
- If NEITHER the manifest's `approved` fact nor the live `rejected` label authorizes it → stop and report:
  ```
  ⛔ {TICKET-ID} not approved yet. Run /ticket-approve {TICKET-ID} (or wait for the `rejected` label for UAT rework), then re-run.
  ```

**When authorized,** find the local directory:
```bash
find . -type d -name "{TICKET-ID}*"
```

If not found → tell the user to run `/ticket-appraise {TICKET-ID}` first. Stop here.

Read `context.md` and `notes.md`.

**Regression Risk gate:** Check notes.md for a `## ⚠️ Regression Risk` section.

If it exists AND `**Status:** UNACKNOWLEDGED` is present → stop immediately:

```
⚠️  Implementation blocked — unacknowledged regression risk.

Open notes.md for {TICKET-ID} and review the ## Regression Risk section.
Then change:
  **Status:** UNACKNOWLEDGED
to:
  **Status:** ACKNOWLEDGED

Re-run /ticket-implement {TICKET-ID} after acknowledging.
```

If the section is absent, or Status is `ACKNOWLEDGED` → proceed normally.

Append a session checkpoint:
```markdown
### {today's date} — implementation session started
- Authorization: {approved | rejected (UAT rework)}. Repos and branch to be confirmed in Step 2.
```

bash ~/.claude/skills/lib/plog.sh IMPLEMENT check-approval done "Authorized"

---

## Step 2 — Identify implementation path

Log the step start:
```bash
bash ~/.claude/skills/lib/plog.sh IMPLEMENT detect-path start "Identifying implementation path"
```

From `notes.md` and `context.md`, identify affected repos. Cross-reference with the CLAUDE.md codebase table for full paths.

**Implementation path** — use the one plan-artifact resolver (whole-ID match: `TEST-7` never
picks up `TEST-77`'s files). Run it from the tickets repo (CWD here):
```bash
bash ~/.claude/skills/lib/ticket-dir.sh plan "{TICKET-ID}" --root . --log-file "$TAP_LOG"
```
It prints `PLAN_MODE=`, `PLAN_PATH=` and, for openspec, `CHANGE_DIR=`.
- Exit 0, `PLAN_MODE=simple-fix` → mode **simple-fix**. Read `PLAN_PATH` now.
- Exit 0, `PLAN_MODE=openspec` → mode **openspec**. The change is `CHANGE_DIR`; read its `tasks.md` (`PLAN_PATH`).
- Exit 2 → more than one change dir matches this ticket (listed on stderr). Stop and report it — never pick one.
- Exit 12 → no plan artifact. Stop and report it.

**Activate persona** based on the `Layer` column in CLAUDE.md for each affected repo. For `FE+BE` monorepos, use the layer boundary table to classify by actual files touched:

Run the selector in one bash block per layer (`{ticket-dir}` is the directory found in Step 1). `--ticket-dir` derives the ticket type (manifest `type`, else `bug` from context.md's Labels line, else none — the `--type` it would pass) and feeds the selector the ticket text; the block then logs which personas were injected:
```bash
eval "$(TICKET_ID="{TICKET-ID}" TICKET_TEXT_FILE="{ticket-dir}/context.md" bash ~/.claude/skills/lib/persona-select.sh --repo <repo> --layer <FE|BE> --phase implement --ticket-dir "{ticket-dir}")"
for _k in PERSONA_TYPE PERSONA_BASE PERSONA_SPECIALIZER PERSONA_AUTO_INCLUDE PERSONA_TESTDATA PERSONA_TESTDATA_SPECIALIZERS PERSONA_DEBUG PERSONA_DEBUG_SPECIALIZER; do echo "$_k=${!_k:-}"; done
# META pseudo-phase on purpose: an IMPLEMENT|persona-select line would become detect-resume's IMPLEMENT_FROM.
_ps_spec="${PERSONA_SPECIALIZER#*/specializers/}"
_ps_debug="none"
[ -n "${PERSONA_DEBUG:-}" ] && _ps_debug="debugger"
[ -n "${PERSONA_DEBUG_SPECIALIZER:-}" ] && _ps_debug="${PERSONA_DEBUG_SPECIALIZER#*/specializers/}"
bash ~/.claude/skills/lib/plog.sh META persona-select info "base=$(basename "$PERSONA_BASE" .md);spec=${_ps_spec:-none};debug=${_ps_debug}"
```
Read the persona files at `$PERSONA_BASE` and `$PERSONA_SPECIALIZER`. If `$PERSONA_AUTO_INCLUDE` is non-empty, read that too. If `$PERSONA_TESTDATA` is non-empty, read it and every path in `$PERSONA_TESTDATA_SPECIALIZERS` (colon-separated) — they say how to build idempotent, namespaced, synthetic test data for the channels the ticket uses. If `$PERSONA_DEBUG` is non-empty (a bug ticket), read it and `$PERSONA_DEBUG_SPECIALIZER` when set — a debugging procedure layered on top of the stack persona, not a replacement for it: reproduce, trace back to the original trigger, state one hypothesis with evidence, write the failing test first, make one change. Keep the `PERSONA_TYPE` value printed above — Step 2.5 Part B reuses it.

A `## Test Data Provided` ticket swaps `$PERSONA_BASE` to `test-data-engineer.md`. A hand-filed bug with neither a manifest `type` nor a `bug` label gets no debugger overlay.
- Mixed → run once per layer; switch at the FE/BE boundary. Note the boundary in `notes.md`.
- Test-data ticket (`$PERSONA_BASE` is `test-data-engineer.md`) → the whole deliverable is data, so do not split per layer. Make the ticket's `Seed command:` and `Verify command:` real (create the targets or scripts they name, or correct the lines to match what you built) and run the seed command twice to prove it is idempotent.
- Seeder scenario on any ticket → static checks in Step 4b "Seeder scenarios" (#601).

bash ~/.claude/skills/lib/plog.sh IMPLEMENT detect-path done "{simple-fix|openspec}"

---

## Step 2.5 — Detect verification re-run

Count all `### {date} — Verification FAIL` entries in `notes.md`. Count all `## Verification #` sections in the plan artifact (`simple-fix.md` or openspec `tasks.md`).

- **If `FAIL_COUNT` = 0** → gate skipped (no brief expected). Proceed to Step 3.
- **If `FAIL_COUNT` <= `SECTION_COUNT`** → all failures already addressed. Proceed to Step 3.
- **If `FAIL_COUNT` > `SECTION_COUNT`** → unaddressed failures remain: this is a rework entry. Read `references/rework.md` (load condition above), then run its integrity check, failure processing and Part B, in that order, before Step 3.

Moved to `references/rework.md` (the REMEDIATION_BRIEF integrity check with its `REMEDIATION_BRIEF_TRUNCATED` gate-stop, the `## Verification #{N+1}` append to the plan and the notes.md re-run entry), read per "Reference files (load condition)" above.

### Part B — Extract REMEDIATION_BRIEF from the Verification section

Moved to `references/rework.md` (the debugger overlay re-run with `--remediation`, the Rework rule, the REMEDIATION_BRIEF heading table and the UAT Rework Context block), read per the same condition. Its persona selector call reuses the `PERSONA_TYPE` Step 2 printed.

---

## Step 3 — Checkout and branch (worktree)

bash ~/.claude/skills/lib/plog.sh IMPLEMENT checkout-branch start "Creating worktree"

Branch variables are injected by the router via the env file (`$TICKET_BRANCH`, `$BASE_BRANCH`,
`$INTEGRATION_BRANCH`, `$WORKTREE_ROOT`). Source it and the worktree library before checkout:

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
source "$HOME/.claude/skills/lib/worktree.sh"
```

For each affected repo, create an isolated git worktree instead of checking out in the shared clone:

```bash
WORKTREE_PATH=$(ensure_worktree "$TICKET_ID" "{repo-path}" "$TICKET_BRANCH" "$BASE_BRANCH")
```

This creates the worktree at `$WORKTREE_ROOT/{repo-slug}`. It is idempotent — on resume, it returns the existing path without touching files. If the worktree exists on a different branch, it fails loudly (identity guard — no silent re-checkout).

Do NOT `cd` into the shared clone. All subsequent git operations (`git diff`, `git add`, `git commit`, `git push`) run inside the worktree at `$WORKTREE_PATH`.

Append to `notes.md`:
```markdown
### {today's date} — pre-implementation checkpoint
- Repos: {list} | Branch: {TICKET_BRANCH} | Worktree: {WORKTREE_PATH} | Mode: {simple-fix | openspec: <name>}
```

bash ~/.claude/skills/lib/plog.sh IMPLEMENT checkout-branch done "{TICKET_BRANCH}"

---

## Step 4 — Implement

bash ~/.claude/skills/lib/plog.sh IMPLEMENT implement start "Implementing changes"

**Navigate (both modes):** Grep to locate, then Read confirmed targets only. Never scan whole files.

**Before editing, run GitNexus blast radius:** Call `mcp__gitnexus__impact` on each target symbol from the plan. Compare the result's d=1 (WILL BREAK) callers against the affected files listed in the plan. If any d=1 symbol is NOT in the plan, append it to the implementation scope. If GitNexus is unavailable, log a warning and proceed — never block on it.

**ADR gate:** the plan's approach was vetted at appraise-exec. If the work turns out to need a different system-level approach (one that constrains other components or future work, not a local detail), invoke the gate per preamble § 8 before committing to it.

### Simple-fix mode

Work through each change in `simple-fix.md` in order. **As each acceptance criterion is verified, check off its box in the `## Completion Checklist` section of `simple-fix.md`** (`- [ ]` → `- [x]`) before moving on to Step 4b.
`return-completeness-check.sh` reads these boxes directly and reports `RETURN_INCOMPLETE` for any left unchecked — even when the underlying work is fully done and verified.

### Openspec mode

Spawn a `general-purpose` agent to apply the change and return a difficulty summary. The worktree is already created at `$WORKTREE_PATH` — all edits happen there.

**Prompt the agent with:**
```
Apply the openspec change `{change-name}` by running `/opsx:apply` in the worktree at `{WORKTREE_PATH}`. Follow its instructions fully.

Locate code with Grep, then Read confirmed targets only — never scan whole files. Before starting edits, run GitNexus `impact()` on target symbols to map blast radius.

Track these metrics as you work:
- fix_cycles: how many times did you need to fix and re-run tests?
- discovery_rounds: how many rounds of unexpected investigation beyond the plan were needed?
- plan_deviation: "followed" (as-written) | "adapted" (one step changed) | "rewrote" (approach changed)
- changes_made: list of "file:line — what changed" entries

When complete, return ONLY this JSON (no other text):
{
  "fix_cycles": N,
  "discovery_rounds": N,
  "plan_deviation": "followed|adapted|rewrote",
  "changes_made": ["file:line — what changed"],
  "notes": "anything unexpected encountered"
}
```

**Save the returned JSON as `{DIFFICULTY_SUMMARY}` — Step 4c uses it.**

bash ~/.claude/skills/lib/plog.sh IMPLEMENT implement done "{N} files changed"

---

## Step 4b — Write tests + run tests + code review (mandatory for all modes)

### Write unit tests

**After implementation is complete, write tests covering the changed logic.** This is mandatory — do not skip.

- **If `{BE_TEST_CMD}` is defined and the ticket touches a BE repo:** Write tests in the repo's test directory. Create `tests/` if it doesn't exist. Test any new or modified functions/methods, including error paths. Install the test framework if needed (e.g. `pip install pytest`). Use `{BE_TEST_RUNNER}` as the test invocation if defined (e.g., `~/.pyenv/versions/3.13.12/bin/pytest`), otherwise fall back to `{BE_TEST_CMD}`.
- **If `{FE_TEST_CMD}` is defined and the ticket touches a non-BE repo:** Write tests alongside the changed files or in `__tests__/`. Test new or modified components, API routes, and utility functions. Install the test framework if needed.
- **If neither is defined:** Skip all tests. Do not invent or install a test framework. Note "no test command configured" in the session log and move on.
- **DB migrations:** If the change includes a migration, write a test that verifies the new schema (column exists, index exists, constraint works).

### Refinement test candidates

If `{ticket-dir}/notes.md` has a `### Test candidates` sub-section under `## Refinement Carry-over` (written by ticket-appraise from the planner's Refinement phase — one line per `MISSING_CORE_AC` gap, with the quote and the behaviour the gap names), list them:

```bash
awk '/^## Refinement Carry-over/{on=1; next} on && /^## /{exit} on && /^### Test candidates/{tc=1; next} tc && /^### /{exit} tc && /^- /' "{ticket-dir}/notes.md"
```

**Every candidate must end as a test or a recorded reason** — never silently dropped:

- **Add a test** covering the named behaviour, alongside the tests above, when the behaviour is in this ticket's scope and a test command is configured.
- **Otherwise record why not**: append one line per candidate to notes.md under `## Session Log`, naming it by its `(candidate <key>)` suffix — e.g. `- Test candidate f-0123456789ab not tested: out of scope for this change (belongs to the export service)` or `… not tested: no test command configured`.

A candidate is a gap Refinement found, not an accepted acceptance criterion: do not widen the implementation to satisfy one, and do not treat an untestable one as a blocker. `ticket-verify` re-checks each candidate as a non-failing `carry-over` check. No `### Test candidates` sub-section → skip this.

### Run tests

bash ~/.claude/skills/lib/plog.sh IMPLEMENT run-tests start "Running tests"

```bash
# BE repos (only if BE_TEST_CMD is defined)
# BE_TEST_RUNNER takes precedence over BE_TEST_CMD for pyenv/pipenv environments
# where the bare command (e.g. "pytest") is not on PATH.
_test_cmd="{BE_TEST_RUNNER:-{BE_TEST_CMD}}"
cd {WORKTREE_PATH} && $_test_cmd

# FE repos (only if FE_TEST_CMD is defined)
cd {WORKTREE_PATH} && {FE_TEST_CMD}
```

If tests fail → fix the code or the tests, re-run. Do not proceed until all tests pass. Skip a test command only if its corresponding variable is not defined in CLAUDE.md.

bash ~/.claude/skills/lib/plog.sh IMPLEMENT run-tests done "Tests pass"

### Code review

bash ~/.claude/skills/lib/plog.sh IMPLEMENT code-review start "Reviewing changes"

Spawn a `general-purpose` agent for each repo with changes. Pass it:
- The worktree path and branch name
- The list of changed files (`git -C "$WORKTREE_PATH" fetch origin "$BASE_BRANCH" --quiet 2>/dev/null; git -C "$WORKTREE_PATH" diff --name-only "${BASE_REF:-origin/$BASE_BRANCH}"` — always the remote base ref: a stale local epic ref would attribute earlier tickets' commits to this one)
- The ticket ID and a one-sentence description of what was implemented
- This exact instruction: **Invoke `Skill("superpowers:requesting-code-review")` — use the Skill tool with this exact name. Do NOT use any other review tool, plugin, or slash command.**

The agent returns a findings list, each tagged with a severity. **Only `medium` severity and above are blockers** — `low`-severity findings (style preferences, naming opinions) never gate the commit.

This fix-and-re-review loop is **capped at 3 cycles**, tracked with a `cycle#N` counter on the log line:

- Cycle 1: spawn the agent. If there are no medium+ findings, the review is clean — stop here.
- If medium+ findings exist and `cycle < 3`: fix each one, re-run unit tests, re-spawn the agent with the updated file list as the next cycle.
- If medium+ findings still exist at `cycle == 3`: gate-stop and stop — do not commit:
  ```bash
  bash ~/.claude/skills/lib/plog.sh IMPLEMENT code-review fail "cycle#3 CODE_REVIEW_EXHAUSTED"
  bash ~/.claude/skills/lib/plog.sh META gate-stop fail "CODE_REVIEW_EXHAUSTED"
  ```
  This ticket needs human review.

Do not commit until the review is clean or the loop gate-stops. At a clean exit, append residual low-severity findings to notes.md under `## Code Review — Deferred Findings` (create if absent), one `- {file}:{line} — {finding summary}` line each; they never block.

bash ~/.claude/skills/lib/plog.sh IMPLEMENT code-review done "cycle#{N} clean"

**Seeder scenarios (#601).** If the ticket ships one (`seed.sh <scenario>`, `Seed command:`, a diff under `$WIKI_ROOT/api/_tools/seed/`), check every request it makes against the OpenAPI contract (path, method, param min/max, required fields) and that a re-run takes its "already exists" paths. Do not start or reset the shared stack: VERIFY Step 1.6d runs it twice on its clean baseline before any criterion.

---

## Step 4c — Rate actual complexity and update Linear label

Assign an outcome label based on implementation difficulty:

| Label | Criteria |
|---|---|
| `Smooth` | Plan was accurate, followed without deviation, tests passed first run, no extra discovery needed |
| `Rough` | 1–2 fix cycles needed, or minor gaps required small additional investigation |
| `Hard` | Multiple fix/test cycles, significant extra discovery, or the plan was materially incomplete |

Rate from `{DIFFICULTY_SUMMARY}` (openspec) or in-context history (simple-fix). Take the worst signal: fix cycles (0/1–2/3+ → Smooth/Rough/Hard), discovery rounds (none/minor/significant), plan deviation (followed/adapted/rewrote).

**Update Linear:**

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} implement-outcome --data outcome={Smooth|Rough|Hard}
_rc=$?
# flow-run.sh has already logged any non-zero exit (META|flow-error + heartbeat).
# implement-outcome carries no verdict_gate, so exit 11 cannot occur; a failure is non-fatal — continue.
# flow.sh's implement-outcome trigger itself writes the dedicated
# IMPLEMENT|implement-outcome|info| entry that outcome-label-check.sh reads —
# so the Linear label and the pipeline log can never drift apart. No manual
# log write needed here.
```

### Post-implement: Record verifier result (Phase 0 RLVR)

After writing the implement-outcome, source and call write_verifier_result:
```bash
source ~/.claude/skills/lib/verifier-result.sh
write_verifier_result verifier=implement_tests verdict=<PASS|FAIL> outcome=<Smooth|Rough|Hard> corrections=<N> phase=IMPLEMENT
```
Map test results: all pass → PASS, any fail → FAIL. Pass outcome and corrections count.

**Mismatch retrospective (only if prediction and outcome disagree):**

A mismatch means the appraisal missed something. When `simple` + `Rough`/`Hard`, or `complex` + `Smooth`:

Moved to `references/feedback.md` (the Linear mismatch comment, the claude-mem feedback memory, and why this is scoring feedback for Part 4's `source=appraise`/`source=exec` CORRECTIONS block, not wiki knowledge), read per "Reference files (load condition)" above.

### Part 3 — Wiki errata (always checked — never gated on complexity mismatch)

Check notes.md for a `Wiki bootstrap:` line under Initial Investigation (written by
`ticket-appraise` Step 3a when it loaded a wiki flow file for this ticket). If no such line
exists, skip this Part entirely — there is nothing wiki-sourced to check.

If the wiki was consulted, ask independently of the mismatch check above: **did anything the
wiki said turn out wrong, stale, or missing during implementation?** A wrong class name, a
Feign client the flow didn't mention, an entity field the wiki didn't document, a call-chain
step that no longer matches the code — any of these counts, on any outcome label, `Smooth` included.

- **No gap found:** log `META|wiki-check|info|wiki consulted, no gap found` (via `$TAP_LOG`
  when `--from-auto`) and move on. Nothing to write.
- **Gap found:** read the feedback reference (load condition above), then write the errata entry and the `source=wiki` correction it describes.

Moved to `references/feedback.md` (the errata entry in `wiki-maintenance`'s `Gap:`/`Fix:` schema, which wiki file to append it to, and the unconditional `source=wiki` correction), read per the load condition above.

### Part 4 — Write CORRECTIONS to notes.md

Two independent triggers write to the same CORRECTIONS block in notes.md, so downstream skills
(`ticket-document`, `wiki-maintenance`, `ticket-retro`, `ticket-prescan`) can feed the signal
back into their own artifacts:

- **Complexity mismatch** (outcome label disagrees with prediction) → `source=appraise` or
  `source=exec`, per the mapping table in the feedback reference.
- **Wiki gap found in Part 3** → `source=wiki`, whatever the outcome label.

Moved to `references/feedback.md` (the outcome-vs-prediction source mapping table and the two `append_correction` blocks), read per the load condition above.

A failed correction write logs a `corrections-error` warning and **never halts** the implement phase.

---

## Step 5 — Commit and push

bash ~/.claude/skills/lib/plog.sh IMPLEMENT commit-push start "Committing and pushing"

**No-diff check first.** Pass every affected repo's worktree. When none of them has a
source change (no uncommitted or untracked non-ignored file, and no commit ahead of the
base), the script writes `IMPLEMENT|commit-push|skip|…` and exits 4 — the line
`ticket-pr-review` keys its no-diff exemption on (a verification-only ticket has no PR):

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
bash "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/implement-diff-check.sh" \
  --base-ref "origin/${BASE_BRANCH:-develop}" --log-file "$TAP_LOG" \
  "$WORKTREE_PATH" # one argument per affected repo's worktree
_idc_rc=$?
```

- `_idc_rc=4` → nothing to commit or push. Skip the rest of Step 5 (no commit, no push, no
  `commit-push|done` line) and append to `notes.md`: `### {today's date} — no source diff`
  `- Verification-only: nothing committed`. Continue to Step 5.5.
- `_idc_rc=0` → commit and push as below.
- `_idc_rc=2` → a worktree path is wrong. Resolve it again (Step 4) and re-run the check;
  never skip the commit on rc 2.

An unresolvable base ref counts as a diff, so the skip line is only written on positive
evidence that there is nothing to ship.

For each affected repo:
1. Run `/commit-commands:commit` from the worktree (`cd "$WORKTREE_PATH"` first).
2. **Pre-push safety check — GitNexus `detect_changes`:** The worktree is a full git checkout — `detect_changes` operates on the branch, not the filesystem path.
   - **Branch verification first (#359):** call `mcp__gitnexus__list_repos`, find the entry for this repo, and read its `lastCommit`. Then run:
     ```bash
     source "$HOME/.claude/skills/lib/gitnexus-preflight.sh"
     gitnexus_verify_branch "$WORKTREE_PATH" "{lastCommit}" "HEAD"
     ```
     (Run from `$WORKTREE_PATH`: `HEAD` is the branch you're about to push. `list_repos`' `commitsBehind` is measured against the indexed clone's checkout, not this branch.) `ok <n>` (exit 0) means verified — proceed to `detect_changes`. `wrong-branch`/`ahead <n>`/`stale <n>` (exit 1) or `unresolvable <reason>` (exit 2) mean unverified — skip `detect_changes`, log a warning, and proceed without it (never block the push on GitNexus).
   - Only once verified: call `mcp__gitnexus__detect_changes` with `scope: "compare"` and `base_ref: "$BASE_BRANCH"`.
   - **Sanity-check the result (#359):** compare the affected-file list against `git -C "$WORKTREE_PATH" diff --name-only "$BASE_BRANCH"...HEAD` (one path per line each) via `gitnexus_check_result_subset "$RETURNED_FILES" "$KNOWN_DIFF_FILES"`. A non-subset result (exit 1) means the structural diff named files outside this branch's actual changes — discard it, log a warning, and proceed without it.
   - If the result shows `risk_level: "high"` or `"critical"`, OR affected execution flows outside the ticket's stated scope: append a warning to the handoff output.
   - If GitNexus is unavailable, unverified, or the result fails the subset check: log a warning and proceed — never block on it.
3. Push from the worktree: `git -C "$WORKTREE_PATH" push origin {branch-name}`

### Commit title template

`type(TICKET-ID): imperative-mood description`, type one of `feat`, `fix`, `refactor`, `chore`
(tooling, deps, config). The ticket ID is **mandatory**, e.g. `fix(WIL-35): add SSE log replay buffer`.

**Append to `notes.md`:**
```markdown
### {today's date} — committed
- Branch: `{branch-name}` on {repo}
- Pushed — awaiting verification before PR
```

**Report:**
```
## {TICKET-ID} committed

Branch: `{branch-name}` pushed to {repo}.
```

No PR created yet. No Linear state change. The calling pipeline (`ticket-auto` or user) handles verification and PR creation.

bash ~/.claude/skills/lib/plog.sh IMPLEMENT commit-push done "Pushed {branch-name}"

---

## Step 5.5 — Plan artifact durability check

Backstop for #363: an openspec plan artifact must be committed in the tickets repo, not merely on
disk (appraise-exec Step 3.4 commits it, but a resumed exec can skip that). Resolve against
`$IMPLEMENT_TICKETS_ROOT`, not CWD:

```bash
EXPECT_FLAG=""
# Re-derive the mode (simple-fix.md found → simple-fix, else openspec) rather than trust carried state.
bash ~/.claude/skills/lib/ticket-dir.sh plan "{TICKET-ID}" --root "$IMPLEMENT_TICKETS_ROOT" --type simple-fix >/dev/null 2>&1 || EXPECT_FLAG="--expect"
bash ~/.claude/skills/lib/openspec-tracking-check.sh assert "{TICKET-ID}" $EXPECT_FLAG --root "$IMPLEMENT_TICKETS_ROOT"
ASSERT_RC=$?
```

- **Exit 0** (`tracked`, or `not-applicable` for a simple-fix ticket) — proceed silently to Step 6.
- **Non-zero** — the change dir is `gitignored`, `untracked`, `partial`, or (with `--expect`)
  `missing` entirely. **Warn loudly — never gate-stop.** The implementation itself is unaffected;
  losing the design rationale is a documentation-durability problem, not a correctness one.
  ```bash
  bash ~/.claude/skills/lib/plog.sh META gate-warn info "OPENSPEC_ARTIFACT_UNTRACKED — plan artifact for {TICKET-ID} is not durably tracked in the tickets repo"
  ```
  Append to `notes.md`:
  ```markdown
  ### {today's date} — plan artifact durability warning
  - ⚠️ openspec change for {TICKET-ID} is not durably tracked in the tickets repo (status:
    {OPENSPEC_TRACK_STATUS from the assert output}). It is one `git clean` from loss. Fix with:
    `bash ~/.claude/skills/lib/openspec-tracking-check.sh commit "{CHANGE_DIR}" "{TICKET-ID}"`
    from the tickets repo root.
  ```
  Include the same warning in the final report (Step 5's report block, above). Continue to Step 6.

---

## Step 6 — Emit the PHASE_RESULT block (--from-auto only)

IMPLEMENT is a loop-bearing phase: the router decides whether to advance or re-implement
partly on what you report, and today that requires a model to read your prose.

End your return with the `=== PHASE_RESULT ===` block described in **§ 6 Phase result
emission** of the auto preamble, with `PHASE: IMPLEMENT` and `VERIFIER: implement_tests`.
Map `VERDICT` from Step 4b's test results: all pass → `PASS`, any fail → `FAIL`, blockers
still open after the code-review loop → `BLOCK`. Use `CRITERIA_MET`/`CRITERIA_TOTAL` for
the artifact's completion checklist (openspec `tasks.md` boxes, or simple-fix.md's
Completion Checklist), and `UNADDRESSED` for any task you did not complete.

**Emit whether you succeeded or not.** A run that aborted before pushing still reports —
that is exactly the case where the router's only other evidence is prose. Nothing goes
after the closing marker.
