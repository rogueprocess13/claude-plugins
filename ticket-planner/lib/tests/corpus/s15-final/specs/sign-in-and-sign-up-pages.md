# sign-in-and-sign-up-pages

## Title

Authors can sign up and sign in from the browser

## Description

## Summary

Add the sign-in page and the sign-up page. A person can create an author account or sign in to an existing one, and the site then shows them as signed in.

## Outcome

**Serves:** O1

**Who:** Author, a registered user who signs in and publishes articles.

**Need:** Create an account and sign in from the site.

**Outcome:** A person can sign up or sign in on the site and is then shown as signed in, with their username in the header.

## Background / Motivation

An author has to be signed in before they can publish. The acceptance walk has `jake` sign in with the seeded password. The brief names a sign-up page and a sign-in page, and it keeps the token in local storage under `jwt`.

The brief does not say where a person lands after signing in or signing up, or what the page shows when the API rejects the form. This ticket sets both: the landing is the home page, and the page lists the API's messages above the form.

## Proposed Behaviour

Sign-in page, at `/login`:

- It shows an `Email` field, a `Password` field that hides what is typed, and a `Sign in` button.
- Submitting sends the two values to the login endpoint.
- On success the site stores the returned token under the `jwt` key in local storage, goes to the home page at `/`, and the header shows the username and `New Article` without a reload.
- On an error the person stays on `/login`, nothing is stored under `jwt`, and the messages from the API are listed above the form.

Sign-up page, at `/register`:

- It shows a `Username` field, an `Email` field, a `Password` field that hides what is typed, and a `Sign up` button.
- Submitting sends the three values to the register endpoint.
- On success the site stores the returned token under `jwt`, goes to `/`, and the header shows the new username.
- On an error the person stays on `/register`, nothing is stored under `jwt`, and the messages are listed above the form.

Error list:

- Each message from the API's `errors` object is one line, written as the field name, a space, and the message. Examples: `email can't be blank`, `username has already been taken`, `email or password is invalid`.
- The forms do no checking of their own. An empty field is sent to the API, and the API's `can't be blank` message is what the person sees.
- Each submit replaces the list from the previous submit.

## Technical Context

All paths are under `app/frontend/`. The router, `src/api.js`, `src/auth.js` (token storage and current-user fetch) and the header refresh function come from the frontend shell ticket. `POST /api/members`, `POST /api/members/login` and `GET /api/user` come from the account endpoints ticket. The home page a person lands on after signing in comes from the read pages ticket, which also edits the route table in `src/router.js`; this ticket is built after it, so the two never change that file at the same time.

- New `src/pages/login.js`: the sign-in form. It posts `{"user":{"email","password"}}` to `/api/members/login`. On a 200 it stores the token through `src/auth.js`, refreshes the header and calls `navigate('/')`.
- New `src/pages/register.js`: the sign-up form. It posts `{"user":{"username","email","password"}}` to `/api/members`. On a 201 it does the same three steps.
- New `src/errors.js`: renders an `errors` object as a list, one item per message, into a container above the form, and clears it first. The editor page reuses it.
- `src/router.js`: register the two render functions for `/login` and `/register`.
- Inputs carry no `required` attribute and the forms set `novalidate`, so the browser does not block an empty submit before the API sees it.
- Field values and error text are written with `textContent`.
- There is no frontend test runner. `npm run build` in `frontend/` must still exit with code 0. The API does not reload its code and keeps every account created since it started. The `newauthor` sign-up checks create a real account, and the same API answers a second sign-up of `newauthor` with `has already been taken`, so stop the running API and start it again (`npm start` in `backend/`) before checking.

## Acceptance Criteria

- [ ] The sign-in page shows an `Email` field.
- [ ] The sign-in page shows a `Password` field.
- [ ] The sign-in page shows a `Sign in` button.
- [ ] Text typed into the `Password` field of the sign-in page is hidden.
- [ ] Signing in with email `jake@conduit.test` and password `Jake-Pass-123` changes the address bar path to `/`.
- [ ] After `jake` signs in, the `jwt` key in local storage holds a token that `GET /api/user` answers with status 200.
- [ ] After `jake` signs in, the header shows the text `jake` without a page reload.
- [ ] After `jake` signs in, the header shows a `New Article` link.
- [ ] Signing in with email `jake@conduit.test` and password `wrong-password` shows the line `email or password is invalid`.
- [ ] After a sign-in attempt with password `wrong-password`, the address bar path is still `/login`.
- [ ] After a sign-in attempt with password `wrong-password`, local storage has no `jwt` key.
- [ ] Submitting the sign-in form with an empty `Email` and a filled `Password` shows the line `email can't be blank`.
- [ ] Submitting the sign-in form with a filled `Email` and an empty `Password` shows the line `password can't be blank`.
- [ ] After a wrong-password attempt followed by a submit with an empty `Email`, the line `email or password is invalid` is no longer shown.
- [ ] The sign-up page shows a `Username` field.
- [ ] The sign-up page shows an `Email` field.
- [ ] The sign-up page shows a `Password` field.
- [ ] The sign-up page shows a `Sign up` button.
- [ ] Text typed into the `Password` field of the sign-up page is hidden.
- [ ] Signing up with username `newauthor`, email `newauthor@conduit.test` and password `New-Pass-123` changes the address bar path to `/`.
- [ ] After `newauthor` signs up, the `jwt` key in local storage holds a token that `GET /api/user` answers with status 200.
- [ ] After `newauthor` signs up, the header shows the text `newauthor`.
- [ ] Signing up with the email `jake@conduit.test` and a free username shows the line `email has already been taken`.
- [ ] After a sign-up attempt with the email `jake@conduit.test`, the address bar path is still `/register`.
- [ ] After a sign-up attempt with the email `jake@conduit.test`, local storage has no `jwt` key.
- [ ] Signing up with the username `jake` and a free email shows the line `username has already been taken`.
- [ ] Submitting the sign-up form with every field empty shows the line `username can't be blank`.
- [ ] Submitting the sign-up form with every field empty shows the line `email can't be blank`.
- [ ] Submitting the sign-up form with every field empty shows the line `password can't be blank`.

## Out of Scope

A sign-out control, password reset, "remember me", email format or password strength checks in the browser, user settings and profile pages. A redirect away from `/login` or `/register` for a person who is already signed in.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/src/pages/login.js`, `frontend/src/pages/register.js`, `frontend/src/errors.js`, `frontend/src/router.js` |
| BE | app | none changed; the pages call the existing API |

## Test User

`jake@conduit.test`, password `Jake-Pass-123` (seeded author). Sign-up checks create a new account, for example `newauthor` / `newauthor@conduit.test` / `New-Pass-123`.

## Navigation Path

Stop any process that is listening on port 3000, then start the API (`npm start` in `backend/`). If `npm start` prints `Port 3000 is already in use`, an older API is still running: stop it and start again. Start the frontend (`npm run dev` in `frontend/`). Open the site. Click `Sign in` in the header for the sign-in page, or `Sign up` for the sign-up page. To return to the signed-out state between checks, remove the `jwt` key from the browser's local storage and reload.

## Labels

planned, INIT-0000000000-5702, feature, blocked-by:scaffold-packages, blocked-by:store-and-seed, blocked-by:auth-endpoints, blocked-by:frontend-shell, blocked-by:read-pages

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 1,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Two independent npm packages in app: backend/ (Express createApp factory over a per-instance seeded in-memory store, node:test + supertest behind npm test) and frontend/ (Vite + vanilla JS with a History-API router and a dev-server proxy for /api), with no root package, no database and no CORS.",
  "AffectedServices": "app",
  "TargetSymbols": "LOCAL_URL:app/CLAUDE.md:34;loginPage (new):app/frontend/src/pages/login.js;registerPage (new):app/frontend/src/pages/register.js;errors (new):app/frontend/src/errors.js;auth (new in frontend-shell):app/frontend/src/auth.js;header (new in frontend-shell):app/frontend/src/header.js;router (new in frontend-shell):app/frontend/src/router.js;homePage (new in read-pages):app/frontend/src/pages/home.js;usersRouter (new in auth-endpoints):app/backend/src/routes/members.js",
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
| The sign-in page shows an `Email` field. | Anonymous reader | none | — | Open the site > click `Sign in` | a text input labelled Email is visible | yes |
| The sign-in page shows a `Password` field. | Anonymous reader | none | — | Open the site > click `Sign in` | an input labelled Password is visible | yes |
| The sign-in page shows a `Sign in` button. | Anonymous reader | none | — | Open the site > click `Sign in` | a button with the text Sign in is visible | yes |
| Text typed into the `Password` field of the sign-in page is hidden. | Anonymous reader | none | — | Open the site > click `Sign in` | the input has type password | yes |
| Signing in with email `jake@conduit.test` and password `Jake-Pass-123` changes the address bar path to `/`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` | path is / | yes |
| After `jake` signs in, the `jwt` key in local storage holds a token that `GET /api/user` answers with status 200. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` | the jwt value is non-empty and a current-user request with it returns status 200 | yes |
| After `jake` signs in, the header shows the text `jake` without a page reload. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` | the text jake is visible in the header | yes |
| After `jake` signs in, the header shows a `New Article` link. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` | a link with the text New Article is visible | yes |
| Signing in with email `jake@conduit.test` and password `wrong-password` shows the line `email or password is invalid`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` | the line email or password is invalid is visible above the form | yes |
| After a sign-in attempt with password `wrong-password`, the address bar path is still `/login`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` | path is /login | yes |
| After a sign-in attempt with password `wrong-password`, local storage has no `jwt` key. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` | local storage has no jwt key | yes |
| Submitting the sign-in form with an empty `Email` and a filled `Password` shows the line `email can't be blank`. | Anonymous reader | none | — | Open the site > click `Sign in` | the line email can't be blank is visible above the form | yes |
| Submitting the sign-in form with a filled `Email` and an empty `Password` shows the line `password can't be blank`. | Anonymous reader | none | — | Open the site > click `Sign in` | the line password can't be blank is visible above the form | yes |
| After a wrong-password attempt followed by a submit with an empty `Email`, the line `email or password is invalid` is no longer shown. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` | the line email or password is invalid is absent; the line email can't be blank is visible | yes |
| The sign-up page shows a `Username` field. | Anonymous reader | none | — | Open the site > click `Sign up` | a text input labelled Username is visible | yes |
| The sign-up page shows an `Email` field. | Anonymous reader | none | — | Open the site > click `Sign up` | a text input labelled Email is visible | yes |
| The sign-up page shows a `Password` field. | Anonymous reader | none | — | Open the site > click `Sign up` | an input labelled Password is visible | yes |
| The sign-up page shows a `Sign up` button. | Anonymous reader | none | — | Open the site > click `Sign up` | a button with the text Sign up is visible | yes |
| Text typed into the `Password` field of the sign-up page is hidden. | Anonymous reader | none | — | Open the site > click `Sign up` | the input has type password | yes |
| Signing up with username `newauthor`, email `newauthor@conduit.test` and password `New-Pass-123` changes the address bar path to `/`. | Anonymous reader | built in the test: a sign-up entry whose username and email no stored account has | — | Open the site > click `Sign up` | path is / | yes |
| After `newauthor` signs up, the `jwt` key in local storage holds a token that `GET /api/user` answers with status 200. | Anonymous reader | built in the test: a sign-up entry whose username and email no stored account has | — | Open the site > click `Sign up` | the jwt value is non-empty and a current-user request with it returns status 200 | yes |
| After `newauthor` signs up, the header shows the text `newauthor`. | Anonymous reader | built in the test: a sign-up entry whose username and email no stored account has | — | Open the site > click `Sign up` | the text newauthor is visible in the header | yes |
| Signing up with the email `jake@conduit.test` and a free username shows the line `email has already been taken`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign up` | the line email has already been taken is visible above the form | yes |
| After a sign-up attempt with the email `jake@conduit.test`, the address bar path is still `/register`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign up` | path is /register | yes |
| After a sign-up attempt with the email `jake@conduit.test`, local storage has no `jwt` key. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign up` | local storage has no jwt key | yes |
| Signing up with the username `jake` and a free email shows the line `username has already been taken`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign up` | the line username has already been taken is visible above the form | yes |
| Submitting the sign-up form with every field empty shows the line `username can't be blank`. | Anonymous reader | none | — | Open the site > click `Sign up` | the line username can't be blank is visible above the form | yes |
| Submitting the sign-up form with every field empty shows the line `email can't be blank`. | Anonymous reader | none | — | Open the site > click `Sign up` | the line email can't be blank is visible above the form | yes |
| Submitting the sign-up form with every field empty shows the line `password can't be blank`. | Anonymous reader | none | — | Open the site > click `Sign up` | the line password can't be blank is visible above the form | yes |

## Writes

| Key | Op |
|---|---|
| `user` | append |

## Reads

| Key | Source |
|---|---|
| `client_session.jwt` | spec |
| `user.username` | spec |
| `user.email` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|---|---|---|---|---|
| Signing in with email `jake@conduit.test` and password `Jake-Pass-123` changes the address bar path to `/`. | `user.username` | state | value:jake | spec:store-and-seed |
| After `jake` signs in, the `jwt` key in local storage holds a token that `GET /api/user` answers with status 200. | `user.username` | state | value:jake | spec:store-and-seed |
| After `jake` signs in, the header shows the text `jake` without a page reload. | `user.username` | state | value:jake | spec:store-and-seed |
| After `jake` signs in, the header shows a `New Article` link. | `user.username` | state | value:jake | spec:store-and-seed |
| Signing in with email `jake@conduit.test` and password `wrong-password` shows the line `email or password is invalid`. | `user.username` | state | value:jake | spec:store-and-seed |
| After a sign-in attempt with password `wrong-password`, the address bar path is still `/login`. | `user.username` | state | value:jake | spec:store-and-seed |
| After a sign-in attempt with password `wrong-password`, local storage has no `jwt` key. | `user.username` | state | value:jake | spec:store-and-seed |
| Submitting the sign-in form with an empty `Email` and a filled `Password` shows the line `email can't be blank`. | `user.email` | input | null | — |
| Submitting the sign-in form with a filled `Email` and an empty `Password` shows the line `password can't be blank`. | `user.password` | input | null | — |
| After a wrong-password attempt followed by a submit with an empty `Email`, the line `email or password is invalid` is no longer shown. | `user.username` | state | value:jake | spec:store-and-seed |
| Signing up with the email `jake@conduit.test` and a free username shows the line `email has already been taken`. | `user.username` | state | value:jake | spec:store-and-seed |
| After a sign-up attempt with the email `jake@conduit.test`, the address bar path is still `/register`. | `user.username` | state | value:jake | spec:store-and-seed |
| After a sign-up attempt with the email `jake@conduit.test`, local storage has no `jwt` key. | `user.username` | state | value:jake | spec:store-and-seed |
| Signing up with the username `jake` and a free email shows the line `username has already been taken`. | `user.username` | state | value:jake | spec:store-and-seed |
| Submitting the sign-up form with every field empty shows the line `username can't be blank`. | `user.username` | input | null | — |
| Submitting the sign-up form with every field empty shows the line `email can't be blank`. | `user.email` | input | null | — |
| Submitting the sign-up form with every field empty shows the line `password can't be blank`. | `user.password` | input | null | — |
