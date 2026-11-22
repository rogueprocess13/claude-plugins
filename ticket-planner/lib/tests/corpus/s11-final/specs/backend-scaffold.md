# backend-scaffold

## Title

Scaffold the Express backend with an in-memory store and Jest test runner

## Description

## Summary

Create the `backend/` project in `app`: an Express app that starts on port 3000, an in-memory store that later tickets fill and tests reset, a Jest test suite behind `npm test`, and the `scripts/env-start.sh` script that the pipeline's verify step uses to start the app stack.

## Enables

**Enables:** O1, O2, O3 — every API endpoint and the browser walkthrough need a running backend and a test runner.

The repo holds only `README.md` and `CLAUDE.md`. The pipeline runs `npm test` from `backend/` on every ticket (`BE_TEST_CMD`), so no endpoint ticket can pass until this project exists.

## Background / Motivation

There is no `backend/`, no `package.json` and no test runner in the repo. The brief asks for an Express API on port 3000 with a test runner behind `npm test`, created from scratch.

## Proposed Changes

- A `backend/` Node project with an `npm test` script that runs the Jest suite and an `npm start` script that starts the server.
- The server listens on port 3000 when started with `npm start`. Running the tests does not open the port.
- An in-memory store for users and articles, with a reset function that puts the store back to its seed state. The seed starts empty; the auth and article tickets add the seed users and articles.
- A helper that builds the error body `{"errors":{"<field>":["<message>"]}}` used by every later endpoint.
- A request to an `/api` path that no route serves gets 404 with the body `{"errors":{"route":["not found"]}}`.
- A request whose body is not valid JSON gets 400 with the body `{"errors":{"body":["is not valid JSON"]}}`, never an HTML error page.
- A smoke test so the suite has at least one passing test.
- A `.gitignore` so installed packages are not committed.
- A `scripts/env-start.sh` script at the repo root. It always restarts the backend on port 3000, so every run leaves the in-memory store holding only the seed. It installs packages first when `backend/node_modules/` is missing, waits until the backend answers, and exits 0. It serves the checkout named by `VERIFY_REPO_PATH_APP` when that variable is set. It accepts and ignores any arguments. While `frontend/package.json` does not exist it prints `frontend: skipped`; `frontend-scaffold` adds the frontend start. If the backend cannot start, it prints `backend did not start on port 3000` and exits 1.

## Technical Context

- Repository: `app` (pinned `200f5a4`). Code goes in `backend/` per `app/CLAUDE.md:53`. The pipeline runs `npm test` from `backend/` (`app/CLAUDE.md:42`, `app/CLAUDE.md:46`).
- Port: parameter `backend.port` = 3000, from the stack line `app/CLAUDE.md:21`.
- `backend/package.json`: CommonJS (no `"type": "module"`); `"scripts": {"start": "node server.js", "test": "jest"}`; dependency `express@^5`; dev dependencies `jest`, `supertest`. Add `"jest": {"testEnvironment": "node"}`.
- `backend/.gitignore`: `node_modules/`.
- `backend/app.js`: builds and exports the Express app (`express.json()`, an `/api` router that later tickets mount routes on). After the router it adds a 404 handler that responds `errorBody({route: ['not found']})`, and an error handler that turns the JSON parser's error (`err.type === 'entity.parse.failed'`) into 400 `errorBody({body: ['is not valid JSON']})`. It never calls `listen`.
- `backend/server.js`: requires `./app` and `./store`, calls `store.reset()`, then `app.listen(3000)` only when `require.main === module`. Exports nothing the tests need.
- `backend/store.js`: exports `users` and `articles` arrays, the seed lists `seedUsers` and `seedArticles` (empty here), and `reset()`, which empties both arrays in place and refills them from the seed lists. Later tickets push to the seed lists; they do not replace the arrays, so modules holding a reference stay valid.
- `backend/errors.js`: `errorBody(errors)` returns `{"errors": errors}` where `errors` maps each field to an array of messages.
- `backend/tests/smoke.test.js`: requires the app through supertest, calls `store.reset()` in `beforeEach`, and asserts a request to `/api/unknown` gets status 404 with the `route` body, and that a malformed JSON body gets status 400 with the `body` body.
- `scripts/env-start.sh` (bash, executable). This is the repo side of the verify step's `env-start.sh` contract (`ticket-verify` Step 1.6b): the verify step runs `env-start.sh` from the workspace root and waits for it to exit. Steps, in order:
  1. Repo dir = `VERIFY_REPO_PATH_APP` when set, else the parent of the script's own folder. Ignore all arguments (the verify step passes `--restart <services> gateway-fe`).
  2. Stop every process listening on port 3000 (`lsof -ti tcp:3000`, then `kill`; wait until the port is free).
  3. If `<repo>/backend/node_modules/` is missing, run `npm install` in `<repo>/backend/`.
  4. Start `npm start` in `<repo>/backend/` detached (`setsid nohup … &`), output to `/tmp/app-backend.log`, so the server outlives the script.
  5. Poll `http://localhost:3000/api/unknown` until it answers 404, for at most 60 seconds (parameter `env.start_timeout`). If the server process exits or the time runs out, print `backend did not start on port 3000` and the last 20 lines of the log, and exit 1.
  6. If `<repo>/frontend/package.json` does not exist, print `frontend: skipped`. (`frontend-scaffold` replaces this step with the frontend start.)
  7. Exit 0.
- The workspace-root `env-start.sh` that the verify step calls lives outside this repo, under `REPOS_ROOT`, so no ticket can commit it. The operator installs a one-line wrapper there that runs `bash "${VERIFY_REPO_PATH_APP:-$REPOS_ROOT/app}/scripts/env-start.sh" "$@"` (see the initiative's consensus Open Questions). This ticket's criteria run the repo script directly.
- Prior art (described only, not citable): tag `sandbox-before-reset-2026-10-29` had an Express 5 + Jest + supertest backend whose server only listened when run directly. Rebuild the same shape; do not copy from the tag.

## Acceptance Criteria

- [ ] Running `npm test` in `backend/` after `npm install` exits with code 0.
- [ ] The `npm test` output in `backend/` reports at least one passed test from `backend/tests/`.
- [ ] Running `npm test` in `backend/` exits with code 0 while another process is already listening on port 3000.
- [ ] With `npm start` running in `backend/`, a GET request to `http://localhost:3000/api/unknown` receives status 404.
- [ ] After `npm install` in `backend/`, `git status --porcelain` lists no path under `backend/node_modules/`.
- [ ] With `npm start` running in `backend/`, a GET request to `http://localhost:3000/api/unknown` receives the body `{"errors":{"route":["not found"]}}`.
- [ ] With `npm start` running in `backend/`, a POST request to `http://localhost:3000/api/unknown` with header `Content-Type: application/json` and body `{bad` receives status 400.
- [ ] With `npm start` running in `backend/`, a POST request to `http://localhost:3000/api/unknown` with header `Content-Type: application/json` and body `{bad` receives the body `{"errors":{"body":["is not valid JSON"]}}`.
- [ ] With nothing listening on port 3000, running `bash scripts/env-start.sh` in `app` exits with code 0.
- [ ] After `bash scripts/env-start.sh` exits with code 0, a GET request to `http://localhost:3000/api/unknown` receives status 404.
- [ ] Running `bash scripts/env-start.sh` a second time, while the backend it started is still running, leaves a different process ID listening on port 3000 than before the second run.
- [ ] With `backend/node_modules/` deleted, running `bash scripts/env-start.sh` exits with code 0.
- [ ] Running `bash scripts/env-start.sh --restart app gateway-fe` exits with code 0.
- [ ] With `VERIFY_REPO_PATH_APP` set to the path of a second clone of `app` on this ticket's branch, the process listening on port 3000 after `bash scripts/env-start.sh` has that clone's `backend/` folder as its working directory.
- [ ] With no `frontend/package.json` in the repo, running `bash scripts/env-start.sh` prints a line containing `frontend: skipped`.
- [ ] In a scratch copy of the repo with `backend/server.js` deleted, running `bash scripts/env-start.sh` exits with code 1.
- [ ] In a scratch copy of the repo with `backend/server.js` deleted, running `bash scripts/env-start.sh` prints a line containing `backend did not start on port 3000`.
- [ ] Requiring `./store` from `backend/` with `node` yields `users`, `articles`, `seedUsers` and `seedArticles` as arrays, `seedUsers` and `seedArticles` empty, and `reset` as a function.
- [ ] In `node` from `backend/`, after pushing one object to the store's `seedUsers` and a different object to its `users`, calling `reset()` leaves the same `users` array object holding exactly the seed object.
- [ ] In `node` from `backend/`, after pushing one object to the store's `seedArticles` and a different object to its `articles`, calling `reset()` leaves the same `articles` array object holding exactly the seed object.

## Out of Scope

- Any endpoint (auth and articles come in later tickets).
- Seed users and seed articles (added by the auth and article read tickets).
- The frontend.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/` package, app, server, store, error helper, smoke test |
| Tooling | app | `scripts/env-start.sh` (backend start for the verify step) |

## Test User

No login: this ticket has no UI and no authenticated endpoint. Role: developer running commands in `backend/`; no password.

## Environment

- [x] Local (`backend/` on port 3000)

## Test Data Provided

- A second clone of `app` on this ticket's branch, made in a scratch folder by the check that uses it.
- A scratch copy of the repo with `backend/server.js` deleted, made by the check that uses it.

## Labels

planned, INIT-0000000000-5252, chore

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Build a CommonJS Express 5 API in app/backend with an importable app module, a resettable in-memory store, and Jest + supertest behind npm test.",
  "AffectedServices": "app",
  "TargetSymbols": "app (new):app/backend/app.js;server (new):app/backend/server.js;store (new):app/backend/store.js;errorBody (new):app/backend/errors.js;smoke (new):app/backend/tests/smoke.test.js;envStart (new):app/scripts/env-start.sh",
  "Kind": "enabler",
  "Serves": [],
  "Enables": ["O1", "O2", "O3"]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `npm test` in `backend/` after `npm install` exits with code 0. | developer | none | — | | exit code 0 | yes |
| The `npm test` output in `backend/` reports at least one passed test from `backend/tests/`. | developer | none | — | | Jest summary shows 1 or more passed tests, 0 failed | yes |
| Running `npm test` in `backend/` exits with code 0 while another process is already listening on port 3000. | developer | none | — | | exit code 0 with port 3000 held by another process | yes |
| With `npm start` running in `backend/`, a GET request to `http://localhost:3000/api/unknown` receives status 404. | developer | none | — | | HTTP status 404 | yes |
| After `npm install` in `backend/`, `git status --porcelain` lists no path under `backend/node_modules/`. | developer | none | — | | no line containing `backend/node_modules/` | yes |
| With `npm start` running in `backend/`, a GET request to `http://localhost:3000/api/unknown` receives the body `{"errors":{"route":["not found"]}}`. | developer | none | — | | body `{"errors":{"route":["not found"]}}` | yes |
| With `npm start` running in `backend/`, a POST request to `http://localhost:3000/api/unknown` with header `Content-Type: application/json` and body `{bad` receives status 400. | developer | none | — | | HTTP status 400 | yes |
| With `npm start` running in `backend/`, a POST request to `http://localhost:3000/api/unknown` with header `Content-Type: application/json` and body `{bad` receives the body `{"errors":{"body":["is not valid JSON"]}}`. | developer | none | — | | body `{"errors":{"body":["is not valid JSON"]}}` | yes |
| With nothing listening on port 3000, running `bash scripts/env-start.sh` in `app` exits with code 0. | developer | none | — | stop any process on port 3000, then run the script from the repo root | exit code 0 | yes |
| After `bash scripts/env-start.sh` exits with code 0, a GET request to `http://localhost:3000/api/unknown` receives status 404. | developer | none | — | run the script, then send the request | HTTP status 404 | yes |
| Running `bash scripts/env-start.sh` a second time, while the backend it started is still running, leaves a different process ID listening on port 3000 than before the second run. | developer | none | — | run the script, note `lsof -ti tcp:3000`, run it again, compare | the two process IDs differ | yes |
| With `backend/node_modules/` deleted, running `bash scripts/env-start.sh` exits with code 0. | developer | none | — | `rm -rf backend/node_modules`, then run the script | exit code 0 | yes |
| Running `bash scripts/env-start.sh --restart app gateway-fe` exits with code 0. | developer | none | — | run the script with those arguments | exit code 0 | yes |
| With `VERIFY_REPO_PATH_APP` set to the path of a second clone of `app` on this ticket's branch, the process listening on port 3000 after `bash scripts/env-start.sh` has that clone's `backend/` folder as its working directory. | developer | a second clone of `app` on this ticket's branch | seeded-by:backend-scaffold | clone to a scratch folder, export the variable, run the script, then `readlink /proc/$(lsof -ti tcp:3000)/cwd` | the clone's `backend/` path | yes |
| With no `frontend/package.json` in the repo, running `bash scripts/env-start.sh` prints a line containing `frontend: skipped`. | developer | none | — | run the script on this ticket's branch, which has no `frontend/` | output line containing `frontend: skipped` | yes |
| In a scratch copy of the repo with `backend/server.js` deleted, running `bash scripts/env-start.sh` exits with code 1. | developer | a scratch copy of the repo with `backend/server.js` deleted | seeded-by:backend-scaffold | copy the repo, delete the file, run the copy's script | exit code 1 | yes |
| In a scratch copy of the repo with `backend/server.js` deleted, running `bash scripts/env-start.sh` prints a line containing `backend did not start on port 3000`. | developer | a scratch copy of the repo with `backend/server.js` deleted | seeded-by:backend-scaffold | copy the repo, delete the file, run the copy's script | output line containing `backend did not start on port 3000` | yes |
| Requiring `./store` from `backend/` with `node` yields `users`, `articles`, `seedUsers` and `seedArticles` as arrays, `seedUsers` and `seedArticles` empty, and `reset` as a function. | developer | none | — | in `backend/`, run `node -e` requiring `./store` and print `Array.isArray` for each list, the seed list lengths and `typeof reset` | four arrays, both seed lists length 0, `reset` is `function` | yes |
| In `node` from `backend/`, after pushing one object to the store's `seedUsers` and a different object to its `users`, calling `reset()` leaves the same `users` array object holding exactly the seed object. | developer | none | — | in `backend/`, run `node -e`: keep a reference to `users`, push to both lists, call `reset()`, compare | the kept reference is identical to the exported `users`, which has length 1 and contains only the seed object | yes |
| In `node` from `backend/`, after pushing one object to the store's `seedArticles` and a different object to its `articles`, calling `reset()` leaves the same `articles` array object holding exactly the seed object. | developer | none | — | in `backend/`, run `node -e`: keep a reference to `articles`, push to both lists, call `reset()`, compare | the kept reference is identical to the exported `articles`, which has length 1 and contains only the seed object | yes |

## Writes

None.

## Reads

None.

## Preconditions

None.
