# reader-pages

## Title

Anonymous readers can browse the article list and open an article

## Description

## Summary

Add the home page, which lists articles newest first, and the article page, which shows one article in full. Both work without signing in.

## Outcome

**Serves:** O1

**Who:** Anonymous reader

**Need:** Read articles without an account.

**Outcome:** An anonymous reader sees the published articles on the home page, newest first, and can open any one of them to read it.

## Background / Motivation

The brief's first browser check is that an anonymous reader sees both seeded articles on the home page, with `welcome-to-conduit` first, and can open either one. The API already returns the list and single articles; this ticket shows them.

## Proposed Behaviour

**Home page (`/`)**

- Shows one preview per article returned by the article list, in the order the API returns them (newest first).
- Each preview shows the article title as a link, the author's username and the description.
- Clicking a preview's title opens that article's page at `/article/<slug>`.
- Any path the app does not know shows the home page.

**Article page (`/article/<slug>`)**

- Shows the article title as the page heading, the author's username and the article body.
- When the API answers 404, the page shows the text `article not found` in place of the article.
- The browser Back button returns to the home page.

## Technical Context

- Repository `app`, folder `frontend/`, built on the router, API client and header from `frontend-shell`, the list and read endpoints from `articles-api`, and the seeded articles from `backend-foundation`.
- Parameters: `ui.error_display` (a list above the form, one line per message, formatted field then message). The 404 body `{"errors":{"article":["not found"]}}` renders as `article not found`.
- New files:
  - `frontend/src/pages/home.js`: calls `GET /api/articles`, renders each entry as a preview element with a `data-link` title anchor to `/article/<slug>`, the author username and the description.
  - `frontend/src/pages/article.js`: calls `GET /api/articles/<slug>`, renders the title in an `h1`, the author username and the body; on 404 renders the errors list.
  - `frontend/src/errors.js`: `renderErrors(errors)` turning `{"errors":{"field":["message"]}}` into one `<li>` per message with the text `<field> <message>`.
- Registers `/` and `/article/:slug` in the router path table, and makes the home page the fallback for unknown paths.

## Acceptance Criteria

- [ ] As an anonymous reader, the home page shows exactly 2 article previews
- [ ] As an anonymous reader, the first preview on the home page has the title "Welcome to Conduit"
- [ ] As an anonymous reader, the second preview on the home page has the title "How to train your dragon"
- [ ] The "Welcome to Conduit" preview shows the author username "jane"
- [ ] The "How to train your dragon" preview shows the author username "jake"
- [ ] The "Welcome to Conduit" preview shows the description "Seed article"
- [ ] Clicking the title "Welcome to Conduit" on the home page changes the address bar path to `/article/welcome-to-conduit`
- [ ] Clicking the title "How to train your dragon" on the home page changes the address bar path to `/article/how-to-train-your-dragon`
- [ ] The page at `/article/welcome-to-conduit` shows the heading "Welcome to Conduit"
- [ ] The page at `/article/welcome-to-conduit` shows the body text "Seed body text."
- [ ] The page at `/article/welcome-to-conduit` shows the author username "jane"
- [ ] Opening `/article/how-to-train-your-dragon` directly in a new tab shows the heading "How to train your dragon"
- [ ] Opening `/article/placeholder-slug` shows the text "article not found"
- [ ] Opening the path `/placeholder-page` shows the home page with 2 article previews
- [ ] Pressing the browser Back button on `/article/welcome-to-conduit` after arriving from the home page shows the home page with 2 article previews

## Out of Scope

Paging controls, tag lists, favorites, author profile links, edit or delete buttons, and showing dates.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/src/pages/home.js`, `frontend/src/pages/article.js`, `frontend/src/errors.js` |

## Test User

Anonymous reader, no credentials (this ticket needs no sign-in)

## Environment

- [x] Local (`http://localhost:5173` for the app, with the API from `npm start` in `backend/` on port 3000)

Browser checks need the API running: run `npm install` and `npm start` in `backend/`, then `npm run dev` in `frontend/`. The store is seeded again only when the API starts, so each verification attempt (including a retry) starts the API afresh and uses a new browser profile with empty `localStorage`.

## Navigation Path

Start the API with `npm start` in `backend/` and the app with `npm run dev` in `frontend/` > open the app's home page > read the article list > click the title "Welcome to Conduit" > read the article page > press the browser Back button.

## Labels

planned, INIT-0000000000-5856, feature, blocked-by:backend-foundation, blocked-by:articles-api, blocked-by:frontend-shell

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "Add home and article page renderers that call the list and read endpoints and render errors as field-message lines.",
  "AffectedServices": "app",
  "TargetSymbols": "renderHome (new):app/frontend/src/pages/home.js;renderArticle (new):app/frontend/src/pages/article.js;renderErrors (new):app/frontend/src/errors.js;router (new in frontend-shell):app/frontend/src/router.js;request (new in frontend-shell):app/frontend/src/api.js",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| As an anonymous reader, the home page shows exactly 2 article previews | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | Open the app's home page | 2 previews | yes |
| As an anonymous reader, the first preview on the home page has the title "Welcome to Conduit" | anonymous reader | 2 seeded `article` records with distinct `createdAt` | seeded-by:backend-foundation | Open the app's home page | first preview title "Welcome to Conduit" | yes |
| As an anonymous reader, the second preview on the home page has the title "How to train your dragon" | anonymous reader | 2 seeded `article` records with distinct `createdAt` | seeded-by:backend-foundation | Open the app's home page | second preview title "How to train your dragon" | yes |
| The "Welcome to Conduit" preview shows the author username "jane" | anonymous reader | 1 `article` `welcome-to-conduit` by `user` `jane` | seeded-by:backend-foundation | Open the app's home page | text "jane" in that preview | yes |
| The "How to train your dragon" preview shows the author username "jake" | anonymous reader | 1 `article` `how-to-train-your-dragon` by `user` `jake` | seeded-by:backend-foundation | Open the app's home page | text "jake" in that preview | yes |
| The "Welcome to Conduit" preview shows the description "Seed article" | anonymous reader | 1 `article` `welcome-to-conduit` | seeded-by:backend-foundation | Open the app's home page | text "Seed article" in that preview | yes |
| Clicking the title "Welcome to Conduit" on the home page changes the address bar path to `/article/welcome-to-conduit` | anonymous reader | 1 `article` `welcome-to-conduit` | seeded-by:backend-foundation | Home > click "Welcome to Conduit" | `location.pathname` is `/article/welcome-to-conduit` | yes |
| Clicking the title "How to train your dragon" on the home page changes the address bar path to `/article/how-to-train-your-dragon` | anonymous reader | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | Home > click "How to train your dragon" | `location.pathname` is `/article/how-to-train-your-dragon` | yes |
| The page at `/article/welcome-to-conduit` shows the heading "Welcome to Conduit" | anonymous reader | 1 `article` `welcome-to-conduit` | seeded-by:backend-foundation | Home > click "Welcome to Conduit" | heading "Welcome to Conduit" | yes |
| The page at `/article/welcome-to-conduit` shows the body text "Seed body text." | anonymous reader | 1 `article` `welcome-to-conduit` | seeded-by:backend-foundation | Home > click "Welcome to Conduit" | text "Seed body text." | yes |
| The page at `/article/welcome-to-conduit` shows the author username "jane" | anonymous reader | 1 `article` `welcome-to-conduit` by `user` `jane` | seeded-by:backend-foundation | Home > click "Welcome to Conduit" | text "jane" | yes |
| Opening `/article/how-to-train-your-dragon` directly in a new tab shows the heading "How to train your dragon" | anonymous reader | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | open the deep link in a new tab | heading "How to train your dragon" | yes |
| Opening `/article/placeholder-slug` shows the text "article not found" | anonymous reader | none | — | open the deep link directly | text "article not found" | yes |
| Opening the path `/placeholder-page` shows the home page with 2 article previews | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | open the path directly | 2 previews | yes |
| Pressing the browser Back button on `/article/welcome-to-conduit` after arriving from the home page shows the home page with 2 article previews | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | Home > click "Welcome to Conduit" > Back | `location.pathname` is `/`, 2 previews | yes |

## Writes

None.

## Reads

| Key | Source |
|-----|--------|
| `article.slug` | spec |
| `article.title` | spec |
| `article.description` | spec |
| `article.body` | spec |
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| The "Welcome to Conduit" preview shows the author username "jane" | `user.username` | state | value:jane | spec:backend-foundation |
| The "How to train your dragon" preview shows the author username "jake" | `user.username` | state | value:jake | spec:backend-foundation |
| The page at `/article/welcome-to-conduit` shows the author username "jane" | `user.username` | state | value:jane | spec:backend-foundation |
