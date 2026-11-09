---
name: fleet-controller
description: Monitors all active ticket-auto pipelines with deterministic detection engines (phase failures, stalls, zombies, loops, abandonment, flow failures, auto-mode blocks, tool errors, planner feedback, blocked-by resolution, initiative dispatch, epic-branch readiness, runaway tool-call rate, workspace misconfiguration and more) and escalates autonomously through OBSERVE → WARN → KILL → KILL+RESTART severity levels. Also dispatches planned initiatives, stops epics, and aggregates planner feedback. All interventions execute through fleet lib functions — no silent mutations outside the declared tool set.
allowed-tools: Bash, Read, Agent
---

# Fleet Controller — Automated Pipeline Orchestration

Parent orchestrator above ticket-planner and ticket-auto. Dispatches planned tickets, monitors pipeline health, aggregates execution feedback. Bash-only — zero Claude agents for detection/intervention.

The detector list, escalation ladder, configuration, fleetd scheduling, state locations and the owned-worker lifecycle (run registry, verified kill, generation fencing) are documented in the plugin's `README.md` and `CLAUDE.md`; this file covers the modes and the commands behind them.

## When to Use

| Trigger | Mode |
|---------|------|
| `/fleet-controller monitor` | Continuous detection loop with automated intervention |
| `/fleet-controller status` | One-shot health dashboard + markdown report |
| `/fleet-controller intervene <TICKET_ID>` | Manual kill or restart of a specific pipeline |
| `/fleet-controller dispatch <INITIATIVE_ID>` | Dispatch planned child tickets from an initiative epic |
| `/fleet-controller stop <INITIATIVE_ID>` | Epic-scoped stop — purge queue, kill workers, write stop-file |
| `/fleet-controller feedback` | Aggregate planner feedback across all initiatives |

## Modes

### Monitor (`monitor`)

Runs detection in a continuous loop via `fleet_monitor_loop`, rendering the dashboard each cycle and executing interventions at KILL and KILL+RESTART severities. **Monitor does not start workers.** Queued tickets (from `dispatch`, or a KILL+RESTART decision) run only under fleetd with `FLEETD_SPAWN_ENABLED=1`. Tell the operator this when they start `monitor` and the queue is not empty.

```
/fleet-controller monitor
```

- Polls every `FLEET_POLL_INTERVAL` seconds (default 30)
- Checks for stop file `${state_dir}/fleet-{instance}-controller-stop` at the start of each cycle
- Respects `FLEET_DRY_RUN=true` — detection runs but interventions are logged, not executed
- Leaves spawn queue entries in place for fleetd and prints one `PENDING:spawn tid=...` line per waiting entry (it removes only stale entries whose pipeline already finished). `PENDING:spawn` lines need no action from you except telling the operator to start fleetd
- Exits cleanly when stop file is detected

### Status (`status`)

One-shot health check — renders the dashboard to terminal and writes a report to `logs/reports/fleet-dashboard.md`. Gate-stopped, exhausted and dead-lettered tickets appear in a separate **Needs Attention** section (from `fleet_detect_all`'s `attention` array) with their reason and next step; always relay that section to the operator when it is present.

With fleetd running, `GET http://127.0.0.1:21001/health` gives the live worker set and `GET /workers/<tid>` one ticket's phase, anomalies and tokens (README § HTTP API).

```
/fleet-controller status
```

### Intervene (`intervene`)

Manual kill or restart for a specific ticket. Useful for operator-driven recovery.

```
/fleet-controller intervene CRE-47           # kill + attempt restart if eligible
/fleet-controller intervene CRE-47 --kill     # kill only, no restart
/fleet-controller intervene CRE-47 --restart  # restart if eligible (implies kill first)
```

### Dispatch (`dispatch`)

The single repeatable campaign command: run it any time, and it figures out what to do — resume dead/incomplete child pipelines, enqueue the newly-unblocked next wave, skip what is queued/running/done, and respect stop-files and concurrency caps. Repeated invocations advance the campaign one wave at a time.

```
/fleet-controller dispatch INIT-42            # reconcile + next wave
/fleet-controller dispatch INIT-42 --dry-run  # preview: would-resume/blocked/would-enqueue, writes nothing
/fleet-controller dispatch INIT-42 --resume   # un-stop: clear stop-file, then reconcile + dispatch
```

- Validates the epic has `state:execution` label
- **Campaign reconcile** (before enumeration): re-runs the shared `fleet_reconcile_orphans` scoped to ALL of the epic's children (every child, not just `planned`+`Backlog` — a mid-flight child is not in Backlog) and re-enqueues incomplete pipelines with reason `campaign-resume from {epic}`; a bash-killed pipeline is resumable unless its log carries a gate-stop marker
- Finds child tickets with `planned` label + `Backlog` state for the next wave
- Resolves `blocked-by:{ID}` dependencies (skips blocked tickets)
- Writes to spawn queue at `${state_dir}/fleet-{instance}-spawn-queue.jsonl` (workspace-relative, not `/tmp`)
- **Capacity counts live pipelines only** (worker pgrep-live or run-registry-alive) minus the epic's own pending queue entries — a dead pipeline log never consumes a slot
- Ends with a summary line: `fleet_dispatch: resumed N | dead-lettered N | blocked N | enqueued N ticket(s) for {epic}` (dry-run: `[DRY-RUN] would resume N | blocked N | would enqueue N ...`); per-tid `  resumed {tid}` / `  blocked {tid}` / `  enqueued {tid}` lines precede it
- Idempotent — re-running won't duplicate already-queued tickets
- Serialized per epic via an epic-scoped flock (`{queue}.{epic}.dispatch.lock`) — concurrent invocations (skill, `POST /dispatch`, auto-sweep) never double-enqueue
- A stopped epic enqueues nothing without `--resume` — dispatch is the single start/resume/un-stop entry point

### Stop (`stop`)

Epic-scoped stop: purge that epic's spawn-queue entries, escalate-kill its running workers, and write `stop-{epic}.json` so no dispatch trigger path re-enqueues it. Works with fleetd down — workers outlive a dead daemon.

```
/fleet-controller stop INIT-42              # stop an initiative epic
/fleet-controller stop INIT-42 "operator decision"  # with a recorded reason
```

- Single implementation in `fleet_dispatch_initiative`'s sibling `fleet_stop_initiative` (fleet-dispatch.sh) — `POST /stop` shells out to the same function
- Kills via `fleet_kill_pipeline`'s verified escalation (stop-files → grace → SIGTERM → SIGKILL, PID-reuse guard)
- **Purges by reason AND by child**: queue entries matching `planned-dispatch from {epic}` or `campaign-resume from {epic}` (or whose tid is one of the epic's Linear-resolved children) are purged; the same alternation matches running workers for the kill
- **Pins every child that could otherwise resume**: the stop-file's `tickets` array includes purged entries, killed workers, AND every child whose pipeline log classifies incomplete — a stop with an empty queue and no live workers still pins its mid-flight children (a failed children query degrades with a warning, never aborts the stop)
- The stop-file pins stopped tickets against fleetd's startup reconciliation
- Only an explicit resume (`dispatch --resume` or `POST /dispatch {"resume": true}`) clears it

### Feedback (`feedback`)

Aggregate `META|planner-feedback` entries from pipeline logs across all active workspaces.

```
/fleet-controller feedback                  # aggregate all feedback
/fleet-controller feedback --initiative INIT-42  # filter to single initiative
/fleet-controller feedback --dry-run        # preview without writing
```

- Groups feedback by `{initiative-id}` label
- Computes confidence drift (actual vs. predicted)
- Writes to `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`

## Implementation

The skill delegates to fleet lib scripts for all heavy lifting:

```
# Status mode — one-shot dashboard + report
source fleet-controller/lib/fleet-monitor.sh
data=$(fleet_detect_all ./logs)
fleet_render_dashboard_from_data "$data"
fleet_write_report_from_data "$data" ./logs

# Monitor mode — continuous detection loop
source fleet-controller/lib/fleet-monitor.sh
fleet_monitor_loop ./logs

# Intervene mode — manual kill/restart
source fleet-controller/lib/fleet-intervene.sh
fleet_kill_pipeline "$TICKET_ID" "manual-intervention" ./logs
# Or: fleet_restart_pipeline "$TICKET_ID" "manual-restart" ./logs

# Dispatch mode — enqueue planned tickets
source fleet-controller/lib/fleet-dispatch.sh
fleet_dispatch_initiative "INIT-42"
# Resume a stopped epic:
fleet_dispatch_initiative "INIT-42" ./logs --resume

# Stop mode — epic-scoped stop (works with fleetd down)
source fleet-controller/lib/fleet-dispatch.sh
fleet_stop_initiative "INIT-42" "operator decision" ./logs

# Feedback mode — aggregate planner feedback
source fleet-controller/lib/fleet-feedback.sh
fleet_aggregate_feedback
```

## Related Skills

- `ticket-auto-pipeline:ticket-overseer` — human-facing status reports (complementary)
- `ticket-auto-pipeline:ticket-detect-resume` — crash recovery from pipeline log
- `ticket-auto-pipeline:ticket-retro` — post-mortem failure analysis
