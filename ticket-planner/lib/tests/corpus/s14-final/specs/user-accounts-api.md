# user-accounts-api

## Title

Authors can register, sign in and fetch their account through the API

## Description

## Summary

Add the account endpoints to the backend: register (`POST /api/members`), login (`POST /api/members/login`) and current user (`GET /api/user`), with token auth, password hashing, the error bodies the brief defines, and the two seeded authors `jake` and `jane`.

## Outcome

**Serves:** O1

**Who:** Author

**Need:** Get an account and sign in, so they can publish.

**Outcome:** A person can register as an author, and a registered author can sign in and is shown as signed in.

## Background / Motivation

Nobody can register or sign in yet. Every author-only action (publishing, the editor page, the signed-in header) depends on these endpoints and on the token they issue.

## Proposed Behaviour

Seed data, created fresh every time the app is built (every server start and every test file):

- Author `jake`, email `jake@conduit.test`, password `Jake-Pass-123`.
- Author `jane`, email `jane@conduit.test`, password `Jane-Pass-123`.
- Both have `bio` and `image` set to `null`. Accounts registered at runtime are gone after a restart.

Register — `POST /api/members` with `{"user":{"username","email","password"}}`:

- Success returns 201 and `{"user":{"email","token","username","bio","image"}}`, exactly those five keys. `bio` and `image` are `null`. `token` is a new token. The password never appears.
- A field is blank when it is missing, not a string, or empty after trimming whitespace. Each blank field is reported as `can't be blank`; all blank fields are reported together in one 422 body. A body with no `user` object reports all three fields.
- After the blank checks pass: an email already registered, compared case-insensitively, gives 422 `{"errors":{"email":["has already been taken"]}}`. A username already registered, compared case-sensitively, gives 422 `{"errors":{"username":["has already been taken"]}}`. When both collide, both keys are in one body. A username that differs only in case is accepted.
- The new account can sign in straight away.

Login — `POST /api/members/login` with `{"user":{"email","password"}}`:

- Correct email (any letter case) and password returns 200 with the same five-key `user` shape and a new token.
- A blank email or password returns 422 `can't be blank` for that field.
- An unknown email or a wrong password returns 401 `{"errors":{"email or password":["is invalid"]}}`.

Token:

- Signed with HS256. Payload `{"id","username"}`. Expires 24h after it is issued, so `exp` minus `iat` is 86400.
- Signed with the `JWT_SECRET` environment variable when it is set, otherwise with `conduit-dev-secret`.

Current user — `GET /api/user` with header `Authorization: Token <jwt>`:

- A valid token returns 200 with the five-key `user` shape; `user.token` is the token that was presented.
- These all return 401 `{"errors":{"token":["is missing or invalid"]}}`: no `Authorization` header; a scheme other than `Token` (for example `Bearer`); a bad signature; an expired token; a token whose `id` matches no account.

## Technical Context

- Builds on the `backend-scaffold` project: `backend/src/app.js` (`createApp()`), the mounted `backend/src/routes/members.js` router and the `node --test` runner.
- Add dependencies `bcryptjs` `^3` and `jsonwebtoken` `^9` to `backend/package.json`.
- New `backend/src/store.js`: `createStore()` returning `{ users: [], articles: [], nextUserId, nextArticleId }` plus lookups `findUserByEmail` (lower-cases both sides), `findUserByUsername` (exact), `findUserById`. `createApp()` builds one store per app and passes it, in place of `null`, to the router factories `usersRouter(store)` and `articlesRouter(store)` from `backend-scaffold`, so each app built by `createApp()` has its own store. The `articles` array stays empty here; the articles ticket fills it.
- New `backend/src/seed.js`: `seedUsers(store)` inserts `jake` and `jane` with `bcryptjs.hashSync(password, 10)`. Called from `createApp()`.
- New `backend/src/auth.js`: `hashPassword`, `verifyPassword`, `signToken(user)` (`jwt.sign({ id, username }, secret, { algorithm: 'HS256', expiresIn: '24h' })`), `requireAuth` middleware (parses `Authorization: Token <jwt>`, verifies, loads the user by `id`, attaches the user and the token to `req`; any failure → 401 token body). The secret is `process.env.JWT_SECRET || 'conduit-dev-secret'`, read when signing or verifying so tests can set it.
- New `backend/src/errors.js`: `isBlank(value)` per the blank rule, `blankErrors(obj, fields)` returning the `errors` object, `sendErrors(res, status, errors)`.
- New `backend/src/serializers.js`: `toUserJSON(user, token)` returning exactly `email`, `token`, `username`, `bio`, `image`; `toProfileJSON(user)` returning `username`, `bio`, `image` (used by the articles ticket).
- Fill `backend/src/routes/members.js` with `POST /members`, `POST /members/login`, `GET /user` (mounted under `/api`).
- New tests `backend/test/members.test.js` covering every criterion below with `supertest(createApp())`. For the expired-token case sign a token with `expiresIn: -10`; for the bad-signature case sign with `wrong-secret`; for the unknown-id case sign `{ id: 9999, username: 'ghost' }` with the real secret.
- Parameters: `auth.bcrypt_cost` = 10; `auth.token_ttl` = 24h; `auth.jwt_dev_secret` = conduit-dev-secret; `validation.blank_rule` = missing, not a string, or empty after trimming whitespace; `auth.login_blank_status` = 422 can't be blank per field.
- Values are stored as sent (not trimmed).

## Acceptance Criteria

- [ ] `POST /api/members` with username `newauthor`, email `newauthor@conduit.test`, password `New-Pass-123` returns status 201
- [ ] The register response for `newauthor` has `user.username` equal to `newauthor`
- [ ] The register response for `newauthor` has `user.email` equal to `newauthor@conduit.test`
- [ ] The register response for `newauthor` has `user.bio` equal to `null`
- [ ] The register response for `newauthor` has `user.image` equal to `null`
- [ ] The register response for `newauthor` has a non-empty string in `user.token`
- [ ] The register response for `newauthor` has a `user` object with exactly the keys `email`, `token`, `username`, `bio`, `image`
- [ ] After registering `newauthor`, `POST /api/members/login` with email `newauthor@conduit.test`, password `New-Pass-123` returns status 200
- [ ] After registering `newauthor` then rebuilding the app, `POST /api/members/login` with email `newauthor@conduit.test`, password `New-Pass-123` returns status 401
- [ ] `POST /api/members` with email `a@conduit.test`, password `Pass-123`, no `username` returns status 422 with the body `{"errors":{"username":["can't be blank"]}}`
- [ ] `POST /api/members` with username `alice`, email `""`, password `Pass-123` returns status 422 with the body `{"errors":{"email":["can't be blank"]}}`
- [ ] `POST /api/members` with username `alice`, email `alice@conduit.test`, password `"   "` returns status 422 with the body `{"errors":{"password":["can't be blank"]}}`
- [ ] `POST /api/members` with the body `{}` returns status 422 with the body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}`
- [ ] `POST /api/members` with username `jake2`, email `JAKE@conduit.test`, password `Pass-123` returns status 422 with the body `{"errors":{"email":["has already been taken"]}}`
- [ ] `POST /api/members` with username `jake`, email `other@conduit.test`, password `Pass-123` returns status 422 with the body `{"errors":{"username":["has already been taken"]}}`
- [ ] `POST /api/members` with username `jake`, email `jake@conduit.test`, password `Pass-123` returns status 422 with the body `{"errors":{"email":["has already been taken"],"username":["has already been taken"]}}`
- [ ] `POST /api/members` with username `Jake`, email `capital@conduit.test`, password `Pass-123` returns status 201
- [ ] `POST /api/members/login` with email `jake@conduit.test`, password `Jake-Pass-123` returns status 200
- [ ] The login response for `jake` has `user.username` equal to `jake`
- [ ] The login response for `jake` has a `user` object with exactly the keys `email`, `token`, `username`, `bio`, `image`
- [ ] `POST /api/members/login` with email `jane@conduit.test`, password `Jane-Pass-123` returns status 200
- [ ] `POST /api/members/login` with email `JAKE@conduit.test`, password `Jake-Pass-123` returns status 200
- [ ] `POST /api/members/login` with email `jake@conduit.test`, password `wrong-pass` returns status 401 with the body `{"errors":{"email or password":["is invalid"]}}`
- [ ] `POST /api/members/login` with email `nobody@conduit.test`, password `Jake-Pass-123` returns status 401 with the body `{"errors":{"email or password":["is invalid"]}}`
- [ ] `POST /api/members/login` with email `jake@conduit.test`, no `password` returns status 422 with the body `{"errors":{"password":["can't be blank"]}}`
- [ ] `POST /api/members/login` with email `""`, password `Jake-Pass-123` returns status 422 with the body `{"errors":{"email":["can't be blank"]}}`
- [ ] The token from the `jake` login has header `alg` equal to `HS256`
- [ ] The token from the `jake` login decodes to a payload whose `username` is `jake`
- [ ] The token from the `jake` login decodes to a payload that has an `id` field
- [ ] The token from the `jake` login has `exp` minus `iat` equal to 86400
- [ ] With `JWT_SECRET` unset, the token from the `jake` login verifies with the secret `conduit-dev-secret`
- [ ] With `JWT_SECRET` set to `test-secret`, the token from the `jake` login verifies with the secret `test-secret`
- [ ] `GET /api/user` with header `Authorization: Token <jake login token>` returns status 200
- [ ] `GET /api/user` with the `jake` login token returns `user.username` equal to `jake`
- [ ] `GET /api/user` with the `jake` login token returns `user.token` equal to the presented token
- [ ] `GET /api/user` with the `jake` login token returns a `user` object with exactly the keys `email`, `token`, `username`, `bio`, `image`
- [ ] `GET /api/user` with no `Authorization` header returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with header `Authorization: Bearer <jake login token>` returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with a token for `jake` signed with the secret `wrong-secret` returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with a `jake` token whose `exp` is in the past returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with a validly signed token for `id` 9999 returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`

## Out of Scope

Articles, the frontend pages, profiles, user settings, sign-out, password rules beyond "not blank", and hardening of the development secret.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app backend | `src/store.js`, `src/seed.js`, `src/auth.js`, `src/errors.js`, `src/serializers.js`, `src/routes/members.js`, `test/members.test.js` |

## Test User

`jake@conduit.test` — password `Jake-Pass-123` (seeded author). Second author: `jane@conduit.test` — password `Jane-Pass-123`.

## Navigation Path

No page: exercise the API with supertest in `npm test`, or with curl against `http://localhost:3000`.

## Labels

planned, INIT-0000000000-2767, feature, blocked-by:backend-scaffold

## Signals

```json
{
  "services_identified": 3,
  "symbols_resolved": 6,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "CommonJS Express 5 API built by a createApp() factory with a seeded in-memory store, tested with node:test plus supertest; Vite vanilla JS SPA reaching it through a /api dev proxy.",
  "AffectedServices": "app backend",
  "TargetSymbols": "createApp (new in backend-scaffold):app/backend/src/app.js;usersRouter (new in backend-scaffold):app/backend/src/routes/members.js;createStore (new):app/backend/src/store.js;seedUsers (new):app/backend/src/seed.js;requireAuth (new):app/backend/src/auth.js;blankErrors (new):app/backend/src/errors.js;toUserJSON (new):app/backend/src/serializers.js;usersTest (new):app/backend/test/members.test.js",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `POST /api/members` with username `newauthor`, email `newauthor@conduit.test`, password `New-Pass-123` returns status 201 | anonymous visitor | none | — | `npm test` in `backend/` | status 201 | yes |
| The register response for `newauthor` has `user.username` equal to `newauthor` | anonymous visitor | none | — | `npm test` in `backend/` | `user.username` = `newauthor` | yes |
| The register response for `newauthor` has `user.email` equal to `newauthor@conduit.test` | anonymous visitor | none | — | `npm test` in `backend/` | `user.email` = `newauthor@conduit.test` | yes |
| The register response for `newauthor` has `user.bio` equal to `null` | anonymous visitor | none | — | `npm test` in `backend/` | `user.bio` = `null` | yes |
| The register response for `newauthor` has `user.image` equal to `null` | anonymous visitor | none | — | `npm test` in `backend/` | `user.image` = `null` | yes |
| The register response for `newauthor` has a non-empty string in `user.token` | anonymous visitor | none | — | `npm test` in `backend/` | `user.token` is a string longer than zero | yes |
| The register response for `newauthor` has a `user` object with exactly the keys `email`, `token`, `username`, `bio`, `image` | anonymous visitor | none | — | `npm test` in `backend/` | key set {email, token, username, bio, image}, no `password` key | yes |
| After registering `newauthor`, `POST /api/members/login` with email `newauthor@conduit.test`, password `New-Pass-123` returns status 200 | anonymous visitor | none | — | `npm test` in `backend/` | status 200 | yes |
| After registering `newauthor` then rebuilding the app, `POST /api/members/login` with email `newauthor@conduit.test`, password `New-Pass-123` returns status 401 | anonymous visitor | none | — | `npm test` in `backend/` | status 401 | yes |
| `POST /api/members` with email `a@conduit.test`, password `Pass-123`, no `username` returns status 422 with the body `{"errors":{"username":["can't be blank"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 422, `{"errors":{"username":["can't be blank"]}}` | yes |
| `POST /api/members` with username `alice`, email `""`, password `Pass-123` returns status 422 with the body `{"errors":{"email":["can't be blank"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 422, `{"errors":{"email":["can't be blank"]}}` | yes |
| `POST /api/members` with username `alice`, email `alice@conduit.test`, password `"   "` returns status 422 with the body `{"errors":{"password":["can't be blank"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 422, `{"errors":{"password":["can't be blank"]}}` | yes |
| `POST /api/members` with the body `{}` returns status 422 with the body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 422, all three fields `can't be blank` | yes |
| `POST /api/members` with username `jake2`, email `JAKE@conduit.test`, password `Pass-123` returns status 422 with the body `{"errors":{"email":["has already been taken"]}}` | anonymous visitor | 1 `user` jake with email `jake@conduit.test` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 422, `{"errors":{"email":["has already been taken"]}}` | yes |
| `POST /api/members` with username `jake`, email `other@conduit.test`, password `Pass-123` returns status 422 with the body `{"errors":{"username":["has already been taken"]}}` | anonymous visitor | 1 `user` jake | seeded-by:user-accounts-api | `npm test` in `backend/` | status 422, `{"errors":{"username":["has already been taken"]}}` | yes |
| `POST /api/members` with username `jake`, email `jake@conduit.test`, password `Pass-123` returns status 422 with the body `{"errors":{"email":["has already been taken"],"username":["has already been taken"]}}` | anonymous visitor | 1 `user` jake with email `jake@conduit.test` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 422, both `email` and `username` keys `has already been taken` | yes |
| `POST /api/members` with username `Jake`, email `capital@conduit.test`, password `Pass-123` returns status 201 | anonymous visitor | 1 `user` jake | seeded-by:user-accounts-api | `npm test` in `backend/` | status 201 | yes |
| `POST /api/members/login` with email `jake@conduit.test`, password `Jake-Pass-123` returns status 200 | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 200 | yes |
| The login response for `jake` has `user.username` equal to `jake` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `user.username` = `jake` | yes |
| The login response for `jake` has a `user` object with exactly the keys `email`, `token`, `username`, `bio`, `image` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | key set {email, token, username, bio, image}, no `password` key | yes |
| `POST /api/members/login` with email `jane@conduit.test`, password `Jane-Pass-123` returns status 200 | author jane | 1 `user` jane with password `Jane-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 200 | yes |
| `POST /api/members/login` with email `JAKE@conduit.test`, password `Jake-Pass-123` returns status 200 | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 200 | yes |
| `POST /api/members/login` with email `jake@conduit.test`, password `wrong-pass` returns status 401 with the body `{"errors":{"email or password":["is invalid"]}}` | author jake | 1 `user` jake | seeded-by:user-accounts-api | `npm test` in `backend/` | status 401, `{"errors":{"email or password":["is invalid"]}}` | yes |
| `POST /api/members/login` with email `nobody@conduit.test`, password `Jake-Pass-123` returns status 401 with the body `{"errors":{"email or password":["is invalid"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 401, `{"errors":{"email or password":["is invalid"]}}` | yes |
| `POST /api/members/login` with email `jake@conduit.test`, no `password` returns status 422 with the body `{"errors":{"password":["can't be blank"]}}` | author jake | none | — | `npm test` in `backend/` | status 422, `{"errors":{"password":["can't be blank"]}}` | yes |
| `POST /api/members/login` with email `""`, password `Jake-Pass-123` returns status 422 with the body `{"errors":{"email":["can't be blank"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 422, `{"errors":{"email":["can't be blank"]}}` | yes |
| The token from the `jake` login has header `alg` equal to `HS256` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | decoded header `alg` = `HS256` | yes |
| The token from the `jake` login decodes to a payload whose `username` is `jake` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | payload `username` = `jake` | yes |
| The token from the `jake` login decodes to a payload that has an `id` field | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | payload has key `id` | yes |
| The token from the `jake` login has `exp` minus `iat` equal to 86400 | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `exp - iat` = 86400 | yes |
| With `JWT_SECRET` unset, the token from the `jake` login verifies with the secret `conduit-dev-secret` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `jwt.verify(token, 'conduit-dev-secret')` returns the payload | yes |
| With `JWT_SECRET` set to `test-secret`, the token from the `jake` login verifies with the secret `test-secret` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `jwt.verify(token, 'test-secret')` returns the payload | yes |
| `GET /api/user` with header `Authorization: Token <jake login token>` returns status 200 | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 200 | yes |
| `GET /api/user` with the `jake` login token returns `user.username` equal to `jake` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `user.username` = `jake` | yes |
| `GET /api/user` with the `jake` login token returns `user.token` equal to the presented token | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `user.token` equals the token sent | yes |
| `GET /api/user` with the `jake` login token returns a `user` object with exactly the keys `email`, `token`, `username`, `bio`, `image` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | key set {email, token, username, bio, image}, no `password` key | yes |
| `GET /api/user` with no `Authorization` header returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with header `Authorization: Bearer <jake login token>` returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with a token for `jake` signed with the secret `wrong-secret` returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | author jake | 1 `user` jake | seeded-by:user-accounts-api | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with a `jake` token whose `exp` is in the past returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | author jake | 1 `user` jake | seeded-by:user-accounts-api | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with a validly signed token for `id` 9999 returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |

## Test Data Provided

- 2 `user` records seeded on every app build: `jake` / `jake@conduit.test` / `Jake-Pass-123` and `jane` / `jane@conduit.test` / `Jane-Pass-123`, both with `bio` and `image` `null`, passwords hashed with bcryptjs at cost 10.

## Writes

| Key | Op |
|-----|----|
| `user` | create |

## Reads

None.

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `POST /api/members` with email `a@conduit.test`, password `Pass-123`, no `username` returns status 422 with the body `{"errors":{"username":["can't be blank"]}}` | `user.username` | input | null | — |
| `POST /api/members` with username `alice`, email `""`, password `Pass-123` returns status 422 with the body `{"errors":{"email":["can't be blank"]}}` | `user.email` | input | null | — |
| `POST /api/members` with username `alice`, email `alice@conduit.test`, password `"   "` returns status 422 with the body `{"errors":{"password":["can't be blank"]}}` | `user.password` | input | null | — |
| `POST /api/members/login` with email `jake@conduit.test`, no `password` returns status 422 with the body `{"errors":{"password":["can't be blank"]}}` | `user.password` | input | null | — |
| `POST /api/members/login` with email `""`, password `Jake-Pass-123` returns status 422 with the body `{"errors":{"email":["can't be blank"]}}` | `user.email` | input | null | — |
