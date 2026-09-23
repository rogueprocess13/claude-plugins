---
name: ticket-reject
description: Rejects a Linear ticket's plan and clears any approval fact in its local manifest. The sole actuator for human rejection — removing the `approved` label directly in the tracker UI has no effect. Use when the user says "/ticket-reject <ID>", "reject ticket <ID>", or "reject <ID>".
---

# Ticket Reject

Rejects a ticket's plan by firing `flow.sh <TID> human-reject` (returns the ticket to `Todo` for re-appraisal) and clears the manifest's approval fact.

## Usage

```
/ticket-reject <TICKET-ID>
```

## Execution

This skill is a thin wrapper around `reject.sh`. Manifest bootstrap, the `flow.sh` mutation, the approval clear, and the read-back verification are all handled deterministically by the script — no LLM reasoning needed.

```bash
bash ~/.claude/skills/ticket-reject/reject.sh "<TICKET-ID>"
```

The script:
1. Makes the ticket manifest-addressable (`ensure_ticket_manifest`).
2. Runs `flow.sh <TICKET-ID> human-reject`, which moves the ticket to `Todo`.
3. Clears `approved`/`approval_provenance` on the manifest directly — `human-reject` is not one of `flow.sh`'s own approval-clearing triggers (only `re-claim` is), so this script owns the clear rather than depending on flow.sh plumbing that a previously-approved reject target would otherwise miss.
4. Reads the fields back and prints them (`approved=`, `approval_provenance=`, `stage=`).
5. Exits non-zero if the manifest still shows an approval afterward.

Report the printed values to the user. On a non-zero exit, show the script's stderr.
