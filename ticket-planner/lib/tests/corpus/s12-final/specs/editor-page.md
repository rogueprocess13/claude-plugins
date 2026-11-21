# editor-page

## Title

Signed-in authors can publish an article from the editor

## Description

## Summary

Add the editor page at `/editor`, where a signed-in author writes a title, description and body and publishes the article. After publishing, the app opens the new article's page. A visitor who is not signed in is sent to the sign-in page instead.

## Outcome

**Serves:** O3

**Who:** Author

**Need:** Publish articles.

**Outcome:** A signed-in author can publish a new article and is taken to its page, while people who are not signed in cannot reach the editor.

## Background / Motivation

The brief's browser check is that `jake` signs in, publishes "My first post" and lands on `/article/my-first-post`, and that a signed-out visitor who opens `/editor` is redirected to `/login`. The create endpoint, the sign-in page and the article page exist; this ticket adds the editor and its guard.

## Proposed Behaviour

- The header's "New Article" link opens `/editor`. The page has the fields Title, Description and Body and a "Publish Article" button.
- On success (201) the app goes to `/article/<slug>` using the slug the API returned, and the article page shows the new article.
- On a 422 the page lists every error message above the form, one line per message, as `<field> <message>` (for example `title can't be blank`), and stays on `/editor`.
- With no `jwt` stored, opening `/editor` replaces the address with `/login` and shows the sign-in page. The Back button does not return to `/editor`.
- With a `jwt` the API rejects, the app clears it when it loads, so opening `/editor` also ends on `/login`.

## Technical Context

- Repository `app`, folder `frontend/`, built on the router, API client, session and header from `frontend-shell`, the article page and `frontend/src/errors.js` from `reader-pages`, the sign-in page from `auth-pages`, the create endpoint from `articles-api`, the token check from `user-auth-api`, and the seeded user `jake` from `backend-foundation`.
- Parameters: `ui.error_display` (a list above the form, one line per message, formatted field then message), `articles.empty_slug_title` (422 with title "is invalid").
- New file `frontend/src/pages/editor.js`: a form posting `{"article":{"title","description","body"}}` to `POST /api/articles` through `request()` (which adds `Authorization: Token <jwt>`); on 201 `navigate('/article/' + data.article.slug)`; on 401 or 422 `renderErrors(data.errors)`.
- Runs after `reader-pages` (publishing lands on its article page, and the home page check reads its list) and after `auth-pages` (the navigation path signs in through its sign-in page, and the guard shows that page).
- Router guard in `frontend/src/router.js`: the `/editor` route checks `getToken()` after boot has validated the token, and when there is none calls `history.replaceState(null, '', '/login')` and renders the sign-in page.

## Acceptance Criteria

- [ ] After jake signs in, clicking "New Article" in the header changes the address bar path to `/editor`
- [ ] The editor shows an input field labelled Title
- [ ] The editor shows an input field labelled Description
- [ ] The editor shows a text area labelled Body
- [ ] The editor shows a button with the text "Publish Article"
- [ ] Signed in as jake, publishing title `My first post`, description `About me` and body `Hello world` changes the address bar path to `/article/my-first-post`
- [ ] Publishing `My first post` as jake receives status 201 from `POST /api/articles` in the browser's network log
- [ ] After jake publishes `My first post`, the article page shows the heading "My first post"
- [ ] After jake publishes `My first post`, the article page shows the author username "jake"
- [ ] After jake publishes `My first post`, the home page shows "My first post" as the first preview
- [ ] Signed in as jake, publishing with an empty title shows the line "title can't be blank"
- [ ] Signed in as jake, publishing with the title `!!!` shows the line "title is invalid"
- [ ] Publishing with an empty title as jake receives status 422 from `POST /api/articles` in the browser's network log
- [ ] After a rejected publish the address bar path stays `/editor`
- [ ] With no `jwt` in `localStorage`, opening `/editor` changes the address bar path to `/login`
- [ ] With no `jwt` in `localStorage`, opening `/editor` shows the sign-in form
- [ ] With no `jwt` in `localStorage`, pressing Back after the redirect from `/editor` does not show `/editor` in the address bar
- [ ] With `jwt` set to `not-a-jwt`, opening `/editor` changes the address bar path to `/login`
- [ ] Signed in as an author, publishing with Title, Description and Body all empty shows the lines "title can't be blank", "description can't be blank" and "body can't be blank", each on its own separate line above the form
- [ ] Signed in as an author, after a 422 from `POST /api/articles` whose `errors` hold several messages, the page shows one line per message, so the number of error lines equals the number of messages in the response

## Out of Scope

Editing or deleting articles, tags, a draft or preview mode, and a "Sign out" control.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/src/pages/editor.js`, `/editor` guard in `frontend/src/router.js` |

## Test User

`jake@conduit.test` — password `Jake-Pass-123`

## Environment

- [x] Local (`http://localhost:5173` for the app, with the API from `npm start` in `backend/` on port 3000)

Browser checks need the API running: run `npm install` and `npm start` in `backend/`, then `npm run dev` in `frontend/`. The store is seeded again only when the API starts, so each verification attempt (including a retry) starts the API afresh and uses a new browser profile with empty `localStorage`.

## Navigation Path

Start the API with `npm start` in `backend/` and the app with `npm run dev` in `frontend/` > open the app's home page > click "Sign in" > sign in as jake > click "New Article" in the header > fill Title, Description and Body > click "Publish Article".

## Labels

planned, INIT-0000000000-5856, feature, blocked-by:backend-foundation, blocked-by:user-auth-api, blocked-by:articles-api, blocked-by:frontend-shell, blocked-by:reader-pages, blocked-by:auth-pages

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "Add an editor page that posts to the create endpoint and navigates to the returned slug, with a router guard that replaces /editor with /login when no token is stored.",
  "AffectedServices": "app",
  "TargetSymbols": "renderEditor (new):app/frontend/src/pages/editor.js;router (new in frontend-shell):app/frontend/src/router.js;getToken (new in frontend-shell):app/frontend/src/session.js;renderErrors (new in reader-pages):app/frontend/src/errors.js",
  "Kind": "business",
  "Serves": ["O3"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| After jake signs in, clicking "New Article" in the header changes the address bar path to `/editor` | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > click "New Article" | `location.pathname` is `/editor` | yes |
| The editor shows an input field labelled Title | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > click "New Article" | input labelled Title | yes |
| The editor shows an input field labelled Description | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > click "New Article" | input labelled Description | yes |
| The editor shows a text area labelled Body | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > click "New Article" | text area labelled Body | yes |
| The editor shows a button with the text "Publish Article" | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > click "New Article" | button "Publish Article" | yes |
| Signed in as jake, publishing title `My first post`, description `About me` and body `Hello world` changes the address bar path to `/article/my-first-post` | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > New Article > fill form > Publish Article | `location.pathname` is `/article/my-first-post` | yes |
| Publishing `My first post` as jake receives status 201 from `POST /api/articles` in the browser's network log | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > New Article > fill form > Publish Article | status 201 on the `POST /api/articles` request | yes |
| After jake publishes `My first post`, the article page shows the heading "My first post" | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > New Article > fill form > Publish Article | heading "My first post" | yes |
| After jake publishes `My first post`, the article page shows the author username "jake" | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > New Article > fill form > Publish Article | text "jake" on the article page | yes |
| After jake publishes `My first post`, the home page shows "My first post" as the first preview | author | 1 `user` `jake`; 2 seeded `article` records | seeded-by:backend-foundation | publish > open the app's home page | first preview title "My first post" | yes |
| Signed in as jake, publishing with an empty title shows the line "title can't be blank" | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > New Article > leave Title empty > Publish Article | line "title can't be blank" | yes |
| Signed in as jake, publishing with the title `!!!` shows the line "title is invalid" | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > New Article > Title `!!!` > Publish Article | line "title is invalid" | yes |
| Publishing with an empty title as jake receives status 422 from `POST /api/articles` in the browser's network log | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > New Article > leave Title empty > Publish Article | status 422 on the `POST /api/articles` request | yes |
| After a rejected publish the address bar path stays `/editor` | author | 1 `user` `jake` | seeded-by:backend-foundation | Sign in as jake > New Article > Publish Article with empty fields | `location.pathname` is `/editor` | yes |
| With no `jwt` in `localStorage`, opening `/editor` changes the address bar path to `/login` | anonymous reader | none | — | open the editor path directly while signed out | `location.pathname` is `/login` | yes |
| With no `jwt` in `localStorage`, opening `/editor` shows the sign-in form | anonymous reader | none | — | open the editor path directly while signed out | Email and Password inputs with a "Sign in" button | yes |
| With no `jwt` in `localStorage`, pressing Back after the redirect from `/editor` does not show `/editor` in the address bar | anonymous reader | none | — | open the home page > open the editor path > Back | `location.pathname` is not `/editor` | yes |
| With `jwt` set to `not-a-jwt`, opening `/editor` changes the address bar path to `/login` | anonymous reader | none | — | set `jwt`, open the editor path directly | `location.pathname` is `/login` | yes |
| Signed in as an author, publishing with Title, Description and Body all empty shows the lines "title can't be blank", "description can't be blank" and "body can't be blank", each on its own separate line above the form | author | 1 seeded author `user` | seeded-by:backend-foundation | Sign in as an author > New Article > leave all fields empty > Publish Article | three separate lines "title can't be blank", "description can't be blank", "body can't be blank" | yes |
| Signed in as an author, after a 422 from `POST /api/articles` whose `errors` hold several messages, the page shows one line per message, so the number of error lines equals the number of messages in the response | author | 1 seeded author `user` | seeded-by:backend-foundation | Sign in as an author > New Article > leave all fields empty > Publish Article | count of error lines equals count of messages in the 422 response `errors` | yes |

## Writes

| Key | Op |
|-----|----|
| `article` | append |

## Reads

| Key | Source |
|-----|--------|
| `local_storage.jwt` | framework:session |
| `article.slug` | spec |
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| After jake signs in, clicking "New Article" in the header changes the address bar path to `/editor` | `user.username` | state | value:jake | spec:backend-foundation |
| Signed in as jake, publishing title `My first post`, description `About me` and body `Hello world` changes the address bar path to `/article/my-first-post` | `user.username` | state | value:jake | spec:backend-foundation |
| Signed in as jake, publishing with an empty title shows the line "title can't be blank" | `article.title` | input | null | — |
