# api-user-auth

## Title

Authors can register, sign in and fetch their account through the API

## Description

## Summary

Add the three account endpoints: register a new author, sign in with email and password, and fetch the signed-in author's account with a token. Also add the shared token check that the article create endpoint will reuse.

## Outcome

**Serves:** O1

**Who:** Author

**Need:** Create an account and sign in, so the app knows who is publishing.

**Outcome:** A person can register as an author, sign in with their email and password, and the app then shows them as signed in.

## Background / Motivation

Only signed-in authors may publish. Before the frontend can show a signed-in header or an editor, the API has to create accounts, check passwords and issue a token the browser can send back. The brief requires `npm test` in `backend/` to cover every endpoint, including each error case.

## Proposed Behaviour

- **Register.** A request with `{"user":{"username","email","password"}}` creates the author and returns status 201 with `{"user":{"email","token","username","bio","image"}}`. `bio` and `image` are `null` for a new author.
- **Sign in.** A request with `{"user":{"email","password"}}` returns status 200 with the same `user` shape. The email is matched without regard to letter case.
- **Current user.** A request with the header `Authorization: Token <jwt>` returns status 200 with the same `user` shape for the author the token names.
- **Blank fields.** A field that is missing, not a string, or empty after trimming spaces is blank. Each blank field gets `can't be blank` in a status 422 body `{"errors":{"<field>":["can't be blank"]}}`, and every blank field is listed in the same body. A body that is not valid JSON, or that has no `user` object, counts as all fields blank.
- **Duplicates.** An email already in use, compared without regard to letter case, gets status 422 with `{"errors":{"email":["has already been taken"]}}`. A username already in use, compared with exact letter case, gets status 422 with `{"errors":{"username":["has already been taken"]}}`. So `Jake` can register while `jake` exists.
- **Wrong credentials.** A wrong password, or an email nobody has, gets status 401 with `{"errors":{"email or password":["is invalid"]}}`.
- **Bad token.** On the current-user endpoint, a missing header, a scheme other than `Token`, a token with a bad signature, an expired token, or a token naming an author who is not in the store gets status 401 with `{"errors":{"token":["is missing or invalid"]}}`.
- **Token.** The token is signed with HS256. Its payload holds the author's `id` and `username`. It expires 24h after it is issued. The signing secret is the `JWT_SECRET` environment variable, or `conduit-dev-secret` when that variable is unset.
- **Passwords.** Passwords are stored only as bcrypt hashes with cost 10. No response contains a password or a hash.

## Technical Context

- Builds on `backend-foundation`: `createApp()` in `backend/src/app.js`, the store with `reset()` and `insertUser()` in `backend/src/store.js`, the seeded authors in `backend/src/seed.js`, and the error helpers `validationError` and `sendError` in `backend/src/errors.js`. The JSON parse shim in `createApp()` already turns malformed JSON into an empty body (`request.body.malformed_json`).
- Add `backend/src/auth.js`:
  - `hashPassword(plain)` with `bcryptjs` at cost 10 (`auth.bcrypt.cost`) and `checkPassword(plain, hash)`.
  - `signToken(user)` with `jsonwebtoken`, algorithm HS256, `expiresIn: '24h'` (`auth.jwt.expiry`), payload `{id, username}`, secret `process.env.JWT_SECRET || 'conduit-dev-secret'` (`auth.jwt.dev_secret`). The secret is read at call time so tests can set it.
  - `verifyToken(token)` and `requireAuth` middleware. `requireAuth` accepts only `Authorization: Token <jwt>` (`auth.token.scheme`), verifies it, looks the `id` up in the store, and attaches the matching author to the request. Any failure sends the 401 token body. The article create ticket mounts this same middleware.
- Add `backend/src/routes/members.js` with `POST /api/members`, `POST /api/members/login` and `GET /api/user` (behind `requireAuth`), and mount it in `createApp()`.
- Add a `toUserResponse(user, token)` serializer returning only `email`, `token`, `username`, `bio` and `image`. It is the only way a user reaches a response.
- Blank rule (`validation.field.blank`): missing, not a string, or empty after `trim()`. All blank fields are reported together, in the order username, email, password. Duplicate checks run only when no field is blank; both duplicate errors can appear in one body. Email is compared without regard to letter case and username with exact letter case (`auth.email.compare`, `auth.username.compare`).
- Registration adds the new author through `store.insertUser()`, which gives it the next integer `id`; `bio` and `image` are `null`.
- Tests: `backend/test/members.test.js`, supertest against `createApp()` with `store.reset()` in `beforeEach`. Expired tokens and tokens for a missing `id` are built in the test with `jsonwebtoken` and the same secret.

## Acceptance Criteria

- [ ] Registering username `alice`, email `alice@conduit.test`, password `Alice-Pass-123` returns status 201
- [ ] Registering `alice` returns a `user` with `username` "alice"
- [ ] Registering `alice` returns a `user` with `email` "alice@conduit.test"
- [ ] Registering `alice` returns a `user` with `bio` null
- [ ] Registering `alice` returns a `user` with `image` null
- [ ] Registering `alice` returns a `user` with a non-empty `token` string
- [ ] The register response for `alice` contains no `password` key
- [ ] After registering `alice`, the stored password value for `alice` is a bcrypt hash whose cost field is `10`
- [ ] Registering without a `username` returns status 422 with `{"errors":{"username":["can't be blank"]}}`
- [ ] Registering with `email` set to an empty string returns status 422 with `{"errors":{"email":["can't be blank"]}}`
- [ ] Registering with `password` set to three spaces returns status 422 with `{"errors":{"password":["can't be blank"]}}`
- [ ] Registering with a body that is not valid JSON returns status 422 listing `username`, `email` and `password` as `can't be blank`
- [ ] Registering with email `JAKE@conduit.test` while `jake` exists returns status 422 with `{"errors":{"email":["has already been taken"]}}`
- [ ] Registering with username `jake` and a new email returns status 422 with `{"errors":{"username":["has already been taken"]}}`
- [ ] Registering with username `Jake` and email `jake2@conduit.test` returns status 201
- [ ] Signing in as `jake@conduit.test` with `Jake-Pass-123` returns status 200
- [ ] Signing in as `jake@conduit.test` returns a `user` with `username` "jake"
- [ ] Signing in as `jake@conduit.test` returns a `user` with a non-empty `token` string
- [ ] The sign-in response for `jake` contains no `password` key
- [ ] Signing in as `JAKE@conduit.test` with `Jake-Pass-123` returns status 200
- [ ] Signing in as `jake@conduit.test` with `wrong-pass` returns status 401 with `{"errors":{"email or password":["is invalid"]}}`
- [ ] Signing in as `nobody@conduit.test` returns status 401 with `{"errors":{"email or password":["is invalid"]}}`
- [ ] Signing in with `email` set to an empty string returns status 422 with `{"errors":{"email":["can't be blank"]}}`
- [ ] Signing in without a `password` returns status 422 with `{"errors":{"password":["can't be blank"]}}`
- [ ] The sign-in token for `jake` has the header algorithm `HS256`
- [ ] The sign-in token for `jake` decodes to a payload with `username` "jake"
- [ ] The sign-in token for `jake` decodes to a payload with the numeric `id` of `jake`
- [ ] The sign-in token for `jake` expires 24h after it is issued (`exp` minus `iat` is 86400)
- [ ] With `JWT_SECRET` unset, the sign-in token for `jake` verifies with the secret `conduit-dev-secret`
- [ ] With `JWT_SECRET` set to `test-secret`, the sign-in token for `jake` verifies with the secret `test-secret`
- [ ] Fetching the current user with `Authorization: Token <jake's token>` returns status 200
- [ ] Fetching the current user with `jake`'s token returns a `user` with `email` "jake@conduit.test"
- [ ] The current-user response for `jake` contains no `password` key
- [ ] Fetching the current user with no `Authorization` header returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Fetching the current user with `Authorization: Bearer <jake's token>` returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Fetching the current user with a token signed by a different secret returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Fetching the current user with an expired token for `jake` returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Fetching the current user with a valid token for user `id` 999 returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `npm test` in `backend/` runs the user endpoint tests and exits with code 0

## Test User

- Author: `jake@conduit.test` / `Jake-Pass-123` (username `jake`).
- Author: `jane@conduit.test` / `Jane-Pass-123` (username `jane`).
- New author created by the tests: `alice` / `alice@conduit.test` / `Alice-Pass-123`.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Backend | app | `POST /api/members`, `POST /api/members/login`, `GET /api/user`, password hashing, token signing and checking, user serializer, user endpoint tests |

## Navigation Path

No page in the app. Start the API with `npm start` in `backend/`, then send the requests from an HTTP client to port 3000, or run `npm test` in `backend/`.

## Labels

planned, INIT-0000000000-9899, feature, blocked-by:backend-foundation

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 5,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Add a users router for register, login and current user, with bcryptjs cost 10 hashing, HS256 jsonwebtoken tokens and a shared requireAuth middleware.",
  "AffectedServices": "app",
  "TargetSymbols": "requireAuth (new):app/backend/src/auth.js;signToken (new):app/backend/src/auth.js;usersRouter (new):app/backend/src/routes/members.js;createApp (new in backend-foundation):app/backend/src/app.js;insertUser (new in backend-foundation):app/backend/src/store.js",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Registering username `alice`, email `alice@conduit.test`, password `Alice-Pass-123` returns status 201 | anonymous reader | none | — | | status 201 | yes |
| Registering `alice` returns a `user` with `username` "alice" | anonymous reader | none | — | | `user.username` "alice" | yes |
| Registering `alice` returns a `user` with `email` "alice@conduit.test" | anonymous reader | none | — | | `user.email` "alice@conduit.test" | yes |
| Registering `alice` returns a `user` with `bio` null | anonymous reader | none | — | | `user.bio` null | yes |
| Registering `alice` returns a `user` with `image` null | anonymous reader | none | — | | `user.image` null | yes |
| Registering `alice` returns a `user` with a non-empty `token` string | anonymous reader | none | — | | `user.token` is a non-empty string | yes |
| The register response for `alice` contains no `password` key | anonymous reader | none | — | | no `password` key at any level | yes |
| After registering `alice`, the stored password value for `alice` is a bcrypt hash whose cost field is `10` | developer | none | — | `backend/test/members.test.js` | stored value matches `$2?$10$` prefix | yes |
| Registering without a `username` returns status 422 with `{"errors":{"username":["can't be blank"]}}` | anonymous reader | none | — | | status 422; `{"errors":{"username":["can't be blank"]}}` | yes |
| Registering with `email` set to an empty string returns status 422 with `{"errors":{"email":["can't be blank"]}}` | anonymous reader | none | — | | status 422; `{"errors":{"email":["can't be blank"]}}` | yes |
| Registering with `password` set to three spaces returns status 422 with `{"errors":{"password":["can't be blank"]}}` | anonymous reader | none | — | | status 422; `{"errors":{"password":["can't be blank"]}}` | yes |
| Registering with a body that is not valid JSON returns status 422 listing `username`, `email` and `password` as `can't be blank` | anonymous reader | none | — | | status 422; `errors` has `username`, `email`, `password`, each `["can't be blank"]` | yes |
| Registering with email `JAKE@conduit.test` while `jake` exists returns status 422 with `{"errors":{"email":["has already been taken"]}}` | anonymous reader | seeded `user` jake (`jake@conduit.test`) | seeded-by:backend-foundation | | status 422; `{"errors":{"email":["has already been taken"]}}` | yes |
| Registering with username `jake` and a new email returns status 422 with `{"errors":{"username":["has already been taken"]}}` | anonymous reader | seeded `user` jake | seeded-by:backend-foundation | | status 422; `{"errors":{"username":["has already been taken"]}}` | yes |
| Registering with username `Jake` and email `jake2@conduit.test` returns status 201 | anonymous reader | seeded `user` jake (lower-case username) | seeded-by:backend-foundation | | status 201; `user.username` "Jake" | yes |
| Signing in as `jake@conduit.test` with `Jake-Pass-123` returns status 200 | author | seeded `user` jake | seeded-by:backend-foundation | | status 200 | yes |
| Signing in as `jake@conduit.test` returns a `user` with `username` "jake" | author | seeded `user` jake | seeded-by:backend-foundation | | `user.username` "jake" | yes |
| Signing in as `jake@conduit.test` returns a `user` with a non-empty `token` string | author | seeded `user` jake | seeded-by:backend-foundation | | `user.token` is a non-empty string | yes |
| The sign-in response for `jake` contains no `password` key | author | seeded `user` jake | seeded-by:backend-foundation | | no `password` key at any level | yes |
| Signing in as `JAKE@conduit.test` with `Jake-Pass-123` returns status 200 | author | seeded `user` jake (`jake@conduit.test`) | seeded-by:backend-foundation | | status 200; `user.username` "jake" | yes |
| Signing in as `jake@conduit.test` with `wrong-pass` returns status 401 with `{"errors":{"email or password":["is invalid"]}}` | author | seeded `user` jake | seeded-by:backend-foundation | | status 401; `{"errors":{"email or password":["is invalid"]}}` | yes |
| Signing in as `nobody@conduit.test` returns status 401 with `{"errors":{"email or password":["is invalid"]}}` | anonymous reader | none | — | | status 401; `{"errors":{"email or password":["is invalid"]}}` | yes |
| Signing in with `email` set to an empty string returns status 422 with `{"errors":{"email":["can't be blank"]}}` | anonymous reader | none | — | | status 422; `{"errors":{"email":["can't be blank"]}}` | yes |
| Signing in without a `password` returns status 422 with `{"errors":{"password":["can't be blank"]}}` | anonymous reader | none | — | | status 422; `{"errors":{"password":["can't be blank"]}}` | yes |
| The sign-in token for `jake` has the header algorithm `HS256` | author | seeded `user` jake | seeded-by:backend-foundation | | decoded header `alg` "HS256" | yes |
| The sign-in token for `jake` decodes to a payload with `username` "jake" | author | seeded `user` jake | seeded-by:backend-foundation | | payload `username` "jake" | yes |
| The sign-in token for `jake` decodes to a payload with the numeric `id` of `jake` | author | seeded `user` jake | seeded-by:backend-foundation | | payload `id` equals the stored `id` of jake | yes |
| The sign-in token for `jake` expires 24h after it is issued (`exp` minus `iat` is 86400) | author | seeded `user` jake | seeded-by:backend-foundation | | `exp` minus `iat` equals 86400 | yes |
| With `JWT_SECRET` unset, the sign-in token for `jake` verifies with the secret `conduit-dev-secret` | author | seeded `user` jake | seeded-by:backend-foundation | | verification with `conduit-dev-secret` succeeds | yes |
| With `JWT_SECRET` set to `test-secret`, the sign-in token for `jake` verifies with the secret `test-secret` | author | seeded `user` jake | seeded-by:backend-foundation | | verification with `test-secret` succeeds | yes |
| Fetching the current user with `Authorization: Token <jake's token>` returns status 200 | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 200 | yes |
| Fetching the current user with `jake`'s token returns a `user` with `email` "jake@conduit.test" | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `user.email` "jake@conduit.test" | yes |
| The current-user response for `jake` contains no `password` key | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | no `password` key at any level | yes |
| Fetching the current user with no `Authorization` header returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Fetching the current user with `Authorization: Bearer <jake's token>` returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Fetching the current user with a token signed by a different secret returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | author | a token for seeded `user` jake signed with the secret `other-secret`, built in the test | seeded-by:api-user-auth | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Fetching the current user with an expired token for `jake` returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | author | an expired token for seeded `user` jake, built in the test | seeded-by:api-user-auth | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Fetching the current user with a valid token for user `id` 999 returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | author | a correctly signed token naming `user` `id` 999, which the store does not hold, built in the test | seeded-by:api-user-auth | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `npm test` in `backend/` runs the user endpoint tests and exits with code 0 | developer | none | — | terminal in `backend/` | exit code 0 with `users.test.js` listed | yes |

## Test Data Provided

- Test-only tokens that `backend/test/members.test.js` builds with `jsonwebtoken`: a token for `jake` signed with the secret `other-secret`, an already expired token for `jake`, and a correctly signed token naming user `id` 999.

## Writes

| Key | Op |
|-----|----|
| `user.id` | append |
| `user.username` | append |
| `user.email` | append |
| `user.password_hash` | append |
| `user.bio` | append |
| `user.image` | append |

## Reads

| Key | Source |
|-----|--------|
| `user.id` | spec |
| `user.username` | spec |
| `user.email` | spec |
| `user.password_hash` | spec |
| `user.bio` | spec |
| `user.image` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| Registering with username `jake` and a new email returns status 422 with `{"errors":{"username":["has already been taken"]}}` | `user.username` | state | value:jake | spec:backend-foundation |
| Signing in as `jake@conduit.test` with `Jake-Pass-123` returns status 200 | `user.username` | state | value:jake | spec:backend-foundation |
| Registering without a `username` returns status 422 with `{"errors":{"username":["can't be blank"]}}` | `user.username` | input | null | — |
| Signing in without a `password` returns status 422 with `{"errors":{"password":["can't be blank"]}}` | `user.password_hash` | input | null | — |
