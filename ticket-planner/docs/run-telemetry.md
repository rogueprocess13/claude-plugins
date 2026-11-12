# Run telemetry (planner and grill-me)

ticket-planner and grill-me record how long each planner phase and each grill
round took, and how many tokens it used, plus one summary per run. All of it is
bash and jq. No model is involved, and tokens are never estimated: when no
transcript holds them, the field is `null`.

## Where the tokens come from

Claude Code writes every subagent's transcript to
`<projects>/<project-slug>/<session-id>/subagents/agent-<id>.jsonl`, next to a
`agent-<id>.meta.json` that holds the `description` the caller passed to the Agent
tool. The planner's spawns already use fixed descriptions:

| Spawn | Description | Attributed to |
|---|---|---|
| Phase agent (SKILL.md step 7.3) | `Run planner phase: <Phase> for <INIT>` | that phase |
| Spawn-list agent (step 1e) | `<scan\|audit\|revise>: <id>` | `Refinement` when `<id>` is a ticket of the initiative, `DraftReadiness` when it is one of its draft slugs |
| Goldfish lens (step 1e, planner-goldfish-review) | `lens: <INIT>` | `Review`, for this initiative only: the first Review attempt that started at or after the transcript ended (less 5s), since the lens finishes before Review writes its first line |

A transcript is added to the latest attempt of its phase that started before the
transcript ended. Usage is summed once per message id: Claude Code writes one
line per content block of a streamed message, and each line repeats the whole
message's usage.

grill-me's assessment runs in the skill's own context (no subagent), so a
round's tokens are the session transcript's assistant usage between the round's
start and end. The planner's own orchestration tokens are counted the same way,
over the run's window, as `tokens.orchestrator` in the run record.

`<projects>` is `${CLAUDE_CONFIG_DIR:-~/.claude}/projects`
(`PLANNER_TRANSCRIPT_ROOT` / `GRILL_TRANSCRIPT_ROOT` override it).

### Why not the ticket-auto token-tracker hooks

`ticket-auto-pipeline/hooks/token-tracker*.sh` resolve the spawn from a
`ticket-auto-<ID>-spawn-meta.txt` in the private scratch dir, keyed by
`SESSION_ID`, and write `META|tokens` to its `LOG_FILE`. Reusing them would mean:

- writing a planner spawn-meta whose `LOG_FILE` ends in `-pipeline.log`, because
  the hooks refuse any other name (#619), and fleet detectors treat every
  `*-pipeline.log` as a live ticket pipeline;
- the step 1e spawn-list agents are named agent types, and named spawns arrive
  without `agent_transcript_path`, so the hook would skip them;
- grill-me has no subagent at all, so `SubagentStop` never fires for it.

Reading the transcript files after the fact needs none of that, and changes no
ticket-auto file.

## When records are written

| Plugin | Record | Written by |
|---|---|---|
| ticket-planner | `planner_phase` | `planner_telemetry_sync` — at the end of each run and by the read-out. One line per closed attempt, rebuilt from `state.log` |
| ticket-planner | `planner_run` | the plugin's `Stop` hook (`hooks/planner-telemetry-stop.sh`) when the planner's turn ends — completion and every halt alike. A run that never reached its hook is closed by the next `begin`, at its last state.log line (`closed_by: next-begin`) |
| grill-me | `grill_round` | `grill_score` itself, after it writes `result.json` |
| grill-me | `grill_session` | the plugin's `Stop` hook (`hooks/grill-telemetry-stop.sh`), one per invocation: sealed, waiting for answers, at the round cap, aborted or refused |

SKILL.md calls `planner-run-telemetry.sh begin "$INITIATIVE_ID"` once, before the
dispatch loop. That registers the Claude session (one file per session under
`${XDG_STATE_HOME:-~/.local/state}/ticket-planner/telemetry/sessions/`) so the
hook knows which initiative to close. grill-me needs no prose: `grill_score`,
`grill_answers_fold` and `grill_seal_generate` call `lib/grill-telemetry.sh`
themselves, and only inside a Claude Code session (`CLAUDE_CODE_SESSION_ID`).

## Where they are stored

- ticket-planner: `<initiative>/telemetry/runs.jsonl`
- grill-me: `<work_dir>/telemetry/runs.jsonl`

Not the workspace `runs.jsonl` ticket-auto writes. The initiative is the unit a
rehearsal reads, the file needs no lock shared with merge-poll, and the record
`kind`s are distinct anyway: every ticket-auto reader (`merge-poll.sh`,
`manifest-read.sh`, `pipeline-finalize.sh`, `run-score-export.sh`, fleetd's cost
index) selects on its own `kind`, which `test-planner-run-telemetry.sh` checks
against a file mixing all four new kinds.

## Attempts

An attempt is a run of consecutive `state.log` lines of one phase. META steps
count toward the phase that writes them (`crosscheck` → Crosscheck,
`refinement*` → Refinement, `ticketgen` → TicketGen, `adr-gate` → Architecture,
`draft-readiness`/`draft-revise` → the pseudo-phase `DraftReadiness`).
Configuration lines are ignored. A new attempt starts at another phase's line,
at any line after a `fail` or a halt, or when a step starts a second time.
A Crosscheck re-run inside the draft readiness gate stays part of that gate run.

Wall-clock is first to last line, at the log's one-second resolution, so the
agent's start-up before its first line is not counted. Outcomes: `done`, `skip`,
`fail`, `halt` (with `halt_code` `CROSSCHECK_BLOCKED`, `DRAFT_NOT_READY`,
`REFINEMENT_HALT` or `ADR_GATE`), and `incomplete` for an attempt that never
wrote a terminal line before the next one started. The last attempt is not
written while it is still open.

## Record fields

`planner_phase`: `initiative`, `run_id`, `phase`, `attempt`, `started_at`,
`ended_at`, `wall_ms`, `outcome`, `halt_code`, `revise_rounds` (DraftReadiness
only), `agents`, `agent_types`, `tokens` (`input`, `output`, `cache_read`,
`cache_create`, or `null`), `model`.

`planner_run`: `run_id`, `session_id`, `started_at`, `ended_at`, `wall_ms`,
`start_position`, `furthest_phase`, `next_phase` (empty means finished),
`stop_reason` and `halt_code` (from `planner-stop-describe.sh`),
`phase_attempts`, `failed_attempts`, `draft_revise_rounds`,
`draft_revise_spawns`, `human_answer_rounds` (`META|human-hold|done` in the
window), `unmeasured_phases`, `tokens.phases` / `tokens.orchestrator` /
`tokens.total`, `closed_by`.

`grill_round`: `grill_id`, `session_id`, `invocation`, `round`, `started_at`,
`ended_at`, `wall_ms`, `human_wait_ms` (AskUserQuestion call to answer),
`readiness`, `recommendation`, `questions`, `tokens`, `model`.

`grill_session`: `invocation`, `status` (`sealed`, else `state.json`'s status,
else `unsealed`), `sealed_path`, `verdict`, `score`, `rounds`,
`rounds_this_invocation`, `human_wait_ms`, `tokens`, `closed_by`.

## Read-out

```bash
REPOS_ROOT=... bash ticket-planner/lib/planner-run-report.sh <INIT>   # planner
bash grill-me/lib/grill-telemetry.sh report <work_dir>                # grill-me
```

The planner read-out prints a phase table, a run table and two lines,
`Timing:` and `Cost:`, for a rehearsal iteration's `run-record.md`. A phase with
agents but no transcript prints `UNMEASURED`; a bash-only phase prints
`n/a (bash)`.

## Known gaps

- Tokens need the transcript files on the machine that ran the session. A run
  on another host, or after the transcripts were cleaned up, reports
  `UNMEASURED`.
- A phase agent spawned with a description other than the one in SKILL.md
  (for example a hand-run retry) is not matched.
- Cost in USD is not computed: only tokens are recorded.
- Planner phase lines are written by the agents themselves; a phase that writes
  none (an agent that crashed before its first line) has no attempt to carry
  its tokens.
