---
name: ticket-verify
description: Verifies a Linear ticket fix by loading its requirements, then navigating the live app via Playwright (browser tickets), running the project's build tooling (build-only tickets — e.g. parent-POM/dependency-management changes with no UI or API surface), or checking a running backend directly via health/API calls (live-backend tickets — e.g. service registration, circuit breaker behaviour — a live system with no UI to click), reproducing the original issue steps, and confirming the fix works. Produces a structured pass/fail report. On failure, emits a REMEDIATION_BRIEF that can be fed directly to ticket-implement or a fix skill. Use when the user says "/ticket-verify {ID}", "verify ticket {ID}", "test ticket {ID}", or "check if {ID} is fixed". Accepts optional --user, --password, and --env flags.
---

# Ticket Verify

You have been given a ticket ID as the argument (e.g. `CRE-39`), with optional flags:
- `--user <email>` — login email override. If omitted, derived from the ticket description.
- `--password <password>` — login password override. If omitted, resolved from the `UAT_TEST_PASSWORD` environment variable, else the `UAT_TEST_PASSWORD` field in `./CLAUDE.md` (see Step 1b5). There is no built-in default password. On local, the login gate is typically bypassed.
- `--env local|uat` — which environment to test against (default: `local`)
- `--from-auto` — called by ticket-auto or batch. Suppresses all user prompts.
  Missing credentials or nav failures produce a diagnostic FAIL instead
  of asking the user.
- `--no-env-start` — skip Step 1.6 (don't start/check backend services).
  Use when managing the environment manually.

Parse the arguments before proceeding.

**Environment URLs:**
- `local` → Read `LOCAL_URL` from `./CLAUDE.md`. If absent, abort: "No LOCAL_URL configured for this project."
- `uat` → Read `UAT_URL` from `./CLAUDE.md`. If absent, abort: "No UAT_URL configured for this project."

**Credential derivation (UAT only):** If `--user` is not explicitly provided, extract it from the ticket description after Step 1b. If `--password` is not provided, resolve it from configuration (Step 1b5) — never assume a default. On local, credentials are typically not needed.

This skill never modifies source code.

**Secrets rule:** a password is only ever typed into the login field. Never write it into a Linear comment, PR body, pipeline/heartbeat log line, verification plan, report, REMEDIATION_BRIEF, notes.md or any other file, and never `echo` it in a bash block.

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=VERIFY, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_GUARD=true, HAS_PROJECT_CONTEXT=false, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=false

When `--from-auto` is present, VERIFY is a loop-bearing phase: additionally follow **§ 6 Phase result emission** in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: EMITS_PHASE_RESULT=true, PHASE_RESULT_TIER=1, PHASE_RESULT_VERIFIER=<this run's actual verifier — `playwright_uat` in browser mode, `build_only` when `VERIFY_MODE=build-only`, `live_backend` when `VERIFY_MODE=live-backend`>, PHASE_RESULT_ATTEMPT=<the `PHASE_RESULT_ATTEMPT=` value in your spawn INSTRUCTIONS; omit the ATTEMPT field entirely if you were not given one>. The block grammar lives there and in `docs/phase-result-schema.md`; it is never restated here.

### Heartbeat points
Event catalogue: [pipeline-heartbeat-format.md](../../pipeline-heartbeat-format.md). Write with `hb-wrap.sh`:
- after starting Playwright: `api "browser-session" "ok" "browser session established"` (or `"fail" "browser session failed"`)
- after each navigation: `api "browser-navigate" "ok" "navigated to <url>" '{"url":"...","title":"..."}'`
- on a lost-and-resumed session: `fallback "browser-resume" "fired" "session lost, rebuilding plan" '{"reason":"Playwright session lost"}'`
- before each criterion (advisory): `heartbeat "step-progress" "ok" "verify: criterion N of M" '{"step":"execute-steps","done":"N","total":"M"}'`
- after the verdict: `decision "verification-verdict" "fired" "PASS|FAIL" '{"verdict":"PASS|FAIL","criteria_met":"N","criteria_total":"M"}'`

### Step dispatch
**Important:** Steps `browser-session`, `navigate`, and `execute-steps` depend on a live Playwright session that is lost when the server crashes. If `--from-step` is one of these values, fall back to `build-plan` instead — always re-run browser steps from scratch. This does not apply in build-only or live-backend mode: neither has a browser session to lose, so an `execute-steps` resume in either mode re-enters its Step 4c variant (4c build-only, 4c-live live-backend) at the next unchecked criterion, not `build-plan`. Any value not in the table below (e.g. setup steps `seed-apply`, `verify-lock`) means start at Step 1. Any resume past Step 1.6 (`build-plan`, or a 4c/4c-live `execute-steps` re-entry) first runs the 1.6a3 lock block unless this run skips 1.6; a dead attempt's orphaned lock for this ticket is taken over.

| `--from-step` value | Effective skip to | Restore from |
|---------------------|-------------------|--------------|
| `load-context` | **Step 1** (start over) | Step 1.6 (lock, env, seeds) runs after it |
| `build-plan` | Step 3, after the 1.6a3 lock block | re-run Steps 3+ in full |
| `browser-session` | **falls back to `build-plan`** | browser state lost on crash |
| `navigate` | **falls back to `build-plan`** | browser state lost on crash |
| `execute-steps` | **falls back to `build-plan`** (browser); Step 4c / 4c-live (build-only / live-backend, after reading `references/build-only.md` / `references/live-backend.md` per Step 1f) | browser state lost on crash |
| `checkpoint` | treated as `execute-steps` (so `build-plan` in browser mode) | older routers only |

**Checkpoint resume (deterministic).** Which criteria already passed is never inferred
from memory or prose. At the start of the criterion loop (Step 4b / 4c / 4c-live), run:

```bash
VERIFY_CHECKPOINT=$(bash "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/verify-checkpoint.sh" "$TAP_LOG" 2>/dev/null) || VERIFY_CHECKPOINT=""
```

It prints the highest `N` with a `VERIFY|checkpoint|done|criterion-N-pass` line in the
**current attempt only**: after the last verdict, re-implement or operator stop/reset. Only
an unattended crash keeps earlier passes. The router also receives the same value as
`VERIFY_CHECKPOINT` from `detect-resume.sh`.

- Build-only and live-backend mode: if `VERIFY_CHECKPOINT` is a number `N`, record criteria
  1..N as PASS (`resumed from checkpoint`) and start at criterion `N+1`. If it is empty,
  start at criterion 1.
- Browser mode: ignore `VERIFY_CHECKPOINT` and verify every criterion.

---

## Step 1 — Load ticket context

### 1a — Load app knowledge and navigation hints

Read both knowledge sources before fetching the ticket:

```bash
cat "$HOME/.claude/skills/app-knowledge/SKILL.md"
```

Then load the project nav hints (read the file directly — this agent has no Skill tool, and Step 2a reads the same file):

```bash
cat "{TICKETS_ROOT}/nav-hints.md" 2>/dev/null || echo "(no nav-hints.md yet)"
```

`app-knowledge/SKILL.md` contains business rules, role-based UI behaviour, state mappings, and navigation patterns confirmed across sessions. Use it to interpret what you see in Playwright snapshots and to derive correct navigation without guessing.

`nav-hints.md` holds area → click-path mappings learned during previous ticket verification and reproduction sessions. **Never use direct URLs for in-app navigation** — always click through the UI because Angular loses session state on full page reload.

### 1b — Fetch from Linear

Call the Linear access strategy to fetch the ticket (bash `get_issue` when `LINEAR_API_KEY` is set, MCP `get_issue` fallback otherwise).

Capture:
- `title`, `description`, `status`, `labels`, `url`

Parse the description for the following sections (they may use any heading style):
- **Steps to Reproduce** — numbered list of user actions
- **Expected Behaviour / Acceptance Criteria** — what "working" looks like
- **Actual Behaviour / Bug** — what was broken

If these sections are not explicitly labelled, infer them from context.

### 1b4 — Refuse UAT verification under epic UAT policy

The epic branch is not deployed to UAT until the epic's integration PRs merge, so a UAT result for one child of an epic with `UAT Policy: epic` is meaningless, and without this guard `uat-pass` would close it straight to `Done` (the second UAT decision site):

```bash
bash ~/.claude/skills/lib/uat-policy-guard.sh "{TICKET-ID}" --env {env}
```

Exit 0: continue (always for `--env local`). Exit 3: refused — the script has printed why and logged `uat-policy-guard|skip`; stop here. **No state transition occurs** and `uat-pass` is NOT fired.

### 1b5 — Derive credentials (UAT only)

Skip this step if `--env local` is set.

If `--user` was provided, use it. If `--password` was provided, use it. Otherwise:

1. Scan the ticket `description` for an email address matching typical test users (e.g. `user@example.com`). The ticket description often contains a `**User:**` field or an inline mention like "Log in as X (email)".
2. If found → `derived_user = email`. Resolve `derived_password` (only when `--password` was not passed) from configuration — env first, then the project CLAUDE.md field — without printing it:
   ```bash
   source "$HOME/.claude/skills/lib/claude-md-field.sh"
   _uat_pw="${UAT_TEST_PASSWORD:-$(claude_md_field ./CLAUDE.md UAT_TEST_PASSWORD 2>/dev/null || true)}"
   [ -n "$_uat_pw" ] && echo "UAT test password: configured" || echo "UAT test password: NOT configured"
   ```
   If it is not configured and `--password` was not passed: with `--from-auto`, abort with a FAIL verdict (skip to Step 7 with WHAT_FAILED = "No UAT test password configured — set UAT_TEST_PASSWORD or pass --password"); otherwise ask the user for `--password`. Do not post this to Linear — it is a host configuration gap, not a ticket gap.
3. If an email is found but `--user` was also passed → `--user` takes precedence.
4. If an email is found but `--password` was also passed → `--password` takes precedence.
5. If no email found in the description:
   - **If `--from-auto`** → post a comment to the Linear ticket:
     ```
     ⚠️ Cannot verify: no user found in ticket description. Please add the test user email to the ticket (e.g. "**User:** user@example.com").
     ```
     Then abort with a FAIL verdict (skip to Step 7 with WHAT_FAILED = "No test user email in ticket description").
   - **Otherwise** → ask the user: "No user email found in the ticket. Which user should I log in as? (provide --user <email>)"
6. Record the derived credentials for Step 3.

### 1c — Load local workspace

```bash
find "$TICKETS_ROOT" -type d -name "{TICKET-ID}*"
```

If found, read:
- `context.md` — extra reproduction detail; an appraisal-time snapshot (of `body.md` for `planned` tickets). Pipe the Step 1b description into `bash ~/.claude/skills/lib/ac-drift.sh {ticket-dir} --tag VERIFY --log-file "$TAP_LOG"`: on exit 1 (AC drift) number the plan from the Linear list (#604).
- `notes.md` — the fix summary and UAT notes from implement
- `artifacts/` — playwright scripts, test plans or snapshots from implement

If not found, continue — the Linear description alone is sufficient.

### 1d — Load openspec change (if present)

```bash
bash ~/.claude/skills/lib/ticket-dir.sh plan "{TICKET-ID}" --root "$TICKETS_ROOT" --type openspec
```

This is the one plan-artifact resolver (whole-ID match, so `TEST-7` never picks up `TEST-77`'s
change). If it exits 0, read `tasks.md` at `PLAN_PATH` to understand what was implemented and any "Manually verify" tasks — these become your verification checklist.

### 1e — Detect verification mode (browser vs. build-only vs. live-backend)

Some tickets are verified by running build tooling (no UI or API surface: a parent-POM, a dependency bump), some by checking a running backend through health/API calls (service registration, circuit breakers: no login, no page), and the rest in a browser. Treating one as another gives a silent false-pass or a stall. `lib/verify-mode.sh` classifies the ticket from its plan and `context.md`; live-backend is tested before build-only, so a passing mention of `mvn` never hides a runtime check. It writes the `load-context` log line itself:

```bash
bash ~/.claude/skills/lib/verify-mode.sh "{TICKET-ID}" --ticket-dir "{ticket-dir}" --root "$TICKETS_ROOT"
```

Record the printed `VERIFY_MODE` for the rest of this skill. `browser` (the default) runs every step. `build-only` skips Step 1.6, 1.7a/1.7b and Steps 3, 4 and 4b, and runs Step 4c instead. `live-backend` runs Step 1.6 (a real system must be up) but skips 1.7a/1.7b and Steps 3, 4 and 4b, and runs Step 4c-live instead. Steps 2, 6 and 7 carry per-mode variants. The REMEDIATION_BRIEF and reports keep their field names in every mode (Step 7a maps the diagnostics).

### 1f — Mode reference (load condition)

**If `VERIFY_MODE=build-only`**, run `bash ~/.claude/skills/lib/skill-ref.sh ticket-verify references/build-only.md`; **if `VERIFY_MODE=live-backend`**, run `bash ~/.claude/skills/lib/skill-ref.sh ticket-verify references/live-backend.md`. Do this before Step 2, and before re-entering Step 4c or 4c-live on a `--from-step` resume (`build-plan`, `execute-steps` or `checkpoint`), then Read the printed path in full. Do not continue until you have read it. If `skill-ref.sh` exits non-zero, run `bash ~/.claude/skills/lib/plog.sh META reference-missing fail "references/${VERIFY_MODE}.md"` and stop: never run the Step 2 variant, Step 4c, Step 4c-live or their Step 7a diagnostics from memory. In `browser` mode, read neither file.

A `--from-step` resume skips Step 1e, so take the mode from this ticket's latest `load-context` line:

```bash
VERIFY_MODE=$(grep '|VERIFY|load-context|done|' "$TAP_LOG" 2>/dev/null | tail -1 | sed -n 's/.*mode=//p')
```

If that prints nothing, run Steps 1b, 1c and 1e first. After a context compaction, read the mode reference again before continuing any of those steps.

---

## Step 1.5 — Create task tracker

Create a TaskCreate for every remaining step (Steps 2 through 7). Each task subject = the step heading. After each step is fully done, mark it completed with TaskUpdate. At session end, write a trace file to the ticket directory:

```bash
cat > {ticket-dir}/verify-session.md << 'TRACE'
# verify session — {ISSUE-ID}
**Date:** {today}
**Environment:** {env}
**User:** {--user}
**Verdict:** {PASS|FAIL}

## Step trace
- [x] Step 1.6: Env readiness — {env start status}; seed-apply {done N|skip}
- [x] Step 1.7: Verify pre-flight — user:{test_user} nav:{nav_target}
- [x] Step 2: Build verification plan — {N} criteria
- [x] Step 3: Establish browser session — {logged in|already authenticated}
- [x] Step 4: Navigate to feature — {path}, {attempts} attempts
- [x] Step 4b: Execute verification — {N} steps
- [x] Step 5: Evaluate — {PASS|FAIL}
- [x] Step 6/7: Report — {pass report|failure report + REMEDIATION_BRIEF}
TRACE
```

---

## Step 1.6 — Ensure local environment is ready (local only)

Skip entirely if `--env=uat`, `--no-env-start`, or `VERIFY_MODE=build-only` is set. Do **not** skip for `VERIFY_MODE=live-backend`.

Everything from here through Step 5 touches the shared local app stack (fixed ports, no per-run namespacing). Keep the order: GC (1.6a2), lock (1.6a3), then this run's worktree resync (1.6a4, destructive) only under the lock.

### 1.6a — Detect affected backend services

Extract service names from the ticket's notes.md and context.md:

```bash
grep -oP '(?<=microservices/)[a-z][a-z-]+' {ticket-dir}/notes.md {ticket-dir}/context.md 2>/dev/null \
  | grep -v '^gateway-fe$' | sort -u
```

If the ticket dir is not found (no local workspace), affected services = empty (env-start.sh will start all).

### 1.6a2 — Sweep stale verify worktrees

TTL sweep of old verify worktrees (unlocked; never touches this run's):

```bash
source "$HOME/.claude/skills/lib/verify-worktree.sh"
# Fresh shell: without REPOS_ROOT the sweep would target ./.verify-worktrees.
verify_env_init "{TICKET-ID}" ./CLAUDE.md && verify_worktree_gc
```

Worktrees are not torn down at the end of a run; only this sweep reaps them (rules in `lib/verify-worktree.sh`).

### 1.6a2b — ADR gate check

**This runs before the lock in 1.6a3, never after**, so a parked run never holds the lock. If
the plan/diff under test surfaces an architectural decision candidate with no governing ADR,
invoke the gate now (§ 8 ADR gate in the shared preamble). `CREATED_PROPOSED` or
`SUPERSEDE_REQUIRED` emits the human hold here; `CONFLICT` emits the `ADR_CONFLICT` gate-stop
here. With no candidate (the common case), go to Step 1.6a3.

### 1.6a3 — Acquire the single-flight verify lock

Only one verify app stack is ever up at a time; a concurrent request queues:

```bash
source "$HOME/.claude/skills/lib/verify-lock.sh"

if ! verify_lock_acquire "{TICKET-ID}"; then
  bash ~/.claude/skills/lib/plog.sh VERIFY verify-lock fail "timed out waiting for the app-stack lock"
  echo "ticket-verify: could not acquire the single-flight verify lock — see the diagnostic above for who currently holds it. Retry later." >&2
  exit 1
fi
bash ~/.claude/skills/lib/plog.sh VERIFY verify-lock done "acquired"
```

Timeouts and the crash backstop live in `lib/verify-lock.sh`. **Release the lock on every exit path**: first action of Step 5, and at every earlier exit — Step 1.6b's `env-start.sh` failure and served-checkout gate-stops, Step 1.6c's seed-apply failure, Step 1.6d's seeder-precheck failure (the helper releases it), Step 1.7a's "no test user found" SKIP exit, and Step 7 (Steps 3b/4 reach it without Step 5). `verify_lock_release` is idempotent.

### 1.6a4 — Resolve isolated worktrees for affected repos

With the lock held, resolve/resync this run's own worktree per affected repo (destructive on reuse), so the stack serves this ticket's branch rather than whatever the shared clone holds:

```bash
source "$HOME/.claude/skills/lib/verify-worktree.sh"

# This block is a fresh shell: REPOS_ROOT is resolved here, not inherited.
# Unresolved, every repo below would be skipped and no worktree created — a
# silent "worktrees ready" for a run that serves the primary checkout.
verify_env_init "{TICKET-ID}" ./CLAUDE.md || {
  bash ~/.claude/skills/lib/plog.sh META gate-stop fail "VERIFY_WORKTREE_FAILED — REPOS_ROOT unresolved"
  echo "ticket-verify: REPOS_ROOT could not be resolved — see stderr above." >&2
  verify_lock_release
  exit 1
}

_branch="{the ticket's branch — from notes.md's pre-implementation-checkpoint
  'Worktree:'/branch entry, or branch-resolve.sh's BRANCH_CONTEXT_RESULT for
  this ticket}"

# Affected services from 1.6a; if 1.6a found none, use every repo directory
# directly under REPOS_ROOT that has a .git (mirrors env-start.sh's own
# "no specific services → everything" fallback).
_verify_services="{affected services from 1.6a, or every REPOS_ROOT/*/.git repo}"

_wt_count=0
for _svc in $_verify_services; do
  _repo_path="$REPOS_ROOT/$_svc"
  [ -d "$_repo_path/.git" ] || continue
  _wt=$(ensure_verify_worktree "{TICKET-ID}" "$_repo_path" "$_branch") || {
    bash ~/.claude/skills/lib/plog.sh META gate-stop fail "VERIFY_WORKTREE_FAILED — $_svc @ $_branch"
    echo "ticket-verify: could not prepare an isolated worktree for $_svc on branch $_branch — see stderr above." >&2
    verify_lock_release
    exit 1
  }
  export "$(verify_worktree_env_var "$_svc")=$_wt"
  _wt_count=$((_wt_count + 1))
done

if [ "$_wt_count" -eq 0 ]; then
  bash ~/.claude/skills/lib/plog.sh META gate-warn warn "VERIFY_WORKTREE_NONE — none of '${_verify_services}' is a git repo under ${REPOS_ROOT}; the stack will serve whatever the primary checkouts hold"
fi
bash ~/.claude/skills/lib/plog.sh VERIFY worktree-setup done "${_wt_count} worktree(s) ready for ${_branch}"
```

Each path is exported as `VERIFY_REPO_PATH_<SERVICE>` (e.g. `VERIFY_REPO_PATH_CREDIT_REPORT`), but only for this block's shell — **Step 1.6b re-derives the same values with `verify_worktree_exports` in the shell that runs `env-start.sh`**. `env-start.sh` lives in the consuming workspace, so check whether it reads them:

```bash
if ! grep -q "VERIFY_REPO_PATH" "{TICKETS_ROOT}/env-start.sh" 2>/dev/null; then
  bash ~/.claude/skills/lib/plog.sh META verify-worktree-unwired warn "env-start.sh does not read VERIFY_REPO_PATH_* — branch isolation is partial (worktree checkout is correct; the running app stack may still build from the shared clone) until env-start.sh is updated to consume it"
fi
```

The warning does not block; Step 1.6b's served-checkout check decides.

### 1.6b — Run env-start.sh (BE + FE)

Always start all services including the gateway FE. `env-start.sh` skips anything already running. Every invocation runs in **one** bash block together with `verify_env_init` and `verify_worktree_exports`, which re-export `REPOS_ROOT`, `VERIFY_TICKET_ID` and each `VERIFY_REPO_PATH_<REPO>` from 1.6a4 — a separate block would start `env-start.sh` without them (shell state does not carry over between blocks), and it would serve the primary checkout. `verify_env_init` comes first because `verify_worktree_exports` derives every path from `REPOS_ROOT`: with it unset, the exports come out empty.

**env-start.sh contract** (implemented in the consuming workspace, not this plugin): when `VERIFY_REPO_PATH_<REPO>` is set, build and serve that repo from that path instead of `REPOS_ROOT/<repo>` (every path the script derives from the repo dir, such as a worker dir or an env file, follows it), and restart a service that is already running from a different directory rather than skipping it. Optionally, `env-status.sh` can show which checkout each port serves with `bash "$HOME/.claude/skills/lib/verify-worktree.sh" served <port>...`.

If no specific affected services were detected in 1.6a (or ticket dir missing):

```bash
source "$HOME/.claude/skills/lib/verify-worktree.sh"
verify_env_init "{TICKET-ID}" ./CLAUDE.md || true
eval "$(verify_worktree_exports "{TICKET-ID}")"
bash {TICKETS_ROOT}/env-start.sh
```

If specific affected services were detected and the ticket dir exists, restart only those plus the FE:

```bash
source "$HOME/.claude/skills/lib/verify-worktree.sh"
verify_env_init "{TICKET-ID}" ./CLAUDE.md || true
eval "$(verify_worktree_exports "{TICKET-ID}")"
bash {TICKETS_ROOT}/env-start.sh --restart {affected-services} gateway-fe
```

Block until the script exits. If it exits non-zero, release the verify lock and abort ticket-verify with the script's error — do not proceed to browser:

```bash
source "$HOME/.claude/skills/lib/verify-lock.sh" 2>/dev/null || true
verify_lock_release
```

**Check what is actually served.** `env-status.sh` reports up/down only, not which checkout a process runs from, so a stack serving the primary clone (possibly another ticket's branch) reads green and yields a silent false PASS/FAIL. Once `env-start.sh` succeeds, compare the checkout behind `LOCAL_URL`'s port, and every port in the project's optional `VERIFY_SERVED_PORTS` CLAUDE.md field, with this ticket's verify worktrees. Run this for `live-backend` mode too:

```bash
bash ~/.claude/skills/lib/verify-env-up.sh served-check "{TICKET-ID}" --local-url "{LOCAL_URL}"
```

Exit 0: continue — the port serves this ticket's code (`served-worktree|done`), or the check could not decide and logged a visible `VERIFY_SERVED_UNVERIFIED` gate-warn (no worktree to compare, an unreadable or container-served port). Exit 1: the script wrote a gate-stop (`VERIFY_SERVED_WRONG_WORKTREE`: a port serves a different commit or a dirty checkout of a repo under test), printed how to recover and released the lock; stop. `VERIFY_SERVED_WORKTREE_ENFORCE=false` downgrades the wrong-worktree stop to a gate-warn; `VERIFY_SERVED_WORKTREE_STRICT=true` turns every undecided case into a `VERIFY_SERVED_UNVERIFIED` gate-stop.

### 1.6c — Apply seeds from merged test-data blockers

Before any acceptance testing, load the data this ticket's merged test-data (TD) blockers provide. `lib/seed-apply.sh` owns the rules (which blockers count, the `make <target>` command check, its log lines). Run it in `browser` and `live-backend` modes:

```bash
source "$HOME/.claude/skills/lib/verify-worktree.sh"
source "$HOME/.claude/skills/lib/verify-lock.sh" 2>/dev/null || true
source "$HOME/.claude/skills/lib/events.sh" 2>/dev/null || true
source "$HOME/.claude/skills/lib/seed-apply.sh"
verify_env_init "{TICKET-ID}" ./CLAUDE.md || true
# The seed runs in this ticket's verify worktree: the first (sorted) one
# 1.6a4 created, else REPOS_ROOT itself when no worktree exists.
_seed_wt=$(ls -d "${REPOS_ROOT}"/.verify-worktrees/*/"{TICKET-ID}" 2>/dev/null | sort | head -1)
[ -n "$_seed_wt" ] || _seed_wt="$REPOS_ROOT"
_seed_rc=0
seed_apply "{TICKET-ID}" "$_seed_wt" || _seed_rc=$?
if [ "$_seed_rc" -ne 0 ]; then
  bash ~/.claude/skills/lib/plog.sh META gate-stop fail "VERIFY_SEED_FAILED — ${SEED_APPLY_MSG}"
  if declare -f emit_event >/dev/null 2>&1; then
    emit_event "{TICKET-ID}" gate-held "$(jq -nc --arg r "VERIFY_SEED_FAILED — ${SEED_APPLY_MSG}" '{reason: $r}')" 2>/dev/null || true
  fi
  echo "ticket-verify: test data could not be loaded — ${SEED_APPLY_MSG}" >&2
  verify_lock_release
  exit 1
fi
```

On a non-zero exit, **stop here** (the block has written the `VERIFY_SEED_FAILED` gate-stop, emitted `gate-held` and released the lock). Do not run acceptance testing, and do not write a verify FAIL or a `REMEDIATION_BRIEF`: the fix belongs in the TD ticket's seed target, not this ticket's code. `skip` (no TD blockers) is normal; continue.

### 1.6d — Seeder precheck (#601)

Same modes as 1.6c. The scenarios this ticket's seed-tool commits changed run twice, under the lock, before any criterion. The helper picks and runs them; never run seed commands from ticket text yourself:

```bash
bash ~/.claude/skills/lib/seed-precheck.sh "{TICKET-ID}" "$(ls -d "${REPOS_ROOT}"/.verify-worktrees/*/"{TICKET-ID}" 2>/dev/null | sort | head -1)" --log-file "$TAP_LOG" --release-on-fail
```

`pass`/`skip`/`unavailable` → continue. `fail` (lock released) → skip the criteria, go to Step 7 as a normal FAIL: WHAT_FAILED is `SEED_PRECHECK_MSG`, the REMEDIATION_BRIEF points at that scenario. Its `seed-precheck|fail` line counts no attempt; Step 7's `verify|fail` counts it once.

---

## Step 1.7 — Verify pre-flight (prerequisite resolution)

Before building the verification plan, resolve the test user, navigation target, and expected behavior. This ensures the verify agent has everything needed before launching the browser.

bash ~/.claude/skills/lib/plog.sh VERIFY pre-flight start "Resolving verification prerequisites"

**If `VERIFY_MODE=build-only` or `VERIFY_MODE=live-backend`**: skip 1.7a (test user) and 1.7b (navigation target) entirely — there is no login and no page to reach. Go directly to 1.7c.

### 1.7a — Resolve test user

Use this priority chain (stop at first match):

1. **`--user` flag** — if explicitly passed on the command line, use it verbatim
2. **notes.md `## Verification Readiness` section** — if present, extract the test user from the prerequisite table
3. **context.md `**User:**` field** — if present in the ticket context
4. **Linear ticket description** — scan for `**User:**`, email addresses, or role mentions ("as an attorney", "log in as admin")
5. **`test-users.json` catalog** — resolve the catalog, find a user matching any role mentioned in the ticket. If no specific role is mentioned in the ticket, catalog lookup SHALL return empty (do NOT default to admin — a ticket with zero role mentions is underspecified and should have been blocked earlier in the pipeline)

**If no test user is found:**

- **If `--from-auto`**: abort with FAIL. Do not launch the browser. Post a Linear comment:
  ```
  ⚠️ Cannot verify: no test user found. Resolution chain exhausted — no user in --user flag, notes.md, context.md, ticket description, or test-users.json catalog. Add a test user to the ticket (e.g. "**User:** user@example.com") or provide --user.
  ```
  Write to log:
  ```bash
  bash ~/.claude/skills/lib/plog.sh VERIFY pre-flight fail "No test user found"
  ```
  This is a SKIP exit that does not route through Step 5/6/7 — if Step 1.6a3 acquired the verify lock (browser/live-backend modes), release it explicitly before exiting:
  ```bash
  source "$HOME/.claude/skills/lib/verify-lock.sh" 2>/dev/null || true
  verify_lock_release
  ```
  Exit with SKIP (no failure — the ticket needs human input).

- **If interactive** (no `--from-auto`): prompt the user: "No test user found. Which user should I log in as? (provide --user <email>)"

**If a test user is found**, record it for use in Step 2 and Step 3b.

### 1.7b — Resolve navigation target

Use this priority chain (stop at first match):

1. **notes.md `## Verification Readiness`** — if present, extract the navigation target
2. **nav-hints.md** — match the ticket's feature area against known nav-hints entries
3. **context.md** — scan for URL patterns (`/handover/`, `/admin/`, etc.)
4. **Linear ticket description** — scan for URL patterns or navigation instructions

**If no navigation target is found:**

- **If `--from-auto`**: log a warning but continue. The verifier has a 3-attempt nav budget and can often discover the page from context.
  ```bash
  bash ~/.claude/skills/lib/plog.sh VERIFY pre-flight warning "No navigation target found, will use 3-attempt nav budget"
  ```
- **If interactive**: note the gap in the verification plan but continue (the user can guide navigation in Step 4).

### 1.7c — Pre-populate expected behavior

Check if the plan artifact already has expected behavior (from the `## Verification Readiness` section in notes.md):

1. **notes.md `## Verification Readiness`** — if present, extract expected behavior
2. **Linear ticket description** — extract from acceptance criteria, "Expected Behaviour", or "What should be true" sections

If found in notes.md, use it as the basis for verification criteria in Step 2. If not, extract from the Linear ticket description as normal.

bash ~/.claude/skills/lib/plog.sh VERIFY pre-flight done "User:{test_user} Nav:{nav_target}"

---

## Step 2 — Build the verification plan

**If `VERIFY_MODE=build-only`, skip 2a–2c below and use this variant instead:**

**If `VERIFY_MODE=live-backend`, skip 2a–2c and the build-only variant below and use the live-backend variant instead (after it).**

**Every variant applies Step 2d (carry-over checks) to its plan before printing it**, even the two that skip 2a–2c.

### 2 (build-only variant)

Moved to `references/build-only.md` (module list, build commands and plan template; then Step 4c, skipping Steps 3, 4 and 4b), read per the Step 1f condition.

### 2 (live-backend variant)

Moved to `references/live-backend.md` (running-system checks and plan template; then Step 4c-live, skipping Steps 3, 4 and 4b), read per the Step 1f condition.

---

### 2a — Derive the navigation path

Using the ticket title, labels, description, and context.md, determine where in the app to navigate. Use this priority order:

1. **Explicit URL** — if the ticket description or notes.md contains a path (e.g. `/handover/123`, `/admin/users`), use it. **Only** use it to identify the URL pattern — the actual navigation must still be done via UI clicks (Step 4), never `page.goto()`.
2. **Nav hints** — read `{TICKETS_ROOT}/nav-hints.md` and match the ticket's feature area (e.g. "Handover Payments", "Handover Progress") against known area headings. The hint provides the exact click-by-click path. **Do not use the URL from the hint for `page.goto()`** — use it only to verify you landed in the right place. Always execute the click-by-click steps.
3. **Inference from labels and title** — derive the likely feature area from keywords:
   - "Handover" / "correspondent" → Handover Correspondents
   - "Attorney" / "Legal" → Handover List (Active filter = LEGAL state)
   - "Payment" → Handover Payments (receipt icon on handover row)
   - "Progress" → Handover Progress
   - "Administration" / "User" / "Organisation" → Administration
   - "Credit report" → Credit Report
   - If uncertain, start from the handover list and explore via the action icons

Record the **derived area** and its **source** (explicit / nav-hints / inferred). Include this in the plan.

### 2b — Expand acceptance criteria into atomic items

Before writing the plan, extract every requirement from the ticket description and **expand compound requirements into individual atomic items**. A criterion is atomic if it describes exactly one observable fact that can be independently confirmed in the UI.

Rules for expansion:
- A list with N items → N separate criteria (e.g. "dropdown offers Plaintiff, Defendant, and Attorney" → three criteria, one per type)
- "A and B" in a single sentence → two criteria
- "Only X may be added" → one criterion confirming X is present AND one confirming non-permitted types are absent (if testable)
- Vague phrases like "works correctly" or "is enabled" → replace with the specific observable: element label, disabled/enabled state, visible/absent element

Write out the expanded criteria as a numbered list before proceeding to the plan template. This list becomes the pass criteria verbatim.

### 2c — Write the plan

Construct and print the **Verification Plan**:

```
## Verification Plan — {TICKET-ID}: {title}

**Environment:** {env} ({base URL})
**Test user:** {--user value}
**Navigation path:** {derived path} (source: {explicit|nav-hints|inferred})

**What was broken:** {one sentence from Actual Behaviour}
**What should be true now:** {one sentence from Expected Behaviour / AC}

### Acceptance criteria (expanded — each item verified independently)
1. {atomic criterion — one observable fact}
2. {atomic criterion}
3. {atomic criterion}
...

### Steps
1. Navigate to {derived path}
2. {action derived from Steps to Reproduce}
3. {action}
...

### Pass criteria
- [ ] {criterion 1 from expanded list above}
- [ ] {criterion 2}
- [ ] {criterion 3}
...
```

**Each pass criterion maps 1:1 to an expanded acceptance criterion. Never collapse multiple requirements into one criterion line.**

### 2d — Carry-over checks (all verification modes)

If `{ticket-dir}/notes.md` has a `### Test candidates` sub-section under `## Refinement Carry-over` (written by ticket-appraise from the planner's Refinement phase), add one extra check per candidate line, labelled `carry-over`, to whichever plan variant you wrote (browser, build-only or live-backend):

```bash
awk '/^## Refinement Carry-over/{on=1; next} on && /^## /{exit} on && /^### Test candidates/{tc=1; next} tc && /^### /{exit} tc && /^- /' "{ticket-dir}/notes.md"
```

Append them to the plan under their own heading, **after** Pass criteria and never as `- [ ]` checkboxes:

```
### Carry-over checks (do not affect the verdict)
1. carry-over — {behaviour named in the candidate} (candidate {key})
```

Exercise each one in Step 4b / 4c / 4c-live the same way as a criterion, and record its result. A carry-over check is **not** an acceptance criterion: Refinement judged it a gap, nobody accepted it. A failed carry-over check is reported in the verify report (Step 6 or 7b) and in the REMEDIATION_BRIEF (7c), but it **never changes the verdict** — it is not counted in `criteria_met`/`criteria_total`, not written as a checkbox in `verify-session.md`, and Step 5 ignores it. No `### Test candidates` sub-section → skip this step.

If `--from-auto` is NOT set:
  Pause here and ask the user: **"Does this plan look right? (yes / adjust: ...)"**
  If the user adjusts, update the plan accordingly. If yes, proceed to Step 3.

If `--from-auto` IS set:
  Print the plan and proceed directly to Step 3 (no user prompt).

bash ~/.claude/skills/lib/plog.sh VERIFY build-plan done "{N} criteria"

---

## Step 3 — Establish browser session

Browser mode only (Step 1e routes the other modes to 4c / 4c-live).

### 3a — Navigate to the app

```playwright
mcp__playwright__browser_navigate: {base URL from --env}
```

Take a snapshot. If the nav already shows an authenticated user name, skip 3b.

### 3b — Log in

Use the credentials from Step 1b5 (derived or explicit).

Reach the login form using this project's own login path — never a hard-coded one:
1. If `nav-hints.md` has a `## Login` entry, follow its click-by-click steps.
2. Otherwise use the login path described in app-knowledge.
3. Otherwise read the snapshot and click the control that opens sign-in (a link or button labelled e.g. "Sign in" / "Log in", possibly inside an account or user menu). After a successful login, save the path you used as a `## Login` entry in `nav-hints.md` (Step 4a format) so the next run does not have to search.

Fill the login form with `{derived_user}` and the resolved password, and submit it (click the submit button, or `mcp__playwright__browser_press_key` `Enter` in the password field). Then wait for the page to settle (see **Wait for settle** in Step 4) and take a snapshot. Confirm the nav shows the authenticated user (name, avatar or account menu — whatever app-knowledge names as the logged-in marker).

If login fails:

- **On UAT**: take a screenshot (`verify-login-fail.png`, see **Screenshot evidence** in Step 4b) and post a comment to the Linear ticket. The comment names the user only — never the password or where it came from:
  ```
  ⚠️ Login failed for {derived_user} on UAT. The configured test password may be wrong for this account, or the account may be locked. Please verify the test credentials and re-run with --user and --password flags.
  ```
  Then abort with a FAIL verdict (skip to Step 7 with WHAT_FAILED = "Login failed for {derived_user}").
- **On local**: report and stop as above (local env may have different requirements).

bash ~/.claude/skills/lib/plog.sh VERIFY browser-session done "Logged in as {--user}"

---

## Step 4 — Navigate to the feature under test

This step uses a **3-attempt** budget to reach the correct location before escalating to the user.

### Attempt tracking

Maintain a counter `nav_attempts = 0`. Each time you try a click path and it does not show the expected content, increment the counter.

### Attempt loop

**For each attempt (up to 3):**

1. Execute the click-by-click steps from the nav-hints entry (or the inferred path from Step 2a). **Never use `page.goto()` for in-app navigation** — Angular loses session state on full reload.
2. Wait for settle (below), then take a snapshot.
3. Evaluate the snapshot:
   - **Success** — the page shows content related to the ticket's feature area (relevant headings, buttons, forms, or list items mentioned in the ticket). Proceed to Step 4b.
   - **Wrong page** — the page looks unrelated, shows a 404, redirects to `/accessdenied`, or the expected component is absent. Increment `nav_attempts`. Try the next candidate path.

**Wait for settle.** The app is an async SPA: a click returns before the XHRs it triggers finish, so a snapshot taken immediately can show a loading spinner or the previous view. After every click that navigates, opens a dialog or submits a form, call `mcp__playwright__browser_wait_for` before the snapshot:
- with `text` set to a heading, label or value the plan expects on the next view (preferred), or
- with `textGone` set to a loading indicator you saw ("Loading…", spinner label), or
- as a last resort, a short fixed `time` (1–2 s).

Bound every wait (no more than ~15 s). A wait that times out is evidence, not a crash: take the snapshot anyway and judge the page from it — a still-loading page counts as a **Wrong page** attempt, not a FAIL.

**Candidate click paths to try in order (if the first fails):**
1. The exact click path from the matched nav-hints entry.
2. A parent/sibling click path (e.g. if "Handover Progress" fails, go to "Handover Payments" first using its nav-hints entry, then look for tabs/links to Progress).
3. Explore the nav: start from the root page (click Home), then click through nav bar items that match the feature area until reaching the target.

**Important:** If any attempt results in an `/accessdenied` redirect, do NOT try that URL or click path again. The nav bar will likely be broken after `/accessdenied` — navigate to the root URL (`/`) to restore session, then continue with the next attempt.

### After 3 failed attempts

If `nav_attempts == 3` and the correct page has not been reached:

- **If `--from-auto`** → record the 3 attempted paths and proceed directly to Step 7 (failure report). Include nav diagnostics in WHAT_FAILED:
  ```
  Navigation failed after 3 attempts. Tried: {path1}, {path2}, {path3}. Target area: {feature area}.
  ```
- **Otherwise** → stop and ask:

  > "I tried {list the 3 paths attempted} but couldn't find the {feature area} section. Where should I navigate to test this? (e.g. `/handover/456` or click path through the UI)"

  Wait for the user's answer. Use the provided path as attempt 4 and proceed.

### Save new navigation knowledge (Step 4a)

Once the correct page is reached — whether via the plan, retry, or user input — **if the area was not already in `{TICKETS_ROOT}/nav-hints.md`**, save it now.

Append to `{TICKETS_ROOT}/nav-hints.md` (create the file if it doesn't exist):

```markdown
## {feature area label}
- **Path:** {exact URL pattern, e.g. `/handover-payment/{id}`}
- **How to reach:** {numbered click-by-click steps — no `page.goto()` references}
- **Learned from:** {TICKET-ID}
- **Date:** {today's date}
```

Tell the user: `"Saved navigation hint for '{feature area}' to nav-hints.md for future tickets."`

bash ~/.claude/skills/lib/plog.sh VERIFY navigate done "Reached {feature area}"

---

## Step 4b — Execute verification steps

**Phase timeout:** The verify phase has a 30-minute wall-clock limit from this step. If 30 minutes elapse, checkpoint progress and emit a clean diagnostic — do not crash.

With the browser now on the correct page, work through each remaining step in the Verification Plan sequentially. For **every step**:

1. Perform the Playwright action with the matching tool: click (`mcp__playwright__browser_click`), type into a field (`mcp__playwright__browser_type`), choose a native `<select>` option (`mcp__playwright__browser_select_option`), press a key such as Enter, Escape or Tab (`mcp__playwright__browser_press_key`), hover to open a hover menu (`mcp__playwright__browser_hover`), accept or dismiss a native `confirm()`/`alert()` (`mcp__playwright__browser_handle_dialog`), upload a file (`mcp__playwright__browser_file_upload`), go back (`mcp__playwright__browser_navigate_back`), or change the viewport for a responsive criterion (`mcp__playwright__browser_resize`). Do not substitute `mcp__playwright__browser_evaluate` DOM edits for a user action — they bypass the framework's change detection and can produce a false PASS. Use `browser_evaluate` only to read state.
2. Wait for settle (Step 4) whenever the action triggers navigation, a dialog, a save or any async load.
3. Take a snapshot with `mcp__playwright__browser_snapshot`
4. Record the **observed result** — what you see in the snapshot

Capture after each step:
- The snapshot YAML (accessibility tree)
- The current URL
- Any new console errors: `mcp__playwright__browser_console_messages`

**Screenshot evidence.** The accessibility tree hides layout, overlap, styling and contrast, so every criterion also gets a picture. At each criterion's assertion point — PASS or FAIL — and on any unexpected broken state, call `mcp__playwright__browser_take_screenshot` with `filename` set to `verify-{TICKET-ID}-c{N}-{pass|fail}.png` (N = criterion number). Then make sure the file lands in the ticket workspace — Playwright MCP saves into its own output directory, so copy it from the path the tool reports:
```bash
mkdir -p "{ticket-dir}/artifacts" && cp "<path reported by browser_take_screenshot>" "{ticket-dir}/artifacts/"
```
Record each file under `### Evidence` in the report (Steps 6/7) and in the REMEDIATION_BRIEF for a FAIL. Never screenshot a page while a password field is visibly filled in.

**Per-criterion checkpointing:** After EACH criterion passes, write a checkpoint entry to the pipeline log (resume rules: [Step dispatch](#step-dispatch)):

```bash
# After criterion N passes, write checkpoint:
bash ~/.claude/skills/lib/plog.sh VERIFY checkpoint done "criterion-{N}-pass"
```

At any point, if the observed result contradicts a pass criterion, mark that criterion **FAIL** and record:
- The step number
- What was expected
- What was observed (quote element labels, button states, error messages verbatim from the snapshot)

Continue executing remaining steps unless the page is in a broken state (crash, blank page, unexpected auth redirect).

bash ~/.claude/skills/lib/plog.sh VERIFY execute-steps done "{N} steps executed"

---

## Step 4c — Execute build verification (build-only mode only)

Moved to `references/build-only.md` (run each build command, checkpoint each passing criterion, record failures, then Step 5), read per the Step 1f condition.

---

## Step 4c-live — Execute live-backend verification (live-backend mode only)

Moved to `references/live-backend.md` (run each live check, checkpoint each passing criterion, restore any stopped dependency, then Step 5), read per the Step 1f condition.

---

## Step 5 — Evaluate pass/fail

Release the verify lock now, before evaluating — the app stack is no longer needed once checks have finished, so free it for the next queued verify run as early as possible rather than waiting for the pass/fail report to finish. Idempotent no-op when the lock was never acquired (`--env uat`, `--no-env-start`, or `VERIFY_MODE=build-only`):

```bash
source "$HOME/.claude/skills/lib/verify-lock.sh" 2>/dev/null || true
verify_lock_release
```

### Pass

All pass criteria are met → proceed to Step 6. Carry-over checks (Step 2d) are not pass criteria: a failed one never routes here to Step 7.

### Fail

One or more pass criteria are not met → proceed to Step 7.

### Report templates (load condition)

Before writing the Step 6 pass report or the Step 7b failure report, including a Step 7 reached directly from Step 1b5, 1.6d, 3b or 4, run `bash ~/.claude/skills/lib/skill-ref.sh ticket-verify references/templates.md`, then Read the printed path in full. Do not continue until you have read it. If `skill-ref.sh` exits non-zero, run `bash ~/.claude/skills/lib/plog.sh META reference-missing fail "references/templates.md"` and stop: never write a report or comment from memory. The REMEDIATION_BRIEF (7c), the notes.md records and the PR body stay in this file.

---

## Step 6 — Pass report

Moved to `references/templates.md` (§ Pass report), read per the Step 5 condition. Print it to the user.

Omit the Carry-over checks table when Step 2d added none. A failed carry-over check stays a pass verdict; also append it to notes.md (below) as `- **Carry-over failed:** {behaviour} (candidate {key}) — {observed}` so a follow-up can pick it up.

Append to `{ticket-dir}/notes.md`:
```markdown
### {today's date} — Verification PASS ({env})
- **User:** {--user}
- **Criteria:** {N}/{N} passed
- **Evidence:** {brief summary}
```

### Post-verdict: Record verifier result (Phase 0 RLVR) — PASS

You only reach this point on the pass branch (`### Fail` routes to Step 7, which records FAIL). Record the verdict **before either state-transition branch below**: `uat-pass` is verdict-gated (#368), and a later PASS clears an earlier attempt's FAIL only once it is on the log. `criteria_met` = `criteria_total` = the passing-criterion count:

```bash
source ~/.claude/skills/lib/verifier-result.sh && verify_record_verdict "{VERIFY_MODE}" PASS <N> <M> <A>
```

`verify_record_verdict` picks the verifier from the mode — `browser` → `playwright_uat`, `build-only` → `build_only`, `live-backend` → `live_backend` — and writes the same `META|verifier-result` line `write_verifier_result verifier=<id> … phase=VERIFY` did. Exit 2 means the mode or verdict was not filled in and nothing was recorded: fix the call and re-run it.

### If `--env local`: Open PR and close out

Verification passed on localhost — the implementation is confirmed working. Now open the PR:

1. Read `notes.md` for the branch name, repo, and worktree path from the `pre-implementation checkpoint` entry.
2. For each affected repo, check if a PR already exists for this branch, then open one against `$BASE_BRANCH`:
   ```bash
   source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
   # Resolve worktree path — prefer notes.md checkpoint, fall back to path computation
   WORKTREE_PATH=$(grep "Worktree:" {ticket-dir}/notes.md 2>/dev/null | head -1 | sed 's/.*Worktree: //')
   if [ -z "$WORKTREE_PATH" ]; then
     source "$HOME/.claude/skills/lib/worktree.sh"
     WORKTREE_PATH=$(worktree_path "$TICKET_ID" "{repo-slug}")
   fi
   existing_pr=$(cd "$WORKTREE_PATH" && gh pr list --head {branch-name} --json url --jq '.[0].url' 2>/dev/null)
   _pr_newly_created=false
   if [ -n "$existing_pr" ]; then
     echo "PR already exists: $existing_pr"
     _pr_url="$existing_pr"
   else
     _pr_url=$(cd "$WORKTREE_PATH" && gh pr create --base "${BASE_BRANCH:-develop}" --head {branch-name} \
       --title "{type}({TICKET-ID}): {description}" \
       --body "$(cat <<'EOF'
   ## Summary
   {bullets from the plan}
   
   ## Test plan
   - [x] ticket-verify --env local PASS ({N}/{N} criteria)
   EOF
     )")
     _pr_newly_created=true
   fi
   # Record the PR — REQUIRED, run this exactly as written (GitHub #525).
   # lib/pr-evidence.sh is the one writer of META|pr-created (and of the
   # pr-opened outbox event for a genuinely new PR). Without that line the
   # run has no PR repo, merge-poll never polls the PR, and every ticket
   # blocked by this one stays held after the PR merges. Do not write your
   # own "pr-open" log line instead.
   source "$HOME/.claude/skills/lib/pr-evidence.sh" 2>/dev/null || true
   if $_pr_newly_created; then
     record_pr_created --new "{LOG_FILE}" "{TICKET_ID}" "$_pr_url"
   else
     record_pr_created "{LOG_FILE}" "{TICKET_ID}" "$_pr_url"
   fi
   ```
3. Capture the PR URL(s). Run the block above once per affected repo — each PR needs its own
   `record_pr_created` call (a `META|pr-created` line per PR).
4. **If `--from-auto` is present: skip this item entirely** and go to item 5. ticket-auto's
   router owns `implement-complete` in that mode — it fires it itself right after IMPLEMENT
   (STEP_4's post-spawn `flow_trigger`, and again after every re-implement in the verify-retry
   and pr-iterate loops), so the ticket is already in `Review` by the time VERIFY runs. A second
   call here is not a harmless no-op: `flow.sh` logs `META|flow-warn|info|ILLEGAL_TRANSITION …
   from Review` and still advances `rev` and emits a duplicate `implement-completed` event to
   the outbox (#415).

   **Standalone runs only (no `--from-auto`):** delegate to the flow executor. `implement-complete`
   carries no `verdict_gate` (it only opens code review — it is not a Done/UAT-reaching trigger),
   so no exit-11 branch applies here:
   ```bash
   bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} implement-complete
   _rc=$?
   # flow-run.sh has already logged any non-zero exit (META|flow-error + heartbeat).
   # implement-complete carries no verdict_gate, so exit 11 cannot occur; a failure is non-fatal — continue.
   ```
   This moves state → `Review` and clears the manifest `approved` fact.

5. Append to `notes.md`:
   ```markdown
   - PRs: {repo}: {URL}
   - Status → Review
   ```

6. Post the **Local PASS comment** from `references/templates.md` via the Linear access strategy
   (bash `save_comment` when `LINEAR_API_KEY` is set, MCP `save_comment` fallback otherwise).
7. Skip to **Post-verdict: Emit the PHASE_RESULT block** below with `VERDICT: PASS`.

### If `--env uat`: Move to Done

No PR creation. Delegate the state transition — this trigger carries `verdict_gate: true`
([SKILL.md § Verdict gate](../ticket-flow/SKILL.md#verdict-gate)), so it is the one call
site in this skill that can come back `exit 11` (gate-blocked) rather than a generic
non-zero failure:

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} uat-pass
_rc=$?
if [ "$_rc" -eq 11 ]; then
  # Gate-blocked: this run's own verdict (just written above) was PASS, but flow.sh
  # refused the transition because a trailing FAIL/BLOCK for a DIFFERENT verifier/phase
  # is still the latest on record and nothing has superseded it. This is not the same as
  # "verification failed" — do not post the PASS comment or emit a PASS phase result,
  # since either would look identical to a real Done in the log/Linear (the inverted form
  # of the bug this gate exists to fix). A human must review and either fix the other
  # verifier's failure or re-run `/ticket-flow {TICKET-ID} uat-pass --override <reason>`.
  # flow-run.sh has already written META|gate-stop|fail|VERDICT_GATE_BLOCKED + heartbeat.
  echo "uat-pass gate-blocked for {TICKET-ID}"
fi
# Any other non-zero exit is already logged by flow-run.sh (META|flow-error).
```

This moves state → `Done` and removes `claimed` + `reviewed` — only when `_rc` is `0`.

**If `_rc` was `11`** (gate-blocked): post the **UAT BLOCKED comment** from `references/templates.md`
instead of the pass comment, then skip to **Post-verdict: Emit the PHASE_RESULT block** below
with `VERDICT: BLOCK` (not `PASS`).

**Otherwise** (`_rc` was `0`, or a non-gate error was logged and the caller chooses to
continue) post the **UAT PASS comment** from `references/templates.md` via the Linear access strategy.
Then continue to **Post-verdict: Emit the PHASE_RESULT block** below with `VERDICT: PASS`.

### Post-verdict: Emit the PHASE_RESULT block (--from-auto only)

End your return with the `=== PHASE_RESULT ===` block described in **§ 6 Phase result
emission** of the auto preamble: `PHASE: VERIFY`, `VERIFIER` set to this run's actual
verifier, and `CRITERIA_MET`/`CRITERIA_TOTAL`/`ATTEMPT` matching the `verify_record_verdict`
call above. `VERDICT` is `PASS` in every case above except the gate-blocked `--env uat`
branch, where it is `BLOCK` — "the phase found something that must stop forward progress"
(`docs/phase-result-schema.md`'s enum) describes this exactly: this run's own check passed,
but a downstream gate stopped the ticket from advancing. Nothing goes after the closing
marker.

---

## Step 7 — Failure report

First run Step 5's `verify_lock_release` block (idempotent). If you reached Step 7 without passing Step 5, also read `references/templates.md` per the Step 5 condition.

### 7a — Collect diagnostics

**Browser mode:**
1. **Console errors** — `mcp__playwright__browser_console_messages` (errors only, not warnings)
2. **Current URL** — from the last snapshot
3. **Last snapshot YAML** — accessibility tree at the point of failure
4. **Failed step** — step number, expected vs. observed

Moved to `references/build-only.md` (build-only diagnostics and their REMEDIATION_BRIEF field mapping), read per the Step 1f condition.

Moved to `references/live-backend.md` (live-backend diagnostics and their REMEDIATION_BRIEF field mapping), read per the Step 1f condition.

### 7b — Write the failure report

Moved to `references/templates.md` (§ Failure report), read per the Step 5 condition. Print it to the user.

If several criteria fail, report all of them here and in 7c: WHAT_FAILED and SNAPSHOT_EXCERPT cover the first failure; list the rest under an `ADDITIONAL_FAILURES:` key in the brief.

### Post-verdict: Record verifier result (Phase 0 RLVR) — FAIL

A real FAIL must land on the log so the verdict gate (#368) blocks any later `uat-pass` while it stands. `criteria_met` is the passing-criterion count, `criteria_total` the attempted count:

```bash
source ~/.claude/skills/lib/verifier-result.sh && verify_record_verdict "{VERIFY_MODE}" FAIL <N> <M> <A>
```

### 7c — Emit the REMEDIATION_BRIEF

After the failure report, emit this block verbatim (preserving delimiter lines and key names — downstream skills parse them):

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REMEDIATION_BRIEF — paste into /ticket-implement or a fix skill
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TICKET_ID: {TICKET-ID}
TICKET_TITLE: {title}
TICKET_URL: {Linear URL}
ENV: {env}
TEST_USER: {--user}

WHAT_WAS_EXPECTED:
{1–3 sentences describing the expected behaviour from the acceptance criteria}

WHAT_FAILED:
{1–3 sentences describing exactly what was observed — be specific: UI element names,
button states (disabled/enabled), error messages, missing elements}

FAILED_AT_STEP: {N} — {step description}

CONSOLE_ERRORS:
{list, or "none"}

SNAPSHOT_EXCERPT:
{10–20 most relevant lines of the accessibility tree YAML at the failure point,
focused on the component under test}

CURRENT_URL: {url}

SCREENSHOTS:
{ticket-dir}/artifacts/verify-{TICKET-ID}-c{N}-fail.png (and any other verify-*.png from this run, or "none" in build-only/live-backend mode)

CONTEXT_FILES:
- {ticket-dir}/context.md  (or "not found locally")
- {ticket-dir}/notes.md    (or "not found locally")
- {openspec change tasks.md path, or "none"}

CARRY_OVER_CHECKS:
{one line per Step 2d carry-over check: "carry-over — {behaviour} (candidate {key}): pass|FAIL — {observed}",
or "none". Informational only — a failed carry-over check did not cause this failure.}

SUGGESTED_FIX:
{2–4 sentence hypothesis about what is likely still broken in the code. Reference
specific file names, component names, Angular template bindings, or Java service
methods if known from notes.md or openspec tasks. If unknown, say so explicitly
rather than guessing.}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 7c5 — Write REMEDIATION_BRIEF to plan artifact

Persist the brief to the plan artifact, so `ticket-implement` can read SUGGESTED_FIX, SNAPSHOT_EXCERPT, the diagnostics and the context files. Write this section body to `{ticket-dir}/remediation-section.md`, filling every placeholder and ending at the context-file list:

```markdown
**Date:** {today's date}
**Environment:** {env}
**Failed at step:** {N} — {step description}
**Test user:** {--user}

### Expected
{WHAT_WAS_EXPECTED — 1–3 sentences}

### Observed
{WHAT_FAILED — 1–3 sentences}

### Suggested Fix
{SUGGESTED_FIX — 2–4 sentence hypothesis from the brief}

### Diagnostics
**URL at failure:** {CURRENT_URL}
**Console errors:** {CONSOLE_ERRORS content}
**Snapshot excerpt:**
{SNAPSHOT_EXCERPT content}

### Context Files
{CONTEXT_FILES list items}
```

Then append it:

```bash
bash ~/.claude/skills/lib/remediation-append.sh "{TICKET-ID}" --section "{ticket-dir}/remediation-section.md" --root .
```

The script finds the plan (`ticket-dir.sh plan`), adds `## Verification #<N>` (existing sections + 1), your file verbatim and the `<!-- /REMEDIATION_BRIEF -->` marker through a temp file and a rename, and prints `PLAN=`/`N=` for 7d2. Exit 3: no single plan artifact; report "No plan artifact found for REMEDIATION_BRIEF — brief emitted to chat and notes.md only." Exit 1: the write or rename failed and `REMEDIATION_BRIEF_TRUNCATED` is logged; stop.

### 7d — Post VERIFY_EXHAUSTED summary to Linear

When the verify phase has exhausted its retries (2 attempts), post the **VERIFY_EXHAUSTED comment** from `references/templates.md` to the Linear ticket via the Linear access strategy (bash `save_comment` when `LINEAR_API_KEY` is set, MCP fallback otherwise). This is the final communication — no further retries will occur — so it says which criteria passed, which failed, and that no automated retry follows.

### 7d2 — Record in notes.md

Append to `{ticket-dir}/notes.md`:
```markdown
### {today's date} — Verification FAIL ({env})
- **User:** {--user}
- **Failed at step:** {N} — {step description}
- **Expected:** {expected}
- **Observed:** {observed}
- **Console errors:** {count or "none"}
- **Plan updated:** {PLAN from 7c5, or "not found"} — `## Verification #{N}` appended
```

### 7e — Post findings to Linear

Post the **FAIL comment** from `references/templates.md` via the Linear access strategy (bash `save_comment` when `LINEAR_API_KEY` is set, MCP `save_comment` fallback otherwise).

### 7f — Update Linear state (UAT only)

If `--env uat`:

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} uat-fail
# flow-run.sh logs any failure itself (no verdict_gate, so no exit 11); non-fatal — continue.
```

This moves state → `Ready`, adds `rejected`, removes `reviewed`. A human must run `/ticket-approve {TICKET-ID}` before the next implementation cycle can start.

If `--env local`: no state change — the ticket is still in `Ready`, code just needs more work. The REMEDIATION_BRIEF above feeds `ticket-implement` for the fix round.

### 7g — Emit the PHASE_RESULT block (--from-auto only)

A failure still reports. End your return with the `=== PHASE_RESULT ===` block described in **§ 6 Phase result emission** of the auto preamble: `PHASE: VERIFY`, `VERDICT: FAIL`, `VERIFIER` set to this run's actual verifier, `CRITERIA_MET` the number that passed, `CRITERIA_TOTAL` the number attempted, and `UNADDRESSED` naming any criterion never reached. This is **additive** — the REMEDIATION_BRIEF above is unchanged and keeps its canonical format. The block goes last, after everything else in the return.

A FAIL with a block is a usable signal; a FAIL with no block is an absence of information, and any consumer must then fall back to whole-run classification.
