# editor-page

## Title

Authors can publish a new article from the browser

## Description

## Summary

Add the editor page, where a signed-in author writes and publishes a new article. A signed-out visitor who opens the editor is sent to the sign-in page.

## Outcome

**Serves:** O1

**Who:** Author, a registered user who signs in and publishes articles.

**Need:** Publish an article from the site.

**Outcome:** A signed-in author can publish an article and is taken to it. A visitor who is not signed in cannot reach the editor.

## Background / Motivation

Publishing is what an author signs in for. The last part of the acceptance walk is: `jake` signs in, publishes "My first post" and lands on `/article/my-first-post`. Signed out, the "New Article" link is not shown and `/editor` redirects to `/login`.

The walk gives `my-first-post` only on an API that has not seen that title since it started. A second publish of the same title lands on `/article/my-first-post-2`. Stop the running API and start it again before running the walk.

## Proposed Behaviour

Signed out (no `jwt` key in local storage):

- Opening `/editor` sends the visitor to `/login`. The redirect replaces the `/editor` entry in the browser history, so the Back button goes to the page visited before `/editor` and does not loop.
- The signed-out header, which has no `New Article` link, is built and checked in the frontend shell ticket. This ticket does not change the header.

Signed in:

- The editor page, reached with the `New Article` link, shows a `Title` field, a `Description` field, a multi-line `Body` field and a `Publish Article` button.
- Submitting sends the three values to the create-article endpoint with the stored token.
- On success the site goes to `/article/<slug>`, using the slug the API returned. The article page shows the new article, and the home page lists it first.
- If a field is blank, the author stays on `/editor` and the API's messages are listed above the form, one line each: `title can't be blank`, `description can't be blank`, `body can't be blank`. The form does no checking of its own.
- If the API rejects the token with 401 when the form is submitted, the site removes the `jwt` key and goes to `/login`.

## Technical Context

All paths are under `app/frontend/`. The router, `src/api.js`, `src/auth.js` and the header come from the frontend shell ticket. `src/errors.js` and the sign-in page come from the sign-in and sign-up pages ticket. The home page and the article page come from the read pages ticket. `POST /api/articles` comes from the article endpoints ticket, and `jake` comes from the store ticket's seed.

- New `src/pages/editor.js`: the form. It posts `{"article":{"title","description","body"}}` to `/api/articles` through `src/api.js`, which adds the `Authorization: Token <jwt>` header. On a 201 it calls `navigate('/article/' + slug)` with the `slug` of the response. On a 422 it renders the `errors` object with `src/errors.js`. On a 401 it clears the token through `src/auth.js`, refreshes the header and navigates to `/login`.
- `src/router.js`: register the editor render function for `/editor` and add the guard. When the route is `/editor` and no token is stored, the router calls `history.replaceState` with `/login` and renders the sign-in page.
- Inputs carry no `required` attribute and the form sets `novalidate`.
- There is no frontend test runner. `npm run build` in `frontend/` must still exit with code 0.
- Backend tests run in-process and never touch the running API, so `npm test` does not change what the walk sees. The API does not reload its code and keeps every article published since it started. Only stopping the running API and starting it again (`npm start` in `backend/`) resets it to the seed.

## Acceptance Criteria

- [ ] With no `jwt` key in local storage, loading the address `/editor` ends with the address bar path `/login`.
- [ ] With no `jwt` key in local storage, after opening the home address and then loading `/editor`, the browser Back button shows the path `/`.
- [ ] Signed in as `jake`, the editor page shows a `Title` field.
- [ ] Signed in as `jake`, the editor page shows a `Description` field.
- [ ] Signed in as `jake`, the editor page shows a multi-line `Body` field.
- [ ] Signed in as `jake`, the editor page shows a `Publish Article` button.
- [ ] On a freshly started API, `jake` publishing the title `My first post`, description `About my post` and body `Hello world` changes the address bar path to `/article/my-first-post`.
- [ ] After `jake` publishes `My first post`, the page shows the heading `My first post`.
- [ ] After `jake` publishes `My first post`, the page shows the body `Hello world`.
- [ ] After `jake` publishes `My first post`, the page shows the author `jake`.
- [ ] After `jake` publishes `My first post` on a freshly started API, the home page lists `My first post` first.
- [ ] After `jake` publishes `My first post` on a freshly started API, the home page lists exactly 3 articles.
- [ ] Publishing the title `My first post` a second time on the same API changes the address bar path to `/article/my-first-post-2`.
- [ ] Submitting the editor form with an empty `Title` shows the line `title can't be blank`.
- [ ] Submitting the editor form with an empty `Description` shows the line `description can't be blank`.
- [ ] Submitting the editor form with an empty `Body` shows the line `body can't be blank`.
- [ ] After submitting the editor form with an empty `Title`, the address bar path is still `/editor`.
- [ ] With the text `not-a-jwt` under the `jwt` key, which the API rejects with 401, submitting a filled editor form ends with the address bar path `/login`.
- [ ] With the text `not-a-jwt` under the `jwt` key, local storage has no `jwt` key after a filled editor form is submitted.

## Out of Scope

Editing or deleting an article, tags, drafts, a preview and a sign-out control. Checking fields in the browser before the API is called.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/src/pages/editor.js`, `frontend/src/router.js` |
| BE | app | none changed; the pages call the existing API |

## Test User

`jake@conduit.test`, password `Jake-Pass-123` (seeded author).

## Navigation Path

Stop any process that is listening on port 3000, then start the API (`npm start` in `backend/`). If `npm start` prints `Port 3000 is already in use`, an older API is still running: stop it and start again. Start the frontend (`npm run dev` in `frontend/`). Open the site. Click `Sign in`, sign in as `jake`, then click `New Article` in the header. For the signed-out checks, use a fresh browser window or remove the `jwt` key from the browser's local storage and reload.

## Labels

planned, INIT-0000000000-5702, feature, blocked-by:scaffold-packages, blocked-by:store-and-seed, blocked-by:auth-endpoints, blocked-by:article-endpoints, blocked-by:frontend-shell, blocked-by:read-pages, blocked-by:sign-in-and-sign-up-pages

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 2,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Two independent npm packages in app: backend/ (Express createApp factory over a per-instance seeded in-memory store, node:test + supertest behind npm test) and frontend/ (Vite + vanilla JS with a History-API router and a dev-server proxy for /api), with no root package, no database and no CORS.",
  "AffectedServices": "app",
  "TargetSymbols": "LOCAL_URL:app/CLAUDE.md:34;UAT_URL:app/CLAUDE.md:36;editorPage (new):app/frontend/src/pages/editor.js;router (new in frontend-shell):app/frontend/src/router.js;auth (new in frontend-shell):app/frontend/src/auth.js;errors (new in sign-in-and-sign-up-pages):app/frontend/src/errors.js;articlePage (new in read-pages):app/frontend/src/pages/article.js;articlesRouter (new in article-endpoints):app/backend/src/routes/articles.js",
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
| With no `jwt` key in local storage, loading the address `/editor` ends with the address bar path `/login`. | Anonymous reader | none | — | Open the site > add `/editor` to the site address | path is /login and the sign-in form is visible | yes |
| With no `jwt` key in local storage, after opening the home address and then loading `/editor`, the browser Back button shows the path `/`. | Anonymous reader | none | — | Open the site > add `/editor` to the site address > press the browser Back button | path is / after one Back press | yes |
| Signed in as `jake`, the editor page shows a `Title` field. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` | a text input labelled Title is visible | yes |
| Signed in as `jake`, the editor page shows a `Description` field. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` | a text input labelled Description is visible | yes |
| Signed in as `jake`, the editor page shows a multi-line `Body` field. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` | a textarea labelled Body is visible | yes |
| Signed in as `jake`, the editor page shows a `Publish Article` button. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` | a button with the text Publish Article is visible | yes |
| On a freshly started API, `jake` publishing the title `My first post`, description `About my post` and body `Hello world` changes the address bar path to `/article/my-first-post`. | Author (`jake`) | a freshly started API holding 2 `article` records in state seeded and 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` | path is /article/my-first-post | yes |
| After `jake` publishes `My first post`, the page shows the heading `My first post`. | Author (`jake`) | a freshly started API holding 2 `article` records in state seeded and 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` | the page heading is My first post | yes |
| After `jake` publishes `My first post`, the page shows the body `Hello world`. | Author (`jake`) | a freshly started API holding 2 `article` records in state seeded and 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` | the text Hello world is visible | yes |
| After `jake` publishes `My first post`, the page shows the author `jake`. | Author (`jake`) | a freshly started API holding 2 `article` records in state seeded and 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` | the text jake is visible on the article page | yes |
| After `jake` publishes `My first post` on a freshly started API, the home page lists `My first post` first. | Author (`jake`) | a freshly started API holding 2 `article` records in state seeded and 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` > press the browser Back button twice to reach the home page > reload | first entry title is My first post | yes |
| After `jake` publishes `My first post` on a freshly started API, the home page lists exactly 3 articles. | Author (`jake`) | a freshly started API holding 2 `article` records in state seeded and 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` > press the browser Back button twice to reach the home page > reload | the list holds three entries | yes |
| Publishing the title `My first post` a second time on the same API changes the address bar path to `/article/my-first-post-2`. | Author (`jake`) | a freshly started API holding 2 `article` records in state seeded and 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` > click `New Article` > fill in the same title > click `Publish Article` | path is /article/my-first-post-2 | yes |
| Submitting the editor form with an empty `Title` shows the line `title can't be blank`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` | the line title can't be blank is visible above the form | yes |
| Submitting the editor form with an empty `Description` shows the line `description can't be blank`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` | the line description can't be blank is visible above the form | yes |
| Submitting the editor form with an empty `Body` shows the line `body can't be blank`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` | the line body can't be blank is visible above the form | yes |
| After submitting the editor form with an empty `Title`, the address bar path is still `/editor`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed | Open the site > click `Sign in` > sign in as `jake` > click `New Article` > fill in the form > click `Publish Article` | path is /editor | yes |
| With the text `not-a-jwt` under the `jwt` key, which the API rejects with 401, submitting a filled editor form ends with the address bar path `/login`. | Anonymous reader | none | — | Open the site > put the text `not-a-jwt` under the `jwt` key in the browser's local storage > add `/editor` to the site address > fill in the form > click `Publish Article` | path is /login | yes |
| With the text `not-a-jwt` under the `jwt` key, local storage has no `jwt` key after a filled editor form is submitted. | Anonymous reader | none | — | Open the site > put the text `not-a-jwt` under the `jwt` key in the browser's local storage > add `/editor` to the site address > fill in the form > click `Publish Article` | local storage has no jwt key | yes |

## Writes

| Key | Op |
|---|---|
| `article` | append |

## Reads

| Key | Source |
|---|---|
| `client_session.jwt` | spec |
| `article.slug` | spec |
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|---|---|---|---|---|
| With no `jwt` key in local storage, loading the address `/editor` ends with the address bar path `/login`. | `client_session.jwt` | state | null | spec:frontend-shell |
| With no `jwt` key in local storage, after opening the home address and then loading `/editor`, the browser Back button shows the path `/`. | `client_session.jwt` | state | null | spec:frontend-shell |
| Signed in as `jake`, the editor page shows a `Title` field. | `user.username` | state | value:jake | spec:store-and-seed |
| Signed in as `jake`, the editor page shows a `Description` field. | `user.username` | state | value:jake | spec:store-and-seed |
| Signed in as `jake`, the editor page shows a multi-line `Body` field. | `user.username` | state | value:jake | spec:store-and-seed |
| Signed in as `jake`, the editor page shows a `Publish Article` button. | `user.username` | state | value:jake | spec:store-and-seed |
| On a freshly started API, `jake` publishing the title `My first post`, description `About my post` and body `Hello world` changes the address bar path to `/article/my-first-post`. | `user.username` | state | value:jake | spec:store-and-seed |
| After `jake` publishes `My first post`, the page shows the heading `My first post`. | `user.username` | state | value:jake | spec:store-and-seed |
| After `jake` publishes `My first post`, the page shows the body `Hello world`. | `user.username` | state | value:jake | spec:store-and-seed |
| After `jake` publishes `My first post`, the page shows the author `jake`. | `user.username` | state | value:jake | spec:store-and-seed |
| After `jake` publishes `My first post` on a freshly started API, the home page lists `My first post` first. | `user.username` | state | value:jake | spec:store-and-seed |
| After `jake` publishes `My first post` on a freshly started API, the home page lists exactly 3 articles. | `user.username` | state | value:jake | spec:store-and-seed |
| Publishing the title `My first post` a second time on the same API changes the address bar path to `/article/my-first-post-2`. | `user.username` | state | value:jake | spec:store-and-seed |
| Submitting the editor form with an empty `Title` shows the line `title can't be blank`. | `user.username` | state | value:jake | spec:store-and-seed |
| Submitting the editor form with an empty `Title` shows the line `title can't be blank`. | `article.title` | input | null | — |
| Submitting the editor form with an empty `Description` shows the line `description can't be blank`. | `user.username` | state | value:jake | spec:store-and-seed |
| Submitting the editor form with an empty `Description` shows the line `description can't be blank`. | `article.description` | input | null | — |
| Submitting the editor form with an empty `Body` shows the line `body can't be blank`. | `user.username` | state | value:jake | spec:store-and-seed |
| Submitting the editor form with an empty `Body` shows the line `body can't be blank`. | `article.body` | input | null | — |
| After submitting the editor form with an empty `Title`, the address bar path is still `/editor`. | `user.username` | state | value:jake | spec:store-and-seed |
