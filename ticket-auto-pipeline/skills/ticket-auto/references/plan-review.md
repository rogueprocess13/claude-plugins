# ticket-auto — independent plan review (STEP_2_2)

Read only under the condition in SKILL.md "STEP_2_2 — Plan review": `{PLAN_REVIEW}` is `review` or `revise`. That happens when `TICKET_ROUTER_PLAN_REVIEW` was not `false` when the ticket's preamble first ran (`META|plan-review|info|router`). `lib/plan-review.sh` makes every decision here; you only spawn the agent and act on what the script prints.

## STEP_2 with `{PLAN_REVIEW}` = `revise`

The last review BLOCKED the plan and the cap is not reached. Dispatch STEP_2 as SKILL.md describes, with two changes: `FROM_STEP=create-artifact`, and `INSTRUCTIONS` is the file this prints:

```bash
bash ~/.claude/skills/lib/plan-review.sh revise {TICKET_ID} --log-file "{LOG_FILE}" --ticket-dir "{TICKET_DIR}"
```

Pass `INSTRUCTIONS="$(cat <PLAN_REVISE_INSTRUCTIONS_FILE>)"`. After the agent returns, close the spawn as for any STEP_2, then re-run `detect-resume.sh`: it routes to STEP_2_2 for the re-review.

## STEP_2_2

```bash
bash ~/.claude/skills/lib/plan-review.sh prepare {TICKET_ID} --log-file "{LOG_FILE}" --ticket-dir "{TICKET_DIR}" --repos-root "{REPOS_ROOT}"
```

If it prints `PLAN_REVIEW_READY=skip`, there is nothing to review (a simple ticket under the default, no plan, or already reviewed): spawn nothing and re-run `detect-resume.sh`. Otherwise spawn the reviewer with the standard pattern (Agent spawn template):

```
STEP=plan-review PHASE=EXEC SKILL=/ticket-auto-pipeline:ticket-plan-review
AGENT_TYPE=ticket-auto-pipeline:ticket-plan-review-agent
DESCRIPTION="Independent plan review (round <PLAN_REVIEW_ROUND>)"
INSTRUCTIONS="$(cat <PLAN_REVIEW_INSTRUCTIONS_FILE>)"
```

Pass the reviewer nothing else: no summary of the plan, no opinion, nothing from an earlier phase's return. After it returns, write its return to `./logs/{TICKET-ID}-agent-return.txt` (quoted heredoc), then run the script below **instead of** `spawn_capture` / `spawn_agent_post`: it captures the return and closes the bracket itself.

```bash
eval "$(bash ~/.claude/skills/lib/plan-review.sh done {TICKET_ID} --log-file "{LOG_FILE}" --ticket-dir "{TICKET_DIR}")"
echo "PLAN_REVIEW_VERDICT=$PLAN_REVIEW_VERDICT PLAN_REVIEW_DECISION=$PLAN_REVIEW_DECISION round=$PLAN_REVIEW_ROUND"
case "$PLAN_REVIEW_DECISION" in
advance | retry) ;;
*)
  # exhausted (ADVERSARIAL_BLOCKED) or invalid (PLAN_REVIEW_NO_VERDICT): the gate-stop is already in the log.
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
  ;;
esac
```

- `advance` (PASS or WARNINGS): the findings are in `notes.md` under `## Adversarial Review`. Re-run `detect-resume.sh`; it routes to STEP_2_5.
- `retry` (BLOCKED, under the cap): re-run `detect-resume.sh`; it reports `PLAN_REVIEW: revise` and STEP_2.
- anything else: stopped above. Tell the user the findings are in `plan-review.md` in the ticket workspace. A person revises the plan and re-runs `/ticket-auto {TICKET_ID}`, or accepts it with `adversarial-override.sh` (README "Human Decisions").

Never decide the verdict yourself and never write an `adversarial-review` log line: the script reads the reviewer's result file.
