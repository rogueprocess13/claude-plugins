# frontend-shell

## Title

The app header shows whether a person is signed in

## Description

## Summary

Create the `frontend/` project in `app` (Vite + vanilla JS on port 5173) with page routing, a connection to the API, sign-in session handling, and the header. The header shows "Sign in" and "Sign up" to a signed-out visitor, and the username plus "New Article" to a signed-in author. A stored sign-in that the API no longer accepts is cleared.

## Enables

**Enables:** O1, O4 — the sign-up, sign-in, read and editor pages all render inside this shell, and its header is where a signed-in author is shown as signed in and a signed-out visitor is not offered publishing.

## Background / Motivation

The repo has no frontend yet. Every page in this slice needs the same frame: a header, page routing with real paths such as `/login` and `/article/<slug>`, a way to call the API, and the stored sign-in token. The brief fixes the header's two states and says the token lives in the browser's `localStorage` under the key `jwt`. Where the brief is silent, the RealWorld reference frontend applies: a stored token is checked when the app opens, and one the API rejects is removed.

## Proposed Behaviour

- `npm run dev` in `frontend/` serves the app on port 5173. `npm run build` in `frontend/` builds it.
- Every page shows a header with the brand link "conduit", which goes to the home page.
- Signed out (no `jwt` in `localStorage`): the header shows the links "Sign in" (to `/login`) and "Sign up" (to `/register`). It does not show "New Article".
- Signed in: the header shows the author's username and the link "New Article" (to `/editor`). It does not show "Sign in" or "Sign up".
- When the app opens with a `jwt` stored, it asks the API for the current user. If the API answers status 401, the app removes `jwt` and shows the signed-out header.
- Header links change the page without a full reload, and the browser's back button returns to the previous page.
- Opening any app path directly in the browser, such as `/article/<slug>`, loads the app. A path the app does not know shows the home page.
- The browser reaches the API through the same address and port as the app: requests to `/api/...` on port 5173 are passed to the API on port 3000.
- This ticket adds a placeholder for each of the five pages: a heading with the page name, "Home", "Article", "Sign up", "Sign in" or "Editor". The home, article, sign-up, sign-in and editor tickets replace them.

## Technical Context

- Builds on `api-user-auth` (`GET /api/user` and its 401 body), which runs on the API from `backend-foundation`. The proxy is checked with `GET /api/user` too, so this ticket does not wait for the article endpoints.
- `app/CLAUDE.md:22` fixes Vite + vanilla JS on port 5173, `CLAUDE.md:43` and `CLAUDE.md:44` fix `npm run dev` and `npm run build` from `frontend/`, and `CLAUDE.md:53` puts frontend code in `frontend/`. No framework (no React).
- Add `frontend/package.json` (scripts `dev`, `build`, `preview`; dev dependency `vite`) and commit `frontend/package-lock.json`. ES modules.
- Add `frontend/vite.config.js`: dev server port 5173 with `strictPort`, and a proxy from `/api` to `http://localhost:3000` for both the dev server and `vite preview`. The API gets no CORS code. Vite's default SPA mode serves `index.html` for unknown paths.
- Add `frontend/index.html` with a header container and a main container, loading `src/main.js`.
- `frontend/src/router.js`: a History API router with the routes `/`, `/login`, `/register`, `/editor` and `/article/:slug`. It intercepts clicks on same-origin links, pushes the new path, and re-renders on the browser's popstate event. An unknown path renders the home page.
- `frontend/src/api.js`: a `fetch` wrapper for `/api/...` that sends JSON, adds `Authorization: Token <jwt>` when a token is stored, and returns the status with the parsed body.
- `frontend/src/session.js`: owns the `jwt` key in `localStorage`. Exposes `getToken`, `setToken`, `clearToken`, `currentUser` and `loadSession()`. `loadSession()` runs on boot: with a token it calls `GET /api/user`; on status 200 it keeps the user, on status 401 it clears the token (`frontend.session.stale_token`).
- `frontend/src/header.js`: renders the two header states from the session and re-renders when the session changes.
- `frontend/src/pages/home.js`, `register.js`, `login.js`, `editor.js`, `article.js`: placeholders that each render an `<h1>` with the page name ("Home", "Sign up", "Sign in", "Editor", "Article"). Later tickets replace them. After `frontend-read-pages` replaces the home placeholder, the unknown-path rule is checked there by its article previews.
- There is no sign-out control in this slice.

## Acceptance Criteria

- [ ] Running `npm run build` in `frontend/` exits with code 0
- [ ] With `npm run dev` running in `frontend/`, opening the app on port 5173 shows the header link "conduit"
- [ ] With no `jwt` in `localStorage`, the header shows the link "Sign in"
- [ ] With no `jwt` in `localStorage`, the header shows the link "Sign up"
- [ ] With no `jwt` in `localStorage`, the header does not show "New Article"
- [ ] With a valid token for `jake` stored as `jwt`, the header shows the text "jake"
- [ ] With a valid token for `jake` stored as `jwt`, the header shows the link "New Article"
- [ ] With a valid token for `jake` stored as `jwt`, the header does not show "Sign in"
- [ ] With a valid token for `jake` stored as `jwt`, the header does not show "Sign up"
- [ ] With `jwt` set to `not-a-valid-token`, after the app opens, `localStorage` holds no `jwt` key
- [ ] With `jwt` set to `not-a-valid-token`, after the app opens, the header shows the link "Sign in"
- [ ] Clicking "Sign in" in the header changes the address to `/login`
- [ ] Clicking "Sign up" in the header changes the address to `/register`
- [ ] With a valid token for `jake` stored as `jwt`, clicking "New Article" in the header changes the address to `/editor`
- [ ] Clicking "conduit" in the header on the `/login` page changes the address to `/`
- [ ] After clicking "Sign in" in the header, the browser's back button returns the address to `/`
- [ ] Opening `/article/placeholder-slug` directly on port 5173 shows the header link "conduit"
- [ ] Opening `/no-such-page` directly on port 5173 shows the heading "Home"
- [ ] With the API running, a browser request without a token to `/api/user` on port 5173 returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`

## Test User

- Signed-out visitor: no credentials; clear `localStorage` first.
- Author: `jake@conduit.test` / `Jake-Pass-123` (username `jake`). Until the sign-in page exists, get a token by signing in through the API and store it in `localStorage` under `jwt` from the browser console.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Frontend | app | `frontend/` project setup, dev proxy, router, API client, session, header, page placeholders |

## Navigation Path

1. Before every verification attempt, including a retry, stop any process listening on port 3000 or 5173. Then, from this ticket's branch checkout, run `npm install` and `npm start` in `backend/`, and `npm install` and `npm run dev` in `frontend/`. Open the app at `http://localhost:5173`. Restarting the API re-seeds the store, so every attempt starts from the 2 seeded `user` and 2 seeded `article` records.
2. Open the app home page on port 5173 in a browser.
3. Look at the header at the top of the page.
4. Click "Sign in", "Sign up" or "conduit" in the header.
5. For the signed-in checks, store `jake`'s token under `jwt` in `localStorage` and reload the home page.

## Labels

planned, INIT-0000000000-9899, feature, blocked-by:backend-foundation, blocked-by:api-user-auth

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 5,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Scaffold a Vite + vanilla JS SPA with a History API router, a same-origin /api dev proxy to port 3000, a session module owning the jwt key, and a two-state header.",
  "AffectedServices": "app",
  "TargetSymbols": "loadSession (new):app/frontend/src/session.js;renderHeader (new):app/frontend/src/header.js;router (new):app/frontend/src/router.js;apiFetch (new):app/frontend/src/api.js;viteConfig (new):app/frontend/vite.config.js",
  "Kind": "enabler",
  "Serves": [],
  "Enables": ["O1", "O4"]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `npm run build` in `frontend/` exits with code 0 | developer | none | — | terminal in `frontend/` | exit code 0 | yes |
| With `npm run dev` running in `frontend/`, opening the app on port 5173 shows the header link "conduit" | anonymous reader | none | — | Home page | link text "conduit" in the header | yes |
| With no `jwt` in `localStorage`, the header shows the link "Sign in" | anonymous reader | none | — | Home page | link "Sign in" visible | yes |
| With no `jwt` in `localStorage`, the header shows the link "Sign up" | anonymous reader | none | — | Home page | link "Sign up" visible | yes |
| With no `jwt` in `localStorage`, the header does not show "New Article" | anonymous reader | none | — | Home page | text "New Article" absent | yes |
| With a valid token for `jake` stored as `jwt`, the header shows the text "jake" | author | seeded `user` jake with a sign-in token from the API | seeded-by:backend-foundation | Home page | text "jake" in the header | yes |
| With a valid token for `jake` stored as `jwt`, the header shows the link "New Article" | author | seeded `user` jake with a sign-in token from the API | seeded-by:backend-foundation | Home page | link "New Article" visible | yes |
| With a valid token for `jake` stored as `jwt`, the header does not show "Sign in" | author | seeded `user` jake with a sign-in token from the API | seeded-by:backend-foundation | Home page | text "Sign in" absent | yes |
| With a valid token for `jake` stored as `jwt`, the header does not show "Sign up" | author | seeded `user` jake with a sign-in token from the API | seeded-by:backend-foundation | Home page | text "Sign up" absent | yes |
| With `jwt` set to `not-a-valid-token`, after the app opens, `localStorage` holds no `jwt` key | anonymous reader | a stored `jwt` value `not-a-valid-token` in `localStorage` | seeded-by:frontend-shell | Home page | `localStorage.getItem('jwt')` returns null | yes |
| With `jwt` set to `not-a-valid-token`, after the app opens, the header shows the link "Sign in" | anonymous reader | a stored `jwt` value `not-a-valid-token` in `localStorage` | seeded-by:frontend-shell | Home page | link "Sign in" visible | yes |
| Clicking "Sign in" in the header changes the address to `/login` | anonymous reader | none | — | Home page > Sign in | address path `/login` | yes |
| Clicking "Sign up" in the header changes the address to `/register` | anonymous reader | none | — | Home page > Sign up | address path `/register` | yes |
| With a valid token for `jake` stored as `jwt`, clicking "New Article" in the header changes the address to `/editor` | author | seeded `user` jake with a sign-in token from the API | seeded-by:backend-foundation | Home page > New Article | address path `/editor` | yes |
| Clicking "conduit" in the header on the `/login` page changes the address to `/` | anonymous reader | none | — | Home page > Sign in > conduit | address path `/` | yes |
| After clicking "Sign in" in the header, the browser's back button returns the address to `/` | anonymous reader | none | — | Home page > Sign in > browser Back | address path `/` | yes |
| Opening `/article/placeholder-slug` directly on port 5173 shows the header link "conduit" | anonymous reader | none | — | type the path in the address bar | link text "conduit" in the header | yes |
| Opening `/no-such-page` directly on port 5173 shows the heading "Home" | anonymous reader | none | — | type the path in the address bar | heading "Home" | yes |
| With the API running, a browser request without a token to `/api/user` on port 5173 returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | browser console on the home page | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |

## Test Data Provided

- A stale sign-in fixture for the browser checks: the value `not-a-valid-token` stored in `localStorage` under `jwt` from the browser console before the app opens.

## Writes

| Key | Op |
|-----|----|
| `browser_session.jwt` | transition:present->absent |

## Reads

| Key | Source |
|-----|--------|
| `browser_session.jwt` | spec |
| `user.username` | spec |
| `user.email` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| With a valid token for `jake` stored as `jwt`, the header shows the text "jake" | `user.username` | state | value:jake | spec:backend-foundation |
