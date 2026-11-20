# Simple Fix (reduced copy: a ticket that only adds one markdown file)

## Summary
Add a new file `SMOKE.md` at the root of the `sample-app` repository containing the single line `Smoke test`.

## How to implement
1. Create `SMOKE.md` at the repository root. Equivalent command: `printf 'Smoke test\n' > SMOKE.md`
2. Commit only `SMOKE.md`, push the ticket branch to `origin`, and open the PR against `develop`.

## Verification
This ticket has no UI, no API, no user account and no test data. It needs no browser and no login. All three acceptance criteria are checked from git:
- Role / user: none required.
- Navigation path: not applicable. The target is the file `SMOKE.md` at the root of `sample-app`.
- Expected behavior:
  - `git ls-tree --name-only origin/develop` lists `SMOKE.md` after merge.
  - `git show <ref>:SMOKE.md` prints exactly `Smoke test`.
  - `git diff --name-status origin/develop...HEAD` shows the single entry `A SMOKE.md`.

## Completion Checklist
- [x] AC-1: The file `SMOKE.md` exists at the repository root on `develop`.
- [x] AC-2: `SMOKE.md` contains exactly one line: `Smoke test`.
- [x] AC-3: No other file is changed.

## Constraints and gotchas
- The repository has no lint, build, test or CI step, so there is no test command to run. Verification is the git checks above.

## Technical Context

Repository `sample-app`, base branch `develop`. One new file, `SMOKE.md`. No code, no tests, no UI, no dependencies.
