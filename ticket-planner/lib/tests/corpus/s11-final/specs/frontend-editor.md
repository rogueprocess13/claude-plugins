# frontend-editor

## Title

Signed-in authors can publish a new article from the editor

## Description

## Summary

Add the editor page (`/editor`). A signed-in author fills in a title, a description and a body, publishes, and lands on the new article's page. A signed-out visitor who opens `/editor` is sent to `/login`.

## Outcome

**Serves:** O2

**Who:** Author

**Need:** Publish articles; only a signed-in author can publish.

**Outcome:** A signed-in author can publish an article and lands on its page. A signed-out visitor is not offered publishing.

## Background / Motivation

The brief's acceptance walkthrough has `jake` sign in, publish "My first post" and land on `/article/my-first-post`. Signed out, `/editor` must redirect to `/login`. The intent also asks that article text render as plain text, so markup an author types into a body must not run in the page.

## Proposed Behaviour

**Signed out.** Opening `/editor` with no stored `jwt` replaces the address with `/login` and shows the sign-in page.

**Signed in.** `/editor` shows a form with a "Title" field, a "Description" field, a "Body" text area and a "Publish Article" button.

- Publishing sends `POST /api/articles` with the three values. On success the browser goes to `/article/<slug>`, using the slug the API returns, and the article page shows the new article.
- If the API returns errors, the page stays on `/editor` and shows each error as `<field> <message>` above the form (for example "title can't be blank").
- The new article then appears first on the home page, because it is the newest.
- Publishing the same title again lands on the suffixed slug the API picks (`my-first-post-2`).
- A body typed with markup, such as `<b>bold</b>`, shows as those literal characters on the article page.

## Technical Context

- Repository `app`, folder `frontend/`. Builds on `src/router.js` and `src/api.js` (`frontend-scaffold`), `src/session.js` and the token header (`frontend-auth-pages`), and the article page `src/pages/article.js` and home page `src/pages/home.js` (`frontend-reading-pages`). Calls `POST /api/articles` from `backend-articles-publish`. Signs in with the seed user `jake` from `backend-auth`. The backend runs with `npm start` in `backend/` (`backend-scaffold`).
- `frontend/src/pages/editor.js` (new): registered on `/editor` by adding one `addRoute` line to the route list in `src/main.js`, below the lines `frontend-auth-pages` and `frontend-reading-pages` added. If `getToken()` is empty, call `history.replaceState(null, '', '/login')` and render the sign-in page instead. Otherwise render the form (`<label>` texts "Title", "Description", "Body"; inputs named `title`, `description`, `body`; a `<textarea>` for body; a "Publish Article" submit button).
- On submit: `request('POST', '/articles', {article: {title, description, body}})`. When the article is created, `navigate('/article/' + body.article.slug)`. On an error response render each `errors` entry as `field + ' ' + message` (parameter `ui.api_error_display`).
- The article page from `frontend-reading-pages` already renders with `textContent` (parameter `ui.article_text_rendering`); the editor must not add any `innerHTML` path.
- No browser-side validation: the `<form>` carries `novalidate` and no input or text area has `required`, `minlength` or `pattern`. A blank field must reach the API, so the API's `can't be blank` message is what the page shows; the blank-field criteria below fail if the browser blocks the submit.
- Verify setup: the verify step starts the stack with `scripts/env-start.sh` (new in `backend-scaffold`), which restarts the backend, so each verify attempt starts with only the 2 seed articles and no `my-first-post`. The criteria run in the order listed, on that one backend start: the first `My first post` lands on `my-first-post`, the second on `my-first-post-2`.

## Acceptance Criteria

- [ ] Signed out, opening `http://localhost:5173/editor` changes the address bar to `http://localhost:5173/login`.
- [ ] Signed in as `jake`, opening `/editor` shows a "Title" field.
- [ ] Signed in as `jake`, opening `/editor` shows a "Description" field.
- [ ] Signed in as `jake`, opening `/editor` shows a "Body" field.
- [ ] Signed in as `jake`, opening `/editor` shows a "Publish Article" button.
- [ ] Signed in as `jake`, publishing title `My first post`, description `Intro` and body `Hello Conduit` changes the address bar to `http://localhost:5173/article/my-first-post`.
- [ ] After `jake` publishes `My first post`, the article page shows the heading "My first post".
- [ ] After `jake` publishes `My first post`, the article page shows the body text "Hello Conduit".
- [ ] After `jake` publishes `My first post`, the article page shows the author username `jake`.
- [ ] After `jake` publishes `My first post`, the first preview on the home page has the title "My first post".
- [ ] Signed in as `jake`, publishing a second article titled `My first post` changes the address bar to `http://localhost:5173/article/my-first-post-2`.
- [ ] Signed in as `jake`, publishing with an empty title shows the text "title can't be blank".
- [ ] Signed in as `jake`, publishing with an empty title leaves the address bar at `http://localhost:5173/editor`.
- [ ] Signed in as `jake`, publishing with an empty body shows the text "body can't be blank".
- [ ] Signed in as `jake`, publishing title `Markup test`, description `Intro` and body `<b>bold</b>` shows the literal text `<b>bold</b>` on the article page.

## Out of Scope

- Editing or deleting articles, tags, drafts, a markdown preview.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `src/pages/editor.js` |

## Test User

`jake@conduit.test` (Author) — password `Jake-Pass-123`.

## Navigation Path

Start each verify attempt from a stack started by `bash scripts/env-start.sh` (the verify step does this), so the backend holds only the seed data. Signed-out check first: run `localStorage.removeItem('jwt')` in the page, reload, then open `/editor`. Then: Home > header "Sign in" > sign in as `jake` > header "New Article" > fill Title, Description and Body > "Publish Article". Run the criteria in the listed order.

## Labels

planned, INIT-0000000000-5252, feature, blocked-by:backend-scaffold, blocked-by:backend-auth, blocked-by:backend-articles-publish, blocked-by:frontend-scaffold, blocked-by:frontend-auth-pages, blocked-by:frontend-reading-pages

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Add a vanilla JS editor page that redirects to /login without a stored jwt, posts to /api/articles with the Token header, and navigates to /article/<slug> on success.",
  "AffectedServices": "app",
  "TargetSymbols": "editorPage (new):app/frontend/src/pages/editor.js;session (new in frontend-auth-pages):app/frontend/src/session.js;articlePage (new in frontend-reading-pages):app/frontend/src/pages/article.js;main (new in frontend-scaffold):app/frontend/src/main.js;envStart (new in backend-scaffold):app/scripts/env-start.sh",
  "Kind": "business",
  "Serves": ["O2"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Signed out, opening `http://localhost:5173/editor` changes the address bar to `http://localhost:5173/login`. | anonymous reader | none | — | run `localStorage.removeItem('jwt')` in the page, reload, then open `/editor` | address bar `http://localhost:5173/login` | yes |
| Signed in as `jake`, opening `/editor` shows a "Title" field. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article | input labelled "Title" | yes |
| Signed in as `jake`, opening `/editor` shows a "Description" field. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article | input labelled "Description" | yes |
| Signed in as `jake`, opening `/editor` shows a "Body" field. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article | text area labelled "Body" | yes |
| Signed in as `jake`, opening `/editor` shows a "Publish Article" button. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article | button with text "Publish Article" | yes |
| Signed in as `jake`, publishing title `My first post`, description `Intro` and body `Hello Conduit` changes the address bar to `http://localhost:5173/article/my-first-post`. | author | 1 `user` in state registered (`jake`); 2 `article` records in state published (seed) and no `my-first-post`, from a backend restarted by `bash scripts/env-start.sh` at the start of this attempt | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | address bar `http://localhost:5173/article/my-first-post` | yes |
| After `jake` publishes `My first post`, the article page shows the heading "My first post". | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | heading "My first post" | yes |
| After `jake` publishes `My first post`, the article page shows the body text "Hello Conduit". | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | body text "Hello Conduit" | yes |
| After `jake` publishes `My first post`, the article page shows the author username `jake`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | page text includes `jake` | yes |
| After `jake` publishes `My first post`, the first preview on the home page has the title "My first post". | author | 1 `user` in state registered (`jake`); 2 `article` records in state published (seed) | seeded-by:backend-articles-read | Home | first preview title "My first post" | yes |
| Signed in as `jake`, publishing a second article titled `My first post` changes the address bar to `http://localhost:5173/article/my-first-post-2`. | author | 1 `user` in state registered (`jake`); 1 `article` in state published (`my-first-post`, published earlier in this check) | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | address bar `http://localhost:5173/article/my-first-post-2` | yes |
| Signed in as `jake`, publishing with an empty title shows the text "title can't be blank". | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | text "title can't be blank" | yes |
| Signed in as `jake`, publishing with an empty title leaves the address bar at `http://localhost:5173/editor`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | address bar `http://localhost:5173/editor` | yes |
| Signed in as `jake`, publishing with an empty body shows the text "body can't be blank". | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | text "body can't be blank" | yes |
| Signed in as `jake`, publishing title `Markup test`, description `Intro` and body `<b>bold</b>` shows the literal text `<b>bold</b>` on the article page. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | Home > Sign in > New Article > Publish Article | body text is the literal string `<b>bold</b>`, with no bold element | yes |

## Writes

None.

## Reads

| Key | Source |
|-----|--------|
| `local_storage.jwt` | spec |
| `article.slug` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| Signed out, opening `http://localhost:5173/editor` changes the address bar to `http://localhost:5173/login`. | `local_storage.jwt` | state | null | spec:frontend-auth-pages |
| Signed in as `jake`, opening `/editor` shows a "Title" field. | `user.username` | state | value:jake | spec:backend-auth |
| Signed in as `jake`, publishing with an empty title shows the text "title can't be blank". | `article.title` | input | null | — |
| Signed in as `jake`, publishing with an empty body shows the text "body can't be blank". | `article.body` | input | null | — |
