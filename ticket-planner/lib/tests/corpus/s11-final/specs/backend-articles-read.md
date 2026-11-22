# backend-articles-read

## Title

Anyone can list articles and read one article through the API

## Description

## Summary

Add the two public article endpoints, read one article (`GET /api/articles/:slug`) and list articles (`GET /api/articles?limit=&offset=&author=`), and seed the two articles from the brief on every server start.

## Outcome

**Serves:** O3

**Who:** Anonymous reader

**Need:** Read articles without an account.

**Outcome:** An anonymous reader sees the published articles on the home page, newest first, and can open any of them.

## Background / Motivation

The home page and the article page need an API that returns articles to anyone, signed in or not. The brief fixes the article shape, the list envelope, the paging defaults, the newest-first order and the 404 body. It also fixes two seed articles with set `createdAt` values, so the order is predictable.

## Proposed Behaviour

**Read one.** `GET /api/articles/:slug` returns 200 with `{"article":{"slug","title","description","body","createdAt","updatedAt","author":{"username","bio","image"}}}`. No token is needed. An unknown slug returns 404 `{"errors":{"article":["not found"]}}`.

**List.** `GET /api/articles` returns 200 with `{"articles":[...],"articlesCount":N}`. No token is needed. Each item has the same shape as the single article.

- Articles are ordered newest first by `createdAt`.
- `limit` defaults to 20 and `offset` to 0.
- `articlesCount` is the number of matching articles before paging.
- `author=<username>` keeps only that author's articles. An unknown author returns 200 `{"articles":[],"articlesCount":0}`.
- A `limit` or `offset` that is not a whole number, or is negative, is ignored and the default is used. No error is returned.

**Seed.** Every server start, and every store reset, loads two articles, both with description `Seed article` and body `Seed body text.`:

| Slug | Title | Author | createdAt |
|---|---|---|---|
| `how-to-train-your-dragon` | How to train your dragon | jake | 2026-01-01T10:00:00.000Z |
| `welcome-to-conduit` | Welcome to Conduit | jane | 2026-01-02T10:00:00.000Z |

Each seed article's `updatedAt` equals its `createdAt`.

## Technical Context

- Repository `app`, folder `backend/`. Builds on `app.js`, `store.js` and `errors.js` from `backend-scaffold`, and on the seed users `jake` and `jane` from `backend-auth`.
- Store: each article record is `{slug, title, description, body, createdAt, updatedAt, authorId}`, with `authorId` the user's `id`. Push the two seed articles into `store.seedArticles`, looking up `authorId` from the seed users by username. Each seed article's `updatedAt` equals its `createdAt` (parameter `articles.seed_updated_at`).
- `backend/serializers.js` (created by `backend-auth`): add `toArticleJSON(article, store)` returning exactly `{slug, title, description, body, createdAt, updatedAt, author: {username, bio, image}}`, with `author` built from the user record.
- `backend/routes/articles.js`: mounts `GET /api/articles/:slug` and `GET /api/articles` on the `/api` router. No `requireAuth` on either.
- List: filter by `author` (exact username match) first, count, sort by `createdAt` descending (ISO strings compare correctly), then slice with `offset` and `limit`. Parse each with `Number`; keep it only if `Number.isInteger(n) && n >= 0`, else use the default (parameters `articles.list_default_limit` = 20, `articles.list_default_offset` = 0, `articles.invalid_paging`). An unknown author gives an empty list (parameter `articles.unknown_author`).
- 404 body through `errorBody({article: ['not found']})`.
- Tests: `backend/tests/articles-read.test.js`, supertest, `store.reset()` in `beforeEach`.

## Acceptance Criteria

- [ ] `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns status 200.
- [ ] The response for `how-to-train-your-dragon` has `article.slug` equal to `how-to-train-your-dragon`.
- [ ] The response for `how-to-train-your-dragon` has `article.title` equal to `How to train your dragon`.
- [ ] The response for `how-to-train-your-dragon` has `article.description` equal to `Seed article`.
- [ ] The response for `how-to-train-your-dragon` has `article.body` equal to `Seed body text.`.
- [ ] The response for `how-to-train-your-dragon` has `article.createdAt` equal to `2026-01-01T10:00:00.000Z`.
- [ ] The response for `how-to-train-your-dragon` has `article.updatedAt` equal to `2026-01-01T10:00:00.000Z`.
- [ ] The response for `how-to-train-your-dragon` has `article.author.username` equal to `jake`.
- [ ] The response for `how-to-train-your-dragon` has `article.author.bio` equal to null.
- [ ] The response for `how-to-train-your-dragon` has `article.author.image` equal to null.
- [ ] The response for `how-to-train-your-dragon` has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author` under `article`.
- [ ] `GET /api/articles/no-such-article` returns status 404 with body `{"errors":{"article":["not found"]}}`.
- [ ] `GET /api/articles` with no query and no `Authorization` header returns status 200.
- [ ] `GET /api/articles` with no query returns `articlesCount` equal to 2.
- [ ] `GET /api/articles` with no query returns `articles[0].slug` equal to `welcome-to-conduit`.
- [ ] `GET /api/articles` with no query returns `articles[1].slug` equal to `how-to-train-your-dragon`.
- [ ] Every item in the `GET /api/articles` response has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author`.
- [ ] `GET /api/articles?limit=1` returns an `articles` array of length 1.
- [ ] `GET /api/articles?limit=1` returns `articlesCount` equal to 2.
- [ ] `GET /api/articles?offset=1` returns `articles[0].slug` equal to `how-to-train-your-dragon`.
- [ ] `GET /api/articles?author=jake` returns `articlesCount` equal to 1.
- [ ] `GET /api/articles?author=jake` returns `articles[0].slug` equal to `how-to-train-your-dragon`.
- [ ] `GET /api/articles?author=nobody` returns status 200 with body `{"articles":[],"articlesCount":0}`.
- [ ] `GET /api/articles?limit=abc` returns an `articles` array of length 2.
- [ ] `GET /api/articles?limit=-1` returns an `articles` array of length 2.
- [ ] `GET /api/articles?offset=abc` returns `articles[0].slug` equal to `welcome-to-conduit`.
- [ ] `GET /api/articles?offset=-5` returns `articles[0].slug` equal to `welcome-to-conduit`.

## Out of Scope

- Creating articles (`backend-articles-publish`).
- Tags, favorites, comments, the feed, article edit and delete.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/routes/articles.js` (read and list), `toArticleJSON` in `backend/serializers.js`, article seed in `backend/store.js`, `backend/tests/articles-read.test.js` |

## Test User

Anonymous reader: no account and no password. The endpoints need no token.

## Navigation Path

No UI: exercise the endpoints with `npm test` in `backend/`, or with an HTTP client against `npm start` in `backend/`.

## Test Data Provided

- 2 `article` records in state published, loaded on every server start and every `store.reset()`: `how-to-train-your-dragon` ("How to train your dragon", author `jake`, createdAt `2026-01-01T10:00:00.000Z`) and `welcome-to-conduit` ("Welcome to Conduit", author `jane`, createdAt `2026-01-02T10:00:00.000Z`), both with description `Seed article` and body `Seed body text.`, `updatedAt` equal to `createdAt`.

## Labels

planned, INIT-0000000000-5252, feature, blocked-by:backend-scaffold, blocked-by:backend-auth

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Add public read and list article routes on the Express app over the in-memory store, with seeded articles, newest-first ordering and default paging.",
  "AffectedServices": "app",
  "TargetSymbols": "articles (new):app/backend/routes/articles.js;toArticleJSON (new in backend-auth):app/backend/serializers.js;store (new in backend-scaffold):app/backend/store.js;articlesReadTest (new):app/backend/tests/articles-read.test.js",
  "Kind": "business",
  "Serves": ["O3"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns status 200. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`, author `jake`) | seeded-by:backend-articles-read | | status 200 | yes |
| The response for `how-to-train-your-dragon` has `article.slug` equal to `how-to-train-your-dragon`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | | `how-to-train-your-dragon` | yes |
| The response for `how-to-train-your-dragon` has `article.title` equal to `How to train your dragon`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | | `How to train your dragon` | yes |
| The response for `how-to-train-your-dragon` has `article.description` equal to `Seed article`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | | `Seed article` | yes |
| The response for `how-to-train-your-dragon` has `article.body` equal to `Seed body text.`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | | `Seed body text.` | yes |
| The response for `how-to-train-your-dragon` has `article.createdAt` equal to `2026-01-01T10:00:00.000Z`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | | `2026-01-01T10:00:00.000Z` | yes |
| The response for `how-to-train-your-dragon` has `article.updatedAt` equal to `2026-01-01T10:00:00.000Z`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | | `2026-01-01T10:00:00.000Z` | yes |
| The response for `how-to-train-your-dragon` has `article.author.username` equal to `jake`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`); 1 `user` in state registered (`jake`) | seeded-by:backend-articles-read | | `jake` | yes |
| The response for `how-to-train-your-dragon` has `article.author.bio` equal to null. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`); 1 `user` in state registered (`jake`) | seeded-by:backend-articles-read | | null | yes |
| The response for `how-to-train-your-dragon` has `article.author.image` equal to null. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`); 1 `user` in state registered (`jake`) | seeded-by:backend-articles-read | | null | yes |
| The response for `how-to-train-your-dragon` has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author` under `article`. | anonymous reader | 1 `article` in state published (`how-to-train-your-dragon`) | seeded-by:backend-articles-read | | key set equals the seven listed keys | yes |
| `GET /api/articles/no-such-article` returns status 404 with body `{"errors":{"article":["not found"]}}`. | anonymous reader | none | — | | 404, `{"errors":{"article":["not found"]}}` | yes |
| `GET /api/articles` with no query and no `Authorization` header returns status 200. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | status 200 | yes |
| `GET /api/articles` with no query returns `articlesCount` equal to 2. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | 2 | yes |
| `GET /api/articles` with no query returns `articles[0].slug` equal to `welcome-to-conduit`. | anonymous reader | 2 `article` records in state published (seed, distinct `createdAt`) | seeded-by:backend-articles-read | | `welcome-to-conduit` | yes |
| `GET /api/articles` with no query returns `articles[1].slug` equal to `how-to-train-your-dragon`. | anonymous reader | 2 `article` records in state published (seed, distinct `createdAt`) | seeded-by:backend-articles-read | | `how-to-train-your-dragon` | yes |
| Every item in the `GET /api/articles` response has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author`. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | each item's key set equals the seven listed keys | yes |
| `GET /api/articles?limit=1` returns an `articles` array of length 1. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | length 1 | yes |
| `GET /api/articles?limit=1` returns `articlesCount` equal to 2. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | 2 | yes |
| `GET /api/articles?offset=1` returns `articles[0].slug` equal to `how-to-train-your-dragon`. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | `how-to-train-your-dragon` | yes |
| `GET /api/articles?author=jake` returns `articlesCount` equal to 1. | anonymous reader | 2 `article` records in state published (seed, one by `jake`, one by `jane`) | seeded-by:backend-articles-read | | 1 | yes |
| `GET /api/articles?author=jake` returns `articles[0].slug` equal to `how-to-train-your-dragon`. | anonymous reader | 2 `article` records in state published (seed, one by `jake`, one by `jane`) | seeded-by:backend-articles-read | | `how-to-train-your-dragon` | yes |
| `GET /api/articles?author=nobody` returns status 200 with body `{"articles":[],"articlesCount":0}`. | anonymous reader | 2 `article` records in state published (seed, none by `nobody`) | seeded-by:backend-articles-read | | 200, `{"articles":[],"articlesCount":0}` | yes |
| `GET /api/articles?limit=abc` returns an `articles` array of length 2. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | length 2 | yes |
| `GET /api/articles?limit=-1` returns an `articles` array of length 2. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | length 2 | yes |
| `GET /api/articles?offset=abc` returns `articles[0].slug` equal to `welcome-to-conduit`. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | `welcome-to-conduit` | yes |
| `GET /api/articles?offset=-5` returns `articles[0].slug` equal to `welcome-to-conduit`. | anonymous reader | 2 `article` records in state published (seed) | seeded-by:backend-articles-read | | `welcome-to-conduit` | yes |

## Writes

| Key | Op |
|-----|----|
| `article` | create |

## Reads

| Key | Source |
|-----|--------|
| `user.username` | spec |
| `user.bio` | spec |
| `user.image` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns status 200. | `article.author` | state | value:jake | spec:backend-articles-read |
| The response for `how-to-train-your-dragon` has `article.author.username` equal to `jake`. | `user.username` | state | value:jake | spec:backend-auth |
| `GET /api/articles?author=jake` returns `articlesCount` equal to 1. | `article.author` | state | value:jake | spec:backend-articles-read |
| `GET /api/articles` with no query returns `articles[0].slug` equal to `welcome-to-conduit`. | `article.author` | state | value:jane | spec:backend-articles-read |
