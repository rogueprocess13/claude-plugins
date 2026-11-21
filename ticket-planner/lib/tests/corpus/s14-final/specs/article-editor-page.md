# article-editor-page

## Title

Authors can publish a new article from the editor

## Description

## Summary

Fill in the editor page (`/editor`): a form a signed-in author uses to publish a new article, which then opens the new article's page. API errors appear as a list above the form.

## Outcome

**Serves:** O2

**Who:** Author

**Need:** Publish articles.

**Outcome:** A signed-in author can publish an article and then sees it on its own page. People who are not signed in cannot reach the editor.

## Background / Motivation

The brief's walkthrough ends with `jake` publishing "My first post" and landing on `/article/my-first-post`. The create endpoint exists; the editor page is still an empty stub.

## Proposed Behaviour

- Signed in, the editor shows a `Title` input, a `Description` input, a `Body` text area and a `Publish Article` button.
- Publishing sends the three fields to the API. On success the browser goes to the new article's page, `/article/<slug>`, using the slug from the response, and that page shows the new article.
- The new article then appears first in the home page list, because it is the newest.
- When the API returns errors, they appear in the same list format as the sign-in page (for example `title can't be blank`, `title is invalid`), one item per message. The address stays on `/editor` and the typed values stay in the form.
- Signed out, `/editor` is never shown: the shell's guard sends the visitor to `/login`.

## Technical Context

- Builds on `backend-scaffold` (`npm start` in `backend/`, used to start a freshly seeded backend for verification), `frontend-shell` (stub `frontend/src/pages/editor.js`, `post` from `frontend/src/api.js` which adds `Authorization: Token <jwt>`, `navigate` in `frontend/src/router.js`, the `/editor` guard), `articles-api` (`POST /api/articles`), `sign-up-and-sign-in-pages` (`renderErrors` in `frontend/src/errors.js`; the sign-in page used to sign `jake` in) and `reader-pages` (`frontend/src/pages/article.js`, the page the editor lands on; `frontend/src/pages/home.js`, the list).
- Replace the editor stub. Post `{"article":{"title","description","body"}}` to `/api/articles`. On success `navigate('/article/' + body.article.slug)`. On an error answer call `renderErrors` with the response's `errors` object.
- Inputs carry `<label>` text `Title`, `Description`, `Body`; the body field is a `<textarea>`.
- Inputs carry no HTML validation attributes (`required`, `minlength`, `maxlength`, `pattern`), so the browser never blocks a submit: an empty field reaches the API and its error appears in the list.
- Parameters: `ui.form_error_format` = one list item per message, field name then message; `articles.empty_slug_title` = 422 title is invalid.
- Verification setup: before each browser verification attempt, including every verify retry, stop any process listening on port 3000, start the backend fresh with `npm start` in `backend/` (a fresh start reseeds the 2 seeded users and 2 seeded articles and drops everything created at runtime), then run `npm run dev` in `frontend/`. The criteria below assume that freshly seeded backend.

## Acceptance Criteria

- [ ] Signed in as `jake`, the editor page shows a `Title` input
- [ ] Signed in as `jake`, the editor page shows a `Description` input
- [ ] Signed in as `jake`, the editor page shows a `Body` text area
- [ ] Signed in as `jake`, the editor page shows a `Publish Article` button
- [ ] Signed in as `jake`, publishing title `My first post`, description `First description`, body `First body` changes the address to `/article/my-first-post`
- [ ] Signed in as `jake`, publishing title `My first post`, description `First description`, body `First body` shows the heading `My first post`
- [ ] After `jake` publishes `My first post`, the first article preview on the home page has the title `My first post`
- [ ] Signed in as `jake`, publishing an empty title, description `d`, body `b` shows the error `title can't be blank`
- [ ] Signed in as `jake`, publishing an empty title, description `d`, body `b` keeps the address at `/editor`
- [ ] Signed in as `jake`, publishing title `!!!`, description `d`, body `b` shows the error `title is invalid`
- [ ] Signed in as `jake`, publishing an empty form shows an error list of 3 items
- [ ] Signed in as `jake`, publishing title `!!!`, description `d`, body `b` leaves `!!!` in the `Title` input
- [ ] Signed out, opening `http://localhost:5173/editor` changes the address to `/login`

## Out of Scope

Editing or deleting articles, tags, markdown preview, and the signed-out guard itself (part of the frontend shell).

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app frontend | `src/pages/editor.js` |

## Test User

`jake@conduit.test` — password `Jake-Pass-123` (seeded author). Restart the backend before each verification attempt (see Technical Context), so `my-first-post` does not exist yet and the published slug is not `my-first-post-2`.

## Navigation Path

Open the app home page > click `Sign in` in the header > sign in as `jake` > click `New Article` in the header.

## Labels

planned, INIT-0000000000-2767, feature, blocked-by:backend-scaffold, blocked-by:frontend-shell, blocked-by:articles-api, blocked-by:sign-up-and-sign-in-pages, blocked-by:reader-pages

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
  "TargetSymbols": "editorPage (new in frontend-shell):app/frontend/src/pages/editor.js;renderErrors (new in sign-up-and-sign-in-pages):app/frontend/src/errors.js;articlePage (new in frontend-shell):app/frontend/src/pages/article.js",
  "Kind": "business",
  "Serves": ["O2"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Signed in as `jake`, the editor page shows a `Title` input | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | input labelled `Title` visible | yes |
| Signed in as `jake`, the editor page shows a `Description` input | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | input labelled `Description` visible | yes |
| Signed in as `jake`, the editor page shows a `Body` text area | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | `textarea` labelled `Body` visible | yes |
| Signed in as `jake`, the editor page shows a `Publish Article` button | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | button `Publish Article` visible | yes |
| Signed in as `jake`, publishing title `My first post`, description `First description`, body `First body` changes the address to `/article/my-first-post` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | address path `/article/my-first-post` | yes |
| Signed in as `jake`, publishing title `My first post`, description `First description`, body `First body` shows the heading `My first post` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | `h1` text `My first post` | yes |
| After `jake` publishes `My first post`, the first article preview on the home page has the title `My first post` | author jake | 1 `user` jake signed in, plus the 2 seeded `article` records | seeded-by:articles-api | sign in as jake > header > New Article > publish > header > Home | first preview title `My first post` | yes |
| Signed in as `jake`, publishing an empty title, description `d`, body `b` shows the error `title can't be blank` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | list item `title can't be blank` visible | yes |
| Signed in as `jake`, publishing an empty title, description `d`, body `b` keeps the address at `/editor` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | address path `/editor` | yes |
| Signed in as `jake`, publishing title `!!!`, description `d`, body `b` shows the error `title is invalid` | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | list item `title is invalid` visible | yes |
| Signed in as `jake`, publishing an empty form shows an error list of 3 items | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | 3 `li` elements in `ul.error-messages` | yes |
| Signed in as `jake`, publishing title `!!!`, description `d`, body `b` leaves `!!!` in the `Title` input | author jake | 1 `user` jake with email `jake@conduit.test`, password `Jake-Pass-123`, signed in through the sign-in page | seeded-by:user-accounts-api | sign in as jake > header > New Article | `Title` input value `!!!` | yes |
| Signed out, opening `http://localhost:5173/editor` changes the address to `/login` | anonymous reader | none | — | type the editor address | address path `/login` | yes |

## Writes

None.

## Reads

| Key | Source |
|-----|--------|
| `session_token` | spec |
| `article.slug` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| Signed in as `jake`, publishing an empty title, description `d`, body `b` shows the error `title can't be blank` | `article.title` | input | null | — |
