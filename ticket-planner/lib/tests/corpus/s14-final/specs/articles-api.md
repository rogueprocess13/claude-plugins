# articles-api

## Title

Authors can publish articles and anyone can read them through the API

## Description

## Summary

Add the article endpoints to the backend: create (`POST /api/articles`, authors only), read one (`GET /api/articles/:slug`) and list (`GET /api/articles` with `limit`, `offset` and `author`), plus the two seeded articles.

## Outcome

**Serves:** O2, O3

**Who:** Author (publishes); Anonymous reader (reads)

**Need:** Authors need to publish articles. Readers need to read them without an account.

**Outcome:** A signed-in author can publish an article. Anyone can list published articles, newest first, and open any one.

## Background / Motivation

The home page, the article page and the editor all depend on these endpoints. The brief fixes the response shapes, the slug rule, the paging defaults and the ordering, so the browser walkthrough can rely on them.

## Proposed Behaviour

Seed data, created fresh every time the app is built:

- `how-to-train-your-dragon`: title "How to train your dragon", author `jake`, `createdAt` and `updatedAt` `2026-01-01T10:00:00.000Z`.
- `welcome-to-conduit`: title "Welcome to Conduit", author `jane`, `createdAt` and `updatedAt` `2026-01-02T10:00:00.000Z`.
- Both have description `Seed article` and body `Seed body text.`

Create — `POST /api/articles` with `{"article":{"title","description","body"}}`, author only:

- Success returns 201 and `{"article":{"slug","title","description","body","createdAt","updatedAt","author":{"username","bio","image"}}}`, exactly those keys. `author` is the signed-in author, with `bio` and `image` `null`. `createdAt` and `updatedAt` are the same ISO 8601 timestamp with milliseconds.
- The slug is the title lower-cased, with each run of characters other than `a-z` and `0-9` replaced by `-`, and leading and trailing `-` removed. If that slug is taken, `-2` is appended; if that is taken too, `-3`, and so on.
- A title that leaves an empty slug (no letters or digits) returns 422 `{"errors":{"title":["is invalid"]}}`.
- Blank `title`, `description` or `body` (missing, not a string, or empty after trimming whitespace) returns 422 `can't be blank` for each blank field, all in one body. A body with no `article` object reports all three.
- No `Authorization` header, a scheme other than `Token`, a bad signature, an expired token, or a token whose `id` matches no account returns 401 `{"errors":{"token":["is missing or invalid"]}}`.

Read one — `GET /api/articles/:slug`, no sign-in needed:

- A known slug returns 200 with `{"article":{...}}` in the same shape.
- An unknown slug returns 404 `{"errors":{"article":["not found"]}}`.

List — `GET /api/articles?limit=&offset=&author=`, no sign-in needed:

- Returns 200 and `{"articles":[...],"articlesCount":N}`. Each item has the same shape as a single article.
- Articles are ordered by `createdAt`, newest first. When two articles have the same `createdAt`, the one created later comes first.
- `author` keeps only articles whose author username matches exactly (case-sensitive). An unknown author gives `{"articles":[],"articlesCount":0}`.
- `articlesCount` is the number of matching articles before paging.
- `limit` defaults to 20 and `offset` to 0. A `limit` that is not a whole number of at least 1, or an `offset` that is not a whole number of at least 0, uses the default instead. Paging values never cause a 422.

## Technical Context

- Builds on `backend-scaffold` (`createApp()` in `backend/src/app.js`, the mounted `backend/src/routes/articles.js` router) and on `user-accounts-api` (`createStore()` in `backend/src/store.js`, `requireAuth` in `backend/src/auth.js`, `blankErrors` in `backend/src/errors.js`, `toProfileJSON` in `backend/src/serializers.js`, seeded `jake` and `jane`).
- Store: articles live in the store's `articles` array as `{ id, slug, title, description, body, authorId, createdAt, updatedAt }`. Add `findArticleBySlug`.
- New `backend/src/slug.js`: `slugify(title)` = `title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')`; `uniqueSlug(base, store)` tries `base`, `base-2`, `base-3`, ...
- Extend `backend/src/seed.js` with `seedArticles(store)` (values above); `createApp()` calls it after `seedUsers`.
- Add `toArticleJSON(article, store)` to `backend/src/serializers.js`, returning exactly the seven keys with `author` from `toProfileJSON`.
- Add the routes inside the `articlesRouter(store)` factory in `backend/src/routes/articles.js` (router contract from `backend-scaffold`; the store comes from `createApp()`): `POST /articles` (behind the same `requireAuth` middleware `GET /api/user` uses), `GET /articles/:slug`, `GET /articles`. Timestamps come from `new Date().toISOString()`. Sort by `createdAt` descending, then by insertion order descending.
- Paging: `Number(limit)`; use 20 unless the result is an integer ≥ 1. `Number(offset)`; use 0 unless the result is an integer ≥ 0. No upper cap.
- New tests `backend/test/articles.test.js` with `supertest(createApp())`; get `jake`'s token through `POST /api/members/login`. For the tie-break case freeze `Date` at `2030-01-01T00:00:00.000Z` with `mock.timers.enable({ apis: ['Date'], now: Date.parse('2030-01-01T00:00:00.000Z') })` from `node:test`, create both tie articles, read the list, then call `mock.timers.reset()`. The frozen instant is later than both seed articles, so the two tie articles are the two newest rows. For the expired-token case sign a `jake` token with `expiresIn: -10`; for the unknown-id case sign `{ id: 9999, username: 'ghost' }` with the real secret. For the default-limit case create 23 articles in a loop.
- Parameters: `articles.list_default_limit` = 20; `articles.list_default_offset` = 0; `articles.list_invalid_paging` = use the default limit or offset, never reject; `articles.empty_slug_title` = 422 title is invalid; `articles.unknown_author` = empty list, articlesCount 0; `articles.order_tiebreak` = newest inserted first; `validation.blank_rule` = missing, not a string, or empty after trimming whitespace.

## Acceptance Criteria

- [ ] `POST /api/articles` as `jake` with title `My first post`, description `First description`, body `First body` returns status 201
- [ ] The create response for `My first post` has `article.slug` equal to `my-first-post`
- [ ] The create response for `My first post` has `article.title` equal to `My first post`
- [ ] The create response for `My first post` has `article.description` equal to `First description`
- [ ] The create response for `My first post` has `article.body` equal to `First body`
- [ ] The create response for `My first post` has `article.author.username` equal to `jake`
- [ ] The create response for `My first post` has `article.author.bio` equal to `null`
- [ ] The create response for `My first post` has `article.author.image` equal to `null`
- [ ] The create response for `My first post` has an `article` object with exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author`
- [ ] The create response for `My first post` has an `article.author` object with exactly the keys `username`, `bio`, `image`
- [ ] The create response for `My first post` has `article.createdAt` equal to `article.updatedAt`
- [ ] The create response for `My first post` has `article.createdAt` in the format `YYYY-MM-DDTHH:mm:ss.sssZ`
- [ ] `POST /api/articles` as `jake` with title `!!Hello, World!!`, description `d`, body `b` returns `article.slug` equal to `hello-world`
- [ ] `POST /api/articles` as `jake` with title `Welcome to Conduit`, description `d`, body `b` returns `article.slug` equal to `welcome-to-conduit-2`
- [ ] A second `POST /api/articles` as `jake` with title `Welcome to Conduit`, description `d`, body `b` returns `article.slug` equal to `welcome-to-conduit-3`
- [ ] `POST /api/articles` as `jake` with title `!!!`, description `d`, body `b` returns status 422 with the body `{"errors":{"title":["is invalid"]}}`
- [ ] `POST /api/articles` as `jake` with description `d`, body `b`, no `title` returns status 422 with the body `{"errors":{"title":["can't be blank"]}}`
- [ ] `POST /api/articles` as `jake` with title `T`, description `""`, body `b` returns status 422 with the body `{"errors":{"description":["can't be blank"]}}`
- [ ] `POST /api/articles` as `jake` with title `T`, description `d`, body `"   "` returns status 422 with the body `{"errors":{"body":["can't be blank"]}}`
- [ ] `POST /api/articles` as `jake` with the body `{}` returns status 422 with the body `{"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}}`
- [ ] `POST /api/articles` with no `Authorization` header returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `POST /api/articles` with header `Authorization: Bearer <jake login token>` returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `POST /api/articles` with a token for `jake` signed with the secret `wrong-secret` returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `POST /api/articles` with a `jake` token whose `exp` is in the past returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `POST /api/articles` with a validly signed token for `id` 9999 returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns status 200
- [ ] `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.title` equal to `How to train your dragon`
- [ ] `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.description` equal to `Seed article`
- [ ] `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.body` equal to `Seed body text.`
- [ ] `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.author.username` equal to `jake`
- [ ] `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.createdAt` equal to `2026-01-01T10:00:00.000Z`
- [ ] `GET /api/articles/welcome-to-conduit` returns `article.author.username` equal to `jane`
- [ ] `GET /api/articles/no-such-article` returns status 404 with the body `{"errors":{"article":["not found"]}}`
- [ ] After `jake` creates `My first post`, `GET /api/articles/my-first-post` returns status 200
- [ ] `GET /api/articles` with no query returns status 200
- [ ] `GET /api/articles` with no query returns `articlesCount` equal to 2
- [ ] `GET /api/articles` with no query returns `articles[0].slug` equal to `welcome-to-conduit`
- [ ] `GET /api/articles` with no query returns `articles[1].slug` equal to `how-to-train-your-dragon`
- [ ] `GET /api/articles` with no query returns items that each have exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author`
- [ ] After `jake` creates `My first post`, `GET /api/articles` returns `articles[0].slug` equal to `my-first-post`
- [ ] `GET /api/articles?limit=1` returns an `articles` array of length 1
- [ ] `GET /api/articles?limit=1` returns `articlesCount` equal to 2
- [ ] `GET /api/articles?offset=1` returns `articles[0].slug` equal to `how-to-train-your-dragon`
- [ ] `GET /api/articles?author=jake` returns `articlesCount` equal to 1
- [ ] `GET /api/articles?author=jake` returns `articles[0].slug` equal to `how-to-train-your-dragon`
- [ ] `GET /api/articles?author=Jake` returns `articlesCount` equal to 0
- [ ] `GET /api/articles?author=nobody` returns the body `{"articles":[],"articlesCount":0}`
- [ ] `GET /api/articles?limit=abc` returns an `articles` array of length 2
- [ ] `GET /api/articles?limit=0` returns an `articles` array of length 2
- [ ] `GET /api/articles?offset=-1` returns `articles[0].slug` equal to `welcome-to-conduit`
- [ ] `GET /api/articles?offset=abc` returns `articles[0].slug` equal to `welcome-to-conduit`
- [ ] With 25 `article` records in the store, `GET /api/articles` returns an `articles` array of length 20
- [ ] With 25 `article` records in the store, `GET /api/articles` returns `articlesCount` equal to 25
- [ ] When `jake` creates `Tie one` then `Tie two` with `Date` frozen at `2030-01-01T00:00:00.000Z`, `GET /api/articles` returns `articles[0].slug` equal to `tie-two`
- [ ] When `jake` creates `Tie one` then `Tie two` with `Date` frozen at `2030-01-01T00:00:00.000Z`, `GET /api/articles` returns `articles[1].slug` equal to `tie-one`

## Out of Scope

Tags, comments, favorites, the feed, editing or deleting articles, and the frontend pages.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app backend | `src/slug.js`, `src/seed.js`, `src/serializers.js`, `src/store.js`, `src/routes/articles.js`, `test/articles.test.js` |

## Test User

`jake@conduit.test` — password `Jake-Pass-123` (seeded author). Reads need no user.

## Navigation Path

No page: exercise the API with supertest in `npm test`, or with curl against `http://localhost:3000`.

## Labels

planned, INIT-0000000000-2767, feature, blocked-by:backend-scaffold, blocked-by:user-accounts-api

## Signals

```json
{
  "services_identified": 3,
  "symbols_resolved": 6,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "quick-scan",
  "Strategy": "Conservative",
  "Decision": "CommonJS Express 5 API built by a createApp() factory with a seeded in-memory store, tested with node:test plus supertest; Vite vanilla JS SPA reaching it through a /api dev proxy.",
  "AffectedServices": "app backend",
  "TargetSymbols": "createApp (new in backend-scaffold):app/backend/src/app.js;articlesRouter (new in backend-scaffold):app/backend/src/routes/articles.js;createStore (new in user-accounts-api):app/backend/src/store.js;requireAuth (new in user-accounts-api):app/backend/src/auth.js;seedArticles (new):app/backend/src/seed.js;toArticleJSON (new):app/backend/src/serializers.js;slugify (new):app/backend/src/slug.js;articlesTest (new):app/backend/test/articles.test.js",
  "Kind": "business",
  "Serves": ["O2", "O3"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `POST /api/articles` as `jake` with title `My first post`, description `First description`, body `First body` returns status 201 | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 201 | yes |
| The create response for `My first post` has `article.slug` equal to `my-first-post` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `article.slug` = `my-first-post` | yes |
| The create response for `My first post` has `article.title` equal to `My first post` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `article.title` = `My first post` | yes |
| The create response for `My first post` has `article.description` equal to `First description` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `article.description` = `First description` | yes |
| The create response for `My first post` has `article.body` equal to `First body` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `article.body` = `First body` | yes |
| The create response for `My first post` has `article.author.username` equal to `jake` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `article.author.username` = `jake` | yes |
| The create response for `My first post` has `article.author.bio` equal to `null` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `article.author.bio` = `null` | yes |
| The create response for `My first post` has `article.author.image` equal to `null` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `article.author.image` = `null` | yes |
| The create response for `My first post` has an `article` object with exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | key set {slug, title, description, body, createdAt, updatedAt, author} | yes |
| The create response for `My first post` has an `article.author` object with exactly the keys `username`, `bio`, `image` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | key set {username, bio, image}, no `password` key | yes |
| The create response for `My first post` has `article.createdAt` equal to `article.updatedAt` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | the two strings are identical | yes |
| The create response for `My first post` has `article.createdAt` in the format `YYYY-MM-DDTHH:mm:ss.sssZ` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `createdAt` has 4-digit year, then `-`, month, `-`, day, `T`, hours, minutes, seconds, a 3-digit fraction, then `Z` | yes |
| `POST /api/articles` as `jake` with title `!!Hello, World!!`, description `d`, body `b` returns `article.slug` equal to `hello-world` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | `article.slug` = `hello-world` | yes |
| `POST /api/articles` as `jake` with title `Welcome to Conduit`, description `d`, body `b` returns `article.slug` equal to `welcome-to-conduit-2` | author jake | 1 `user` jake with password `Jake-Pass-123`, plus 2 seeded `article` records `how-to-train-your-dragon` and `welcome-to-conduit` | seeded-by:articles-api | `npm test` in `backend/` | `article.slug` = `welcome-to-conduit-2` | yes |
| A second `POST /api/articles` as `jake` with title `Welcome to Conduit`, description `d`, body `b` returns `article.slug` equal to `welcome-to-conduit-3` | author jake | 1 `user` jake with password `Jake-Pass-123`, plus 2 seeded `article` records `how-to-train-your-dragon` and `welcome-to-conduit` | seeded-by:articles-api | `npm test` in `backend/` | `article.slug` = `welcome-to-conduit-3` | yes |
| `POST /api/articles` as `jake` with title `!!!`, description `d`, body `b` returns status 422 with the body `{"errors":{"title":["is invalid"]}}` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 422, `{"errors":{"title":["is invalid"]}}` | yes |
| `POST /api/articles` as `jake` with description `d`, body `b`, no `title` returns status 422 with the body `{"errors":{"title":["can't be blank"]}}` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 422, `{"errors":{"title":["can't be blank"]}}` | yes |
| `POST /api/articles` as `jake` with title `T`, description `""`, body `b` returns status 422 with the body `{"errors":{"description":["can't be blank"]}}` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 422, `{"errors":{"description":["can't be blank"]}}` | yes |
| `POST /api/articles` as `jake` with title `T`, description `d`, body `"   "` returns status 422 with the body `{"errors":{"body":["can't be blank"]}}` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 422, `{"errors":{"body":["can't be blank"]}}` | yes |
| `POST /api/articles` as `jake` with the body `{}` returns status 422 with the body `{"errors":{"title":["can't be blank"],"description":["can't be blank"],"body":["can't be blank"]}}` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 422, all three fields `can't be blank` | yes |
| `POST /api/articles` with no `Authorization` header returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with header `Authorization: Bearer <jake login token>` returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with a token for `jake` signed with the secret `wrong-secret` returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | author jake | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with a `jake` token whose `exp` is in the past returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | author jake | 1 `user` jake | seeded-by:user-accounts-api | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with a validly signed token for `id` 9999 returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}` | anonymous visitor | none | — | `npm test` in `backend/` | status 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns status 200 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | status 200 | yes |
| `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.title` equal to `How to train your dragon` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `article.title` = `How to train your dragon` | yes |
| `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.description` equal to `Seed article` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `article.description` = `Seed article` | yes |
| `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.body` equal to `Seed body text.` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `article.body` = `Seed body text.` | yes |
| `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.author.username` equal to `jake` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `article.author.username` = `jake` | yes |
| `GET /api/articles/how-to-train-your-dragon` with no `Authorization` header returns `article.createdAt` equal to `2026-01-01T10:00:00.000Z` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `article.createdAt` = `2026-01-01T10:00:00.000Z` | yes |
| `GET /api/articles/welcome-to-conduit` returns `article.author.username` equal to `jane` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `article.author.username` = `jane` | yes |
| `GET /api/articles/no-such-article` returns status 404 with the body `{"errors":{"article":["not found"]}}` | anonymous reader | none | — | `npm test` in `backend/` | status 404, `{"errors":{"article":["not found"]}}` | yes |
| After `jake` creates `My first post`, `GET /api/articles/my-first-post` returns status 200 | anonymous reader | 1 `user` jake with password `Jake-Pass-123` | seeded-by:user-accounts-api | `npm test` in `backend/` | status 200 | yes |
| `GET /api/articles` with no query returns status 200 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | status 200 | yes |
| `GET /api/articles` with no query returns `articlesCount` equal to 2 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articlesCount` = 2 | yes |
| `GET /api/articles` with no query returns `articles[0].slug` equal to `welcome-to-conduit` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles[0].slug` = `welcome-to-conduit` | yes |
| `GET /api/articles` with no query returns `articles[1].slug` equal to `how-to-train-your-dragon` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles[1].slug` = `how-to-train-your-dragon` | yes |
| `GET /api/articles` with no query returns items that each have exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | each item key set {slug, title, description, body, createdAt, updatedAt, author} | yes |
| After `jake` creates `My first post`, `GET /api/articles` returns `articles[0].slug` equal to `my-first-post` | anonymous reader | 1 `user` jake with password `Jake-Pass-123`, plus 2 seeded `article` records `how-to-train-your-dragon` and `welcome-to-conduit` | seeded-by:articles-api | `npm test` in `backend/` | `articles[0].slug` = `my-first-post` | yes |
| `GET /api/articles?limit=1` returns an `articles` array of length 1 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles.length` = 1 | yes |
| `GET /api/articles?limit=1` returns `articlesCount` equal to 2 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articlesCount` = 2 | yes |
| `GET /api/articles?offset=1` returns `articles[0].slug` equal to `how-to-train-your-dragon` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles[0].slug` = `how-to-train-your-dragon` | yes |
| `GET /api/articles?author=jake` returns `articlesCount` equal to 1 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articlesCount` = 1 | yes |
| `GET /api/articles?author=jake` returns `articles[0].slug` equal to `how-to-train-your-dragon` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles[0].slug` = `how-to-train-your-dragon` | yes |
| `GET /api/articles?author=Jake` returns `articlesCount` equal to 0 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articlesCount` = 0 | yes |
| `GET /api/articles?author=nobody` returns the body `{"articles":[],"articlesCount":0}` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `{"articles":[],"articlesCount":0}` | yes |
| `GET /api/articles?limit=abc` returns an `articles` array of length 2 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles.length` = 2 | yes |
| `GET /api/articles?limit=0` returns an `articles` array of length 2 | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles.length` = 2 | yes |
| `GET /api/articles?offset=-1` returns `articles[0].slug` equal to `welcome-to-conduit` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles[0].slug` = `welcome-to-conduit` | yes |
| `GET /api/articles?offset=abc` returns `articles[0].slug` equal to `welcome-to-conduit` | anonymous reader | 2 seeded `article` records `how-to-train-your-dragon` (jake) and `welcome-to-conduit` (jane) | seeded-by:articles-api | `npm test` in `backend/` | `articles[0].slug` = `welcome-to-conduit` | yes |
| With 25 `article` records in the store, `GET /api/articles` returns an `articles` array of length 20 | anonymous reader | 23 `article` records created by `jake` through `POST /api/articles`, plus the 2 seeded `article` records | seeded-by:articles-api | `npm test` in `backend/` | `articles.length` = 20 | yes |
| With 25 `article` records in the store, `GET /api/articles` returns `articlesCount` equal to 25 | anonymous reader | 23 `article` records created by `jake` through `POST /api/articles`, plus the 2 seeded `article` records | seeded-by:articles-api | `npm test` in `backend/` | `articlesCount` = 25 | yes |
| When `jake` creates `Tie one` then `Tie two` with `Date` frozen at `2030-01-01T00:00:00.000Z`, `GET /api/articles` returns `articles[0].slug` equal to `tie-two` | anonymous reader | 2 `article` records `Tie one` then `Tie two` created by `jake` with `Date` frozen at `2030-01-01T00:00:00.000Z`, plus the 2 seeded `article` records | seeded-by:articles-api | `npm test` in `backend/` | `articles[0].slug` = `tie-two` | yes |
| When `jake` creates `Tie one` then `Tie two` with `Date` frozen at `2030-01-01T00:00:00.000Z`, `GET /api/articles` returns `articles[1].slug` equal to `tie-one` | anonymous reader | 2 `article` records `Tie one` then `Tie two` created by `jake` with `Date` frozen at `2030-01-01T00:00:00.000Z`, plus the 2 seeded `article` records | seeded-by:articles-api | `npm test` in `backend/` | `articles[1].slug` = `tie-one` | yes |

## Test Data Provided

- 2 `article` records seeded on every app build: `how-to-train-your-dragon` (jake, `2026-01-01T10:00:00.000Z`) and `welcome-to-conduit` (jane, `2026-01-02T10:00:00.000Z`), description `Seed article`, body `Seed body text.`
- The test suite creates its own extra `article` records through `POST /api/articles` as `jake`: `My first post`, two more `Welcome to Conduit`, 23 paging articles, and `Tie one` / `Tie two` with `Date` frozen at `2030-01-01T00:00:00.000Z`.

## Writes

| Key | Op |
|-----|----|
| `article` | create |

## Reads

| Key | Source |
|-----|--------|
| `user.id` | spec |
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `POST /api/articles` as `jake` with description `d`, body `b`, no `title` returns status 422 with the body `{"errors":{"title":["can't be blank"]}}` | `article.title` | input | null | — |
| `POST /api/articles` as `jake` with title `T`, description `""`, body `b` returns status 422 with the body `{"errors":{"description":["can't be blank"]}}` | `article.description` | input | null | — |
| `POST /api/articles` as `jake` with title `T`, description `d`, body `"   "` returns status 422 with the body `{"errors":{"body":["can't be blank"]}}` | `article.body` | input | null | — |
