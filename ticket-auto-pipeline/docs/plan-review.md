# Independent plan review (STEP_2_2)

GitHub #667. Under the ticket-auto router each phase runs as a subagent, and a subagent cannot spawn another agent. The adversarial review that `ticket-appraise-exec` Step 3.6 describes therefore ran inline, in the context that had just written the plan. With `TICKET_ROUTER_PLAN_REVIEW=true` the router runs that review itself, as its own dispatch step, with a fresh read-only agent.

## Turn it on

Set `TICKET_ROUTER_PLAN_REVIEW=true` in the environment the router runs in (for example the `env` block of the tickets project's `.claude/settings.local.json`). Default `false`. Catalog entry: `fleet-controller/features.json`.

The flag is read once per ticket, by `ticket-preamble.sh`, and recorded in the pipeline log:

| Line | Meaning |
|---|---|
| `META\|plan-review\|info\|router` | The router runs STEP_2_2. `ticket-appraise-exec` skips Step 3.6. |
| `META\|plan-review\|info\|inline — …` | The flag was on, but the caller was fleetd phase dispatch, which does not run STEP_2_2. Step 3.6 runs inline as before. |
| no line | The flag was off. Nothing changes. |

Every later reader asks `lib/plan-review.sh`, never the environment variable, so a ticket keeps one mode from start to finish.

## What runs

1. STEP_2 (EXEC) writes the plan. In router mode Step 3.6 is skipped and `references/adversarial-review.md` is not read.
2. `detect-resume.sh` reports `PLAN_REVIEW: review` and `RESUME_STEP: STEP_2_2`.
3. `plan-review.sh prepare` skips simple tickets (`EXEC|plan-review|skip|`) and writes the reviewer's instructions: ticket workspace, plan artifact, repositories root, result file.
4. The router spawns `ticket-plan-review-agent` (tools: Read, Grep, Glob, Write) on the `ticket-plan-review` skill. It gets no text from the phase that wrote the plan. It writes `plan-review.md` in the ticket workspace and returns one line.
5. `plan-review.sh done` reads that file and decides. No model reads the verdict.

## The rule for findings

The result file lists findings as `### F<n> — <blocker|major|minor|nit> — <title>`, or `None.`.

| Result | Verdict | What happens |
|---|---|---|
| `None.` | PASS | Advance to the entry gate (STEP_2_5). |
| Findings, no `blocker` | WARNINGS | Advance. The findings are appended to `notes.md` under `## Adversarial Review` and recorded as a WARN verifier result, so they travel with the ticket. |
| At least one `blocker`, first time | BLOCKED | One loop back: STEP_2 re-runs from `create-artifact` with `plan-review.md` as input, revises the plan, and STEP_2_2 reviews again. |
| At least one `blocker`, second time | BLOCKED | `META\|gate-stop\|fail\|ADVERSARIAL_BLOCKED — round N — …`. The pipeline stops. |
| File missing or malformed | none | `META\|gate-stop\|fail\|PLAN_REVIEW_NO_VERDICT`. The next run reviews again. Never a pass. |

The cap is `revise_loop.max_iterations` (2) on STEP_2_2 in `dispatch-table.json`: the number of BLOCKED verdicts since the last passing verdict or `ADVERSARIAL_BLOCKED` gate-stop, counted from the pipeline log. This is the verify retry's shape (two attempts, then a named gate-stop).

The verdict records are the ones Step 3.6 writes inline (`EXEC|adversarial-review|done|<VERDICT>`, the `adversarial_review` verifier result, the `ADVERSARIAL_BLOCKED` gate-stop). So the verdict gate in `flow.sh`, `adversarial-override.sh`, `adversarial-rounds.sh` and the failure classification work unchanged. After a stop a person revises the plan and re-runs `/ticket-auto`, or accepts it with `adversarial-override.sh`.

## Resume

`plan-review.sh state <log>` reads the log alone:

| State | When | `detect-resume.sh` |
|---|---|---|
| `off` | no `router` line | unchanged |
| `review` | no verdict yet, or EXEC ran again after a BLOCKED verdict | `STEP_2_2` |
| `revise` | latest verdict BLOCKED, under the cap, plan not revised yet | `STEP_2`, `EXEC_FROM=create-artifact` |
| `stopped` | latest verdict BLOCKED and its gate-stop written | `STEP_2` from `create-artifact` (the existing recovery) |
| `resolved` | latest verdict PASS or WARNINGS, or the review was skipped | `STEP_2_5` |

A review agent that died leaves `EXEC|plan-review|waiting|` open; zombie detection closes it and routes back to STEP_2_2.

## fleetd

A ticket-level fleetd worker is the router, so it runs STEP_2_2. fleetd **phase dispatch** does not: its preamble records `inline`, so the review stays in Step 3.6. If phase dispatch adopts a ticket a router marked `router`, `next_step` sends STEP_2 to STEP_2_2 and the supervisor leaves the ticket there with `META|phase-dispatch-skip|warn|STEP_2_2 …` for `/ticket-auto` to continue; it never passes an unreviewed plan to the gate.

## Not covered

- The appraise claim verifier (`ticket-appraise` Step 3.5c) and the implement code review still run inline.
- With the flag on, the appraisal comment is posted before the review, so it carries no adversarial summary on a first-pass PASS or WARNINGS. The findings are in `notes.md` and `plan-review.md`.
