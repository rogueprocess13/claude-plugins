# api-article-reads

## Title

Anyone can list and read articles through the API

## Description

## Summary

Add the two public article endpoints: a newest-first list with paging and an author filter, and a single article looked up by its slug. Neither needs a sign-in.

## Outcome

**Serves:** O3

**Who:** Anonymous reader

**Need:** Read articles without an account.

**Outcome:** Anyone can see a newest-first list of articles and open any one of them.

## Background / Motivation

Readers need to see what has been published and open a single article. The home page and the article page of the frontend are built on these two endpoints, and the brief requires `npm test` in `backend/` to cover every endpoint, including each error case.

## Proposed Behaviour

- Listing articles returns status 200 and `{"articles":[...],"articlesCount":N}`, newest first by `createdAt`.
- Each listed article has `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`, where `author` is `{"username","bio","image"}`.
- `limit` defaults to 20 and `offset` defaults to 0. `articlesCount` is the total number of matching articles before paging.
- A `limit` or `offset` that is missing, not an integer, or negative falls back to its default. A `limit` of 0 returns an empty `articles` array with the full `articlesCount`.
- `author=<username>` keeps only that author's articles, matched exactly. An author with no articles, or a username nobody has, gives `{"articles":[],"articlesCount":0}`.
- Two articles with the same `createdAt` are ordered with the one added later first.
- Reading one article by slug returns status 200 and `{"article":{...}}` in the same article shape.
- An unknown slug returns status 404 and `{"errors":{"article":["not found"]}}`.
- No response contains a password or password hash.

## Technical Context

- Builds on `backend-foundation`: `createApp()` in `backend/src/app.js`, the store with `reset()` and `insertArticle()` in `backend/src/store.js`, the seed in `backend/src/seed.js`, and the error helper `sendError` in `backend/src/errors.js`.
- Add `backend/src/routes/articles.js` with `GET /api/articles` and `GET /api/articles/:slug`, and mount it in `createApp()`. The create endpoint is added to the same router by a later ticket. `api-user-auth` also adds one mount line to `createApp()` in parallel, so whichever branch merges second resolves a small conflict there by keeping both mount lines.
- Add a `toArticle(article)` serializer that builds the response shape and resolves `author` through a `toProfile(user)` serializer returning only `username`, `bio` and `image`. These two are the only way an article reaches a response.
- Paging: parse `limit` and `offset` as base-10 integers. A missing, non-integer or negative value falls back to the default (`articles.list.invalid_paging`). Defaults are `limit` 20 (`articles.list.default_limit`) and `offset` 0 (`articles.list.default_offset`). No upper cap on `limit`.
- Ordering: sort by `createdAt` descending; on a tie, the record with the higher store `id` comes first (`articles.list.tie_break`). The `author` filter is an exact username match (`articles.list.author_match`).
- Store records use the fields set up by `backend-foundation`; the response's `createdAt` and `updatedAt` come from the record's timestamps and `author` from the user whose `id` matches the article's author id.
- Tests: `backend/test/articles-read.test.js`, using supertest against `createApp()` with `store.reset()` in `beforeEach`. Tests that need more articles than the seed add them with `store.insertArticle()`, so their ids follow the seed's.

## Acceptance Criteria

- [ ] A list request with no query parameters, against the 2 seeded `article` records, returns status 200
- [ ] A list request with no query parameters returns `articlesCount` 2
- [ ] A list request with no query parameters returns `welcome-to-conduit` as the first article
- [ ] A list request with no query parameters returns `how-to-train-your-dragon` as the second article
- [ ] Each article in the list response has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author`
- [ ] The `author` of `welcome-to-conduit` in the list response is `{"username":"jane","bio":null,"image":null}`
- [ ] With 25 `article` records in the store, a list request with no `limit` returns 20 articles
- [ ] With 25 `article` records in the store, a list request with no `limit` returns `articlesCount` 25
- [ ] A list request with `limit=1` returns only `welcome-to-conduit`, with `articlesCount` 2
- [ ] A list request with `offset=1` returns only `how-to-train-your-dragon`, with `articlesCount` 2
- [ ] A list request with `limit=0` returns an empty `articles` array, with `articlesCount` 2
- [ ] A list request with `limit=abc` returns both seeded articles
- [ ] A list request with `limit=-1` returns both seeded articles
- [ ] A list request with `offset=abc` returns `welcome-to-conduit` as the first article
- [ ] A list request with `offset=-1` returns `welcome-to-conduit` as the first article
- [ ] A list request with `author=jake` returns only `how-to-train-your-dragon`, with `articlesCount` 1
- [ ] A list request with `author=Jake` returns `{"articles":[],"articlesCount":0}`
- [ ] A list request with `author=nobody` returns `{"articles":[],"articlesCount":0}`
- [ ] Given 2 `article` records with the same `createdAt`, the list shows the one added later first
- [ ] A request for the article `welcome-to-conduit` returns status 200
- [ ] A request for the article `welcome-to-conduit` returns `title` "Welcome to Conduit"
- [ ] A request for the article `welcome-to-conduit` returns `description` "Seed article"
- [ ] A request for the article `welcome-to-conduit` returns `body` "Seed body text."
- [ ] A request for the article `welcome-to-conduit` returns `createdAt` "2026-01-02T10:00:00.000Z"
- [ ] A request for the article `welcome-to-conduit` returns `author` `{"username":"jane","bio":null,"image":null}`
- [ ] A request for the article `no-such-article` returns status 404
- [ ] A request for the article `no-such-article` returns the body `{"errors":{"article":["not found"]}}`
- [ ] No list response contains the text `password`
- [ ] No single-article response contains the text `password`
- [ ] `npm test` in `backend/` runs the article read tests and exits with code 0
- [ ] A list request with `limit=1.5` returns both seeded articles
- [ ] A list request with `limit=1abc` returns both seeded articles
- [ ] A list request with `offset=1abc` returns `welcome-to-conduit` as the first article

## Test User

- Anonymous reader: no credentials. No `Authorization` header is sent.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Backend | app | `GET /api/articles`, `GET /api/articles/:slug`, article and author serializers, article read tests |

## Navigation Path

No page in the app. Start the API with `npm start` in `backend/`, then send the requests from an HTTP client to port 3000, or run `npm test` in `backend/`.

## Labels

planned, INIT-0000000000-9899, feature, blocked-by:backend-foundation

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 5,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Add a public articles router with a newest-first paged list and a by-slug lookup, using one article serializer and one author serializer.",
  "AffectedServices": "app",
  "TargetSymbols": "articlesRouter (new):app/backend/src/routes/articles.js;toArticle (new):app/backend/src/routes/articles.js;createApp (new in backend-foundation):app/backend/src/app.js;reset (new in backend-foundation):app/backend/src/store.js;insertArticle (new in backend-foundation):app/backend/src/store.js",
  "Kind": "business",
  "Serves": ["O3"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| A list request with no query parameters, against the 2 seeded `article` records, returns status 200 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | status 200 | yes |
| A list request with no query parameters returns `articlesCount` 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articlesCount` 2 | yes |
| A list request with no query parameters returns `welcome-to-conduit` as the first article | anonymous reader | 2 seeded `article` records (welcome-to-conduit is newer) | seeded-by:backend-foundation | | `articles[0].slug` is `welcome-to-conduit` | yes |
| A list request with no query parameters returns `how-to-train-your-dragon` as the second article | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles[1].slug` is `how-to-train-your-dragon` | yes |
| Each article in the list response has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt` and `author` | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | key set equals `slug, title, description, body, createdAt, updatedAt, author` | yes |
| The `author` of `welcome-to-conduit` in the list response is `{"username":"jane","bio":null,"image":null}` | anonymous reader | seeded `article` welcome-to-conduit by seeded `user` jane | seeded-by:backend-foundation | | `{"username":"jane","bio":null,"image":null}` | yes |
| With 25 `article` records in the store, a list request with no `limit` returns 20 articles | anonymous reader | 25 `article` records (2 seeded plus 23 added by the test) | seeded-by:api-article-reads | | `articles` length 20 | yes |
| With 25 `article` records in the store, a list request with no `limit` returns `articlesCount` 25 | anonymous reader | 25 `article` records (2 seeded plus 23 added by the test) | seeded-by:api-article-reads | | `articlesCount` 25 | yes |
| A list request with `limit=1` returns only `welcome-to-conduit`, with `articlesCount` 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | 1 article, slug `welcome-to-conduit`; `articlesCount` 2 | yes |
| A list request with `offset=1` returns only `how-to-train-your-dragon`, with `articlesCount` 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | 1 article, slug `how-to-train-your-dragon`; `articlesCount` 2 | yes |
| A list request with `limit=0` returns an empty `articles` array, with `articlesCount` 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles` is `[]`; `articlesCount` 2 | yes |
| A list request with `limit=abc` returns both seeded articles | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles` length 2 | yes |
| A list request with `limit=-1` returns both seeded articles | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles` length 2 | yes |
| A list request with `offset=abc` returns `welcome-to-conduit` as the first article | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles[0].slug` is `welcome-to-conduit` | yes |
| A list request with `offset=-1` returns `welcome-to-conduit` as the first article | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles[0].slug` is `welcome-to-conduit` | yes |
| A list request with `author=jake` returns only `how-to-train-your-dragon`, with `articlesCount` 1 | anonymous reader | seeded `user` jake with 1 seeded `article` | seeded-by:backend-foundation | | 1 article, slug `how-to-train-your-dragon`; `articlesCount` 1 | yes |
| A list request with `author=Jake` returns `{"articles":[],"articlesCount":0}` | anonymous reader | seeded `user` jake (lower-case username) | seeded-by:backend-foundation | | `{"articles":[],"articlesCount":0}` | yes |
| A list request with `author=nobody` returns `{"articles":[],"articlesCount":0}` | anonymous reader | 2 seeded `user` records, none named nobody | seeded-by:backend-foundation | | `{"articles":[],"articlesCount":0}` | yes |
| Given 2 `article` records with the same `createdAt`, the list shows the one added later first | anonymous reader | 2 `article` records with equal `createdAt`, added by the test in a known order | seeded-by:api-article-reads | | the later-added slug is listed before the earlier one | yes |
| A request for the article `welcome-to-conduit` returns status 200 | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | | status 200 | yes |
| A request for the article `welcome-to-conduit` returns `title` "Welcome to Conduit" | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | | `title` "Welcome to Conduit" | yes |
| A request for the article `welcome-to-conduit` returns `description` "Seed article" | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | | `description` "Seed article" | yes |
| A request for the article `welcome-to-conduit` returns `body` "Seed body text." | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | | `body` "Seed body text." | yes |
| A request for the article `welcome-to-conduit` returns `createdAt` "2026-01-02T10:00:00.000Z" | anonymous reader | seeded `article` welcome-to-conduit | seeded-by:backend-foundation | | `createdAt` "2026-01-02T10:00:00.000Z" | yes |
| A request for the article `welcome-to-conduit` returns `author` `{"username":"jane","bio":null,"image":null}` | anonymous reader | seeded `article` welcome-to-conduit by seeded `user` jane | seeded-by:backend-foundation | | `{"username":"jane","bio":null,"image":null}` | yes |
| A request for the article `no-such-article` returns status 404 | anonymous reader | none | — | | status 404 | yes |
| A request for the article `no-such-article` returns the body `{"errors":{"article":["not found"]}}` | anonymous reader | none | — | | `{"errors":{"article":["not found"]}}` | yes |
| No list response contains the text `password` | anonymous reader | 2 seeded `article` records by seeded `user` records jake and jane | seeded-by:backend-foundation | | `password` absent from the response body | yes |
| No single-article response contains the text `password` | anonymous reader | seeded `article` welcome-to-conduit by seeded `user` jane | seeded-by:backend-foundation | | `password` absent from the response body | yes |
| `npm test` in `backend/` runs the article read tests and exits with code 0 | developer | none | — | terminal in `backend/` | exit code 0 with `articles-read.test.js` listed | yes |
| A list request with `limit=1.5` returns both seeded articles | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles` length 2 | yes |
| A list request with `limit=1abc` returns both seeded articles | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles` length 2 | yes |
| A list request with `offset=1abc` returns `welcome-to-conduit` as the first article | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articles[0].slug` is `welcome-to-conduit` | yes |

## Test Data Provided

- Test-only `article` records that `backend/test/articles-read.test.js` adds to the store after `store.reset()`: 23 extra articles (25 in total with the seed) for the default-limit check, and 2 articles with the same `createdAt` added in a known order for the tie-break check.

## Writes

None.

## Reads

| Key | Source |
|-----|--------|
| `article.id` | spec |
| `article.slug` | spec |
| `article.title` | spec |
| `article.description` | spec |
| `article.body` | spec |
| `article.created_at` | spec |
| `article.updated_at` | spec |
| `article.author_id` | spec |
| `user.id` | spec |
| `user.username` | spec |
| `user.bio` | spec |
| `user.image` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| A list request with `author=jake` returns only `how-to-train-your-dragon`, with `articlesCount` 1 | `user.username` | state | value:jake | spec:backend-foundation |
| A request for the article `welcome-to-conduit` returns `author` `{"username":"jane","bio":null,"image":null}` | `user.bio` | state | null | spec:backend-foundation |
| A request for the article `welcome-to-conduit` returns `author` `{"username":"jane","bio":null,"image":null}` | `user.image` | state | null | spec:backend-foundation |
