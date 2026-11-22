# frontend-reading-pages

## Title

Readers can browse the article list and open an article

## Description

## Summary

Add the home page (`/`), which lists articles newest first, and the article page (`/article/:slug`), which shows one article. Both work for a visitor who is not signed in.

## Outcome

**Serves:** O3

**Who:** Anonymous reader

**Need:** Read articles without an account.

**Outcome:** An anonymous reader sees the published articles on the home page, newest first, and can open any of them.

## Background / Motivation

The brief's acceptance walkthrough starts with an anonymous reader who sees both seeded articles on the home page, `welcome-to-conduit` first, and opens either one. The intent also asks that article text render as plain text, so no article can inject markup into the page.

## Proposed Behaviour

**Home page (`/`).** The page loads `GET /api/articles` and shows one preview per article, in the order the API returns (newest first). Each preview shows:

- the article title, as a link to `/article/<slug>`;
- the author's username;
- the description.

**Article page (`/article/:slug`).** The page loads `GET /api/articles/<slug>` and shows the title as the page heading, the author's username, and the body.

- If the API reports that no article has that slug, the page shows the text "article not found", built from the error body as `<field> <message>`.

All article text (title, description, body, username) shows as plain text. Markup in it is displayed as typed, not interpreted.

## Technical Context

- Repository `app`, folder `frontend/`. Builds on `src/router.js` and `src/api.js` from `frontend-scaffold`, and on the route list in `src/main.js` as `frontend-auth-pages` leaves it (with its `/login` and `/register` lines and its token header in `src/api.js`). This ticket runs after `frontend-auth-pages`, so the two never edit `src/main.js` or `src/api.js` on parallel branches. Calls `GET /api/articles` and `GET /api/articles/:slug` from `backend-articles-read`, which also seeds the two articles; the backend runs with `npm start` in `backend/` (`backend-scaffold`).
- Register both pages by adding two `addRoute` lines to the route list in `src/main.js`, below the lines `frontend-auth-pages` added.
- `frontend/src/pages/home.js` (new): registered on `/`. Each preview is an `<article class="preview">` holding an `<a href="/article/<slug>">` (title), a `.author` element (username) and a `<p>` (description). The router's link interception handles the click.
- `frontend/src/pages/article.js` (new): registered on `/article/:slug`. Renders `<h1>` (title), `.author` (username) and a `.body` element (body). On a non-2xx response, render each `errors` entry as `field + ' ' + message` (parameter `ui.api_error_display`).
- Build every element with `document.createElement` and set text with `textContent`; never use `innerHTML` with API data (parameter `ui.article_text_rendering`).
- Verify setup: the verify step starts the stack with `scripts/env-start.sh` (new in `backend-scaffold`), which restarts the backend, so each verify attempt starts with only the 2 seed articles. No criterion in this ticket publishes an article.

## Acceptance Criteria

- [ ] Signed out, opening `http://localhost:5173/` shows exactly 2 article previews.
- [ ] Signed out, the first preview on the home page has the title "Welcome to Conduit".
- [ ] Signed out, the second preview on the home page has the title "How to train your dragon".
- [ ] The "Welcome to Conduit" preview shows the author username `jane`.
- [ ] The "Welcome to Conduit" preview shows the description "Seed article".
- [ ] Clicking the "Welcome to Conduit" title changes the address bar to `http://localhost:5173/article/welcome-to-conduit`.
- [ ] Clicking the "How to train your dragon" title changes the address bar to `http://localhost:5173/article/how-to-train-your-dragon`.
- [ ] Signed out, opening `/article/how-to-train-your-dragon` shows the heading "How to train your dragon".
- [ ] Signed out, opening `/article/how-to-train-your-dragon` shows the author username `jake`.
- [ ] Signed out, opening `/article/how-to-train-your-dragon` shows the body text "Seed body text.".
- [ ] Signed out, opening `/article/welcome-to-conduit` shows the heading "Welcome to Conduit".
- [ ] Opening `/article/no-such-article` shows the text "article not found".
- [ ] With the browser's `GET /api/articles` response intercepted and replaced by one article titled `<b>Bold</b>`, the home page preview shows the literal text `<b>Bold</b>` and contains no `b` element.
- [ ] With the browser's `GET /api/articles/:slug` response intercepted and replaced by an article whose body is `<img src=x onerror=alert(1)>`, the article page `.body` element shows that literal text and contains no `img` element.
- [ ] Neither `frontend/src/pages/home.js` nor `frontend/src/pages/article.js` in `app` contains the text `innerHTML`.

## Out of Scope

- Publishing (`frontend-editor`), editing, deleting, comments, favorites, tags, the feed, pagination controls.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `src/pages/home.js`, `src/pages/article.js` |

## Test User

Anonymous reader: no account and no password.

## Navigation Path

Start each verify attempt from a stack started by `bash scripts/env-start.sh` (the verify step does this), so the backend holds only the 2 seed articles. Signed out means no `jwt` key: run `localStorage.removeItem('jwt')` in the page and reload first. Home (article list) > click an article title > article page.

## Labels

planned, INIT-0000000000-5252, feature, blocked-by:backend-scaffold, blocked-by:backend-articles-read, blocked-by:frontend-scaffold, blocked-by:frontend-auth-pages

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Add vanilla JS home and article pages that render API data with textContent only, routed through the History API router.",
  "AffectedServices": "app",
  "TargetSymbols": "homePage (new):app/frontend/src/pages/home.js;articlePage (new):app/frontend/src/pages/article.js;router (new in frontend-scaffold):app/frontend/src/router.js;main (new in frontend-scaffold):app/frontend/src/main.js;envStart (new in backend-scaffold):app/scripts/env-start.sh",
  "Kind": "business",
  "Serves": ["O3"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Signed out, opening `http://localhost:5173/` shows exactly 2 article previews. | anonymous reader | 2 `article` records in state published (seed) and no other article, from a backend restarted by `bash scripts/env-start.sh` at the start of this attempt | seeded-by:backend-articles-read | clear `jwt` and reload > Home | 2 previews | yes |
| Signed out, the first preview on the home page has the title "Welcome to Conduit". | anonymous reader | 2 `article` records in state published (seed, distinct `createdAt`) | seeded-by:backend-articles-read | Home | first preview title "Welcome to Conduit" | yes |
| Signed out, the second preview on the home page has the title "How to train your dragon". | anonymous reader | 2 `article` records in state published (seed, distinct `createdAt`) | seeded-by:backend-articles-read | Home | second preview title "How to train your dragon" | yes |
| The "Welcome to Conduit" preview shows the author username `jane`. | anonymous reader | 1 `article` in state published (`welcome-to-conduit`, author `jane`) | seeded-by:backend-articles-read | Home | preview text includes `jane` | yes |
| The "Welcome to Conduit" preview shows the description "Seed article". | anonymous reader | 1 `article` in state published (`welcome-to-conduit`) | seeded-by:backend-articles-read | Home | preview text includes "Seed article" | yes |
| Clicking the "Welcome to Conduit" title changes the address bar to `http://localhost:5173/article/welcome-to-conduit`. | anonymous reader | 1 `article` in state published (`welcome-to-conduit`) | seeded-by:backend-articles-read | Home > Welcome to Conduit | address bar `http://localhost:5173/article/welcome-to-conduit` | yes |
| Clicking the "How to train your dragon" title changes the address bar to `http://localhost:5173/article/how-to-train-your-dragon`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | Home > How to train your dragon | address bar `http://localhost:5173/article/how-to-train-your-dragon` | yes |
| Signed out, opening `/article/how-to-train-your-dragon` shows the heading "How to train your dragon". | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | Home > How to train your dragon | heading "How to train your dragon" | yes |
| Signed out, opening `/article/how-to-train-your-dragon` shows the author username `jake`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`, author `jake`) | seeded-by:backend-articles-read | Home > How to train your dragon | page text includes `jake` | yes |
| Signed out, opening `/article/how-to-train-your-dragon` shows the body text "Seed body text.". | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | Home > How to train your dragon | body text "Seed body text." | yes |
| Signed out, opening `/article/welcome-to-conduit` shows the heading "Welcome to Conduit". | anonymous reader | 1 `article` in state published (`welcome-to-conduit`) | seeded-by:backend-articles-read | Home > Welcome to Conduit | heading "Welcome to Conduit" | yes |
| Opening `/article/no-such-article` shows the text "article not found". | anonymous reader | none | — | | text "article not found" | yes |
| With the browser's `GET /api/articles` response intercepted and replaced by one article titled `<b>Bold</b>`, the home page preview shows the literal text `<b>Bold</b>` and contains no `b` element. | anonymous reader | none in the backend; the browser test intercepts `GET /api/articles` and answers 200 with one article titled `<b>Bold</b>`, so no article is published | — | clear `jwt` and reload > Home | preview title text `<b>Bold</b>`, no `b` element inside the preview | yes |
| With the browser's `GET /api/articles/:slug` response intercepted and replaced by an article whose body is `<img src=x onerror=alert(1)>`, the article page `.body` element shows that literal text and contains no `img` element. | anonymous reader | none in the backend; the browser test intercepts `GET /api/articles/how-to-train-your-dragon` and answers 200 with that article's body replaced by `<img src=x onerror=alert(1)>`, so no article is published | — | clear `jwt` and reload > open `/article/how-to-train-your-dragon` | `.body` text `<img src=x onerror=alert(1)>`, no `img` element inside `.body` | yes |
| Neither `frontend/src/pages/home.js` nor `frontend/src/pages/article.js` in `app` contains the text `innerHTML`. | anonymous reader | none | — | `grep -c innerHTML frontend/src/pages/home.js frontend/src/pages/article.js` in `app` | each file reports count 0 | yes |

## Writes

None.

## Reads

| Key | Source |
|-----|--------|
| `article.slug` | spec |
| `article.title` | spec |
| `article.description` | spec |
| `article.body` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| The "Welcome to Conduit" preview shows the author username `jane`. | `article.author` | state | value:jane | spec:backend-articles-read |
| Signed out, opening `/article/how-to-train-your-dragon` shows the author username `jake`. | `article.author` | state | value:jake | spec:backend-articles-read |
