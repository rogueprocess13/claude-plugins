---
name: ticket-planner
description: 11-phase autonomous planner — turns a business idea into dependency-ordered planned tickets. Phases: Appraisal → Discovery → Architecture → Specify → Review → Consensus → Crosscheck → Epic Gen → Ticket Gen → Refinement → Completed. Produces against frozen Planner Context and labels contracts.
allowed-tools: Bash, Read, Agent
---

# Ticket Planner — Idea-to-Tickets Pipeline

Autonomous 11-phase planner that turns business ideas into Linear initiatives, epics, and dependency-ordered planned tickets the existing `ticket-auto` pipeline consumes without special-casing.

Sits upstream of `ticket-auto` and `fleet-controller`. Produces against frozen consumption-side contracts — does not re-specify them.

## When to Use

| Trigger | Mode |
|---------|------|
| `/ticket-planner plan "idea"` | Plan a new initiative — artifacts only, nothing in Linear |
| `/ticket-planner resume <INIT_ID>` | Resume a crashed or paused initiative |
| `/ticket-planner resume <INIT_ID> --create` | Authorize creation and run through to Linear |
| `/ticket-planner resume <INIT_ID> --answers <file>` | Resume with answers to the stop's questions — headless callers (see [Headless use](#headless-use---answers)) |
| `/ticket-planner status <INIT_ID>` | Show current phase and recent log entries |
| `/ticket-planner replan <INIT_ID>` | Re-plan an initiative from feedback (requires Regenerate flag) |
| `/ticket-planner doctor` | Preflight check — REPOS_ROOT, Linear team/labels, helper scripts |
| `/ticket-planner doctor <INIT_ID>` | Preflight check, plus resume branch/sha alignment (#217) |

## Modes

### Plan (`plan`)

Start a new planning run from a business idea. The planner initializes the state directory, creates the state log, and begins at the Appraisal phase. Each phase runs as an isolated agent; the router advances sequentially through the state machine.

```
/ticket-planner plan "Add real-time collaboration to the document editor"
```

**`plan` stops after Crosscheck and creates nothing in Linear.** Phases 1–7 write only
to disk; Epic Gen (phase 8) is the first Linear write, and the `plan` phase sequence ends
before it. Crosscheck (a deterministic linter, see `### Crosscheck` below) runs
unconditionally, then draft readiness (step 1d) halts with `DRAFT_NOT_READY` on a blocking
finding. The run leaves the ticket set reviewable on disk (`proposal.md`, `review.md`,
`consensus.md`, `specs/*.md`) and reports the command to continue.

Or, pass a grill-me validated intent file (recommended):

```
/ticket-planner plan ./intents/rt-collab.md
```

When an intent file is passed, the planner verifies the seal before creating any state. A missing seal, a tampered file, or a `do-not-proceed` verdict is a hard stop. On `ready`, the intent document is captured as `artifacts/intent.md` and the Appraisal phase treats it as authoritative.

If the run is interrupted (crash, timeout, manual stop), resume with `resume` — the router re-derives position from the state log and continues from where it left off.

### Plan flags

Accepted by `plan` and `resume`. Every flag is **written to the state log the moment it
is parsed** and read back from there, never carried in an exported variable: the dispatch
loop spans a fresh process per phase (#144). Full semantics: `docs/ticket-planner.md` § Plan and resume flags.

| Flag | Effect |
|------|--------|
| `--create` | **`resume` only.** Authorize Linear creation, then run Epic Gen → Ticket Gen → Refinement → Completed |
| `--accept CODE:"reason"` | **`resume` only**, repeatable. Mark a blocking Crosscheck finding genuine-and-expected |
| `--shared-branch` / `--no-shared-branch` | Force / suppress the shared-branch directive. Both together is an error; neither → heuristic (≥ 3 tickets **and** dependency chain depth ≥ 2) |
| `--until <Phase>` | Stop the dispatch loop once `<Phase>` completes; `resume` continues |
| `--dry-run` | Accepted and redundant — stopping before Linear is already the default |
| `--team <key\|name\|id>` | Linear team to create on (overrides `LINEAR_TEAM_ID`) |
| `--project <name\|id>` / `--no-project` | Linear project for the epic and its tickets / deliberately none (silences the project gate) |
| `--milestone <name\|id>` | Linear project milestone (needs `--project` when given by name) |
| `--no-tests-rule[=true\|false]` | Record whether the project forbids implementation from writing tests (#503). Sticky (`no-tests-rule` key); without it, detected once from `REPOS_ROOT` CLAUDE.md files |
| `--refresh-bodies` | **`resume` only**, one-shot. Re-read every child from Linear before Refinement — the release for `BODY_DRIFT` / `BODY_UNVERIFIED`. Also accepted on a Completed initiative |
| `--converge --only <TID[,TID...]> [--by <name>]` | **`resume` only**, one-shot. Demote the named tickets' remaining blocking, verified, non-structural semantic findings without a rescan. `--only` is mandatory. Also accepted on a Completed initiative |
| `--answers <file>` | **`resume` only.** Apply an answers file to the open question round, then resume. See [Headless use](#headless-use---answers) |

`--create` is rejected in `plan` mode: authorizing creation is a separate, deliberate
invocation made *after* the artifacts exist and have been read.

### The create gate

```
/ticket-planner plan ./intents/rt-collab.md     # → stops after Crosscheck
/ticket-planner resume INIT-42 --create         # → Epic Gen, Ticket Gen, Refinement, Completed
```

`--create` writes `META|create-authorized|done` to the state log **before the loop
starts**; every later check reads it back, so a `resume` after a crash mid-Epic-Gen
proceeds without re-passing the flag. A plain `resume` at the gate creates nothing: it
reports the position and the `--create` command, and stops. When `--until` also applies,
the **earliest** stop wins. Background: `docs/ticket-planner.md` § The create gate and stop conditions.

### Accepting a genuine Crosscheck finding (`--accept`)

```
/ticket-planner resume INIT-42 --accept CARVE_SCOPE_LOST:"documented rescope, see consensus.md#tickets-6"
```

`resume` only, repeatable, persisted at parsing as `META|crosscheck|accepted|<CODE> <reason>`.
An accepted code stays accepted for the life of the initiative: it is non-blocking on every
later Crosscheck run and is re-logged as `accepted` each time it recurs. A finding under any
other code still blocks. `--accept DRAFT_NOT_READY:"reason"` is not a Crosscheck accept: it
passes a draft readiness halt (step 1d) for the current drafts only
(`META|draft-readiness|accepted|<hash> <reason>`), so any spec edit re-arms the gate.

### Resume (`resume`)

Continue an interrupted or paused run. The router reads the state log, finds the last incomplete phase, and resumes from there. Completed phases are skipped.

```
/ticket-planner resume INIT-42
```

A bare `resume` never crosses the write boundary — see [The create gate](#the-create-gate).
`resume` is also the only mode that takes `--accept`, `--refresh-bodies`, `--converge` and `--answers`.

### Headless use (`--answers`)

A caller with no terminal runs describe → answer → resume:
`bash lib/planner-stop-describe.sh <INIT_ID>` prints the stop as a human-hold
Schema-Version 2 block (format: `ticket-auto-pipeline/docs/human-hold-schema.md`); the
caller writes an answers file; `/ticket-planner resume <INIT_ID> --answers <file>` applies
it in step 2b (`lib/planner-answers.sh`). A question back instead of an answer goes to the
read-only `lib/planner-artifact-qa.sh` and never touches the open round. Stop reasons,
bindings, intake rules and both scripts' exit codes: `docs/ticket-planner.md` § Headless use.

### Status (`status`)

Show the current phase, initiative metadata, and the last few state log entries.

```
/ticket-planner status INIT-42
```

### Replan (`replan`)

Re-plan an initiative that carries the `Regenerate` flag. Ingests aggregated feedback, applies confidence drift, and regenerates undispatched Backlog tickets. Dispatched, in-progress, and completed tickets are left unchanged.

```
/ticket-planner replan INIT-42
```

### Doctor (`doctor`)

Run every environment/Linear-side preflight check the planner has ever hit mid-run,
before starting or resuming a run. Deterministic bash, no Linear writes unless
`--fix` is passed:

```
/ticket-planner doctor
/ticket-planner doctor INIT-42          # also checks resume branch/sha alignment (#217)
/ticket-planner doctor --fix            # create any missing board-projected label
```

Checks: `REPOS_ROOT` resolves and is a real directory; the Linear team resolves
(`--team`/`LINEAR_TEAM_ID`/the workspace's only team); the 4 board-projected
labels (`needs-info`, `needs-adr`, `rejected`, `reviewed`) exist on that team —
reported individually, and created with `--fix`. These are the only labels
anything in the pipeline still writes to Linear (`workflow.json`'s
`board_drivers.linear.projected_labels`, applied by the board driver). The
former static contract labels (`planned`, `epic`, `pre-approved`,
`state:execution`) are retired and no longer checked or created: the planner
creates every issue with an empty label set, and what those labels carried now
lives in the local ticket/epic manifests and the Planner Context block.

Doctor also checks, when an initiative id is given, whether the live
`REPOS_ROOT` checkout for each repo Discovery explored still matches the ref
it pinned, or an isolated worktree is available (the same mechanism
Crosscheck itself falls back to, see #217 below); and whether the
cross-plugin helper scripts the phase prompts reference
(`planned-ticket-check.sh`, `branch-directive-check.sh` from
`ticket-auto-pipeline`, `grill-seal.sh` from `grill-me`) actually resolve on
this install (#232).

`doctor` never creates state and never dispatches a phase — it is safe to run
before `plan`, before `resume`, or any time something in the pipeline feels off.

## The 11 Phases

| # | Phase | What it does | Output |
|---|-------|-------------|--------|
| 1 | Appraisal | Interprets the idea, establishes initiative scope | Scope summary |
| 2 | Discovery | Explores affected repos, gathers context | Code paths, symbols, APIs |
| 3 | Architecture | Determines the technical approach | Architecture decision record |
| 4 | Specify | Synthesizes proposal + writes per-ticket specs with signals, self-lints citations | `proposal.md`, spec files |
| 5 | Review | Critiques the proposal and specs (internal by default) | Review findings |
| 6 | Consensus | Resolves review findings into a settled plan | Finalized proposal |
| 7 | Crosscheck | Deterministic bash — test-data synthesis (`testdata-synth` sub-step), then citation + cross-ticket propagation + test-data checks against the artifacts and the live repo | `META|crosscheck` events; gates Epic Gen on a blocking finding |
| 8 | Epic Gen | Creates the initiative epic in Linear — **first Linear write, gated on `--create`**. Stamps `**UAT Policy:** epic` on a shared-branch epic with synthesized test-data specs unless `PLANNER_UAT_POLICY` says otherwise | Linear epic |
| 9 | Ticket Gen | Creates planned child tickets (test-data tickets first, at Linear priority High; consumers `blocked_by` them via the sidecar), persists each body to `planner/body.md`, computes confidence | Linear tickets, per-ticket `body.md` |
| 10 | Refinement | Deterministic bash — per-ticket DoR check plus `dor-semantic-agent` scan+audit; stamps the epic `dispatch=true` once every child has a verdict | Per-ticket readiness verdicts; epic manifest `dispatch=true` |
| 11 | Completed | Terminal phase — summarizes the run; auto-dispatched right after Refinement's gate passes (or legacy-skips), no operator action | `COMPLETED.md`, terminal state log entry |

### Crosscheck

Not an agent: `planner_crosscheck_run` (`lib/planner-crosscheck.sh`) is deterministic bash
that the dispatch loop calls directly (step 1a). It runs the `testdata-synth` sub-step, then
the citation, propagation, test-data, bypass, contract, Signals, AC-coverage and dependency
check families. Every finding is written to state.log as
`META|crosscheck|fail|<CODE> <message>` (`warn` for a non-blocking code). A blocking finding
halts the dispatch loop immediately, before the create gate and outside the retry budget —
a deterministic check against unchanged artifacts cannot change its answer. Fix the cited
artifact and `resume`, or `--accept` a genuine-but-expected finding
(see [Accepting a genuine Crosscheck finding](#accepting-a-genuine-crosscheck-finding---accept)).

**Hard rule: the planner never runs `git checkout`, `git switch`, or `git reset`
against a REPOS_ROOT repo — anywhere, in any phase.** It may only read from a REPOS_ROOT
repo, or create a worktree alongside it.

Check families, the Specify self-lint (#218) and Discovery-pinned ref resolution (#217):
`docs/ticket-planner.md` § Crosscheck.

### Refinement

Also bash, with no prompt: step 1b runs `lib/planner-refinement.sh`. For each child, a
strict deterministic DoR check (`DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true`) runs
against its `planner/body.md`, then, unless `PLANNER_REFINEMENT_SEMANTIC=false`, a
`dor-semantic-agent` scan and audit that bash parses and applies. The epic manifest is
stamped `dispatch=true` once every child has a verdict. While any child is not ready the
planner halts (no `Refinement|gate|done`, no retry-budget use) and prints a per-ticket
report with its waive commands and converge hints. `resume` reuses every cached verdict
whose body and evaluator are unchanged. Releases: `dor-check.sh --waive`, `--converge`, and
`--refresh-bodies` for the non-waivable `BODY_DRIFT` / `BODY_UNVERIFIED`. An initiative whose
log carries the retired `TicketGen|dispatch-gate|done` line skips Refinement.

Rounds and convergence, audit demotion, body drift and the carry-over into ticket-auto:
`docs/ticket-planner.md` § Refinement.

## Target Symbols Grammar

The Signals `TargetSymbols` field — and any `path:line` citation in proposal.md
or spec prose — is parsed literally by the citation linter
(`lib/planner-crosscheck-citations.sh`, [#172](https://github.com/willard-pro/claude-plugins/issues/172)),
not read as natural language. Getting the shape wrong is the single biggest
source of Crosscheck findings across every initiative to date — one
initiative's remediation round found 17 of its 22 raw findings were the same
mistake (annotation on the wrong side of the colon). This section documents
the grammar the linter actually enforces, so Specify can follow it instead of
re-deriving it from checker failures one finding at a time:

```
TargetSymbols := entry (';' entry)*
entry         := Name ':' location (',' location)*
              |  Name ':' path                      -- no line at all: checks only that the file exists
Name          := identifier ['(' annotation ')']     -- annotation goes HERE, never in `location`
              |  identifier '/' identifier ...       -- two+ related symbols sharing the SAME location
location      := [path ':'] line ['-' line2]         -- omitting `path:` reuses the previous location's path
```

- **Annotations belong on the `Name` side, never the path side.**
  `uploadFile (new):UploadPageClient.tsx:304-310` resolves cleanly.
  `uploadFile:UploadPageClient.tsx (new):304-310` does not — the parser
  treats everything up to the trailing `:line` as the path, so the
  annotation gets folded into the literal filename it searches for
  (`UploadPageClient.tsx (new)`), which never exists on disk. This single
  mistake is the majority-cause finding above.
- **`(new)` and its variants skip the unresolved-path check only.** `(new)`,
  `(new in <slug>, ...)`, or any parenthetical whose first word is `new`
  tells the linter this file doesn't exist yet — don't flag
  `CITATION_UNRESOLVED` for it. It does not skip the line-range or
  symbol-proximity checks once the file exists.
- **Don't cite two symbols against two different line ranges in one compound
  `Name1()/Name2()` entry.** The linter checks *every* `/`-separated name in
  `Name` against *every* comma-separated range in the entry (each within
  `±PLANNER_CROSSCHECK_SYMBOL_PROXIMITY` lines, or via an earlier definition
  line) — it does not pair the first name with the first range and the
  second with the second. `check_llm_allowed()/record_llm_usage():guard.py:58-87,89-115`
  happens to pass when the two symbols sit close together and fails when
  they don't, because each range is checked against both names
  independently. Write one entry per symbol instead:
  `check_llm_allowed():guard.py:58-87;record_llm_usage():guard.py:89-115`.
  A compound `Name1/Name2` sharing one *single* location is fine — the
  ambiguity only appears once a second, distinct range enters the same entry.
- **A concept with no citable source location is not a `TargetSymbols`
  entry.** A migration description, a sibling initiative's slug, or any
  other non-file concept has nothing for the linter to resolve against
  `REPOS_ROOT` — state it in prose (Summary, Technical Approach, Risk
  Register), not as a colon-path citation.

## Contracts (frozen — the planner produces against these)

The planner does not re-specify the downstream contracts: the Planner Context block, the
per-type body section contract, the local ticket/epic manifests (issues are created with an
empty label set), the artifact plane and feedback. It ships no copy of their validators
(`planned-ticket-check.sh`, `planned-ticket-body-check.sh`, `branch-directive-check.sh`,
`grill-seal.sh`) and resolves them from the owning plugins; `/ticket-planner doctor` shows
whether each resolves. Details: `docs/ticket-planner.md` § Contracts.

## Determinism Boundary

The router is bash and never reasons about content; Crosscheck and Refinement's own
decisions are bash; phases never mutate state directly (they write log entries the router
reads). Agents supply per-phase content and Refinement's per-ticket semantic judgement.
See `docs/ticket-planner.md` § Determinism Boundary.

## Configuration

Variables and defaults: `docs/ticket-planner.md` § Configuration. Every variable except the
`PLANNER_REFINEMENT_*` and `PLANNER_DRAFT_*` families is read **once, in the shell that
parses arguments** (step 2a), and persisted to the state log there; setting one after a run
has started has no effect — re-invoke with the corresponding flag. When more than one stop
point applies (`PLANNER_REVIEW_HOLD`, `--until`, the create gate), the **earliest** wins.

---

## Implementation

When invoked, follow this procedure:

### 1. Source libraries

`planner-lib-root.sh` resolves the plugin root across all install layouts
(marketplace cache → `~/.claude/skills/lib` → source checkout). Use it rather than
trusting `CLAUDE_PLUGIN_ROOT`, which is not guaranteed to be set or correct.

```bash
# Bootstrap: find the resolver itself. Try the installed version recorded in
# installed_plugins.json first, then the newest cached version by *version*
# order (sort -V — a plain sort puts 0.9.0 after 0.15.1, issue #454), then the
# SessionStart-hook copy in ~/.claude/skills/lib.
PLANNER_LIB_ROOT_SH=$(sed -n 's/.*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*\/ticket-planner\/[^"]*\)".*/\1/p' \
  "${HOME}/.claude/plugins/installed_plugins.json" 2>/dev/null | head -1)
[ -n "$PLANNER_LIB_ROOT_SH" ] && PLANNER_LIB_ROOT_SH="${PLANNER_LIB_ROOT_SH%/}/lib/planner-lib-root.sh"
[ -f "$PLANNER_LIB_ROOT_SH" ] || PLANNER_LIB_ROOT_SH=$(find "${HOME}/.claude/plugins/cache" \
  -path "*/ticket-planner/*/lib/planner-lib-root.sh" 2>/dev/null | sort -V | tail -1)
[ -f "$PLANNER_LIB_ROOT_SH" ] || PLANNER_LIB_ROOT_SH="${HOME}/.claude/skills/lib/planner-lib-root.sh"

if [ ! -f "$PLANNER_LIB_ROOT_SH" ]; then
  echo "FATAL: ticket-planner is not installed — no planner-lib-root.sh found." >&2
  echo "Run: claude plugin install ticket-planner@willard-pro-claude-plugins" >&2
  exit 5
fi

source "$PLANNER_LIB_ROOT_SH"
PLUGIN_ROOT=$(planner_require_lib_root) || exit $?
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

source "${PLUGIN_ROOT}/lib/planner-state.sh"
source "${PLUGIN_ROOT}/lib/planner-router.sh"
source "${PLUGIN_ROOT}/lib/planner-phase-prompts.sh"
```

If `planner_require_lib_root` fails it prints every path it tried plus the install
command, and exits 5. Never fall back to a hardcoded path — a wrong one makes every
spawned phase agent die at its first `source` with a bare "No such file or directory"
and no state log entry, so `resume` re-runs straight back into the same failure.

### 2. Parse mode

First argument is the mode: `plan`, `resume`, `status`, `replan`, or `doctor`. Capture it as
`MODE` — step 2a checks it when rejecting `--create` outside `resume`.

```bash
MODE="${1:-}"
shift || true
```

### 2z. Doctor mode (short-circuits before flag parsing)

`doctor` takes none of the plan/resume flags in step 2a — it has its own
optional initiative id and its own `--fix` flag — and it never touches the
state log or the create gate, so it runs and exits here rather than falling
through to steps 2a/2b.

```bash
if [ "$MODE" = "doctor" ]; then
  source "${PLUGIN_ROOT}/lib/planner-doctor.sh"
  DOCTOR_OUTPUT=$(planner_doctor_run "$@")
  DOCTOR_ISSUES=$?
  echo "$DOCTOR_OUTPUT"
fi
```

Render the `---BEGIN_VARS---`/`---END_VARS---` block the same way `/ticket-env-check`
and `/fleet-env-check` already do: first pipe-delimited row is the header, the
`ROWCOUNT=N` line is metadata, every remaining row renders as a markdown table
(**Name**, **Status**, **Value**, **Location**, **Note**). After the table, report
"N issue(s) found" (`$DOCTOR_ISSUES`) or "All checks passed." Then **stop — do not
proceed to any other mode's steps.**

### 2a. Parse override flags

Flags are accepted in both `plan` and `resume` mode. `planner_flags_parse`
(`planner-invocation.sh`) parses them into plain shell variables (never exported:
each phase runs in a fresh process, so an export is gone by the next phase, #144),
reads the env-var defaults once, and validates every combination and `--until`
before anything is written. It prints the reason and returns 1 on a bad invocation.
The variables live only in this shell: run step 2b in the same Bash call, or parse again there.

```bash
source "${PLUGIN_ROOT}/lib/planner-invocation.sh"
planner_flags_parse "$MODE" "$@" || exit 1
```

### 2b. Persist the invocation config

Run this **immediately after the initiative ID is known and `planner_state_init` has
run** — in `plan` mode that is step 3's item 6, in `resume` mode it is item 2, before
anything is dispatched. Nothing may be dispatched before it: the persisted config is what every
later phase reads, and `--create` must be durable *before* Epic Gen can be reached, so
that a crash in between does not lose the authorization.

`planner_flags_persist` writes the parsed flags: `--answers` first (validated against
the round the run is stopped on now; a rejected file stops here with nothing written),
then the `--create` authorization, then every config key:

```bash
planner_flags_persist "$INITIATIVE_ID" || exit $?
```

Config is last-write-wins, so a later invocation overrides an earlier one — that is how
`resume --create` lifts the stop point `plan` recorded. `planner_config_set` rejects any
key outside `PLANNER_CONFIG_KEYS`; do not invent new ones inline. `--accept` is the one
exception to the `planner_config_set` path — accepted codes accumulate rather than
overwrite, so it goes straight to `planner_state_write` via `planner_crosscheck_accept_set`
(see [Accepting a genuine Crosscheck finding](#accepting-a-genuine-crosscheck-finding---accept)).

The team, project and milestone refs are recorded here as given. Epic Gen resolves them
to UUIDs, records the resolved ids with `planner_config_set`, and Ticket Gen reads those
ids straight back — so the epic and every child land on the same team and in the same
project, with one name lookup for the whole run.

`--team` is optional. With nothing set, `planner_linear_resolve_team_id` falls back to
the workspace's only team; when several are visible it fails naming them, because
guessing would file an entire initiative against the wrong board.

`--project` is optional too, but its absence is no longer silent. With neither
`--project` nor `--no-project` set, Epic Gen runs `planner_project_gate_check`
(`planner-project-gate.sh`) before creating anything: it lists the team's projects and
matches their names against the idea and the Affected Services. Exactly one match stops
the phase naming that project, so the operator confirms it with
`resume <ID> --create --project '<name>'` or opts out with `--no-project` — it is never
applied automatically, for the same reason `--team` refuses to pick between teams. Zero
or several matches proceed with no project, as before, but record an
`EpicGen|project|skip` entry in the state log so the omission is visible there rather
than in the Linear UI weeks later (#256). `--no-project` is persisted, so a workspace
that does not use Linear projects is asked once and never again.

### 3. Plan mode

When mode is `plan`:

1. Extract the idea from the second argument.
2. **PLANNER_REQUIRE_INTENT check.** If `PLANNER_REQUIRE_INTENT=true` and the argument is a raw string (not an existing file), hard stop and direct the user to `/grill-me`.
3. **Intent file gate (step 0).** If the argument resolves to an existing file:
   - Source `planner-intent-gate.sh` and run `planner_intent_gate "$path"` **directly** —
     not inside `$(...)`, which runs in a subshell and loses the values.
   - On hard stop (exit 1/2/3): report the reason and stop — no state created.
   - On pass (exit 0): the gate has set and exported `PLANNER_INTENT_READINESS`,
     `PLANNER_INTENT_RECOMMENDATION`, `PLANNER_INTENT_HASH`, `PLANNER_INTENT_PROFILE`
     in the current shell. They must still be set at step 7 (same shell, or
     re-export them).
   - Derive the state log's idea line: `IDEA=$(planner_intent_idea "$path")` (the
     `## Objective` lines joined, truncated to `PLANNER_IDEA_MAX_LENGTH`, else the
     path). Phase agents read the whole document (`artifacts/intent.md`).
   - The original file path is preserved as `PLANNER_INTENT_FILE` for later artifact capture.
4. Generate an initiative ID: `INIT-$(date +%s)-$(shuf -i 1000-9999 -n 1)` to avoid collision.
5. Initialize state: `planner_state_init "$INITIATIVE_ID" "$IDEA"`
6. **Persist the invocation config** — run step 2b now that `$INITIATIVE_ID` exists.
7. **If an intent file was accepted:** Copy the verified file byte-identically to `${state_dir}/artifacts/intent.md`, then run `planner_intent_capture_brief "$path" "$state_dir"`: a grill-me 0.4.0+ intent's `## Original Brief` replaces `artifacts/idea.txt` verbatim (Discovery reads it); an older intent prints `absent` and changes nothing. Write provenance with `planner_intent_record "$INITIATIVE_ID"` (`META|intent|done|<readiness>,<recommendation>,<hash>`), never by hand: it fails loudly, writing nothing, if a value is empty — then stop and re-run the gate.
8. Run the dispatch loop (see below). It ends after Crosscheck — `plan` creates nothing in Linear.

### 4. Resume mode

When mode is `resume`:

1. Extract the initiative ID from the second argument.
2. **Persist the invocation config** — run step 2b before anything is dispatched. `--create` must be on disk before Epic Gen becomes reachable, so that a crash in between cannot lose it.
3. Call `planner_resume "$INITIATIVE_ID"` — it outputs `PLANNER_NEXT_PHASE`, `PLANNER_INITIATIVE`, `PLANNER_LAST_LOG`.
4. If `PLANNER_COMPLETE=true` is output, first check for a Refinement re-run on the
   finished initiative (planner-refinement-convergence D6/D10). `--refresh-bodies` and
   `--converge` are accepted after Completed so a ticket ticket-auto held on drift, or
   one an operator converges, has a release path:

   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/planner-refinement.sh"
   REFINEMENT_AFTER_COMPLETED=""
   if planner_refinement_after_completed_pending "$INITIATIVE_ID"; then
     REFINEMENT_AFTER_COMPLETED=true
     PHASE="Refinement"
   fi
   ```

   When `REFINEMENT_AFTER_COMPLETED=true`, run step 7's item 1b once with that
   `PHASE` (it re-evaluates the affected children only and writes `META` lines only,
   so `planner_position_derive` still returns the empty string), then continue to
   step 8. Otherwise run the step-8 completion verification before reporting
   completion — an initiative whose Completed phase never ran also reports
   `PLANNER_COMPLETE=true` here once its log has a terminal entry.
5. Run the dispatch loop starting from the returned phase. When that phase is
   `Completed`, it is the terminal phase and still has to run — see step 7.

### 5. Status mode

When mode is `status`:

1. Extract the initiative ID from the second argument.
2. Read the state log: `planner_state_read "$INITIATIVE_ID"`
3. Run `planner_position_derive "$INITIATIVE_ID"` to get the current phase.
4. Run `planner_crosscheck_findings_summary "$INITIATIVE_ID"` (source
   `planner-crosscheck.sh` first if not already sourced). Empty output means no
   Crosscheck findings recorded — omit the section. Otherwise report it as its
   own "Crosscheck findings" section: the per-code lines and the trailing
   `TOTAL:` line, and note whether the initiative is currently halted on a
   blocking finding (blocking total > 0 and current phase is still
   `Crosscheck`) — see #176.
   When the initiative *is* halted that way, also run
   `planner_crosscheck_findings_report "$INITIATIVE_ID"` and report its output
   verbatim below the summary — the counts say how much is outstanding, the
   report says which artifact and which token to open first (#233).
5. **Refinement section** (planner-refinement-phase). Source
   `planner-refinement.sh` first if not already sourced, then resolve
   `EPIC_ID=$(planner_epic_id "$INITIATIVE_ID")`. No epic id yet (Epic Gen
   hasn't run) — omit the section entirely. Otherwise, for each child in the
   epic manifest's `children[]`, read its manifest `ready` field and report
   one line: the ticket id, `ready`/`not-ready`/`unavailable`, and — when
   not ready — its `missing` codes (deterministic and `SEMANTIC_*` both).
   When the current phase is still `Refinement` (the run is halted there),
   also run `planner_refinement_report "$INITIATIVE_ID"` and print its
   output verbatim below the per-ticket summary — same relationship as
   Crosscheck's own summary-then-report pair above.
6. **Open business decisions** (planner-specify-waiting-on-human). When the current
   phase is `Review`, source `planner-specify-decisions.sh` and run
   `planner_specify_decisions_open "$INITIATIVE_ID"` (read-only — never the gate,
   which can write a warn line). Each output line is `O<n>\t<hash8>\t<line>\t<question>`.
   With one or more lines, report the phase as
   `Review — waiting on N business decision(s): O1, O3` (the ids in file order)
   instead of plain `Review`.
7. Report: current phase, initiative metadata, last 10 log entries, artifact listing.

### 6. Replan mode

When mode is `replan`:

1. Extract the initiative ID from the second argument.
2. Verify the `Regenerate` flag is present in the state log or initiative artifacts.
3. If no Regenerate flag, report that re-planning requires the flag and stop.
4. Ingest feedback from `${state_dir}/feedback/` — read all JSON files, compute drift.
5. Compute readiness gaps: aggregate `summary.readiness_gaps` across the ingested feedback
   files via `planner_readiness_gaps_compute` — informational only, never a regeneration
   input (see "Re-planning details" below).
6. Identify undispatched Backlog tickets (read intent files, cross-reference with spawn queue).
7. For each eligible ticket, regenerate the Planner Context block with adjusted confidence.
8. Validate the regenerated dependency set is still acyclic.
9. Write `META|replan|done` to the state log with counts: tickets regenerated, unchanged, skipped
   (via `planner_replan_record`, which also writes the `META|replan-readiness-gaps` line from
   step 5).
10. Do NOT modify dispatched, in-progress, or completed tickets.

### 7. Dispatch loop

`CLAUDE_PLUGIN_ROOT` was already resolved and exported in step 1. Phase prompts do not
depend on it being inherited — `planner_prompt_for_phase` resolves the plugin root at
prompt-generation time and interpolates the literal path into each prompt's preamble,
so the spawned agent never has to resolve anything.

First open the run's telemetry record (the Stop hook closes it on any halt or completion):
`bash "${CLAUDE_PLUGIN_ROOT}/lib/planner-run-telemetry.sh" begin "$INITIATIVE_ID" || true`

Every halt below is one `planner_dispatch_gate <gate> "$INITIATIVE_ID" "$PHASE" "$STATE_DIR"`
call (`planner-router.sh`). It returns 0 to proceed, 3 after printing a normal stop, or 1
after an error on stderr; always call it as `... || exit $(($? == 3 ? 0 : 1))`. Report a
stop's output verbatim (do not re-summarize or re-order it) as a normal terminal outcome,
not a failure: do not ask the user whether to proceed, and never fall through to step 5's
retry budget, because a halt is a content decision that re-running cannot change. The
`resume` command it prints is the continuation, and it is theirs to invoke.

For each phase to run:

1. **Pre-dispatch gates.** If `$PHASE` is `EpicGen`, run step 1d first. Then:

   ```bash
   planner_dispatch_gate pre "$INITIATIVE_ID" "$PHASE" "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
   ```

   It runs, in order: the **create gate** (Epic Gen and Ticket Gen write to Linear; an
   unauthorized initiative stops with "Planning complete — nothing was created in
   Linear", the normal end of a `plan` run); for `Crosscheck`, the **Consensus
   readiness gate** (DET-PL-11: only an explicit `Readiness: blocked` in consensus.md
   halts; it holds no state and releases once a person changes Readiness or Consensus
   re-runs); for `Review`, the **open business decisions gate** (step 1c).

1a. **Crosscheck is not an agent phase.** If `$PHASE` is `Crosscheck`, run the check
    directly and skip steps 2–5 entirely — there is no prompt for it in
    `planner_prompt_for_phase`:

    ```bash
    planner_dispatch_gate crosscheck "$INITIATIVE_ID" "$PHASE" "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
    ```

    On a blocking finding it prints `planner_crosscheck_findings_report` (artifact →
    code, the offending token, a one-line fix hint per code, #233) and stops: the check
    is deterministic, so only an edit to the artifacts and a `resume` can change the
    answer. On success, run step 1d, then continue to step 6 (skip 2–5).

1b. **Refinement is not an agent phase either** (planner-refinement-phase). If `$PHASE`
    is `Refinement`, run it directly and skip steps 2–5 — like Crosscheck, it has no
    prompt in `planner_prompt_for_phase`:

    ```bash
    source "${CLAUDE_PLUGIN_ROOT}/lib/planner-refinement.sh"
    source "${CLAUDE_PLUGIN_ROOT}/lib/planner-linear-api.sh"
    _rf_rc=0
    planner_refinement_prepare "$INITIATIVE_ID" || _rf_rc=$?
    ```

    rc 2 is a legacy initiative (planned before this phase; skip lines written):
    continue to step 6. Any other non-zero rc: halt (`exit 1`). On rc 0 print prepare's output verbatim (the one-shot
    `--converge` result), run step 1e with `NEXT=planner_refinement_next` and
    `APPLY=planner_refinement_apply_pending`, then:

    ```bash
    planner_refinement_finish "$INITIATIVE_ID" "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
    ```

    It gates (or, with `REFINEMENT_AFTER_COMPLETED=true` from step 4, only reports),
    prints the advisory summary on a pass, and halts like a dispatch gate when a ticket
    is not ready. On a legacy-skip or a clean pass, continue to step 6 (skip 2–5).

1d. **Draft readiness gates the first Linear write** (planner-draft-readiness). Run it
    from step 1a's success path and from step 1 when `$PHASE` is `EpicGen`:

    ```bash
    source "${CLAUDE_PLUGIN_ROOT}/lib/planner-draft-readiness-gate.sh"
    _dr_rc=0
    planner_draft_readiness_begin "$INITIATIVE_ID" || _dr_rc=$?
    ```

    On rc 0, run step 1e with `NEXT=planner_draft_readiness_next` and
    `APPLY=planner_draft_readiness_apply`, then:

    ```bash
    [ "$_dr_rc" -eq 0 ] && { planner_draft_readiness_gate "$INITIATIVE_ID" || _dr_rc=$?; }
    case "$_dr_rc" in
    0 | 2) ;; # 2: skipped by --until Crosscheck, or accepted
    3) planner_draft_readiness_report "$INITIATIVE_ID"; exit 0 ;;
    *) echo "ERROR: draft readiness could not run (message above)" >&2; exit 1 ;;
    esac
    ```

    Report the output verbatim. rc 3 is a normal stop like Crosscheck's, not a retry:
    nothing is in Linear. The gate writes no manifest and calls no Linear endpoint; a
    resume on unchanged specs spawns nothing.

1e. **Spawn-list loop** (steps 1b and 1d name `NEXT` and `APPLY`, lib function names).
    Each Bash call re-sources the step's lib, sets `INITIATIVE_ID` and `REPOS_ROOT`, and
    passes `timeout: 600000` (settling a revise round can take minutes). Repeat:
    1. `_list=$($NEXT "$INITIATIVE_ID")`. `done 0` ends the loop. A non-zero rc or
       empty output is an error: halt (`exit 1`), never treat it as done.
    2. Each line is `<id>\t<kind>\t<subagent-type>\t<prompt-file>\t<result-file>`. Spawn
       one Agent per line, all in the same response (they are independent; a scan
       and the audit of the same id never share a list): `subagent_type` = column 3,
       `prompt` = the contents of the column-4 file, `description` = "<kind>: <id>".
       Wait for all; each writes its column-5 file.
    3. Run `$APPLY "$INITIATIVE_ID"` even if a spawn failed (the lib counts a missing
       result as a failed attempt), then go back to 1.

    After a crash, rerun the step (state is on disk). A failed agent is retried once,
    then recorded unavailable.

1c. **Open business decisions halt the loop** (planner-specify-waiting-on-human,
    planner-specify-parameters). Specify writes `NEEDS_HUMAN_DECISION — <question>` for
    an unstated Outcome in `## Business Outcomes` or an open row in `## Parameters`;
    step 1's `pre` gate halts on one before Review, and again before Crosscheck for rows
    Consensus opened. It holds no state and reruns on every dispatch. A person releases a
    decision with `--answers` (`specify-answer:O<n>` / `specify-param:<key>`), `__defer__`
    or a hand edit of proposal.md. Its only write is one `META|specify-gate|warn` line
    per proposal version for malformed text. Detail: `docs/ticket-planner.md` § Parameters.

2. **Get the prompt** for the current phase:
   ```bash
   prompt=$(planner_prompt_for_phase "$PHASE" "$INITIATIVE_ID" "$IDEA" "$STATE_DIR") ||
     { echo "HALT: $PHASE prompt failed (message above) — fix it and resume" >&2; exit 1; }
   ```

   The prompt carries the invocation config as literals read from the state log. Never
   pass configuration through the environment; the agent does not inherit this shell.

3. **Spawn the agent** using the Agent tool with:
   - `description`: "Run planner phase: $PHASE for $INITIATIVE_ID"
   - `prompt`: the phase prompt from `planner_prompt_for_phase`
   - `subagent_type`: "general-purpose" (the agent needs Read, Bash, and Linear API access)
   - `timeout_ms`: \$((PLANNER_PHASE_TIMEOUT * 1000)) (default 600000ms = 10min)

4. **Wait for the agent** to complete. The agent writes state log entries itself.

4a. **ADR gate halt bridge (adr-governance-gate).** Before step 5's retry check: a
    blocking ADR verdict needs a human to accept or resolve the ADR out of band, so it
    halts instead of consuming the retry budget (it is a no-op for any other phase):

    ```bash
    planner_dispatch_gate adr "$INITIATIVE_ID" "$PHASE" "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
    ```

5. **Check the result.** The retry budget is derived from `fail` entries in the state
   log, not held in memory, so it survives a crashed router:

   ```bash
   if planner_phase_retries_exhausted "$INITIATIVE_ID" "$PHASE"; then
     echo "ERROR: ${PHASE} exhausted its retry budget (PLANNER_MAX_PHASE_RETRIES=${PLANNER_MAX_PHASE_RETRIES:-2})" >&2
     exit 1
   fi
   ```

   - If the agent succeeded (state log shows `done` for this phase), continue to step 6.
   - If the agent failed (state log shows `fail`) and the budget is not exhausted, retry
     the same phase.
   - If the state log has no terminal entry for the phase (agent crashed), retry
     (phases are idempotent, so re-running is safe).

6. **Check the stop condition.** The create gate and `--until` collapse into one
   earliest-stop-phase decision, resolved entirely from the state log:

   ```bash
   planner_dispatch_gate stop "$INITIATIVE_ID" "$PHASE" "$STATE_DIR" || exit $(($? == 3 ? 0 : 1))
   ```

   The stop report names the phase reached, the artifact and spec directories, the
   state log and the exact continuation command.

7. **Advance** by re-reading `planner_position_derive`, and read its result exactly:

   ```bash
   NEXT_PHASE=$(planner_position_derive "$INITIATIVE_ID")
   ```

   - **Any phase name — including the literal `Completed`** — means that phase has
     not run yet. Loop back to step 1 with `PHASE=$NEXT_PHASE`.
   - **The empty string is the only value that means the initiative is finished.**

   `Completed` is the terminal *phase* (11 of 11), not a terminal *state*: it writes
   `artifacts/COMPLETED.md` and the final state log entry, and it is dispatched in
   this same invocation — immediately after Refinement's gate passes clean (or
   legacy-skips), never left for the operator to remember to `resume` into (#226).
   Nothing gates it: Completed writes only to disk, so `planner_create_gate_check`
   waves it through, and step 6 has already stopped the loop first if `--until
   TicketGen` or `--until Refinement` asked it to. Use the predicate rather than
   comparing the string by hand:

   ```bash
   if planner_terminal_pending "$INITIATIVE_ID"; then
     : # dispatch Completed now — do NOT report the run as finished
   fi
   ```

   A run that stops after Refinement's gate stamp looks done from Linear while
   `COMPLETED.md` was never written; dispatching Completed here closes that gap.

### 8. After completion

When the dispatch loop finishes (`planner_position_derive` returns empty):

1. **Verify the terminal phase actually produced its artifacts** before reporting
   anything. This is the only check anywhere in the pipeline that looks for
   `COMPLETED.md` specifically:

   ```bash
   if ! planner_completion_verify "$INITIATIVE_ID"; then
     # Phases are idempotent — re-dispatch Completed once, then re-verify.
     ...spawn the Completed agent (steps 2-4 above with PHASE=Completed)...
     if ! planner_completion_verify "$INITIATIVE_ID"; then
       echo "ERROR: the Completed phase did not write its summary — the initiative is NOT finished." >&2
       exit 1
     fi
   fi
   ```

   Do not report the run as complete while this fails. `planner_completion_verify`
   names what is missing on stderr: no terminal state log entry means the phase never
   ran, a `done` entry with no file means it half-ran.
2. Read the completion summary from `${STATE_DIR}/artifacts/COMPLETED.md`.
3. Report to the user:
   - Initiative ID
   - Epic ID
   - Number of tickets created
   - Whether auto-dispatch will pick them up (FLEET_AUTO_DISPATCH status)
   - Path to the state log for inspection

## Re-planning details

Background: `docs/ticket-planner.md` § Re-Planning. The rules step 6 applies:

1. **Drift:** per ticket, `confidence_predicted` (Planner Context block) minus
   `confidence_actual` (feedback).
2. **Readiness gaps are report-only:** `planner_readiness_gaps_compute` sums gate-stop
   counts and per-code breakdowns and unions `affected_tickets`; never an input to the
   steps below.
3. **Adjust confidence:** apply drift to the original signal. Average drift > 0.15
   (systematic overconfidence) applies a uniform penalty to every regenerated ticket.
4. **Scope:** regenerate only tickets in `Backlog`, absent from the spawn queue, and not
   completed or merged.
5. **Re-validate:** the regenerated dependency set must be acyclic. If regeneration removes
   a ticket others depend on, update the dependents or abort.
6. **Record:** `META|replan` with the triggering flag, the feedback files considered, drift
   per ticket and regenerated/unchanged/skipped counts, plus `META|replan-readiness-gaps`
   (via `planner_replan_record`'s 8th parameter) with the aggregate, or the literal `none` —
   written unconditionally.
