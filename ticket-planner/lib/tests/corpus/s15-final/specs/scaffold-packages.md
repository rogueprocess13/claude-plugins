# scaffold-packages

## Title

Scaffold the backend and frontend packages for Conduit-lite

## Description

## Summary

Create the two npm packages the blogging app is built in: `backend/` (an Express API with a test runner behind `npm test`) and `frontend/` (a Vite + vanilla JS page shell). Add a `.gitignore`, and reword the repository documents that still describe a calculator app.

## Enables

**Enables:** O1, O2 — authors can publish and anonymous readers can read. Every later ticket adds code to these two packages.

The repository holds only `README.md` and `CLAUDE.md`. No endpoint or page can be built or tested until both packages, the test runner and the dev-server wiring exist.

## Background / Motivation

`app` has no `backend/`, no `frontend/`, no `package.json` and no test runner. The repository `CLAUDE.md` already fixes the layout and the commands: backend code in `backend/`, frontend code in `frontend/`, the API on port 3000, the frontend dev server on port 5173, `npm test` run from `backend/`, `npm run dev` and `npm run build` run from `frontend/`. It names no command that starts the API.

`CLAUDE.md` and `README.md` describe the repository as a calculator app. That placeholder is replaced by the blogging app.

## Proposed Changes

Backend package:

- `npm test` in `backend/` runs the test suite with Node's built-in test runner. The suite holds one smoke test. It builds the app in-process, requests the unknown path `GET /api/ping` and expects status 404. The test opens no network port.
- `npm start` in `backend/` starts the API on port 3000. At this stage the API has no routes, so every `/api` path returns 404.
- If port 3000 is already in use, `npm start` prints `Port 3000 is already in use` and exits with a non-zero code.

Frontend package:

- `npm run dev` in `frontend/` starts the Vite dev server on port 5173 and serves a page shell whose document title is `Conduit`.
- The dev server serves the same shell for any page path, for example `/login`, so a page address loads when opened directly.
- The dev server forwards every path that starts with `/api` to the API on port 3000. A request to `/api/ping` through port 5173 therefore returns the API's 404 and not the page shell, which the dev server would serve with status 200.
- If port 5173 is already in use, `npm run dev` exits with an error. It does not move to another port.
- `npm run build` in `frontend/` completes with exit code 0.

Repository:

- A root `.gitignore` ignores `node_modules/` and `dist/`.
- Both `package-lock.json` files are committed.
- `CLAUDE.md` line 7 (the Purpose paragraph), `CLAUDE.md` line 15 (the Codebase Projects row) and `README.md` line 2 describe the Conduit-lite blogging app. The word "calculator" no longer appears in either file.
- The Build & Test table in `CLAUDE.md` gains one row: `BE dev server`, with the command `npm start` (run from `backend/`).
- Every other line of `CLAUDE.md` stays as it is. The pipeline reads the Stack lines, the Linear team and project, `LOCAL_URL`, `UAT_URL`, the three existing Build & Test rows, `BE_TEST_CMD`, `REPOS_ROOT` and the folder convention from this file.

## Technical Context

All paths are under `app/`. Nothing but `CLAUDE.md` and `README.md` exists today.

Backend (`backend/`, ES modules, `"type": "module"`):

- `package.json` with scripts `start` (`node src/server.js`) and `test` (`node --test`). Dependencies: `express`, `bcryptjs`, `jsonwebtoken`. Dev dependency: `supertest`. `bcryptjs` and `jsonwebtoken` are installed here so later tickets do not touch the lock file for them.
- `src/app.js` exports `createApp({ store } = {})`. It returns an Express app with the JSON body parser and an empty router mounted under `/api`, and it never calls `listen`. The `store` option is accepted and unused until the store ticket.
- `src/server.js` is the only file that opens a port. It calls `createApp()` and listens on the value of `api_port` (3000). On an `EADDRINUSE` error it prints the message above and exits with code 1.
- `test/smoke.test.js` uses `node:test` and `supertest` against `createApp()`.

Frontend (`frontend/`, ES modules):

- `package.json` with scripts `dev` (`vite`) and `build` (`vite build`). Dev dependency: `vite`.
- `vite.config.js` sets the dev-server port to the value of `frontend_port` (5173), turns `strictPort` on, and proxies the single key `/api` to `http://localhost:3000`. No other proxy key is added. Page paths never start with `/api`.
- `index.html` holds the document title `Conduit`, an empty header container, an empty page container and a module script tag for `src/main.js`. `src/main.js` and `src/style.css` are minimal at this stage.
- No CORS middleware is added to the backend. The browser reaches the API only through the dev-server proxy.

Repository documents:

- `app/CLAUDE.md:7`, `app/CLAUDE.md:15` and `app/README.md:2` are the three lines that say "calculator".
- Lines that must keep their value and shape: `app/CLAUDE.md:21`, `app/CLAUDE.md:22`, `app/CLAUDE.md:26`, `app/CLAUDE.md:27`, `app/CLAUDE.md:34`, `app/CLAUDE.md:36`, `app/CLAUDE.md:42`, `app/CLAUDE.md:43`, `app/CLAUDE.md:44`, `app/CLAUDE.md:46`, `app/CLAUDE.md:48` and `app/CLAUDE.md:53`. The "FE type check" label on line 44 is left as it is.
- No root `package.json` is added. Every command runs from `backend/` or `frontend/`.

## Acceptance Criteria

- [ ] Running `npm test` in `backend/` after `npm install` exits with code 0.
- [ ] The `npm test` summary in `backend/` lists the smoke test as passed.
- [ ] The `npm test` summary in `backend/` counts no failed test.
- [ ] While another process is listening on the API port, `npm test` in `backend/` exits with code 0.
- [ ] After `npm start` in `backend/`, `GET http://localhost:3000/api/ping` returns status 404.
- [ ] When the API port is already in use, `npm start` in `backend/` prints `Port 3000 is already in use`.
- [ ] When the API port is already in use, `npm start` in `backend/` exits with a non-zero code.
- [ ] After `npm run dev` in `frontend/`, `GET http://localhost:5173/` returns status 200 with an HTML document whose title is `Conduit`.
- [ ] With the dev server running, `GET http://localhost:5173/login` returns status 200 with an HTML document whose title is `Conduit`.
- [ ] With both servers running, `GET http://localhost:5173/api/ping` returns status 404.
- [ ] When the frontend port is already in use, `npm run dev` in `frontend/` exits with an error that names port 5173.
- [ ] Running `npm run build` in `frontend/` after `npm install` exits with code 0.
- [ ] After `npm install` in both packages and `npm run build` in `frontend/`, `git status --porcelain` lists no path under `node_modules/`.
- [ ] After `npm run build` in `frontend/`, `git status --porcelain` lists no path under `dist/`.
- [ ] `git ls-files` lists `backend/package-lock.json`.
- [ ] `git ls-files` lists `frontend/package-lock.json`.
- [ ] A case-insensitive search for `calculator` in `CLAUDE.md` finds no match.
- [ ] A case-insensitive search for `calculator` in `README.md` finds no match.
- [ ] The Build & Test table in `CLAUDE.md` holds a row `BE dev server` with the command `npm start` (run from `backend/`).
- [ ] The diff of `CLAUDE.md` against the base branch changes only the Purpose paragraph, the Codebase Projects row and the added `BE dev server` row.

## Out of Scope

The in-memory store, the seed data, every API endpoint, the client-side router, the header and all pages. A root `package.json`, CORS, a database, a frontend test runner and CI configuration are not added.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/` package: app factory, server entry point, smoke test |
| FE | app | `frontend/` package: Vite config, page shell |
| Infra | app | `.gitignore`, `CLAUDE.md`, `README.md` |

## Test User

Anonymous reader. No account exists at this stage and none is needed.

## Labels

planned, INIT-0000000000-5702, chore

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 10,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Two independent npm packages in app: backend/ (Express createApp factory over a per-instance seeded in-memory store, node:test + supertest behind npm test) and frontend/ (Vite + vanilla JS with a History-API router and a dev-server proxy for /api), with no root package, no database and no CORS.",
  "AffectedServices": "app",
  "TargetSymbols": "calculator:app/CLAUDE.md:7;Calculator:app/CLAUDE.md:15;calculator:app/README.md:2;Express:app/CLAUDE.md:21;Vite:app/CLAUDE.md:22;LOCAL_URL:app/CLAUDE.md:34;UAT_URL:app/CLAUDE.md:36;BE_TEST_CMD:app/CLAUDE.md:46;REPOS_ROOT:app/CLAUDE.md:48;backend:app/CLAUDE.md:53;createApp (new):app/backend/src/app.js;server (new):app/backend/src/server.js;smokeTest (new):app/backend/test/smoke.test.js;viteConfig (new):app/frontend/vite.config.js;indexHtml (new):app/frontend/index.html;gitignore (new):app/.gitignore",
  "Kind": "enabler",
  "Serves": [],
  "Enables": [
    "O1",
    "O2"
  ]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|---|
| Running `npm test` in `backend/` after `npm install` exits with code 0. | Developer | none | — |  | exit code 0 | yes |
| The `npm test` summary in `backend/` lists the smoke test as passed. | Developer | none | — |  | the smoke test line is marked passed | yes |
| The `npm test` summary in `backend/` counts no failed test. | Developer | none | — |  | the fail count in the summary is zero | yes |
| While another process is listening on the API port, `npm test` in `backend/` exits with code 0. | Developer | none | — |  | exit code 0 with port 3000 occupied | yes |
| After `npm start` in `backend/`, `GET http://localhost:3000/api/ping` returns status 404. | Developer | none | — |  | status 404 | yes |
| When the API port is already in use, `npm start` in `backend/` prints `Port 3000 is already in use`. | Developer | none | — |  | the output holds the line Port 3000 is already in use | yes |
| When the API port is already in use, `npm start` in `backend/` exits with a non-zero code. | Developer | none | — |  | exit code 1 | yes |
| After `npm run dev` in `frontend/`, `GET http://localhost:5173/` returns status 200 with an HTML document whose title is `Conduit`. | Anonymous reader | none | — | Open the site | status 200, document title Conduit | yes |
| With the dev server running, `GET http://localhost:5173/login` returns status 200 with an HTML document whose title is `Conduit`. | Anonymous reader | none | — | Open the site > add `/login` to the site address | status 200, document title Conduit | yes |
| With both servers running, `GET http://localhost:5173/api/ping` returns status 404. | Anonymous reader | none | — |  | status 404; the page shell would be status 200 with the title Conduit | yes |
| When the frontend port is already in use, `npm run dev` in `frontend/` exits with an error that names port 5173. | Developer | none | — |  | the process exits, the error text holds 5173, nothing listens on port 5174 | yes |
| Running `npm run build` in `frontend/` after `npm install` exits with code 0. | Developer | none | — |  | exit code 0 | yes |
| After `npm install` in both packages and `npm run build` in `frontend/`, `git status --porcelain` lists no path under `node_modules/`. | Developer | none | — |  | no output line holds node_modules/ | yes |
| After `npm run build` in `frontend/`, `git status --porcelain` lists no path under `dist/`. | Developer | none | — |  | no output line holds dist/ | yes |
| `git ls-files` lists `backend/package-lock.json`. | Developer | none | — |  | the path is listed | yes |
| `git ls-files` lists `frontend/package-lock.json`. | Developer | none | — |  | the path is listed | yes |
| A case-insensitive search for `calculator` in `CLAUDE.md` finds no match. | Developer | none | — |  | 0 matches | yes |
| A case-insensitive search for `calculator` in `README.md` finds no match. | Developer | none | — |  | 0 matches | yes |
| The Build & Test table in `CLAUDE.md` holds a row `BE dev server` with the command `npm start` (run from `backend/`). | Developer | none | — |  | the row is present | yes |
| The diff of `CLAUDE.md` against the base branch changes only the Purpose paragraph, the Codebase Projects row and the added `BE dev server` row. | Developer | none | — |  | the diff holds exactly those three hunks; the Stack, Linear, LOCAL_URL, UAT_URL, BE_TEST_CMD, REPOS_ROOT and Conventions lines are unchanged | yes |

## Writes

None.

## Reads

None.

## Preconditions

None.
