# CLAUDE.md — fleet-controller

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Parent orchestrator above ticket-planner and ticket-auto. Fleet controller dispatches planned tickets from initiative epics, monitors all active pipeline health via 18 detection engines, and aggregates execution feedback back to the planner. Bash-only — zero Claude agents, zero LLM reasoning. All detection and intervention is deterministic.

## Directory layout

```
fleet-controller/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/fleet-controller/        # Single skill: /fleet-controller
  lib/                            # Shared bash libraries
  lib/tests/                      # Test suites
  fleetd/                         # Python 3 supervisor daemon (stdlib-only)
  fleetd/schema.sql               # Fleet state store schema (SQLite, v2)
  fleetd/store.py                 # State store module — fleetd is its sole writer
  fleetd/phase_dispatch.py        # Phase-level dispatch — table loader, classifier, spawn construction, loop caps, spawn bracket
  fleetd/gate_hold.py             # Hold reconciliation on its own cadence, kind-dispatched (a hold is a row, not a process)
  fleetd/orchestration.py         # Executor for the table's declared between-phase steps — bash gates, flow triggers, auto-merge
  fleetd/preamble.py              # Once-per-ticket preamble caller — env file, log init, branch context, preflight
  fleetd/otel.py                  # OTel exporter — the ONLY module with a third-party dep
  fleetd/requirements-otel.txt    # That dep, optional and deliberately not project-wide
  docs/                           # Architecture and reference docs
```

## fleetd supervisor daemon

`fleetd` is a long-lived Python 3 daemon that owns worker process lifecycle. It replaces cron-based fleet invocation for spawn and kill operations. Detection engines remain in bash; fleetd invokes them as subprocesses.

**Key properties:**
- **Real PIDs**: Every worker's registry PID is the PID of a process fleetd forked. No sentinel zeros. (The legacy cron/monitor path writes a PID=0 sentinel until the spawn captures the real PID — startup reconciliation's live-process check compensates so such workers are not re-enqueued.)
- **Single-instance**: `fcntl.flock` on a pidfile; kernel releases on death.
- **Kill escalation**: Cooperative stop → SIGINT → SIGTERM → SIGKILL, signalling the process group, with a liveness re-check + zombie reap + fence write after each rung. The SIGINT rung exists because a headless `claude -p` worker exits **0** on SIGINT, not a signal-derived code — so `killed_by_fleet` attribution comes from `kill_worker()`'s own success, never from an exit code (a bare `exit 143`/`0` is not proof of anything). See "Worker exit records" below.
- **Crash recovery**: On restart, verifies surviving PIDs via `/proc/<pid>/stat` start time before adoption. When `/proc` start-time verification is unavailable, falls back to a cmdline substring match — a known limitation: a reused PID whose command line happens to contain the ticket ID could be misadopted (documented and tested, not fixed). Stale registry deletion preserves the last-known generation to `{tid}-last-generation` so a reconciled re-spawn continues the generation sequence. Startup orphan reconciliation (pipeline-log-based, read-only) re-enqueues `incomplete` tickets whose workers died while fleetd was down; the restart cap reuses the existing `FLEET_MAX_RESTARTS` mechanism.
- **Generation fencing**: Supervisor assigns generations above any fenced predecessor.
- **CLI alignment**: The `/fleet-controller` skill writes kill requests to `{state_dir}/kill-requests/`; fleetd processes them.
- **Worker identity**: fleetd generates a `--session-id <uuid>` before exec (not the `SessionStart` hook — that can't fire for a worker SIGKILLed before startup completes) and appends `--output-format json` for machine-readable `session_id`/`stop_reason`/`total_cost_usd`/`permission_denials`/`is_error` on the final turn. `FLEET_WORKER_PID` and `FLEET_WORKER_START_TICKS` (the child's own PID + `/proc` start-ticks) are stamped into the worker's env so the ticket-auto-pipeline watchdog (`spawn-helper.sh`) can tell a live worker from a stale/reused PID instead of trusting its own continued existence as a liveness proxy. `FLEET_GENERATION` (the worker's generation number) and `FLEET_VERSION` (the fleet-controller plugin version, read once from `plugin.json`, fail-soft to `''`) are stamped alongside them (Commercial Evidence MVP Branch C) so ticket-auto-pipeline's `run-identity.sh` can carry real `gen`/`fleet` values in `META|run-id`/`META|version` instead of the permanent `null` those fields carried for every fleetd-dispatched run before this.
- **Explicit permission mode**: fleetd appends `--permission-mode ${FLEET_WORKER_PERMISSION_MODE:-bypassPermissions}` unless `CLAUDE_CMD` already specifies one. `dontAsk`/`auto` are deliberately never defaulted to — `auto` has no turn boundary in non-interactive mode, so one classifier denial silently poisons the rest of the run.
- **Headless-worker isolation** (headless-worker-isolation): root-caused from a live WIL-77 failure — three consecutive generations of a fleetd-spawned `/ticket-auto` worker ran `ps aux | grep ticket-auto`, matched their own command line, concluded a conflicting worker was already running, and stopped to ask a nonexistent human which one should win; each false stop became a claude-mem observation that seeded the next generation's context, compounding the mistake across restarts. Every spawned worker (`_build_worker_cmd`) now carries `HEADLESS_WORKER_CONTRACT` via `--append-system-prompt` — no questions, no process-table inspection, `detect-resume.sh` output is the only router — unless `CLAUDE_CMD` already sets `--system-prompt`/`--append-system-prompt` itself. Independently, `FLEET_WORKER_ISOLATE_SETTINGS` (default true) appends `--setting-sources project,local` plus a `--settings` override re-enabling only the `ticket-auto-pipeline`/`fleet-controller` plugins — live-probed (`claude -p ... --setting-sources project,local`) as the mechanism that actually silences claude-mem's plugin SessionStart hook (the 12KB "recent context" block that seeded the false positive above), the learning/explanatory output-style hooks, and caveman mode, all three enabled only at user scope. Neither mechanism touches secrets (`LINEAR_API_KEY`, `GITHUB_PERSONAL_ACCESS_TOKEN`, `CLAUDE_CMD`, ...) — those reach the worker via `worker_env = dict(os.environ)`, fleetd's own process environment populated by `fleet-start.sh` from project-scoped `.claude/settings.local.json`, never via Claude Code's own user-settings merge.
- **Deterministic-failure circuit breaker**: a streak of `FLEET_DETERMINISTIC_FAILURE_COUNT` consecutive fast (`< FLEET_DETERMINISTIC_FAILURE_SECS`) non-zero-exit workers halts dispatch (`spawn_enabled=False`) instead of burning `FLEET_MAX_RESTARTS` per ticket — a bad `CLAUDE_CMD` or expired auth would otherwise restart every ticket in the fleet to the cap before anyone noticed.
- **Startup env-check gate**: `__main__.py`'s `_run_startup_env_check()` shells out to `lib/fleet-env-check.sh` before constructing the `Supervisor` and refuses to start (nonzero exit) if it reports any issue — the daemon-process equivalent of ticket-auto-pipeline's Step-0 `validate-env` prose guard, which fleetd has no LLM turn to run inline. Reads `PROJECT_DIR` from fleetd's own cwd, same as a manual `/fleet-controller:fleet-env-check` run. Opt out with `FLEET_STARTUP_ENV_CHECK=false` (used by fleetd's own subprocess-spawning tests, which exercise supervisor mechanics only and have no reason to depend on a real `LINEAR_API_KEY`/`CLAUDE_CMD`).

**Invocation:** `python -m fleet-controller.fleetd [--port PORT] [--state-dir DIR]`

**Gating:** Set `FLEETD_SPAWN_ENABLED=1` to enable worker spawning. Default is observe-only (detection + health API, no spawns). Startup itself is gated separately by the env-check above — this flag only controls whether an already-running fleetd spawns workers.

**HTTP control surface (on-demand, loopback-bound):** alongside `GET /health`, fleetd serves `POST /dispatch` (scoped dispatch of one epic against the running daemon — same `fleet_dispatch_initiative` the skill and auto-sweep call, spawns immediately instead of waiting for the poll cycle), `POST /stop` (epic-scoped stop: purge queue, escalate-kill workers, write `stop-{epic}.json`; the single bash implementation is `fleet_stop_initiative`, also reachable via the skill's `stop` subcommand with the daemon down), and read-only `GET /workers`, `GET /workers/<tid>` (phase/anomalies/tokens/confidence per worker), `GET /queue`, `GET /epics`. Use these as an alternative to the `/fleet-controller dispatch` skill (on-demand, no restart-to-reconfigure) and to the fleet dashboard (per-ticket detail without re-rendering the whole fleet). Dispatch is the single start/resume/un-stop entry point: a stop-file gates every dispatch trigger path until an explicit `resume: true` clears it; the auto-sweep never clears. See README "HTTP API" for request/response shapes.

## Phase-level dispatch (two invocation modes)

fleetd can run a ticket through the pipeline two ways:

- **Ticket-level** (the original mode, still the default): fleetd spawns one
  `claude -p '/ticket-auto-pipeline:ticket-auto {tid} --auto'` worker, and
  that worker — an LLM reading `ticket-auto/SKILL.md`'s dispatch table —
  sequences every phase itself inside one long-lived process. Plugin-qualified
  since headless-worker-isolation Task C: a bare `/ticket-auto` can resolve to
  a stale personal skill of the same name under `~/.claude/skills/` instead of
  the plugin's own current version (WIL-77's actual root cause — the worker
  ran a skill months out of date), and the qualified form cannot be shadowed.
- **Phase-level**: fleetd spawns one short-lived `claude -p '/ticket-<phase>
  {tid} ...'` worker per phase and sequences them itself in Python, deciding
  done/fail deterministically from exit code, log markers and
  `META|phase-result` rather than reading agent prose.

Both modes read the same canonical file, `ticket-auto-pipeline/skills/ticket-flow/dispatch-table.json`
— the manual path's rendered `SKILL.md` table and phase-dispatch's in-memory
phase sequence are two views of one JSON, which is what keeps a table edit
from silently diverging the two paths (a coverage test asserts every
`step_id` has a phase-dispatch handler; see "Dispatch table" in
`ticket-auto-pipeline/CLAUDE.md`).

Four `fleetd/` modules implement the phase-level path, each replacing one
slice of what the router (an LLM) does inline on the manual path:

| Module | Replaces | What it owns |
|--------|----------|---------------|
| `preamble.py` | `SKILL.md` Steps 0.1–0.6 | Once-per-ticket setup: env file, pipeline-log schema line, branch context, Linear preflight. Calls `ticket-auto-pipeline/lib/ticket-preamble.sh` rather than reimplementing it — idempotent, so fleetd re-entering mid-ticket after a restart just gets the same result back. |
| `phase_dispatch.py` | The router's step-to-step sequencing | Loads the dispatch table, builds and forks each phase's `claude -p` command, records dispatch position and worker rows in the state store as it goes (so resume never needs to re-derive position from the log), evaluates the four loop-type steps' caps, and opens/closes each phase's log bracket. |
| `gate_hold.py` | The router's `GATE_HELD`/`RECONCILE_CYCLE` handling | A held ticket as a kind-agnostic `tickets` row (`held`, `hold_kind`, `hold_id`, `reconcile_cycle`), reconciled from `run_observe`'s live loop on its own `FLEET_GATE_RECONCILE_INTERVAL` cadence rather than every detection sweep or the (still dormant) phase-dispatch path — an indefinite human-approval wait survives a fleetd restart because it was never a process to begin with. Release-predicate dispatch is keyed on `hold_kind`: `'gate'` maps to `run_entry_gate` (`gate-check.sh --mode entry`, unchanged); `'human'` (human-hold-protocol) maps to `_reconcile_human_hold`, which reads Linear comments via `probe_human_answer` (three conditions: posted after `held_at`, non-bot author, body contains `hold_id`) instead of re-running a bash gate. Any other kind still resolves to `UNAVAILABLE`, never a release or a gate-stop. |
| `orchestration.py` | The non-agent steps the router interleaves between phase spawns | Executor for each step's `pre_dispatch`/`post_dispatch` array in the dispatch table — `return-completeness-check.sh`, `outcome-label-check.sh`, `flow.sh` triggers, auto-merge, worktree release. Declared in the table, not enumerated in Python, for the same reason `phase_dispatch.py` loads the table instead of transcribing it. |

**Rollout is not yet switched on.** Both paths are fully implemented and
tested; fleetd still dispatches every ticket through the ticket-level path
by default. Moving the default to phase-level is a separate, later step —
feature-flag first, compare outcomes on a subset, then promote — tracked
outside this file.

## Worker exit records & recovery

Every worker exit — natural or fleet-killed — is persisted per-generation, never overwriting a prior generation's record:

- `{tid}-gen{N}.json` / `{tid}-gen{N}.stderr` — captured stdout/stderr, opened `O_APPEND` at spawn.
- `{tid}-gen{N}-exit.json` — `{tid, generation, pid, exit_code, exit_type, exited_at, killed_by_fleet, terminal, session_id, last_assistant_message, action, cost_usd}` (+ `suppressed_retry_reason` when set). `killed_by_fleet` is `True` only when written from `kill_worker()`'s own success (never inferred from an exit code); `terminal` reflects whether the ticket's pipeline log already reached `META|outcome|`; `cost_usd` (float or `null`) is the worker's `total_cost_usd`, read from its captured stdout envelope by `worker_cost_usd` (`fleetd/phase_dispatch.py`) on both the reap and fleet-kill paths, **before** the generation-file sweep below runs — reading after would race the sweep and silently return `null` for a file that aged out mid-cycle. `FLEET_WORKER_LOG_RETENTION` (default 3) generations of these files are kept per ticket; older ones are swept at each reap.
- **Cost events**: whenever `worker_cost_usd` finds a value, fleetd appends `{kind:"cost", tid, run_id, gen, phase, usd, observed_at}` to `logs/runs.jsonl` (Commercial Evidence MVP Branch C) via `_append_runs_event` — the same `flock`-guarded, fail-soft append discipline as ticket-auto-pipeline's `run-summary.sh`/`merge-poll.sh` writers to that file. `run_id` is resolved from the last `META|run-id` pipeline-log line only when that line's `gen` matches the reaped/killed worker's own generation; otherwise `null` — an honest gap rather than a mis-attributed run. No cost value found means no event at all, not a null-valued one. Adopted workers (`poll_adopted_workers`) have no captured stdout envelope, so they never produce a cost event.
- `{tid}-gen{N}-hook.json` — written by the `Stop` hook (`ticket-auto-pipeline/hooks/stop-capture.sh`) with `last_assistant_message`, the only channel a headless worker's question travels through (`AskUserQuestion` is absent from the `-p` tool list). Merged into the exit record when present; absent whenever `Stop` doesn't fire — SIGINT and SIGKILL never trigger it, only a cooperative stop or a normal completion do. `hooks/stop-failure.sh` (`StopFailure`) instead appends a `META|worker-api-error|warn|` line to the ticket's own pipeline log when a turn ends on an API error.

A natural (non-fleet-killed) exit over a **non-terminal** pipeline log — the only reliable "did it actually finish" signal — triggers scoped reap-time recovery: `reconcile_orphaned_tickets(scope_tids=[tid])` calls the existing `fleet_reconcile_orphans` (bash), which shares the restart cap / stop-pin / dead-letter logic with startup reconciliation via `FLEET_RECONCILE_TIDS`. Exit code `127` (fleetd's own exec-failure sentinel) and a tripped circuit breaker both skip reconciliation — recorded as `action: "skipped: exec-failure"` / `"skipped: circuit-breaker (...)"` on the exit record — rather than burning a restart credit on a failure that will only repeat.

The pipeline log gains one new `META` step: `META|worker-exit|done|fail|code=<N> type=<T> gen=<G> killed_by_fleet=<bool>`, appended at reap time regardless of recovery outcome.

**Slack notifier** (`lib/fleet-notify.sh`): posts via `chat.postMessage` (never a webhook — webhooks don't return the `ts` a reply thread needs) for a non-terminal natural exit or a dead-letter, never for clean completion. Content is observed facts only — ticket, phase, generation, elapsed, exit classification, recovery decision, and the captured final assistant message when present — deliberately not classified as "question vs. failure." Follow-ups for the same ticket reply into the stored `{tid}-slack-thread.json` thread. Requires `SLACK_BOT_TOKEN` + `SLACK_CHANNEL`; absent or misconfigured, or a transport failure, degrades to a log-only line and never affects reaping, reconciliation, or the daemon.

## Skills

- `fleet-controller` — `/fleet-controller:fleet-controller` slash command. Subcommands: `detect`, `intervene`, `dashboard`, `dispatch`, `feedback`.
- `fleet-env-check` — `/fleet-controller:fleet-env-check` slash command. Validates `LINEAR_API_KEY`, `REPOS_ROOT`, the fleetd worker spawn command (`CLAUDE_BIN`/`CLAUDE_CMD`), and `jq`/`git`/`python3`/`gh`. Read-only, smaller scope than ticket-auto-pipeline's `ticket-env-check` (no hooks/spawn-permission/UAT_URL checks — those are ticket-auto concerns). The same script also runs automatically, deterministically, at fleetd process startup (see "Startup env-check gate" above) — this skill is for a human to run it on demand and see the full table; it is not the only place it runs.

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `fleet-config.sh` | Configuration defaults: `FLEET_STATE_DIR`, `FLEET_KILL_GRACE_SECS`, `FLEET_KILL_VERIFY`, `FLEET_FENCE_ENFORCE`, `FLEET_QUEUE_LOCK_TIMEOUT`. State-directory resolver: `_fleet_state_dir <workspace>`. |
| `fleet-detect.sh` | 18 detection engines: `detect_phase_failures`, `detect_stalls`, `detect_zombies`, `detect_loops`, `detect_abandoned`, `detect_flow_failures`, `detect_auto_mode_blocks`, `detect_tool_errors`, `detect_planner_feedback`, `detect_blocked_by`, `detect_initiative_dispatch`, `detect_epic_branch_ready`, `detect_runaway_calls`, `detect_workspace_config`, `detect_human_hold`, `detect_observer_findings`, `detect_worker_api_errors`, `detect_stalled_approved_children`. Aggregator: `fleet_detect_all` outputs JSON. Sourceable library — no `set -euo pipefail`. |
| `fleet-intervene.sh` | Intervention executor: `fleet_kill_pipeline` (verified escalation with PID-reuse guard), `fleet_can_restart`, `fleet_restart_pipeline`, `fleet_stop_background`. flow.sh mutex-aware, `FLEET_DRY_RUN` guard. |
| `fleet-monitor.sh` | Monitor loop: `fleet_monitor_cycle` (one detection + intervention pass), `fleet_monitor_loop` (continuous polling with stop-file gating). Spawn queue consumption integrated with `flock` serialization. Dual-mode: interactive (ACTION:spawn-restart) or cron (JSONL queue). |
| `fleet-store.sh` | Read-only bash access to the fleet state store via the `sqlite3` CLI: `fleet_store_ready`, `fleet_store_sql`, `fleet_store_pipeline_rows`, `fleet_store_owner`, `fleet_store_is_owned`, `fleet_store_position`, `fleet_store_last_activity_epoch`, `fleet_store_in_flight`, `fleet_store_fence_allows`, `fleet_store_worker_by_session` (session_id → `tid\|generation`, the `ticket-auto-pipeline/hooks/stop-capture.sh` and `stop-failure.sh` resolution path). Every function degrades to "no store" rather than failing, so a host with no fleetd — or no sqlite3 — keeps working on the file path. Ticket ids and session ids are validated against an identifier alphabet before reaching an SQL string, not escaped. |
| `fleet-registry.sh` | Run registry + generation fence helpers: `registry_write`, `registry_read`, `registry_pid`, `registry_generation`, `registry_exists`, `registry_clear`, `fence_write`, `fence_read`, `fence_is_superseded`, `fence_clear`. Per-ticket JSON files; no shared-file races. |
| `fleetd/otel.py` | OTel exporter — derives GenAI-convention spans from the pipeline and activity logs, ships OTLP. Pure stdlib at import time; the `opentelemetry` dependency is lazy and inside the exporter process. Supervised by fleetd under the fixed id `otel-exporter`. |
| `fleet-dashboard.sh` | Dashboard renderer: `fleet_render_dashboard` / `fleet_render_dashboard_from_data` (terminal health table) and `fleet_write_report` / `fleet_write_report_from_data` (markdown report). |
| `fleet-dispatch.sh` | Planned-ticket dispatch. Reads initiative epics from Linear via `lib/linear-api.sh`, validates `state:execution`, ensures the epic branch exists in **every** working repo under `REPOS_ROOT` before enqueue (multi-repo precondition — creation failure in any repo gate-stops with `EPIC_BRANCH_UNAVAILABLE`; sync failure in one repo warns and continues), resolves `blocked-by` dependencies, orders tickets by explicit dispatch rank (`Urgent`→`High`→`Medium`→`Low`→`No priority` last), writes spawn queue JSONL with `generation` field via shared `_fleet_queue_append` (flock, retry, dead-letter). Respects `FLEET_MAX_CONCURRENT` and `FLEET_DRY_RUN`. |
| `fleet-feedback.sh` | Feedback aggregation. Scans pipeline logs for `META\|planner-feedback`, groups by `{initiative-id}`, computes confidence drift, writes `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`. |
| `fleet-env-check.sh` | Standalone (not sourced) — validates `LINEAR_API_KEY`, `REPOS_ROOT`, `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN` (only required when `FLEET_EPIC_AUTO_PR=true`), `SLACK_BOT_TOKEN` (optional), the fleetd worker spawn command (`CLAUDE_CMD` if set, else `CLAUDE_BIN`) including its permission mode, and `jq`/`git`/`python3`/`gh` presence. Same `NAME\|STATUS\|VALUE\|LOCATION\|NOTE` pipe-delimited contract as ticket-auto-pipeline's `env-check.sh`. Masks secret values to `****` + last 4 chars — never echoes secrets in full. The live permission probe (an actual worker turn) is opt-in via `FLEET_ENV_CHECK_LIVE_PROBE=true` — off by default so `make test`/CI never spawns a real worker. |
| `fleet-notify.sh` | Deterministic Slack notifier: `fleet_slack_post <tid> <state_dir> <text>` (transport — `chat.postMessage`, persists/reuses `{tid}-slack-thread.json`'s `ts`), `fleet_notify_worker_event <tid> <state_dir> <event_type> [detail]` (`event_type`: `non-terminal-exit`\|`dead-letter` — builds the message from the ticket's exit record + pipeline log). Called from `supervisor.py`'s reap path and from `fleet-reconcile.sh`'s dead-letter branch. `fleet_notify_hold <tid> <state_dir> <transition>` (`transition`: `created`\|`escalate`, human-hold-protocol) reads the latest valid `META|human-hold` record straight from the pipeline log — REASON, BLOCKS, numbered questions, observed facts only, never a classification of what the question means — and posts once per hold, escalating once more at `FLEET_HOLD_ESCALATE_HOURS`. Its idempotency deliberately does **not** key off the fleet state store's `notify_state` column despite design.md D7 naming that column authoritative: a bash library has no write access to the store (fleetd is its sole writer), and the row carries no question text regardless. It keeps its own per-ticket sidecar instead (`{tid}-hold-notify.json`), the same pattern `fleet_slack_post` already uses for its own thread-ts bookkeeping — restart-safe and failure-retried by construction, just not through the row. All fail-soft throughout. |
| `run-score-export.sh` | `run_score_export_sweep RUNS_FILE` (langfuse-evidence-layer Phase 5 — run-score-export). Reads `runs.jsonl`, ships one Langfuse score per finished-run field (outcome, verify/review/fix/reconcile counters, cycle time, cost, complexity-estimate accuracy, gate-stopped, failure class/phase from `exit-path.sh`, bridged from ticket-auto-pipeline the same way `linear-api.sh` is) plus a ticket-level rollup (`ticket_runs`, `ticket_cost_total`, `ticket_cycle_ms`, `ticket_first_pass_success`) once a merge decision is known for that run — resolved from a separate `merge`-kind event, never the run event's own (possibly stale, append-only) field. Off by default (`FLEET_SCORE_EXPORT_ENABLE`) and credential-gated (`LANGFUSE_HOST`/`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`); no credentials, an unreachable backend, a request timeout, or a malformed record each warn and continue, never gating the sweep's caller. Idempotent via a per-run-id cursor (`score-export-cursor.json`) that is advisory only — every score's `id` is a deterministic hash of `(run_id, score name)`, so a lost cursor re-ships harmlessly. Cost prefers a `cost` event; when a worker was killed before writing one, falls back to `run.tokens` × a local, fleetd-owned `fleetd/model-pricing.json`, stamping `cost_source=tokens` vs `envelope`. Invoked from `supervisor.py`'s `_score_export_sweep`, on the same periodic cadence as `_merge_poll_sweep`. |

### Canonical library sources (dependency bridge)

Fleet controller depends on libraries defined in `ticket-auto-pipeline/`:
- `linear-api.sh` — GraphQL API client (used by `fleet-dispatch.sh` for Linear queries)
- `heartbeat.sh` — Heartbeat log helpers (used by `fleet-monitor.sh`, `fleet-dashboard.sh`, `fleet-intervene.sh`)
- `exit-path.sh` — `derive_failure_class`/`derive_failure_phase` (used by `run-score-export.sh` to score a finished run's failure class and phase)

These are sourced via `_source_if_missing` from `~/.claude/skills/lib/` (synced by the ticket-auto-pipeline SessionStart hook). Fleet controller does NOT maintain its own copies — it bridges to the canonical sources.

## Detection engines (18 total)

| # | Detector | What it catches | Severity range |
|---|----------|----------------|----------------|
| 1 | `detect_phase_failures` | `\|fail\|` entries on non-MAINTENANCE phases | 0–3 |
| 2 | `detect_stalls` | Stale heartbeats (last `orchestrator-waiting` or `watchdog\|alive`) | 0–3 |
| 3 | `detect_zombies` | Unresolved `\|waiting\|` entries with no matching terminal | 0–2 |
| 4 | `detect_loops` | Excessive `decision\|loop-back` counts vs configured caps | 0–3 |
| 5 | `detect_abandoned` | Pipeline log exists but no `META\|outcome` after threshold | 0–3 |
| 6 | `detect_flow_failures` | `retry\|flow-sh\|fail` entries in heartbeat log | 0–2 |
| 7 | `detect_auto_mode_blocks` | `check-approval\|fail` + denial patterns in agent logs | 0–2 |
| 8 | `detect_tool_errors` | Deduplicated tool errors in `{tid}-tool-errors.log` | 0–2 |
| 9 | `detect_planner_feedback` | Uncollected `META\|planner-feedback` entries | 0–1 |
| 10 | `detect_blocked_by` | Tickets with `blocked-by:{ID}` where blocker is Done | 0–1 |
| 11 | `detect_initiative_dispatch` | `state:execution` epics with undispatched planned tickets | 0–1 |
| 12 | `detect_epic_branch_ready` | Directive-carrying `state:execution` epics with all children Done; when `FLEET_EPIC_AUTO_PR=true`, actuates by calling `epic_branch_open_pr` once per tracked repo (never auto-merged) | 0–1 |
| 13 | `detect_runaway_calls` | Tool-call count within the current open spawn bracket above `FLEET_RUNAWAY_CALL_THRESHOLD`. Per-ticket. The inverse of `detect_stalls`' activity dimension: a runaway agent never stops calling tools, which looks as healthy to the watchdog as a stalled one looks dead | 0–1 |
| 14 | `detect_workspace_config` | Fleet-wide. The pipeline log directory is missing, is not a directory, or is unreadable. `FLEET_PIPELINE_LOG_DIR` defaults to the *relative* `./logs`, so a fleetd started from the wrong working directory monitors nothing and reports a clean bill of health — this is the only engine that fires when there is no pipeline to inspect. An existing but empty directory is a genuinely idle fleet and stays silent | 0–1 |
| 15 | `detect_human_hold` (human-hold-protocol) | A ticket parked waiting on a person (`held: human` outcome), or a `META|human-hold` record the parser rejected (`parse_status: invalid`, visible regardless of hold state — a swallowed ask is the defect this detector exists to catch). Runs only inside the held-ticket branch, alongside `detect_abandoned`. **The one detector that never exceeds severity 1, for any hold age — this is deliberate, not a bug to "fix" by raising it.** In this codebase severity 2 is already an intervention (`KILL: touch stop files, finalize the pipeline log`). A held ticket has no process to kill — the router exited cleanly when the agent asked — so finalizing would overwrite the `held:` outcome that is the hold's own audit record and the exact line both terminal classifiers key on, making the waiting ticket look *finished* to the machinery that was just taught to recognise it. A future contributor raising this cap would silently reintroduce the log-overwrite bug this detector exists to prevent. Escalation for a long-unanswered hold lives in `fleet_notify_hold` instead (louder notification at `FLEET_HOLD_ESCALATE_HOURS`), never in severity | 0–1 (hard cap) |
| 16 | `detect_observer_findings` (agent-observer) | A `HIGH`-severity finding recorded by the observer sidecar (`fleetd/observer.py`) for the ticket's current open spawn bracket — claim contradictions, scope violations, unexpected tools, runaway cost, etc. Scoped to the bracket via `_spawn_bracket_info`, same pattern as `detect_runaway_calls`: only findings logged (`META\|observer-finding`) since the bracket's `start_iso` count, so a finding from a prior, already-closed bracket never re-fires. **Hard-capped at severity 1, same rationale as `detect_human_hold`** — the observer is deliberately non-authoritative (it never gate-stops or kills a phase on its own), so its bash-side surfacing must never let a finding escalate a healthy-looking pipeline to a `KILL` intervention the observer itself has no authority to request | 0–1 (hard cap) |
| 17 | `detect_worker_api_errors` (issue #341 finding 5) | `META\|worker-api-error\|warn\|` (written by `ticket-auto-pipeline/hooks/stop-failure.sh` when a turn ends on an API error) for the ticket's current open spawn bracket, same `_spawn_bracket_info` scoping as `detect_runaway_calls`/`detect_observer_findings`. Previously write-only — read back only by `exit-path.sh`'s post-hoc retro classification, never while the ticket was still live. **Hard-capped at severity 1, same rationale as `detect_human_hold`/`detect_observer_findings`** — an API error ending a turn is not necessarily this pipeline's fault (a transient provider-side outage reads identically to a genuinely stuck worker from here), so this exists to make sure a human sees the pattern, never to drive a KILL/RESTART on its own | 0–1 (hard cap) |
| 18 | `detect_stalled_approved_children` (issue #342) | Fleet-wide, like #11/#12. For each child of a `state:execution` epic: flags one whose Linear state is in `{Ready, Approve, Review, UAT}` (not `Backlog` — dispatch's own Step 2 population; not `Done` — finished) and carries the `approved` label, but has neither a live worker (a `fleet-state.db` `workers` row with `status='running'`, falling back to the same file-based liveness checks dispatch itself uses when no store is available) nor a pending spawn-queue entry. Closes the gap between dispatch's two existing scheduling paths — Step 2 (new `planned`+`Backlog` children only) and Step 1.75's `fleet_reconcile_orphans` (resumes a mid-flight child only when ITS PIPELINE LOG shows a crash/orphan/stall signature) — neither of which notices a child fixed/re-approved *outside* the pipeline (directly via `ticket-flow`/the Linear API), which leaves no such log signature and would otherwise sit idle forever, blocking every ticket that names it in a `blocked-by:` label. **Actuation**: opt-in via `FLEET_AUTO_RESUME_STALLED` (default `false`), mirroring `FLEET_EPIC_AUTO_PR`'s exact detect-then-optionally-actuate shape (see #12) — when `true`, enqueues a resume entry for the flagged tid via the same `_reconcile_entry` (`fleet-reconcile.sh`) the manual-requeue/campaign-resume workaround already uses (`dispatch_type` stays `"initial"`, matching every entry this codebase writes — there is no `"resume"` dispatch_type; resume vs. fresh dispatch is distinguished only by the `reason` string). With actuation off (default), the finding is reported and nothing is enqueued — a diagnostic `POST /dispatch` call never gains an unconditional side effect of starting new implementation work on a ticket nobody just decided to move forward | 0–1 |

## Fleet state store (SQLite)

`fleetd/store.py` over `fleetd/schema.sql`. One database holding fleet-controller's operational state, replacing both the per-ticket JSON file conventions and the habit of answering "what is happening right now" by globbing `logs/*-pipeline.log` and re-parsing them on every sweep.

**Authorship decides authority.** Two classes of table, and the distinction is the design:

| Class | Tables | Authority |
|-------|--------|-----------|
| fleetd-authored | `tickets`, `workers`, `phase_runs` | Authoritative. fleetd performed the dispatch, so it knows these first-hand rather than inferring them. Nothing else writes them. |
| projection | `log_events`, `phase_results`, `activity_events` | The append-only logs remain the source of truth. On disagreement the log wins. All are rebuildable from the logs alone. |

**fleetd is the sole writer.** Every phase is an independent `claude -p` process and every tool call fires a `PostToolUse` hook; letting either write here would put dozens of uncoordinated short-lived writers on the write path. They keep appending to their logs — no change required of them — and fleetd ingests. WAL mode lets detectors and dashboards read while the writer works. Bash reads through `lib/fleet-store.sh`, which uses `sqlite3 -readonly`.

**Location and lifecycle.** `${FLEET_STATE_DIR}/fleet-state.db` (falling back to the workspace, via the same `_fleet_state_dir` resolver every other piece of fleet state uses), so it inherits the reboot-surviving lifecycle the run registry and fence markers already have. No separate backup: everything that matters for recovery is either derivable from the logs or re-imported from the registry files on next start. `log_events` and `activity_events` are pruned past `FLEET_STORE_EVENT_RETENTION_DAYS` (default 30) — safe because they are projections, and retention is about query cost, not durability. Deleting the database costs a slow cold start, never data.

**Startup.** `scan_workers` runs `_store_bootstrap` after registry adoption: `import_legacy_state` adopts surviving `*-run.json` and `*-fence` files, then `ingest_workspace` projects the logs. Idempotent, and also the recovery path when the database has been deleted. Each detection cycle calls `_store_sync` first, which ingests only the bytes written since the last pass.

**Fail-soft everywhere.** Every store call in `supervisor.py` goes through `_store_do`, which swallows all exceptions and warns once per distinct failure. A supervisor that cannot open its store must still supervise processes: losing the store costs a slower cold start, losing the supervisor loses the fleet. `FLEET_STORE_ENABLE=false` disables it entirely.

**Fence files are still written.** `_write_fence_files` writes both the store row and the `{tid}-fence` marker. `flow.sh`'s fence guard runs inside a worker and still reads the file; dropping it would let a superseded generation's Linear mutations through, which is the one thing the fence exists to prevent. The file goes away when every consumer reads the store.

**Schema versioning.** `store.py:SCHEMA_VERSION` (currently 2) is refused upward unconditionally — a database written by a newer fleetd may have moved a column this code reads by name, and a supervisor that misreads which processes are alive is the one class of error it must not make. A store found at an *older* version migrates forward automatically, but only when every step in the gap is declared `additive` (new column with a default, new index, new table) in `store.py`'s per-version migration table — a rename, drop, type change or tightened `CHECK` refuses with a message distinguishing it from the upward refusal, and the store must be recreated. The v1→v2 rename (`gate_held`/`gate_hold_reason`/`gate_held_at` → `held`/`hold_reason`/`held_at`) is the one declared non-additive exception, taken because no production store existed at the time; every version from v2 onward must either be additive or ship a real migration.

**Hold state is kind-agnostic.** `tickets.held`/`hold_kind`/`hold_id`/`hold_reason`/`held_at`/`hold_generation`/`hold_attempts` describe a hold regardless of what caused it. `Store.set_hold`/`release_hold` are the only two hold transitions and both are conditional `UPDATE`s whose rowcount is the idempotency proof — no lock, no read-then-write window. `hold_kind='human'` (human-hold-protocol) now has a registered release predicate (`gate_hold._reconcile_human_hold`, dispatched the same way as `'gate'`) — but, like `'gate'`, **no live caller creates the row yet**: `store.set_hold` is exercised only by tests for both kinds, a pre-existing, explicitly accepted gap (see `gate_hold.py` above, "has no live caller"). What human-hold-protocol shipped as genuinely live today is the parts that never touch this store at all: the pipeline-log parser, the `held: human` outcome branch, and the log-driven `detect_human_hold`/`fleet_notify_hold`. `notify_state`/`notified_at`/`escalated_at` are likewise schema-only: created, written by nothing — `fleet_notify_hold` keeps its own per-ticket sidecar file instead, since a bash library cannot write this store regardless (see `fleet-notify.sh` above).

**Detector input.** `fleet-detect.sh` reads pipeline-log lines through one seam, `_pipeline_rows`, which returns store rows when a store is available and file lines otherwise. One seam rather than a store-backed variant per engine: the filtering, thresholds and severities stay literally the same code, which is what makes the parity assertion (`lib/tests/test-fleet-store-parity.sh`) cheap and meaningful. The heartbeat-log engines (`detect_stalls`' heartbeat dimension, `detect_loops`) and the Linear-API engines are unaffected — the store does not ingest those inputs.

## OTel exporter

`fleetd/otel.py` derives OpenTelemetry GenAI-convention spans by tailing the
pipeline log and the agent-activity log, and ships them to an OTLP collector.
Off by default (`FLEET_OTEL_ENABLE=false`).

```bash
python3 -m pip install -r fleet-controller/fleetd/requirements-otel.txt
export FLEET_OTEL_ENABLE=true FLEET_OTEL_ENDPOINT=http://collector:4318
# fleetd spawns and supervises it; or run it standalone:
python3 fleet-controller/fleetd/otel.py --log-dir ./logs
```

**Derived, never hand-instrumented (D5).** No phase skill, hook, or fleetd
module emits a span at the point of action. A log `printf` and an OTel SDK call
sitting side by side eventually disagree — a new phase gets one and not the
other — and then two things claim to say what happened. There is one writer of
truth (the log) and one reader that translates it, which also means a new phase
skill is traced correctly by writing its log lines correctly and nothing else.

**Downstream, never authoritative (D5).** `detect-resume.sh`, the gate scripts,
`fleet-detect.sh` and `dashboard.py --fleet` all read the pipeline log directly.
Nothing waits on the exporter or notices its absence. Stopping it, or pointing
it at a collector that is down, costs traces and nothing else — the SDK retries
with backoff and the process exits cleanly.

**Span model (otel-span-identity, langfuse-evidence-layer).** One root span per
**execution** — keyed by `(ticket, run_id)`, not ticket alone, so a ticket's
separate runs are separate, comparable traces — opened on first sight (a
provisional key if the run id isn't known yet, re-keyed on first sight per
SI1) and closed on `META|outcome` or superseded by the next `META|run-id`. One
child span per phase/step bracket (`invoke_agent {phase}.{step}`), from its
`|waiting|` line to its terminal; a `|fail|` terminal sets span status ERROR.
Every span — root and child alike — carries session identity set to the
`run_id` (`langfuse.session.id`), never the ticket id, plus filterable
metadata (`langfuse.trace.metadata.*`: ticket id, run id, generation, phase,
step, model, pipeline/skill versions, and the worker's own runtime session id
when the supervisor recorded one) and trace tags (ticket, trigger, complexity,
autonomy, and — on the root at close — outcome). Backend-specific attributes
are additive, never a replacement for the vendor-neutral GenAI conventions —
`gen_ai.system`, `gen_ai.operation.name`, `gen_ai.agent.name`,
`gen_ai.request.model` from `META|model`, `gen_ai.usage.*` from `META|tokens` —
plus `ticket.id` and `pipeline.*`. Per-phase cost attaches from a matching
`runs.jsonl` `cost` event at flush time — present when the evidence exists,
omitted (never zero, never re-exported) otherwise; the per-run score
(`run-score-export.sh` below) is the authoritative cost, this is informational.
Tool calls from the activity log attach to the span that contains them as a
count attribute and bounded span events, not as spans of their own: one span
per tool call would swamp a trace whose useful unit is the phase.

**Why spans wait before emission.** `META|tokens|info|` is written by the
SubagentStop hook a moment *after* the router writes the phase terminal, so a
span emitted the instant its bracket closes always loses its token counts.
Completed spans sit in a buffer for `FLEET_OTEL_SPAN_GRACE_SECS` (30) so late
enrichment attaches. A ticket reaching its outcome flushes its spans
immediately — nothing more can arrive for a finished ticket.

**Supervision (task 8.5).** The exporter is a fleetd child under the fixed
identifier `otel-exporter`: spawned through the same `spawn_worker` fork/exec,
a run-registry entry while active, reaped by the same `ChildReaper`, stopped
through the same kill escalation, respawned on crash with a bounded backoff
(5s → 30s → 2m → 10m). Its exit is branched away from the ticket reap path
before anything else runs: sending it down that path would write a
`META|worker-exit` line into an `otel-exporter-pipeline.log`, which
`fleet_detect_all` would then glob and report as a stuck pipeline — the monitor
manufacturing findings about itself.

**The one dependency (D11).** `opentelemetry-sdk` is the repository's first
third-party Python dependency, and it is quarantined to this module.
`supervisor.py` and `store.py` stay pure-stdlib; the SDK import is lazy and
inside the exporter *process*. Without the packages the exporter starts, says
so once on stderr, and emits nothing — fleetd is unaffected. CI runs the whole
suite without them for exactly that reason, then installs them in a later step
so the real SDK path is covered too.

## Worker telemetry env (worker-telemetry-env, langfuse-evidence-layer)

`Supervisor.spawn_worker` stamps `OTEL_RESOURCE_ATTRIBUTES` into every spawned
worker's environment, unconditionally — a separate concern from
`FLEET_OTEL_ENABLE` above, since this feeds the agent runtime's *own* OTel
stream rather than fleetd's log-derived exporter. A runtime with its own
telemetry disabled never reads these vars; one with it enabled joins the run's
session with no trace propagation required (WE2, probed and confirmed: the
runtime copies resource attributes onto every span it emits, and
`langfuse.session.id`/`langfuse.trace.metadata.*` land as first-class,
filterable fields).

`_worker_otel_resource_attributes(run_id, tid, phase, environment)`
(`fleetd/supervisor.py`) builds the value — the run id under the session key,
ticket under the filterable-metadata namespace, and phase too for a
phase-level spawn (omitted, never emitted empty, for a ticket-level one).
Every value is percent-encoded (`_otel_pct_encode`); a value that cannot be
encoded is dropped rather than emitted raw, and a builder failure never
touches the spawn's command line or exit handling. `OTEL_BSP_SCHEDULE_DELAY`
is shortened alongside it (`FLEET_OTEL_WORKER_EXPORT_MS`) so a worker killed
mid-phase has less unexported telemetry buffered at the moment it dies.

`fleetd/supervisor.py` also writes `META|trace-context` at phase-spawn time
(`_write_trace_context`) — run id, the worker's own runtime session id,
generation, phase, a `propagate` flag, and — only when
`FLEET_TRACE_PROPAGATE_ENABLE` is true and the run id was known at spawn time
— the derived `trace_id`/`span_id` (trace-context-propagation, see below) —
respecting the pipeline log's own "nothing after outcome" rule. This is the
one place the exporter can read a phase span's worker session id from,
without reaching outside the pipeline log for it (SI5).

## Trace-context propagation (trace-context-propagation, langfuse-evidence-layer Phase 3)

Off by default (`FLEET_TRACE_PROPAGATE_ENABLE=false`) and never load-bearing —
deriving, recording or exporting a parent context is best-effort at every
step and can never alter a spawn's command line, delay it, or change its exit
handling. When enabled:

- `fleetd/otel.py`'s `derive_trace_context(run_id, phase, generation)` — one
  pure function, used by both the spawning path and this exporter, so both
  sides compute identical identifiers with no shared state and no ordering
  requirement (TP1). A trace id is `sha256("trace:{run_id}")[:32]`; a phase's
  span id is `sha256("span:{run_id}:{phase}:{generation}")[:16]` — both
  lowercase hex, the W3C traceparent shape.
- `Supervisor.spawn_phase_worker` derives the pair before spawning, exports
  `TRACEPARENT=00-{trace_id}-{span_id}-01` into the worker's environment, and
  records both in `META|trace-context` (TP2).
- `OtlpEmitter` installs a queued `IdGenerator` on its `TracerProvider`
  (`build_queued_id_generator`, task 7.6): when a ticket's root span is
  created for a run with propagation on, it queues the derived trace id
  before creating it; when a phase span is created, it queues that phase's
  derived span id. Both fall back to the SDK's normal random generation the
  instant the queued value is consumed, or whenever propagation is off — the
  emitted spans are then identical to phase 2's (task 7.7/7.8).
- **Known limitation**, matching design.md's Risks: if the root has to open
  under a provisional key (run id unknown at the moment the first phase
  bracket closes) and propagation is on, its trace id was already randomly
  assigned before the run id became known and cannot be changed after
  creation — the derived trace id is adopted only when `run_id` is known at
  the moment the root is first created.
- **Not yet settled**: whether a derived phase span — which reaches the
  backend *after* the children that attach beneath it, since the exporter is
  a tailing reader — actually reconciles into one trace at the real backend.
  That is phase 4 (design.md Gate verdicts), a live end-to-end ticket run
  this change has not performed. The flag stays off until it has.

## Run score export (run-score-export, langfuse-evidence-layer)

`lib/run-score-export.sh`'s `run_score_export_sweep` turns finished runs in
`runs.jsonl` into Langfuse scores — see its row in "Shared libraries" above for
the full field mapping. Off by default (`FLEET_SCORE_EXPORT_ENABLE=false`) and
requires `LANGFUSE_HOST`/`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`; invoked
from `Supervisor._score_export_sweep`, on the same cadence as
`_merge_poll_sweep`. Failure classification is scoped to the specific run
being scored — `_score_export_run_window` isolates the lines between that
run's own `META|run-id` line and the next one (or EOF) before handing them to
`exit-path.sh`, because a ticket's pipeline log is one continuous file across
every run it ever had and `derive_failure_class` reads a whole file.

## Severity scale

| Code | Name | Action |
|------|------|--------|
| 0 | OBSERVE | Log only, no action |
| 1 | WARN | Alert, no destructive action |
| 2 | KILL | Touch stop files, finalize pipeline log |
| 3 | KILL+RESTART | Kill + spawn new pipeline (unless `FLEET_AUTO_RESTART=false`) |
| 4 | KILL degraded to WARN | KILL severity downgraded (e.g., non-retryable gate-stop) |

## Key design decisions

- **Bash-only, zero LLM**: Fleet controller never spawns Claude agents. Detection, dispatch, intervention, and feedback are all deterministic bash scripts. The skill file is the human interface for manual intervention.
- **Detection engines are sourceable library**: `fleet-detect.sh` exports functions as a sourceable bash library — no `-euo pipefail`. Callers source it and call individual detectors or the aggregator `fleet_detect_all`.
- **Dispatch uses spawn queue file**: `fleet-dispatch.sh` writes to `{state_dir}/fleet-{instance}-spawn-queue.jsonl` (resolved via `_fleet_queue_file` — `FLEET_STATE_DIR` env or the workspace logs dir, never `/tmp`). The monitor loop or fleetd consumes the queue. Separation of concerns — dispatch identifies work, the consumer executes it.
- **Feedback writes to REPOS_ROOT, not Linear**: `fleet-feedback.sh` collects and structures data; agents act on it. The determinism boundary — fleet controller scripts are bash, Linear comment posting is an agent responsibility.
- **Intervention respects flow.sh mutex**: Kill/restart operations check for flow.sh locks (`/tmp/ticket-flow-{ID}.lock`) before acting. `FLEET_DRY_RUN=true` makes all interventions no-op. Kill escalation is verified: stop-files → grace → SIGTERM → grace → SIGKILL → re-verify, with PID-reuse guard. Fence markers prevent superseded zombie mutations at flow.sh.
- **Owned worker lifecycle**: Run registry (`{tid}-run.json`) records PID + generation at spawn. Generation fencing (`{tid}-fence`) blocks superseded workers at flow.sh (fleet-registry.sh). Per-ticket JSON files avoid shared-file write races. Durable state under workspace, not /tmp.
- **fleetd is externally supervised, not self-supervised**: A shipped systemd unit (`Restart=always`) or a documented cron watchdog restarts fleetd itself — see `docs/process-supervision.md`. The existing single-instance `flock` guard prevents a supervisor restart from racing a still-shutting-down instance into a second concurrent supervisor.
- **Epic branch creation is worktree-safe**: `ensure_epic_branch` creates the branch as a plain ref (`git branch`), never checking it out — the shared clone's checked-out HEAD and working tree are never mutated by branch creation.
- **Dead-letter entries are surfaced**: Every dead-letter write emits a structured `fleet-dead-letter|tid=<TID>|reason=<REASON>` line (and, from reconciliation, a `META|dead-letter|warn|reason=…` marker on the ticket's pipeline log) so a status-reporting script can surface it — nothing sits silently on disk. (Note: `/ticket-overseer` does NOT scan for dead-letters — wire a consumer before assuming visibility.)
- **Plugin manifest mimics ticket-auto-pipeline structure**: Same `.claude-plugin/plugin.json` conventions. No custom agent types — fleet controller doesn't spawn Claude agents.
- **Dependency bridge**: Fleet controller sources `linear-api.sh` and `heartbeat.sh` from `~/.claude/skills/lib/` (synced by ticket-auto-pipeline's SessionStart hook). Does not maintain its own copies — uses the canonical sources.
- **Detector output format preserved**: Existing 8 detectors produce byte-identical output after migration. New detectors follow same severity convention and pipe-delimited output format.

## Determinism boundary

All fleet controller operations are deterministic bash — no Claude agent involvement, no LLM reasoning. The determinism boundary is:
- **Fleet controller side (bash)**: Detection, dispatch planning, feedback aggregation, verified kill escalation (stop-files → SIGTERM → SIGKILL → fence), pipeline log finalization, run registry and fence marker writes
- **Agent side (Claude)**: Actual ticket-auto pipeline execution, Linear comment posting (feedback acting), ticket appraisal/implementation/verification

Fleet controller reads from pipeline logs and heartbeat logs; it never writes to them except for intervention markers, fence markers, and run registry entries (`META|fleet-intervention`, `META|outcome`) and stop-file touches. Dispatch writes to a separate spawn queue; feedback writes to a separate feedback directory.

## Configuration

All settings use `${VAR:-default}` pattern for env-var overrides:

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_STATE_DIR` | (workspace) | Directory for spawn queue, stop files, run registry, fence markers — survives reboot |
| `FLEET_STARTUP_ENV_CHECK` | true | Gates fleetd process startup on `lib/fleet-env-check.sh` — a nonzero exit refuses to start. Set `false` to skip (used by fleetd's own subprocess-spawning tests) |
| `FLEET_KILL_GRACE_SECS` | 10 | Wait for cooperative shutdown before SIGTERM |
| `FLEET_KILL_VERIFY` | true | Fall back to stop-file-only kill when false |
| `FLEET_FENCE_ENFORCE` | true | Enable generation fencing in flow.sh |
| `FLEET_QUEUE_LOCK_TIMEOUT` | 5 | Spawn queue flock timeout in seconds |
| `FLEET_POLL_INTERVAL` | 30 | Seconds between monitor cycles |
| `FLEET_STALL_WARN_SECS` | 600 | Stale heartbeat threshold for WARN. Raised from 300 — background subagents are waited for up to 10 minutes at exit (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`), so 300 false-positived on a worker legitimately still exiting. Must stay strictly less than `FLEET_STALL_KILL_SECS`/`FLEET_STALL_RESTART_SECS` |
| `FLEET_STALL_KILL_SECS` | 900 | Stale heartbeat threshold for KILL |
| `FLEET_STALL_RESTART_SECS` | 1800 | Stale heartbeat threshold for KILL+RESTART |
| `FLEET_ABANDON_WARN_HOURS` | 1 | Abandonment threshold for WARN |
| `FLEET_ABANDON_KILL_HOURS` | 4 | Abandonment threshold for KILL+RESTART |
| `FLEET_ZOMBIE_SECS` | 900 | Unresolved waiting entry threshold |
| `FLEET_ACTIVITY_WARN_SECS` | 240 | Agent-activity staleness → WARN. Second, independent liveness input to `detect_stalls`, read from `{tid}-activity.log` (written per tool call by `ticket-auto-pipeline/hooks/agent-activity.sh`) and applied only while a spawn bracket is open. The watchdog `alive` line proves the *router* is running; this proves the *agent* is. 240s is deliberately well under `FLEET_STALL_WARN_SECS` — an agent that has made no tool call in 4 minutes is anomalous even though a router waiting 4 minutes is not |
| `FLEET_ACTIVITY_STALE_SECS` | 900 | Agent-activity staleness → KILL. Capped at WARN for tickets with no fleetd run-registry entry, so a human running `/ticket-auto` by hand — who reads output and thinks between tool calls — is never escalated to an intervention |
| `FLEET_FOREIGN_ACTIVITY_SECS` | 300 | Seconds of `{tid}-activity.log` silence after which an open pipeline bracket that fleetd does not own reads as a crashed run rather than as another orchestrator's live session. The dual-invocation interlock (`detect_foreign_run`) defers dispatch only when all three hold: an unresolved `|waiting|` bracket, no live fleetd worker, and a tool call inside this window. The window is what separates a **foreign run** from an **orphan** — collapse them and every crash recovery looks like a human at the keyboard, and fleetd stops recovering anything. A cooperative lock was rejected: the manual path is an LLM following prose, and a lock that is usually honoured turns a visible collision into a rare one nobody watches for |
| `FLEET_GATE_RECONCILE_INTERVAL` | 300 | Seconds between hold-reconciliation passes, run from `run_observe`'s live loop (`Supervisor._hold_reconcile_pass`, gated on `gate_hold.is_due(...)`) — deliberately its own cadence, not a step of the 30s detection sweep, and never the still-dormant phase-dispatch path. Detection reads local logs; a held-ticket re-check is a Linear round trip per held ticket, and a human attaching an `approved` label is not a sub-minute-latency event. For `hold_kind='gate'` the probe re-runs `gate-check.sh --mode entry` (never `--mode reapprove`, which writes `APPROVAL_REVOKED` on any non-pass and would gate-stop a ticket nobody has looked at yet) against a scratch log, appending its lines to the real pipeline log only when the answer changed — a ticket held over a weekend must not accumulate one identical `GATE\|gate\|fail\|held:` line per pass. `hold_kind='human'` (human-hold-protocol) probes Linear comments instead via `probe_human_answer` — same cadence, same UNAVAILABLE-on-API-failure discipline |
| `FLEET_HOLD_WARN_HOURS` | 2 | Age past which `detect_human_hold` reports severity 1 for a `held: human` ticket. Never anything above 1, at any age — see detector #15's table entry for why |
| `FLEET_HOLD_ESCALATE_HOURS` | 24 | Age past which `fleet_notify_hold`'s `escalate` transition sends one additional, louder Slack message, gated on `escalated_at` so it fires at most once per hold. Escalation lives here, not in `detect_human_hold`'s severity — a severity-2+ response would kill or restart a ticket that has no process to kill |
| `FLEET_HOLD_MAX_ATTEMPTS` | 3 | Bound on the ask → partial-answer → re-ask loop (`gate_hold.human_hold_attempt_exceeds_max`). A request that would push a ticket's `hold_attempts` past this writes `META\|gate-stop\|fail\|HUMAN_HOLD_EXHAUSTED` instead of creating another hold — matches `RECONCILE_EXHAUSTED`'s shape. `hold_attempts` never resets on release |
| `FLEET_STORE_ENABLE` | true | Set `false` to disable the state store entirely — fleetd stops writing it and every detection engine falls back to reading the log files, which is the pre-store behaviour |
| `FLEET_STORE_EVENT_RETENTION_DAYS` | 30 | Age past which `log_events`/`activity_events` projection rows are pruned. Projections only — nothing fleetd authored is ever pruned, and anything dropped returns on a rebuild |
| `FLEET_ACTIVITY_LOG_MAX_LINES` | 500 | Ring cap on `{tid}-activity.log`. Read by the hook, not the detector: only the last line's age and the current bracket's line count have consumers |
| `FLEET_RUNAWAY_CALL_THRESHOLD` | 300 | Tool calls within one open spawn bracket above which `detect_runaway_calls` emits WARN. The mirror image of the activity-stall signal: a stalled agent stops calling tools, a runaway one never stops, and both keep the router's watchdog chirping. Counted per bracket rather than per log, so a long ticket is not flagged for being long. Must stay below `FLEET_ACTIVITY_LOG_MAX_LINES` — the activity log is ring-capped, so the count saturates there and a threshold above the cap is unreachable. WARN-only by design; a high call count is evidence, never proof |
| `FLEET_MAX_RESTARTS` | 2 | Max automatic restarts before giving up |
| `FLEET_AUTO_DISPATCH` | false | Must be `true` to enable automatic dispatch of planned tickets from initiative epics. Detection still runs and reports; dispatch is the actuation step. Human approval gate still stops every auto-dispatched ticket. |
| `FLEET_AUTO_RESTART` | true | Automatic restarts are enabled by default; set to `false` to opt out |
| `FLEET_DRY_RUN` | false | When `true`, interventions are logged not executed |
| `FLEET_EPIC_BRANCH_SYNC` | true | Sync base changes into epic branch each dispatch cycle — safety mechanism against branch rot |
| `FLEET_EPIC_AUTO_PR` | false | Automatically open integration PRs when all children Done — detection runs, actuation is opt-in |
| `FLEET_AUTO_DISPATCH` | false | When `false` (the documented default) fleetd sits idle — detection reports, dispatch happens only when explicitly triggered (skill or `POST /dispatch`). When `true`, the global sweep of `state:execution` epics runs unchanged. |
| `FLEET_DISPATCH_LOCK_TIMEOUT` | 5 | Seconds to wait for the epic-scoped dispatch flock (`{queue}.{epic}.dispatch.lock`) per attempt — serializes dispatch/stop per epic across processes |
| `FLEET_MAX_CONCURRENT` | 3 | Max concurrent pipelines for dispatch |
| `FLEET_EPIC_REPOS_DEPTH` | 3 | Levels of non-repo directories `_fleet_repos_under_root` descends into looking for nested service repos (e.g. `microservices/<svc>`) before giving up |
| `FLEET_EPIC_REPOS` | (unset) | Comma- or colon-separated list of explicit repo paths — when set, bypasses `_fleet_repos_under_root` directory discovery entirely; for operators pinning the exact repo set |
| `FLEET_POSTMORTEM_ON_KILL` | false | Run pipeline post-mortem analysis on fleet-killed pipelines (RLVR Phase 3). Opt-in — kills can be mass interventions; network cost and gh rate limits argue for per-kill opt-in. |
| `FLEET_INSTANCE_ID` | default | Namespace for stop files and spawn queues |
| `FLEET_SUMMARY_INTERVAL_CYCLES` | 10 | Cycles between forced fleet-summary heartbeat emissions |
| `CLAUDE_BIN` | `claude` | Worker binary name used by fleetd's `spawn_worker` |
| `CLAUDE_CMD` | (unset) | Full worker command line, overrides `CLAUDE_BIN` — e.g. `claude-deepseek 2 --bypass`. The `-p '/ticket-auto-pipeline:ticket-auto {tid} ...'` invocation is always appended after it |
| `FLEET_WORKER_PERMISSION_MODE` | `bypassPermissions` | Appended as `--permission-mode` unless `CLAUDE_CMD` already specifies one. `dontAsk`/`auto` are not sane defaults for a headless worker — see design.md Decision 9 |
| `FLEET_WORKER_DISALLOWED_TOOLS` | (unset) | Passed through to the worker invocation when set — comma-separated tool names to block. Recommended defense-in-depth given `bypassPermissions` is the default worker mode (e.g. `Bash(rm -rf:*),Bash(sudo:*)`) — not enforced by fleetd, since the pipeline's autonomy model already requires unattended write access to the workspace |
| `FLEET_WORKER_ISOLATE_SETTINGS` | true | headless-worker-isolation Task B. Appends `--setting-sources project,local` plus a `--settings` JSON override re-enabling only `ticket-auto-pipeline`/`fleet-controller` — live-probed as the actual mechanism that silences claude-mem's plugin SessionStart hook, output-style hooks and caveman mode, all of which are enabled only at user scope. Set `false` to opt a worker back into full user-scope settings (loses the isolation) |
| `FLEET_WORKER_PLUGIN_MARKETPLACE` | `willard-pro-claude-plugins` | Marketplace slug used to build the `<plugin>@<marketplace>` keys in the `FLEET_WORKER_ISOLATE_SETTINGS` override — a property of how a given host added the marketplace, not of the plugins themselves |
| `FLEET_WORKER_LOG_RETENTION` | 3 | Generations of `{tid}-gen{N}.json`/`.stderr`/`-exit.json` kept per ticket; older ones are swept at reap |
| `FLEET_MERGE_POLL_CYCLES` | 10 | `run_observe` cycles between periodic merge-poll sweeps (`lib/merge-poll.sh`'s `merge_poll_sweep`, outer `timeout=60`) — the async complement to `pipeline-finalize.sh`'s one-shot post-outcome sweep, catching PRs that merge after the pipeline process has already exited. A missing script is a no-op |
| `FLEET_DETERMINISTIC_FAILURE_SECS` | 5 | A worker exit faster than this counts toward the deterministic-failure circuit breaker streak |
| `FLEET_DETERMINISTIC_FAILURE_COUNT` | 3 | Consecutive fast-failure streak length that trips the circuit breaker (halts dispatch) |
| `FLEET_ENV_CHECK_LIVE_PROBE` | false | Opt-in: `fleet-env-check.sh` spawns one real worker turn to verify `permission_denials == []`. Off by default — never runs in `make test`/CI |
| `SLACK_BOT_TOKEN` | (unset) | Bot token for `fleet-notify.sh`'s `chat.postMessage` calls. Absent → notifications degrade to log-only |
| `FLEET_OTEL_WORKER_ENVIRONMENT` | `pipeline` | `deployment.environment` stamped on every worker spawn (worker-telemetry-env) — separates autonomous pipeline execution from interactive use on the same telemetry backend |
| `FLEET_OTEL_WORKER_EXPORT_MS` | 2000 | `OTEL_BSP_SCHEDULE_DELAY` (ms) stamped on every worker spawn — shortens the runtime's own batch-export interval below its SDK default so a killed worker loses less buffered telemetry |
| `FLEET_OTEL_HEADERS` | (unset) | `key1=val1,key2=val2` extra headers on fleetd's own OTLP exporter requests, and forwarded unchanged as `OTEL_EXPORTER_OTLP_HEADERS` on every worker spawn so both streams authenticate against the same collector |
| `FLEET_TRACE_PROPAGATE_ENABLE` | false | trace-context-propagation (langfuse-evidence-layer Phase 3) — when true, fleetd derives a trace/span id from `(run_id, phase, generation)`, exports it into the worker's environment as `TRACEPARENT`, and the exporter's `IdGenerator` adopts the same identifiers for the derived phase span, so the runtime's own observations nest beneath it. Stays off until a real end-to-end ticket confirms a derived parent span — which reaches the backend *after* the children that attached to it — reconciles into one trace rather than two (design.md Gate verdicts, phase 4, not yet run) |
| `FLEET_SCORE_EXPORT_ENABLE` | false | Gates `run-score-export.sh`'s periodic sweep (run-score-export). Also requires `LANGFUSE_HOST`/`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` — any one missing is a no-op |
| `LANGFUSE_HOST` | (unset) | Base URL for the score-export sweeper's `POST /api/public/scores` calls |
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` | (unset) | HTTP Basic Auth credentials for the score-export sweeper |

## Known sharp edges

- **Dependency on ticket-auto-pipeline libs**: Fleet controller bridges to `linear-api.sh` and `heartbeat.sh` from ticket-auto-pipeline. If those change, fleet controller must be tested.
- **Spawn queue is file-based**: No atomicity guarantees for concurrent readers. Single-writer (dispatch) single-reader (monitor) design avoids this in practice.
- **Pipeline log fragility**: `_last_field` correctly uses awk joins for field 5+ (message) to avoid `cut -f5` truncation. New detectors must use `_last_msg` for message fields.
- **Stop file namespacing**: Uses `FLEET_INSTANCE_ID` to avoid collisions between multiple fleet controller instances.

## Related docs

- [Fleet controller architecture](docs/fleet-controller.md)
- [Human Hold schema](../ticket-auto-pipeline/docs/human-hold-schema.md) — the request contract `gate_hold.py`'s `human` predicate and `fleet-detect.sh`'s `detect_human_hold` both consume
- [Root CLAUDE.md](../CLAUDE.md)
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md)
