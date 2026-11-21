# sign-up-and-sign-in-pages

## Title

Authors can sign up and sign in from the browser

## Description

## Summary

Fill in the sign-in page (`/login`) and the sign-up page (`/register`): forms that call the account API, store the token, land on the home page, and show the API's errors as a list above the form.

## Outcome

**Serves:** O1

**Who:** Author

**Need:** Get an account and sign in, so they can publish.

**Outcome:** A person can register as an author, and a registered author can sign in and is shown as signed in.

## Background / Motivation

The account API exists, but a person in the browser has no way to use it. The brief's walkthrough starts with `jake` signing in at `http://localhost:5173`.

## Proposed Behaviour

Sign-in page:

- Shows an `Email` input, a `Password` input (characters hidden) and a `Sign in` button.
- Correct credentials: the token is stored in `localStorage.jwt`, the header switches to the signed-in state with the username, and the browser goes to the home page `/`.
- When the API returns errors, they appear in a list above the form, one item per message, written as the field name then the message (for example `email or password is invalid`, `email can't be blank`). The address stays on the page and the typed values stay in the form.

Sign-up page:

- Shows a `Username` input, an `Email` input, a `Password` input (characters hidden) and a `Sign up` button.
- Success: same as sign-in — token stored, header shows the new username, browser goes to `/`.
- Errors appear in the same list format (for example `email has already been taken`, `username has already been taken`, `username can't be blank`), one item per message; the address stays on the page.

## Technical Context

- Builds on `backend-scaffold` (`npm start` in `backend/`, used to start a freshly seeded backend for verification), `frontend-shell` (`frontend/src/pages/login.js` and `frontend/src/pages/register.js` stubs, `post` from `frontend/src/api.js`, `session.signIn` in `frontend/src/session.js`, `navigate` in `frontend/src/router.js`) and `user-accounts-api` (`POST /api/members/login`, `POST /api/members`, the seeded `jake`).
- Replace the two stubs. Sign-in posts `{"user":{"email","password"}}` to `/api/members/login`; sign-up posts `{"user":{"username","email","password"}}` to `/api/members`. On success call `session.signIn(body.user)` then `navigate("/")`.
- New `frontend/src/errors.js`: `renderErrors(container, errors)` builds `<ul class="error-messages">` with one `<li>` per message, text `${field} ${message}` (so the 401 body renders `email or password is invalid`). The editor ticket reuses it.
- Inputs carry `<label>` text `Username`, `Email`, `Password`; password inputs use `type="password"`.
- Inputs carry no HTML validation attributes (`required`, `minlength`, `maxlength`, `pattern`), and the `Email` inputs use `type="text"`, so the browser never blocks a submit: an empty field reaches the API and its error appears in the list.
- Parameters: `session.landing_route` = home page /; `ui.form_error_format` = one list item per message, field name then message.
- Verification setup: before each browser verification attempt, including every verify retry, stop any process listening on port 3000, start the backend fresh with `npm start` in `backend/` (a fresh start reseeds the 2 seeded users and 2 seeded articles and drops everything created at runtime), then run `npm run dev` in `frontend/`. The criteria below assume that freshly seeded backend.

## Acceptance Criteria

- [ ] Signed out, the sign-in page shows an `Email` input
- [ ] Signed out, the sign-in page shows a `Password` input of type `password`
- [ ] Signed out, the sign-in page shows a `Sign in` button
- [ ] Submitting the sign-in form with email `jake@conduit.test`, password `Jake-Pass-123` changes the address to `/`
- [ ] Submitting the sign-in form with email `jake@conduit.test`, password `Jake-Pass-123` shows `jake` in the header
- [ ] Submitting the sign-in form with email `jake@conduit.test`, password `Jake-Pass-123` stores a non-empty token in `localStorage.jwt`
- [ ] Submitting the sign-in form with email `jake@conduit.test`, password `wrong-pass` shows the error `email or password is invalid`
- [ ] Submitting the sign-in form with email `jake@conduit.test`, password `wrong-pass` keeps the address at `/login`
- [ ] Submitting the sign-in form with email `jake@conduit.test`, password `wrong-pass` leaves `jake@conduit.test` in the `Email` input
- [ ] Submitting the sign-in form with an empty email, password `Jake-Pass-123` shows the error `email can't be blank`
- [ ] Signed out, the sign-up page shows a `Username` input
- [ ] Signed out, the sign-up page shows an `Email` input
- [ ] Signed out, the sign-up page shows a `Password` input of type `password`
- [ ] Signed out, the sign-up page shows a `Sign up` button
- [ ] Submitting the sign-up form with username `newauthor`, email `newauthor@conduit.test`, password `New-Pass-123` changes the address to `/`
- [ ] Submitting the sign-up form with username `newauthor`, email `newauthor@conduit.test`, password `New-Pass-123` shows `newauthor` in the header
- [ ] Submitting the sign-up form with username `newauthor`, email `newauthor@conduit.test`, password `New-Pass-123` stores a non-empty token in `localStorage.jwt`
- [ ] Submitting the sign-up form with username `someone`, email `jake@conduit.test`, password `Pass-123` shows the error `email has already been taken`
- [ ] Submitting the sign-up form with username `someone`, email `jake@conduit.test`, password `Pass-123` keeps the address at `/register`
- [ ] Submitting the sign-up form with username `jake`, email `other@conduit.test`, password `Pass-123` shows the error `username has already been taken`
- [ ] Submitting the sign-up form with username `jake`, email `jake@conduit.test`, password `Pass-123` shows an error list of 2 items
- [ ] Submitting the sign-up form with an empty username, email `x@conduit.test`, password `Pass-123` shows the error `username can't be blank`

## Out of Scope

Sign-out, password reset, profile and settings pages, and client-side validation beyond what the API returns.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app frontend | `src/pages/login.js`, `src/pages/register.js`, `src/errors.js` |

## Test User

`jake@conduit.test` — password `Jake-Pass-123` (seeded author). Sign-up checks use a new account `newauthor` / `newauthor@conduit.test` / `New-Pass-123`. Restart the backend before each verification attempt (see Technical Context), so `newauthor` does not exist yet.

## Navigation Path

Open the app home page > click `Sign in` in the header (sign-in page) — or click `Sign up` in the header (sign-up page).

## Labels

planned, INIT-0000000000-2767, feature, blocked-by:backend-scaffold, blocked-by:frontend-shell, blocked-by:user-accounts-api

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
  "AffectedServices": "app frontend",
  "TargetSymbols": "loginPage (new in frontend-shell):app/frontend/src/pages/login.js;registerPage (new in frontend-shell):app/frontend/src/pages/register.js;session (new in frontend-shell):app/frontend/src/session.js;renderErrors (new):app/frontend/src/errors.js",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Signed out, the sign-in page shows an `Email` input | anonymous reader | none | — | header > Sign in | input labelled `Email` visible | yes |
| Signed out, the sign-in page shows a `Password` input of type `password` | anonymous reader | none | — | header > Sign in | input labelled `Password` with `type="password"` | yes |
| Signed out, the sign-in page shows a `Sign in` button | anonymous reader | none | — | header > Sign in | button `Sign in` visible | yes |
| Submitting the sign-in form with email `jake@conduit.test`, password `Jake-Pass-123` changes the address to `/` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign in | address path `/` | yes |
| Submitting the sign-in form with email `jake@conduit.test`, password `Jake-Pass-123` shows `jake` in the header | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign in | header text `jake` visible | yes |
| Submitting the sign-in form with email `jake@conduit.test`, password `Jake-Pass-123` stores a non-empty token in `localStorage.jwt` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign in, browser storage panel | `localStorage.getItem('jwt')` is a non-empty string | yes |
| Submitting the sign-in form with email `jake@conduit.test`, password `wrong-pass` shows the error `email or password is invalid` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign in | list item `email or password is invalid` visible | yes |
| Submitting the sign-in form with email `jake@conduit.test`, password `wrong-pass` keeps the address at `/login` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign in | address path `/login` | yes |
| Submitting the sign-in form with email `jake@conduit.test`, password `wrong-pass` leaves `jake@conduit.test` in the `Email` input | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign in | `Email` input value `jake@conduit.test` | yes |
| Submitting the sign-in form with an empty email, password `Jake-Pass-123` shows the error `email can't be blank` | anonymous reader | none | — | header > Sign in | list item `email can't be blank` visible | yes |
| Signed out, the sign-up page shows a `Username` input | anonymous reader | none | — | header > Sign up | input labelled `Username` visible | yes |
| Signed out, the sign-up page shows an `Email` input | anonymous reader | none | — | header > Sign up | input labelled `Email` visible | yes |
| Signed out, the sign-up page shows a `Password` input of type `password` | anonymous reader | none | — | header > Sign up | input labelled `Password` with `type="password"` | yes |
| Signed out, the sign-up page shows a `Sign up` button | anonymous reader | none | — | header > Sign up | button `Sign up` visible | yes |
| Submitting the sign-up form with username `newauthor`, email `newauthor@conduit.test`, password `New-Pass-123` changes the address to `/` | anonymous reader | none | — | header > Sign up | address path `/` | yes |
| Submitting the sign-up form with username `newauthor`, email `newauthor@conduit.test`, password `New-Pass-123` shows `newauthor` in the header | anonymous reader | none | — | header > Sign up | header text `newauthor` visible | yes |
| Submitting the sign-up form with username `newauthor`, email `newauthor@conduit.test`, password `New-Pass-123` stores a non-empty token in `localStorage.jwt` | anonymous reader | none | — | header > Sign up, browser storage panel | `localStorage.getItem('jwt')` is a non-empty string | yes |
| Submitting the sign-up form with username `someone`, email `jake@conduit.test`, password `Pass-123` shows the error `email has already been taken` | anonymous reader | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign up | list item `email has already been taken` visible | yes |
| Submitting the sign-up form with username `someone`, email `jake@conduit.test`, password `Pass-123` keeps the address at `/register` | anonymous reader | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign up | address path `/register` | yes |
| Submitting the sign-up form with username `jake`, email `other@conduit.test`, password `Pass-123` shows the error `username has already been taken` | anonymous reader | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign up | list item `username has already been taken` visible | yes |
| Submitting the sign-up form with username `jake`, email `jake@conduit.test`, password `Pass-123` shows an error list of 2 items | anonymous reader | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123` | seeded-by:user-accounts-api | header > Sign up | 2 `li` elements in `ul.error-messages` | yes |
| Submitting the sign-up form with an empty username, email `x@conduit.test`, password `Pass-123` shows the error `username can't be blank` | anonymous reader | none | — | header > Sign up | list item `username can't be blank` visible | yes |

## Writes

| Key | Op |
|-----|----|
| `session_token` | transition:absent->stored |

## Reads

| Key | Source |
|-----|--------|
| `user.username` | spec |
| `user.email` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| Submitting the sign-in form with an empty email, password `Jake-Pass-123` shows the error `email can't be blank` | `user.email` | input | null | — |
| Submitting the sign-up form with an empty username, email `x@conduit.test`, password `Pass-123` shows the error `username can't be blank` | `user.username` | input | null | — |
