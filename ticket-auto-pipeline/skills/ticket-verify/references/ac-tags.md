# ticket-verify — criterion tags (`VERIFY_AC_TAGS=true`)

Read only when Step 1i's condition holds: the flag is on, the environment is `local`, and the ticket has at least one criterion that starts with `[unit]`. Otherwise none of this applies and every criterion is proved live, as SKILL.md says.

A `[unit]` criterion states a fact that only an automated test can prove. You prove it by running the project's test command yourself, through the helper, and seeing a named test pass in that run. A `[live]` criterion, and a criterion with no tag, is proved on the running system exactly as SKILL.md and the mode reference say. Nothing below changes those.

## Guard — what never proves a `[unit]` criterion

- A claim. notes.md, the plan, the PR text, an IMPLEMENT log line, a CI result and an earlier verify attempt are not proof. Only a `UNIT_TEST … pass` line printed by `verify-ac-tags.sh run` in this attempt is.
- A command you chose. The helper learns the test command from the project's configuration and runs it in the verify worktree. Never run the test command yourself in its place, and never change or shorten it.
- A live attempt. If a `[unit]` criterion cannot be proved by a named test, it **fails**. Do not prove it in the browser or with `curl` instead, do not skip it, and do not leave it out of the count.
- A changed tag. The tag comes from the ticket body. Never move a criterion from `[unit]` to `[live]` or back.

This skill still never edits source code or tests.

## Step 2b — keep the tag on each item

List the criteria with their tags:

```bash
bash ~/.claude/skills/lib/verify-ac-tags.sh list "{ticket-dir}"
```

Each line is `number`, `unit` or `live`, and the criterion text. When you expand a criterion into atomic items, every item keeps its parent's tag. Write `[unit]` or `[live]` in front of every item in the expanded list and in the plan's Pass criteria. This applies to the build-only and live-backend plan variants too.

## Step 2c — name the test for each `[unit]` item

For each `[unit]` item, find the one test that proves it, in the code of the ticket's branch:

1. If the criterion names a test, use that name.
2. Otherwise search the branch's test files, for example `git -C "{repo path}" diff --name-only origin/{base}...origin/{branch}` and `git -C "{repo path}" grep -n "<term>" origin/{branch}`, and read the candidates with `git -C "{repo path}" show origin/{branch}:{path}`.
3. Read the test's body. It is this item's test only if it asserts the fact the item states. A test that only has a similar name is not.

Write the name the way the test runner reports it: the method or function name, the class name, or both (`InvoiceServiceTest.rejectsEmptyTotal`, `tests/test_invoice.py::test_rejects_empty_total`). If no test asserts the fact, write `no named test` for that item. Do not pick the nearest test.

In the plan, a `[unit]` item gets this line under Steps (or Build commands, or the live checks) in place of a browser, build or `curl` step:

```
U{n}. unit — {repo}: {test name | no named test}
```

## Step 4b / 4c / 4c-live — one run per repository

Work through the `[live]` items first, as the step says. If every item is `[unit]`, Step 1e printed `VERIFY_MODE=build-only`: Step 4c runs only this helper.

Then, before Step 5 releases the lock, run the helper once for each repository that has named tests, with every name for that repository in one call. Give it a long Bash timeout (the run may take up to 15 minutes):

```bash
bash ~/.claude/skills/lib/verify-ac-tags.sh run {TICKET-ID} --repo-path "{repo path}" --branch "{branch}" --out "{ticket-dir}/artifacts" --test "{test name 1}" --test "{test name 2}"
```

`{repo path}` is the repository under `REPOS_ROOT`, not a worktree: the helper finds or creates the verify worktree itself. `{branch}` is the ticket's branch (as in Step 1.6a3, also in build-only). The run comes last: a test command may rebuild files the running stack serves.

Read the output. `UNIT_RUN` says what ran and where the log is. Each `UNIT_TEST` line carries a name, `pass` or `fail`, and the reason:

- `pass` → every item with that test passes. Write the usual checkpoint line, `bash ~/.claude/skills/lib/plog.sh VERIFY checkpoint done "criterion-{N}-pass"`.
- `fail` → every item with that test is **FAIL**. Record the reason and the log file as what was observed.
- An item with `no named test` is **FAIL** with that as the reason. It needs no run.

Run the helper once per repository in an attempt. Do not run it again to get a pass.

A `[unit]` item has no browser step, no `curl` call, no `verify-{TICKET-ID}-c{N}-*.png` screenshot and, under `--record`, no recording frame. The checkpoint resume rule is unchanged: in build-only and live-backend mode an item at or below `VERIFY_CHECKPOINT` is already passed, and any other `[unit]` item needs a run in this attempt.

## Steps 5 to 7 — count and report

A `[unit]` item is a pass criterion like any other. It counts in `criteria_met` and `criteria_total`, in the heartbeat verdict and in the `{N} criteria` log lines, and one failed `[unit]` item routes Step 5 to Step 7.

In the Step 6 and 7b reports, say how each criterion was proved, so nobody looks for a screenshot that was never taken: `live`, or `unit: {test name} ({repo})`. Under Evidence, list `verify-unit-{repo}.log` for the `[unit]` items.

In the REMEDIATION_BRIEF (7c), a failed `[unit]` item names what the implementer must change:

- `no named test` → "No test asserts criterion {N}: {criterion}. Add one."
- `not in this run's test reports` → the named test did not run under the project's test command.
- `test failed` or `test was skipped` → quote the failing lines from the log.
- `no test command` or `no verify worktree` → say so as the cause. This is a project configuration problem, not a code fault.
