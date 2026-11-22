# docs-conduit-description

## Title

Replace the calculator description in CLAUDE.md and README.md with Conduit-lite

## Description

## Summary

Reword the repo's `CLAUDE.md` and `README.md` so they describe the Conduit-lite blogging app instead of a calculator, and note in the README that the development token secret is only a fallback.

## Enables

**Enables:** none of the stated outcomes. This is repository housekeeping: the brief says this slice replaces the calculator placeholder that the repo's `CLAUDE.md` names, and agents and people read these two files before working in the repo.

## Background / Motivation

`app/CLAUDE.md` says the repo is "A minimal calculator application" and its projects table calls it "Calculator app". `README.md` calls it a "Dummy calculator app". After this slice the repo holds a Conduit-style blogging app, so both files would mislead the next reader. The README is also the place the architecture chose to say that the built-in token secret is for development only.

## Proposed Changes

- In `CLAUDE.md`, replace the calculator wording in the Purpose paragraph with a Conduit-lite description: a RealWorld Conduit-style blogging app (sign-up, sign-in, articles) used as the end-to-end test harness for the user `ticket-auto-pipeline`.
- In `CLAUDE.md`, change the projects table's Purpose cell for `app/` to "Conduit-lite blogging app — Express backend + Vite FE".
- In `README.md`, replace the calculator description with a one-line Conduit-lite description.
- In `README.md`, add a short note that the API signs tokens with the `JWT_SECRET` environment variable and falls back to `conduit-dev-secret` only when it is unset, so the fallback is for development only.
- Leave every other line of `CLAUDE.md` unchanged, in particular the Stack, Build & Test and path lines.

## Technical Context

- `app/CLAUDE.md:7` holds the Purpose paragraph and `app/CLAUDE.md:15` the projects table row. `app/README.md:2` holds the description line.
- `CLAUDE.md` is marked skip-worktree in the operator's `app` clone (`git ls-files -v CLAUDE.md` shows `S`), and that working copy has environment-local path edits on lines 11, 17 and 48 that differ from the committed file. This ticket never runs `git update-index` on `CLAUDE.md` and never edits the operator clone's working copy of it. It makes its edit in a separate git worktree created from the ticket's base branch (`git worktree add`). There `CLAUDE.md` is the committed file, with no local edits and no skip-worktree flag, so the agent changes lines 7 and 15, stages the whole file and commits normally.
- The README note describes the token signing that `api-user-auth` adds; the dev secret wording uses `auth.jwt.dev_secret` (`conduit-dev-secret`). This ticket also runs after `frontend-editor`, the last code ticket, so it describes the finished slice and is not active while other tickets of this initiative run.

## Acceptance Criteria

- [ ] After the change, the Purpose section of `CLAUDE.md` does not contain the word "calculator"
- [ ] After the change, the Purpose section of `CLAUDE.md` contains the text "Conduit-lite"
- [ ] The projects table row for `app/` in `CLAUDE.md` reads "Conduit-lite blogging app — Express backend + Vite FE"
- [ ] After the change, `README.md` does not contain the word "calculator"
- [ ] After the change, `README.md` contains the text "Conduit-lite"
- [ ] `README.md` contains the text `conduit-dev-secret` in a sentence that names `JWT_SECRET`
- [ ] The committed diff of `CLAUDE.md` changes only lines 7 and 15
- [ ] The committed `CLAUDE.md` still contains the line "- **Backend (BE):** Node.js / Express — serves REST API on port 3000"
- [ ] The committed `CLAUDE.md` still names `REPOS_ROOT` as `~/repos`
- [ ] After this ticket's commit, `git ls-files -v CLAUDE.md` in the operator's `app` clone still starts with `S`

## Test User

No sign-in is needed. Every check reads the two files or the commit diff.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Docs | app | `CLAUDE.md` Purpose paragraph and projects row, `README.md` description and secret note |

## Labels

planned, INIT-0000000000-9899, chore, blocked-by:api-user-auth, blocked-by:frontend-editor

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 3,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Reword only the calculator lines of CLAUDE.md and README.md and add a dev-secret note to README.md, leaving the environment path lines untouched.",
  "AffectedServices": "app",
  "TargetSymbols": "Purpose:app/CLAUDE.md:7;Calculator:app/CLAUDE.md:15;calculator:app/README.md:2",
  "Kind": "enabler",
  "Serves": [],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| After the change, the Purpose section of `CLAUDE.md` does not contain the word "calculator" | developer | none | — | `app/CLAUDE.md` | no match for "calculator" in the Purpose section | yes |
| After the change, the Purpose section of `CLAUDE.md` contains the text "Conduit-lite" | developer | none | — | `app/CLAUDE.md` | "Conduit-lite" present in the Purpose section | yes |
| The projects table row for `app/` in `CLAUDE.md` reads "Conduit-lite blogging app — Express backend + Vite FE" | developer | none | — | `app/CLAUDE.md` | Purpose cell "Conduit-lite blogging app — Express backend + Vite FE" | yes |
| After the change, `README.md` does not contain the word "calculator" | developer | none | — | `app/README.md` | no match for "calculator" | yes |
| After the change, `README.md` contains the text "Conduit-lite" | developer | none | — | `app/README.md` | "Conduit-lite" present | yes |
| `README.md` contains the text `conduit-dev-secret` in a sentence that names `JWT_SECRET` | developer | none | — | `app/README.md` | one sentence holding both `conduit-dev-secret` and `JWT_SECRET` | yes |
| The committed diff of `CLAUDE.md` changes only lines 7 and 15 | developer | none | — | `git show --stat` and `git show -- CLAUDE.md` on the commit | hunks touch lines 7 and 15 only | yes |
| The committed `CLAUDE.md` still contains the line "- **Backend (BE):** Node.js / Express — serves REST API on port 3000" | developer | none | — | `git show HEAD:CLAUDE.md` | line present unchanged | yes |
| The committed `CLAUDE.md` still names `REPOS_ROOT` as `~/repos` | developer | none | — | `git show HEAD:CLAUDE.md` | `~/repos` present on the `REPOS_ROOT` lines | yes |
| After this ticket's commit, `git ls-files -v CLAUDE.md` in the operator's `app` clone still starts with `S` | developer | none | — | terminal in the operator's `app` clone | output starts with `S CLAUDE.md` | yes |

## Writes

None.

## Reads

None.

## Preconditions

None.
