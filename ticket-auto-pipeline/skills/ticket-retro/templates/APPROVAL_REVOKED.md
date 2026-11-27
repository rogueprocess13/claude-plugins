# APPROVAL_REVOKED — Gate-Stop Analysis Template

## Pattern

The pipeline halted because the manifest recorded no approval at the reapprove gate, between the PR iteration phase and the re-implement phase. `gate-check.sh --mode reapprove` reads the local manifest, not Linear: it gate-stops (exit 2) when the manifest shows no approval at stage `Ready`. Only re-claim or `reject.sh` clears an approval.

Approval is a local manifest fact (`approved`, `approval_provenance` = `human` or `policy`), never a tracker label. A `human` approval is recorded only by a person running `bash ~/.claude/skills/ticket-approve/approve.sh {ID}` in their own terminal. `ticket-pr-iterate` records a `policy` approval when it moves the ticket `Review -> Ready`.

## What to Look For

In `~/.claude/skills/ticket-auto/SKILL.md` STEP_4_6 (PR Review iteration sub-loop, the `ROUTE_VERDICT=WARN` row):

1. **Loop order**: the loop body must be `pr-review -> pr-iterate -> gate-check.sh --mode reapprove -> implement ...`. Does the reapprove gate run after `pr-iterate` on every iteration?
2. **What cleared the approval**: look in the pipeline log and the ticket outbox for a `re-claim` or `human-reject` transition between `pr-iterate` and the gate-stop. Either one legitimately clears `approved`.
3. **Stage**: the gate also stops when the manifest stage is not `Ready`. Check that `pr-iterate`'s `flow.sh` trigger ran and did not fail (`META|flow-error`, `META|flow-warn`).

In `~/.claude/skills/ticket-pr-iterate/SKILL.md`:

4. **State transition**: after posting findings, does the skill fire `pr-iterate` with `--provenance policy`, so the manifest shows stage `Ready` with a policy approval?

Not this code: a held reapprove gate (exit 1, `GATE|reapprove|fail|held: ...`) is not `APPROVAL_REVOKED`. Since PR #831 the reapprove gate applies the entry gate's approval rule: a complex, manual-mode or open-`[needs-human]` ticket waits for a person's `approve.sh` on the amended plan, because `pr-iterate`'s policy approval does not count for it.

## Order-of-operations artifact (check first)

Before chasing a cleared-approval hypothesis, check whether a `pr-iterate` trigger-def line follows the gate-stop within a minute or two, with `GATE|reapprove|done` shortly after. If so, the reapprove gate ran before `pr-iterate` on a PR-review WARN. A WARN legitimately leaves the ticket in `Review` with no approval in the manifest; only `pr-iterate` moves it `Review -> Ready` and records a (policy) approval. A gate-stop with reason `manifest records no approval` right before a `pr-iterate` line is this ordering bug, not a revoked approval.

## Minimal Fix Pattern

Fix the order in the router, not the approval. The reapprove gate must run after `pr-iterate` returns and its `flow.sh` trigger succeeds. Never add a tracker label check: the tracker label is not read by any gate.

## Related

- `ticket-auto/SKILL.md` STEP_4_6 for the iteration loop and the reapprove gate call.
- `lib/gate-check.sh` `_gate_reapprove` for the gate itself.
- `ticket-flow/workflow.json` for the `pr-iterate`, `re-claim` and `human-reject` triggers.
