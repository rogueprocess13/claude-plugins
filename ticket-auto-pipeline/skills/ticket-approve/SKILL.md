---
name: ticket-approve
description: Tells the user how to approve a Linear ticket held at the entry gate. Approval is a person's decision, so this skill never approves — it prints the command for the user to run in their own terminal. Use when the user says "/ticket-approve {ID}", "approve ticket {ID}", or "approve {ID}".
---

# Ticket Approve

An approval is recorded only by `approve.sh`, run by a person at an interactive terminal. The script, `flow.sh` and the manifest writer refuse an agent or fleetd-worker session and a missing terminal. Do **not** run the script, `flow.sh human-approve` or a manifest write yourself, and do not look for a way round the refusal.

## Usage

```
/ticket-approve <TICKET-ID>
```

## Execution

Print this for the user, with the ticket id filled in, and stop:

```
Run this in your own terminal, from the tickets root:

  bash ~/.claude/skills/ticket-approve/approve.sh <TICKET-ID>

It shows the ticket and its stage and asks you to type the ticket id back.
Then re-run /ticket-auto <TICKET-ID>.
```

Remind the user to read the plan and answer open questions in the appraisal comment first. On an error they report: exit 3 means `REPOS_ROOT` could not be resolved (export it, or run from the tickets root); exit 4 means the command did not run in an interactive terminal.
