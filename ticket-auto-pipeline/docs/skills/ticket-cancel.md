# ticket-cancel

> Cancels a ticket nobody will finish (obsolete, duplicate, superseded by a re-plan). The one sanctioned way to retire a ticket. Use when the user says "/ticket-cancel {ID} --reason ...", "cancel ticket {ID}", or "retire {ID}".

## What it does

`ticket-cancel` is a thin wrapper around `skills/ticket-cancel/cancel.sh`, which fires the `cancel` trigger through `flow.sh` and writes the pipeline-log record. Setting Canceled by hand in the tracker changes only the board: the local manifest still holds the old stage, no event is recorded, and the log says nothing.

## Trigger

**Slash command:** `/ticket-cancel <ID> --reason "<why>" [--force]`

**Natural language:** "cancel ticket <ID>", "retire <ID>"

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Ticket ID | Argument | Yes |
| `--reason "<text>"` | Argument | Yes |
| `--force` | Argument (cancel while a worker is alive) | No |
| `REPOS_ROOT` | Environment | Yes |

## Outputs / Artifacts

| Artifact | Location | Description |
|----------|----------|-------------|
| Manifest | `$REPOS_ROOT/.ticket-auto/initiatives/…/manifest.json` | `stage: Canceled`, `flags: []`, approval cleared, `rev` + 1 |
| Outbox event | `{log dir}/{ID}-outbox.jsonl` | One `ticket-cancelled` event with `data.reason` |
| Board | Linear, when the outbox drains | Card in the cancelled column (the state named `Canceled`, else the team's first state of type `canceled`); `needs-info`, `needs-adr`, `rejected`, `reviewed` removed; every other label kept |
| Log record | `{log dir}/{ID}-pipeline.log` | `META\|cancel\|info\|reason=…; from=…; by=…` then `META\|outcome\|info\|cancelled: …` as the last line |
| Stdout | Process | `stage=`, `already_cancelled=`, `reason=`, `log=`, `logged=`, `blocked_dependents=` |
| Exit code | Process | 0 cancelled or already cancelled, 1 usage, 5 `Done` or an epic, 6 a worker is alive, else `flow.sh`'s code |

## How it works

```mermaid
flowchart TD
    A[/ticket-cancel ID --reason/] --> B{epic, or stage Done?}
    B -- yes --> X[exit 5, nothing written]
    B -- no --> C{worker alive?}
    C -- yes, no --force --> Y[exit 6, nothing written]
    C -- no, or --force --> D[flow.sh cancel: manifest + one outbox event]
    D --> E[log: META cancel, then META outcome cancelled]
    E --> F[print blocked dependents]
    D -. outbox drain .-> G[board: cancelled column, four labels removed]
```

## Rules

- **Canceled is final.** `flow.sh` refuses every other trigger on a cancelled ticket with exit 14 and writes nothing. To redo the work, file a new ticket.
- **A running worker.** The script refuses while a worker for the ticket is alive: stop it first. With `--force` the ticket is cancelled under it and the worker's later transitions are refused (exit 14). The script never kills a process.
- **Dependents are not released.** `blocked-by` resolves on `Done` only. A ticket blocked by a cancelled one stays blocked; fleet dispatch names the cancelled blocker on every pass, and the script prints the dependents. A person cancels them too or re-plans.
- **An epic's child.** An epic that lists a cancelled child cannot reach "all children Done", so its integration PR is not opened. Dispatch prints the cancelled child on every pass.
- **Fenced generations.** A worker whose generation was superseded cannot cancel (exit 9 or 10), as for any trigger.
- **Repeat.** Cancelling an already-cancelled ticket is a no-op.
