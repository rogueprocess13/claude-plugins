# Pre-fix proof (bug tickets)

Loaded by ticket-implement Step 4b when `pre-fix-fails.sh wanted` printed `true`: a bug ticket with `PRE_FIX_FAILS` not `off`. It checks that the regression test you wrote fails on the code before your fix. Bash decides the verdict; you only name the tests. It records evidence and never blocks.

Run it once the code review is clean, before Step 5, for each repo with a diff.

1. **Name the regression test(s)**: the test(s) you wrote or changed that reproduce this bug and fail on the old code. Name one test method each, never a whole class:
   - Java, Kotlin, C#: `FooServiceTest.rejectsExpiredToken` or `FooServiceTest#rejectsExpiredToken`
   - pytest: `tests/test_tokens.py::test_rejects_expired` (or `::TestTokens::test_rejects_expired`)
   - other runners: the test's name as it appears in the JUnit report
2. **Run the check** (it can take as long as two test runs; never in the background):
   ```bash
   bash ~/.claude/skills/lib/pre-fix-fails.sh check {TICKET-ID} --worktree "$WORKTREE_PATH" \
     --base-ref "${BASE_REF:-origin/$BASE_BRANCH}" --claude-md "$IMPLEMENT_TICKETS_ROOT/CLAUDE.md" \
     --test "<name>" [--test "<name>" ...]
   ```
   It prints one `PRE_FIX_TEST` line per name, then `PRE_FIX_VERDICT=` and `PRE_FIX_REASON=`, and writes the `META|pre-fix-fails` log line itself. Never write that line yourself.
3. **Read the verdict.**
   - `proved` or `proved-weak`: done.
   - `unproven passes-before-fix`: your test passes on the old code, so it does not catch the bug. Strengthen the test once (assert the behaviour the bug broke), re-run the unit tests, then re-run this check. Never weaken a test, and never change production code for this check.
   - `unproven ambiguous-name` or `not-run-before-fix`: the name did not pick out one test. Fix the name and re-run once.
   - any other verdict (`no-report`, `did-not-build` causes, `timeout`, `no-test-files`, `skipped …`): go on. It is evidence about the project's test setup, not something to fix here.
4. Append the final `PRE_FIX_VERDICT`/`PRE_FIX_REASON` and the test names to notes.md under `## Session Log`, then continue with Step 5.

The pre-fix tree is the merge base plus only your test files. A test that needs a new helper outside a test directory, or a new production symbol, errors or does not build there; that is `proved-weak`, which is expected. An editable Python install that points at another checkout makes the pre-fix run test that checkout's code.
