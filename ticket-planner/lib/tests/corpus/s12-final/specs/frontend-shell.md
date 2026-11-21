# frontend-shell

## Title

The page header shows whether the visitor is signed in

## Description

## Summary

Create the `frontend/` web app (Vite + vanilla JS on port 5173) with its page header, path-based navigation and the connection to the API. The header shows "Sign in" and "Sign up" to a visitor who is not signed in, and the username plus "New Article" to a signed-in author. The pages themselves come in later tickets.

## Outcome

**Serves:** O2

**Who:** Author

**Need:** Create an account and sign in so they can publish.

**Outcome:** A person can register as an author or sign in with an existing account, and the app then shows them as signed in.

## Background / Motivation

There is no frontend yet. Every page in this slice needs the same header, the same way of moving between pages without a full reload, and the same way of calling the API with the stored token. The brief says the header shows "Sign in" / "Sign up" when signed out and the username plus "New Article" when signed in, and that the token is kept in the browser's `localStorage` under `jwt`.

## Proposed Behaviour

- Opening the app shows a header on every page.
- With no `jwt` stored, the header shows a "Sign in" link and a "Sign up" link, and no "New Article" link.
- With a valid `jwt` stored, the app asks the API who is signed in, and the header shows that user's username and a "New Article" link, and no "Sign in" link.
- With a `jwt` the API rejects (401), the app removes `jwt` from `localStorage` and shows the signed-out header.
- Header links move between pages by changing the address bar path without a full page reload, and the browser Back button returns to the previous page.
- Opening any path directly (for example a deep link to an article) loads the app instead of a server "not found" page.
- Calls to `/api/...` from the browser reach the API on port 3000 through the dev server.

## Technical Context

- Repository `app`, folder `frontend/` (new). The dev server must run on port 5173 because `LOCAL_URL` and `UAT_URL` are `http://localhost:5173` (`app/CLAUDE.md:34`, `app/CLAUDE.md:36`), and `npm run dev` / `npm run build` run from `frontend/` (`app/CLAUDE.md:43`). Vanilla JS only, no framework (`app/CLAUDE.md:22`); do not restore the React frontend from the tag `sandbox-develop-before-reset-2026-10-29`.
- Parameters: `ui.port` (5173), `api.port` (3000).
- Uses `GET /api/user` from `user-auth-api` and the server from `backend-foundation`.
- New files:
  - `frontend/package.json`: `scripts.dev = vite`, `scripts.build = vite build`, dev dependency `vite`, `engines.node >= 22`.
  - `frontend/vite.config.js`: `server.port: 5173`, `server.strictPort: true`, `server.proxy: { '/api': 'http://localhost:3000' }`; `appType` left at its default `'spa'` so unknown paths serve `index.html`.
  - `frontend/index.html`: a header mount and an app mount, loading `src/main.js`.
  - `frontend/src/main.js`: boot: read `jwt`, call `GET /api/user`, on 401 call `clearToken()`, render the header, start the router.
  - `frontend/src/router.js`: path table (`/`, `/register`, `/login`, `/editor`, `/article/:slug`) that later tickets fill with page renderers, `navigate(path)` with `history.pushState`, `popstate` handling, click interception for internal links (`a[data-link]`), and a fallback that renders the home page for any other path.
  - `frontend/src/api.js`: `request(method, path, body)` with relative `/api/...` URLs, adding `Authorization: Token <jwt>` when a token is stored, returning `{ ok, status, data }`.
  - `frontend/src/session.js`: `getToken()`, `setToken(token)`, `clearToken()` over `localStorage` key `jwt`, plus the current user.
  - `frontend/package-lock.json`: committed, written by `npm install`. Installed packages stay out of git through the repository-root `.gitignore` from `backend-foundation`.
  - `frontend/src/header.js`: the two header states. Link texts are exactly `Sign in`, `Sign up`, `New Article`; the signed-in username is shown as plain text.

## Acceptance Criteria

- [ ] Running `npm run build` in `frontend/` exits with code 0
- [ ] With `npm run dev` running in `frontend/`, the app answers at `http://localhost:5173`
- [ ] With no `jwt` in `localStorage`, the header shows a link with the text "Sign in"
- [ ] With no `jwt` in `localStorage`, the header shows a link with the text "Sign up"
- [ ] With no `jwt` in `localStorage`, the header shows no "New Article" link
- [ ] With jake's login token stored as `jwt`, the header shows the text "jake"
- [ ] With jake's login token stored as `jwt`, the header shows a link with the text "New Article"
- [ ] With jake's login token stored as `jwt`, the header shows no "Sign in" link
- [ ] With `jwt` set to `not-a-jwt`, loading the app removes the `jwt` key from `localStorage`
- [ ] With `jwt` set to `not-a-jwt`, loading the app shows the "Sign in" link in the header
- [ ] Clicking the header's "Sign in" link changes the address bar path to `/login` without a full page reload
- [ ] After clicking "Sign in", pressing the browser Back button changes the address bar path back to `/`
- [ ] Opening the path `/article/placeholder-slug` directly shows the app header instead of a server error page
- [ ] A browser request to `http://localhost:5173/api/user` with no token returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] After `npm install` in `frontend/`, `git status --porcelain` run at the repository root lists no path under `frontend/node_modules/`
- [ ] `git ls-files frontend/package-lock.json` run at the repository root prints `frontend/package-lock.json`
- [ ] With `jwt` set to `not-a-jwt` and the API on port 3000 stopped, loading the app leaves `localStorage.getItem('jwt')` equal to `not-a-jwt`
- [ ] With `jwt` set to `not-a-jwt` and the API on port 3000 stopped, loading the app shows the "Sign in" link and no "New Article" link in the header

## Out of Scope

The page contents (home list, article page, sign-up, sign-in, editor), a "Sign out" control, and CORS on the API.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/` scaffold: Vite config with `/api` proxy, `index.html`, boot, router, API client, session, header |
- Assumption: When the current-user check at app start fails with anything other than a 401 (API not running, a server error, a network error or an unreadable reply), the app keeps the stored token and shows the signed-out header.

## Test User

`jake@conduit.test` — password `Jake-Pass-123`

## Environment

- [x] Local (`http://localhost:5173` for the app, with the API from `npm start` in `backend/` on port 3000)

Browser checks need the API running: run `npm install` and `npm start` in `backend/`, then `npm run dev` in `frontend/`. The store is seeded again only when the API starts, so each verification attempt (including a retry) starts the API afresh and uses a new browser profile with empty `localStorage`.

## Navigation Path

Start the API with `npm start` in `backend/` and the app with `npm run dev` in `frontend/` > open the app's home page > look at the header. For the signed-in state: sign in through the API as jake, store the returned token in `localStorage` under `jwt`, reload the home page > look at the header.

## Labels

planned, INIT-0000000000-5856, feature, blocked-by:backend-foundation, blocked-by:user-auth-api

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "Build frontend/ as a Vite vanilla-JS single-page app with a History API router, a session module over localStorage jwt and a Vite /api proxy to port 3000.",
  "AffectedServices": "app",
  "TargetSymbols": "router (new):app/frontend/src/router.js;renderHeader (new):app/frontend/src/header.js;request (new):app/frontend/src/api.js;getToken (new):app/frontend/src/session.js;viteConfig (new):app/frontend/vite.config.js",
  "Kind": "business",
  "Serves": ["O2"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `npm run build` in `frontend/` exits with code 0 | developer | none | — | terminal in `frontend/` | exit code 0 | yes |
| With `npm run dev` running in `frontend/`, the app answers at `http://localhost:5173` | anonymous reader | none | — | open the app | page loads with the header | yes |
| With no `jwt` in `localStorage`, the header shows a link with the text "Sign in" | anonymous reader | none | — | open the app | link "Sign in" visible | yes |
| With no `jwt` in `localStorage`, the header shows a link with the text "Sign up" | anonymous reader | none | — | open the app | link "Sign up" visible | yes |
| With no `jwt` in `localStorage`, the header shows no "New Article" link | anonymous reader | none | — | open the app | no element with text "New Article" | yes |
| With jake's login token stored as `jwt`, the header shows the text "jake" | author | 1 `user` `jake` | seeded-by:backend-foundation | sign in through the API, store the token, reload | text "jake" in the header | yes |
| With jake's login token stored as `jwt`, the header shows a link with the text "New Article" | author | 1 `user` `jake` | seeded-by:backend-foundation | sign in through the API, store the token, reload | link "New Article" visible | yes |
| With jake's login token stored as `jwt`, the header shows no "Sign in" link | author | 1 `user` `jake` | seeded-by:backend-foundation | sign in through the API, store the token, reload | no element with text "Sign in" | yes |
| With `jwt` set to `not-a-jwt`, loading the app removes the `jwt` key from `localStorage` | anonymous reader | none | — | set `jwt`, reload the app | `localStorage.getItem('jwt')` is `null` | yes |
| With `jwt` set to `not-a-jwt`, loading the app shows the "Sign in" link in the header | anonymous reader | none | — | set `jwt`, reload the app | link "Sign in" visible | yes |
| Clicking the header's "Sign in" link changes the address bar path to `/login` without a full page reload | anonymous reader | none | — | open the app > click Sign in | `location.pathname` is `/login`; a `window` marker set before the click is still present | yes |
| After clicking "Sign in", pressing the browser Back button changes the address bar path back to `/` | anonymous reader | none | — | open the app > click Sign in > Back | `location.pathname` is `/` | yes |
| Opening the path `/article/placeholder-slug` directly shows the app header instead of a server error page | anonymous reader | none | — | open the deep link directly | header visible, HTTP status 200 | yes |
| A browser request to `http://localhost:5173/api/user` with no token returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | HTTP client against the dev server | status 401 with that exact body | yes |
| After `npm install` in `frontend/`, `git status --porcelain` run at the repository root lists no path under `frontend/node_modules/` | developer | none | — | terminal at the repository root | zero output lines containing `frontend/node_modules/` | yes |
| `git ls-files frontend/package-lock.json` run at the repository root prints `frontend/package-lock.json` | developer | none | — | terminal at the repository root | output is exactly `frontend/package-lock.json` | yes |
| With `jwt` set to `not-a-jwt` and the API on port 3000 stopped, loading the app leaves `localStorage.getItem('jwt')` equal to `not-a-jwt` | anonymous reader | none | — | stop the API, set `jwt`, reload the app | `localStorage.getItem('jwt')` is `not-a-jwt` | yes |
| With `jwt` set to `not-a-jwt` and the API on port 3000 stopped, loading the app shows the "Sign in" link and no "New Article" link in the header | anonymous reader | none | — | stop the API, set `jwt`, reload the app | link "Sign in" visible; no element with text "New Article" | yes |

## Writes

| Key | Op |
|-----|----|
| `local_storage.jwt` | transition:present->absent |

## Reads

| Key | Source |
|-----|--------|
| `local_storage.jwt` | framework:session |
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| With jake's login token stored as `jwt`, the header shows the text "jake" | `user.username` | state | value:jake | spec:backend-foundation |
| With jake's login token stored as `jwt`, the header shows a link with the text "New Article" | `user.username` | state | value:jake | spec:backend-foundation |
| With jake's login token stored as `jwt`, the header shows no "Sign in" link | `user.username` | state | value:jake | spec:backend-foundation |
