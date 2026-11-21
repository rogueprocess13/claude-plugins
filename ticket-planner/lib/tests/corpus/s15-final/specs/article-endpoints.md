# article-endpoints

## Title

Authors can publish articles and anyone can read and list them through the API

## Description

## Summary

Add the three article endpoints of the API: create an article (authors only), read one article by its slug, and list articles newest first with paging and an author filter.

## Outcome

**Serves:** O1, O2

**Who:** Author, and Anonymous reader.

**Need:** An author needs to publish an article. Anyone needs to read articles without an account.

**Outcome:** A signed-in author can publish an article, and anyone can open a published article or see the list of articles, newest first.

## Background / Motivation

Articles are the content of the app. Authors publish them, and anyone, with or without an account, reads them. The brief gives the request and response shapes, the rule that turns a title into a slug, the list defaults and ordering, and the exact error bodies.

Where the brief is silent, this ticket states the behaviour outright so that it can be tested: a title with no letters or digits, `limit` and `offset` values that are not usable, an unknown author, and the order of two articles created at the same instant.

## Proposed Behaviour

All three endpoints answer with JSON. An article is returned in the `article` shape: `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`, where `author` is `{"username","bio","image"}`. No other key is returned.

Create, `POST /api/articles` with `{"article":{"title","description","body"}}` and the header `Authorization: Token <jwt>`:

- With a valid token and three non-blank fields it stores the article with the token's user as author and returns 201 with `{"article":{...}}`.
- `title`, `description` and `body` are stored and returned as submitted.
- `createdAt` is the server time as an ISO 8601 UTC string with milliseconds, for example `2026-03-04T05:06:07.890Z`. `updatedAt` equals `createdAt`.
- A missing or invalid token returns 401 with `{"errors":{"token":["is missing or invalid"]}}`. The token is checked before the fields are validated, so a request with no token and an empty body also gets the 401.
- Each blank field (missing, not a string, or empty after trimming) gives 422 with `{"errors":{"<field>":["can't be blank"]}}`. All blank fields are reported in one response. A body with no `article` object is treated as all three fields blank.
- A request body that is not valid JSON returns 422 with `{"errors":{"json":["is not valid"]}}`, both with a valid token and with no token. The app reads the body before it reads the token, so this is the one case where a request with no token does not get the 401.

Slug:

- The slug is the title in lower case, with each run of characters other than `a` to `z` and `0` to `9` replaced by one `-`, and with leading and trailing `-` removed. Accented letters count as other characters.
- If the slug is already used, `-2` is appended. If that is used too, `-3`, and so on: the first free number wins.
- If the title has no letter or digit, the slug is `untitled`, and the same suffix rule applies.

Read one, `GET /api/articles/:slug`, no token needed:

- A known slug returns 200 with `{"article":{...}}`.
- An unknown slug returns 404 with `{"errors":{"article":["not found"]}}`.

List, `GET /api/articles?limit=&offset=&author=`, no token needed:

- It returns 200 with `{"articles":[...],"articlesCount":N}`. Each element of `articles` has the `article` shape.
- Articles are ordered by `createdAt`, newest first. When two articles share one `createdAt` value, the one created later comes first.
- `author` keeps only the articles whose author's username equals the value exactly, case included. An author nobody has gives an empty list. An empty `author=` is ignored.
- `articlesCount` is the number of articles after the author filter and before paging.
- `offset` skips that many articles and `limit` caps how many are returned. The defaults are `limit` 20 and `offset` 0. A `limit` or `offset` that is not a non-negative whole number (negative, fractional, not a number) falls back to its default.
- `limit=0` returns an empty `articles` array with the full count. An `offset` past the end does the same. There is no upper cap on `limit`.

## Technical Context

All paths are under `app/backend/`. `src/app.js` comes from the scaffold ticket. `src/store.js` (article lookup by slug, add article, list articles, the insertion sequence) comes from the store ticket. `requireAuth` in `src/auth.js`, the blank check in `src/validation.js` and `src/serializers.js` come from the account endpoints ticket.

- New `src/slug.js`: `slugify(title)` and `uniqueSlug(title, exists)`. `slugify` lower-cases, replaces each run matching `[^a-z0-9]+` with `-` and trims `-` from both ends. `uniqueSlug` falls back to `untitled` for an empty result, then tries the bare slug, then `-2`, `-3` and upward until `exists` says the slug is free.
- `src/serializers.js`: add `toArticleResponse(article, author)`. It returns the seven named keys and builds `author` from username, bio and image only.
- New `src/routes/articles.js`: `POST /api/articles` behind `requireAuth`, `GET /api/articles/:slug`, `GET /api/articles`. Paging defaults are the values of `list_default_limit` (20) and `list_default_offset` (0). Query values are accepted only when they match `^[0-9]+$`. Sorting is by `createdAt` descending, then insertion sequence descending.
- `src/app.js`: mount the articles router under `/api`. The handler that answers a body that is not valid JSON comes from the account endpoints ticket and already covers the new route; this ticket adds no parser and no handler of its own.
- New `test/slug.test.js` and `test/articles.test.js` (`node:test` + `supertest`): one test per acceptance criterion, each against its own `createApp()`, so each starts from the two seeded articles. Tests that need a token log in as `jake` first. The equal-`createdAt` case freezes the clock with the `node:test` mock timers.
- After this ticket `npm test` in `backend/` covers all six endpoints of the brief and each of its error cases.

## Acceptance Criteria

- [ ] `POST /api/articles` with the token of `jake`, title `My first post`, description `About my post` and body `Hello world` returns 201.
- [ ] The 201 create response body is an `article` object with exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`.
- [ ] Creating an article titled `My first post` on a store holding only the seed returns the slug `my-first-post`.
- [ ] The 201 create response returns `title` `My first post` as submitted.
- [ ] The 201 create response returns `description` `About my post` as submitted.
- [ ] The 201 create response returns `body` `Hello world` as submitted.
- [ ] The 201 create response for the token of `jake` has `author` equal to `{"username":"jake","bio":null,"image":null}`.
- [ ] The 201 create response has a `createdAt` value in the form `YYYY-MM-DDTHH:mm:ss.sssZ`.
- [ ] The 201 create response has `updatedAt` equal to `createdAt`.
- [ ] `POST /api/articles` with no `Authorization` header returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `POST /api/articles` with the header `Authorization: Token not-a-jwt` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `POST /api/articles` with no `Authorization` header and the body `{}` returns 401, not 422.
- [ ] `POST /api/articles` with the token of `jake`, the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`.
- [ ] `POST /api/articles` with no `Authorization` header, the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`.
- [ ] `POST /api/articles` with the token of `jake` and no `title` returns 422 with body `{"errors":{"title":["can't be blank"]}}`.
- [ ] `POST /api/articles` with the token of `jake` and no `description` returns 422 with body `{"errors":{"description":["can't be blank"]}}`.
- [ ] `POST /api/articles` with the token of `jake` and no `body` returns 422 with body `{"errors":{"body":["can't be blank"]}}`.
- [ ] `POST /api/articles` with the token of `jake` and a `title` made only of spaces returns 422 with body `{"errors":{"title":["can't be blank"]}}`.
- [ ] `POST /api/articles` with the token of `jake` and the body `{}` returns 422 with body `{"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}}`.
- [ ] Creating an article titled `Hello,   World!!` returns the slug `hello-world`.
- [ ] Creating an article titled `--Tips & Tricks--` returns the slug `tips-tricks`.
- [ ] Creating an article titled `Top 10 Tips` returns the slug `top-10-tips`.
- [ ] Creating an article titled `Café Olé` returns the slug `caf-ol`.
- [ ] Creating a second article titled `My first post` returns the slug `my-first-post-2`.
- [ ] Creating a third article titled `My first post` returns the slug `my-first-post-3`.
- [ ] Creating an article titled `Welcome to Conduit` on a store holding the seed returns the slug `welcome-to-conduit-2`.
- [ ] Creating an article titled `!!!` returns the slug `untitled`.
- [ ] Creating an article titled `!!!` returns `title` `!!!` unchanged.
- [ ] Creating a second article titled `!!!` returns the slug `untitled-2`.
- [ ] `GET /api/articles/welcome-to-conduit` with no `Authorization` header returns 200.
- [ ] The 200 response for `welcome-to-conduit` is an `article` object with exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`.
- [ ] The 200 response for `welcome-to-conduit` has the title `Welcome to Conduit`.
- [ ] The 200 response for `welcome-to-conduit` has the description `Seed article`.
- [ ] The 200 response for `welcome-to-conduit` has the body `Seed body text.`
- [ ] The 200 response for `welcome-to-conduit` has the `createdAt` value `2026-01-02T10:00:00.000Z`.
- [ ] The 200 response for `welcome-to-conduit` has the `updatedAt` value `2026-01-02T10:00:00.000Z`.
- [ ] The 200 response for `welcome-to-conduit` has `author` equal to `{"username":"jane","bio":null,"image":null}`.
- [ ] `GET /api/articles/how-to-train-your-dragon` returns 200 with the title `How to train your dragon`.
- [ ] The 200 response for `how-to-train-your-dragon` has the author username `jake`.
- [ ] The 200 response for `how-to-train-your-dragon` has the `createdAt` value `2026-01-01T10:00:00.000Z`.
- [ ] `GET /api/articles/no-such-article` returns 404 with body `{"errors":{"article":["not found"]}}`.
- [ ] After `jake` creates `My first post`, `GET /api/articles/my-first-post` returns 200 with the body `Hello world`.
- [ ] `GET /api/articles` with no query and no `Authorization` header returns 200.
- [ ] The 200 list response body has exactly the keys `articles` and `articlesCount`.
- [ ] On a store holding only the seed, the list response has `articlesCount` 2.
- [ ] On a store holding only the seed, the list returns `welcome-to-conduit` first.
- [ ] On a store holding only the seed, the list returns `how-to-train-your-dragon` second.
- [ ] Each element of the list `articles` array has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`.
- [ ] After `jake` creates `My first post`, the list returns `my-first-post` first.
- [ ] After `jake` creates `My first post`, the list response has `articlesCount` 3.
- [ ] `GET /api/articles?limit=1` on the seed returns only `welcome-to-conduit`.
- [ ] `GET /api/articles?limit=1` on the seed returns `articlesCount` 2.
- [ ] `GET /api/articles?offset=1` on the seed returns only `how-to-train-your-dragon`.
- [ ] `GET /api/articles?offset=1` on the seed returns `articlesCount` 2.
- [ ] `GET /api/articles?limit=0` on the seed returns an empty `articles` array with `articlesCount` 2.
- [ ] `GET /api/articles?offset=5` on the seed returns an empty `articles` array with `articlesCount` 2.
- [ ] `GET /api/articles?limit=abc` on the seed returns both seeded articles.
- [ ] `GET /api/articles?limit=-1` on the seed returns both seeded articles.
- [ ] `GET /api/articles?limit=1.5` on the seed returns both seeded articles.
- [ ] `GET /api/articles?offset=abc` on the seed returns both seeded articles.
- [ ] `GET /api/articles?offset=-1` on the seed returns both seeded articles.
- [ ] With 22 stored articles, `GET /api/articles` with no `limit` returns 20 articles.
- [ ] With 22 stored articles, `GET /api/articles` with no `limit` returns `articlesCount` 22.
- [ ] With 22 stored articles, `GET /api/articles?limit=100` returns 22 articles.
- [ ] `GET /api/articles?author=jake` on the seed returns only `how-to-train-your-dragon` with `articlesCount` 1.
- [ ] `GET /api/articles?author=jane` on the seed returns only `welcome-to-conduit` with `articlesCount` 1.
- [ ] `GET /api/articles?author=Jake` on the seed returns 200 with body `{"articles":[],"articlesCount":0}`.
- [ ] `GET /api/articles?author=nobody` on the seed returns 200 with body `{"articles":[],"articlesCount":0}`.
- [ ] `GET /api/articles?author=` on the seed returns both seeded articles.
- [ ] `GET /api/articles?author=jake&limit=0` on the seed returns an empty `articles` array with `articlesCount` 1.
- [ ] When two created articles share one `createdAt` value, the list returns the one created later first.

## Out of Scope

Editing and deleting articles, tags, comments, favorites, the feed and follow. Paging metadata beyond `articlesCount`, sorting options and full-text search are not built. No page is added by this ticket.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/src/routes/articles.js`, `backend/src/slug.js`, `backend/src/serializers.js`, `backend/src/app.js`, `backend/test/articles.test.js`, `backend/test/slug.test.js` |

## Test User

`jake@conduit.test`, password `Jake-Pass-123` (seeded author) for publishing. Reading and listing need no account.

## Navigation Path

No screen. This ticket is API only: each check is an HTTP request to the API, run by `npm test` in `backend/`, or sent by hand to a freshly started API (`npm start` in `backend/`).

## Labels

planned, INIT-0000000000-5702, feature, blocked-by:scaffold-packages, blocked-by:store-and-seed, blocked-by:auth-endpoints

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
  "TargetSymbols": "Express:app/CLAUDE.md:21;BE_TEST_CMD:app/CLAUDE.md:46;slugify/uniqueSlug (new):app/backend/src/slug.js;articlesRouter (new):app/backend/src/routes/articles.js;toArticleResponse (new in auth-endpoints):app/backend/src/serializers.js;requireAuth (new in auth-endpoints):app/backend/src/auth.js;createStore (new in store-and-seed):app/backend/src/store.js;createApp (new in scaffold-packages):app/backend/src/app.js;articlesTest (new):app/backend/test/articles.test.js;slugTest (new):app/backend/test/slug.test.js",
  "Kind": "business",
  "Serves": [
    "O1",
    "O2"
  ],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|---|
| `POST /api/articles` with the token of `jake`, title `My first post`, description `About my post` and body `Hello world` returns 201. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 201 | yes |
| The 201 create response body is an `article` object with exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | the key set of `article` is slug, title, description, body, createdAt, updatedAt, author | yes |
| Creating an article titled `My first post` on a store holding only the seed returns the slug `my-first-post`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is my-first-post | yes |
| The 201 create response returns `title` `My first post` as submitted. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | title is My first post | yes |
| The 201 create response returns `description` `About my post` as submitted. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | description is About my post | yes |
| The 201 create response returns `body` `Hello world` as submitted. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | body is Hello world | yes |
| The 201 create response for the token of `jake` has `author` equal to `{"username":"jake","bio":null,"image":null}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | author is {"username":"jake","bio":null,"image":null} with no other key | yes |
| The 201 create response has a `createdAt` value in the form `YYYY-MM-DDTHH:mm:ss.sssZ`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | createdAt matches the pattern of four digits, two, two, T, time with milliseconds, Z | yes |
| The 201 create response has `updatedAt` equal to `createdAt`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | the two values are the same string | yes |
| `POST /api/articles` with no `Authorization` header returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | API client with no account | built in the test: a valid article payload sent with no token | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `POST /api/articles` with the header `Authorization: Token not-a-jwt` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | API client with no account | built in the test: a valid article payload sent with a token that is not a JWT | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `POST /api/articles` with no `Authorization` header and the body `{}` returns 401, not 422. | API client with no account | built in the test: an empty JSON object sent with no token | — |  | status 401, body {"errors":{"token":["is missing or invalid"]}} | yes |
| `POST /api/articles` with the token of `jake`, the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"json":["is not valid"]}} | yes |
| `POST /api/articles` with no `Authorization` header, the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`. | API client with no account | built in the test: a malformed JSON request body sent with no token | — |  | status 422, body {"errors":{"json":["is not valid"]}} | yes |
| `POST /api/articles` with the token of `jake` and no `title` returns 422 with body `{"errors":{"title":["can't be blank"]}}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"title":["can't be blank"]}} | yes |
| `POST /api/articles` with the token of `jake` and no `description` returns 422 with body `{"errors":{"description":["can't be blank"]}}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"description":["can't be blank"]}} | yes |
| `POST /api/articles` with the token of `jake` and no `body` returns 422 with body `{"errors":{"body":["can't be blank"]}}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"body":["can't be blank"]}} | yes |
| `POST /api/articles` with the token of `jake` and a `title` made only of spaces returns 422 with body `{"errors":{"title":["can't be blank"]}}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"title":["can't be blank"]}} | yes |
| `POST /api/articles` with the token of `jake` and the body `{}` returns 422 with body `{"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}}`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 422, body {"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}} | yes |
| Creating an article titled `Hello,   World!!` returns the slug `hello-world`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is hello-world | yes |
| Creating an article titled `--Tips & Tricks--` returns the slug `tips-tricks`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is tips-tricks | yes |
| Creating an article titled `Top 10 Tips` returns the slug `top-10-tips`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is top-10-tips | yes |
| Creating an article titled `Café Olé` returns the slug `caf-ol`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is caf-ol | yes |
| Creating a second article titled `My first post` returns the slug `my-first-post-2`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is my-first-post-2 | yes |
| Creating a third article titled `My first post` returns the slug `my-first-post-3`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is my-first-post-3 | yes |
| Creating an article titled `Welcome to Conduit` on a store holding the seed returns the slug `welcome-to-conduit-2`. | Author (`jake`) | 1 `article` in state seeded `welcome-to-conduit`; the test publishes as seeded author `jake` | seeded-by:store-and-seed |  | slug is welcome-to-conduit-2 | yes |
| Creating an article titled `!!!` returns the slug `untitled`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is untitled | yes |
| Creating an article titled `!!!` returns `title` `!!!` unchanged. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | title is !!! | yes |
| Creating a second article titled `!!!` returns the slug `untitled-2`. | Author (`jake`) | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | slug is untitled-2 | yes |
| `GET /api/articles/welcome-to-conduit` with no `Authorization` header returns 200. | Anonymous reader | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | status 200 | yes |
| The 200 response for `welcome-to-conduit` is an `article` object with exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`. | Anonymous reader | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | the key set of `article` is slug, title, description, body, createdAt, updatedAt, author | yes |
| The 200 response for `welcome-to-conduit` has the title `Welcome to Conduit`. | Anonymous reader | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | title is Welcome to Conduit | yes |
| The 200 response for `welcome-to-conduit` has the description `Seed article`. | Anonymous reader | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | description is Seed article | yes |
| The 200 response for `welcome-to-conduit` has the body `Seed body text.` | Anonymous reader | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | body is Seed body text. | yes |
| The 200 response for `welcome-to-conduit` has the `createdAt` value `2026-01-02T10:00:00.000Z`. | Anonymous reader | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | createdAt is 2026-01-02T10:00:00.000Z | yes |
| The 200 response for `welcome-to-conduit` has the `updatedAt` value `2026-01-02T10:00:00.000Z`. | Anonymous reader | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | updatedAt is 2026-01-02T10:00:00.000Z | yes |
| The 200 response for `welcome-to-conduit` has `author` equal to `{"username":"jane","bio":null,"image":null}`. | Anonymous reader | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | author is {"username":"jane","bio":null,"image":null} with no other key | yes |
| `GET /api/articles/how-to-train-your-dragon` returns 200 with the title `How to train your dragon`. | Anonymous reader | 1 `article` in state seeded `how-to-train-your-dragon` | seeded-by:store-and-seed |  | status 200, title is How to train your dragon | yes |
| The 200 response for `how-to-train-your-dragon` has the author username `jake`. | Anonymous reader | 1 `article` in state seeded `how-to-train-your-dragon` | seeded-by:store-and-seed |  | author.username is jake | yes |
| The 200 response for `how-to-train-your-dragon` has the `createdAt` value `2026-01-01T10:00:00.000Z`. | Anonymous reader | 1 `article` in state seeded `how-to-train-your-dragon` | seeded-by:store-and-seed |  | createdAt is 2026-01-01T10:00:00.000Z | yes |
| `GET /api/articles/no-such-article` returns 404 with body `{"errors":{"article":["not found"]}}`. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | status 404, body {"errors":{"article":["not found"]}} | yes |
| After `jake` creates `My first post`, `GET /api/articles/my-first-post` returns 200 with the body `Hello world`. | Anonymous reader | 1 `user` in state seeded author `jake` (`jake@conduit.test` / `Jake-Pass-123`) | seeded-by:store-and-seed |  | status 200, body field is Hello world | yes |
| `GET /api/articles` with no query and no `Authorization` header returns 200. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | status 200 | yes |
| The 200 list response body has exactly the keys `articles` and `articlesCount`. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | the top-level key set is articles, articlesCount | yes |
| On a store holding only the seed, the list response has `articlesCount` 2. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articlesCount is 2 | yes |
| On a store holding only the seed, the list returns `welcome-to-conduit` first. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles[0].slug is welcome-to-conduit | yes |
| On a store holding only the seed, the list returns `how-to-train-your-dragon` second. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles[1].slug is how-to-train-your-dragon | yes |
| Each element of the list `articles` array has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | every element has the key set slug, title, description, body, createdAt, updatedAt, author | yes |
| After `jake` creates `My first post`, the list returns `my-first-post` first. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`); the test publishes one more as seeded author `jake` | seeded-by:store-and-seed |  | articles[0].slug is my-first-post | yes |
| After `jake` creates `My first post`, the list response has `articlesCount` 3. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`); the test publishes one more as seeded author `jake` | seeded-by:store-and-seed |  | articlesCount is 3 | yes |
| `GET /api/articles?limit=1` on the seed returns only `welcome-to-conduit`. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds one element, slug welcome-to-conduit | yes |
| `GET /api/articles?limit=1` on the seed returns `articlesCount` 2. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articlesCount is 2 | yes |
| `GET /api/articles?offset=1` on the seed returns only `how-to-train-your-dragon`. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds one element, slug how-to-train-your-dragon | yes |
| `GET /api/articles?offset=1` on the seed returns `articlesCount` 2. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articlesCount is 2 | yes |
| `GET /api/articles?limit=0` on the seed returns an empty `articles` array with `articlesCount` 2. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles is [], articlesCount is 2 | yes |
| `GET /api/articles?offset=5` on the seed returns an empty `articles` array with `articlesCount` 2. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles is [], articlesCount is 2 | yes |
| `GET /api/articles?limit=abc` on the seed returns both seeded articles. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds two elements | yes |
| `GET /api/articles?limit=-1` on the seed returns both seeded articles. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds two elements | yes |
| `GET /api/articles?limit=1.5` on the seed returns both seeded articles. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds two elements | yes |
| `GET /api/articles?offset=abc` on the seed returns both seeded articles. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds two elements | yes |
| `GET /api/articles?offset=-1` on the seed returns both seeded articles. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds two elements | yes |
| With 22 stored articles, `GET /api/articles` with no `limit` returns 20 articles. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`); the test publishes 20 more as seeded author `jake` | seeded-by:store-and-seed |  | articles holds twenty elements | yes |
| With 22 stored articles, `GET /api/articles` with no `limit` returns `articlesCount` 22. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`); the test publishes 20 more as seeded author `jake` | seeded-by:store-and-seed |  | articlesCount is 22 | yes |
| With 22 stored articles, `GET /api/articles?limit=100` returns 22 articles. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`); the test publishes 20 more as seeded author `jake` | seeded-by:store-and-seed |  | articles holds twenty-two elements | yes |
| `GET /api/articles?author=jake` on the seed returns only `how-to-train-your-dragon` with `articlesCount` 1. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds one element, slug how-to-train-your-dragon, articlesCount is 1 | yes |
| `GET /api/articles?author=jane` on the seed returns only `welcome-to-conduit` with `articlesCount` 1. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds one element, slug welcome-to-conduit, articlesCount is 1 | yes |
| `GET /api/articles?author=Jake` on the seed returns 200 with body `{"articles":[],"articlesCount":0}`. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | status 200, body {"articles":[],"articlesCount":0} | yes |
| `GET /api/articles?author=nobody` on the seed returns 200 with body `{"articles":[],"articlesCount":0}`. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | status 200, body {"articles":[],"articlesCount":0} | yes |
| `GET /api/articles?author=` on the seed returns both seeded articles. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles holds two elements, articlesCount is 2 | yes |
| `GET /api/articles?author=jake&limit=0` on the seed returns an empty `articles` array with `articlesCount` 1. | Anonymous reader | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | articles is [], articlesCount is 1 | yes |
| When two created articles share one `createdAt` value, the list returns the one created later first. | Author (`jake`) | 1 `user` in state seeded author `jake`; the test freezes the clock and publishes twice | seeded-by:store-and-seed |  | the later-created slug is at the lower index | yes |

## Writes

| Key | Op |
|---|---|
| `article` | append |

## Reads

| Key | Source |
|---|---|
| `article.slug` | spec |
| `article.created_at` | spec |
| `user.id` | spec |
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|---|---|---|---|---|
| `POST /api/articles` with the token of `jake`, title `My first post`, description `About my post` and body `Hello world` returns 201. | `user.username` | state | value:jake | spec:store-and-seed |
| `POST /api/articles` with the token of `jake`, the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`. | `user.username` | state | value:jake | spec:store-and-seed |
| `POST /api/articles` with the token of `jake` and no `title` returns 422 with body `{"errors":{"title":["can't be blank"]}}`. | `article.title` | input | null | — |
| `POST /api/articles` with the token of `jake` and no `description` returns 422 with body `{"errors":{"description":["can't be blank"]}}`. | `article.description` | input | null | — |
| `POST /api/articles` with the token of `jake` and no `body` returns 422 with body `{"errors":{"body":["can't be blank"]}}`. | `article.body` | input | null | — |
| Creating an article titled `Welcome to Conduit` on a store holding the seed returns the slug `welcome-to-conduit-2`. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles/welcome-to-conduit` with no `Authorization` header returns 200. | `article.author` | state | value:jane | spec:store-and-seed |
| The 200 response for `welcome-to-conduit` is an `article` object with exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`. | `article.author` | state | value:jane | spec:store-and-seed |
| The 200 response for `welcome-to-conduit` has the title `Welcome to Conduit`. | `article.author` | state | value:jane | spec:store-and-seed |
| The 200 response for `welcome-to-conduit` has the description `Seed article`. | `article.author` | state | value:jane | spec:store-and-seed |
| The 200 response for `welcome-to-conduit` has the body `Seed body text.` | `article.author` | state | value:jane | spec:store-and-seed |
| The 200 response for `welcome-to-conduit` has the `createdAt` value `2026-01-02T10:00:00.000Z`. | `article.author` | state | value:jane | spec:store-and-seed |
| The 200 response for `welcome-to-conduit` has the `updatedAt` value `2026-01-02T10:00:00.000Z`. | `article.author` | state | value:jane | spec:store-and-seed |
| The 200 response for `welcome-to-conduit` has `author` equal to `{"username":"jane","bio":null,"image":null}`. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles/how-to-train-your-dragon` returns 200 with the title `How to train your dragon`. | `article.author` | state | value:jake | spec:store-and-seed |
| The 200 response for `how-to-train-your-dragon` has the author username `jake`. | `article.author` | state | value:jake | spec:store-and-seed |
| The 200 response for `how-to-train-your-dragon` has the `createdAt` value `2026-01-01T10:00:00.000Z`. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles` with no query and no `Authorization` header returns 200. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles` with no query and no `Authorization` header returns 200. | `article.author` | state | value:jake | spec:store-and-seed |
| The 200 list response body has exactly the keys `articles` and `articlesCount`. | `article.author` | state | value:jane | spec:store-and-seed |
| The 200 list response body has exactly the keys `articles` and `articlesCount`. | `article.author` | state | value:jake | spec:store-and-seed |
| On a store holding only the seed, the list response has `articlesCount` 2. | `article.author` | state | value:jane | spec:store-and-seed |
| On a store holding only the seed, the list response has `articlesCount` 2. | `article.author` | state | value:jake | spec:store-and-seed |
| On a store holding only the seed, the list returns `welcome-to-conduit` first. | `article.author` | state | value:jane | spec:store-and-seed |
| On a store holding only the seed, the list returns `welcome-to-conduit` first. | `article.author` | state | value:jake | spec:store-and-seed |
| On a store holding only the seed, the list returns `how-to-train-your-dragon` second. | `article.author` | state | value:jane | spec:store-and-seed |
| On a store holding only the seed, the list returns `how-to-train-your-dragon` second. | `article.author` | state | value:jake | spec:store-and-seed |
| Each element of the list `articles` array has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`. | `article.author` | state | value:jane | spec:store-and-seed |
| Each element of the list `articles` array has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`. | `article.author` | state | value:jake | spec:store-and-seed |
| After `jake` creates `My first post`, the list returns `my-first-post` first. | `article.author` | state | value:jane | spec:store-and-seed |
| After `jake` creates `My first post`, the list returns `my-first-post` first. | `article.author` | state | value:jake | spec:store-and-seed |
| After `jake` creates `My first post`, the list response has `articlesCount` 3. | `article.author` | state | value:jane | spec:store-and-seed |
| After `jake` creates `My first post`, the list response has `articlesCount` 3. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?limit=1` on the seed returns only `welcome-to-conduit`. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?limit=1` on the seed returns only `welcome-to-conduit`. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?limit=1` on the seed returns `articlesCount` 2. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?limit=1` on the seed returns `articlesCount` 2. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?offset=1` on the seed returns only `how-to-train-your-dragon`. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?offset=1` on the seed returns only `how-to-train-your-dragon`. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?offset=1` on the seed returns `articlesCount` 2. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?offset=1` on the seed returns `articlesCount` 2. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?limit=0` on the seed returns an empty `articles` array with `articlesCount` 2. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?limit=0` on the seed returns an empty `articles` array with `articlesCount` 2. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?offset=5` on the seed returns an empty `articles` array with `articlesCount` 2. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?offset=5` on the seed returns an empty `articles` array with `articlesCount` 2. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?limit=abc` on the seed returns both seeded articles. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?limit=abc` on the seed returns both seeded articles. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?limit=-1` on the seed returns both seeded articles. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?limit=-1` on the seed returns both seeded articles. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?limit=1.5` on the seed returns both seeded articles. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?limit=1.5` on the seed returns both seeded articles. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?offset=abc` on the seed returns both seeded articles. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?offset=abc` on the seed returns both seeded articles. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?offset=-1` on the seed returns both seeded articles. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?offset=-1` on the seed returns both seeded articles. | `article.author` | state | value:jake | spec:store-and-seed |
| With 22 stored articles, `GET /api/articles` with no `limit` returns 20 articles. | `article.author` | state | value:jane | spec:store-and-seed |
| With 22 stored articles, `GET /api/articles` with no `limit` returns 20 articles. | `article.author` | state | value:jake | spec:store-and-seed |
| With 22 stored articles, `GET /api/articles` with no `limit` returns `articlesCount` 22. | `article.author` | state | value:jane | spec:store-and-seed |
| With 22 stored articles, `GET /api/articles` with no `limit` returns `articlesCount` 22. | `article.author` | state | value:jake | spec:store-and-seed |
| With 22 stored articles, `GET /api/articles?limit=100` returns 22 articles. | `article.author` | state | value:jane | spec:store-and-seed |
| With 22 stored articles, `GET /api/articles?limit=100` returns 22 articles. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?author=jake` on the seed returns only `how-to-train-your-dragon` with `articlesCount` 1. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?author=jane` on the seed returns only `welcome-to-conduit` with `articlesCount` 1. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?author=Jake` on the seed returns 200 with body `{"articles":[],"articlesCount":0}`. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?author=Jake` on the seed returns 200 with body `{"articles":[],"articlesCount":0}`. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?author=nobody` on the seed returns 200 with body `{"articles":[],"articlesCount":0}`. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?author=nobody` on the seed returns 200 with body `{"articles":[],"articlesCount":0}`. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?author=` on the seed returns both seeded articles. | `article.author` | state | value:jane | spec:store-and-seed |
| `GET /api/articles?author=` on the seed returns both seeded articles. | `article.author` | state | value:jake | spec:store-and-seed |
| `GET /api/articles?author=jake&limit=0` on the seed returns an empty `articles` array with `articlesCount` 1. | `article.author` | state | value:jake | spec:store-and-seed |
