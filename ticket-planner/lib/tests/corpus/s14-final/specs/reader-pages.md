# reader-pages

## Title

Anyone can browse and read published articles

## Description

## Summary

Fill in the home page (`/`) with the list of published articles, newest first, and the article page (`/article/:slug`) with one full article. Neither needs an account.

## Outcome

**Serves:** O3

**Who:** Anonymous reader

**Need:** Read articles without an account.

**Outcome:** Anyone can see the list of published articles, newest first, and open any one of them.

## Background / Motivation

The articles API exists, but a reader in the browser sees empty pages. The brief's walkthrough has an anonymous reader see both seeded articles on the home page, `welcome-to-conduit` first, and open either one.

## Proposed Behaviour

Home page:

- Lists article previews in the order the API returns them (newest first). Each preview shows the title, the description and the author's username.
- Clicking a preview's title opens that article's page at `/article/<slug>`.

Article page:

- Shows the title as the page heading, the author's username and the full body text.
- An unknown slug shows "Article not found".

## Technical Context

- Builds on `backend-scaffold` (`npm start` in `backend/`, used to start a freshly seeded backend for verification), `frontend-shell` (stubs `frontend/src/pages/home.js` and `frontend/src/pages/article.js`, `get` from `frontend/src/api.js`, `data-link` handling in `frontend/src/router.js`) and `articles-api` (`GET /api/articles`, `GET /api/articles/:slug`, the two seeded articles).
- Home calls `GET /api/articles` with no query (default page of 20) and renders one `<article class="article-preview">` per item: an `<a data-link href="/article/<slug>">` around an `<h2>` with the title, a `<p>` with the description, and the author username.
- Article page calls `GET /api/articles/<slug>`. When the article is found it renders `<h1>` with the title, the author username in `.article-meta`, and the body in a `<div class="article-body">`. When the API answers not found, it renders "Article not found".
- Set all article text with `textContent`, never `innerHTML`.
- Parameters: `articles.list_default_limit` = 20.
- Verification setup: before each browser verification attempt, including every verify retry, stop any process listening on port 3000, start the backend fresh with `npm start` in `backend/` (a fresh start reseeds the 2 seeded users and 2 seeded articles and drops everything created at runtime), then run `npm run dev` in `frontend/`. The criteria below assume that freshly seeded backend.

## Acceptance Criteria

- [ ] Signed out, the home page lists 2 article previews
- [ ] Signed out, the first article preview on the home page has the title `Welcome to Conduit`
- [ ] Signed out, the second article preview on the home page has the title `How to train your dragon`
- [ ] Signed out, the `Welcome to Conduit` preview shows the author `jane`
- [ ] Signed out, the `How to train your dragon` preview shows the author `jake`
- [ ] Signed out, the `Welcome to Conduit` preview shows the description `Seed article`
- [ ] Signed out, clicking the `Welcome to Conduit` preview title changes the address to `/article/welcome-to-conduit`
- [ ] Signed out, clicking the `How to train your dragon` preview title changes the address to `/article/how-to-train-your-dragon`
- [ ] Signed out, the `how-to-train-your-dragon` article page shows the heading `How to train your dragon`
- [ ] Signed out, the `how-to-train-your-dragon` article page shows the body text `Seed body text.`
- [ ] Signed out, the `how-to-train-your-dragon` article page shows the author `jake`
- [ ] Signed out, the `welcome-to-conduit` article page shows the heading `Welcome to Conduit`
- [ ] Opening `http://localhost:5173/article/no-such-article` shows the text `Article not found`

## Out of Scope

Paging controls, tags, author profile pages, favorites, comments, and the editor.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app frontend | `src/pages/home.js`, `src/pages/article.js` |

## Test User

None — every check runs signed out (anonymous reader, no credentials). Restart the backend before each verification attempt (see Technical Context), so the home page holds only the 2 seeded articles.

## Navigation Path

Open the app home page > click an article title in the list.

## Labels

planned, INIT-0000000000-2767, feature, blocked-by:backend-scaffold, blocked-by:frontend-shell, blocked-by:articles-api

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
  "TargetSymbols": "homePage (new in frontend-shell):app/frontend/src/pages/home.js;articlePage (new in frontend-shell):app/frontend/src/pages/article.js;api (new in frontend-shell):app/frontend/src/api.js",
  "Kind": "business",
  "Serves": ["O3"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Signed out, the home page lists 2 article previews | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | open the app home page | 2 article previews visible | yes |
| Signed out, the first article preview on the home page has the title `Welcome to Conduit` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | open the app home page | first preview title `Welcome to Conduit` | yes |
| Signed out, the second article preview on the home page has the title `How to train your dragon` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | open the app home page | second preview title `How to train your dragon` | yes |
| Signed out, the `Welcome to Conduit` preview shows the author `jane` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | open the app home page | text `jane` inside that preview | yes |
| Signed out, the `How to train your dragon` preview shows the author `jake` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | open the app home page | text `jake` inside that preview | yes |
| Signed out, the `Welcome to Conduit` preview shows the description `Seed article` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | open the app home page | text `Seed article` inside that preview | yes |
| Signed out, clicking the `Welcome to Conduit` preview title changes the address to `/article/welcome-to-conduit` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | open the app home page > click Welcome to Conduit | address path `/article/welcome-to-conduit` | yes |
| Signed out, clicking the `How to train your dragon` preview title changes the address to `/article/how-to-train-your-dragon` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | open the app home page > click How to train your dragon | address path `/article/how-to-train-your-dragon` | yes |
| Signed out, the `how-to-train-your-dragon` article page shows the heading `How to train your dragon` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | home page > click How to train your dragon | `h1` text `How to train your dragon` | yes |
| Signed out, the `how-to-train-your-dragon` article page shows the body text `Seed body text.` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | home page > click How to train your dragon | text `Seed body text.` visible | yes |
| Signed out, the `how-to-train-your-dragon` article page shows the author `jake` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | home page > click How to train your dragon | text `jake` in the article meta | yes |
| Signed out, the `welcome-to-conduit` article page shows the heading `Welcome to Conduit` | anonymous reader | 2 seeded `article` records `welcome-to-conduit` (jane) and `how-to-train-your-dragon` (jake) | seeded-by:articles-api | home page > click Welcome to Conduit | `h1` text `Welcome to Conduit` | yes |
| Opening `http://localhost:5173/article/no-such-article` shows the text `Article not found` | anonymous reader | none | — | type an article address with an unknown slug | text `Article not found` visible | yes |

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

None.
