# articles-api

## Title

Authors can publish articles and anyone can read and list them through the API

## Description

## Summary

Add the three article endpoints: create (`POST /api/articles`, signed-in authors only), read one (`GET /api/articles/:slug`, anyone) and list (`GET /api/articles`, anyone, with `limit`, `offset` and `author`). Each article gets a readable slug made from its title. This ticket also adds the backend tests for every success and error case.

## Outcome

**Serves:** O1, O3

**Who:** Anonymous reader; Author

**Need:** Read articles without an account; publish articles.

**Outcome:** An anonymous reader can see and open the published articles, newest first, and a signed-in author can publish a new article.

## Background / Motivation

Readers need the list and the single-article view, and authors need a way to publish. The brief fixes the request and response shapes, the slug rule, the paging defaults and order, and the error bodies. Behaviour the brief leaves open (bad paging values, an unknown author filter, a title with no letters or digits) follows the decided parameters below.

## Proposed Behaviour

**Create**: `POST /api/articles` with header `Authorization: Token <jwt>` and `{"article":{"title","description","body"}}`:

- A valid request returns 201 and `{"article":{"slug","title","description","body","createdAt","updatedAt","author":{"username","bio","image"}}}`. `author` is the signed-in user. `createdAt` and `updatedAt` are the same ISO 8601 time. The `author` object never contains a `password` field.
- The slug is the title in lower case, with every run of characters that are not ASCII letters or digits (`a` to `z` and `0` to `9` after lower-casing) replaced by `-`, and any leading or trailing `-` removed. Accented and non-Latin letters count as non-alphanumeric, so `Café` becomes `caf`.
- If that slug is already used by any stored article, seeded ones included, the first free one of `<slug>-2`, `<slug>-3` and so on is used.
- A title that is not blank but has no ASCII letters or digits returns 422 `{"errors":{"title":["is invalid"]}}`.
- Every blank field (missing, not a string, or empty after trimming) is reported in one 422 response, `{"errors":{"<field>":["can't be blank"]}}`.
- A missing or bad token returns 401 `{"errors":{"token":["is missing or invalid"]}}`, using the token check from the account endpoints.

**Read one**: `GET /api/articles/:slug`:

- A known slug returns 200 and `{"article":{...}}` in the same shape as create.
- An unknown slug returns 404 `{"errors":{"article":["not found"]}}`.

**List**: `GET /api/articles?limit=&offset=&author=`:

- Returns 200 and `{"articles":[...],"articlesCount":N}`. Each entry has the same shape as a single article.
- Articles are ordered newest first by `createdAt`. Articles with the same `createdAt` are listed with the later-inserted one first.
- `limit` defaults to 20 and `offset` to 0. `articlesCount` is the number of matching articles before paging.
- A non-numeric or negative `limit` or `offset` uses its default.
- `limit=0` returns an empty `articles` list with the real `articlesCount`.
- `author` keeps only that user's articles. A username with no articles, or no account, returns 200 with `{"articles":[],"articlesCount":0}`.

## Technical Context

- Repository `app`, folder `backend/`, built on the app factory, store and seed from `backend-foundation` and on `requireAuth` and `profileJson` from `user-auth-api`.
- Parameters: `articles.slug_collision` (append -2, -3 and so on), `articles.empty_slug_title` (422 with title "is invalid"), `articles.default_limit` (20), `articles.default_offset` (0), `articles.invalid_paging` (a non-numeric or negative limit or offset uses its default), `articles.zero_limit` (limit=0 returns an empty articles list with the real articlesCount), `articles.unknown_author` (status 200 with an empty list and articlesCount 0), `articles.tie_order` (the later-inserted article first), `articles.collision_scope` (every stored slug, seeded ones included), `articles.slug_charset` (ASCII letters a to z and digits 0 to 9 after lower-casing), `validation.blank`.
- New files:
  - `backend/src/slug.js`: `slugify(title)` (`title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')`) and `uniqueSlug(base, exists)` trying `base`, `base-2`, `base-3`, … until `exists` is false.
  - `backend/src/routes/articles.js`: the three routes; the list route is registered so that `GET /api/articles` never reaches the `:slug` handler.
  - `articleJson(article, author)` added to `backend/src/serializers.js`, embedding `profileJson(author)`.
  - `backend/test/articles.test.js`, `backend/test/slug.test.js`: one test per acceptance criterion below, using `freshApp()`.
- `limit`/`offset` are parsed with `Number.parseInt(value, 10)`; `NaN` or a negative result uses the default. Sort is by `createdAt` descending, and articles with equal `createdAt` keep reverse insertion order (the later insert first). New articles take `new Date().toISOString()` for both timestamps, so they sort before the January 2026 seeds.

## Acceptance Criteria

- [ ] `POST /api/articles` as jake with title `My first post`, description `About me` and body `Hello world` returns status 201
- [ ] The create response for `My first post` has `article.slug` equal to `my-first-post`
- [ ] The create response for `My first post` has `article.title` equal to `My first post`
- [ ] The create response for `My first post` has `article.description` equal to `About me`
- [ ] The create response for `My first post` has `article.body` equal to `Hello world`
- [ ] The create response for `My first post` has `article.author.username` equal to `jake`
- [ ] The create response for `My first post` has `article.author.bio` equal to `null`
- [ ] The create response for `My first post` has `article.author.image` equal to `null`
- [ ] The create response for `My first post` has `article.createdAt` equal to `article.updatedAt`
- [ ] The create response for `My first post` has an `article.createdAt` that parses as an ISO 8601 date
- [ ] The create response for `My first post` contains no `password` key anywhere in the body
- [ ] `POST /api/articles` as jake with title `"  Hello, World!! 2026  "` returns `article.slug` equal to `hello-world-2026`
- [ ] `POST /api/articles` as jake with title `How to train your dragon` returns `article.slug` equal to `how-to-train-your-dragon-2`
- [ ] A second `POST /api/articles` as jake with title `How to train your dragon` returns `article.slug` equal to `how-to-train-your-dragon-3`
- [ ] `POST /api/articles` as jake with title `!!!` returns status 422 with body `{"errors":{"title":["is invalid"]}}`
- [ ] `POST /api/articles` as jake with title `Café` returns `article.slug` equal to `caf`
- [ ] `POST /api/articles` as jake with title `日本語` returns status 422 with body `{"errors":{"title":["is invalid"]}}`
- [ ] `POST /api/articles` as jake with body `{"article":{}}` returns status 422 with body `{"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}}`
- [ ] `POST /api/articles` as jake with an empty title returns status 422 with body `{"errors":{"title":["can't be blank"]}}`
- [ ] `POST /api/articles` as jake with an empty description returns status 422 with body `{"errors":{"description":["can't be blank"]}}`
- [ ] `POST /api/articles` as jake with an empty body field returns status 422 with body `{"errors":{"body":["can't be blank"]}}`
- [ ] `POST /api/articles` with no `Authorization` header returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `POST /api/articles` with header `Authorization: Token not-a-jwt` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/articles/how-to-train-your-dragon` returns status 200
- [ ] `GET /api/articles/how-to-train-your-dragon` returns `article.title` equal to `How to train your dragon`
- [ ] `GET /api/articles/how-to-train-your-dragon` returns `article.author.username` equal to `jake`
- [ ] `GET /api/articles/how-to-train-your-dragon` returns `article.description` equal to `Seed article`
- [ ] `GET /api/articles/how-to-train-your-dragon` returns `article.body` equal to `Seed body text.`
- [ ] `GET /api/articles/how-to-train-your-dragon` returns `article.createdAt` equal to `2026-01-01T10:00:00.000Z`
- [ ] After jake creates `My first post`, `GET /api/articles/my-first-post` returns status 200 with `article.title` equal to `My first post`
- [ ] `GET /api/articles/no-such-article` returns status 404 with body `{"errors":{"article":["not found"]}}`
- [ ] `GET /api/articles` returns status 200 with `articlesCount` equal to 2
- [ ] `GET /api/articles` returns `welcome-to-conduit` as the first entry of `articles`
- [ ] `GET /api/articles` returns `how-to-train-your-dragon` as the second entry of `articles`
- [ ] `GET /api/articles` returns entries that each have the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author`
- [ ] After jake creates `My first post`, `GET /api/articles` returns `my-first-post` as the first entry with `articlesCount` equal to 3
- [ ] `GET /api/articles?limit=1` returns 1 entry with `articlesCount` equal to 2
- [ ] `GET /api/articles?offset=1` returns `how-to-train-your-dragon` as the only entry with `articlesCount` equal to 2
- [ ] `GET /api/articles?limit=abc` returns 2 entries
- [ ] `GET /api/articles?limit=-1` returns 2 entries
- [ ] `GET /api/articles?offset=-5` returns `welcome-to-conduit` as the first entry
- [ ] `GET /api/articles?limit=0` returns an empty `articles` list with `articlesCount` equal to 2
- [ ] `GET /api/articles?author=jake` returns only `how-to-train-your-dragon` with `articlesCount` equal to 1
- [ ] `GET /api/articles?author=nobody` returns status 200 with body `{"articles":[],"articlesCount":0}`
- [ ] `npm test` in `backend/` reports a passing list-order test in which two articles stored with the same `createdAt` are listed with the later-inserted one first
- [ ] `npm test` in `backend/` exits with code 0 with the article and slug tests included
- [ ] `POST /api/articles` as a signed-in author with the JSON body `{}` (no `article` wrapper) returns status 422 with body `{"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}}`
- [ ] `POST /api/articles` as a signed-in author with title `"   "` (spaces only), description `About me` and body `Hello world` returns status 422 with body `{"errors":{"title":["can't be blank"]}}`
- [ ] `POST /api/articles` as a signed-in author with title `123` sent as a JSON number, description `About me` and body `Hello world` returns status 422 with body `{"errors":{"title":["can't be blank"]}}`

## Out of Scope

Article edit and delete, tags, comments, favorites, the feed, profiles, and any frontend page.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/src/slug.js`, `backend/src/routes/articles.js`, `articleJson` in `backend/src/serializers.js`, article and slug tests |

## Test User

`jake@conduit.test` — password `Jake-Pass-123`

## Environment

- [x] Local (`http://localhost:3000` for the API)

## Labels

planned, INIT-0000000000-5856, feature, blocked-by:backend-foundation, blocked-by:user-auth-api

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "Add create, read and list article routes with a slugify plus collision-suffix helper and newest-first paging over the in-memory store.",
  "AffectedServices": "app",
  "TargetSymbols": "slugify (new):app/backend/src/slug.js;articlesRouter (new):app/backend/src/routes/articles.js;requireAuth (new in user-auth-api):app/backend/src/auth.js;profileJson (new in user-auth-api):app/backend/src/serializers.js;createStore (new in backend-foundation):app/backend/src/store.js",
  "Kind": "business",
  "Serves": ["O1", "O3"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `POST /api/articles` as jake with title `My first post`, description `About me` and body `Hello world` returns status 201 | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 201 | yes |
| The create response for `My first post` has `article.slug` equal to `my-first-post` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `my-first-post` | yes |
| The create response for `My first post` has `article.title` equal to `My first post` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `My first post` | yes |
| The create response for `My first post` has `article.description` equal to `About me` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `About me` | yes |
| The create response for `My first post` has `article.body` equal to `Hello world` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `Hello world` | yes |
| The create response for `My first post` has `article.author.username` equal to `jake` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `jake` | yes |
| The create response for `My first post` has `article.author.bio` equal to `null` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `null` | yes |
| The create response for `My first post` has `article.author.image` equal to `null` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `null` | yes |
| The create response for `My first post` has `article.createdAt` equal to `article.updatedAt` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | the two strings are identical | yes |
| The create response for `My first post` has an `article.createdAt` that parses as an ISO 8601 date | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `new Date(createdAt).toISOString()` equals `createdAt` | yes |
| The create response for `My first post` contains no `password` key anywhere in the body | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | no key named `password` | yes |
| `POST /api/articles` as jake with title `"  Hello, World!! 2026  "` returns `article.slug` equal to `hello-world-2026` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `hello-world-2026` | yes |
| `POST /api/articles` as jake with title `How to train your dragon` returns `article.slug` equal to `how-to-train-your-dragon-2` | author | 1 `user` `jake`; 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | HTTP client | `how-to-train-your-dragon-2` | yes |
| A second `POST /api/articles` as jake with title `How to train your dragon` returns `article.slug` equal to `how-to-train-your-dragon-3` | author | 1 `user` `jake`; 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | HTTP client | `how-to-train-your-dragon-3` | yes |
| `POST /api/articles` as jake with title `!!!` returns status 422 with body `{"errors":{"title":["is invalid"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body | yes |
| `POST /api/articles` as jake with title `Café` returns `article.slug` equal to `caf` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | `caf` | yes |
| `POST /api/articles` as jake with title `日本語` returns status 422 with body `{"errors":{"title":["is invalid"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body | yes |
| `POST /api/articles` as jake with body `{"article":{}}` returns status 422 with body `{"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body | yes |
| `POST /api/articles` as jake with an empty title returns status 422 with body `{"errors":{"title":["can't be blank"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body | yes |
| `POST /api/articles` as jake with an empty description returns status 422 with body `{"errors":{"description":["can't be blank"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body | yes |
| `POST /api/articles` as jake with an empty body field returns status 422 with body `{"errors":{"body":["can't be blank"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body | yes |
| `POST /api/articles` with no `Authorization` header returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | HTTP client | status 401 with that exact body | yes |
| `POST /api/articles` with header `Authorization: Token not-a-jwt` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | HTTP client | status 401 with that exact body | yes |
| `GET /api/articles/how-to-train-your-dragon` returns status 200 | anonymous reader | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | HTTP client | status 200 | yes |
| `GET /api/articles/how-to-train-your-dragon` returns `article.title` equal to `How to train your dragon` | anonymous reader | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | HTTP client | `How to train your dragon` | yes |
| `GET /api/articles/how-to-train-your-dragon` returns `article.author.username` equal to `jake` | anonymous reader | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | HTTP client | `jake` | yes |
| `GET /api/articles/how-to-train-your-dragon` returns `article.description` equal to `Seed article` | anonymous reader | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | HTTP client | `Seed article` | yes |
| `GET /api/articles/how-to-train-your-dragon` returns `article.body` equal to `Seed body text.` | anonymous reader | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | HTTP client | `Seed body text.` | yes |
| `GET /api/articles/how-to-train-your-dragon` returns `article.createdAt` equal to `2026-01-01T10:00:00.000Z` | anonymous reader | 1 `article` `how-to-train-your-dragon` | seeded-by:backend-foundation | HTTP client | `2026-01-01T10:00:00.000Z` | yes |
| After jake creates `My first post`, `GET /api/articles/my-first-post` returns status 200 with `article.title` equal to `My first post` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 200, title `My first post` | yes |
| `GET /api/articles/no-such-article` returns status 404 with body `{"errors":{"article":["not found"]}}` | anonymous reader | none | — | HTTP client | status 404 with that exact body | yes |
| `GET /api/articles` returns status 200 with `articlesCount` equal to 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | status 200, `articlesCount` 2 | yes |
| `GET /api/articles` returns `welcome-to-conduit` as the first entry of `articles` | anonymous reader | 2 seeded `article` records with distinct `createdAt` | seeded-by:backend-foundation | HTTP client | `articles[0].slug` is `welcome-to-conduit` | yes |
| `GET /api/articles` returns `how-to-train-your-dragon` as the second entry of `articles` | anonymous reader | 2 seeded `article` records with distinct `createdAt` | seeded-by:backend-foundation | HTTP client | `articles[1].slug` is `how-to-train-your-dragon` | yes |
| `GET /api/articles` returns entries that each have the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author` | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | all seven keys present on both entries | yes |
| After jake creates `My first post`, `GET /api/articles` returns `my-first-post` as the first entry with `articlesCount` equal to 3 | author | 1 `user` `jake`; 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | `articles[0].slug` is `my-first-post`, `articlesCount` 3 | yes |
| `GET /api/articles?limit=1` returns 1 entry with `articlesCount` equal to 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | `articles.length` 1, `articlesCount` 2 | yes |
| `GET /api/articles?offset=1` returns `how-to-train-your-dragon` as the only entry with `articlesCount` equal to 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | one entry `how-to-train-your-dragon`, `articlesCount` 2 | yes |
| `GET /api/articles?limit=abc` returns 2 entries | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | `articles.length` 2 | yes |
| `GET /api/articles?limit=-1` returns 2 entries | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | `articles.length` 2 | yes |
| `GET /api/articles?offset=-5` returns `welcome-to-conduit` as the first entry | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | `articles[0].slug` is `welcome-to-conduit` | yes |
| `GET /api/articles?limit=0` returns an empty `articles` list with `articlesCount` equal to 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | `articles` is `[]`, `articlesCount` 2 | yes |
| `GET /api/articles?author=jake` returns only `how-to-train-your-dragon` with `articlesCount` equal to 1 | anonymous reader | 1 `user` `jake`; 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | one entry `how-to-train-your-dragon`, `articlesCount` 1 | yes |
| `GET /api/articles?author=nobody` returns status 200 with body `{"articles":[],"articlesCount":0}` | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | HTTP client | status 200 with that exact body | yes |
| `npm test` in `backend/` reports a passing list-order test in which two articles stored with the same `createdAt` are listed with the later-inserted one first | developer | none | — | terminal in `backend/` | list-order tie test reported as passing (the test itself stores the two articles with equal `createdAt` in a fresh store) | yes |
| `npm test` in `backend/` exits with code 0 with the article and slug tests included | developer | 2 seeded `user` records; 2 seeded `article` records | seeded-by:backend-foundation | terminal in `backend/` | exit code 0 | yes |
| `POST /api/articles` as a signed-in author with the JSON body `{}` (no `article` wrapper) returns status 422 with body `{"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body, not 500 | yes |
| `POST /api/articles` as a signed-in author with title `"   "` (spaces only), description `About me` and body `Hello world` returns status 422 with body `{"errors":{"title":["can't be blank"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body, not title `is invalid` | yes |
| `POST /api/articles` as a signed-in author with title `123` sent as a JSON number, description `About me` and body `Hello world` returns status 422 with body `{"errors":{"title":["can't be blank"]}}` | author | 1 `user` `jake` | seeded-by:backend-foundation | HTTP client | status 422 with that exact body, not 500 | yes |

## Writes

| Key | Op |
|-----|----|
| `article` | append |

## Reads

| Key | Source |
|-----|--------|
| `user.id` | spec |
| `user.username` | spec |
| `user.bio` | spec |
| `user.image` | spec |
| `clock.now` | framework:clock |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `POST /api/articles` as jake with title `My first post`, description `About me` and body `Hello world` returns status 201 | `user.username` | state | value:jake | spec:backend-foundation |
| `GET /api/articles?author=jake` returns only `how-to-train-your-dragon` with `articlesCount` equal to 1 | `user.username` | state | value:jake | spec:backend-foundation |
| `POST /api/articles` as jake with an empty title returns status 422 with body `{"errors":{"title":["can't be blank"]}}` | `article.title` | input | null | — |
