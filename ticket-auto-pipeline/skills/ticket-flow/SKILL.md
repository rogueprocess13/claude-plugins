---
name: ticket-flow
description: ticket-flow
---

# ticket-flow

Centralized Linear state/label executor for the ticket workflow. Every ticket skill delegates state transitions and label changes here — no skill calls Linear for state or labels directly.

## Usage

Invoke with:

```
/ticket-flow <TICKET-ID> <TRIGGER> [--data key=value] [--dry-run] [--override REASON]
```

Where `--data` supplies trigger-specific values (e.g. `complexity=simple`, `outcome=Smooth`).

## Execution

This skill is a thin wrapper around `flow.sh`. All state machine logic and the local manifest write are handled deterministically by the script — `flow.sh` performs no tracker I/O (tracker-flow-projection-cutover). It reads and writes only `workflow.json` and the ticket's local manifest, then emits one outbox event and drains it. `$LINEAR_API_KEY` is not required to invoke this skill; it is required only for the board projection to actually reach Linear (the driver `flow.sh` dispatches to at exit, via `outbox-drain.sh`), and its absence never fails or delays a transition.

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "${TAP_LOG:-}" "<TICKET-ID>" "<TRIGGER>" [--data key=value] [--dry-run] [--override REASON]
```

`lib/flow-run.sh` is the one shell entry point for a trigger. It resolves `flow.sh`
(`~/.claude/skills/ticket-flow/flow.sh`, then `tap_cache_find` — installed version, then
newest cached version by version order, #468), runs it, records a failure in the pipeline
log and heartbeat, and exits with `flow.sh`'s own code. **Skills and phase agents call the
wrapper with Bash, never this slash command inside a bash block** — `/ticket-flow` is not a
shell command, so a following `_rc=$?` would read nothing, and the phase agents
(appraise, implement, verify, pr-review) have no Skill tool.

### Exit codes

| Code | Meaning | Recorded by `flow-run.sh` |
|------|---------|---------------------------|
| `0` | Transition applied (or a warn-only no-op such as `ILLEGAL_TRANSITION`) | nothing |
| `1` | Usage (`error_type=usage`) or runtime error (`flow_error`) | `META\|flow-error\|fail\|exit 1: <trigger> — <stderr>` |
| `3`/`8`/`9`/`10`/`12`/`13` | Unknown trigger / precondition / fence: no token / fence: superseded / pending event not replayable / `REPOS_ROOT` unset | `META\|flow-error` |
| `11` | **Verdict gate blocked** — a `verdict_gate` trigger (`uat-pass`, `pr-review-pass-done`, `pr-review-pass-uat`) refused because a trailing FAIL/BLOCK verifier-result is on record. Not transient: do not retry and do not report PASS/Done. | `META\|gate-stop\|fail\|VERDICT_GATE_BLOCKED — <trigger> refused, see flow.sh stderr` |
| `42` | Another `flow.sh` run for this ticket holds the lock | `META\|flow-error` |
| `127` | `flow.sh` could not be resolved — nothing ran | `META\|flow-error\|fail\|flow.sh not found: <trigger>` |

Every call site that fires a verdict-gated trigger branches on `11` explicitly;
`lib/tests/test-flow-run.sh` fails the build if one does not.

## Reference: State Machine

`skills/ticket-flow/workflow.json` owns the states, triggers, label deltas and preconditions;
`flow.sh` reads it live. Print the trigger table (name, from, to, adds, removes, precondition,
verdict gate) with:

```bash
jq -r '.triggers | to_entries[] | [.key, (.value.from|tostring), (.value.to // "-"), (.value.adds // [] | join(",")), (.value.removes // [] | join(",")), (.value.precondition // "-"), (if .value.verdict_gate then "verdict_gate" else "-" end)] | @tsv' skills/ticket-flow/workflow.json
```

Each trigger's `description` and `emits` fields carry its notes and its outbox event.

### Labels

The board driver writes exactly four labels, `needs-info`, `needs-adr`, `rejected` and
`reviewed` (`workflow.json` `board_drivers.linear.projected_labels`), from the manifest's
`flags`; nothing reads them back. Every other label on a ticket is left untouched. Under
`UAT Policy: epic` a child goes straight to `Done` and keeps `reviewed`, so `reviewed` does not
mean "awaiting QA" there: do not key an "in flight" heuristic on it. Approval and the
`Smooth`/`Rough`/`Hard` outcome are manifest facts, never tracker labels.

**The board is a projection, not the source of truth.** It lags at most one pusher interval
(`FLEET_BOARD_PUSHER_INTERVAL`, default 300s) when only `fleetd` drains a ticket's outbox, and
updates within the same command when `flow.sh` drains at exit. A hand edit to one of the four
projected labels is reverted on the next event that projects to it, if pipeline state
disagrees; any other hand-applied label is left alone.

**Which pass trigger fires (`pr-review-pass-done` or `pr-review-pass-uat`) is not decided here.**
`uat_decide_trigger` in `lib/branch-resolve.sh` evaluates the epic's UAT policy *before* the UAT
target. That ordering is load-bearing: `UAT_URL` is exported into every pipeline agent's
environment, so a policy check placed after an "is UAT configured?" test would never be reached.
The decision is logged as `META|uat-policy|info|<policy>`.

### Preconditions

The epic guard is **bidirectional**: `must_be_epic` rejects (exit 8) the three epic triggers on
a non-epic issue, and `must_not_be_epic` rejects every child lifecycle trigger on an epic. The
inverse direction matters because the router does not branch on which trigger fired: without it,
an epic pushed through the ticket pipeline would take a child's pass-to-`Done` trigger and close
itself. The epic triggers act on the epic issue itself; there is deliberately no epic-rejection
trigger (a human moves the card). Epic detection lives in `lib/epic-precondition.sh`, which
`flow.sh` sources.

### Verdict gate

`pr-review-pass-done`, `pr-review-pass-uat` and `uat-pass` carry `"verdict_gate": true`.
`flow.sh` refuses them with exit 11 while any `(verifier, phase)` pair's **latest**
`META|verifier-result` is `FAIL` or `BLOCK` (see `verifier_latest_verdict` in
`lib/verifier-result.sh`). Caller contract:

- **Write your own verdict (`write_verifier_result`) before firing the gated trigger, not
  after**, or a verify retry that now passes is blocked by the previous attempt's FAIL.
- On exit `11`, skip the PASS comment and `PHASE_RESULT`; emit
  `META|gate-stop|fail|VERDICT_GATE_BLOCKED` and `PHASE_RESULT: VERDICT: BLOCK` instead.
- `--override <reason>` forces the trigger and records `META|verdict-override` with the pairs it
  superseded.

## Preflight Sentinel

`validate-linear-config.sh` writes a sentinel file at:
```
~/.claude/state/ticket-flow/validated-{TEAM_ID}
```

The sentinel contains `schema_version`, `sm_hash` (SHA256 of `workflow.json`), and `validated_at`. `ticket-preamble.sh` reads this file — if it exists and the hash matches the current `workflow.json`, validation is skipped (warm hit). Any edit to `workflow.json` automatically invalidates the sentinel.

To force re-validation:
```bash
source ~/.claude/skills/lib/plugin-cache.sh
_validate_sh="${HOME}/.claude/skills/ticket-flow/validate-linear-config.sh"
# Not synced: the installed (else newest cached) version, by version order (#468).
[ -f "$_validate_sh" ] || _validate_sh=$(tap_cache_find ticket-auto-pipeline skills/ticket-flow/validate-linear-config.sh)
bash "$_validate_sh" --force
```

To delete the sentinel manually:
```bash
rm ~/.claude/state/ticket-flow/validated-{TEAM_ID}
```
