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
_flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
[ -f "$_flow_sh" ] || _flow_sh=$(find "${HOME}/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)
bash "$_flow_sh" "<TICKET-ID>" "<TRIGGER>" [--data key=value] [--dry-run]
```

## Reference: State Machine

### States

| State | Meaning |
|-------|---------|
| `Backlog` | New, unclaimed |
| `Blocked` | Waiting on external dependency |
| `Todo` | Claimed, under appraisal |
| `Approve` | Appraisal done, awaiting human sign-off |
| `Ready` | Approved, implementation in progress |
| `Review` | PR(s) open, awaiting code review / QA |
| `UAT` | Code reviewed, awaiting business partner acceptance testing |
| `Done` | Verified — all acceptance criteria confirmed |

Epic issues reuse these same states for their own acceptance (see the epic triggers below):
`Backlog` while children execute → `Review` when integration PRs are open → `UAT` when the
integration is merged and deployed → `Done` on acceptance.

### Labels

Four labels — the complete set the pipeline writes to the board, per `workflow.json`'s
`board_drivers.linear.projected_labels` (tracker-flow-projection-cutover). They are outputs:
written by the board driver from the ticket's manifest `flags`, read by nothing. Every other
label a ticket carries (`bug`, `feature`, a still-planner-written `planned`/`INIT-*`, or anything
hand-applied) is preserved untouched by the driver — it only ever adds/removes these four.

| Label | Meaning |
|-------|---------|
| `needs-info` | Blocked waiting for clarification |
| `needs-adr` | Parked or stopped on an ADR gate verdict |
| `rejected` | PR review found gaps OR UAT verification failed — ticket needs rework |
| `reviewed` | PR review passed. Under `per-ticket` UAT policy this means "awaiting QA" and is cleared by `uat-pass`. **Under `UAT Policy: epic` it does not mean that** — the child goes straight to `Done` and retains the label, because there is no per-ticket QA step. Do not key an "in flight" heuristic on it. |

Approval (`approved`), predicted complexity (`Simple`/`Complex`, removed — vestigial per
`docs/label-audit.md`), and implementation outcome (`Smooth`/`Rough`/`Hard`) are **not** tracker
labels: approval lives in the local manifest as the authoritative decision fact
(`/ticket-approve`/`/ticket-reject`, tracker-approval-by-script), and outcome lives in the
manifest's `outcome_label` field (`outcome-label-check.sh`). Neither is ever written to Linear.

**The board is a projection, not the source of truth.** It lags at most one pusher interval
(`FLEET_BOARD_PUSHER_INTERVAL`, default 300s) when only `fleetd` drains a ticket's outbox; it
updates within the same command when the router does (`flow.sh` drains at exit, unconditionally).
Hand-editing one of the four projected labels is reconciled — reverted, if the pipeline's own
state disagrees — on the next event that projects to that label, not immediately; every other
label a person applies by hand is left alone indefinitely.

### Transitions

| Trigger | State | Flags Added | Flags Removed | Notes |
|---------|-------|-------------|----------------|-------|
| `appraise-start` | `Todo` | — | — | Board projection also sets `assignee: "me"` |
| `appraise-complete` | `Approve` | — | — | |
| `human-approve` | `Ready` | — | `rejected` | Manifest `approved`/`approval_provenance` set (tracker-approval-by-script) |
| `human-reject` | `Todo` | — | — | |
| `implement-outcome` | — | — | — | No state or flag change; outcome recorded in the manifest, not the board |
| `implement-complete` | `Review` | — | — | Manifest `approved` cleared |
| `pr-review-pass-done` | `Done` | `reviewed` | `rejected` | Chosen by `uat_decide_trigger` — fires under `UAT Policy: epic`, or under `per-ticket` with no UAT target |
| `pr-review-pass-uat` | `UAT` | `reviewed` | `rejected` | Chosen by `uat_decide_trigger` — fires under `per-ticket` policy with a UAT target |
| `pr-review-fail` | — | `rejected` | — | No state change |
| `pr-iterate` | `Ready` | — | `reviewed`, `rejected` | |
| `uat-pass` | `Done` | — | `reviewed` | |
| `uat-fail` | `Ready` | `rejected` | `reviewed` | |
| `needs-info` | — | `needs-info` | — | No state change |
| `needs-info-resolved` | — | — | `needs-info` | No state change |
| `needs-adr` | — | `needs-adr` | — | No state change |
| `needs-adr-resolved` | — | — | `needs-adr` | No state change |
| `re-claim` | — | — | — | No state change; manifest `approved` cleared; restarts gate hold cycle |

**Which of the two pass triggers fires is not decided here.** It is computed by
`uat_decide_trigger` in `lib/branch-resolve.sh`, which evaluates the epic's UAT policy *before*
the UAT target. That ordering is load-bearing: `UAT_URL` is exported into every pipeline agent's
environment unconditionally, so a policy check placed after a "is UAT configured?" test would
never be reached. The decision is recorded in the pipeline log as `META|uat-policy|info|<policy>`.

### Epic acceptance transitions

These act on the **epic issue itself**, not on child tickets. They add and remove no labels, so no
new workspace label is required, and each declares a single-valued source state so log and
telemetry records stay on one line.

| Trigger | From | To | Labels | Notes |
|---------|------|----|--------|-------|
| `epic-integration-open` | `Backlog` | `Review` | — | Fired by the fleet controller's epic-readiness detector once at least one integration PR is observed open |
| `epic-uat-start` | `Review` | `UAT` | — | Operator signals the integration has been merged and deployed |
| `epic-uat-pass` | `UAT` | `Done` | — | Epic UAT accepted |

There is deliberately **no epic-rejection trigger**. `Ready` means "approved, implementation in
progress" — a child-workflow state nothing acts on for an epic whose children are all `Done`. At
the moment a business partner rejects, a human is already in Linear and can move the card.

### Preconditions

A precondition may be declared on a **trigger** as well as on a label, and the epic guard is
**bidirectional**:

| Precondition | Effect |
|---|---|
| `must_be_epic` | The trigger or label is rejected (exit 8) on a non-epic issue. Carried by the three epic triggers and by the `state:execution` label. |
| `must_not_be_epic` | The trigger is rejected (exit 8) on an epic issue. Carried by every child lifecycle trigger. |

The inverse direction matters because the router does not branch on which trigger fired: without
it, an epic accidentally pushed through the ticket pipeline would take a child's pass-to-`Done`
trigger and close itself.

An issue counts as an epic when it carries the epic marker label (`EPIC_MARKER_LABEL`, default
`epic`) **or** a valid `## Branch Directive` in its description — both already present in the
payload `flow.sh` fetches, so neither costs an extra request. The evaluator lives in
`lib/epic-precondition.sh` and `flow.sh` sources it, so tests exercise the same code path the
executor runs.

### Verdict gate

Independent of the epic precondition above, a trigger may also declare `"verdict_gate": true` in
`workflow.json`. `pr-review-pass-done`, `pr-review-pass-uat`, and `uat-pass` carry it —
the three triggers that can land a ticket in `Done` or `UAT`. Before dispatching such a trigger,
`flow.sh` calls `verifier_latest_verdict` (`lib/verifier-result.sh`) to find the most recently
recorded verdict for every `(verifier, phase)` pair the pipeline log has written a
`META|verifier-result` entry for. If any pair's **latest** verdict is `FAIL` or `BLOCK`, the
trigger is refused (exit 11) with a clear message naming the offending pair — a later `PASS`/
`WARN` for that same pair supersedes the earlier failure and clears the block on its own.

To force the trigger through anyway (e.g. a fix verified by hand, outside the pipeline), pass
`--override <reason>`. The reason is recorded as `META|verdict-override` alongside which
`(verifier, phase)` pairs it superseded — never silently.

A ticket with zero `META|verifier-result` entries (every ticket that predates this gate) is
unaffected: absence of evidence is not failure.

```
flow.sh <TICKET-ID> pr-review-pass-done --override "manually verified per WIL-79, HTTP 500 fixed in 979b648"
```

**Callers must write their own verdict before dispatching the gated trigger, not after.**
`ticket-verify` and `ticket-pr-review` each call `write_verifier_result` immediately once
their own verdict is known, strictly before the `uat-pass` / `pr-review-pass-*` call —
otherwise the router's own documented verify-retry loop (attempt 1 FAILs and is logged,
attempt 2 genuinely PASSes) would have attempt 2's own trigger call check the log *before*
its own PASS was written, still see attempt 1's stale FAIL, and block a ticket that just
legitimately passed. On a `flow.sh` exit `11`, both callers skip their normal PASS
comment/`PHASE_RESULT` and emit `META|gate-stop|fail|VERDICT_GATE_BLOCKED` with
`PHASE_RESULT: VERDICT: BLOCK` instead — a gate block must never look identical to a real
completion in the log or in Linear, the inverted form of the bug this gate exists to fix.

**`epic-uat-pass` deliberately carries no `verdict_gate`.** No phase writes a per-epic
`META|verifier-result` against the epic issue's own pipeline log — verifier-results are
written by child-ticket phases (VERIFY/PR-REVIEW) against each *child's* log. A
`verdict_gate` on the epic trigger would read an always-empty per-epic verifier history and
never block anything — worse than no gate, since it would look load-bearing without being
one. See `workflow.json`'s `epic-uat-pass` `description` field for the same note next
to the trigger it documents.

## Preflight Sentinel

`validate-linear-config.sh` writes a sentinel file at:
```
~/.claude/state/ticket-flow/validated-{TEAM_ID}
```

The sentinel contains `schema_version`, `sm_hash` (SHA256 of `workflow.json`), and `validated_at`. `ticket-auto` Step 0.4 reads this file — if it exists and the hash matches the current `workflow.json`, validation is skipped (warm hit). Any edit to `workflow.json` automatically invalidates the sentinel.

To force re-validation:
```bash
_validate_sh="${HOME}/.claude/skills/ticket-flow/validate-linear-config.sh"
[ -f "$_validate_sh" ] || _validate_sh=$(find "${HOME}/.claude/plugins/cache" -name "validate-linear-config.sh" -path "*/ticket-auto-pipeline/*/validate-linear-config.sh" 2>/dev/null | sort | tail -1)
bash "$_validate_sh" --force
```

To delete the sentinel manually:
```bash
rm ~/.claude/state/ticket-flow/validated-{TEAM_ID}
```
