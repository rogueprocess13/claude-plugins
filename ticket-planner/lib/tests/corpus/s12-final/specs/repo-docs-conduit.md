# repo-docs-conduit

## Title

Replace the calculator description in the repository docs with Conduit-lite

## Description

## Summary

Change the repository's `CLAUDE.md` and `README.md` so they describe the Conduit-lite blogging app instead of a calculator. Every pipeline configuration line in `CLAUDE.md` keeps its exact value.

## Enables

**Enables:** none of the stated outcomes directly. The repository description must match the code it holds: the brief says this slice replaces the calculator placeholder named in `CLAUDE.md`, and every agent that works in the repository reads `CLAUDE.md` first.

The text change is required so that people and agents reading the repository are not told it is a calculator app.

## Background / Motivation

`app/CLAUDE.md:7` calls the repository "A minimal calculator application", `app/CLAUDE.md:15` lists it as "Calculator app — Express backend + Vite FE", and `app/README.md:2` calls it a "Dummy calculator app". No calculator code exists on `origin/develop`, so replacing the placeholder is a text change only. The same `CLAUDE.md` holds configuration the pipeline reads (`LOCAL_URL`, `UAT_URL`, the Build & Test table, `BE_TEST_CMD`, `REPOS_ROOT`), which must not change.

## Proposed Changes

- In `CLAUDE.md`, the Purpose paragraph describes "A minimal Conduit-lite blogging app (modelled on the RealWorld Conduit spec)" used as the end-to-end test harness; the rest of the paragraph stays.
- In `CLAUDE.md`, the Codebase Projects row's Purpose cell reads "Conduit-lite blogging app — Express backend + Vite FE".
- In `README.md`, line 2 reads "Conduit-lite blogging app for testing the ticket-auto-pipeline end-to-end. Not a real project — test harness only."
- Nothing else in either file changes.

## Technical Context

- Repository `app`, base `origin/develop` (commit `200f5a4`).
- Lines that change: `app/CLAUDE.md:7` (Purpose), `app/CLAUDE.md:15` (Codebase Projects row), `app/README.md:2`.
- Lines that must keep their exact text: Stack `app/CLAUDE.md:21` and `app/CLAUDE.md:22`; `LOCAL_URL` `app/CLAUDE.md:34`; `UAT_URL` `app/CLAUDE.md:36`; Build & Test rows `app/CLAUDE.md:42`, `app/CLAUDE.md:43` and `app/CLAUDE.md:44`; `BE_TEST_CMD` `app/CLAUDE.md:46`; `REPOS_ROOT` `app/CLAUDE.md:48`; Conventions `app/CLAUDE.md:53` and `app/CLAUDE.md:54`.
- Parameters: `api.port` (3000) and `ui.port` (5173) stay as the Stack lines state them.
- This ticket touches no code and can land at any point in the slice.

## Acceptance Criteria

- [ ] `grep -ic calculator CLAUDE.md README.md` in the repository root prints a count of 0 for each file
- [ ] The Purpose paragraph of `CLAUDE.md` contains the text "Conduit-lite blogging app"
- [ ] The Codebase Projects row for `app/` in `CLAUDE.md` has the Purpose cell "Conduit-lite blogging app — Express backend + Vite FE"
- [ ] Line 2 of `README.md` reads "Conduit-lite blogging app for testing the ticket-auto-pipeline end-to-end. Not a real project — test harness only."
- [ ] `CLAUDE.md` still contains the line `LOCAL_URL` = `http://localhost:5173`
- [ ] `CLAUDE.md` still contains the line `UAT_URL` = `http://localhost:5173`
- [ ] `CLAUDE.md` still contains the line `BE_TEST_CMD` = `npm test`
- [ ] `CLAUDE.md` still contains the line `REPOS_ROOT` = `~/work/e2e-conduit`
- [ ] `CLAUDE.md` still contains the Build & Test row for "BE unit tests" with the command `npm test` run from `backend/`
- [ ] `CLAUDE.md` still contains the Build & Test row for "FE dev server" with the command `npm run dev` run from `frontend/`
- [ ] `CLAUDE.md` still contains the Build & Test row for "FE type check" with the command `npm run build`
- [ ] `git diff origin/develop -- CLAUDE.md` shows changed lines only in the Purpose paragraph and the Codebase Projects row

## Out of Scope

Any code, any other section of `CLAUDE.md`, and any change to the Linear integration settings.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| Docs | app | `CLAUDE.md` Purpose and Codebase Projects row, `README.md` description |

## Test User

None needed. This ticket changes documentation only; verification reads the files.

## Environment

- [x] Local (repository checkout)

## Labels

planned, INIT-0000000000-5856, chore

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 3,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Edit only the calculator wording in CLAUDE.md and README.md, leaving every pipeline configuration line unchanged.",
  "AffectedServices": "app",
  "TargetSymbols": "Purpose:app/CLAUDE.md:7;Calculator:app/CLAUDE.md:15;calculator:app/README.md:2;LOCAL_URL:app/CLAUDE.md:34;UAT_URL:app/CLAUDE.md:36;BE_TEST_CMD:app/CLAUDE.md:46;REPOS_ROOT:app/CLAUDE.md:48",
  "Kind": "enabler",
  "Serves": [],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `grep -ic calculator CLAUDE.md README.md` in the repository root prints a count of 0 for each file | developer | none | — | terminal in the repository root | `CLAUDE.md:0` and `README.md:0` | yes |
| The Purpose paragraph of `CLAUDE.md` contains the text "Conduit-lite blogging app" | developer | none | — | open `CLAUDE.md` | text "Conduit-lite blogging app" under Purpose | yes |
| The Codebase Projects row for `app/` in `CLAUDE.md` has the Purpose cell "Conduit-lite blogging app — Express backend + Vite FE" | developer | none | — | open `CLAUDE.md` | that exact cell text | yes |
| Line 2 of `README.md` reads "Conduit-lite blogging app for testing the ticket-auto-pipeline end-to-end. Not a real project — test harness only." | developer | none | — | open `README.md` | that exact line | yes |
| `CLAUDE.md` still contains the line `LOCAL_URL` = `http://localhost:5173` | developer | none | — | open `CLAUDE.md` | line present unchanged | yes |
| `CLAUDE.md` still contains the line `UAT_URL` = `http://localhost:5173` | developer | none | — | open `CLAUDE.md` | line present unchanged | yes |
| `CLAUDE.md` still contains the line `BE_TEST_CMD` = `npm test` | developer | none | — | open `CLAUDE.md` | line present unchanged | yes |
| `CLAUDE.md` still contains the line `REPOS_ROOT` = `~/work/e2e-conduit` | developer | none | — | open `CLAUDE.md` | line present unchanged | yes |
| `CLAUDE.md` still contains the Build & Test row for "BE unit tests" with the command `npm test` run from `backend/` | developer | none | — | open `CLAUDE.md` | row present unchanged | yes |
| `CLAUDE.md` still contains the Build & Test row for "FE dev server" with the command `npm run dev` run from `frontend/` | developer | none | — | open `CLAUDE.md` | row present unchanged | yes |
| `CLAUDE.md` still contains the Build & Test row for "FE type check" with the command `npm run build` | developer | none | — | open `CLAUDE.md` | row present unchanged | yes |
| `git diff origin/develop -- CLAUDE.md` shows changed lines only in the Purpose paragraph and the Codebase Projects row | developer | none | — | terminal in the repository root | diff hunks touch only lines 7 and 15 | yes |

## Writes

None.

## Reads

None.

## Preconditions

None.
