# backend-foundation

## Title

Scaffold the Conduit-lite backend with a seeded in-memory store and npm test

## Description

## Summary

Create the `backend/` project in `app`: an Express app on port 3000, an in-memory store that is seeded with two authors and two articles every time the server or a test starts, shared JSON error handling, and a test suite behind `npm test`. No user or article endpoint is added here; those come in later tickets that build on this one.

## Enables

**Enables:** O1, O2, O3 — every API endpoint and page of the slice runs on this server, its store and its seed data.

The repository has no backend, no `package.json` and no test runner yet. The register, login and article endpoints need a running app, a place to keep users and articles, the seeded accounts and articles the browser checks use, and an `npm test` command the pipeline already expects (`BE_TEST_CMD`).

## Background / Motivation

`app` holds only `README.md` and `CLAUDE.md`. The repository's `CLAUDE.md` already declares `npm test` run from `backend/` as the backend test command and port 3000 for the API, so the backend must exist with that layout before any endpoint can be built or tested. Storage is in memory and is seeded again on every start, as the brief requires; there is no database.

## Proposed Changes

- Add `backend/package.json` with `scripts.start` = `node src/server.js`, `scripts.test` = `node --test`, `engines.node` = `>=22`, dependencies `express` (5.x), `jsonwebtoken` and `bcryptjs`, and dev dependency `supertest`.
- Add an app factory that builds a fresh Express app over a store passed in by the caller. It parses JSON bodies, answers any request under the `/api` path prefix that no route matches with 404 and the body `{"errors":{"route":["not found"]}}`, and answers a malformed JSON body with 422 and the body `{"errors":{"request":["is invalid"]}}`. The 404 is a prefix handler mounted on `/api` after the routers, not a `*` route pattern, which Express 5 rejects at start-up.
- Add a server entry that creates and seeds a store, reads `JWT_SECRET`, logs one warning line naming `JWT_SECRET` when the variable is unset and the development secret `conduit-dev-secret` is used instead, and listens on port 3000.
- Add the in-memory store (users and articles, with lookups by user id, by email ignoring case, by username matching case exactly, and by article slug).
- Add the seed: users `jake` (`jake@conduit.test`, password `Jake-Pass-123`) and `jane` (`jane@conduit.test`, password `Jane-Pass-123`), both with `bio` and `image` set to `null`; articles `how-to-train-your-dragon` ("How to train your dragon", by jake, `createdAt` `2026-01-01T10:00:00.000Z`) and `welcome-to-conduit` ("Welcome to Conduit", by jane, `createdAt` `2026-01-02T10:00:00.000Z`), both with description `Seed article` and body `Seed body text.`, and `updatedAt` equal to `createdAt`. Passwords are stored only as bcrypt hashes with cost 10.
- Add the shared error helper and the test helpers, plus a seed test.
- Add a repository-root `.gitignore` containing `node_modules/`, which keeps installed packages of both `backend/` and `frontend/` out of git, and commit `backend/package-lock.json`.

## Technical Context

- Repository: `app`, branch base `origin/develop` (commit `200f5a4`, which holds only `CLAUDE.md` and `README.md`). This is greenfield work: do not merge or cherry-pick the tags `sandbox-before-reset-2026-10-29` or `sandbox-develop-before-reset-2026-10-29`.
- The pipeline reads `BE_TEST_CMD` = `npm test` (`app/CLAUDE.md:46`) and runs it from `backend/` (`app/CLAUDE.md:42`). The API port is fixed at 3000 (`app/CLAUDE.md:21`). Parameters: `api.port` (3000), `auth.bcrypt_cost` (10), `auth.jwt_secret_default` (conduit-dev-secret), `api.unknown_route` (404 with errors.route "not found"), `api.malformed_json` (422 with errors.request "is invalid"), `api.express_major` (5).
- New files:
  - `backend/package.json`
  - `backend/src/app.js`: `createApp({ store, jwtSecret })`: `express.json()`, a router mount point for later tickets, the `/api` 404 handler and an error middleware that turns a JSON parse error into the 422 body.
  - `backend/src/server.js`: `createStore()` + `seed(store)`, `process.env.JWT_SECRET || 'conduit-dev-secret'` with a single `console.warn()` line containing `JWT_SECRET` when the fallback is used, `listen(3000)`.
  - `backend/src/store.js`: `createStore()` returning `{ users, articles }` plus `findUserById`, `findUserByEmail` (lower-cased compare), `findUserByUsername` (exact compare), `findArticleBySlug`, `addUser`, `addArticle`, `listArticles`. User records hold `id`, `username`, `email`, `passwordHash`, `bio`, `image`. Article records hold `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `authorId`.
  - `backend/src/seed.js`: `seed(store)`; the two seed password hashes are computed once per process (memoised) with `bcryptjs` cost 10 and reused by every store.
  - `backend/src/errors.js`: `sendErrors(res, status, errorsObject)` writing `{"errors": errorsObject}`.
  - `backend/test/helpers.js`: `freshApp()` returning `{ app, store }` with a new seeded store per call.
  - `backend/test/seed.test.js`: asserts every seed value below.
  - `.gitignore` (repository root): the single line `node_modules/`.
  - `backend/package-lock.json`: committed, written by `npm install`.
- No module-level mutable state: each `createApp` call works only on the store it is given, so tests cannot leak state into each other.

## Acceptance Criteria

- [ ] Running `npm test` in `backend/` on a fresh checkout after `npm install` exits with code 0
- [ ] `npm test` in `backend/` reports a passing seed test that finds user `jake` with email `jake@conduit.test`
- [ ] `npm test` in `backend/` reports a passing seed test that finds user `jane` with email `jane@conduit.test`
- [ ] `npm test` in `backend/` reports a passing seed test that finds article `how-to-train-your-dragon` by `jake` with `createdAt` `2026-01-01T10:00:00.000Z`
- [ ] `npm test` in `backend/` reports a passing seed test that finds article `welcome-to-conduit` by `jane` with `createdAt` `2026-01-02T10:00:00.000Z`
- [ ] `npm test` in `backend/` reports a passing seed test that finds description `Seed article` on both seeded articles
- [ ] `npm test` in `backend/` reports a passing seed test that finds body `Seed body text.` on both seeded articles
- [ ] `npm test` in `backend/` reports a passing seed test that finds `bcryptjs.getRounds` returns 10 for the stored password hash of `jake`
- [ ] With the server started by `npm start` in `backend/`, `GET http://localhost:3000/api/no-such-route` returns status 404
- [ ] With the server started by `npm start` in `backend/`, `GET http://localhost:3000/api/no-such-route` returns the body `{"errors":{"route":["not found"]}}`
- [ ] A `POST` to `http://localhost:3000/api/members` with header `Content-Type: application/json` and the body `{bad json` returns status 422
- [ ] A `POST` to `http://localhost:3000/api/members` with header `Content-Type: application/json` and the body `{bad json` returns the body `{"errors":{"request":["is invalid"]}}`
- [ ] Starting the server with `JWT_SECRET` unset prints one warning line that contains the text `JWT_SECRET`
- [ ] Starting the server with `JWT_SECRET=test-secret` prints no line that contains the text `JWT_SECRET`
- [ ] After `npm install` in `backend/`, `git status --porcelain` run at the repository root lists no path under `backend/node_modules/`
- [ ] `git ls-files backend/package-lock.json` run at the repository root prints `backend/package-lock.json`
- [ ] `npm test` in `backend/` reports a passing store test in which `findUserByEmail`, given a seeded author's email written in upper case, returns that author
- [ ] `npm test` in `backend/` reports a passing store test in which `findUserByUsername` returns a seeded author for that author's exact username and returns no user for the same username written in upper case
- [ ] `npm test` in `backend/` reports a passing store test in which `findUserById` returns a seeded author for that author's id and `findArticleBySlug` returns a seeded article for that article's slug
- [ ] `npm test` in `backend/` reports a passing seed test in which, for each of the two seeded authors, `bcryptjs.compare` of that author's password listed in Test Data Provided against that author's stored `passwordHash` returns true
- [ ] `npm test` in `backend/` reports a passing seed test in which `bcryptjs.compare` of a password not listed in Test Data Provided against a seeded author's stored `passwordHash` returns false
- [ ] `npm test` in `backend/` reports a passing seed test in which no seeded user record holds that user's plaintext password in any field

## Out of Scope

User and article endpoints, the frontend, a database, and any change to `CLAUDE.md` or `README.md`.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/` scaffold: app factory, server entry, store, seed, error helper, test helpers; repository-root `.gitignore` |

## Test User

`jake@conduit.test` — password `Jake-Pass-123` (seeded by this ticket; no browser sign-in is needed to verify it)

## Environment

- [x] Local (`http://localhost:3000` for the API)

## Test Data Provided

- User `jake`: email `jake@conduit.test`, password `Jake-Pass-123`, `bio` `null`, `image` `null`.
- User `jane`: email `jane@conduit.test`, password `Jane-Pass-123`, `bio` `null`, `image` `null`.
- Article `how-to-train-your-dragon`: title "How to train your dragon", author `jake`, description `Seed article`, body `Seed body text.`, `createdAt` and `updatedAt` `2026-01-01T10:00:00.000Z`.
- Article `welcome-to-conduit`: title "Welcome to Conduit", author `jane`, description `Seed article`, body `Seed body text.`, `createdAt` and `updatedAt` `2026-01-02T10:00:00.000Z`.

All four records are created on every server start and in every fresh test store.

## Labels

planned, INIT-0000000000-5856, chore

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "Build backend/ as an Express app factory over a per-instance seeded in-memory store, with node --test and supertest behind npm test.",
  "AffectedServices": "app",
  "TargetSymbols": "createApp (new):app/backend/src/app.js;createStore (new):app/backend/src/store.js;seed (new):app/backend/src/seed.js;sendErrors (new):app/backend/src/errors.js",
  "Kind": "enabler",
  "Serves": [],
  "Enables": ["O1", "O2", "O3"]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `npm test` in `backend/` on a fresh checkout after `npm install` exits with code 0 | developer | none | — | terminal in `backend/` | exit code 0 | yes |
| `npm test` in `backend/` reports a passing seed test that finds user `jake` with email `jake@conduit.test` | developer | 1 `user` `jake` | seeded-by:backend-foundation | terminal in `backend/` | seed test for `jake` reported as passing | yes |
| `npm test` in `backend/` reports a passing seed test that finds user `jane` with email `jane@conduit.test` | developer | 1 `user` `jane` | seeded-by:backend-foundation | terminal in `backend/` | seed test for `jane` reported as passing | yes |
| `npm test` in `backend/` reports a passing seed test that finds article `how-to-train-your-dragon` by `jake` with `createdAt` `2026-01-01T10:00:00.000Z` | developer | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | terminal in `backend/` | seed test for `how-to-train-your-dragon` reported as passing | yes |
| `npm test` in `backend/` reports a passing seed test that finds article `welcome-to-conduit` by `jane` with `createdAt` `2026-01-02T10:00:00.000Z` | developer | 1 `article` `welcome-to-conduit` | seeded-by:backend-foundation | terminal in `backend/` | seed test for `welcome-to-conduit` reported as passing | yes |
| `npm test` in `backend/` reports a passing seed test that finds description `Seed article` on both seeded articles | developer | 2 seeded `article` records | seeded-by:backend-foundation | terminal in `backend/` | seed description test reported as passing | yes |
| `npm test` in `backend/` reports a passing seed test that finds body `Seed body text.` on both seeded articles | developer | 2 seeded `article` records | seeded-by:backend-foundation | terminal in `backend/` | seed body test reported as passing | yes |
| `npm test` in `backend/` reports a passing seed test that finds `bcryptjs.getRounds` returns 10 for the stored password hash of `jake` | developer | 1 `user` `jake` | seeded-by:backend-foundation | terminal in `backend/` | seed hash test reported as passing | yes |
| With the server started by `npm start` in `backend/`, `GET http://localhost:3000/api/no-such-route` returns status 404 | anonymous reader | none | — | HTTP client | status 404 | yes |
| With the server started by `npm start` in `backend/`, `GET http://localhost:3000/api/no-such-route` returns the body `{"errors":{"route":["not found"]}}` | anonymous reader | none | — | HTTP client | `{"errors":{"route":["not found"]}}` | yes |
| A `POST` to `http://localhost:3000/api/members` with header `Content-Type: application/json` and the body `{bad json` returns status 422 | anonymous reader | none | — | HTTP client | status 422 | yes |
| A `POST` to `http://localhost:3000/api/members` with header `Content-Type: application/json` and the body `{bad json` returns the body `{"errors":{"request":["is invalid"]}}` | anonymous reader | none | — | HTTP client | `{"errors":{"request":["is invalid"]}}` | yes |
| Starting the server with `JWT_SECRET` unset prints one warning line that contains the text `JWT_SECRET` | developer | none | — | terminal in `backend/` | exactly one output line containing `JWT_SECRET` | yes |
| Starting the server with `JWT_SECRET=test-secret` prints no line that contains the text `JWT_SECRET` | developer | none | — | terminal in `backend/` | zero output lines containing `JWT_SECRET` | yes |
| After `npm install` in `backend/`, `git status --porcelain` run at the repository root lists no path under `backend/node_modules/` | developer | none | — | terminal at the repository root | zero output lines containing `backend/node_modules/` | yes |
| `git ls-files backend/package-lock.json` run at the repository root prints `backend/package-lock.json` | developer | none | — | terminal at the repository root | output is exactly `backend/package-lock.json` | yes |
| `npm test` in `backend/` reports a passing store test in which `findUserByEmail`, given a seeded author's email written in upper case, returns that author | developer | 1 seeded `user` | seeded-by:backend-foundation | terminal in `backend/` | case-insensitive email lookup test reported as passing | yes |
| `npm test` in `backend/` reports a passing store test in which `findUserByUsername` returns a seeded author for that author's exact username and returns no user for the same username written in upper case | developer | 1 seeded `user` | seeded-by:backend-foundation | terminal in `backend/` | case-exact username lookup test reported as passing | yes |
| `npm test` in `backend/` reports a passing store test in which `findUserById` returns a seeded author for that author's id and `findArticleBySlug` returns a seeded article for that article's slug | developer | 1 seeded `user`, 1 seeded `article` | seeded-by:backend-foundation | terminal in `backend/` | id and slug lookup test reported as passing | yes |
| `npm test` in `backend/` reports a passing seed test in which, for each of the two seeded authors, `bcryptjs.compare` of that author's password listed in Test Data Provided against that author's stored `passwordHash` returns true | developer | 2 seeded `user` records | seeded-by:backend-foundation | terminal in `backend/` | seed password match test reported as passing for both authors | yes |
| `npm test` in `backend/` reports a passing seed test in which `bcryptjs.compare` of a password not listed in Test Data Provided against a seeded author's stored `passwordHash` returns false | developer | 1 seeded `user` | seeded-by:backend-foundation | terminal in `backend/` | seed wrong-password test reported as passing | yes |
| `npm test` in `backend/` reports a passing seed test in which no seeded user record holds that user's plaintext password in any field | developer | 2 seeded `user` records | seeded-by:backend-foundation | terminal in `backend/` | seed no-plaintext-password test reported as passing | yes |

## Writes

| Key | Op |
|-----|----|
| `user` | create |
| `article` | create |

## Reads

None.

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `npm test` in `backend/` reports a passing seed test that finds user `jake` with email `jake@conduit.test` | `user.username` | state | value:jake | spec:backend-foundation |
| `npm test` in `backend/` reports a passing seed test that finds user `jane` with email `jane@conduit.test` | `user.username` | state | value:jane | spec:backend-foundation |
| `npm test` in `backend/` reports a passing seed test that finds `bcryptjs.getRounds` returns 10 for the stored password hash of `jake` | `user.username` | state | value:jake | spec:backend-foundation |
