# State Log Format

Shared format spec for ticket-planner state logging. Phase agents write progress entries to the state log so the router can derive position and resume after interruption. Same pipe-delimited convention as ticket-auto's pipeline log.

## Format

```
ISO|PHASE|STEP|STATUS|MSG
```

Pipe-delimited, no escaping. `ISO` = UTC timestamp from `date -u +%Y-%m-%dT%H:%M:%SZ`.

## Usage

Phase agents write entries via `planner_state_write` from `planner-state.sh`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/planner-state.sh"
planner_state_write "${initiative_id}" "Appraisal" "scope" "start" "Interpreting idea"
# ... do work ...
planner_state_write "${initiative_id}" "Appraisal" "scope" "done" "Scope summary written"
```

Direct writes (without `planner_state_write`) bypass duplicate detection, atomic flock, and pipe sanitization — avoid them.

## Statuses

| Status | Meaning |
|--------|---------|
| `start` | Step began |
| `done`  | Step completed successfully |
| `fail`  | Step failed — will be re-executed on resume (not terminal) |
| `skip`  | Step skipped (not applicable, terminal) |

`fail` is explicitly non-terminal. On resume, a phase that ended with `fail` is re-executed. Only `done` and `skip` advance to the next phase.

## Phases & Steps

Each phase has one primary step. Agents may write additional `start`/`done` pairs for sub-steps.

### Appraisal
`scope` — interpret idea, establish scope, identify affected services

### Discovery
`explore` — trace code paths, resolve symbols, find prior art

### Architecture
`design` — evaluate alternatives, select approach, write ADR

### Specify
`synthesize` — write proposal, per-ticket specs, signals JSON blocks

### Review
`critique` — find gaps, risks, feasibility issues

### Consensus
`resolve` — address review findings, finalize proposal

### Crosscheck
`check` — run the citation ([#172](https://github.com/willard-pro/claude-plugins/issues/172)) and cross-ticket propagation ([#173](https://github.com/willard-pro/claude-plugins/issues/173)) linters; `fail` means at least one blocking finding, not an agent crash (see `META|crosscheck` below)
`testdata-synth` — test-data synthesis (planner-test-data-derivation), written after `check|start` and before any check family: `start`, then `done` with `{N} TD spec(s), {M} need(s)`. On failure there is no `fail` line (it would count as a phase failure); the `start` stays unclosed and each problem is a blocking `META|crosscheck|fail|TEST_DATA_SYNTH_FAILED …` finding. `planner_position_derive` ignores these lines

### EpicGen
`create` — create Linear epic with idempotency guard
`branch-directive` — decide and optionally append shared-branch directive to epic description

### TicketGen
`validate` — pre-creation dependency and spec validation
`create-gate` / `team` — create-gate re-check, team resolution (`fail` only — no `done` line, per-ticket progress is `META|ticketgen|…` below)
`verify` — post-creation verification (`planner_verify_tickets`). The **only** phase-named line TicketGen ever writes with status `done` — `fail` on a missing manifest, retried. Per-ticket generation progress (start/step/done) moved to `META|ticketgen|…` (planner-refinement-phase) so a verify failure can never hide behind an earlier `generate|done` line the way position derivation's "stop at the first done" rule used to let it. **Retired**: `dispatch-gate` — this phase no longer stamps the epic manifest's `dispatch` flag (historically the `state:execution` label); see Refinement below

### Refinement
Not an agent phase — driven by the dispatch loop as bash (`lib/planner-refinement.sh`), like Crosscheck. Writes no `start`/`fail` lines of its own; progress is `META|refinement|…` (see below) and the single terminal line:

`gate` — `done` once every child ticket has a deterministic-and-semantic readiness verdict *and* every one is ready (stamps the epic manifest `dispatch=true`); `skip` when the initiative is legacy (its log already carries the retired `TicketGen|dispatch-gate|done` line) — the epic is still stamped if not already, and the run advances straight to Completed. **A halt writes neither `done` nor `fail`** — only `META|refinement-gate|fail` (see below) — so `planner_phase_fail_count` never counts a halt as a retry, and `planner_position_derive` (which skips `META` lines) keeps returning `Refinement` until every child is ready.

### Completed
`summarize` — write completion summary, verify handoff readiness

## META Pseudo-Phase

`META` is a pseudo-phase for metadata entries outside the phase sequence:

| Step | Description |
|------|-------------|
| `schema` | Schema version declaration (must be first line: `META|schema|start|1`) |
| `initiative-id` | Initiative identifier |
| `idea` | The original business idea (pipes/newlines sanitized) |
| `intent` | Accepted grill-me intent: readiness, recommendation, seal hash |
| `replan` | Re-planning event: trigger, feedback runs, drift summary, counts (written as `replan-start`/`replan-drift`/`replan-result`, see `replan-readiness-gaps` below) |
| `replan-readiness-gaps` | readiness-feedback-loop. Written unconditionally by `planner_replan_record` between `replan-drift` and `replan-result`: the aggregated `summary.readiness_gaps` across every ingested feedback file (gate-stop counts, per-code breakdown, affected tickets), or the literal `none` when the sum carries no gaps. Report-only — surfaces `fleet-controller`'s readiness-gap scan for an operator to read; never changes regeneration logic (confidence adjustment, ticket selection, dependency validation) |
| `crosscheck` | One Crosscheck finding. `fail` = blocking (`{CODE} {message}`, blocks EpicGen — [#176](https://github.com/willard-pro/claude-plugins/issues/176)); `warn` = non-blocking (`info {CODE} {message}`); `accepted` = operator override via `resume <ID> --accept CODE:"reason"` (`{CODE} {reason}` when written at parse time, `{CODE} {message}` when a still-occurring finding is confirmed non-blocking on a later run — [#222](https://github.com/willard-pro/claude-plugins/issues/222)). One entry per finding, written by `planner_crosscheck_run` in `lib/planner-crosscheck.sh` |
| `adr-gate` | Architecture phase's ADR gate verdict (adr-governance-gate). `fail` = a blocking verdict (`{VERDICT} ADR_ID={id}`, one of `CREATED_PROPOSED`\|`SUPERSEDE_REQUIRED`\|`CONFLICT`) — halts the dispatch loop via `planner_adr_gate_blocked` in `lib/planner-adr-gate.sh`, mirroring the `crosscheck` halt above; the planner has no human-hold infrastructure, so there is no `waiting` status here the way `ticket-auto-pipeline`'s pipeline log has for `human-hold`. `NOT_ARCHITECTURAL`/`GOVERNED` verdicts write nothing here — the phase's own `Architecture\|design\|done` line is sufficient. Written by the Architecture phase agent per `planner-phase-prompts.sh` § 4.5 |
| `ticketgen` | TicketGen's per-ticket generation progress (planner-refinement-phase) — `start`/`step`/`done`, e.g. "Generating N planned tickets" / "Created TICK-1: \<title\>" / "N tickets created, M skipped, K failed validation". Never a phase-named line — see TicketGen's own `verify` step above for why |
| `refinement` | Refinement's per-ticket progress and the legacy-skip marker (planner-refinement-phase). `skip\|legacy` when the initiative predates this change; otherwise informational progress as each ticket's deterministic/semantic pass completes. Written by `lib/planner-refinement.sh` |
| `human-hold` | One answered question round (planner-headless-questions). `start` then `done`, both `round={N} sha={sha256 of the answers file}`, written by `planner_answers_apply` (`lib/planner-answers.sh`) for `resume <ID> --answers <file>`: `start` before the bindings are applied, `done` after — always the last line the intake writes. The count of `done` lines is how `planner-stop-describe.sh` numbers the next round (`ROUND` = count + 1), and the `done` line is the replay key: the same file again is a no-op, a different file for the same round is refused. The `start` line also lets a later round's `done` past duplicate-done suppression |
| `consensus-answer` | One headless answer to a cited-artifact question ([#515](https://github.com/willard-pro/claude-plugins/issues/515)). `step`, `cited:{n} {answer} (round {N}, by {who})`, written by `planner_answers_apply` after `planner_cited_answer_set` rewrites the `Answer:` field of consensus.md's `n`th `CITED_ARTIFACT:` question, between that round's `human-hold` `start` and `done`. Audit only; Crosscheck reads the answer from consensus.md. Also `testdata:{slug} [{hash8}] {answer} (round {N}, by {who})` for a `TEST_DATA_IMPLIED` answer, written after `planner_testdata_answer_set` writes the `TESTDATA_CONFIRM` line |
| `refinement-gate` | `fail` = at least one child is not ready (`{n} of {m} not ready`), or the epic id could not be resolved from the state log (`no EpicGen EPIC_ID found in state log`) — this is the halt signal `planner_refinement_report` explains in full when the dispatch loop prints it. Never `done` — a clean pass writes the phase-named `Refinement\|gate\|done` line instead (see Refinement above) |
| `refinement-testdata` | `warn` only (dor-semantic-test-data-gap): `<TID> TEST_DATA_GAP: "<quote>" — <detail> [<hash8>]`, one line per verified advisory `TEST_DATA_GAP` semantic finding, where `<hash8>` is the first 8 hex characters of the finding's `semantic.body_hash`. Written by `_planner_refinement_note_testdata` in `lib/planner-refinement.sh` after a successful `planner_refinement_apply`, at most once per ticket per body hash (an edited body records anew; a resume does not repeat it). **Never blocks**: it is not a gate signal, and a failed write never changes the apply's exit code. The Completed phase lists every such line under Warnings |

### Invocation config

A second group of `META` steps records what the operator asked for at invocation
time. These are written with status `done` by `planner_config_set` and read back by
`planner_config_get`:

| Step | Description |
|------|-------------|
| `create-authorized` | The operator passed `--create`. Until this entry exists, no phase may write to Linear |
| `stop-after` | Phase to stop after (`--until`). The literal `none` clears one an earlier invocation set |
| `linear-team` | Team key, name or id as given (`--team` / `LINEAR_TEAM_ID`) |
| `linear-team-id` | The team UUID Epic Gen resolved, reused verbatim by Ticket Gen |
| `linear-project` / `linear-milestone` | Project and milestone as given on the command line |
| `no-project` | `true` when `--no-project` was passed — a deliberate opt-out from any Linear project, which silences Epic Gen's project gate |
| `linear-project-id` / `linear-milestone-id` | The UUIDs Epic Gen resolved them to, reused verbatim by Ticket Gen |
| `branch-override` | `shared` or `no-shared`, from the branch flags |
| `uat-policy` | The Branch Directive UAT policy, per-ticket or epic, from `PLANNER_UAT_POLICY` (planner-test-data-derivation). Unset: Epic Gen derives the epic policy for a shared-branch epic with synthesized test-data specs |
| `refresh-bodies` | `true` when `--refresh-bodies` was passed (planner-refinement-phase) — a one-shot action, not a sticky setting: the dispatch loop clears it back to `none` immediately after Refinement consumes it, so a later plain `resume` does not keep re-fetching from Linear |

Config exists as log entries rather than shell variables because the dispatch loop
spans one process per phase — an `export` at argument-parsing time is gone by the next
iteration. Persisting the decision is what makes it survive both that boundary and a
crashed router.

Config steps are **last-write-wins** and are the one exception to duplicate-`done`
suppression: `resume --create` has to be able to override the stop point `plan`
recorded, and a suppressed re-write would leave the stale value in force. Read them
with `planner_config_get`, which takes the last matching entry.

## Schema

Schema version `1`. Declared as the first line of every state log:

```
2024-01-15T10:00:00Z|META|schema|start|1
```

`planner_state_init` writes this automatically. `planner_state_repair` validates it.

## Integrity

- **Duplicate detection:** `planner_state_write` rejects `done`→`done` for the same phase+step. Allows `fail`→`done` (retry pattern), and exempts the `META` invocation-config steps, which are last-write-wins.
- **State log repair:** `planner_state_repair` validates every line (ISO format, known phase, valid status), drops invalid lines, strips trailing partial writes (crash mid-write).
- **Phase ordering:** `planner_position_derive` reads the log in reverse to find the last completed phase. Incomplete trailing entries (crash mid-phase) cause resume at that phase.
- **Pipe character safety:** The message field may contain arbitrary text from agent output. `planner_state_write` does not sanitize the message parameter — callers should avoid `|` in messages. `planner_state_repair` preserves trailing fields by reconstructing with `printf` rather than `cut`.
