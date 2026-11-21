---
name: ticket-reject
description: Tells the user how to reject a Linear ticket's plan and clear any approval fact in its local manifest. Rejection is a person's decision, so this skill never rejects — it prints the command for the user to run in their own terminal. Use when the user says "/ticket-reject {ID}", "reject ticket {ID}", or "reject {ID}".
---

# Ticket Reject

A rejection is recorded only by `reject.sh`, run by a person at an interactive terminal. The script and `flow.sh` refuse an agent or fleetd-worker session and a missing terminal. Do **not** run the script or `flow.sh human-reject` yourself.

## Usage

```
/ticket-reject <TICKET-ID>
```

## Execution

Print this for the user, with the ticket id filled in, and stop:

```
Run this in your own terminal, from the tickets root:

  bash ~/.claude/skills/ticket-reject/reject.sh <TICKET-ID>

It asks you to type the ticket id back, clears any approval and returns
the ticket to Todo for re-appraisal.
```
