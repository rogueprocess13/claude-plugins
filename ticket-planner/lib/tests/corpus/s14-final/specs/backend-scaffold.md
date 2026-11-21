# backend-scaffold

## Title

Scaffold the Express backend with a node:test runner

## Description

## Summary

Create the `backend/` project in `app`: an Express 5 app built by a `createApp()` factory, a server entry point on port 3000, empty users and articles router factories, JSON error bodies for malformed request bodies, unknown paths and unexpected errors, and a test runner behind `npm test`.

## Enables

**Enables:** O1, O2, O3 — every API endpoint the authors and readers use runs inside this app.

The repo has no `backend/` directory, no `package.json` and no test runner. Every later backend ticket adds routes and tests to this project, so it has to exist first, with a passing `npm test`.

## Background / Motivation

The repo CLAUDE.md already promises `npm test` from `backend/` (it is the pipeline's `BE_TEST_CMD`), but nothing exists to run. Building the app through a factory lets every test file start from a fresh, seeded store without a shared reset hook.

## Proposed Changes

- `npm test` in `backend/` runs the test files under `backend/test/` and passes.
- `npm start` in `backend/` starts the API on port 3000 when `PORT` is not set.
- When `PORT` is set, the API listens on that port instead.
- A request whose JSON body cannot be parsed gets status 422 with the body `{"errors":{"body":["is invalid"]}}`.
- A request to a path under `/api` that no route serves gets status 404 with the body `{"errors":{"path":["not found"]}}`.
- Any other error that reaches the final error handler gets status 500 with the body `{"errors":{"server":["unexpected error"]}}`. No error answer is HTML.

## Technical Context

- New `backend/package.json`: `"type"` left as CommonJS; scripts `"start": "node src/server.js"`, `"test": "node --test"`; dependency `express` `^5`; dev dependency `supertest` `^7`. Commit `package-lock.json`.
- New `backend/src/app.js` exporting `createApp()` and `errorHandler`: `createApp()` does `app.use(express.json())`, mounts the two routers under `/api`, then a JSON 404 fallback middleware, then `errorHandler`. The 404 fallback answers 404 `{"errors":{"path":["not found"]}}`. `errorHandler(err, req, res, next)` maps the `express.json()` parse error (`err.type === 'entity.parse.failed'`) to 422 `{"errors":{"body":["is invalid"]}}` and any other error to 500 `{"errors":{"server":["unexpected error"]}}`.
- Router contract: `backend/src/routes/members.js` and `backend/src/routes/articles.js` each export a factory function, `usersRouter(store)` and `articlesRouter(store)`, that builds and returns a new `express.Router()` on every call. `createApp()` calls each factory once per app and mounts the result, so two apps never share a router or a store. In this ticket `createApp()` passes `null` as the store and both routers have no routes; `user-accounts-api` creates the store with `createStore()` and passes it to both factories. A module-level shared `Router` instance is not allowed.
- New `backend/src/server.js`: `createApp().listen(process.env.PORT || 3000)`. It is the only file that calls `listen`, so tests never open a port.
- New `backend/test/smoke.test.js` using `node:test` and `supertest(createApp())` for the 404 and malformed-body cases. For the 500 case it builds a small Express app whose only route `GET /boom` throws `new Error('boom')`, mounts `errorHandler` from `backend/src/app.js` after it, and calls it with supertest.
- Parameters: `api.port` = 3000; `api.malformed_json` = 422 body is invalid; `api.unknown_route` = 404 path not found; `api.unhandled_error` = 500 server unexpected error.
- Later tickets add `src/store.js`, `src/seed.js`, `src/auth.js`, `src/errors.js`, `src/slug.js`, add routes inside the two router factories, and change the store argument `createApp()` passes; this ticket only creates the empty router factories and mounts them.
- Node v22.22.2 and npm 10.9.7 are on the host; `node --test` needs no extra dependency.

## Acceptance Criteria

- [ ] Running `npm test` in `backend/` exits with code 0
- [ ] With `npm start` running in `backend/` and `PORT` unset, `GET http://localhost:3000/api/does-not-exist` returns status 404
- [ ] With `PORT=3100 npm start` running in `backend/`, `GET http://localhost:3100/api/does-not-exist` returns status 404
- [ ] `POST /api/members` with header `Content-Type: application/json` with the body `{bad json` returns status 422
- [ ] `POST /api/members` with header `Content-Type: application/json` with the body `{bad json` returns the body `{"errors":{"body":["is invalid"]}}`
- [ ] `GET /api/does-not-exist` on an app from `createApp()` returns the body `{"errors":{"path":["not found"]}}`
- [ ] `GET /api/does-not-exist` on an app from `createApp()` returns a `Content-Type` header that starts with `application/json`
- [ ] `GET /boom` on a test app whose only route throws `new Error('boom')`, with `errorHandler` mounted after it, returns status 500
- [ ] `GET /boom` on a test app whose only route throws `new Error('boom')`, with `errorHandler` mounted after it, returns the body `{"errors":{"server":["unexpected error"]}}`
- [ ] `GET /does-not-exist` on an app from `createApp()` returns status 404 with the body `{"errors":{"path":["not found"]}}`
- [ ] `GET /does-not-exist` on an app from `createApp()` returns a `Content-Type` header that starts with `application/json`

## Out of Scope

Users, articles, seeding, auth, the frontend and the repo docs. Each has its own ticket.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app backend | `package.json`, `src/app.js`, `src/server.js`, empty router factories, `test/smoke.test.js` |

- Assumption: The JSON 404 fallback answers every path no route serves, including paths outside the api prefix, so the backend never returns an HTML error page for an unknown path.

## Test User

None — no endpoint in this ticket needs a user. Use any HTTP client (curl or supertest) with no credentials.

## Environment

- [x] Local (`http://localhost:3000`)

## Labels

planned, INIT-0000000000-2767, chore

## Signals

```json
{
  "services_identified": 3,
  "symbols_resolved": 6,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "CommonJS Express 5 API built by a createApp() factory with a seeded in-memory store, tested with node:test plus supertest; Vite vanilla JS SPA reaching it through a /api dev proxy.",
  "AffectedServices": "app backend",
  "TargetSymbols": "createApp (new):app/backend/src/app.js;server (new):app/backend/src/server.js;usersRouter (new):app/backend/src/routes/members.js;articlesRouter (new):app/backend/src/routes/articles.js;packageJson (new):app/backend/package.json;smokeTest (new):app/backend/test/smoke.test.js",
  "Kind": "enabler",
  "Serves": [],
  "Enables": ["O1", "O2", "O3"]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `npm test` in `backend/` exits with code 0 | developer | none | — | terminal in `backend/` | exit code 0 | yes |
| With `npm start` running in `backend/` and `PORT` unset, `GET http://localhost:3000/api/does-not-exist` returns status 404 | developer | none | — | terminal, curl | status 404 | yes |
| With `PORT=3100 npm start` running in `backend/`, `GET http://localhost:3100/api/does-not-exist` returns status 404 | developer | none | — | terminal, curl | status 404 | yes |
| `POST /api/members` with header `Content-Type: application/json` with the body `{bad json` returns status 422 | developer | none | — | terminal, curl or supertest | status 422 | yes |
| `POST /api/members` with header `Content-Type: application/json` with the body `{bad json` returns the body `{"errors":{"body":["is invalid"]}}` | developer | none | — | terminal, curl or supertest | `{"errors":{"body":["is invalid"]}}` | yes |
| `GET /api/does-not-exist` on an app from `createApp()` returns the body `{"errors":{"path":["not found"]}}` | developer | none | — | `npm test` in `backend/` | `{"errors":{"path":["not found"]}}` | yes |
| `GET /api/does-not-exist` on an app from `createApp()` returns a `Content-Type` header that starts with `application/json` | developer | none | — | `npm test` in `backend/` | `Content-Type` starts with `application/json` | yes |
| `GET /boom` on a test app whose only route throws `new Error('boom')`, with `errorHandler` mounted after it, returns status 500 | developer | a test app with one route `GET /boom` that throws `new Error('boom')` | generate | `npm test` in `backend/` | status 500 | yes |
| `GET /boom` on a test app whose only route throws `new Error('boom')`, with `errorHandler` mounted after it, returns the body `{"errors":{"server":["unexpected error"]}}` | developer | a test app with one route `GET /boom` that throws `new Error('boom')` | generate | `npm test` in `backend/` | `{"errors":{"server":["unexpected error"]}}` | yes |
| `GET /does-not-exist` on an app from `createApp()` returns status 404 with the body `{"errors":{"path":["not found"]}}` | developer | none | — | `npm test` in `backend/` | status 404, `{"errors":{"path":["not found"]}}` | yes |
| `GET /does-not-exist` on an app from `createApp()` returns a `Content-Type` header that starts with `application/json` | developer | none | — | `npm test` in `backend/` | `Content-Type` starts with `application/json` | yes |

## Writes

None.

## Reads

None.

## Preconditions

None.
