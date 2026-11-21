# backend-auth

## Title

Authors can register, sign in and fetch their account through the API

## Description

## Summary

Add the three account endpoints: register (`POST /api/members`), login (`POST /api/members/login`) and current user (`GET /api/user`), with every validation and token error the brief lists. Seed the two authors `jake` and `jane` on every server start.

## Outcome

**Serves:** O1

**Who:** Author

**Need:** Have an account to sign in with before publishing.

**Outcome:** A person can register as an author and sign in, and the app shows who is signed in.

## Background / Motivation

Publishing is limited to signed-in authors, so the API has to create accounts, check passwords and issue tokens before any article or page work can use them. The brief fixes the request and response shapes, the error bodies, the password hashing and the token format.

## Proposed Behaviour

**Register.** `POST /api/members` with `{"user":{"username","email","password"}}` creates the user and returns 201 with `{"user":{"email","token","username","bio","image"}}`. `bio` and `image` are `null` for a new user. The `user` object carries exactly those five keys, so no password or hash ever appears.

- If `username`, `email` or `password` is missing or an empty string, the response is 422 and `errors` lists every blank field, each with `["can't be blank"]`.
- A body with no `user` object (for example `{}`), or a request with no body at all, counts as a `user` object with every field blank: 422 listing `username`, `email` and `password`.
- Blank checks run first. Only when no field is blank does the uniqueness check run.
- If the email is already used, compared without regard to case, the response is 422 `{"errors":{"email":["has already been taken"]}}`.
- If the username is already used, compared with case, the response is 422 `{"errors":{"username":["has already been taken"]}}`. A username that differs only in case is accepted.

**Login.** `POST /api/members/login` with `{"user":{"email","password"}}` returns 200 with the same `user` shape when the password matches. The email lookup ignores case.

- A missing or empty `email` or `password` returns 422 with `can't be blank` for that field.
- A body with no `user` object counts as both fields blank: 422 listing `email` and `password`.
- An unknown email or a wrong password returns 401 `{"errors":{"email or password":["is invalid"]}}`.

**Current user.** `GET /api/user` with `Authorization: Token <jwt>` returns 200 with the `user` shape for the token's user. `user.token` is the same token the request presented.

- A missing header, a scheme other than `Token`, a malformed token, a token signed with another secret, or an expired token returns 401 `{"errors":{"token":["is missing or invalid"]}}`.

**Tokens.** Tokens are signed with HS256, carry the payload `{"id","username"}`, and expire 24h after they are issued. The secret comes from `JWT_SECRET`, read each time a token is signed or checked; when it is unset the server uses `conduit-dev-secret` and prints a warning naming `JWT_SECRET` when it starts.

**Seed.** Every server start, and every store reset, loads two authors: `jake` (`jake@conduit.test`, password `Jake-Pass-123`) and `jane` (`jane@conduit.test`, password `Jane-Pass-123`), both with `bio` and `image` null. A user registered before a restart is gone after it. A live restart is `bash scripts/env-start.sh` (from `backend-scaffold`), which always restarts the backend.

## Technical Context

- Repository `app`, folder `backend/`. Builds on `app.js`, `server.js`, `store.js` and `errors.js` from `backend-scaffold`.
- Add dependencies `bcryptjs` and `jsonwebtoken` to `backend/package.json`.
- `backend/auth.js`: `hashPassword` and `comparePassword` with `bcryptjs` at cost 10 (parameter `auth.bcrypt_cost`); `signToken(user)` with `jsonwebtoken`, algorithm HS256, payload `{id, username}`, `expiresIn: '24h'` (parameter `auth.jwt_expiry`); secret `process.env.JWT_SECRET || 'conduit-dev-secret'` (parameter `auth.jwt_secret_default`), evaluated inside `signToken` and inside `requireAuth` on every call, never once at module load, so one Jest run can test both the set and the unset case; `requireAuth` middleware that reads `Authorization`, accepts only the `Token ` scheme, verifies the token with `algorithms: ['HS256']`, loads the user by `id` from the store, and sets req.user and req.token. Any failure responds 401 with `errorBody({token: ['is missing or invalid']})`. `requireAuth` is exported for `backend-articles-publish`.
- `backend/serializers.js`: `toUserJSON(user, token)` returns exactly `{email, token, username, bio, image}`. Never spread the stored record.
- `backend/routes/members.js`: mounts `POST /api/members`, `POST /api/members/login` and `GET /api/user` (with `requireAuth`) on the `/api` router in `app.js`.
- Store: each user record is `{id, username, email, passwordHash, bio: null, image: null}`. `id` is an increasing integer. Email uniqueness and login compare `email.toLowerCase()`; username compares exactly (parameter `auth.login_email_match`). Store the email as given.
- Validation (parameter `validation.blank_fields_report`): read the fields from `(req.body && req.body.user) || {}`, because Express 5 leaves the parsed body undefined when a request has no JSON body. A field is blank when it is missing, not a string, or `""`. Collect every blank field into one `errors` object first; if any, respond 422. Then check email, then username uniqueness; both duplicates may be reported together.
- Seed: push `jake` and `jane` into `store.seedUsers` with password hashes computed once at module load, so `reset()` does not re-hash on every test.
- `server.js`: when `process.env.JWT_SECRET` is unset, log a warning line that contains `JWT_SECRET` before listening (parameter `auth.jwt_secret_outside_dev`).
- Current user echoes the presented token (parameter `auth.current_user_token`).
- Tests: `backend/tests/members.test.js`, supertest against the app, `store.reset()` in `beforeEach`. Build the expired token with `jsonwebtoken` and a negative `expiresIn`, and the wrong-signature token with a different secret. The two `JWT_SECRET` tests save `process.env.JWT_SECRET`, set or delete it inside the test, and restore it in `afterEach`, so the pipeline host's own value never decides the result.
- The restart criterion is a live check: it runs against the backend that `scripts/env-start.sh` (new in `backend-scaffold`) started, and restarts it by running that script again.

## Acceptance Criteria

- [ ] `POST /api/members` with username `alice`, email `alice@conduit.test` and password `Alice-Pass-123` returns status 201.
- [ ] The 201 register response for `alice` has `user.email` equal to `alice@conduit.test`.
- [ ] The 201 register response for `alice` has `user.username` equal to `alice`.
- [ ] The 201 register response for `alice` has `user.bio` equal to null.
- [ ] The 201 register response for `alice` has `user.image` equal to null.
- [ ] The 201 register response for `alice` has a non-empty string in `user.token`.
- [ ] The 201 register response for `alice` has exactly the keys `email`, `token`, `username`, `bio`, `image` under `user`.
- [ ] `POST /api/members` without a `username` field returns status 422 with body `{"errors":{"username":["can't be blank"]}}`.
- [ ] `POST /api/members` with `email` set to an empty string returns status 422 with body `{"errors":{"email":["can't be blank"]}}`.
- [ ] `POST /api/members` without a `password` field returns status 422 with body `{"errors":{"password":["can't be blank"]}}`.
- [ ] `POST /api/members` with an empty `user` object returns status 422 with an `errors` object holding exactly the keys `username`, `email`, `password`, each `["can't be blank"]`.
- [ ] `POST /api/members` with body `{}`, which has no `user` object, returns status 422 with an `errors` object holding exactly the keys `username`, `email`, `password`, each `["can't be blank"]`.
- [ ] `POST /api/members` with no request body and no `Content-Type` header returns status 422 with an `errors` object holding exactly the keys `username`, `email`, `password`, each `["can't be blank"]`.
- [ ] `POST /api/members` with username `jake`, an empty email and password `Alice-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}`.
- [ ] `POST /api/members` with username `alice`, email `JAKE@conduit.test` and password `Alice-Pass-123` returns status 422 with body `{"errors":{"email":["has already been taken"]}}`.
- [ ] `POST /api/members` with username `jake`, email `alice@conduit.test` and password `Alice-Pass-123` returns status 422 with body `{"errors":{"username":["has already been taken"]}}`.
- [ ] `POST /api/members` with username `Jake`, email `capital@conduit.test` and password `Alice-Pass-123` returns status 201.
- [ ] `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns status 200.
- [ ] The 200 login response for `jake` has `user.username` equal to `jake`.
- [ ] The 200 login response for `jake` has exactly the keys `email`, `token`, `username`, `bio`, `image` under `user`.
- [ ] `POST /api/members/login` with email `jane@conduit.test` and password `Jane-Pass-123` returns status 200.
- [ ] `POST /api/members/login` with email `JAKE@conduit.test` and password `Jake-Pass-123` returns status 200.
- [ ] `POST /api/members/login` with email `jake@conduit.test` and password `Wrong-Pass-1` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}`.
- [ ] `POST /api/members/login` with email `nobody@conduit.test` and password `Jake-Pass-123` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}`.
- [ ] `POST /api/members/login` without an `email` field returns status 422 with body `{"errors":{"email":["can't be blank"]}}`.
- [ ] `POST /api/members/login` with email `jake@conduit.test` and an empty password returns status 422 with body `{"errors":{"password":["can't be blank"]}}`.
- [ ] `POST /api/members/login` with body `{}`, which has no `user` object, returns status 422 with an `errors` object holding exactly the keys `email`, `password`, each `["can't be blank"]`.
- [ ] The token from a `jake` login has a header whose `alg` is `HS256`.
- [ ] The token from a `jake` login decodes to a payload whose `username` is `jake`.
- [ ] The token from a `jake` login decodes to a payload that has an `id` field.
- [ ] The token from a `jake` login has an `exp` claim 24h after its `iat` claim.
- [ ] With `JWT_SECRET` unset, the token from a `jake` login verifies with the secret `conduit-dev-secret`.
- [ ] With `JWT_SECRET=test-secret` set, the token from a `jake` login verifies with the secret `test-secret`.
- [ ] With `JWT_SECRET` unset, `npm start` in `backend/` prints a warning line containing `JWT_SECRET`.
- [ ] With `JWT_SECRET=test-secret` set, `npm start` in `backend/` prints no line containing `JWT_SECRET`.
- [ ] `GET /api/user` with header `Authorization: Token <jake's login token>` returns status 200.
- [ ] The 200 current-user response for `jake` has `user.username` equal to `jake`.
- [ ] The 200 current-user response for `jake` has `user.token` equal to the token sent in the request.
- [ ] The 200 current-user response for `jake` has exactly the keys `email`, `token`, `username`, `bio`, `image` under `user`.
- [ ] `GET /api/user` with no `Authorization` header returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with header `Authorization: Bearer <jake's login token>` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with header `Authorization: Token not-a-jwt` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with a `jake` token signed with the secret `other-secret` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with an expired `jake` token returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] After `alice` registers against the backend that `bash scripts/env-start.sh` started, and the script then runs again, `POST /api/members/login` with email `alice@conduit.test` and password `Alice-Pass-123` returns status 401.
- [ ] `GET /api/user` with an unexpired token signed with the server's secret, whose payload `id` belongs to a registered author but whose payload `username` differs from that author's username, returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] After a newly registered author keeps the token from its register response, `bash scripts/env-start.sh` runs again and a second new author with a different username registers, `GET /api/user` with the kept token returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.

## Out of Scope

- User settings, profiles, follow, sign-out.
- Article endpoints (later tickets reuse `requireAuth`).
- Requiring `JWT_SECRET` outside development (a warning only).

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/auth.js`, `backend/serializers.js`, `backend/routes/members.js`, user seed in `backend/store.js`, `backend/tests/members.test.js` |

- Assumption: When checking a token, the server also requires the token username to equal the username of the stored user with the token id, so a token issued before a restart never authenticates a different user.

## Test User

`jake@conduit.test` (Author) — password `Jake-Pass-123`. Second author: `jane@conduit.test` — password `Jane-Pass-123`.

## Navigation Path

No UI: exercise the endpoints with `npm test` in `backend/`. Live checks (the `npm start` warning lines and the restart criterion) use an HTTP client against the backend that `bash scripts/env-start.sh` starts from the repo root; running the script again restarts the backend and puts the store back to the seed.

## Test Data Provided

- 2 `user` records in state registered, loaded on every server start and every `store.reset()`: `jake` / `jake@conduit.test` / `Jake-Pass-123` and `jane` / `jane@conduit.test` / `Jane-Pass-123`, both with `bio` and `image` null.
- Test-built tokens for `jake`: one expired, one signed with `other-secret`.

## Labels

planned, INIT-0000000000-5252, feature, blocked-by:backend-scaffold

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Implement register, login and current user on the Express app with bcryptjs at cost 10, jsonwebtoken HS256 tokens and a requireAuth middleware for the Token scheme.",
  "AffectedServices": "app",
  "TargetSymbols": "requireAuth (new):app/backend/auth.js;toUserJSON (new):app/backend/serializers.js;users (new):app/backend/routes/members.js;store (new in backend-scaffold):app/backend/store.js;server (new in backend-scaffold):app/backend/server.js;usersTest (new):app/backend/tests/members.test.js;envStart (new in backend-scaffold):app/scripts/env-start.sh",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `POST /api/members` with username `alice`, email `alice@conduit.test` and password `Alice-Pass-123` returns status 201. | anonymous reader | none | — | | status 201 | yes |
| The 201 register response for `alice` has `user.email` equal to `alice@conduit.test`. | anonymous reader | none | — | | `alice@conduit.test` | yes |
| The 201 register response for `alice` has `user.username` equal to `alice`. | anonymous reader | none | — | | `alice` | yes |
| The 201 register response for `alice` has `user.bio` equal to null. | anonymous reader | none | — | | null | yes |
| The 201 register response for `alice` has `user.image` equal to null. | anonymous reader | none | — | | null | yes |
| The 201 register response for `alice` has a non-empty string in `user.token`. | anonymous reader | none | — | | string of length 1 or more | yes |
| The 201 register response for `alice` has exactly the keys `email`, `token`, `username`, `bio`, `image` under `user`. | anonymous reader | none | — | | key set equals email, token, username, bio, image | yes |
| `POST /api/members` without a `username` field returns status 422 with body `{"errors":{"username":["can't be blank"]}}`. | anonymous reader | none | — | | 422, `{"errors":{"username":["can't be blank"]}}` | yes |
| `POST /api/members` with `email` set to an empty string returns status 422 with body `{"errors":{"email":["can't be blank"]}}`. | anonymous reader | none | — | | 422, `{"errors":{"email":["can't be blank"]}}` | yes |
| `POST /api/members` without a `password` field returns status 422 with body `{"errors":{"password":["can't be blank"]}}`. | anonymous reader | none | — | | 422, `{"errors":{"password":["can't be blank"]}}` | yes |
| `POST /api/members` with an empty `user` object returns status 422 with an `errors` object holding exactly the keys `username`, `email`, `password`, each `["can't be blank"]`. | anonymous reader | none | — | | 422, three keys each `["can't be blank"]` | yes |
| `POST /api/members` with body `{}`, which has no `user` object, returns status 422 with an `errors` object holding exactly the keys `username`, `email`, `password`, each `["can't be blank"]`. | anonymous reader | none | — | | 422, three keys each `["can't be blank"]` | yes |
| `POST /api/members` with no request body and no `Content-Type` header returns status 422 with an `errors` object holding exactly the keys `username`, `email`, `password`, each `["can't be blank"]`. | anonymous reader | none | — | | 422, three keys each `["can't be blank"]` | yes |
| `POST /api/members` with username `jake`, an empty email and password `Alice-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}`. | anonymous reader | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 422, `{"errors":{"email":["can't be blank"]}}` with no `username` key | yes |
| `POST /api/members` with username `alice`, email `JAKE@conduit.test` and password `Alice-Pass-123` returns status 422 with body `{"errors":{"email":["has already been taken"]}}`. | anonymous reader | 1 `user` in state registered (`jake`, `jake@conduit.test`) | seeded-by:backend-auth | | 422, `{"errors":{"email":["has already been taken"]}}` | yes |
| `POST /api/members` with username `jake`, email `alice@conduit.test` and password `Alice-Pass-123` returns status 422 with body `{"errors":{"username":["has already been taken"]}}`. | anonymous reader | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 422, `{"errors":{"username":["has already been taken"]}}` | yes |
| `POST /api/members` with username `Jake`, email `capital@conduit.test` and password `Alice-Pass-123` returns status 201. | anonymous reader | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | status 201 | yes |
| `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns status 200. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | status 200 | yes |
| The 200 login response for `jake` has `user.username` equal to `jake`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `jake` | yes |
| The 200 login response for `jake` has exactly the keys `email`, `token`, `username`, `bio`, `image` under `user`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | key set equals email, token, username, bio, image | yes |
| `POST /api/members/login` with email `jane@conduit.test` and password `Jane-Pass-123` returns status 200. | author | 1 `user` in state registered (`jane`) | seeded-by:backend-auth | | status 200 | yes |
| `POST /api/members/login` with email `JAKE@conduit.test` and password `Jake-Pass-123` returns status 200. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | status 200 | yes |
| `POST /api/members/login` with email `jake@conduit.test` and password `Wrong-Pass-1` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 401, `{"errors":{"email or password":["is invalid"]}}` | yes |
| `POST /api/members/login` with email `nobody@conduit.test` and password `Jake-Pass-123` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}`. | anonymous reader | none | — | | 401, `{"errors":{"email or password":["is invalid"]}}` | yes |
| `POST /api/members/login` without an `email` field returns status 422 with body `{"errors":{"email":["can't be blank"]}}`. | anonymous reader | none | — | | 422, `{"errors":{"email":["can't be blank"]}}` | yes |
| `POST /api/members/login` with email `jake@conduit.test` and an empty password returns status 422 with body `{"errors":{"password":["can't be blank"]}}`. | anonymous reader | none | — | | 422, `{"errors":{"password":["can't be blank"]}}` | yes |
| `POST /api/members/login` with body `{}`, which has no `user` object, returns status 422 with an `errors` object holding exactly the keys `email`, `password`, each `["can't be blank"]`. | anonymous reader | none | — | | 422, two keys each `["can't be blank"]` | yes |
| The token from a `jake` login has a header whose `alg` is `HS256`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `HS256` | yes |
| The token from a `jake` login decodes to a payload whose `username` is `jake`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `jake` | yes |
| The token from a `jake` login decodes to a payload that has an `id` field. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | payload has key `id` | yes |
| The token from a `jake` login has an `exp` claim 24h after its `iat` claim. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `exp` minus `iat` equals 24h | yes |
| With `JWT_SECRET` unset, the token from a `jake` login verifies with the secret `conduit-dev-secret`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | `npm test`; the test deletes `JWT_SECRET` and restores it afterwards | verification succeeds | yes |
| With `JWT_SECRET=test-secret` set, the token from a `jake` login verifies with the secret `test-secret`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | the same `npm test` run; the test sets `JWT_SECRET` and restores it afterwards | verification succeeds | yes |
| With `JWT_SECRET` unset, `npm start` in `backend/` prints a warning line containing `JWT_SECRET`. | developer | none | — | | console output has a line containing `JWT_SECRET` | yes |
| With `JWT_SECRET=test-secret` set, `npm start` in `backend/` prints no line containing `JWT_SECRET`. | developer | none | — | | no console line contains `JWT_SECRET` | yes |
| `GET /api/user` with header `Authorization: Token <jake's login token>` returns status 200. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | status 200 | yes |
| The 200 current-user response for `jake` has `user.username` equal to `jake`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `jake` | yes |
| The 200 current-user response for `jake` has `user.token` equal to the token sent in the request. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | same string as the request token | yes |
| The 200 current-user response for `jake` has exactly the keys `email`, `token`, `username`, `bio`, `image` under `user`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | key set equals email, token, username, bio, image | yes |
| `GET /api/user` with no `Authorization` header returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | anonymous reader | none | — | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with header `Authorization: Bearer <jake's login token>` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with header `Authorization: Token not-a-jwt` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | anonymous reader | none | — | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with a `jake` token signed with the secret `other-secret` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | author | a `jake` token signed with `other-secret`, for 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with an expired `jake` token returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | author | an expired `jake` token, for 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| After `alice` registers against the backend that `bash scripts/env-start.sh` started, and the script then runs again, `POST /api/members/login` with email `alice@conduit.test` and password `Alice-Pass-123` returns status 401. | anonymous reader | 1 `user` in state registered (`alice`), created by register against the running backend before the second script run | seeded-by:backend-auth | run `bash scripts/env-start.sh`, register `alice`, run the script again, then log in as `alice` | status 401 | yes |
| `GET /api/user` with an unexpired token signed with the server's secret, whose payload `id` belongs to a registered author but whose payload `username` differs from that author's username, returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | author | 1 `user` in state registered, and a test-built token signed with the server's secret carrying that user's `id` and a different username | seeded-by:backend-auth | `npm test`; the test builds the token with `jsonwebtoken` | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| After a newly registered author keeps the token from its register response, `bash scripts/env-start.sh` runs again and a second new author with a different username registers, `GET /api/user` with the kept token returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | author | 2 `user` records created by register against the running backend, the first before and the second after the second script run, with different usernames | seeded-by:backend-auth | run `bash scripts/env-start.sh`, register the first author and keep its token, run the script again, register the second author, then call `GET /api/user` with the kept token | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |

## Writes

| Key | Op |
|-----|----|
| `user` | create |

## Reads

None.

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `POST /api/members` without a `username` field returns status 422 with body `{"errors":{"username":["can't be blank"]}}`. | `user.username` | input | null | — |
| `POST /api/members` with `email` set to an empty string returns status 422 with body `{"errors":{"email":["can't be blank"]}}`. | `user.email` | input | null | — |
| `POST /api/members` without a `password` field returns status 422 with body `{"errors":{"password":["can't be blank"]}}`. | `user.password` | input | null | — |
| `POST /api/members` with username `jake`, an empty email and password `Alice-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}`. | `user.username` | state | value:jake | spec:backend-auth |
| `POST /api/members` with username `alice`, email `JAKE@conduit.test` and password `Alice-Pass-123` returns status 422 with body `{"errors":{"email":["has already been taken"]}}`. | `user.username` | state | value:jake | spec:backend-auth |
| `POST /api/members` with username `jake`, email `alice@conduit.test` and password `Alice-Pass-123` returns status 422 with body `{"errors":{"username":["has already been taken"]}}`. | `user.username` | state | value:jake | spec:backend-auth |
| `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns status 200. | `user.username` | state | value:jake | spec:backend-auth |
| `POST /api/members/login` with email `jane@conduit.test` and password `Jane-Pass-123` returns status 200. | `user.username` | state | value:jane | spec:backend-auth |
| `POST /api/members/login` without an `email` field returns status 422 with body `{"errors":{"email":["can't be blank"]}}`. | `user.email` | input | null | — |
| `POST /api/members/login` with email `jake@conduit.test` and an empty password returns status 422 with body `{"errors":{"password":["can't be blank"]}}`. | `user.password` | input | null | — |
| `GET /api/user` with header `Authorization: Token <jake's login token>` returns status 200. | `user.username` | state | value:jake | spec:backend-auth |
