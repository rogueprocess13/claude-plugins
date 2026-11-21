# auth-pages

## Title

People can sign up and sign in from the web app

## Description

## Summary

Add the sign-up page at `/register` and the sign-in page at `/login`. On success the app stores the token, shows the person as signed in and takes them to the home page. On failure it lists the API's error messages above the form and stays on the page.

## Outcome

**Serves:** O2

**Who:** Author

**Need:** Create an account and sign in so they can publish.

**Outcome:** A person can register as an author or sign in with an existing account, and the app then shows them as signed in.

## Background / Motivation

The brief's browser check has `jake` sign in before publishing, and the header links "Sign in" and "Sign up" need pages behind them. The brief does not say where people land after signing up or signing in, or how API errors are shown; this ticket follows the decided parameters (home page; a list of `<field> <message>` lines above the form).

## Proposed Behaviour

**Sign up (`/register`)**

- The header's "Sign up" link opens the page. It has the fields Username, Email and Password and a "Sign up" button.
- On success (201) the app stores the returned token in `localStorage` under `jwt`, goes to the home page, and the header shows the new username.
- On a 422 the page lists every error message above the form, one line per message, as `<field> <message>` (for example `email has already been taken`), and stays on `/register`.

**Sign in (`/login`)**

- The header's "Sign in" link opens the page. It has the fields Email and Password and a "Sign in" button.
- On success (200) the app stores the returned token in `localStorage` under `jwt`, goes to the home page, and the header shows the username and "New Article".
- On a 401 the page shows `email or password is invalid` above the form and stays on `/login`.
- On a 422 the page lists every error message the same way and stays on `/login`.

## Technical Context

- Repository `app`, folder `frontend/`, built on the router, API client, session and header from `frontend-shell`, the error list renderer `frontend/src/errors.js` and the home page from `reader-pages`, the register and login endpoints from `user-auth-api`, and the seeded user `jake` from `backend-foundation`.
- Parameters: `ui.signup_path` (/register), `ui.auth_landing` (the home page /), `ui.error_display` (a list above the form, one line per message, formatted field then message).
- New files:
  - `frontend/src/pages/register.js`: form posting `{"user":{"username","email","password"}}` to `POST /api/members`.
  - `frontend/src/pages/login.js`: form posting `{"user":{"email","password"}}` to `POST /api/members/login`.
  - Both call `setToken(data.user.token)`, refresh the header and `navigate('/')` on success, and call `renderErrors(data.errors)` on a 401 or 422.
- Registers `/register` and `/login` in the router path table.
- Runs after `reader-pages` for two reasons: it calls `renderErrors` from `frontend/src/errors.js`, which `reader-pages` creates, and both tickets add entries to the path table in `frontend/src/router.js`, so the edits land one after the other.

## Acceptance Criteria

- [ ] Clicking "Sign up" in the header changes the address bar path to `/register`, starting signed out with no `jwt` key in `localStorage`
- [ ] The sign-up page shows an input field labelled Username, starting signed out with no `jwt` key in `localStorage`
- [ ] The sign-up page shows an input field labelled Email, starting signed out with no `jwt` key in `localStorage`
- [ ] The sign-up page shows an input field labelled Password, starting signed out with no `jwt` key in `localStorage`
- [ ] The sign-up page shows a button with the text "Sign up", starting signed out with no `jwt` key in `localStorage`
- [ ] Signing up as username `alice`, email `alice@conduit.test`, password `Alice-Pass-123` changes the address bar path to `/`, starting signed out with no `jwt` key in `localStorage`
- [ ] After signing up as `alice`, the header shows the text "alice"
- [ ] After signing up as `alice`, `localStorage` key `jwt` holds a non-empty token
- [ ] Signing up with username `bob`, email `jake@conduit.test`, password `Bob-Pass-123` shows the line "email has already been taken", starting signed out with no `jwt` key in `localStorage`
- [ ] Signing up with username `jake`, email `bob@conduit.test`, password `Bob-Pass-123` shows the line "username has already been taken", starting signed out with no `jwt` key in `localStorage`
- [ ] Submitting the sign-up form with all three fields empty shows the line "username can't be blank", starting signed out with no `jwt` key in `localStorage`
- [ ] Submitting the sign-up form with all three fields empty shows the line "email can't be blank", starting signed out with no `jwt` key in `localStorage`
- [ ] Submitting the sign-up form with all three fields empty shows the line "password can't be blank", starting signed out with no `jwt` key in `localStorage`
- [ ] After a rejected sign-up the address bar path stays `/register`, starting signed out with no `jwt` key in `localStorage`
- [ ] Clicking "Sign in" in the header changes the address bar path to `/login`, starting signed out with no `jwt` key in `localStorage`
- [ ] The sign-in page shows an input field labelled Email, starting signed out with no `jwt` key in `localStorage`
- [ ] The sign-in page shows an input field labelled Password, starting signed out with no `jwt` key in `localStorage`
- [ ] The sign-in page shows a button with the text "Sign in", starting signed out with no `jwt` key in `localStorage`
- [ ] Signing in as `jake@conduit.test` with password `Jake-Pass-123` changes the address bar path to `/`, starting signed out with no `jwt` key in `localStorage`
- [ ] After jake signs in, the header shows the text "jake"
- [ ] After jake signs in, the header shows a link with the text "New Article"
- [ ] After jake signs in, `localStorage` key `jwt` holds a non-empty token
- [ ] Signing in as `jake@conduit.test` with password `wrong-password` shows the line "email or password is invalid", starting signed out with no `jwt` key in `localStorage`
- [ ] After a rejected sign-in with a wrong password the address bar path stays `/login`, starting signed out with no `jwt` key in `localStorage`
- [ ] Submitting the sign-in form with an empty email and password `Jake-Pass-123` shows the line "email can't be blank", starting signed out with no `jwt` key in `localStorage`

## Out of Scope

A "Sign out" control, password reset, profile and settings pages, and remembering the page a person came from.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/src/pages/register.js`, `frontend/src/pages/login.js` |

## Test User

`jake@conduit.test` — password `Jake-Pass-123`

## Environment

- [x] Local (`http://localhost:5173` for the app, with the API from `npm start` in `backend/` on port 3000)

Browser checks need the API running: run `npm install` and `npm start` in `backend/`, then `npm run dev` in `frontend/`. The store is seeded again only when the API starts, so each verification attempt (including a retry) starts the API afresh and uses a new browser profile with empty `localStorage`.

## Navigation Path

Start the API with `npm start` in `backend/` and the app with `npm run dev` in `frontend/` > open the app's home page > click "Sign in" in the header > enter the email and password > click the "Sign in" button. For sign-up: open the app's home page > click "Sign up" in the header > enter username, email and password > click the "Sign up" button.

## Labels

planned, INIT-0000000000-5856, feature, blocked-by:backend-foundation, blocked-by:user-auth-api, blocked-by:frontend-shell, blocked-by:reader-pages

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "Add sign-up and sign-in page renderers that store the returned token as jwt, land on the home page and list API errors as field-message lines.",
  "AffectedServices": "app",
  "TargetSymbols": "renderRegister (new):app/frontend/src/pages/register.js;renderLogin (new):app/frontend/src/pages/login.js;setToken (new in frontend-shell):app/frontend/src/session.js;renderErrors (new in reader-pages):app/frontend/src/errors.js",
  "Kind": "business",
  "Serves": ["O2"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Clicking "Sign up" in the header changes the address bar path to `/register`, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign up" | `location.pathname` is `/register` | yes |
| The sign-up page shows an input field labelled Username, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign up" | input labelled Username | yes |
| The sign-up page shows an input field labelled Email, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign up" | input labelled Email | yes |
| The sign-up page shows an input field labelled Password, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign up" | input labelled Password | yes |
| The sign-up page shows a button with the text "Sign up", starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign up" | button "Sign up" | yes |
| Signing up as username `alice`, email `alice@conduit.test`, password `Alice-Pass-123` changes the address bar path to `/`, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > Sign up > fill form > Sign up | `location.pathname` is `/` | yes |
| After signing up as `alice`, the header shows the text "alice" | anonymous reader | none | — | Home > Sign up > fill form > Sign up | text "alice" in the header | yes |
| After signing up as `alice`, `localStorage` key `jwt` holds a non-empty token | anonymous reader | none | — | Home > Sign up > fill form > Sign up | `localStorage.getItem('jwt')` is a non-empty string | yes |
| Signing up with username `bob`, email `jake@conduit.test`, password `Bob-Pass-123` shows the line "email has already been taken", starting signed out with no `jwt` key in `localStorage` | anonymous reader | 1 `user` `jake` with email `jake@conduit.test` | seeded-by:backend-foundation | Home > Sign up > fill form > Sign up | line "email has already been taken" | yes |
| Signing up with username `jake`, email `bob@conduit.test`, password `Bob-Pass-123` shows the line "username has already been taken", starting signed out with no `jwt` key in `localStorage` | anonymous reader | 1 `user` `jake` | seeded-by:backend-foundation | Home > Sign up > fill form > Sign up | line "username has already been taken" | yes |
| Submitting the sign-up form with all three fields empty shows the line "username can't be blank", starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > Sign up > Sign up | line "username can't be blank" | yes |
| Submitting the sign-up form with all three fields empty shows the line "email can't be blank", starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > Sign up > Sign up | line "email can't be blank" | yes |
| Submitting the sign-up form with all three fields empty shows the line "password can't be blank", starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > Sign up > Sign up | line "password can't be blank" | yes |
| After a rejected sign-up the address bar path stays `/register`, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > Sign up > Sign up with empty fields | `location.pathname` is `/register` | yes |
| Clicking "Sign in" in the header changes the address bar path to `/login`, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign in" | `location.pathname` is `/login` | yes |
| The sign-in page shows an input field labelled Email, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign in" | input labelled Email | yes |
| The sign-in page shows an input field labelled Password, starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign in" | input labelled Password | yes |
| The sign-in page shows a button with the text "Sign in", starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > click "Sign in" | button "Sign in" | yes |
| Signing in as `jake@conduit.test` with password `Jake-Pass-123` changes the address bar path to `/`, starting signed out with no `jwt` key in `localStorage` | author | 1 `user` `jake` | seeded-by:backend-foundation | Home > Sign in > fill form > Sign in | `location.pathname` is `/` | yes |
| After jake signs in, the header shows the text "jake" | author | 1 `user` `jake` | seeded-by:backend-foundation | Home > Sign in > fill form > Sign in | text "jake" in the header | yes |
| After jake signs in, the header shows a link with the text "New Article" | author | 1 `user` `jake` | seeded-by:backend-foundation | Home > Sign in > fill form > Sign in | link "New Article" visible | yes |
| After jake signs in, `localStorage` key `jwt` holds a non-empty token | author | 1 `user` `jake` | seeded-by:backend-foundation | Home > Sign in > fill form > Sign in | `localStorage.getItem('jwt')` is a non-empty string | yes |
| Signing in as `jake@conduit.test` with password `wrong-password` shows the line "email or password is invalid", starting signed out with no `jwt` key in `localStorage` | author | 1 `user` `jake` | seeded-by:backend-foundation | Home > Sign in > fill form > Sign in | line "email or password is invalid" | yes |
| After a rejected sign-in with a wrong password the address bar path stays `/login`, starting signed out with no `jwt` key in `localStorage` | author | 1 `user` `jake` | seeded-by:backend-foundation | Home > Sign in > fill form > Sign in | `location.pathname` is `/login` | yes |
| Submitting the sign-in form with an empty email and password `Jake-Pass-123` shows the line "email can't be blank", starting signed out with no `jwt` key in `localStorage` | anonymous reader | none | — | Home > Sign in > fill password only > Sign in | line "email can't be blank" | yes |

## Writes

| Key | Op |
|-----|----|
| `local_storage.jwt` | transition:absent->present |
| `user` | append |

## Reads

| Key | Source |
|-----|--------|
| `user.username` | spec |
| `user.email` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| Signing up with username `jake`, email `bob@conduit.test`, password `Bob-Pass-123` shows the line "username has already been taken", starting signed out with no `jwt` key in `localStorage` | `user.username` | state | value:jake | spec:backend-foundation |
| Signing in as `jake@conduit.test` with password `Jake-Pass-123` changes the address bar path to `/`, starting signed out with no `jwt` key in `localStorage` | `user.username` | state | value:jake | spec:backend-foundation |
| Submitting the sign-in form with an empty email and password `Jake-Pass-123` shows the line "email can't be blank", starting signed out with no `jwt` key in `localStorage` | `user.email` | input | null | — |
