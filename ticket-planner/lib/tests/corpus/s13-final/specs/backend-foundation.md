# backend-foundation

## Title

Scaffold the Express backend with a seeded in-memory store and test runner

## Description

## Summary

Create the `backend/` project in `app`: package manifest, an Express app that can be tested without opening a port, a server entry point on port 3000, an in-memory store that is re-seeded with the brief's two authors and two articles, and a Jest test runner behind `npm test`.

## Enables

**Enables:** O1, O2, O3, O4 — every API endpoint in this slice runs on this app and reads this store.

The repo has no code, no `package.json` and no test runner. The user and article endpoints need a shared app, a shared store with the seed data, a shared error format, and an `npm test` command the pipeline can run as its backend check.

## Background / Motivation

`app` holds only `README.md` and `CLAUDE.md`. Its `CLAUDE.md` already fixes the stack (Express on port 3000) and the backend check (`npm test` run from `backend/`). This ticket builds that base so the later endpoint tickets can each add one router and its tests.

## Proposed Changes

- Add `backend/package.json` with a `start` script that runs the server and a `test` script that runs Jest. Runtime dependencies: `express`, `bcryptjs`, `jsonwebtoken`. Development dependencies: `jest` and `supertest`. Commit the generated `backend/package-lock.json`.
- Add a root `.gitignore` that ignores `node_modules/` and `dist/`.
- Add an app factory that builds the Express app without listening, and a separate server entry point that listens on port 3000 and prints `Conduit API listening on port 3000`.
- Add an in-memory store holding users and articles, with a reset function that restores the seed and one insert function per record kind that gives a new record the next integer id. The server seeds the store on every start and says so in its start-up output.
- The seed holds two authors and two articles, exactly as the brief lists them. Seed passwords are stored only as bcrypt hashes with cost 10.
- Add error-body helpers that every endpoint ticket uses, and a final error handler for unexpected errors.
- Add a smoke test that resets the store and checks the seed, and a test of the error helpers, so `npm test` passes on this ticket alone.

## Technical Context

- Repo: `app`, pinned at `200f5a4`. The tree holds only `CLAUDE.md` and `README.md`. `CLAUDE.md:21` fixes Express on port 3000; `CLAUDE.md:42` and `CLAUDE.md:46` fix `npm test` from `backend/` as `BE_TEST_CMD`; `CLAUDE.md:53` puts backend code in `backend/`.
- Module format: CommonJS (`require`), so Jest runs without a transform.
- `backend/package.json`: `"start": "node src/server.js"`, `"test": "jest"`. No `--forceExit`: tests never call `listen`, so Jest exits on its own.
- `backend/src/app.js` exports `createApp()`. It mounts `express.json()`, then an error middleware that turns a JSON parse failure (`err.type === 'entity.parse.failed'`) into `req.body = {}` and calls `next()` so the route sees an empty body, then the routers (added by later tickets), then a final error handler. `app.js` also exports that final handler as `errorHandler`; it answers any unexpected error with status 500 and `{"errors":{"server":["unexpected error"]}}`. Because of the shim, a request with malformed JSON reaches routing like any other request (`request.body.malformed_json`).
- `backend/src/server.js` is the only file that calls `listen(3000)`. Before it listens it calls `store.reset()` and prints `Seeded 2 users and 2 articles`; once listening it prints `Conduit API listening on port 3000`.
- `backend/src/errors.js` exports two helpers that send the brief's error bodies, in the shape `{"errors":{"<field>":["<message>"]}}`. `validationError(res, fields)` sends status 422 with `can't be blank` for each named field, in the order given, all in one body. `sendError(res, status, field, message)` sends that status with one field and one message. The endpoint tickets call them for validation, sign-in and not-found failures; no endpoint builds an error body by hand.
- `backend/src/store.js` exports `users`, `articles`, `reset()`, `insertUser(fields)` and `insertArticle(fields)`. This is the one write interface for the store: every ticket that adds a record calls `insertUser` or `insertArticle`, never `push` on the arrays and never its own id counter. Each insert function takes the record's fields without an `id`, gives it the next integer `id` from its own per-kind counter, appends it, and returns the stored record. `reset()` is synchronous: it empties the existing `users` and `articles` arrays in place (it never replaces them, so a module that kept `const { articles } = require('./store')` keeps seeing current data), refills them with deep copies of the seed, and sets both counters so the next `id` is 3. Seed ids: `jake` 1, `jane` 2, `how-to-train-your-dragon` 1, `welcome-to-conduit` 2. User record fields: `id`, `username`, `email`, `passwordHash`, `bio` (`null`), `image` (`null`). Article record fields: `id`, `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `authorId`.
- `backend/src/seed.js` hashes the two seed passwords once at module load with `bcryptjs.hashSync(password, 10)` (`auth.bcrypt.cost`: 10) and caches the hashes, so a reset costs no hashing.
- Seed users: `jake` / `jake@conduit.test` / `Jake-Pass-123`; `jane` / `jane@conduit.test` / `Jane-Pass-123`.
- Seed articles: `how-to-train-your-dragon`, "How to train your dragon", author jake, `createdAt` and `updatedAt` `2026-01-01T10:00:00.000Z`; `welcome-to-conduit`, "Welcome to Conduit", author jane, `createdAt` and `updatedAt` `2026-01-02T10:00:00.000Z`. Both have description `Seed article` and body `Seed body text.`
- `backend/test/store.test.js`: the smoke test, named `reset restores the seeded users and articles`.
- Runtime (`runtime.node.version`): Node v22.22.2 and npm 10.9.7 from the host; no `engines` field and no `.nvmrc`. The committed `package-lock.json` pins the exact `express` and `jest` versions.
- Tests: `backend/test/store.test.js` (store and seed) and `backend/test/errors.test.js` (the two helpers and `errorHandler`, each mounted on a small Express app built in the test).

## Acceptance Criteria

- [ ] Running `npm test` in `backend/` after `npm install` exits with code 0
- [ ] The `npm test` output in `backend/` lists the passing test `reset restores the seeded users and articles`
- [ ] Running `npm start` in `backend/` prints `Conduit API listening on port 3000`
- [ ] While `npm start` runs in `backend/`, a request to port 3000 for the path `/api/no-such-route` gets status 404
- [ ] After `npm install` in `backend/`, `git status` does not list `backend/node_modules/`
- [ ] After `store.reset()`, the store holds exactly 2 `user` records, with usernames `jake` and `jane`
- [ ] After `store.reset()`, the store holds exactly 2 `article` records, with slugs `how-to-train-your-dragon` and `welcome-to-conduit`
- [ ] After `store.reset()`, the stored password value of `user` jake begins with `$2` and is not the text `Jake-Pass-123`
- [ ] A test that adds a third `article` and then calls `store.reset()` finds 2 `article` records afterwards
- [ ] After `store.reset()`, `store.insertArticle` returns a new `article` record with `id` 3
- [ ] After `store.reset()`, `store.insertUser` returns a new `user` record with `id` 3
- [ ] A reference to `store.articles` taken before `store.reset()` holds 2 `article` records after the reset
- [ ] Running `npm start` in `backend/` prints `Seeded 2 users and 2 articles`
- [ ] While `npm start` runs in `backend/`, a POST to `/api/no-such-route` with `Content-Type: application/json` and the body `{not json` gets status 404
- [ ] In `backend/test/errors.test.js`, a route that answers through `validationError` for the fields `title` and `body` returns status 422 with `{"errors":{"title":["can't be blank"],"body":["can't be blank"]}}`
- [ ] In `backend/test/errors.test.js`, a route that answers through `sendError` with status 404, field `article` and message `not found` returns status 404 with `{"errors":{"article":["not found"]}}`
- [ ] In `backend/test/errors.test.js`, a route that throws, followed by `errorHandler`, returns status 500 with `{"errors":{"server":["unexpected error"]}}`
- [ ] A test that changes the `title` of a seeded `article` record and then calls `store.reset()` finds that record's `title` equal to its seed value, and a second `store.reset()` gives the same seed value

## Test User

No sign-in is needed. Every check runs from a terminal in `app/backend/`.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Backend | app | `backend/` project setup, app factory, server entry point, in-memory store with its insert functions and seed, error helpers, final error handler, Jest smoke and helper tests |
| Repo | app | root `.gitignore` |

## Labels

planned, INIT-0000000000-9899, chore

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 9,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Build a layered CommonJS Express API with an app factory, an in-memory store with a synchronous reset to a pre-hashed seed, and Jest + supertest behind npm test.",
  "AffectedServices": "app",
  "TargetSymbols": "createApp (new):app/backend/src/app.js;errorHandler (new):app/backend/src/app.js;reset (new):app/backend/src/store.js;insertUser (new):app/backend/src/store.js;insertArticle (new):app/backend/src/store.js;seed (new):app/backend/src/seed.js;validationError (new):app/backend/src/errors.js;sendError (new):app/backend/src/errors.js;listen (new):app/backend/src/server.js",
  "Kind": "enabler",
  "Serves": [],
  "Enables": ["O1", "O2", "O3", "O4"]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `npm test` in `backend/` after `npm install` exits with code 0 | developer | none | — | terminal in `backend/` | exit code 0 | yes |
| The `npm test` output in `backend/` lists the passing test `reset restores the seeded users and articles` | developer | none | — | terminal in `backend/` | test `reset restores the seeded users and articles` marked passed | yes |
| Running `npm start` in `backend/` prints `Conduit API listening on port 3000` | developer | none | — | terminal in `backend/` | output line `Conduit API listening on port 3000` | yes |
| While `npm start` runs in `backend/`, a request to port 3000 for the path `/api/no-such-route` gets status 404 | developer | none | — | terminal with an HTTP client | status 404 | yes |
| After `npm install` in `backend/`, `git status` does not list `backend/node_modules/` | developer | none | — | terminal at repo root | `backend/node_modules/` absent from `git status` output | yes |
| After `store.reset()`, the store holds exactly 2 `user` records, with usernames `jake` and `jane` | developer | 2 `user` records (jake, jane) from the seed | seeded-by:backend-foundation | `backend/test/store.test.js` | usernames `jake`, `jane`; count 2 | yes |
| After `store.reset()`, the store holds exactly 2 `article` records, with slugs `how-to-train-your-dragon` and `welcome-to-conduit` | developer | 2 `article` records (how-to-train-your-dragon, welcome-to-conduit) from the seed | seeded-by:backend-foundation | `backend/test/store.test.js` | slugs `how-to-train-your-dragon`, `welcome-to-conduit`; count 2 | yes |
| After `store.reset()`, the stored password value of `user` jake begins with `$2` and is not the text `Jake-Pass-123` | developer | 1 `user` record jake from the seed | seeded-by:backend-foundation | `backend/test/store.test.js` | value starts with `$2`; value differs from `Jake-Pass-123` | yes |
| A test that adds a third `article` and then calls `store.reset()` finds 2 `article` records afterwards | developer | 2 seeded `article` records plus 1 extra `article` record added by the test | seeded-by:backend-foundation | `backend/test/store.test.js` | count 2 after reset | yes |
| After `store.reset()`, `store.insertArticle` returns a new `article` record with `id` 3 | developer | 2 seeded `article` records (ids 1 and 2) | seeded-by:backend-foundation | `backend/test/store.test.js` | returned record `id` 3 | yes |
| After `store.reset()`, `store.insertUser` returns a new `user` record with `id` 3 | developer | 2 seeded `user` records (ids 1 and 2) | seeded-by:backend-foundation | `backend/test/store.test.js` | returned record `id` 3 | yes |
| A reference to `store.articles` taken before `store.reset()` holds 2 `article` records after the reset | developer | 2 seeded `article` records plus 1 extra `article` record added by the test | seeded-by:backend-foundation | `backend/test/store.test.js` | the earlier reference has length 2 | yes |
| Running `npm start` in `backend/` prints `Seeded 2 users and 2 articles` | developer | 2 `user` and 2 `article` records from the seed | seeded-by:backend-foundation | terminal in `backend/` | output line `Seeded 2 users and 2 articles` | yes |
| While `npm start` runs in `backend/`, a POST to `/api/no-such-route` with `Content-Type: application/json` and the body `{not json` gets status 404 | developer | none | — | terminal with an HTTP client | status 404 | yes |
| In `backend/test/errors.test.js`, a route that answers through `validationError` for the fields `title` and `body` returns status 422 with `{"errors":{"title":["can't be blank"],"body":["can't be blank"]}}` | developer | none | — | `backend/test/errors.test.js` | status 422; `{"errors":{"title":["can't be blank"],"body":["can't be blank"]}}` | yes |
| In `backend/test/errors.test.js`, a route that answers through `sendError` with status 404, field `article` and message `not found` returns status 404 with `{"errors":{"article":["not found"]}}` | developer | none | — | `backend/test/errors.test.js` | status 404; `{"errors":{"article":["not found"]}}` | yes |
| In `backend/test/errors.test.js`, a route that throws, followed by `errorHandler`, returns status 500 with `{"errors":{"server":["unexpected error"]}}` | developer | none | — | `backend/test/errors.test.js` | status 500; `{"errors":{"server":["unexpected error"]}}` | yes |
| A test that changes the `title` of a seeded `article` record and then calls `store.reset()` finds that record's `title` equal to its seed value, and a second `store.reset()` gives the same seed value | developer | 2 seeded `article` records, one with its `title` changed by the test | seeded-by:backend-foundation | `backend/test/store.test.js` | `title` equals the seed value after each reset | yes |

## Test Data Provided

- 2 `user` records, loaded on every server start and by `store.reset()`: `jake` / `jake@conduit.test` / `Jake-Pass-123` and `jane` / `jane@conduit.test` / `Jane-Pass-123`, both with `bio` and `image` `null`, passwords stored as bcrypt hashes with cost 10.
- 2 `article` records, loaded the same way: `how-to-train-your-dragon` ("How to train your dragon", author jake, `createdAt` `2026-01-01T10:00:00.000Z`) and `welcome-to-conduit` ("Welcome to Conduit", author jane, `createdAt` `2026-01-02T10:00:00.000Z`), both with description `Seed article` and body `Seed body text.`

## Writes

| Key | Op |
|-----|----|
| `user.id` | create |
| `user.username` | create |
| `user.email` | create |
| `user.password_hash` | create |
| `user.bio` | create |
| `user.image` | create |
| `article.id` | create |
| `article.slug` | create |
| `article.title` | create |
| `article.description` | create |
| `article.body` | create |
| `article.created_at` | create |
| `article.updated_at` | create |
| `article.author_id` | create |

## Reads

None.

## Preconditions

None.
