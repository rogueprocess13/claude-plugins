---
name: ticket-approve
description: Approves a Linear ticket held at the entry gate. The sole actuator for human approval — adding the `approved` label directly in the tracker UI does not approve a ticket. Use when the user says "/ticket-approve <ID>", "approve ticket <ID>", or "approve <ID>".
---

# Ticket Approve

Approves a gated ticket by writing the approval fact to its local manifest — never by adding a tracker label. Wraps `flow.sh <TID> human-approve --provenance human`.

## Usage

```
/ticket-approve <TICKET-ID>
```

## Execution

This skill is a thin wrapper around `approve.sh`. Manifest bootstrap, the `flow.sh` mutation, and the read-back verification are all handled deterministically by the script — no LLM reasoning needed.

```bash
bash ~/.claude/skills/ticket-approve/approve.sh "<TICKET-ID>"
```

The script:
1. Makes the ticket manifest-addressable (`ensure_ticket_manifest` — a hand-created ticket with no planner-assigned initiative gets a reserved `_adhoc` one, so approval never silently no-ops on it).
2. Runs `flow.sh <TICKET-ID> human-approve --provenance human`, which moves the ticket to `Ready` and writes `approved: true`, `approval_provenance: human`, and `stage: Ready` to the manifest.
3. Reads the three fields back from the manifest and prints them (`approved=`, `approval_provenance=`, `stage=`).
4. Exits non-zero if the manifest does not show `approved=true` afterward — never report success on an unverified write.

Report the printed `approved`/`approval_provenance`/`stage` values to the user. On a non-zero exit, show the script's stderr — do not retry silently, since a repeated failure on the same ticket usually means the ticket isn't actually at the gate (wrong state) or the manifest is unreachable (`REPOS_ROOT` unset).
