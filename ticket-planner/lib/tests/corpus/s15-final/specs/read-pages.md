# read-pages

## Title

Anonymous readers can browse the article list and open an article

## Description

## Summary

Add the home page, which lists the published articles newest first, and the article page, which shows one article. Both work without an account.

## Outcome

**Serves:** O2

**Who:** Anonymous reader, anyone without an account.

**Need:** Read articles without signing in.

**Outcome:** A reader sees the list of articles on the home page, newest first, and can open any of them.

## Background / Motivation

Reading is the one thing an anonymous reader can do in this app. The first part of the acceptance walk is: at the site's home address, an anonymous reader sees both seeded articles, `welcome-to-conduit` first, and can open either one.

## Proposed Behaviour

Home page, at `/`:

- It lists the articles the API returns for a list request with no filter, in the order the API returns them, which is newest first. On a freshly started API that is `Welcome to Conduit`, then `How to train your dragon`.
- Each entry shows the article's title, its description and its author's username.
- The title is a link to `/article/<slug>` for that article. Clicking it opens the article page without reloading the document.

Article page, at `/article/<slug>`:

- It shows the article's title as the page heading, the author's username and the body.
- It works when reached from the home page and when the address is loaded directly.
- If the API answers 404 for the slug, the page shows the text `article not found`.
- The browser Back button returns from an article to the home list.

Both pages work with no `jwt` key in local storage.

Titles, descriptions, bodies and usernames are written as text. An article whose title is `<b>bold</b>` shows those literal characters on both pages.

## Technical Context

All paths are under `app/frontend/`. The router, `src/api.js` and the header come from the frontend shell ticket. `GET /api/articles` and `GET /api/articles/:slug` come from the article endpoints ticket. The two seeded articles come from the store ticket.

- New `src/pages/home.js`: calls `GET /api/articles` with no query string through `src/api.js` and renders one entry per element of `articles`. It shows what the API returns for its default page and has no paging controls.
- New `src/pages/article.js`: reads the slug from the route, calls `GET /api/articles/:slug`, and renders the heading, author and body, or `article not found` on a 404.
- `src/router.js`: register the two render functions for `/` and `/article/<slug>`.
- All API values are written with `textContent`. No HTML string is built from them.
- The created and updated times are not shown.
- There is no frontend test runner. `npm run build` in `frontend/` must still exit with code 0. The API does not reload its code and keeps every article published since it started. The seed-only checks need an API that holds only the seed, so stop the running API and start it again (`npm start` in `backend/`) before checking. The two `<b>bold</b>` checks publish an article, so they run after every seed-only check, and the API is stopped and started again after them.

## Acceptance Criteria

- [ ] On a freshly started API, the home page lists exactly 2 articles.
- [ ] On a freshly started API, the first entry on the home page has the title `Welcome to Conduit`.
- [ ] On a freshly started API, the second entry on the home page has the title `How to train your dragon`.
- [ ] Each seeded entry on the home page shows the description `Seed article`.
- [ ] The home page entry for `Welcome to Conduit` shows the author `jane`.
- [ ] The home page entry for `How to train your dragon` shows the author `jake`.
- [ ] The home page lists the seeded articles when local storage has no `jwt` key.
- [ ] Clicking the title `Welcome to Conduit` on the home page changes the address bar path to `/article/welcome-to-conduit`.
- [ ] Clicking the title `How to train your dragon` on the home page changes the address bar path to `/article/how-to-train-your-dragon`.
- [ ] Clicking an article title on the home page does not reload the document.
- [ ] The article page for `welcome-to-conduit` shows the heading `Welcome to Conduit`.
- [ ] The article page for `welcome-to-conduit` shows the body `Seed body text.`
- [ ] The article page for `welcome-to-conduit` shows the author `jane`.
- [ ] The article page for `how-to-train-your-dragon` shows the heading `How to train your dragon`.
- [ ] The article page for `how-to-train-your-dragon` shows the author `jake`.
- [ ] Loading the address `/article/how-to-train-your-dragon` directly shows the heading `How to train your dragon`.
- [ ] After opening `Welcome to Conduit` from the home page, the browser Back button shows the home list again.
- [ ] Loading the address `/article/no-such-article`, for which the API answers 404, shows the text `article not found`.
- [ ] An article titled `<b>bold</b>` appears on the home page as the literal characters `<b>bold</b>`.
- [ ] An article titled `<b>bold</b>` shows the literal characters `<b>bold</b>` as the heading of its article page.

## Out of Scope

Paging controls, an author filter, tags, the feed, comments, favorites and profile pages. Showing dates. Editing or deleting an article. The sign-in, sign-up and editor pages.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE | app | `frontend/src/pages/home.js`, `frontend/src/pages/article.js`, `frontend/src/router.js` |
| BE | app | none changed; the pages call the existing API |

## Test User

Anonymous reader. No account and no password are needed.

## Navigation Path

Stop any process that is listening on port 3000, then start the API (`npm start` in `backend/`). If `npm start` prints `Port 3000 is already in use`, an older API is still running: stop it and start again. Start the frontend (`npm run dev` in `frontend/`). Open the site: the home page with the article list appears. Click an article title to open its article page. Run the two `<b>bold</b>` checks last, because they add a third article.

## Labels

planned, INIT-0000000000-5702, feature, blocked-by:scaffold-packages, blocked-by:store-and-seed, blocked-by:article-endpoints, blocked-by:frontend-shell

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 2,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Two independent npm packages in app: backend/ (Express createApp factory over a per-instance seeded in-memory store, node:test + supertest behind npm test) and frontend/ (Vite + vanilla JS with a History-API router and a dev-server proxy for /api), with no root package, no database and no CORS.",
  "AffectedServices": "app",
  "TargetSymbols": "LOCAL_URL:app/CLAUDE.md:34;UAT_URL:app/CLAUDE.md:36;homePage (new):app/frontend/src/pages/home.js;articlePage (new):app/frontend/src/pages/article.js;router (new in frontend-shell):app/frontend/src/router.js;api (new in frontend-shell):app/frontend/src/api.js;articlesRouter (new in article-endpoints):app/backend/src/routes/articles.js",
  "Kind": "business",
  "Serves": [
    "O2"
  ],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|---|
| On a freshly started API, the home page lists exactly 2 articles. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site | the list holds two entries | yes |
| On a freshly started API, the first entry on the home page has the title `Welcome to Conduit`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site | first entry title is Welcome to Conduit | yes |
| On a freshly started API, the second entry on the home page has the title `How to train your dragon`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site | second entry title is How to train your dragon | yes |
| Each seeded entry on the home page shows the description `Seed article`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site | both entries show Seed article | yes |
| The home page entry for `Welcome to Conduit` shows the author `jane`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site | the entry shows jane | yes |
| The home page entry for `How to train your dragon` shows the author `jake`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site | the entry shows jake | yes |
| The home page lists the seeded articles when local storage has no `jwt` key. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site | the list holds two entries with no jwt key set | yes |
| Clicking the title `Welcome to Conduit` on the home page changes the address bar path to `/article/welcome-to-conduit`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `Welcome to Conduit` | path is /article/welcome-to-conduit | yes |
| Clicking the title `How to train your dragon` on the home page changes the address bar path to `/article/how-to-train-your-dragon`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `How to train your dragon` | path is /article/how-to-train-your-dragon | yes |
| Clicking an article title on the home page does not reload the document. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `Welcome to Conduit` | a value set on `window` before the click is still there after it | yes |
| The article page for `welcome-to-conduit` shows the heading `Welcome to Conduit`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `Welcome to Conduit` | the page heading is Welcome to Conduit | yes |
| The article page for `welcome-to-conduit` shows the body `Seed body text.` | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `Welcome to Conduit` | the text Seed body text. is visible | yes |
| The article page for `welcome-to-conduit` shows the author `jane`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `Welcome to Conduit` | the text jane is visible on the page | yes |
| The article page for `how-to-train-your-dragon` shows the heading `How to train your dragon`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `How to train your dragon` | the page heading is How to train your dragon | yes |
| The article page for `how-to-train-your-dragon` shows the author `jake`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `How to train your dragon` | the text jake is visible on the page | yes |
| Loading the address `/article/how-to-train-your-dragon` directly shows the heading `How to train your dragon`. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > add `/article/how-to-train-your-dragon` to the site address | the page heading is How to train your dragon | yes |
| After opening `Welcome to Conduit` from the home page, the browser Back button shows the home list again. | Anonymous reader | a freshly started API holding 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed | Open the site > click `Welcome to Conduit` > press the browser Back button | path is / and the list holds two entries | yes |
| Loading the address `/article/no-such-article`, for which the API answers 404, shows the text `article not found`. | Anonymous reader | none | — | Open the site > add `/article/no-such-article` to the site address | the text article not found is visible | yes |
| An article titled `<b>bold</b>` appears on the home page as the literal characters `<b>bold</b>`. | Anonymous reader | 1 `user` in state seeded author `jake`, whose token the check uses to publish that article through the API, after every seed-only check of this ticket has run | seeded-by:store-and-seed | Open the site | the entry title text is <b>bold</b> and the entry holds no `b` element | yes |
| An article titled `<b>bold</b>` shows the literal characters `<b>bold</b>` as the heading of its article page. | Anonymous reader | 1 `user` in state seeded author `jake`, whose token the check uses to publish that article through the API, after every seed-only check of this ticket has run | seeded-by:store-and-seed | Open the site > click `<b>bold</b>` | the heading text is <b>bold</b> and the heading holds no `b` element | yes |

## Writes

None.

## Reads

| Key | Source |
|---|---|
| `article.slug` | spec |
| `article.title` | spec |
| `article.description` | spec |
| `article.body` | spec |
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|---|---|---|---|---|
| On a freshly started API, the home page lists exactly 2 articles. | `article.author` | state | value:jane | spec:store-and-seed |
| On a freshly started API, the home page lists exactly 2 articles. | `article.author` | state | value:jake | spec:store-and-seed |
| On a freshly started API, the first entry on the home page has the title `Welcome to Conduit`. | `article.author` | state | value:jane | spec:store-and-seed |
| On a freshly started API, the first entry on the home page has the title `Welcome to Conduit`. | `article.author` | state | value:jake | spec:store-and-seed |
| On a freshly started API, the second entry on the home page has the title `How to train your dragon`. | `article.author` | state | value:jane | spec:store-and-seed |
| On a freshly started API, the second entry on the home page has the title `How to train your dragon`. | `article.author` | state | value:jake | spec:store-and-seed |
| Each seeded entry on the home page shows the description `Seed article`. | `article.author` | state | value:jane | spec:store-and-seed |
| Each seeded entry on the home page shows the description `Seed article`. | `article.author` | state | value:jake | spec:store-and-seed |
| The home page entry for `Welcome to Conduit` shows the author `jane`. | `article.author` | state | value:jane | spec:store-and-seed |
| The home page entry for `How to train your dragon` shows the author `jake`. | `article.author` | state | value:jake | spec:store-and-seed |
| The home page lists the seeded articles when local storage has no `jwt` key. | `article.author` | state | value:jane | spec:store-and-seed |
| The home page lists the seeded articles when local storage has no `jwt` key. | `article.author` | state | value:jake | spec:store-and-seed |
| Clicking the title `Welcome to Conduit` on the home page changes the address bar path to `/article/welcome-to-conduit`. | `article.author` | state | value:jane | spec:store-and-seed |
| Clicking the title `How to train your dragon` on the home page changes the address bar path to `/article/how-to-train-your-dragon`. | `article.author` | state | value:jake | spec:store-and-seed |
| Clicking an article title on the home page does not reload the document. | `article.author` | state | value:jane | spec:store-and-seed |
| Clicking an article title on the home page does not reload the document. | `article.author` | state | value:jake | spec:store-and-seed |
| The article page for `welcome-to-conduit` shows the heading `Welcome to Conduit`. | `article.author` | state | value:jane | spec:store-and-seed |
| The article page for `welcome-to-conduit` shows the body `Seed body text.` | `article.author` | state | value:jane | spec:store-and-seed |
| The article page for `welcome-to-conduit` shows the author `jane`. | `article.author` | state | value:jane | spec:store-and-seed |
| The article page for `how-to-train-your-dragon` shows the heading `How to train your dragon`. | `article.author` | state | value:jake | spec:store-and-seed |
| The article page for `how-to-train-your-dragon` shows the author `jake`. | `article.author` | state | value:jake | spec:store-and-seed |
| Loading the address `/article/how-to-train-your-dragon` directly shows the heading `How to train your dragon`. | `article.author` | state | value:jake | spec:store-and-seed |
| After opening `Welcome to Conduit` from the home page, the browser Back button shows the home list again. | `article.author` | state | value:jane | spec:store-and-seed |
| After opening `Welcome to Conduit` from the home page, the browser Back button shows the home list again. | `article.author` | state | value:jake | spec:store-and-seed |
