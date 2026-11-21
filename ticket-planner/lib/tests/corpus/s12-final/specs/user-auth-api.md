# user-auth-api

## Title

Authors can register, sign in and fetch their account through the API

## Description

## Summary

Add the three account endpoints: register (`POST /api/members`), login (`POST /api/members/login`) and current user (`GET /api/user`). Each returns the same `user` object, which includes a signed token. This ticket also adds the token check every author-only endpoint uses, and the backend tests for every success and error case.

## Outcome

**Serves:** O2

**Who:** Author

**Need:** Create an account and sign in so they can publish.

**Outcome:** A person can register as an author or sign in with an existing account, and the app then shows them as signed in.

## Background / Motivation

Authors must have an account and a token before they can publish, and the web app needs a way to ask "who is signed in?". The brief fixes the request and response shapes, the error bodies, the uniqueness rules and the token rules; this ticket implements them exactly.

## Proposed Behaviour

**Register**: `POST /api/members` with `{"user":{"username","email","password"}}`:

- A valid request returns 201 and `{"user":{"email","token","username","bio","image"}}`. `bio` and `image` are `null` for a new user. The response never contains a `password` field.
- A missing value, a value that is not a string, or a string that is empty after trimming is blank. Every blank field is reported in one 422 response, `{"errors":{"<field>":["can't be blank"]}}`, one key per blank field.
- Blank fields are checked first. Only when no field is blank are the uniqueness rules checked.
- An email already in use, compared ignoring case, returns 422 `{"errors":{"email":["has already been taken"]}}`.
- A username already in use, compared with exact case, returns 422 `{"errors":{"username":["has already been taken"]}}`. A username that differs from an existing one only in case is accepted.

**Login**: `POST /api/members/login` with `{"user":{"email","password"}}`:

- Correct credentials return 200 with the same `user` object. The email is matched ignoring case.
- A blank `email` or `password` returns 422 with `can't be blank` for that field.
- A wrong password returns 401 `{"errors":{"email or password":["is invalid"]}}`.
- An email that belongs to no account returns the same 401 body.

**Current user**: `GET /api/user` with the header `Authorization: Token <jwt>`:

- A valid token returns 200 with the `user` object of the token's user, including a token.
- Each of these returns 401 `{"errors":{"token":["is missing or invalid"]}}`: no `Authorization` header; the `Bearer` scheme instead of `Token`; a value that is not a JWT; a token signed with a different secret; an expired token; a token with `alg` `none`; a token whose user id is not in the store.

**Token**: HS256, signed with `JWT_SECRET` (development default `conduit-dev-secret`), payload `{"id","username"}`, expiring 24 hours after it is issued.

## Technical Context

- Repository `app`, folder `backend/`, built on the app factory, store, seed and error helper from `backend-foundation`.
- Parameters: `auth.bcrypt_cost` (10), `auth.token_lifetime` (24 hours), `auth.jwt_secret_default` (conduit-dev-secret), `validation.blank` (a missing value, a non-string value, or a string that is empty after trimming counts as blank).
- New files:
  - `backend/src/auth.js`: `hashPassword(plain)` / `verifyPassword(plain, hash)` with `bcryptjs` cost 10; `signToken(user, secret)` → `jsonwebtoken.sign({ id, username }, secret, { algorithm: 'HS256', expiresIn: '24h' })`; `verifyToken(token, secret)` → `jsonwebtoken.verify(token, secret, { algorithms: ['HS256'] })`; `requireAuth` middleware that accepts only `Authorization: Token <jwt>`, looks the user up by the payload `id`, sets `req.user = user` and `req.token = token`, and otherwise sends the 401 token body.
  - `backend/src/serializers.js`: `userJson(user, token)` returning only `email`, `token`, `username`, `bio`, `image`; `profileJson(user)` returning only `username`, `bio`, `image` (used by the article ticket).
  - `backend/src/routes/members.js`: the three routes, mounted by `createApp`.
  - `backend/test/members.test.js`, `backend/test/auth.test.js`: one test per acceptance criterion below, using `freshApp()` from `backend/test/helpers.js`. The expired token is signed in the test with a past `exp`; the `alg: none` token is built by hand.
- Store lookups used: `findUserByEmail` (lower-cased compare), `findUserByUsername` (exact compare), `findUserById`, `addUser` from `backend/src/store.js`.

## Acceptance Criteria

- [ ] `POST /api/members` with username `alice`, email `alice@conduit.test` and password `Alice-Pass-123` returns status 201
- [ ] The register response for `alice` has `user.username` equal to `alice`
- [ ] The register response for `alice` has `user.email` equal to `alice@conduit.test`
- [ ] The register response for `alice` has `user.bio` equal to `null`
- [ ] The register response for `alice` has `user.image` equal to `null`
- [ ] The register response for `alice` has a `user.token` that verifies under HS256 with the server secret
- [ ] The decoded register token for `alice` has a payload `username` equal to `alice`
- [ ] The decoded register token for `alice` has a payload `id` of type number
- [ ] The decoded register token for `alice` has `exp` minus `iat` equal to 86400
- [ ] The register response for `alice` contains no `password` key anywhere in the body
- [ ] `POST /api/members` with body `{"user":{}}` returns status 422 with body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}`
- [ ] `POST /api/members` with username `"   "`, email `bob@conduit.test` and password `Bob-Pass-123` returns status 422 with body `{"errors":{"username":["can't be blank"]}}`
- [ ] `POST /api/members` with username `bob`, email `bob@conduit.test` and password set to the number 12345 returns status 422 with body `{"errors":{"password":["can't be blank"]}}`
- [ ] `POST /api/members` with username `jake`, an empty email and password `Bob-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}`
- [ ] `POST /api/members` with username `bob`, email `JAKE@conduit.test` and password `Bob-Pass-123` returns status 422 with body `{"errors":{"email":["has already been taken"]}}`
- [ ] `POST /api/members` with username `jake`, email `bob@conduit.test` and password `Bob-Pass-123` returns status 422 with body `{"errors":{"username":["has already been taken"]}}`
- [ ] `POST /api/members` with username `Jake`, email `jake2@conduit.test` and password `Jake2-Pass-123` returns status 201
- [ ] `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns status 200
- [ ] The login response for `jake` has `user.username` equal to `jake`
- [ ] The login response for `jake` has `user.email` equal to `jake@conduit.test`
- [ ] The login response for `jake` has a non-empty `user.token` string
- [ ] The login response for `jake` contains no `password` key anywhere in the body
- [ ] `POST /api/members/login` with email `JAKE@conduit.test` and password `Jake-Pass-123` returns status 200
- [ ] `POST /api/members/login` with email `jake@conduit.test` and password `wrong-password` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}`
- [ ] `POST /api/members/login` with email `nobody@conduit.test` and password `Jake-Pass-123` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}`
- [ ] `POST /api/members/login` with an empty email and password `Jake-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}`
- [ ] `POST /api/members/login` with email `jake@conduit.test` and an empty password returns status 422 with body `{"errors":{"password":["can't be blank"]}}`
- [ ] `GET /api/user` with header `Authorization: Token <jake's login token>` returns status 200
- [ ] `GET /api/user` with jake's login token returns `user.username` equal to `jake`
- [ ] `GET /api/user` with jake's login token returns a non-empty `user.token` string
- [ ] `GET /api/user` with jake's login token returns a body with no `password` key
- [ ] `GET /api/user` with no `Authorization` header returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with header `Authorization: Bearer <jake's login token>` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with header `Authorization: Token not-a-jwt` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with a token for jake signed with the secret `other-secret` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with a token for jake whose `exp` is in the past returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with an unsigned token for jake whose header has `alg` `none` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with a validly signed token whose `id` is 9999 returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `npm test` in `backend/` exits with code 0 with the register, login and current-user tests included
- [ ] `POST /api/members` with an existing author's username, that author's email in upper case and a non-blank password returns status 422 with body `{"errors":{"email":["has already been taken"],"username":["has already been taken"]}}`

## Out of Scope

Article endpoints, profile and settings endpoints, sign-out on the server, and any page in the frontend.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/src/auth.js`, `backend/src/serializers.js`, `backend/src/routes/members.js`, user and auth tests |

- Assumption: A register request whose email and username are both already taken returns one 422 response that lists both the email and the username error, the same way every blank field is reported together.

## Test User

`jake@conduit.test` — password `Jake-Pass-123`

## Environment

- [x] Local (`http://localhost:3000` for the API)

## Labels

planned, INIT-0000000000-5856, feature, blocked-by:backend-foundation

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "Add register, login and current-user routes with bcryptjs hashing, HS256 jsonwebtoken tokens and a requireAuth middleware that accepts only the Token scheme.",
  "AffectedServices": "app",
  "TargetSymbols": "requireAuth (new):app/backend/src/auth.js;userJson (new):app/backend/src/serializers.js;usersRouter (new):app/backend/src/routes/members.js;createApp (new in backend-foundation):app/backend/src/app.js;createStore (new in backend-foundation):app/backend/src/store.js",
  "Kind": "business",
  "Serves": ["O2"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `POST /api/members` with username `alice`, email `alice@conduit.test` and password `Alice-Pass-123` returns status 201 | anonymous reader | none | — | HTTP client | status 201 | yes |
| The register response for `alice` has `user.username` equal to `alice` | anonymous reader | none | — | HTTP client | `alice` | yes |
| The register response for `alice` has `user.email` equal to `alice@conduit.test` | anonymous reader | none | — | HTTP client | `alice@conduit.test` | yes |
| The register response for `alice` has `user.bio` equal to `null` | anonymous reader | none | — | HTTP client | `null` | yes |
| The register response for `alice` has `user.image` equal to `null` | anonymous reader | none | — | HTTP client | `null` | yes |
| The register response for `alice` has a `user.token` that verifies under HS256 with the server secret | anonymous reader | none | — | HTTP client | `jsonwebtoken.verify` succeeds with `algorithms: ['HS256']` | yes |
| The decoded register token for `alice` has a payload `username` equal to `alice` | anonymous reader | none | — | HTTP client | `alice` | yes |
| The decoded register token for `alice` has a payload `id` of type number | anonymous reader | none | — | HTTP client | `typeof id` is `number` | yes |
| The decoded register token for `alice` has `exp` minus `iat` equal to 86400 | anonymous reader | none | — | HTTP client | 86400 | yes |
| The register response for `alice` contains no `password` key anywhere in the body | anonymous reader | none | — | HTTP client | no key named `password` | yes |
| `POST /api/members` with body `{"user":{}}` returns status 422 with body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}` | anonymous reader | none | — | HTTP client | status 422 with that exact body | yes |
| `POST /api/members` with username `"   "`, email `bob@conduit.test` and password `Bob-Pass-123` returns status 422 with body `{"errors":{"username":["can't be blank"]}}` | anonymous reader | none | — | HTTP client | status 422 with that exact body | yes |
| `POST /api/members` with username `bob`, email `bob@conduit.test` and password set to the number 12345 returns status 422 with body `{"errors":{"password":["can't be blank"]}}` | anonymous reader | none | — | HTTP client | status 422 with that exact body | yes |
| `POST /api/members` with username `jake`, an empty email and password `Bob-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}` | anonymous reader | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with only the `email` error | yes |
| `POST /api/members` with username `bob`, email `JAKE@conduit.test` and password `Bob-Pass-123` returns status 422 with body `{"errors":{"email":["has already been taken"]}}` | anonymous reader | 1 `user` `jake` with email `jake@conduit.test` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body | yes |
| `POST /api/members` with username `jake`, email `bob@conduit.test` and password `Bob-Pass-123` returns status 422 with body `{"errors":{"username":["has already been taken"]}}` | anonymous reader | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body | yes |
| `POST /api/members` with username `Jake`, email `jake2@conduit.test` and password `Jake2-Pass-123` returns status 201 | anonymous reader | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 201 | yes |
| `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns status 200 | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 200 | yes |
| The login response for `jake` has `user.username` equal to `jake` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `jake` | yes |
| The login response for `jake` has `user.email` equal to `jake@conduit.test` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `jake@conduit.test` | yes |
| The login response for `jake` has a non-empty `user.token` string | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | a string of length greater than zero | yes |
| The login response for `jake` contains no `password` key anywhere in the body | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | no key named `password` | yes |
| `POST /api/members/login` with email `JAKE@conduit.test` and password `Jake-Pass-123` returns status 200 | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 200 | yes |
| `POST /api/members/login` with email `jake@conduit.test` and password `wrong-password` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 401 with that exact body | yes |
| `POST /api/members/login` with email `nobody@conduit.test` and password `Jake-Pass-123` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}` | anonymous reader | none | — | HTTP client | status 401 with that exact body | yes |
| `POST /api/members/login` with an empty email and password `Jake-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}` | anonymous reader | none | — | HTTP client | status 422 with that exact body | yes |
| `POST /api/members/login` with email `jake@conduit.test` and an empty password returns status 422 with body `{"errors":{"password":["can't be blank"]}}` | anonymous reader | none | — | HTTP client | status 422 with that exact body | yes |
| `GET /api/user` with header `Authorization: Token <jake's login token>` returns status 200 | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 200 | yes |
| `GET /api/user` with jake's login token returns `user.username` equal to `jake` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `jake` | yes |
| `GET /api/user` with jake's login token returns a non-empty `user.token` string | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | a string of length greater than zero | yes |
| `GET /api/user` with jake's login token returns a body with no `password` key | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | no key named `password` | yes |
| `GET /api/user` with no `Authorization` header returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | HTTP client | status 401 with that exact body | yes |
| `GET /api/user` with header `Authorization: Bearer <jake's login token>` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 401 with that exact body | yes |
| `GET /api/user` with header `Authorization: Token not-a-jwt` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | HTTP client | status 401 with that exact body | yes |
| `GET /api/user` with a token for jake signed with the secret `other-secret` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 401 with that exact body | yes |
| `GET /api/user` with a token for jake whose `exp` is in the past returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 401 with that exact body | yes |
| `GET /api/user` with an unsigned token for jake whose header has `alg` `none` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 401 with that exact body | yes |
| `GET /api/user` with a validly signed token whose `id` is 9999 returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | HTTP client | status 401 with that exact body | yes |
| `npm test` in `backend/` exits with code 0 with the register, login and current-user tests included | developer | 2 seeded `user` records | seeded-by:backend-foundation | terminal in `backend/` | exit code 0 | yes |
| `POST /api/members` with an existing author's username, that author's email in upper case and a non-blank password returns status 422 with body `{"errors":{"email":["has already been taken"],"username":["has already been taken"]}}` | anonymous reader | 1 `user` `jake` with email `jake@conduit.test` | seeded-by:backend-foundation | HTTP client | status 422 with both keys, each with `has already been taken` | yes |

## Writes

| Key | Op |
|-----|----|
| `user` | append |

## Reads

| Key | Source |
|-----|--------|
| `user.id` | spec |
| `user.email` | spec |
| `user.username` | spec |
| `user.password_hash` | spec |
| `user.bio` | spec |
| `user.image` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `POST /api/members` with username `bob`, email `JAKE@conduit.test` and password `Bob-Pass-123` returns status 422 with body `{"errors":{"email":["has already been taken"]}}` | `user.username` | state | value:jake | spec:backend-foundation |
| `POST /api/members` with username `jake`, email `bob@conduit.test` and password `Bob-Pass-123` returns status 422 with body `{"errors":{"username":["has already been taken"]}}` | `user.username` | state | value:jake | spec:backend-foundation |
| `POST /api/members` with username `Jake`, email `jake2@conduit.test` and password `Jake2-Pass-123` returns status 201 | `user.username` | state | value:jake | spec:backend-foundation |
| `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns status 200 | `user.username` | state | value:jake | spec:backend-foundation |
| `POST /api/members/login` with email `jake@conduit.test` and password `wrong-password` returns status 401 with body `{"errors":{"email or password":["is invalid"]}}` | `user.username` | state | value:jake | spec:backend-foundation |
| `POST /api/members/login` with an empty email and password `Jake-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}` | `user.email` | input | null | — |
| `POST /api/members/login` with email `jake@conduit.test` and an empty password returns status 422 with body `{"errors":{"password":["can't be blank"]}}` | `user.password_hash` | input | null | — |
| `POST /api/members` with username `jake`, an empty email and password `Bob-Pass-123` returns status 422 with body `{"errors":{"email":["can't be blank"]}}` | `user.email` | input | null | — |
| `GET /api/user` with header `Authorization: Token <jake's login token>` returns status 200 | `user.username` | state | value:jake | spec:backend-foundation |
