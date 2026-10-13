# ticket-verify

> Verifies a Linear ticket fix by loading its requirements, navigating the live app via Playwright, reproducing the original issue steps, and confirming the fix works. Produces a structured pass/fail report. On failure, emits a REMEDIATION_BRIEF that can be fed directly to ticket-implement or a fix skill. Use when the user says "/ticket-verify <ID>", "verify ticket <ID>", "test ticket <ID>", or "check if <ID> is fixed". Accepts optional --user, --password, and --env flags.

## What it does

Performs end-to-end browser verification of a ticket fix using Playwright. Loads the ticket's acceptance criteria from Linear, expands compound requirements into atomic pass criteria, derives the navigation path using nav-hints and app-knowledge (never `page.goto()` for in-app nav), logs into the app, executes click-by-click steps through the UI, evaluates each criterion, and produces a structured pass/fail report. On local pass, opens a PR and moves to Review. On UAT pass, moves to Done. On failure, emits a REMEDIATION_BRIEF with SUGGESTED_FIX, diagnostics, and context files, and writes a Verification section to the plan artifact.

## Trigger

**Slash command:** `/ticket-verify <ID> [--user <email>] [--password <pw>] [--env local|uat] [--from-auto] [--no-env-start]`

**Natural language:** verify ticket <ID>, test ticket <ID>, check if <ID> is fixed

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Ticket ID | CLI argument | Yes |
| --env | CLI (local or uat, default: local) | No |
| --user | CLI (login email override) | No |
| --password | CLI (password override, default: admin on UAT) | No |
| LINEAR_API_KEY | Environment variable | Yes |
| LOCAL_URL | CLAUDE.md | Yes (for --env local) |
| UAT_URL | CLAUDE.md | Yes (for --env uat) |
| REPOS_ROOT | env, ticket env file, or CLAUDE.md (`verify_env_init`) | Yes (for --env local) |
| VERIFY_SERVED_PORTS | env or CLAUDE.md — extra ports/URLs that must serve the ticket's code | No |
| nav-hints.md | TICKETS_ROOT | No |
| app-knowledge | Skill reference | No |

## Outputs / Artifacts

| Artifact | Location | Description |
|----------|----------|-------------|
| Verification report | stdout + Linear comment | Pass/fail with criteria table + diagnostics |
| REMEDIATION_BRIEF | stdout + plan artifact | Structured failure context for re-implementation |
| Verification #N section | Plan artifact | Persisted brief for ticket-implement to read |
| PR (local pass) | GitHub | PR created against develop |
| State transition | Linear | implement-complete (standalone local pass only — the ticket-auto router owns it under `--from-auto`), uat-pass, or uat-fail |
| Nav hint | TICKETS_ROOT/nav-hints.md | New navigation path (if discovered) |

## How it works

```mermaid
flowchart TD
    A[Start: /ticket-verify] --> B[Step 1: Load context]
    B --> C[Load app-knowledge + nav-hints]
    C --> D[Fetch Linear ticket]
    D --> E[Derive credentials]
    E --> F[Step 2: Build verification plan]
    F --> G[Expand AC into atomic criteria]
    G --> H[Step 3: Browser session + login]
    H --> I[Step 4: Navigate to feature]
    I --> J{3-attempt nav loop}
    J -->|Success| K[Step 4b: Execute steps]
    J -->|Failed| FAIL1[FAIL: nav exhausted]
    K --> L[Step 5: Evaluate pass/fail]
    L -->|PASS| M[Step 6: Pass report + PR/uat-pass]
    L -->|FAIL| N[Step 7: Failure report]
    N --> O[Emit REMEDIATION_BRIEF]
    O --> P[Write to plan artifact]
```

## Serving the ticket's own code (local env)

For `--env local`, VERIFY must test the ticket's branch, not whatever the primary checkout under
`REPOS_ROOT` has checked out. Three pieces make that hold (`lib/verify-worktree.sh`):

1. **Isolated worktree** (Step 1.6a4): `ensure_verify_worktree` checks out the ticket's pushed
   branch at `REPOS_ROOT/.verify-worktrees/<repo>/<TICKET_ID>`, under the single-flight verify lock.
2. **Hand-off to `env-start.sh`** (Step 1.6b): in the same shell that runs the project's
   `env-start.sh`, `verify_env_init` resolves `REPOS_ROOT` and `verify_worktree_exports` exports
   `VERIFY_TICKET_ID` and one `VERIFY_REPO_PATH_<REPO>` per worktree (repo name upper-cased,
   other characters mapped to `_`).
3. **Served-checkout check** (Step 1.6b): for `LOCAL_URL`'s port and each `VERIFY_SERVED_PORTS`
   port, the listening process's cwd (`/proc/<pid>/cwd`, `lsof` fallback) is resolved to a git
   checkout and compared with the worktrees. Another checkout of a repo under test on a different
   commit, or with uncommitted changes, gate-stops `VERIFY_SERVED_WRONG_WORKTREE`. The check passes
   only when `LOCAL_URL`'s own port serves the ticket's code. If it cannot tell, it writes a
   `VERIFY_SERVED_UNVERIFIED` gate-warn and verify goes on. `VERIFY_SERVED_WORKTREE_STRICT=true`
   makes that a gate-stop.

**What the project's `env-start.sh` must do** (it lives in the consuming workspace, not in this
plugin):

- For each repo it serves, use `VERIFY_REPO_PATH_<REPO>` when set, else `REPOS_ROOT/<repo>`. Every
  path derived from the repo dir (worker dir, env files, build output) must follow it.
- Restart a service already running from a different directory, instead of skipping it because
  its port is up.
- Optionally, show the served checkout in `env-status.sh` with
  `bash ~/.claude/skills/lib/verify-worktree.sh served <port|url>...`.

`/ticket-env-check` warns when the project's `env-start.sh` does not mention `VERIFY_REPO_PATH`.

## Related skills

- [`/ticket-implement`](ticket-implement.md) -- produces the fix being verified; consumes REMEDIATION_BRIEF on failure
- [`/ticket-flow`](ticket-flow.md) -- state transitions (uat-pass, uat-fail, implement-complete)
- [`/nav-hints`](nav-hints.md) -- click-by-click navigation paths
- [`/app-knowledge`](app-knowledge.md) -- business rules and role-based UI behaviour
- [`/ticket-pr-review`](ticket-pr-review.md) -- PR alignment review triggered after local pass PR creation
