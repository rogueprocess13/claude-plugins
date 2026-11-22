# repo-docs

## Title

Describe app as the Conduit-lite app in CLAUDE.md and README

## Description

## Summary

Replace the calculator wording in the repo's `CLAUDE.md` and `README.md` with a description of the Conduit-lite blogging app, drop the two statements that the repo is empty, and add one Build & Test row that tells agents how to start the backend. Every pipeline setting in `CLAUDE.md` stays exactly as it is.

## Enables

**Enables:** none — this keeps the repo's own description accurate and documents how to start the backend. It delivers no stated outcome by itself.

The pipeline reads `CLAUDE.md` before every ticket. While it says "calculator", or says the repo is empty, agents get the wrong picture of the app. `CLAUDE.md` names no command that starts the backend. The added row is documentation for agents only: the verify step starts the app stack through `scripts/env-start.sh` (`backend-scaffold`), not through this table.

## Background / Motivation

The brief says this slice replaces the calculator placeholder named in the repo's `CLAUDE.md`. Today the Purpose paragraph, the Codebase Projects row and the README all describe a calculator.

## Proposed Changes

- `CLAUDE.md` Purpose paragraph: describe the app as a Conduit-lite blogging app (RealWorld Conduit first slice: sign-up, sign-in and articles) that is still used as the end-to-end test harness for the user `ticket-auto-pipeline`. Keep the second sentence's statement that tickets in the `user Sandbox` Linear project drive development, and drop its clause that the codebase is intentionally empty at the start.
- `CLAUDE.md` Conventions, line 54: replace "This repo is empty at the start — the pipeline creates the initial structure." with "The pipeline builds the app ticket by ticket in `backend/` and `frontend/`."
- `CLAUDE.md` Codebase Projects row for `app/`: change the purpose cell to "Conduit-lite blogging app — Express backend + Vite FE".
- `CLAUDE.md` Build & Test table: add one row, "BE server", with command `npm start` (run from `backend/`), directly after the `FE type check` row.
- `README.md` line 2: describe the repo as a Conduit-lite blogging app used to test the ticket-auto-pipeline end to end, still not a real project.
- No other line changes.

## Technical Context

- Repository `app` (pinned `200f5a4`).
- Lines that change: `app/CLAUDE.md:7` (Purpose), `app/CLAUDE.md:15` (Codebase Projects row), `app/CLAUDE.md:54` (Conventions line about an empty repo), `app/README.md:2`. One row is added directly after `app/CLAUDE.md:44`.
- Lines that must stay byte-identical, because the pipeline reads them: `app/CLAUDE.md:21-22` (Stack), `app/CLAUDE.md:34` and `app/CLAUDE.md:36` (Environment URLs), `app/CLAUDE.md:42-44` (existing Build & Test rows), `app/CLAUDE.md:46` (`BE_TEST_CMD`), `app/CLAUDE.md:48` (`REPOS_ROOT`), `app/CLAUDE.md:53` (Conventions).
- So against `200f5a4` the `CLAUDE.md` diff has exactly 3 removed lines (7, 15, 54) and exactly 4 added lines (the new Purpose line, the new Codebase Projects row, the new Conventions line and the `BE server` row).
- The `npm start` script in `backend/package.json` comes from `backend-scaffold`.

## Acceptance Criteria

- [ ] `grep -ci calculator CLAUDE.md` in `app` prints `0`.
- [ ] `grep -ci calculator README.md` in `app` prints `0`.
- [ ] The `CLAUDE.md` Purpose paragraph contains the word "Conduit".
- [ ] The `CLAUDE.md` Codebase Projects row for `app/` contains the word "Conduit".
- [ ] Line 2 of `README.md` contains the word "Conduit".
- [ ] The `CLAUDE.md` Build & Test table has a row whose command is `npm start` (run from `backend/`).
- [ ] `git diff 200f5a4 -- CLAUDE.md` in `app` shows no removed line other than the Purpose paragraph line, the `app/` Codebase Projects row and the Conventions line that says the repo is empty at the start.
- [ ] `git diff --numstat 200f5a4 -- CLAUDE.md` in `app` reports exactly 3 removed lines.
- [ ] `git diff --numstat 200f5a4 -- CLAUDE.md` in `app` reports exactly 4 added lines.
- [ ] In `CLAUDE.md`, the line directly after the `FE type check` row is the row whose command is `npm start` (run from `backend/`).
- [ ] `grep -c "empty at the start" CLAUDE.md` in `app` prints `0`.
- [ ] The `CLAUDE.md` Purpose paragraph contains the text `user Sandbox`.

## Out of Scope

- Any change to Stack, Environment URLs, existing Build & Test rows, `BE_TEST_CMD`, `REPOS_ROOT`, Linear Integration, or Conventions other than line 54.
- A root script or process manager that starts both servers.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| Docs | app | `CLAUDE.md`, `README.md` |

## Test User

No login: documentation change only. Role: developer reading the repo; no password.

## Environment

- [x] Local (repository files only)

## Labels

planned, INIT-0000000000-5252, chore, blocked-by:backend-scaffold

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 3,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Reword only the calculator description lines and the empty-repo Conventions line in app CLAUDE.md, reword README.md line 2, and add one Build & Test row for npm start in backend/, leaving every pipeline setting byte-identical.",
  "AffectedServices": "app",
  "TargetSymbols": "calculator:app/CLAUDE.md:7;Calculator:app/CLAUDE.md:15;empty:app/CLAUDE.md:54;calculator:app/README.md:2",
  "Kind": "enabler",
  "Serves": [],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `grep -ci calculator CLAUDE.md` in `app` prints `0`. | developer | none | — | | `0` | yes |
| `grep -ci calculator README.md` in `app` prints `0`. | developer | none | — | | `0` | yes |
| The `CLAUDE.md` Purpose paragraph contains the word "Conduit". | developer | none | — | | Purpose paragraph includes "Conduit" | yes |
| The `CLAUDE.md` Codebase Projects row for `app/` contains the word "Conduit". | developer | none | — | | row includes "Conduit" | yes |
| Line 2 of `README.md` contains the word "Conduit". | developer | none | — | | line 2 includes "Conduit" | yes |
| The `CLAUDE.md` Build & Test table has a row whose command is `npm start` (run from `backend/`). | developer | none | — | | a table row with `npm start` and `backend/` | yes |
| `git diff 200f5a4 -- CLAUDE.md` in `app` shows no removed line other than the Purpose paragraph line, the `app/` Codebase Projects row and the Conventions line that says the repo is empty at the start. | developer | none | — | | every removed line is original line 7, 15 or 54 | yes |
| `git diff --numstat 200f5a4 -- CLAUDE.md` in `app` reports exactly 3 removed lines. | developer | none | — | | numstat deleted column `3` | yes |
| `git diff --numstat 200f5a4 -- CLAUDE.md` in `app` reports exactly 4 added lines. | developer | none | — | | numstat added column `4` | yes |
| In `CLAUDE.md`, the line directly after the `FE type check` row is the row whose command is `npm start` (run from `backend/`). | developer | none | — | | next line after `FE type check` contains `npm start` and `backend/` | yes |
| `grep -c "empty at the start" CLAUDE.md` in `app` prints `0`. | developer | none | — | | `0` | yes |
| The `CLAUDE.md` Purpose paragraph contains the text `user Sandbox`. | developer | none | — | | Purpose paragraph includes `user Sandbox` | yes |

## Writes

None.

## Reads

None.

## Preconditions

None.
