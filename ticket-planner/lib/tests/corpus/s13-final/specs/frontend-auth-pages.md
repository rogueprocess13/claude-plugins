# frontend-auth-pages

## Title

Authors can sign up and sign in from the app

## Description

## Summary

Build the sign-up page (`/register`) and the sign-in page (`/login`). A successful sign-up or sign-in stores the token, shows the author as signed in, and goes to the home page. A failed one shows the API's error messages on the form.

## Outcome

**Serves:** O1

**Who:** Author

**Need:** Create an account and sign in, so the app knows who is publishing.

**Outcome:** A person can register as an author, sign in with their email and password, and the app then shows them as signed in.

## Background / Motivation

The brief's browser check has `jake` sign in before publishing. The brief does not say what the forms show on an error or where they go on success, so the RealWorld reference frontend applies: errors are listed above the form as "field message" lines, and a successful sign-up or sign-in goes to the home page.

## Proposed Behaviour

- The sign-up page has the inputs Username, Email and Password, and a "Sign up" button.
- The sign-in page has the inputs Email and Password, and a "Sign in" button.
- The Password inputs hide what is typed.
- On success, the app stores the returned token in `localStorage` under `jwt`, the header shows the signed-in state, and the address changes to `/`.
- On an error, the form stays on the page and shows each API error as one line of the form "<field> <message>", for example "email has already been taken" or "email or password is invalid".
- The sign-up page links to the sign-in page with "Have an account?", and the sign-in page links to the sign-up page with "Need an account?".

## Technical Context

- Builds on `frontend-shell`: the router in `frontend/src/router.js` (routes `/register` and `/login`), the API client in `frontend/src/api.js`, the session in `frontend/src/session.js` (`setToken` stores the token and updates the header), and the placeholder pages `frontend/src/pages/register.js` and `frontend/src/pages/login.js`, which this ticket replaces.
- Calls `api-user-auth`: `POST /api/members` with `{"user":{"username","email","password"}}` (201 on success, 422 with an `errors` map on failure) and `POST /api/members/login` with `{"user":{"email","password"}}` (200 on success, 401 or 422 with an `errors` map on failure).
- Error display (`frontend.forms.error_display`): a `<ul class="error-messages">` with one `<li>` per message, the text being the field name, a space, and the message. Text is inserted as text, never as HTML.
- Landing (`frontend.auth.landing`): after `setToken`, navigate to `/` through the router.
- Inputs use `placeholder` text "Username", "Email" and "Password"; the Password inputs use `type="password"`.

## Acceptance Criteria

- [ ] The `/register` page shows an input with the placeholder "Username"
- [ ] The `/register` page shows an input with the placeholder "Email"
- [ ] The `/register` page shows a password input with the placeholder "Password"
- [ ] Signing up as `alice` / `alice@conduit.test` / `Alice-Pass-123` changes the address to `/`
- [ ] After signing up as `alice`, the header shows the text "alice"
- [ ] After signing up as `alice`, `localStorage` holds a `jwt` value
- [ ] Signing up with the email `jake@conduit.test` shows the error line "email has already been taken"
- [ ] Signing up with the username `jake` shows the error line "username has already been taken"
- [ ] Signing up with an empty Username shows the error line "username can't be blank"
- [ ] After a failed sign-up, the address stays `/register`
- [ ] The `/login` page shows an input with the placeholder "Email"
- [ ] The `/login` page shows a password input with the placeholder "Password"
- [ ] Signing in as `jake@conduit.test` / `Jake-Pass-123` changes the address to `/`
- [ ] After signing in as `jake`, the header shows the text "jake"
- [ ] After signing in as `jake`, the header shows the link "New Article"
- [ ] After signing in as `jake`, `localStorage` holds a `jwt` value
- [ ] Signing in as `jake@conduit.test` with the password `wrong-pass` shows the error line "email or password is invalid"
- [ ] Signing in with an empty Email shows the error line "email can't be blank"
- [ ] After a failed sign-in, `localStorage` holds no `jwt` key
- [ ] Clicking "Need an account?" on the `/login` page changes the address to `/register`
- [ ] Clicking "Have an account?" on the `/register` page changes the address to `/login`
- [ ] Running `npm run build` in `frontend/` exits with code 0

## Test User

- Author: `jake@conduit.test` / `Jake-Pass-123` (username `jake`).
- New author for the sign-up check: `alice` / `alice@conduit.test` / `Alice-Pass-123`. The API restart at the start of every verification attempt (Navigation Path step 1) removes `alice`, so a retry can sign up as `alice` again.
- Signed-out visitor: clear `localStorage` before each check.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Frontend | app | sign-up page, sign-in page, form error list |

## Navigation Path

1. Before every verification attempt, including a retry, stop any process listening on port 3000 or 5173. Then, from this ticket's branch checkout, run `npm install` and `npm start` in `backend/`, and `npm install` and `npm run dev` in `frontend/`. Open the app at `http://localhost:5173`. Restarting the API re-seeds the store, so every attempt starts from the 2 seeded `user` and 2 seeded `article` records.
2. Open the app home page on port 5173 in a browser, signed out.
3. Click "Sign up" in the header to reach the sign-up page, or "Sign in" to reach the sign-in page.
4. Fill in the form and click the "Sign up" or "Sign in" button.

## Labels

planned, INIT-0000000000-9899, feature, blocked-by:frontend-shell, blocked-by:api-user-auth

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 3,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Replace the sign-up and sign-in placeholder pages with forms that call the user endpoints, store the token through the session module, list API errors and land on the home page.",
  "AffectedServices": "app",
  "TargetSymbols": "registerPage (new in frontend-shell):app/frontend/src/pages/register.js;loginPage (new in frontend-shell):app/frontend/src/pages/login.js;setToken (new in frontend-shell):app/frontend/src/session.js",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| The `/register` page shows an input with the placeholder "Username" | anonymous reader | none | — | Home page > Sign up | input with placeholder "Username" | yes |
| The `/register` page shows an input with the placeholder "Email" | anonymous reader | none | — | Home page > Sign up | input with placeholder "Email" | yes |
| The `/register` page shows a password input with the placeholder "Password" | anonymous reader | none | — | Home page > Sign up | input of type password with placeholder "Password" | yes |
| Signing up as `alice` / `alice@conduit.test` / `Alice-Pass-123` changes the address to `/` | anonymous reader | none | — | Home page > Sign up | address path `/` | yes |
| After signing up as `alice`, the header shows the text "alice" | author | none | — | Home page > Sign up | text "alice" in the header | yes |
| After signing up as `alice`, `localStorage` holds a `jwt` value | author | none | — | Home page > Sign up | `localStorage.getItem('jwt')` is a non-empty string | yes |
| Signing up with the email `jake@conduit.test` shows the error line "email has already been taken" | anonymous reader | seeded `user` jake | seeded-by:backend-foundation | Home page > Sign up | error line "email has already been taken" | yes |
| Signing up with the username `jake` shows the error line "username has already been taken" | anonymous reader | seeded `user` jake | seeded-by:backend-foundation | Home page > Sign up | error line "username has already been taken" | yes |
| Signing up with an empty Username shows the error line "username can't be blank" | anonymous reader | none | — | Home page > Sign up | error line "username can't be blank" | yes |
| After a failed sign-up, the address stays `/register` | anonymous reader | seeded `user` jake (for a duplicate email) | seeded-by:backend-foundation | Home page > Sign up | address path `/register` | yes |
| The `/login` page shows an input with the placeholder "Email" | anonymous reader | none | — | Home page > Sign in | input with placeholder "Email" | yes |
| The `/login` page shows a password input with the placeholder "Password" | anonymous reader | none | — | Home page > Sign in | input of type password with placeholder "Password" | yes |
| Signing in as `jake@conduit.test` / `Jake-Pass-123` changes the address to `/` | author | seeded `user` jake | seeded-by:backend-foundation | Home page > Sign in | address path `/` | yes |
| After signing in as `jake`, the header shows the text "jake" | author | seeded `user` jake | seeded-by:backend-foundation | Home page > Sign in | text "jake" in the header | yes |
| After signing in as `jake`, the header shows the link "New Article" | author | seeded `user` jake | seeded-by:backend-foundation | Home page > Sign in | link "New Article" visible | yes |
| After signing in as `jake`, `localStorage` holds a `jwt` value | author | seeded `user` jake | seeded-by:backend-foundation | Home page > Sign in | `localStorage.getItem('jwt')` is a non-empty string | yes |
| Signing in as `jake@conduit.test` with the password `wrong-pass` shows the error line "email or password is invalid" | anonymous reader | seeded `user` jake | seeded-by:backend-foundation | Home page > Sign in | error line "email or password is invalid" | yes |
| Signing in with an empty Email shows the error line "email can't be blank" | anonymous reader | none | — | Home page > Sign in | error line "email can't be blank" | yes |
| After a failed sign-in, `localStorage` holds no `jwt` key | anonymous reader | seeded `user` jake | seeded-by:backend-foundation | Home page > Sign in | `localStorage.getItem('jwt')` returns null | yes |
| Clicking "Need an account?" on the `/login` page changes the address to `/register` | anonymous reader | none | — | Home page > Sign in > Need an account? | address path `/register` | yes |
| Clicking "Have an account?" on the `/register` page changes the address to `/login` | anonymous reader | none | — | Home page > Sign up > Have an account? | address path `/login` | yes |
| Running `npm run build` in `frontend/` exits with code 0 | developer | none | — | terminal in `frontend/` | exit code 0 | yes |

## Writes

| Key | Op |
|-----|----|
| `browser_session.jwt` | transition:absent->present |

## Reads

| Key | Source |
|-----|--------|
| `user.username` | spec |
| `user.email` | spec |

## Preconditions

None.
