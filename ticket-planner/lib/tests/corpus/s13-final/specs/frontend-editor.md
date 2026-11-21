# frontend-editor

## Title

Signed-in authors can publish an article from the editor

## Description

## Summary

Build the editor page (`/editor`). A signed-in author fills in a title, a description and a body, clicks "Publish Article", and lands on the new article's page. A signed-out visitor who opens `/editor` is sent to the sign-in page.

## Outcome

**Serves:** O2, O4

**Who:** Author

**Need:** Publish an article that others can read.

**Outcome:** A signed-in author can publish an article, and it gets its own readable address derived from its title. People who are not signed in are not offered publishing.

## Background / Motivation

This is the last step of the brief's browser check: `jake` signs in, publishes "My first post", and lands on `/article/my-first-post`. The brief also says that, signed out, `/editor` redirects to `/login`. The brief does not say how the editor shows an error, so the RealWorld reference frontend applies: errors are listed above the form as "field message" lines.

## Proposed Behaviour

- Signed out (no `jwt` stored), opening `/editor` changes the address to `/login` and shows the sign-in page.
- Signed in, the editor shows an input for the article title, an input for the description, a text area for the body, and a "Publish Article" button.
- Clicking "Publish Article" sends the article to the API. On success the address changes to `/article/<slug>` with the slug the API returned, and the article page shows the new article.
- On an error, the editor stays on the page and shows each API error as one line of the form "<field> <message>", for example "title can't be blank".
- The published article then appears first in the home page list.

## Technical Context

- Builds on `frontend-shell`: the router in `frontend/src/router.js` (route `/editor`), the API client in `frontend/src/api.js` (which adds `Authorization: Token <jwt>`), the session in `frontend/src/session.js`, and the placeholder page `frontend/src/pages/editor.js`, which this ticket replaces.
- Builds on `frontend-auth-pages` (signing in to get a stored token) and `frontend-read-pages` (the article page in `frontend/src/pages/article.js` that the author lands on, and the home page list).
- Calls `api-article-create`: `POST /api/articles` with `{"article":{"title","description","body"}}`; 201 returns `{"article":{"slug",...}}`, 422 returns an `errors` map, 401 returns `{"errors":{"token":["is missing or invalid"]}}`.
- Route guard: the router checks the session before rendering `/editor`; with no token it replaces the address with `/login` (no history entry for `/editor`).
- Error display (`frontend.forms.error_display`): a `<ul class="error-messages">` with one `<li>` per message, text inserted as text. A 401 from the create call is shown the same way, as "token is missing or invalid".
- Inputs use `placeholder` text "Article Title", "What's this article about?" and "Write your article". The button text is "Publish Article".

## Acceptance Criteria

- [ ] With no `jwt` in `localStorage`, opening `/editor` changes the address to `/login`
- [ ] With no `jwt` in `localStorage`, opening `/editor` shows the sign-in page's Email input
- [ ] Signed in as `jake`, the `/editor` page shows an input with the placeholder "Article Title"
- [ ] Signed in as `jake`, the `/editor` page shows an input with the placeholder "What's this article about?"
- [ ] Signed in as `jake`, the `/editor` page shows a text area with the placeholder "Write your article"
- [ ] Signed in as `jake`, the `/editor` page shows the button "Publish Article"
- [ ] Signed in as `jake`, publishing the title "My first post" changes the address to `/article/my-first-post`
- [ ] After `jake` publishes "My first post", the article page shows the heading "My first post"
- [ ] After `jake` publishes "My first post" with the body "Hello world.", the article page shows the body "Hello world."
- [ ] After `jake` publishes "My first post", the article page shows the author "jake"
- [ ] After `jake` publishes "My first post", the first preview on the home page has the title "My first post"
- [ ] Signed in as `jake`, publishing with an empty title shows the error line "title can't be blank"
- [ ] Signed in as `jake`, publishing with an empty description shows the error line "description can't be blank"
- [ ] Signed in as `jake`, publishing with an empty body shows the error line "body can't be blank"
- [ ] After a failed publish, the address stays `/editor`
- [ ] Signed in as `jake`, with `jwt` replaced by `not-a-valid-token` after the editor opens, publishing shows the error line "token is missing or invalid"
- [ ] Running `npm run build` in `frontend/` exits with code 0

## Test User

- Author: `jake@conduit.test` / `Jake-Pass-123` (username `jake`). Sign in through the sign-in page.
- Signed-out visitor: clear `localStorage` first.
- The API restart at the start of every verification attempt (Navigation Path step 1) removes earlier published articles, so a retry publishes to `my-first-post` again, not `my-first-post-2`.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Frontend | app | editor page, signed-out redirect, publish flow |

## Navigation Path

1. Before every verification attempt, including a retry, stop any process listening on port 3000 or 5173. Then, from this ticket's branch checkout, run `npm install` and `npm start` in `backend/`, and `npm install` and `npm run dev` in `frontend/`. Open the app at `http://localhost:5173`. Restarting the API re-seeds the store, so every attempt starts from the 2 seeded `user` and 2 seeded `article` records.
2. Open the app home page on port 5173 in a browser.
3. Click "Sign in" in the header and sign in as `jake`.
4. Click "New Article" in the header to open the editor.
5. Fill in the title, description and body, and click "Publish Article".

## Labels

planned, INIT-0000000000-9899, feature, blocked-by:frontend-shell, blocked-by:frontend-auth-pages, blocked-by:frontend-read-pages, blocked-by:api-article-create

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 3,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Replace the editor placeholder with a form that posts to the create endpoint, lists API errors, navigates to the returned slug, and guard the route so a signed-out visitor goes to /login.",
  "AffectedServices": "app",
  "TargetSymbols": "editorPage (new in frontend-shell):app/frontend/src/pages/editor.js;router (new in frontend-shell):app/frontend/src/router.js;articlePage (new in frontend-shell):app/frontend/src/pages/article.js",
  "Kind": "business",
  "Serves": ["O2", "O4"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| With no `jwt` in `localStorage`, opening `/editor` changes the address to `/login` | anonymous reader | none | — | type `/editor` in the address bar | address path `/login` | yes |
| With no `jwt` in `localStorage`, opening `/editor` shows the sign-in page's Email input | anonymous reader | none | — | type `/editor` in the address bar | input with placeholder "Email" | yes |
| Signed in as `jake`, the `/editor` page shows an input with the placeholder "Article Title" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article | input with placeholder "Article Title" | yes |
| Signed in as `jake`, the `/editor` page shows an input with the placeholder "What's this article about?" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article | input with placeholder "What's this article about?" | yes |
| Signed in as `jake`, the `/editor` page shows a text area with the placeholder "Write your article" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article | text area with placeholder "Write your article" | yes |
| Signed in as `jake`, the `/editor` page shows the button "Publish Article" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article | button "Publish Article" | yes |
| Signed in as `jake`, publishing the title "My first post" changes the address to `/article/my-first-post` | author | seeded `user` jake; no stored `article` with slug my-first-post (fresh API start) | seeded-by:backend-foundation | Sign in > New Article > Publish Article | address path `/article/my-first-post` | yes |
| After `jake` publishes "My first post", the article page shows the heading "My first post" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article > Publish Article | heading "My first post" | yes |
| After `jake` publishes "My first post" with the body "Hello world.", the article page shows the body "Hello world." | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article > Publish Article | text "Hello world." | yes |
| After `jake` publishes "My first post", the article page shows the author "jake" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article > Publish Article | text "jake" on the article page | yes |
| After `jake` publishes "My first post", the first preview on the home page has the title "My first post" | author | seeded `user` jake, 2 seeded `article` records | seeded-by:backend-foundation | Sign in > New Article > Publish Article > conduit | first preview title "My first post" | yes |
| Signed in as `jake`, publishing with an empty title shows the error line "title can't be blank" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article > Publish Article | error line "title can't be blank" | yes |
| Signed in as `jake`, publishing with an empty description shows the error line "description can't be blank" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article > Publish Article | error line "description can't be blank" | yes |
| Signed in as `jake`, publishing with an empty body shows the error line "body can't be blank" | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article > Publish Article | error line "body can't be blank" | yes |
| After a failed publish, the address stays `/editor` | author | seeded `user` jake | seeded-by:backend-foundation | Sign in > New Article > Publish Article | address path `/editor` | yes |
| Signed in as `jake`, with `jwt` replaced by `not-a-valid-token` after the editor opens, publishing shows the error line "token is missing or invalid" | author | seeded `user` jake; the stored `jwt` value replaced with `not-a-valid-token` from the browser console after the editor opens | seeded-by:frontend-editor | Sign in > New Article > browser console > Publish Article | error line "token is missing or invalid" | yes |
| Running `npm run build` in `frontend/` exits with code 0 | developer | none | — | terminal in `frontend/` | exit code 0 | yes |

## Test Data Provided

- A rejected sign-in fixture for the publish-time 401 check: the value `not-a-valid-token` written to `localStorage` under `jwt` from the browser console after the editor page has opened as `jake`.

## Writes

None.

## Reads

| Key | Source |
|-----|--------|
| `browser_session.jwt` | spec |
| `article.slug` | spec |
| `article.title` | spec |
| `article.body` | spec |
| `user.username` | spec |

## Preconditions

None.
