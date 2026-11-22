# conduit-repo-docs

## Title

Describe Conduit-lite in the app README and CLAUDE.md

## Description

## Summary

Rewrite the calculator wording in the `app` `CLAUDE.md` and `README.md` so both describe Conduit-lite, note the `/api` dev proxy in the Stack section, and keep the Build & Test table true.

## Enables

**Enables:** O1, O2, O3 — the pipeline and every agent that builds or verifies the account, publishing and reading features read `CLAUDE.md` for the project's purpose and its build and test commands.

Once the backend and frontend exist, a CLAUDE.md that still describes a calculator app sends readers and agents the wrong way. This is a documentation chore; it delivers no outcome on its own.

## Background / Motivation

The brief says this slice replaces the calculator placeholder named in the repo's CLAUDE.md. Today `CLAUDE.md` calls the project a calculator app (Purpose paragraph and Codebase Projects table) and `README.md` describes a "Dummy calculator app".

## Proposed Changes

- `CLAUDE.md` Purpose paragraph: describe Conduit-lite — a first slice of a RealWorld Conduit-style blogging app where authors register, sign in and publish, and anyone reads.
- `CLAUDE.md` Codebase Projects row: purpose cell names Conduit-lite (Express backend + Vite frontend).
- `CLAUDE.md` Stack section: keep Express on 3000 and Vite + vanilla JS on 5173; add that the Vite dev server proxies `/api` to `http://localhost:3000`.
- `CLAUDE.md` Build & Test table: no change in meaning; it must still list `npm test` from `backend/`, `npm run dev` from `frontend/`, and `npm run build`.
- `README.md` second line: describe Conduit-lite instead of the calculator.
- After the change, neither file mentions a calculator.

## Technical Context

- Builds on `backend-scaffold` (`backend/package.json` with `start` and `test`) and `frontend-shell` (`frontend/package.json` with `dev` and `build`, `frontend/vite.config.js` with the `/api` proxy), so the docs describe files that exist.
- Lines to change at the pinned commit: `app/CLAUDE.md` line 7 (Purpose), line 15 (Codebase Projects row), lines 19-22 (Stack), lines 38-46 (Build & Test, keep), lines 53-54 (Conventions, keep); `app/README.md` line 2.
- Parameters: `api.port` = 3000; `frontend.port` = 5173.

## Acceptance Criteria

- [ ] Running `grep -i calculator CLAUDE.md README.md` in the repo root prints nothing
- [ ] The `CLAUDE.md` Purpose paragraph contains the text `Conduit-lite`
- [ ] The `CLAUDE.md` Codebase Projects table row for `app` contains the text `Conduit-lite`
- [ ] The `CLAUDE.md` Stack section names the Vite `/api` proxy to port 3000
- [ ] The second line of `README.md` contains the text `Conduit-lite`
- [ ] The `CLAUDE.md` Build & Test table lists `npm test` run from `backend/`
- [ ] The `CLAUDE.md` Build & Test table lists `npm run dev` run from `frontend/`
- [ ] The `CLAUDE.md` Build & Test table lists `npm run build`

## Out of Scope

Any code change, and any other documentation file.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| Docs | app docs | `CLAUDE.md`, `README.md` |

## Test User

None — documentation only; no user or credentials are needed.

## Environment

- [x] Local (repository checkout)

## Labels

planned, INIT-0000000000-2767, chore, blocked-by:backend-scaffold, blocked-by:frontend-shell

## Signals

```json
{
  "services_identified": 3,
  "symbols_resolved": 6,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "CommonJS Express 5 API built by a createApp() factory with a seeded in-memory store, tested with node:test plus supertest; Vite vanilla JS SPA reaching it through a /api dev proxy.",
  "AffectedServices": "app docs",
  "TargetSymbols": "calculator (Purpose paragraph):app/CLAUDE.md:7;Calculator (Codebase Projects row):app/CLAUDE.md:15;Stack:app/CLAUDE.md:19-22;Build (Build and Test table):app/CLAUDE.md:38-46;calculator (README description):app/README.md:2;Backend (Conventions):app/CLAUDE.md:53-54",
  "Kind": "enabler",
  "Serves": [],
  "Enables": ["O1", "O2", "O3"]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `grep -i calculator CLAUDE.md README.md` in the repo root prints nothing | developer | none | — | terminal in the `app` repo root | empty output, exit code 1 | yes |
| The `CLAUDE.md` Purpose paragraph contains the text `Conduit-lite` | developer | none | — | open `CLAUDE.md` | `Conduit-lite` present in the Purpose paragraph | yes |
| The `CLAUDE.md` Codebase Projects table row for `app` contains the text `Conduit-lite` | developer | none | — | open `CLAUDE.md` | `Conduit-lite` present in that row | yes |
| The `CLAUDE.md` Stack section names the Vite `/api` proxy to port 3000 | developer | none | — | open `CLAUDE.md` | Stack section contains `/api` with `http://localhost:3000` | yes |
| The second line of `README.md` contains the text `Conduit-lite` | developer | none | — | terminal in the `app` repo root | `sed -n 2p README.md` output contains `Conduit-lite` | yes |
| The `CLAUDE.md` Build & Test table lists `npm test` run from `backend/` | developer | none | — | open `CLAUDE.md` | row with `npm test` and `backend/` present | yes |
| The `CLAUDE.md` Build & Test table lists `npm run dev` run from `frontend/` | developer | none | — | open `CLAUDE.md` | row with `npm run dev` and `frontend/` present | yes |
| The `CLAUDE.md` Build & Test table lists `npm run build` | developer | none | — | open `CLAUDE.md` | row with `npm run build` present | yes |

## Writes

None.

## Reads

None.

## Preconditions

None.
