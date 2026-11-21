# frontend-shell

## Title

Set up the Vite frontend shell with routing, session check and header

## Description

## Summary

Create the `frontend/` project in `app`: a Vite + vanilla JS app on port 5173 that proxies `/api` to the backend, a History-API router with all five routes, a session check for a stored token, the header in its signed-out and signed-in states, and the `/editor` guard.

## Enables

**Enables:** O1, O2, O3 — the sign-in, sign-up, home, article and editor pages all render inside this shell and use its router, session and API client.

The repo has no `frontend/` directory. Each page ticket fills one page module; without the shell there is nothing to put them in, and the header state and editor guard named in the brief's acceptance have no home.

## Background / Motivation

The brief's walkthrough runs in the browser at `http://localhost:5173`: the header must change with sign-in state, the token lives in `localStorage` under `jwt`, and `/editor` must send signed-out visitors to `/login`. These are shared by every page, so they land once, before the pages.

## Proposed Changes

- `npm run dev` in `frontend/` serves the app on port 5173. If that port is busy, it fails instead of moving to another port. `npm run build` produces a build.
- Requests to `/api/...` on port 5173 are forwarded to the backend on port 3000, so the browser talks to one origin.
- Routes: `/` (home), `/login` (sign in), `/register` (sign up), `/editor` (new article), `/article/:slug` (article). Any other path shows "Page not found". Opening any route directly loads the app. Header links change the address, and the browser Back button returns to the previous route.
- Header when signed out: `Home`, `Sign in` (to `/login`), `Sign up` (to `/register`). No `New Article`.
- Header when signed in: `Home`, `New Article` (to `/editor`), and the username. No `Sign in` or `Sign up`.
- On load, a token in `localStorage.jwt` is checked with `GET /api/user`, sent with `Authorization: Token <jwt>`. If the API accepts it, the user is signed in. If it answers 401, the `jwt` key is removed and the page shows the signed-out header. If it gets any other answer (another status, or no answer because the backend is unreachable), the `jwt` key is kept, the page shows the signed-out header for this page load, and the router still renders the requested route.
- `/editor` while signed out replaces the address with `/login` and shows the sign-in route. Signed in, `/editor` stays put.

## Technical Context

- Builds on `backend-scaffold` (the API on port 3000 started with `npm start` in `backend/`) and `user-accounts-api` (`GET /api/user` and the seeded `jake`).
- New `frontend/package.json`: scripts `"dev": "vite"`, `"build": "vite build"`, `"preview": "vite preview"`; dev dependency `vite`. Commit `package-lock.json`.
- New `frontend/vite.config.js`: `server: { port: 5173, strictPort: true, proxy: { '/api': 'http://localhost:3000' } }`. Vite's dev server serves `index.html` for unknown paths, so deep links load the app.
- New `frontend/index.html` with `<header id="header">`, `<main id="app">` and `<script type="module" src="/src/main.js">`.
- New `frontend/src/api.js`: `request(method, path, body)` returning `{ status, body }`, using relative `/api` URLs, adding `Authorization: Token <jwt>` when a token is held. Exports `get`, `post`.
- New `frontend/src/session.js`: `init()` (the boot check above; a network failure or a status other than 200 and 401 leaves `localStorage.jwt` untouched and the current user empty, and `init()` resolves instead of throwing so boot continues), `signIn(user)` (stores the user's `token` field in `localStorage.jwt`, sets the current user), `clear()` (removes `jwt`), `currentUser()`, `onChange(fn)`. The page tickets call `signIn`.
- New `frontend/src/router.js`: route table with `:slug` params, `navigate(path)` (`history.pushState`), `popstate` listener, click interception for `<a data-link>`, and the `/editor` guard (`history.replaceState` to `/login`).
- New `frontend/src/header.js`: renders the header from `session.currentUser()`; re-renders on every session change.
- New `frontend/src/main.js`: runs `session.init()`, renders the header, starts the router.
- New stub page modules `frontend/src/pages/home.js`, `login.js`, `register.js`, `editor.js`, `article.js`, each exporting `render(container, params)` that renders an empty section. The page tickets replace the stubs. New `frontend/src/pages/not-found.js` renders "Page not found".
- New `frontend/src/style.css` with minimal layout.
- Parameters: `frontend.port` = 5173; `api.port` = 3000; `session.rejected_token` = remove jwt from localStorage, show signed out.
- No sign-out control is in scope; clearing `localStorage` signs out.
- Verification setup: before each browser verification attempt, including every verify retry, stop any process listening on port 3000, start the backend fresh with `npm start` in `backend/` (a fresh start reseeds the 2 seeded users and 2 seeded articles and drops everything created at runtime), then run `npm run dev` in `frontend/`. The criteria below assume that freshly seeded backend.

## Acceptance Criteria

- [ ] Running `npm run build` in `frontend/` exits with code 0
- [ ] With `npm run dev` running in `frontend/`, opening `http://localhost:5173/` shows a header link with the text `Home`
- [ ] When port 5173 is already in use, `npm run dev` in `frontend/` exits with an error instead of serving on another port
- [ ] With the backend running, `GET http://localhost:5173/api/user` with no token returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Signed out, the header shows a `Sign in` link
- [ ] Signed out, the header shows a `Sign up` link
- [ ] Signed out, the header shows no `New Article` link
- [ ] Signed out, clicking `Sign in` in the header changes the address to `/login`
- [ ] Signed out, clicking `Sign up` in the header changes the address to `/register`
- [ ] On `/login`, clicking `Home` in the header changes the address to `/`
- [ ] After clicking `Sign in` in the header on `/`, pressing the browser Back button changes the address to `/`
- [ ] Signed out, opening `http://localhost:5173/editor` changes the address to `/login`
- [ ] Opening `http://localhost:5173/no-such-page` shows the text `Page not found`
- [ ] Opening `http://localhost:5173/login` directly in a new tab shows the header `Sign in` link
- [ ] With a valid `jake` token in `localStorage.jwt`, loading `/` shows the text `jake` in the header
- [ ] With a valid `jake` token in `localStorage.jwt`, loading `/` shows a `Home` link in the header
- [ ] With a valid `jake` token in `localStorage.jwt`, loading `/` shows a `New Article` link in the header
- [ ] With a valid `jake` token in `localStorage.jwt`, loading `/` shows no `Sign in` link
- [ ] With a valid `jake` token in `localStorage.jwt`, loading `/` shows no `Sign up` link
- [ ] With a valid `jake` token in `localStorage.jwt`, clicking `New Article` changes the address to `/editor`
- [ ] With a valid `jake` token in `localStorage.jwt`, opening `http://localhost:5173/editor` keeps the address at `/editor`
- [ ] With a valid `jake` token in `localStorage.jwt`, loading `/` sends `GET /api/user` with header `Authorization: Token <that token>`
- [ ] With `localStorage.jwt` set to `not-a-token`, loading `/` shows a `Sign in` link in the header
- [ ] With `localStorage.jwt` set to `not-a-token`, loading `/` leaves no `jwt` key in `localStorage`
- [ ] With the backend stopped and a `jake` token in `localStorage.jwt`, loading `/` shows a `Sign in` link in the header
- [ ] With the backend stopped and a `jake` token in `localStorage.jwt`, loading `/` keeps `localStorage.jwt` equal to that token
- [ ] With the backend stopped and a `jake` token in `localStorage.jwt`, opening `http://localhost:5173/no-such-page` shows the text `Page not found`
- [ ] Opening `http://localhost:5173/article/any-slug` directly keeps the address at `/article/any-slug` and does not show the text `Page not found`

## Out of Scope

The content of the home, article, sign-in, sign-up and editor pages (one ticket each), sign-out, and any production hosting of the built files.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app frontend | `package.json`, `vite.config.js`, `index.html`, `src/main.js`, `src/router.js`, `src/api.js`, `src/session.js`, `src/header.js`, page stubs |

## Test User

`jake@conduit.test` — password `Jake-Pass-123` (seeded author). Signed-out checks need no user. Restart the backend before each verification attempt (see Technical Context); the backend-stopped checks stop it on purpose and start it again afterwards.

## Environment

- [x] Local (`http://localhost:5173`, backend on `http://localhost:3000`)

## Labels

planned, INIT-0000000000-2767, chore, blocked-by:backend-scaffold, blocked-by:user-accounts-api

## Signals

```json
{
  "services_identified": 3,
  "symbols_resolved": 6,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "CommonJS Express 5 API built by a createApp() factory with a seeded in-memory store, tested with node:test plus supertest; Vite vanilla JS SPA reaching it through a /api dev proxy.",
  "AffectedServices": "app frontend",
  "TargetSymbols": "viteConfig (new):app/frontend/vite.config.js;indexHtml (new):app/frontend/index.html;main (new):app/frontend/src/main.js;router (new):app/frontend/src/router.js;api (new):app/frontend/src/api.js;session (new):app/frontend/src/session.js;header (new):app/frontend/src/header.js;notFound (new):app/frontend/src/pages/not-found.js",
  "Kind": "enabler",
  "Serves": [],
  "Enables": ["O1", "O2", "O3"]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `npm run build` in `frontend/` exits with code 0 | developer | none | — | terminal in `frontend/` | exit code 0 | yes |
| With `npm run dev` running in `frontend/`, opening `http://localhost:5173/` shows a header link with the text `Home` | anonymous reader | none | — | open the app | header link `Home` visible | yes |
| When port 5173 is already in use, `npm run dev` in `frontend/` exits with an error instead of serving on another port | developer | none | — | terminal in `frontend/` | process exits non-zero, no server on 5174 | yes |
| With the backend running, `GET http://localhost:5173/api/user` with no token returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | developer | none | — | terminal, curl | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Signed out, the header shows a `Sign in` link | anonymous reader | none | — | open the app | link `Sign in` visible | yes |
| Signed out, the header shows a `Sign up` link | anonymous reader | none | — | open the app | link `Sign up` visible | yes |
| Signed out, the header shows no `New Article` link | anonymous reader | none | — | open the app | no element with text `New Article` | yes |
| Signed out, clicking `Sign in` in the header changes the address to `/login` | anonymous reader | none | — | header > Sign in | address path `/login` | yes |
| Signed out, clicking `Sign up` in the header changes the address to `/register` | anonymous reader | none | — | header > Sign up | address path `/register` | yes |
| On `/login`, clicking `Home` in the header changes the address to `/` | anonymous reader | none | — | header > Sign in > Home | address path `/` | yes |
| After clicking `Sign in` in the header on `/`, pressing the browser Back button changes the address to `/` | anonymous reader | none | — | header > Sign in > browser Back | address path `/` | yes |
| Signed out, opening `http://localhost:5173/editor` changes the address to `/login` | anonymous reader | none | — | type the editor address | address path `/login` | yes |
| Opening `http://localhost:5173/no-such-page` shows the text `Page not found` | anonymous reader | none | — | type an unknown address | text `Page not found` visible | yes |
| Opening `http://localhost:5173/login` directly in a new tab shows the header `Sign in` link | anonymous reader | none | — | type the sign-in address | link `Sign in` visible | yes |
| With a valid `jake` token in `localStorage.jwt`, loading `/` shows the text `jake` in the header | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt` | seeded-by:user-accounts-api | open the app | header text `jake` visible | yes |
| With a valid `jake` token in `localStorage.jwt`, loading `/` shows a `Home` link in the header | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt` | seeded-by:user-accounts-api | open the app | link `Home` visible | yes |
| With a valid `jake` token in `localStorage.jwt`, loading `/` shows a `New Article` link in the header | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt` | seeded-by:user-accounts-api | open the app | link `New Article` visible | yes |
| With a valid `jake` token in `localStorage.jwt`, loading `/` shows no `Sign in` link | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt` | seeded-by:user-accounts-api | open the app | no element with text `Sign in` | yes |
| With a valid `jake` token in `localStorage.jwt`, loading `/` shows no `Sign up` link | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt` | seeded-by:user-accounts-api | open the app | no element with text `Sign up` | yes |
| With a valid `jake` token in `localStorage.jwt`, clicking `New Article` changes the address to `/editor` | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt` | seeded-by:user-accounts-api | header > New Article | address path `/editor` | yes |
| With a valid `jake` token in `localStorage.jwt`, opening `http://localhost:5173/editor` keeps the address at `/editor` | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt` | seeded-by:user-accounts-api | type the editor address | address path `/editor` | yes |
| With a valid `jake` token in `localStorage.jwt`, loading `/` sends `GET /api/user` with header `Authorization: Token <that token>` | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt` | seeded-by:user-accounts-api | open the app, browser network panel | request header `Authorization` = `Token <stored token>` | yes |
| With `localStorage.jwt` set to `not-a-token`, loading `/` shows a `Sign in` link in the header | anonymous reader | none | — | open the app | link `Sign in` visible | yes |
| With `localStorage.jwt` set to `not-a-token`, loading `/` leaves no `jwt` key in `localStorage` | anonymous reader | none | — | open the app, browser storage panel | `localStorage.getItem('jwt')` returns `null` | yes |
| With the backend stopped and a `jake` token in `localStorage.jwt`, loading `/` shows a `Sign in` link in the header | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt`, then the backend process on port 3000 stopped | seeded-by:user-accounts-api | open the app | link `Sign in` visible | yes |
| With the backend stopped and a `jake` token in `localStorage.jwt`, loading `/` keeps `localStorage.jwt` equal to that token | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt`, then the backend process on port 3000 stopped | seeded-by:user-accounts-api | open the app, browser storage panel | `localStorage.getItem('jwt')` equals the stored token | yes |
| With the backend stopped and a `jake` token in `localStorage.jwt`, opening `http://localhost:5173/no-such-page` shows the text `Page not found` | author jake | 1 `user` jake with password `Jake-Pass-123`; its token from `POST /api/members/login` stored in `localStorage.jwt`, then the backend process on port 3000 stopped | seeded-by:user-accounts-api | type an unknown address | text `Page not found` visible | yes |
| Opening `http://localhost:5173/article/any-slug` directly keeps the address at `/article/any-slug` and does not show the text `Page not found` | anonymous reader | none | — | type an article address | address path `/article/any-slug`, no text `Page not found` | yes |

## Writes

| Key | Op |
|-----|----|
| `session_token` | transition:stored->absent |

## Reads

| Key | Source |
|-----|--------|
| `user.username` | spec |

## Preconditions

None.
