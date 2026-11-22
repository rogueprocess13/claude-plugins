# frontend-auth-pages

## Title

Authors can sign up and sign in from the browser

## Description

## Summary

Add the sign-up page (`/register`) and the sign-in page (`/login`). A successful sign-up or sign-in stores the token in `localStorage` under `jwt`, takes the browser to the home page, and switches the header to the signed-in state: the username and a "New Article" link.

## Outcome

**Serves:** O1

**Who:** Author

**Need:** Have an account to sign in with before publishing.

**Outcome:** A person can register as an author and sign in, and the app shows who is signed in.

## Background / Motivation

Authors need a way to create an account and sign in from the browser before they can publish. The brief fixes the header text for both states and the `localStorage` key `jwt`. The acceptance walkthrough starts with `jake` signing in.

## Proposed Behaviour

**Sign-in page (`/login`).** A form with an "Email" field, a "Password" field and a "Sign in" button.

- With correct credentials, the app stores the returned token in `localStorage` under `jwt`, and the browser goes to `/`.
- If the API returns errors, the page stays on `/login`, shows each error as `<field> <message>` in a list above the form (for example "email or password is invalid"), and stores nothing.

**Sign-up page (`/register`).** A form with a "Username" field, an "Email" field, a "Password" field and a "Sign up" button.

- On success, the app stores the returned token under `jwt` and goes to `/`.
- If the API returns errors, the page stays on `/register` and shows each error as `<field> <message>` above the form (for example "username has already been taken").

**Header.** When signed in, the header shows the username and a "New Article" link to `/editor`, and hides "Sign in" and "Sign up". When signed out it shows "Sign in" and "Sign up" as before.

**Staying signed in.** When the app loads with a `jwt` value, it asks the API for the current user, sending `Authorization: Token <jwt>`, and shows the signed-in header with that username. If the API answers 401, the app removes `jwt` and shows the signed-out header.

**Token on requests.** Every API request the app makes while a `jwt` is stored carries `Authorization: Token <jwt>`.

## Technical Context

- Repository `app`, folder `frontend/`. Builds on `src/router.js`, `src/api.js`, `src/header.js` and `src/main.js` from `frontend-scaffold`. Calls `POST /api/members`, `POST /api/members/login` and `GET /api/user` from `backend-auth`; the backend runs with `npm start` in `backend/` (`backend-scaffold`).
- `frontend/src/session.js` (new): `getToken()`, `setToken(token)`, `clearToken()` over `localStorage.getItem/setItem/removeItem('jwt')`; `currentUser` (null, or an object with `username` and `email`); `loadCurrentUser()`, which calls `GET /api/user` when a token exists and clears it on 401.
- `frontend/src/api.js`: add the header `Authorization: 'Token ' + getToken()` when a token exists.
- `frontend/src/header.js`: render the signed-in state from `session.currentUser`; re-render after sign-in and sign-up.
- `frontend/src/pages/login.js` and `frontend/src/pages/register.js` (new): forms built with `document.createElement`; on submit call the API, then `setToken`, set `currentUser`, re-render the header and `navigate('/')`. On a non-2xx response render each `errors` entry as a `<li>` with `textContent = field + ' ' + message` (parameter `ui.api_error_display`). Register them on `/login` and `/register` (parameter `frontend.signup_route`) by adding two `addRoute` lines to the route list in `src/main.js`, the one place every page ticket registers its routes.
- `frontend/src/main.js`: `await loadCurrentUser()` before the first header render.
- Inputs: give each input a `<label>` with the visible text above, and `name` attributes `username`, `email`, `password`.
- No browser-side validation: each `<form>` carries `novalidate`, no input has `required`, `minlength` or `pattern`, and the email input is `type="text"`. A blank field must reach the API, so the API's `can't be blank` message is what the page shows; the blank-field criteria below fail if the browser blocks the submit.
- Verify setup: the verify step starts the stack with `scripts/env-start.sh` (new in `backend-scaffold`), which restarts the backend, so each verify attempt starts with only the seed users `jake` and `jane` and no `alice`.

## Acceptance Criteria

- [ ] On `/login`, submitting email `jake@conduit.test` and password `Jake-Pass-123` changes the address bar to `http://localhost:5173/`.
- [ ] After `jake` signs in, the header shows the text `jake`.
- [ ] After `jake` signs in, the header shows a "New Article" link.
- [ ] After `jake` signs in, the header shows no "Sign in" link.
- [ ] After `jake` signs in, the header shows no "Sign up" link.
- [ ] After `jake` signs in, `localStorage` key `jwt` holds a non-empty string.
- [ ] After `jake` signs in, clicking "New Article" changes the address bar to `http://localhost:5173/editor`.
- [ ] After `jake` signs in and reloads the page, the header shows the text `jake`.
- [ ] After `jake` signs in and reloads the page, the `GET /api/user` request carries header `Authorization: Token ` followed by the stored `jwt` value.
- [ ] On `/login`, submitting email `jake@conduit.test` and password `Wrong-Pass-1` shows the text "email or password is invalid".
- [ ] On `/login`, submitting email `jake@conduit.test` and password `Wrong-Pass-1` leaves the address bar at `http://localhost:5173/login`.
- [ ] On `/login`, submitting email `jake@conduit.test` and password `Wrong-Pass-1` leaves no `jwt` key in `localStorage`.
- [ ] On `/login`, submitting an empty email with password `Jake-Pass-123` shows the text "email can't be blank".
- [ ] On `/register`, submitting username `alice`, email `alice@conduit.test` and password `Alice-Pass-123` changes the address bar to `http://localhost:5173/`.
- [ ] After `alice` signs up, the header shows the text `alice`.
- [ ] On `/register`, submitting username `jake`, email `new@conduit.test` and password `Alice-Pass-123` shows the text "username has already been taken".
- [ ] On `/register`, submitting username `newuser`, email `jane@conduit.test` and password `Alice-Pass-123` shows the text "email has already been taken".
- [ ] On `/register`, submitting username `newuser`, email `newuser@conduit.test` and an empty password shows the text "password can't be blank".
- [ ] Loading `http://localhost:5173/` with `localStorage` key `jwt` set to `not-a-token` shows the header "Sign in" link.
- [ ] Loading `http://localhost:5173/` with `localStorage` key `jwt` set to `not-a-token` leaves no `jwt` key in `localStorage`.

## Out of Scope

- Sign-out, user settings, profiles.
- The editor page and its redirect (`frontend-editor`).

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `src/pages/login.js`, `src/pages/register.js`, `src/session.js`, signed-in state in `src/header.js`, token header in `src/api.js` |

## Test User

`jake@conduit.test` (Author) — password `Jake-Pass-123`.

## Navigation Path

Start each verify attempt from a stack started by `bash scripts/env-start.sh` (the verify step does this), so the backend holds only the seed users. Sign-in: Home > header "Sign in" > fill Email and Password > "Sign in". There is no sign-out: before each sign-up criterion and each signed-out criterion, clear the session by running `localStorage.removeItem('jwt')` in the page and reloading. Sign-up: Home > header "Sign up" > fill Username, Email and Password > "Sign up". Register `alice` once per verify attempt.

## Labels

planned, INIT-0000000000-5252, feature, blocked-by:backend-scaffold, blocked-by:backend-auth, blocked-by:frontend-scaffold

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Add vanilla JS sign-in and sign-up pages that store the API token in localStorage under jwt, attach it as Authorization: Token on requests, and render the signed-in header from GET /api/user.",
  "AffectedServices": "app",
  "TargetSymbols": "session (new):app/frontend/src/session.js;loginPage (new):app/frontend/src/pages/login.js;registerPage (new):app/frontend/src/pages/register.js;renderHeader (new in frontend-scaffold):app/frontend/src/header.js;request (new in frontend-scaffold):app/frontend/src/api.js;main (new in frontend-scaffold):app/frontend/src/main.js",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| On `/login`, submitting email `jake@conduit.test` and password `Jake-Pass-123` changes the address bar to `http://localhost:5173/`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in | address bar `http://localhost:5173/` | yes |
| After `jake` signs in, the header shows the text `jake`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in | header text includes `jake` | yes |
| After `jake` signs in, the header shows a "New Article" link. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in | header link with text "New Article" | yes |
| After `jake` signs in, the header shows no "Sign in" link. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in | no header element with text "Sign in" | yes |
| After `jake` signs in, the header shows no "Sign up" link. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in | no header element with text "Sign up" | yes |
| After `jake` signs in, `localStorage` key `jwt` holds a non-empty string. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in | `localStorage.getItem('jwt')` has length 1 or more | yes |
| After `jake` signs in, clicking "New Article" changes the address bar to `http://localhost:5173/editor`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article | address bar `http://localhost:5173/editor` | yes |
| After `jake` signs in and reloads the page, the header shows the text `jake`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > reload | header text includes `jake` | yes |
| After `jake` signs in and reloads the page, the `GET /api/user` request carries header `Authorization: Token ` followed by the stored `jwt` value. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > reload | request header equals `Token ` plus the `jwt` value | yes |
| On `/login`, submitting email `jake@conduit.test` and password `Wrong-Pass-1` shows the text "email or password is invalid". | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | clear `jwt` and reload > Home > Sign in | text "email or password is invalid" above the form | yes |
| On `/login`, submitting email `jake@conduit.test` and password `Wrong-Pass-1` leaves the address bar at `http://localhost:5173/login`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | clear `jwt` and reload > Home > Sign in | address bar `http://localhost:5173/login` | yes |
| On `/login`, submitting email `jake@conduit.test` and password `Wrong-Pass-1` leaves no `jwt` key in `localStorage`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | clear `jwt` and reload > Home > Sign in | `localStorage.getItem('jwt')` is null | yes |
| On `/login`, submitting an empty email with password `Jake-Pass-123` shows the text "email can't be blank". | anonymous reader | none | — | clear `jwt` and reload > Home > Sign in | text "email can't be blank" | yes |
| On `/register`, submitting username `alice`, email `alice@conduit.test` and password `Alice-Pass-123` changes the address bar to `http://localhost:5173/`. | anonymous reader | 2 `user` records in state registered (`jake`, `jane`) and no `alice`, from a backend restarted by `bash scripts/env-start.sh` at the start of this attempt | seeded-by:backend-auth | clear `jwt` and reload > Home > Sign up | address bar `http://localhost:5173/` | yes |
| After `alice` signs up, the header shows the text `alice`. | anonymous reader | 2 `user` records in state registered (`jake`, `jane`) and no `alice`, from a backend restarted by `bash scripts/env-start.sh` at the start of this attempt | seeded-by:backend-auth | clear `jwt` and reload > Home > Sign up | header text includes `alice` | yes |
| On `/register`, submitting username `jake`, email `new@conduit.test` and password `Alice-Pass-123` shows the text "username has already been taken". | anonymous reader | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | clear `jwt` and reload > Home > Sign up | text "username has already been taken" | yes |
| On `/register`, submitting username `newuser`, email `jane@conduit.test` and password `Alice-Pass-123` shows the text "email has already been taken". | anonymous reader | 1 `user` in state registered (`jane`) | seeded-by:backend-auth | clear `jwt` and reload > Home > Sign up | text "email has already been taken" | yes |
| On `/register`, submitting username `newuser`, email `newuser@conduit.test` and an empty password shows the text "password can't be blank". | anonymous reader | none | — | clear `jwt` and reload > Home > Sign up | text "password can't be blank" | yes |
| Loading `http://localhost:5173/` with `localStorage` key `jwt` set to `not-a-token` shows the header "Sign in" link. | anonymous reader | none | — | Home | header link with text "Sign in" | yes |
| Loading `http://localhost:5173/` with `localStorage` key `jwt` set to `not-a-token` leaves no `jwt` key in `localStorage`. | anonymous reader | none | — | Home | `localStorage.getItem('jwt')` is null | yes |

## Writes

| Key | Op |
|-----|----|
| `local_storage.jwt` | create |

## Reads

| Key | Source |
|-----|--------|
| `user.username` | spec |
| `user.email` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| On `/login`, submitting email `jake@conduit.test` and password `Jake-Pass-123` changes the address bar to `http://localhost:5173/`. | `user.username` | state | value:jake | spec:backend-auth |
| On `/register`, submitting username `jake`, email `new@conduit.test` and password `Alice-Pass-123` shows the text "username has already been taken". | `user.username` | state | value:jake | spec:backend-auth |
| On `/register`, submitting username `newuser`, email `jane@conduit.test` and password `Alice-Pass-123` shows the text "email has already been taken". | `user.username` | state | value:jane | spec:backend-auth |
| On `/login`, submitting an empty email with password `Jake-Pass-123` shows the text "email can't be blank". | `user.email` | input | null | — |
| On `/register`, submitting username `newuser`, email `newuser@conduit.test` and an empty password shows the text "password can't be blank". | `user.password` | input | null | — |
