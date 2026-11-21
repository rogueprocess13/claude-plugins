# frontend-shell

## Title

The site header shows sign-in links or the signed-in author's name

## Description

## Summary

Add the parts of the site every page shares: the header, which changes with whether the visitor is signed in, and the routing that lets each page have its own address.

## Outcome

**Serves:** O1, O2

**Who:** Author, and Anonymous reader.

**Need:** See at a glance whether they are signed in, and reach the sign-in, sign-up and new-article pages.

**Outcome:** A signed-out visitor sees "Sign in" and "Sign up". A signed-in author sees their username and "New Article".

## Background / Motivation

The brief asks for five pages (home, sign-up, sign-in, editor, article) and a header with two states. The acceptance walk uses real addresses such as `/login`, `/editor` and `/article/my-first-post`, so each page needs its own path, and a path must work when it is loaded directly.

The brief keeps the sign-in token in the browser's local storage under the key `jwt`. It does not name a sign-out control, and user settings are out of scope, so the header has none.

## Proposed Behaviour

The header is shown on every page.

Signed out means the browser's local storage has no `jwt` key. The header then shows two links, `Sign in` and `Sign up`, and no `New Article` link. `Sign in` leads to `/login` and `Sign up` leads to `/register`. The site makes no current-user request.

When local storage has a `jwt` key, the site asks the API for the current user, sending the stored value in the header `Authorization: Token <value>`.

- If the API accepts the token, the header shows the username as plain text and a `New Article` link that leads to `/editor`. It shows neither `Sign in` nor `Sign up`.
- If the API answers 401, the site removes the `jwt` key and shows the signed-out header.

A username is always written as text. A username that contains markup, such as `<b>bold</b>`, appears as those literal characters.

Addresses:

- The site has five page addresses: `/` (home), `/login`, `/register`, `/editor` and `/article/<slug>`. The pages themselves arrive in later tickets. Until then the page area under the header is empty for these addresses.
- Any other address shows the text `Not found` under the header.
- Clicking a link in the header changes the address without reloading the document, and the browser Back button returns to the previous address.
- Loading any address directly shows the header.

## Technical Context

All paths are under `app/frontend/`. `index.html`, `vite.config.js` with its `/api` proxy, `src/main.js` and `src/style.css` come from the scaffold ticket. `GET /api/user` comes from the account endpoints ticket.

- New `src/router.js`: a route table for the five addresses, `navigate(path)` (uses `history.pushState`), a `popstate` listener, and one click listener that intercepts same-origin link clicks. A route maps to a render function that receives the page container. The `/article/<slug>` route passes the slug to its render function. An unknown path renders `Not found`.
- New `src/api.js`: one `fetch` wrapper. It calls relative `/api` URLs only, sends and parses JSON, adds `Authorization: Token <jwt>` when a token is stored, and returns the status with the parsed body.
- New `src/auth.js`: the only module that touches local storage. It gets, sets and clears the `jwt` key, and fetches the current user. Later pages call it; they do not use local storage directly.
- New `src/header.js`: renders the signed-out or signed-in header into the header container, and exposes a refresh function the sign-in and sign-up pages call after they store a token. API values are written with `textContent`.
- `src/main.js`: starts the router and renders the header.
- There is no frontend test runner. `npm run build` in `frontend/` must still exit with code 0. Checks run in the browser against `http://localhost:5173`, the address held by `frontend_port` (5173), with the API started by `npm start` in `backend/`. The API does not reload its code and keeps every account created since it started, so the checks of this ticket run against an API started after this ticket's code is in place.

## Acceptance Criteria

- [ ] With no `jwt` key in local storage, the header shows a `Sign in` link.
- [ ] With no `jwt` key in local storage, the header shows a `Sign up` link.
- [ ] With no `jwt` key in local storage, the header shows no `New Article` link.
- [ ] With no `jwt` key in local storage, loading the site sends no request to `/api/user`.
- [ ] Clicking `Sign in` in the header changes the address bar path to `/login`.
- [ ] Clicking `Sign up` in the header changes the address bar path to `/register`.
- [ ] Clicking `Sign in` in the header does not reload the document.
- [ ] After clicking `Sign in` from the home address, the browser Back button returns the address bar path to `/`.
- [ ] With a login token of `jake` under the `jwt` key, the header shows the text `jake`.
- [ ] With a login token of `jake` under the `jwt` key, the header shows a `New Article` link.
- [ ] With a login token of `jake` under the `jwt` key, the header shows no `Sign in` link.
- [ ] With a login token of `jake` under the `jwt` key, the header shows no `Sign up` link.
- [ ] With a login token of `jake` under the `jwt` key, clicking `New Article` changes the address bar path to `/editor`.
- [ ] With a login token of `jake` under the `jwt` key, the request to `/api/user` carries the header `Authorization: Token` followed by that token.
- [ ] With the text `not-a-jwt` under the `jwt` key, which the API answers with 401, the `jwt` key is absent from local storage after the page loads.
- [ ] With the text `not-a-jwt` under the `jwt` key, the header shows a `Sign in` link after the page loads.
- [ ] With the text `not-a-jwt` under the `jwt` key, the header shows no `New Article` link after the page loads.
- [ ] Loading the address `/login` directly shows the header with its `Sign in` link.
- [ ] Loading the address `/no-such-page` shows the text `Not found`.
- [ ] Loading the address `/no-such-page` shows the header with its `Sign in` link.
- [ ] A signed-in user whose username is `<b>bold</b>` sees the literal characters `<b>bold</b>` in the header.
- [ ] Loading the address `/login` directly does not show the text `Not found`.
- [ ] Loading the address `/article/some-slug` directly does not show the text `Not found`.
- [ ] With the text `not-a-jwt` under the `jwt` key and the API stopped, the header shows a `Sign in` link after the page loads.
- [ ] With the text `not-a-jwt` under the `jwt` key and the API stopped, the `jwt` key is absent from local storage after the page loads.

## Out of Scope

The content of the five pages, the redirect from `/editor` to `/login`, and the forms. A sign-out control, a home link in the header, user settings and a profile page are not built.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/src/router.js`, `frontend/src/api.js`, `frontend/src/auth.js`, `frontend/src/header.js`, `frontend/src/main.js` |
| BE | app | none changed; the pages call the existing API |

- Assumption: When the current-user request fails for any reason other than a 401 answer, such as the API not running, the site removes the stored token and shows the signed-out header.

## Test User

`jake@conduit.test`, password `Jake-Pass-123` (seeded author). No sign-in page exists yet, so get a token for `jake` from the login endpoint and put it under the `jwt` key in the browser's local storage. Signed-out checks need no account.

## Navigation Path

Stop any process that is listening on port 3000, then start the API (`npm start` in `backend/`). If `npm start` prints `Port 3000 is already in use`, an older API is still running: stop it and start again. Start the frontend (`npm run dev` in `frontend/`). Open the site. The header is at the top of every page. For the signed-in checks, put a login token of `jake` under the `jwt` key in the browser's local storage, then reload.

## Labels

planned, INIT-0000000000-5702, feature, blocked-by:scaffold-packages, blocked-by:store-and-seed, blocked-by:auth-endpoints

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
  "TargetSymbols": "Vite:app/CLAUDE.md:22;LOCAL_URL:app/CLAUDE.md:34;UAT_URL:app/CLAUDE.md:36;router (new):app/frontend/src/router.js;api (new):app/frontend/src/api.js;auth (new):app/frontend/src/auth.js;header (new):app/frontend/src/header.js;main (new in scaffold-packages):app/frontend/src/main.js;viteConfig (new in scaffold-packages):app/frontend/vite.config.js",
  "Kind": "business",
  "Serves": [
    "O1",
    "O2"
  ],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|---|
| With no `jwt` key in local storage, the header shows a `Sign in` link. | Anonymous reader | none | — | Open the site | a link with the text Sign in is visible | yes |
| With no `jwt` key in local storage, the header shows a `Sign up` link. | Anonymous reader | none | — | Open the site | a link with the text Sign up is visible | yes |
| With no `jwt` key in local storage, the header shows no `New Article` link. | Anonymous reader | none | — | Open the site | no element with the text New Article exists | yes |
| With no `jwt` key in local storage, loading the site sends no request to `/api/user`. | Anonymous reader | none | — | Open the site | the network log holds 0 requests to /api/user | yes |
| Clicking `Sign in` in the header changes the address bar path to `/login`. | Anonymous reader | none | — | Open the site > click `Sign in` | path is /login | yes |
| Clicking `Sign up` in the header changes the address bar path to `/register`. | Anonymous reader | none | — | Open the site > click `Sign up` | path is /register | yes |
| Clicking `Sign in` in the header does not reload the document. | Anonymous reader | none | — | Open the site > click `Sign in` | a value set on `window` before the click is still there after it | yes |
| After clicking `Sign in` from the home address, the browser Back button returns the address bar path to `/`. | Anonymous reader | none | — | Open the site > click `Sign in` > press the browser Back button | path is / | yes |
| With a login token of `jake` under the `jwt` key, the header shows the text `jake`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > put a login token of `jake` under the `jwt` key in the browser's local storage > reload | the text jake is visible in the header | yes |
| With a login token of `jake` under the `jwt` key, the header shows a `New Article` link. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > put a login token of `jake` under the `jwt` key in the browser's local storage > reload | a link with the text New Article is visible | yes |
| With a login token of `jake` under the `jwt` key, the header shows no `Sign in` link. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > put a login token of `jake` under the `jwt` key in the browser's local storage > reload | no element with the text Sign in exists | yes |
| With a login token of `jake` under the `jwt` key, the header shows no `Sign up` link. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > put a login token of `jake` under the `jwt` key in the browser's local storage > reload | no element with the text Sign up exists | yes |
| With a login token of `jake` under the `jwt` key, clicking `New Article` changes the address bar path to `/editor`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > put a login token of `jake` under the `jwt` key in the browser's local storage > reload > click `New Article` | path is /editor | yes |
| With a login token of `jake` under the `jwt` key, the request to `/api/user` carries the header `Authorization: Token` followed by that token. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > put a login token of `jake` under the `jwt` key in the browser's local storage > reload | the request header Authorization equals Token, one space, the stored token | yes |
| With the text `not-a-jwt` under the `jwt` key, which the API answers with 401, the `jwt` key is absent from local storage after the page loads. | Anonymous reader | none | — | Open the site > put the text `not-a-jwt` under the `jwt` key in the browser's local storage > reload | local storage has no jwt key | yes |
| With the text `not-a-jwt` under the `jwt` key, the header shows a `Sign in` link after the page loads. | Anonymous reader | none | — | Open the site > put the text `not-a-jwt` under the `jwt` key in the browser's local storage > reload | a link with the text Sign in is visible | yes |
| With the text `not-a-jwt` under the `jwt` key, the header shows no `New Article` link after the page loads. | Anonymous reader | none | — | Open the site > put the text `not-a-jwt` under the `jwt` key in the browser's local storage > reload | no element with the text New Article exists | yes |
| Loading the address `/login` directly shows the header with its `Sign in` link. | Anonymous reader | none | — | Open the site > add `/login` to the site address | a link with the text Sign in is visible | yes |
| Loading the address `/no-such-page` shows the text `Not found`. | Anonymous reader | none | — | Open the site > add `/no-such-page` to the site address | the text Not found is visible | yes |
| Loading the address `/no-such-page` shows the header with its `Sign in` link. | Anonymous reader | none | — | Open the site > add `/no-such-page` to the site address | a link with the text Sign in is visible | yes |
| A signed-in user whose username is `<b>bold</b>` sees the literal characters `<b>bold</b>` in the header. | Author (created in the check) | built in the test: an account with that username, created through the sign-up endpoint during the check, on an API started fresh for this ticket (the same API refuses a second sign-up with that username) | — | Open the site > put that account's token under the `jwt` key in the browser's local storage > reload | the header text is <b>bold</b> and the header holds no `b` element | yes |
| Loading the address `/login` directly does not show the text `Not found`. | Anonymous reader | none | — | Open the site > add `/login` to the site address | the page holds no text Not found | yes |
| Loading the address `/article/some-slug` directly does not show the text `Not found`. | Anonymous reader | none | — | Open the site > add `/article/some-slug` to the site address | the page holds no text Not found | yes |
| With the text `not-a-jwt` under the `jwt` key and the API stopped, the header shows a `Sign in` link after the page loads. | Anonymous reader | none | — | Open the site > put the text `not-a-jwt` under the `jwt` key in the browser's local storage > stop the API > reload | a link with the text Sign in is visible | yes |
| With the text `not-a-jwt` under the `jwt` key and the API stopped, the `jwt` key is absent from local storage after the page loads. | Anonymous reader | none | — | Open the site > put the text `not-a-jwt` under the `jwt` key in the browser's local storage > stop the API > reload | local storage has no jwt key | yes |

## Writes

| Key | Op |
|---|---|
| `client_session.jwt` | update |

## Reads

| Key | Source |
|---|---|
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|---|---|---|---|---|
| With no `jwt` key in local storage, the header shows a `Sign in` link. | `client_session.jwt` | state | null | spec:frontend-shell |
| With no `jwt` key in local storage, the header shows a `Sign up` link. | `client_session.jwt` | state | null | spec:frontend-shell |
| With no `jwt` key in local storage, the header shows no `New Article` link. | `client_session.jwt` | state | null | spec:frontend-shell |
| With no `jwt` key in local storage, loading the site sends no request to `/api/user`. | `client_session.jwt` | state | null | spec:frontend-shell |
| Clicking `Sign in` in the header changes the address bar path to `/login`. | `client_session.jwt` | state | null | spec:frontend-shell |
| Clicking `Sign up` in the header changes the address bar path to `/register`. | `client_session.jwt` | state | null | spec:frontend-shell |
| Clicking `Sign in` in the header does not reload the document. | `client_session.jwt` | state | null | spec:frontend-shell |
| After clicking `Sign in` from the home address, the browser Back button returns the address bar path to `/`. | `client_session.jwt` | state | null | spec:frontend-shell |
| With a login token of `jake` under the `jwt` key, the header shows the text `jake`. | `user.username` | state | value:jake | spec:store-and-seed |
| With a login token of `jake` under the `jwt` key, the header shows a `New Article` link. | `user.username` | state | value:jake | spec:store-and-seed |
| With a login token of `jake` under the `jwt` key, the header shows no `Sign in` link. | `user.username` | state | value:jake | spec:store-and-seed |
| With a login token of `jake` under the `jwt` key, the header shows no `Sign up` link. | `user.username` | state | value:jake | spec:store-and-seed |
| With a login token of `jake` under the `jwt` key, clicking `New Article` changes the address bar path to `/editor`. | `user.username` | state | value:jake | spec:store-and-seed |
| With a login token of `jake` under the `jwt` key, the request to `/api/user` carries the header `Authorization: Token` followed by that token. | `user.username` | state | value:jake | spec:store-and-seed |
| Loading the address `/login` directly shows the header with its `Sign in` link. | `client_session.jwt` | state | null | spec:frontend-shell |
| Loading the address `/no-such-page` shows the header with its `Sign in` link. | `client_session.jwt` | state | null | spec:frontend-shell |
