# auth-endpoints

## Title

Authors can register, sign in and fetch their account through the API

## Description

## Summary

Add the three account endpoints of the API: register, login and current user. They let a person create an author account, sign in with it, and prove who they are on later requests.

## Outcome

**Serves:** O1

**Who:** Author, a registered user who signs in and publishes articles.

**Need:** Create an account and sign in.

**Outcome:** A person can register as an author, sign in with their email and password, and be recognised on later requests.

## Background / Motivation

Publishing is for authors only, so the app needs accounts before it needs articles. The brief gives the request and response shape of each endpoint and the exact status and body of each error. Passwords must never appear in a response.

Where the brief is silent, this ticket states the behaviour outright so that it can be tested. Those points are: what counts as blank, how several errors are reported together, whether login ignores email case, and which token the current-user response returns.

## Proposed Behaviour

All three endpoints answer with JSON. A successful response has the `user` shape: `{"user":{"email","token","username","bio","image"}}`, with exactly those five keys. No response holds the password or its hash.

A field is blank when it is missing, is not a string, or is empty after surrounding whitespace is removed.

Register, `POST /api/members` with `{"user":{"username","email","password"}}`:

- With three non-blank fields and a free email and username, it creates the user and returns 201 with the `user` shape. `email` and `username` are returned as submitted. `bio` and `image` are null.
- Each blank field gives 422 with `{"errors":{"<field>":["can't be blank"]}}`. All blank fields are reported in one response, one key per field.
- A body with no `user` object is treated as all three fields blank.
- Duplicate checks run only when no field is blank. An email that matches a stored email without regard to case gives 422 with `{"errors":{"email":["has already been taken"]}}`. A username that matches a stored username exactly gives 422 with `{"errors":{"username":["has already been taken"]}}`. If both are taken, both keys are reported in one response.
- Usernames are case sensitive, so `Jake` is free while `jake` exists.
- The new user can sign in at once with the same email and password.

Login, `POST /api/members/login` with `{"user":{"email","password"}}`:

- With the email and password of a stored user it returns 200 with the `user` shape. The email is compared without regard to case, and the response carries the email as stored.
- A blank `email` or `password` gives 422 with the `can't be blank` body, one key per blank field. A body with no `user` object is treated as both fields blank.
- A wrong password, or an email no user has, returns 401 with `{"errors":{"email or password":["is invalid"]}}`.

Current user, `GET /api/user` with the header `Authorization: Token <jwt>`:

- With a valid token it returns 200 with the `user` shape of the token's user. The `token` field repeats the token that was sent.
- Otherwise it returns 401 with `{"errors":{"token":["is missing or invalid"]}}`. This covers: no `Authorization` header, a scheme other than `Token` (for example `Bearer`), a value that is not a JWT, a JWT signed with another secret, a JWT whose algorithm is `none`, an expired JWT, and a valid JWT whose `id` matches no stored user.

Tokens:

- A token is a JWT signed with HS256. Its payload holds the user's `id` and `username`. It expires 24h after it is issued.
- The signing secret is the value of the environment variable `JWT_SECRET`. When that variable is unset the secret is `conduit-dev-secret`.

A request body that is not valid JSON returns 422 with `{"errors":{"json":["is not valid"]}}`.

## Technical Context

All paths are under `app/backend/`. `src/app.js` comes from the scaffold ticket. `src/store.js`, with its user lookups and its add-user function, comes from the store ticket.

- New `src/auth.js`: `signToken(user)` signs `{ id, username }` with `jsonwebtoken`, algorithm from `jwt_algorithm` (HS256), `expiresIn` from `jwt_expiry` (24h). The secret is read from the environment at call time and defaults to the value of `jwt_dev_secret` (`conduit-dev-secret`). `requireAuth` is an Express middleware: it reads the `Authorization` header, requires the `Token` scheme, verifies with `algorithms: ['HS256']` pinned, loads the user by the token's `id` from the store, and puts the user and the raw token on the request. On any failure it answers 401 with the token error body. It is the only place tokens are read, and the article ticket reuses it.
- New `src/validation.js`: the blank check and the builder for 422 error bodies. Error keys are emitted in the order the fields appear in the request shape (register: username, email, password; login: email, password).
- New `src/serializers.js`: `toUserResponse(user, token)` builds every `user` response from the five named fields only, so no handler can return `passwordHash`.
- New `src/routes/members.js`: the three routes. Register hashes the password with `bcryptjs` at the cost named by `bcrypt_cost` (10) and adds the user through the store. Login looks the user up by lower-cased email and compares with `bcryptjs`.
- `src/app.js`: mount the users router under `/api`, and add an error handler that turns the body parser's JSON syntax error into the 422 above.
- New `test/members.test.js` (`node:test` + `supertest`): one test per acceptance criterion, each against its own `createApp()`, so each starts from the seed. Expired and foreign tokens are signed inside the test with `jsonwebtoken`. The `JWT_SECRET` case sets the variable inside the test and restores it afterwards.
- The bcrypt cost stays at 10 in tests.

## Acceptance Criteria

- [ ] `POST /api/members` with username `newauthor`, email `newauthor@conduit.test` and password `New-Pass-123` returns 201.
- [ ] The 201 register response body is a `user` object with exactly the keys `email`, `token`, `username`, `bio` and `image`.
- [ ] The 201 register response for `newauthor@conduit.test` has `email` equal to `newauthor@conduit.test`.
- [ ] The 201 register response for username `newauthor` has `username` equal to `newauthor`.
- [ ] The 201 register response has `bio` equal to null.
- [ ] The 201 register response has `image` equal to null.
- [ ] Registering with email `Mixed.Case@conduit.test` returns that email with its capital letters unchanged.
- [ ] The 201 register response body does not contain the submitted password `New-Pass-123`.
- [ ] The 201 register response body has no key named `passwordHash`.
- [ ] After registering `newauthor@conduit.test` with password `New-Pass-123`, a login with the same email and password returns 200.
- [ ] `POST /api/members` without `username` returns 422 with body `{"errors":{"username":["can't be blank"]}}`.
- [ ] `POST /api/members` without `email` returns 422 with body `{"errors":{"email":["can't be blank"]}}`.
- [ ] `POST /api/members` without `password` returns 422 with body `{"errors":{"password":["can't be blank"]}}`.
- [ ] `POST /api/members` with a `username` made only of spaces returns 422 with body `{"errors":{"username":["can't be blank"]}}`.
- [ ] `POST /api/members` with the number 5 as `username` returns 422 with body `{"errors":{"username":["can't be blank"]}}`.
- [ ] `POST /api/members` with `username`, `email` and `password` all empty strings returns 422 with body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}`.
- [ ] `POST /api/members` with the body `{}` returns 422 with body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}`.
- [ ] `POST /api/members` with the email `jake@conduit.test` and a free username returns 422 with body `{"errors":{"email":["has already been taken"]}}`.
- [ ] `POST /api/members` with the email `JAKE@conduit.test` and a free username returns 422 with body `{"errors":{"email":["has already been taken"]}}`.
- [ ] `POST /api/members` with the username `jake` and a free email returns 422 with body `{"errors":{"username":["has already been taken"]}}`.
- [ ] `POST /api/members` with the username `jake` and the email `jake@conduit.test` returns 422 with body `{"errors":{"username":["has already been taken"],"email":["has already been taken"]}}`.
- [ ] `POST /api/members` with the username `Jake`, a free email and a non-blank password returns 201.
- [ ] `POST /api/members` with the email `jake@conduit.test`, the username `jake` and an empty password returns 422 with body `{"errors":{"password":["can't be blank"]}}`.
- [ ] `POST /api/members` with the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`.
- [ ] `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns 200.
- [ ] The 200 login response for `jake` is a `user` object with exactly the keys `email`, `token`, `username`, `bio` and `image`.
- [ ] The 200 login response for `jake` has `username` equal to `jake`.
- [ ] The 200 login response for `jake` has `email` equal to `jake@conduit.test`.
- [ ] The 200 login response for `jake` has `bio` and `image` both null.
- [ ] The 200 login response body for `jake` does not contain `Jake-Pass-123`.
- [ ] The 200 login response body for `jake` has no key named `passwordHash`.
- [ ] A login with email `JAKE@conduit.test` and password `Jake-Pass-123` returns 200 with `email` equal to `jake@conduit.test`.
- [ ] A login with email `jake@conduit.test` and password `wrong-password` returns 401 with body `{"errors":{"email or password":["is invalid"]}}`.
- [ ] A login with email `nobody@conduit.test` and password `Jake-Pass-123` returns 401 with body `{"errors":{"email or password":["is invalid"]}}`.
- [ ] A login without `email` returns 422 with body `{"errors":{"email":["can't be blank"]}}`.
- [ ] A login without `password` returns 422 with body `{"errors":{"password":["can't be blank"]}}`.
- [ ] A login with the body `{}` returns 422 with body `{"errors":{"email":["can't be blank"],"password":["can't be blank"]}}`.
- [ ] The token in the login response for `jake` has the JWT header algorithm `HS256`.
- [ ] The token in the login response for `jake` has a payload with `id` 1.
- [ ] The token in the login response for `jake` has a payload with `username` equal to `jake`.
- [ ] The token in the login response for `jake` expires 24h after its issue time.
- [ ] With `JWT_SECRET` unset, the token in the login response for `jake` verifies with the secret `conduit-dev-secret`.
- [ ] With `JWT_SECRET` set to `other-secret`, the token in the login response for `jake` verifies with `other-secret`.
- [ ] With `JWT_SECRET` set to `other-secret`, the token in the login response for `jake` does not verify with `conduit-dev-secret`.
- [ ] `GET /api/user` with the header `Authorization: Token <jwt>` holding the login token of `jake` returns 200.
- [ ] The 200 current-user response for `jake` is a `user` object with exactly the keys `email`, `token`, `username`, `bio` and `image`.
- [ ] The 200 current-user response for the token of `jake` has `username` equal to `jake`.
- [ ] The 200 current-user response for the token of `jake` has `email` equal to `jake@conduit.test`.
- [ ] The 200 current-user response has `token` equal to the token sent in the header.
- [ ] `GET /api/user` with no `Authorization` header returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with the header `Authorization: Bearer <jwt>` holding the login token of `jake` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with the header `Authorization: Token not-a-jwt` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with a token for `jake` signed with the secret `wrong-secret` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with an unsigned token for `jake` whose algorithm is `none` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with a correctly signed token for `jake` that expired one hour ago returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `GET /api/user` with a correctly signed token whose `id` is 999 returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.

## Out of Scope

Article endpoints and every page. Updating a user, user settings, profiles, follow, password reset, sign-out on the server, token refresh, email format checks and password strength rules are not built. No CORS middleware is added.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/src/routes/members.js`, `backend/src/auth.js`, `backend/src/validation.js`, `backend/src/serializers.js`, `backend/src/app.js`, `backend/test/members.test.js` |

## Test User

`jake@conduit.test`, password `Jake-Pass-123` (seeded author). Registration checks create their own accounts.

## Navigation Path

No screen. This ticket is API only: each check is an HTTP request to the API, run by `npm test` in `backend/`, or sent by hand to a freshly started API (`npm start` in `backend/`).

## Labels

planned, INIT-0000000000-5702, feature, blocked-by:scaffold-packages, blocked-by:store-and-seed

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 3,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Two independent npm packages in app: backend/ (Express createApp factory over a per-instance seeded in-memory store, node:test + supertest behind npm test) and frontend/ (Vite + vanilla JS with a History-API router and a dev-server proxy for /api), with no root package, no database and no CORS.",
  "AffectedServices": "app",
  "TargetSymbols": "Express:app/CLAUDE.md:21;BE_TEST_CMD:app/CLAUDE.md:46;backend:app/CLAUDE.md:53;signToken/requireAuth (new):app/backend/src/auth.js;validation (new):app/backend/src/validation.js;toUserResponse (new):app/backend/src/serializers.js;usersRouter (new):app/backend/src/routes/members.js;createApp (new in scaffold-packages):app/backend/src/app.js;createStore (new in store-and-seed):app/backend/src/store.js;usersTest (new):app/backend/test/members.test.js",
  "Kind": "business",
  "Serves": [
    "O1"
  ],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|---|
| `POST /api/members` with username `newauthor`, email `newauthor@conduit.test` and password `New-Pass-123` returns 201. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | status 201 | yes |
| The 201 register response body is a `user` object with exactly the keys `email`, `token`, `username`, `bio` and `image`. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | the key set of `user` is email, token, username, bio, image | yes |
| The 201 register response for `newauthor@conduit.test` has `email` equal to `newauthor@conduit.test`. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | email is newauthor@conduit.test | yes |
| The 201 register response for username `newauthor` has `username` equal to `newauthor`. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | username is newauthor | yes |
| The 201 register response has `bio` equal to null. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | bio is null | yes |
| The 201 register response has `image` equal to null. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | image is null | yes |
| Registering with email `Mixed.Case@conduit.test` returns that email with its capital letters unchanged. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | email is Mixed.Case@conduit.test | yes |
| The 201 register response body does not contain the submitted password `New-Pass-123`. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | the raw body has no occurrence of New-Pass-123 | yes |
| The 201 register response body has no key named `passwordHash`. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | no passwordHash key at any depth | yes |
| After registering `newauthor@conduit.test` with password `New-Pass-123`, a login with the same email and password returns 200. | API client with no account | built in the test: a sign-up payload whose username and email no stored user has | — |  | status 200 | yes |
| `POST /api/members` without `username` returns 422 with body `{"errors":{"username":["can't be blank"]}}`. | API client with no account | built in the test: a sign-up payload with no username | — |  | status 422, body {"errors":{"username":["can't be blank"]}} | yes |
| `POST /api/members` without `email` returns 422 with body `{"errors":{"email":["can't be blank"]}}`. | API client with no account | built in the test: a sign-up payload with no email | — |  | status 422, body {"errors":{"email":["can't be blank"]}} | yes |
| `POST /api/members` without `password` returns 422 with body `{"errors":{"password":["can't be blank"]}}`. | API client with no account | built in the test: a sign-up payload with no password | — |  | status 422, body {"errors":{"password":["can't be blank"]}} | yes |
| `POST /api/members` with a `username` made only of spaces returns 422 with body `{"errors":{"username":["can't be blank"]}}`. | API client with no account | built in the test: a sign-up payload whose username is whitespace | — |  | status 422, body {"errors":{"username":["can't be blank"]}} | yes |
| `POST /api/members` with the number 5 as `username` returns 422 with body `{"errors":{"username":["can't be blank"]}}`. | API client with no account | built in the test: a sign-up payload whose username is a JSON number | — |  | status 422, body {"errors":{"username":["can't be blank"]}} | yes |
| `POST /api/members` with `username`, `email` and `password` all empty strings returns 422 with body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}`. | API client with no account | built in the test: a sign-up payload of empty strings | — |  | status 422, body {"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}} | yes |
| `POST /api/members` with the body `{}` returns 422 with body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}`. | API client with no account | built in the test: an empty JSON object | — |  | status 422, body {"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}} | yes |
| `POST /api/members` with the email `jake@conduit.test` and a free username returns 422 with body `{"errors":{"email":["has already been taken"]}}`. | API client with no account | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"email":["has already been taken"]}} | yes |
| `POST /api/members` with the email `JAKE@conduit.test` and a free username returns 422 with body `{"errors":{"email":["has already been taken"]}}`. | API client with no account | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"email":["has already been taken"]}} | yes |
| `POST /api/members` with the username `jake` and a free email returns 422 with body `{"errors":{"username":["has already been taken"]}}`. | API client with no account | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"username":["has already been taken"]}} | yes |
| `POST /api/members` with the username `jake` and the email `jake@conduit.test` returns 422 with body `{"errors":{"username":["has already been taken"],"email":["has already been taken"]}}`. | API client with no account | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"username":["has already been taken"],"email":["has already been taken"]}} | yes |
| `POST /api/members` with the username `Jake`, a free email and a non-blank password returns 201. | API client with no account | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 201 | yes |
| `POST /api/members` with the email `jake@conduit.test`, the username `jake` and an empty password returns 422 with body `{"errors":{"password":["can't be blank"]}}`. | API client with no account | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"password":["can't be blank"]}} with no has already been taken key | yes |
| `POST /api/members` with the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`. | API client with no account | built in the test: a malformed JSON request body | — |  | status 422, body {"errors":{"json":["is not valid"]}} | yes |
| `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns 200. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 200 | yes |
| The 200 login response for `jake` is a `user` object with exactly the keys `email`, `token`, `username`, `bio` and `image`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | the key set of `user` is email, token, username, bio, image | yes |
| The 200 login response for `jake` has `username` equal to `jake`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | username is jake | yes |
| The 200 login response for `jake` has `email` equal to `jake@conduit.test`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | email is jake@conduit.test | yes |
| The 200 login response for `jake` has `bio` and `image` both null. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | bio is null, image is null | yes |
| The 200 login response body for `jake` does not contain `Jake-Pass-123`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | the raw body has no occurrence of Jake-Pass-123 | yes |
| The 200 login response body for `jake` has no key named `passwordHash`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | no passwordHash key at any depth | yes |
| A login with email `JAKE@conduit.test` and password `Jake-Pass-123` returns 200 with `email` equal to `jake@conduit.test`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 200, email is jake@conduit.test | yes |
| A login with email `jake@conduit.test` and password `wrong-password` returns 401 with body `{"errors":{"email or password":["is invalid"]}}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 401, body {"errors":{"email or password":["is invalid"]}} | yes |
| A login with email `nobody@conduit.test` and password `Jake-Pass-123` returns 401 with body `{"errors":{"email or password":["is invalid"]}}`. | API client with no account | built in the test: a login payload whose email no stored user has | — |  | status 401, body {"errors":{"email or password":["is invalid"]}} | yes |
| A login without `email` returns 422 with body `{"errors":{"email":["can't be blank"]}}`. | API client with no account | built in the test: a login payload with no email | — |  | status 422, body {"errors":{"email":["can't be blank"]}} | yes |
| A login without `password` returns 422 with body `{"errors":{"password":["can't be blank"]}}`. | API client with no account | built in the test: a login payload with no password | — |  | status 422, body {"errors":{"password":["can't be blank"]}} | yes |
| A login with the body `{}` returns 422 with body `{"errors":{"email":["can't be blank"],"password":["can't be blank"]}}`. | API client with no account | built in the test: an empty JSON object | — |  | status 422, body {"errors":{"email":["can't be blank"],"password":["can't be blank"]}} | yes |
| The token in the login response for `jake` has the JWT header algorithm `HS256`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | decoded header alg is HS256 | yes |
| The token in the login response for `jake` has a payload with `id` 1. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | decoded payload id is 1 | yes |
| The token in the login response for `jake` has a payload with `username` equal to `jake`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | decoded payload username is jake | yes |
| The token in the login response for `jake` expires 24h after its issue time. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | payload exp minus iat equals 86400 | yes |
| With `JWT_SECRET` unset, the token in the login response for `jake` verifies with the secret `conduit-dev-secret`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | verification with conduit-dev-secret succeeds | yes |
| With `JWT_SECRET` set to `other-secret`, the token in the login response for `jake` verifies with `other-secret`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | verification with other-secret succeeds | yes |
| With `JWT_SECRET` set to `other-secret`, the token in the login response for `jake` does not verify with `conduit-dev-secret`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | verification with conduit-dev-secret fails | yes |
| `GET /api/user` with the header `Authorization: Token <jwt>` holding the login token of `jake` returns 200. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 200 | yes |
| The 200 current-user response for `jake` is a `user` object with exactly the keys `email`, `token`, `username`, `bio` and `image`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | the key set of `user` is email, token, username, bio, image | yes |
| The 200 current-user response for the token of `jake` has `username` equal to `jake`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | username is jake | yes |
| The 200 current-user response for the token of `jake` has `email` equal to `jake@conduit.test`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | email is jake@conduit.test | yes |
| The 200 current-user response has `token` equal to the token sent in the header. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | token equals the request token | yes |
| `GET /api/user` with no `Authorization` header returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | API client with no account | none | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `GET /api/user` with the header `Authorization: Bearer <jwt>` holding the login token of `jake` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `GET /api/user` with the header `Authorization: Token not-a-jwt` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | API client with no account | none | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `GET /api/user` with a token for `jake` signed with the secret `wrong-secret` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | API client with no account | built in the test: a JWT signed with a secret the API does not use | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `GET /api/user` with an unsigned token for `jake` whose algorithm is `none` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | API client with no account | built in the test: an unsigned JWT with algorithm none | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `GET /api/user` with a correctly signed token for `jake` that expired one hour ago returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | API client with no account | built in the test: a correctly signed JWT whose expiry time has passed | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `GET /api/user` with a correctly signed token whose `id` is 999 returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | API client with no account | built in the test: a correctly signed JWT whose id no stored user has | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |

## Writes

| Key | Op |
|---|---|
| `user` | append |

## Reads

| Key | Source |
|---|---|
| `user.id` | spec |
| `user.username` | spec |
| `user.email` | spec |
| `user.password_hash` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|---|---|---|---|---|
| `POST /api/members` without `username` returns 422 with body `{"errors":{"username":["can't be blank"]}}`. | `user.username` | input | null | — |
| `POST /api/members` without `email` returns 422 with body `{"errors":{"email":["can't be blank"]}}`. | `user.email` | input | null | — |
| `POST /api/members` without `password` returns 422 with body `{"errors":{"password":["can't be blank"]}}`. | `user.password` | input | null | — |
| `POST /api/members` with the email `jake@conduit.test` and a free username returns 422 with body `{"errors":{"email":["has already been taken"]}}`. | `user.username` | state | value:jake | spec:store-and-seed |
| `POST /api/members` with the email `JAKE@conduit.test` and a free username returns 422 with body `{"errors":{"email":["has already been taken"]}}`. | `user.username` | state | value:jake | spec:store-and-seed |
| `POST /api/members` with the username `jake` and a free email returns 422 with body `{"errors":{"username":["has already been taken"]}}`. | `user.username` | state | value:jake | spec:store-and-seed |
| `POST /api/members` with the username `jake` and the email `jake@conduit.test` returns 422 with body `{"errors":{"username":["has already been taken"],"email":["has already been taken"]}}`. | `user.username` | state | value:jake | spec:store-and-seed |
| `POST /api/members` with the username `Jake`, a free email and a non-blank password returns 201. | `user.username` | state | value:jake | spec:store-and-seed |
| `POST /api/members` with the email `jake@conduit.test`, the username `jake` and an empty password returns 422 with body `{"errors":{"password":["can't be blank"]}}`. | `user.username` | state | value:jake | spec:store-and-seed |
| `POST /api/members/login` with email `jake@conduit.test` and password `Jake-Pass-123` returns 200. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 login response for `jake` is a `user` object with exactly the keys `email`, `token`, `username`, `bio` and `image`. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 login response for `jake` has `username` equal to `jake`. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 login response for `jake` has `email` equal to `jake@conduit.test`. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 login response for `jake` has `bio` and `image` both null. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 login response body for `jake` does not contain `Jake-Pass-123`. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 login response body for `jake` has no key named `passwordHash`. | `user.username` | state | value:jake | spec:store-and-seed |
| A login with email `JAKE@conduit.test` and password `Jake-Pass-123` returns 200 with `email` equal to `jake@conduit.test`. | `user.username` | state | value:jake | spec:store-and-seed |
| A login with email `jake@conduit.test` and password `wrong-password` returns 401 with body `{"errors":{"email or password":["is invalid"]}}`. | `user.username` | state | value:jake | spec:store-and-seed |
| A login without `email` returns 422 with body `{"errors":{"email":["can't be blank"]}}`. | `user.email` | input | null | — |
| A login without `password` returns 422 with body `{"errors":{"password":["can't be blank"]}}`. | `user.password` | input | null | — |
| The token in the login response for `jake` has the JWT header algorithm `HS256`. | `user.username` | state | value:jake | spec:store-and-seed |
| The token in the login response for `jake` has a payload with `id` 1. | `user.username` | state | value:jake | spec:store-and-seed |
| The token in the login response for `jake` has a payload with `username` equal to `jake`. | `user.username` | state | value:jake | spec:store-and-seed |
| The token in the login response for `jake` expires 24h after its issue time. | `user.username` | state | value:jake | spec:store-and-seed |
| With `JWT_SECRET` unset, the token in the login response for `jake` verifies with the secret `conduit-dev-secret`. | `user.username` | state | value:jake | spec:store-and-seed |
| With `JWT_SECRET` set to `other-secret`, the token in the login response for `jake` verifies with `other-secret`. | `user.username` | state | value:jake | spec:store-and-seed |
| With `JWT_SECRET` set to `other-secret`, the token in the login response for `jake` does not verify with `conduit-dev-secret`. | `user.username` | state | value:jake | spec:store-and-seed |
| `GET /api/user` with the header `Authorization: Token <jwt>` holding the login token of `jake` returns 200. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 current-user response for `jake` is a `user` object with exactly the keys `email`, `token`, `username`, `bio` and `image`. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 current-user response for the token of `jake` has `username` equal to `jake`. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 current-user response for the token of `jake` has `email` equal to `jake@conduit.test`. | `user.username` | state | value:jake | spec:store-and-seed |
| The 200 current-user response has `token` equal to the token sent in the header. | `user.username` | state | value:jake | spec:store-and-seed |
| `GET /api/user` with the header `Authorization: Bearer <jwt>` holding the login token of `jake` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | `user.username` | state | value:jake | spec:store-and-seed |
