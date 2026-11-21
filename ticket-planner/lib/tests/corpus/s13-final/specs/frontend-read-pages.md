# frontend-read-pages

## Title

Readers can browse the article list and open an article

## Description

## Summary

Build the home page, which lists articles newest first, and the article page, which shows one article in full. Both work without signing in.

## Outcome

**Serves:** O3

**Who:** Anonymous reader

**Need:** Read articles without an account.

**Outcome:** Anyone can see a newest-first list of articles and open any one of them.

## Background / Motivation

The brief's browser check starts here: an anonymous reader sees both seeded articles on the home page, with `welcome-to-conduit` first, and can open either one. The article page is also where an author lands after publishing.

## Proposed Behaviour

- The home page (`/`) loads the article list from the API and shows one preview per article, newest first.
- Each preview shows the article's title, its description and its author's username.
- Clicking a preview's title opens that article's page at `/article/<slug>`.
- The article page (`/article/<slug>`) loads that article from the API and shows its title as the page heading, its body, and its author's username.
- Opening an article page directly by its address shows the same content as reaching it from the home page.
- When the API answers status 404 for the slug, the article page shows the message "Article not found".
- Both pages look the same whether the visitor is signed in or not.
- Opening an address the app does not know, such as `/no-such-page`, shows the home page with its article previews.

## Technical Context

- Builds on `frontend-shell`: the router in `frontend/src/router.js` (routes `/` and `/article/:slug`, and its rule that an unknown path renders the home page), the API client in `frontend/src/api.js`, and the placeholder pages `frontend/src/pages/home.js` and `frontend/src/pages/article.js`, which this ticket replaces.
- Reads from `api-article-reads`: `GET /api/articles` (returns `{"articles":[...],"articlesCount":N}`, newest first) and `GET /api/articles/:slug` (returns `{"article":{...}}`, or status 404 with `{"errors":{"article":["not found"]}}`).
- Home page markup: each preview is an element with class `article-preview` holding a link (`<a href="/article/<slug>">`) with the title in an `<h2>`, the description in a `<p>`, and the author's username in an element with class `author`. The router's link interceptor handles the click.
- Article page markup: title in an `<h1>`, body in an element with class `article-content`, author's username in an element with class `author`. The not-found message is shown in place of the article.
- Text from the API is inserted as text, never as HTML.

## Acceptance Criteria

- [ ] Signed out, the home page shows 2 article previews for the 2 seeded `article` records
- [ ] Signed out, the first preview on the home page has the title "Welcome to Conduit"
- [ ] Signed out, the second preview on the home page has the title "How to train your dragon"
- [ ] The "Welcome to Conduit" preview shows the description "Seed article"
- [ ] The "Welcome to Conduit" preview shows the author "jane"
- [ ] The "How to train your dragon" preview shows the author "jake"
- [ ] Clicking the "Welcome to Conduit" preview title changes the address to `/article/welcome-to-conduit`
- [ ] Clicking the "How to train your dragon" preview title changes the address to `/article/how-to-train-your-dragon`
- [ ] The page `/article/welcome-to-conduit` shows the heading "Welcome to Conduit"
- [ ] The page `/article/welcome-to-conduit` shows the body "Seed body text."
- [ ] The page `/article/welcome-to-conduit` shows the author "jane"
- [ ] Opening `/article/how-to-train-your-dragon` directly in the address bar shows the heading "How to train your dragon"
- [ ] Opening `/article/no-such-article` shows the message "Article not found"
- [ ] With a valid token for `jake` stored as `jwt`, the home page shows 2 article previews
- [ ] Opening `/no-such-page` directly on port 5173 shows 2 article previews
- [ ] Running `npm run build` in `frontend/` exits with code 0

## Test User

- Anonymous reader: no credentials; clear `localStorage` first.
- Author: `jake@conduit.test` / `Jake-Pass-123` (username `jake`), for the signed-in check.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Frontend | app | home page article list, article page |

## Navigation Path

1. Before every verification attempt, including a retry, stop any process listening on port 3000 or 5173. Then, from this ticket's branch checkout, run `npm install` and `npm start` in `backend/`, and `npm install` and `npm run dev` in `frontend/`. Open the app at `http://localhost:5173`. Restarting the API re-seeds the store, so every attempt starts from the 2 seeded `user` and 2 seeded `article` records.
2. Open the app home page on port 5173 in a browser.
3. Read the article previews on the home page.
4. Click a preview's title to open the article page.

## Labels

planned, INIT-0000000000-9899, feature, blocked-by:frontend-shell, blocked-by:api-article-reads

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 3,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Replace the home and article placeholder pages with modules that render the API's newest-first list and single article as text.",
  "AffectedServices": "app",
  "TargetSymbols": "homePage (new in frontend-shell):app/frontend/src/pages/home.js;articlePage (new in frontend-shell):app/frontend/src/pages/article.js;apiFetch (new in frontend-shell):app/frontend/src/api.js",
  "Kind": "business",
  "Serves": ["O3"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Signed out, the home page shows 2 article previews for the 2 seeded `article` records | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | Home page | 2 previews | yes |
| Signed out, the first preview on the home page has the title "Welcome to Conduit" | anonymous reader | 2 seeded `article` records (welcome-to-conduit is newer) | seeded-by:backend-foundation | Home page | first preview title "Welcome to Conduit" | yes |
| Signed out, the second preview on the home page has the title "How to train your dragon" | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | Home page | second preview title "How to train your dragon" | yes |
| The "Welcome to Conduit" preview shows the description "Seed article" | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | Home page | text "Seed article" in that preview | yes |
| The "Welcome to Conduit" preview shows the author "jane" | anonymous reader | seeded `article` welcome-to-conduit by seeded `user` jane | seeded-by:backend-foundation | Home page | text "jane" in that preview | yes |
| The "How to train your dragon" preview shows the author "jake" | anonymous reader | seeded `article` how-to-train-your-dragon by seeded `user` jake | seeded-by:backend-foundation | Home page | text "jake" in that preview | yes |
| Clicking the "Welcome to Conduit" preview title changes the address to `/article/welcome-to-conduit` | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | Home page > Welcome to Conduit | address path `/article/welcome-to-conduit` | yes |
| Clicking the "How to train your dragon" preview title changes the address to `/article/how-to-train-your-dragon` | anonymous reader | seeded `article` how-to-train-your-dragon | seeded-by:backend-foundation | Home page > How to train your dragon | address path `/article/how-to-train-your-dragon` | yes |
| The page `/article/welcome-to-conduit` shows the heading "Welcome to Conduit" | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | Home page > Welcome to Conduit | heading "Welcome to Conduit" | yes |
| The page `/article/welcome-to-conduit` shows the body "Seed body text." | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | Home page > Welcome to Conduit | text "Seed body text." | yes |
| The page `/article/welcome-to-conduit` shows the author "jane" | anonymous reader | seeded `article` welcome-to-conduit by seeded `user` jane | seeded-by:backend-foundation | Home page > Welcome to Conduit | text "jane" on the page | yes |
| Opening `/article/how-to-train-your-dragon` directly in the address bar shows the heading "How to train your dragon" | anonymous reader | seeded `article` how-to-train-your-dragon | seeded-by:backend-foundation | type the path in the address bar | heading "How to train your dragon" | yes |
| Opening `/article/no-such-article` shows the message "Article not found" | anonymous reader | none | — | type the path in the address bar | text "Article not found" | yes |
| With a valid token for `jake` stored as `jwt`, the home page shows 2 article previews | author | seeded `user` jake with a sign-in token, 2 seeded `article` records | seeded-by:backend-foundation | Home page | 2 previews | yes |
| Opening `/no-such-page` directly on port 5173 shows 2 article previews | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | type the path in the address bar | 2 previews, the first titled "Welcome to Conduit" | yes |
| Running `npm run build` in `frontend/` exits with code 0 | developer | none | — | terminal in `frontend/` | exit code 0 | yes |

## Writes

None.

## Reads

| Key | Source |
|-----|--------|
| `article.slug` | spec |
| `article.title` | spec |
| `article.description` | spec |
| `article.body` | spec |
| `article.created_at` | spec |
| `user.username` | spec |
| `browser_session.jwt` | spec |

## Preconditions

None.
