# APPROVAL_REVOKED — Gate-Stop Analysis Template

## Pattern

The pipeline halted because the manifest recorded no approval at the reapprove gate, between the PR iteration phase and the re-implement phase. `gate-check.sh --mode reapprove` reads the local manifest, not Linear: it gate-stops when the manifest shows no approval at stage `Ready`. Only re-claim or `reject.sh` clears an approval.

## What to Look For

In `~/.claude/skills/ticket-auto/SKILL.md` Step 5d:

1. **Re-approval gate logic**: the check reads the local manifest and asserts `stage=Ready` with an approval recorded. Is this check happening before every re-implement spawn?
2. **Label lifecycle**: What removes the `approved` label? Check `ticket-pr-iterate` — does it strip labels? Does `ticket-flow`'s state transitions clear labels unexpectedly?
3. **Race condition**: Between `ticket-pr-iterate` posting findings and `ticket-auto` re-spawning implement, could a concurrent action (manual Linear edit, webhook) remove the label?

In `~/.claude/skills/ticket-pr-iterate/SKILL.md`:

4. **State transition**: After posting findings, does the skill move the ticket to `Ready` AND ensure `approved` is still present?

## Order-of-operations artifact (check first)

Before chasing a label-race hypothesis, check whether a `pr-iterate` trigger-def line follows the gate-stop within a minute or two, with `GATE|reapprove|done` shortly after. If so, the reapprove gate ran before `pr-iterate` on a PR-review WARN. A WARN legitimately leaves the ticket in `Review` with no approval in the manifest; only `pr-iterate` moves it `Review -> Ready` and records a (policy) approval. The reapprove gate must run AFTER `pr-iterate` (loop body: `pr-review -> pr-iterate -> gate-check.sh --mode reapprove -> implement ...`). A gate-stop with reason `manifest records no approval` right before a `pr-iterate` line is this ordering bug, not a revoked approval.

## Minimal Fix Pattern

The fix typically adds a label-verification step in `ticket-pr-iterate` after the Linear update:

```bash
# Verify approved label survived the state transition
LABELS=$(linear_api "query { issue(id: \"$TICKET_ID\") { labels { nodes { name } } } }")
echo "$LABELS" | jq -e '.data.issue.labels.nodes[].name | select(. == "approved")' || {
  echo "FATAL: approved label lost during pr-iterate"
  exit 1
}
```

## Related

- See `ticket-auto/SKILL.md` Step 5d for the re-approval gate logic.
- See `ticket-flow/workflow.json` for label-to-state mappings.
