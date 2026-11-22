# frontend-scaffold

## Title

Scaffold the Vite frontend shell with client-side routing and an API proxy

## Description

## Summary

Create the `frontend/` project in `app`: a Vite + vanilla JS app on port 5173 with a header, path-based client-side routing, a small API client, and a dev proxy that sends `/api` requests to the backend on port 3000. Extend `scripts/env-start.sh` so the verify step's stack start also starts the frontend.

## Enables

**Enables:** O1, O2, O3 — the sign-up, sign-in, editor, home and article pages all render inside this shell and call the API through its proxy.

There is no `frontend/` in the repo. The pipeline runs `npm run build` from `frontend/` as its frontend check and verifies tickets in the browser at `http://localhost:5173`, so every page ticket needs this project first.

## Background / Motivation

The brief asks for a Vite + vanilla JS frontend on port 5173, created from scratch. The acceptance walkthrough uses path-style URLs (`/login`, `/editor`, `/article/my-first-post`), so the app needs History API routing, not hash routes. The browser must reach the API, and a dev proxy keeps the frontend on relative URLs with no CORS setup.

## Proposed Changes

- A `frontend/` Vite project with `npm run dev` (dev server on port 5173) and `npm run build`.
- A dev proxy: any request to `/api/...` on port 5173 goes to `http://localhost:3000/api/...`.
- A page shell: a header on every page and a main area where the current route's page renders.
- In this ticket the header always shows the signed-out state: a "Sign in" link to `/login` and a "Sign up" link to `/register`, and no "New Article" link. The sign-in ticket adds the signed-in state.
- A client-side router: clicking an internal link changes the address bar without a full page load, the browser back button works, and opening any app path directly (for example `/login`) loads the app. Later tickets register their pages on the routes `/`, `/login`, `/register`, `/editor` and `/article/:slug`, each in the route list in `src/main.js`.
- A path with no registered page shows the header and the text "Page not found" in the main area. Until the page tickets land, this is what `/login`, `/register`, `/editor` and `/article/...` show.
- `scripts/env-start.sh` also starts the frontend: it always restarts the Vite dev server on port 5173 from the same checkout as the backend, installs packages first when `frontend/node_modules/` is missing, and waits until the page answers. If the frontend cannot start, it prints `frontend did not start on port 5173` and exits 1.
- A small API client that sends JSON to relative `/api/...` URLs and returns the status and parsed body.
- A `.gitignore` so installed packages and build output are not committed.

## Technical Context

- Repository `app` (pinned `200f5a4`). Code goes in `frontend/` per `app/CLAUDE.md:53`. Stack line `app/CLAUDE.md:22` (Vite + vanilla JS, port 5173). Pipeline commands `app/CLAUDE.md:43-44`; `LOCAL_URL` is `http://localhost:5173` (`app/CLAUDE.md:34`).
- Ports: parameter `frontend.port` = 5173; proxy target port from parameter `backend.port` = 3000. The backend comes from `backend-scaffold` (`npm start` in `backend/`).
- `frontend/package.json`: `"type": "module"`, scripts `"dev": "vite"`, `"build": "vite build"`, `"preview": "vite preview"`; dev dependency `vite`. No framework.
- `frontend/vite.config.js`: `server: { port: 5173, strictPort: true, proxy: { '/api': 'http://localhost:3000' } }`. Vite's dev server already serves `index.html` for unknown paths, so no extra fallback config is needed.
- `frontend/.gitignore`: `node_modules/`, `dist/`.
- `frontend/index.html`: `<header id="header">`, `<main id="app">`, `<script type="module" src="/src/main.js">`.
- `frontend/src/router.js`: `addRoute(pattern, render)`, `navigate(path)` (uses `history.pushState`), a `popstate` listener, and a document click handler that intercepts same-origin `<a>` clicks. Patterns support one `:param` segment (`/article/:slug`). When no pattern matches, it renders a `<p>` with the text `Page not found` into `<main id="app">` and leaves the header in place. The sign-up route is `/register` (parameter `frontend.signup_route`).
- `frontend/src/api.js`: `request(method, path, body)` calls `fetch('/api' + path)` with JSON headers and returns `{status, body}`. Later tickets add the token header.
- `frontend/src/header.js`: `renderHeader()` builds the links with `document.createElement` and `textContent`, never `innerHTML` with data.
- `frontend/src/main.js`: renders the header, then starts the router. It holds the one route list: a block of `addRoute(...)` calls, empty in this ticket, under a `// routes` comment. Each page ticket adds its own `addRoute` lines to that block and imports its own page module; no page module registers itself anywhere else.
- `scripts/env-start.sh` (new in `backend-scaffold`): replace its `frontend: skipped` step with the frontend start. In order: stop every process listening on port 5173 (`lsof -ti tcp:5173`, then `kill`); if `<repo>/frontend/node_modules/` is missing, run `npm install` in `<repo>/frontend/`; start `npm run dev` in `<repo>/frontend/` detached (`setsid nohup … &`), output to `/tmp/app-frontend.log`; poll `http://localhost:5173/` until it answers 200, for at most 60 seconds (parameter `env.start_timeout`). If the dev server exits or the time runs out, print `frontend did not start on port 5173` and the last 20 lines of the log, and exit 1. `<repo>` is the same repo dir the backend step uses (`VERIFY_REPO_PATH_APP` when set), so the verify step's served-checkout check sees this ticket's code on port 5173.
- Prior art (described only, not citable): tag `sandbox-develop-before-reset-2026-10-29` had a `vite.config.js` with `server.port: 5173` and a dev proxy to port 3000. Its React code does not carry over.

## Acceptance Criteria

- [ ] Running `npm run build` in `frontend/` after `npm install` exits with code 0.
- [ ] With `npm run dev` running in `frontend/`, opening `http://localhost:5173/` shows a "Sign in" link in the header.
- [ ] With `npm run dev` running in `frontend/`, opening `http://localhost:5173/` shows a "Sign up" link in the header.
- [ ] With `npm run dev` running in `frontend/`, opening `http://localhost:5173/` shows no "New Article" link.
- [ ] Clicking the header "Sign in" link changes the address bar to `http://localhost:5173/login`.
- [ ] Clicking the header "Sign up" link changes the address bar to `http://localhost:5173/register`.
- [ ] After clicking "Sign in", pressing the browser back button changes the address bar to `http://localhost:5173/`.
- [ ] Opening `http://localhost:5173/login` directly in a new tab shows the header "Sign in" link.
- [ ] With `npm start` running in `backend/` and `npm run dev` running in `frontend/`, a GET request to `http://localhost:5173/api/unknown` receives status 404.
- [ ] After `npm install` and `npm run build` in `frontend/`, `git status --porcelain` lists no path under `frontend/node_modules/`.
- [ ] After `npm install` and `npm run build` in `frontend/`, `git status --porcelain` lists no path under `frontend/dist/`.
- [ ] Opening `http://localhost:5173/settings` shows the text "Page not found".
- [ ] Opening `http://localhost:5173/settings` shows the header "Sign in" link.
- [ ] After `bash scripts/env-start.sh` in `app` exits with code 0, a GET request to `http://localhost:5173/` receives status 200.
- [ ] After `bash scripts/env-start.sh` exits with code 0, a GET request to `http://localhost:5173/api/unknown` receives status 404.
- [ ] Running `bash scripts/env-start.sh` prints no line containing `frontend: skipped`.
- [ ] Running `bash scripts/env-start.sh` a second time, while the dev server it started is still running, leaves a different process ID listening on port 5173 than before the second run.
- [ ] With `frontend/node_modules/` deleted, running `bash scripts/env-start.sh` exits with code 0.
- [ ] With `VERIFY_REPO_PATH_APP` set to the path of a second clone of `app` on this ticket's branch, the process listening on port 5173 after `bash scripts/env-start.sh` has that clone's `frontend/` folder as its working directory.
- [ ] In a scratch copy of the repo whose `frontend/package.json` `dev` script is `exit 1`, running `bash scripts/env-start.sh` exits with code 1.
- [ ] In a scratch copy of the repo whose `frontend/package.json` `dev` script is `exit 1`, running `bash scripts/env-start.sh` prints a line containing `frontend did not start on port 5173`.
- [ ] With `npm start` running in `backend/` and `npm run dev` running in `frontend/`, calling `request('GET', '/unknown')` from `/src/api.js` in the browser console at `http://localhost:5173/` resolves to an object whose `status` is 404 and whose `body` is the parsed object `{"errors":{"route":["not found"]}}`.
- [ ] With `npm run dev` running in `frontend/`, calling `request('POST', '/unknown', {"a":1})` from `/src/api.js` in the browser console sends a request to `http://localhost:5173/api/unknown` whose `Content-Type` header is `application/json`.
- [ ] With `npm run dev` running in `frontend/`, calling `request('POST', '/unknown', {"a":1})` from `/src/api.js` in the browser console sends a request whose body is the JSON text `{"a":1}`.

## Out of Scope

- The pages themselves (home, sign-up, sign-in, editor, article) and the signed-in header state.
- CORS on the backend and any static production deploy.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/` package, `vite.config.js`, `index.html`, `src/main.js`, `src/router.js`, `src/api.js`, `src/header.js` |
| Tooling | app | frontend start in `scripts/env-start.sh` |

## Test User

Anonymous reader: no account and no password.

## Environment

- [x] Local (`http://localhost:5173`, backend on port 3000)

## Test Data Provided

- A second clone of `app` on this ticket's branch, made in a scratch folder by the check that uses it.
- A scratch copy of the repo whose `frontend/package.json` `dev` script is `exit 1`, made by the check that uses it.

## Labels

planned, INIT-0000000000-5252, chore, blocked-by:backend-scaffold

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Build a Vite + vanilla JS single-page shell in app/frontend with History API routing and a Vite dev proxy for /api to http://localhost:3000.",
  "AffectedServices": "app",
  "TargetSymbols": "viteConfig (new):app/frontend/vite.config.js;router (new):app/frontend/src/router.js;request (new):app/frontend/src/api.js;renderHeader (new):app/frontend/src/header.js;main (new):app/frontend/src/main.js;envStart (new in backend-scaffold):app/scripts/env-start.sh",
  "Kind": "enabler",
  "Serves": [],
  "Enables": ["O1", "O2", "O3"]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Running `npm run build` in `frontend/` after `npm install` exits with code 0. | developer | none | — | | exit code 0 | yes |
| With `npm run dev` running in `frontend/`, opening `http://localhost:5173/` shows a "Sign in" link in the header. | anonymous reader | none | — | Home | header link with text "Sign in" | yes |
| With `npm run dev` running in `frontend/`, opening `http://localhost:5173/` shows a "Sign up" link in the header. | anonymous reader | none | — | Home | header link with text "Sign up" | yes |
| With `npm run dev` running in `frontend/`, opening `http://localhost:5173/` shows no "New Article" link. | anonymous reader | none | — | Home | no element with text "New Article" | yes |
| Clicking the header "Sign in" link changes the address bar to `http://localhost:5173/login`. | anonymous reader | none | — | Home > Sign in | address bar `http://localhost:5173/login` | yes |
| Clicking the header "Sign up" link changes the address bar to `http://localhost:5173/register`. | anonymous reader | none | — | Home > Sign up | address bar `http://localhost:5173/register` | yes |
| After clicking "Sign in", pressing the browser back button changes the address bar to `http://localhost:5173/`. | anonymous reader | none | — | Home > Sign in > Back | address bar `http://localhost:5173/` | yes |
| Opening `http://localhost:5173/login` directly in a new tab shows the header "Sign in" link. | anonymous reader | none | — | | header link with text "Sign in" | yes |
| With `npm start` running in `backend/` and `npm run dev` running in `frontend/`, a GET request to `http://localhost:5173/api/unknown` receives status 404. | developer | none | — | | HTTP status 404 | yes |
| After `npm install` and `npm run build` in `frontend/`, `git status --porcelain` lists no path under `frontend/node_modules/`. | developer | none | — | | no line containing `frontend/node_modules/` | yes |
| After `npm install` and `npm run build` in `frontend/`, `git status --porcelain` lists no path under `frontend/dist/`. | developer | none | — | | no line containing `frontend/dist/` | yes |
| Opening `http://localhost:5173/settings` shows the text "Page not found". | anonymous reader | none | — | open the URL directly | text "Page not found" in the main area | yes |
| Opening `http://localhost:5173/settings` shows the header "Sign in" link. | anonymous reader | none | — | open the URL directly | header link with text "Sign in" | yes |
| After `bash scripts/env-start.sh` in `app` exits with code 0, a GET request to `http://localhost:5173/` receives status 200. | developer | none | — | run the script from the repo root, then send the request | HTTP status 200 | yes |
| After `bash scripts/env-start.sh` exits with code 0, a GET request to `http://localhost:5173/api/unknown` receives status 404. | developer | none | — | run the script, then send the request | HTTP status 404 | yes |
| Running `bash scripts/env-start.sh` prints no line containing `frontend: skipped`. | developer | none | — | run the script on this ticket's branch | no output line containing `frontend: skipped` | yes |
| Running `bash scripts/env-start.sh` a second time, while the dev server it started is still running, leaves a different process ID listening on port 5173 than before the second run. | developer | none | — | run the script, note `lsof -ti tcp:5173`, run it again, compare | the two process IDs differ | yes |
| With `frontend/node_modules/` deleted, running `bash scripts/env-start.sh` exits with code 0. | developer | none | — | `rm -rf frontend/node_modules`, then run the script | exit code 0 | yes |
| With `VERIFY_REPO_PATH_APP` set to the path of a second clone of `app` on this ticket's branch, the process listening on port 5173 after `bash scripts/env-start.sh` has that clone's `frontend/` folder as its working directory. | developer | a second clone of `app` on this ticket's branch | seeded-by:frontend-scaffold | clone to a scratch folder, export the variable, run the script, then `readlink /proc/$(lsof -ti tcp:5173)/cwd` | the clone's `frontend/` path | yes |
| In a scratch copy of the repo whose `frontend/package.json` `dev` script is `exit 1`, running `bash scripts/env-start.sh` exits with code 1. | developer | a scratch copy of the repo with the `dev` script set to `exit 1` | seeded-by:frontend-scaffold | copy the repo, edit the script entry, run the copy's script | exit code 1 | yes |
| In a scratch copy of the repo whose `frontend/package.json` `dev` script is `exit 1`, running `bash scripts/env-start.sh` prints a line containing `frontend did not start on port 5173`. | developer | a scratch copy of the repo with the `dev` script set to `exit 1` | seeded-by:frontend-scaffold | copy the repo, edit the script entry, run the copy's script | output line containing `frontend did not start on port 5173` | yes |
| With `npm start` running in `backend/` and `npm run dev` running in `frontend/`, calling `request('GET', '/unknown')` from `/src/api.js` in the browser console at `http://localhost:5173/` resolves to an object whose `status` is 404 and whose `body` is the parsed object `{"errors":{"route":["not found"]}}`. | developer | none | — | open `http://localhost:5173/`, in the console run `const { request } = await import('/src/api.js'); await request('GET', '/unknown')` | object with `status` 404 and `body` deep-equal to `{"errors":{"route":["not found"]}}` | yes |
| With `npm run dev` running in `frontend/`, calling `request('POST', '/unknown', {"a":1})` from `/src/api.js` in the browser console sends a request to `http://localhost:5173/api/unknown` whose `Content-Type` header is `application/json`. | developer | none | — | open `http://localhost:5173/`, in the console run `const { request } = await import('/src/api.js'); await request('POST', '/unknown', {"a":1})`, then inspect the request in the Network panel | request header `Content-Type: application/json` | yes |
| With `npm run dev` running in `frontend/`, calling `request('POST', '/unknown', {"a":1})` from `/src/api.js` in the browser console sends a request whose body is the JSON text `{"a":1}`. | developer | none | — | open `http://localhost:5173/`, in the console run `const { request } = await import('/src/api.js'); await request('POST', '/unknown', {"a":1})`, then inspect the request payload in the Network panel | request payload `{"a":1}` | yes |

## Writes

None.

## Reads

None.

## Preconditions

None.
