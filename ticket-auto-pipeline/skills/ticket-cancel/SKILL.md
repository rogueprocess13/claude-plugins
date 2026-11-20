---
name: ticket-cancel
description: Cancels a Linear ticket nobody will finish (obsolete, duplicate, superseded by a re-plan). The sole actuator for retiring a ticket — setting Canceled directly in the tracker UI bypasses the manifest, the outbox and the pipeline log. Use when the user says "/ticket-cancel {ID} --reason ...", "cancel ticket {ID}", or "retire {ID}".
---

# Ticket Cancel

Retires a ticket by firing `flow.sh <TID> cancel --reason "<text>"` (any stage except `Done` → `Canceled`) and writing the pipeline-log record.

## Usage

```
/ticket-cancel <TICKET-ID> --reason "<why the ticket is retired>" [--force]
```

A reason is required. If the user gave none, ask for one before running.

## Execution

This skill is a thin wrapper around `cancel.sh`. Do not set the tracker state yourself.

```bash
bash ~/.claude/skills/ticket-cancel/cancel.sh "<TICKET-ID>" --reason "<reason>"
```

The script:
1. Refuses while a pipeline worker for the ticket is alive (exit 6). Stop the run first. `--force` cancels anyway; the worker's later transitions are then refused by `flow.sh` (exit 14).
2. Runs `flow.sh <TICKET-ID> cancel`: manifest stage `Canceled`, the four projected flags and the approval cleared, one `ticket-cancelled` outbox event. The board driver moves the card to the cancelled column and removes `needs-info`, `needs-adr`, `rejected` and `reviewed`.
3. Appends `META|cancel|info|reason=…; from=…; by=…` and `META|outcome|info|cancelled: …` to the pipeline log.
4. Prints `stage=`, `already_cancelled=`, `reason=`, `log=`, `logged=` and `blocked_dependents=`.

Exit codes: 0 cancelled (or already cancelled, a no-op), 1 usage, 5 the ticket is `Done` or an epic, 6 a worker is alive; any other code is `flow.sh`'s own.

Report the printed values to the user. If `blocked_dependents=` is not empty, say so plainly: those tickets are **not** released and stay blocked until a person cancels them too or re-plans. A cancelled ticket takes no further transition; file a new ticket to redo the work. On a non-zero exit, show the script's stderr.
