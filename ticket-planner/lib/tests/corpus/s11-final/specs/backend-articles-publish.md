# backend-articles-publish

## Title

Signed-in authors can publish articles through the API

## Description

## Summary

Add `POST /api/articles`, which lets a signed-in author create an article. The API builds the slug from the title, adds `-2`, `-3` and so on when the slug is taken, and rejects requests with no valid token or a blank field.

## Outcome

**Serves:** O2

**Who:** Author

**Need:** Publish articles; only a signed-in author can publish.

**Outcome:** A signed-in author can publish an article and lands on its page. A signed-out visitor is not offered publishing.

## Background / Motivation

The editor page needs an endpoint that creates articles for the signed-in author only. The brief fixes the request, the 201 response shape, the slug rule with collision suffixes, the 422 blank-field body and the 401 token body.

## Proposed Behaviour

`POST /api/articles` with header `Authorization: Token <jwt>` and body `{"article":{"title","description","body"}}` creates the article for the token's user and returns 201 with `{"article":{"slug","title","description","body","createdAt","updatedAt","author":{"username","bio","image"}}}`.

- **Slug.** The title is lower-cased, every run of characters that are not letters or digits becomes one `-`, and leading and trailing `-` are removed. "My first post" becomes `my-first-post`. If that slug is taken, the API appends `-2`, then `-3`, and so on, to the first free one.
- **Timestamps.** `createdAt` is the creation time as an ISO 8601 UTC string, for example `2026-11-16T09:30:00.000Z`. `updatedAt` equals `createdAt`. A new article's `createdAt` is always later than every existing article's `createdAt`, even when several articles are created within the same millisecond, so "newest first" never has a tie.
- **Blank fields.** If `title`, `description` or `body` is missing or an empty string, the response is 422 and `errors` lists every blank field, each with `["can't be blank"]`. A title whose slug comes out empty (for example `!!!`) counts as a blank title. A body with no `article` object (for example `{}`) counts as an `article` object with every field blank.
- **Token.** A missing header, a scheme other than `Token`, a malformed token, a token signed with another secret, or an expired token returns 401 `{"errors":{"token":["is missing or invalid"]}}`. The token check runs before the body check.
- **Order.** A new article is newer than both seed articles, so it comes first in `GET /api/articles`.
- **Default page size.** With more than 20 articles, `GET /api/articles` with no query returns 20 items while `articlesCount` counts all of them.
- **Restart.** Articles created through the API are gone after a server restart; only the seed articles remain. A live restart is `bash scripts/env-start.sh` (from `backend-scaffold`), which always restarts the backend.

## Technical Context

- Repository `app`, folder `backend/`. Builds on `app.js`, `store.js`, `errors.js` (`backend-scaffold`), `requireAuth` in `auth.js` and the seed user `jake` (`backend-auth`), and `routes/articles.js`, `toArticleJSON` and the seed articles (`backend-articles-read`).
- `backend/slug.js`: `slugify(title)` = `title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')`. `uniqueSlug(base, articles)` returns `base` if free, else the first free `base-N` for N = 2, 3, and so on.
- `backend/routes/articles.js`: add `POST /api/articles` with `requireAuth` before the handler. Read the fields from `(req.body && req.body.article) || {}`. Validate blank fields as in `backend-auth` (missing, not a string, or `""`, all collected at once); then if `slugify(title)` is `""`, report `title` as blank (parameter `articles.empty_slug_title`). Compute the slug and push the record in the same synchronous block, with no `await` between the free-slug check and the insert.
- Timestamps: take `Date.now()`; if it is not later than the newest `createdAt` in the store, use that newest `createdAt` plus 1 ms instead; `createdAt = updatedAt = new Date(t).toISOString()`. This keeps every `createdAt` distinct, because `toISOString()` has millisecond resolution and a tight loop creates several articles per millisecond. The list route in `backend-articles-read` sorts by `createdAt` only, so distinct values are what make its order total.
- Response through `toArticleJSON` with status 201.
- Default list size 20 comes from parameter `articles.list_default_limit`, already applied by the list route in `backend-articles-read`.
- Tests: `backend/tests/articles-publish.test.js` and `backend/tests/slug.test.js`, supertest, `store.reset()` in `beforeEach`. Get a `jake` token by logging in with the seed credentials. The page-size and ordering tests start from a reset store (the 2 seed articles only) and publish their 19 articles in a loop with no delay.
- The restart criterion is a live check: it runs against the backend that `scripts/env-start.sh` (new in `backend-scaffold`) started, and restarts it by running that script again.

## Acceptance Criteria

- [ ] `POST /api/articles` as `jake` with title `My first post`, description `Intro` and body `Hello Conduit` returns status 201.
- [ ] The 201 response for `My first post` has `article.slug` equal to `my-first-post`.
- [ ] The 201 response for `My first post` has `article.title` equal to `My first post`.
- [ ] The 201 response for `My first post` has `article.description` equal to `Intro`.
- [ ] The 201 response for `My first post` has `article.body` equal to `Hello Conduit`.
- [ ] The 201 response for `My first post` has `article.author.username` equal to `jake`.
- [ ] The 201 response for `My first post` has `article.author.bio` equal to null.
- [ ] The 201 response for `My first post` has `article.author.image` equal to null.
- [ ] The 201 response for `My first post` has `article.createdAt` matching the pattern `YYYY-MM-DDTHH:mm:ss.sssZ`.
- [ ] The 201 response for `My first post` has `article.updatedAt` equal to its `article.createdAt`.
- [ ] The 201 response for `My first post` has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author` under `article`.
- [ ] `POST /api/articles` as `jake` with title `Hello, World!!` returns `article.slug` equal to `hello-world`.
- [ ] `POST /api/articles` as `jake` with title `--Rust & Go--` returns `article.slug` equal to `rust-go`.
- [ ] A second `POST /api/articles` as `jake` with title `My first post` returns `article.slug` equal to `my-first-post-2`.
- [ ] A third `POST /api/articles` as `jake` with title `My first post` returns `article.slug` equal to `my-first-post-3`.
- [ ] `POST /api/articles` as `jake` with title `Welcome to Conduit` returns `article.slug` equal to `welcome-to-conduit-2`.
- [ ] After `jake` publishes `My first post`, `GET /api/articles/my-first-post` returns status 200.
- [ ] After `jake` publishes `My first post`, `GET /api/articles` returns `articles[0].slug` equal to `my-first-post`.
- [ ] After `jake` publishes `My first post`, `GET /api/articles` returns `articlesCount` equal to 3.
- [ ] Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles, `GET /api/articles` with no query returns an `articles` array of length 20.
- [ ] Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles, `GET /api/articles` with no query returns `articlesCount` equal to 21.
- [ ] Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles back to back with no delay, the 20 items `GET /api/articles` returns with no query have 20 distinct `createdAt` values.
- [ ] Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles back to back with no delay, `articles[0].title` in the `GET /api/articles` response equals the title of the 19th article published.
- [ ] `POST /api/articles` as `jake` without a `title` field returns status 422 with body `{"errors":{"title":["can't be blank"]}}`.
- [ ] `POST /api/articles` as `jake` with `description` set to an empty string returns status 422 with body `{"errors":{"description":["can't be blank"]}}`.
- [ ] `POST /api/articles` as `jake` without a `body` field returns status 422 with body `{"errors":{"body":["can't be blank"]}}`.
- [ ] `POST /api/articles` as `jake` with an empty `article` object returns status 422 with an `errors` object holding exactly the keys `title`, `description`, `body`, each `["can't be blank"]`.
- [ ] `POST /api/articles` as `jake` with body `{}`, which has no `article` object, returns status 422 with an `errors` object holding exactly the keys `title`, `description`, `body`, each `["can't be blank"]`.
- [ ] `POST /api/articles` as `jake` with title `!!!` returns status 422 with body `{"errors":{"title":["can't be blank"]}}`.
- [ ] `POST /api/articles` with no `Authorization` header returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `POST /api/articles` with header `Authorization: Bearer <jake's login token>` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `POST /api/articles` with header `Authorization: Token not-a-jwt` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `POST /api/articles` with a `jake` token signed with the secret `other-secret` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `POST /api/articles` with an expired `jake` token returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`.
- [ ] `POST /api/articles` with no `Authorization` header and an empty `article` object returns status 401.
- [ ] After `jake` publishes `My first post` against the backend that `bash scripts/env-start.sh` started, and the script then runs again, `GET /api/articles/my-first-post` returns status 404.

## Out of Scope

- Article edit and delete, tags, favorites, comments.
- The editor page (`frontend-editor`).

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `POST /api/articles` in `backend/routes/articles.js`, `backend/slug.js`, `backend/tests/articles-publish.test.js`, `backend/tests/slug.test.js` |

## Test User

`jake@conduit.test` (Author) — password `Jake-Pass-123`.

## Navigation Path

No UI: exercise the endpoint with `npm test` in `backend/`. The restart criterion uses an HTTP client against the backend that `bash scripts/env-start.sh` starts from the repo root; running the script again restarts the backend and puts the store back to the seed.

## Test Data Provided

- Articles created by `jake` through `POST /api/articles` inside the tests: `My first post` (up to three times), `Hello, World!!`, `--Rust & Go--`, `Welcome to Conduit`, and 19 with distinct titles (`Article 1` to `Article 19`, in that order) for the page-size and ordering checks, published into a store holding only the 2 seed articles.
- Test-built tokens for `jake`: one expired, one signed with `other-secret`.

## Labels

planned, INIT-0000000000-5252, feature, blocked-by:backend-scaffold, blocked-by:backend-auth, blocked-by:backend-articles-read

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 0,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Add an author-only POST /api/articles route behind requireAuth with a slugify helper and synchronous -2/-3 collision suffixing over the in-memory store.",
  "AffectedServices": "app",
  "TargetSymbols": "slugify (new):app/backend/slug.js;articles (new in backend-articles-read):app/backend/routes/articles.js;requireAuth (new in backend-auth):app/backend/auth.js;articlesPublishTest (new):app/backend/tests/articles-publish.test.js;slugTest (new):app/backend/tests/slug.test.js;envStart (new in backend-scaffold):app/scripts/env-start.sh",
  "Kind": "business",
  "Serves": ["O2"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `POST /api/articles` as `jake` with title `My first post`, description `Intro` and body `Hello Conduit` returns status 201. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | status 201 | yes |
| The 201 response for `My first post` has `article.slug` equal to `my-first-post`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `my-first-post` | yes |
| The 201 response for `My first post` has `article.title` equal to `My first post`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `My first post` | yes |
| The 201 response for `My first post` has `article.description` equal to `Intro`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `Intro` | yes |
| The 201 response for `My first post` has `article.body` equal to `Hello Conduit`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `Hello Conduit` | yes |
| The 201 response for `My first post` has `article.author.username` equal to `jake`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `jake` | yes |
| The 201 response for `My first post` has `article.author.bio` equal to null. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | null | yes |
| The 201 response for `My first post` has `article.author.image` equal to null. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | null | yes |
| The 201 response for `My first post` has `article.createdAt` matching the pattern `YYYY-MM-DDTHH:mm:ss.sssZ`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | ISO 8601 UTC string ending in `Z` | yes |
| The 201 response for `My first post` has `article.updatedAt` equal to its `article.createdAt`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | the two strings are equal | yes |
| The 201 response for `My first post` has exactly the keys `slug`, `title`, `description`, `body`, `createdAt`, `updatedAt`, `author` under `article`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | key set equals the seven listed keys | yes |
| `POST /api/articles` as `jake` with title `Hello, World!!` returns `article.slug` equal to `hello-world`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `hello-world` | yes |
| `POST /api/articles` as `jake` with title `--Rust & Go--` returns `article.slug` equal to `rust-go`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | `rust-go` | yes |
| A second `POST /api/articles` as `jake` with title `My first post` returns `article.slug` equal to `my-first-post-2`. | author | 1 `user` in state registered (`jake`); 1 `article` in state published (`my-first-post`, created in the test) | seeded-by:backend-articles-publish | | `my-first-post-2` | yes |
| A third `POST /api/articles` as `jake` with title `My first post` returns `article.slug` equal to `my-first-post-3`. | author | 1 `user` in state registered (`jake`); 2 `article` records in state published (`my-first-post`, `my-first-post-2`, created in the test) | seeded-by:backend-articles-publish | | `my-first-post-3` | yes |
| `POST /api/articles` as `jake` with title `Welcome to Conduit` returns `article.slug` equal to `welcome-to-conduit-2`. | author | 1 `user` in state registered (`jake`); 1 `article` in state published (`welcome-to-conduit`) | seeded-by:backend-articles-read | | `welcome-to-conduit-2` | yes |
| After `jake` publishes `My first post`, `GET /api/articles/my-first-post` returns status 200. | anonymous reader | 1 `article` in state published (`my-first-post`, created in the test) | seeded-by:backend-articles-publish | | status 200 | yes |
| After `jake` publishes `My first post`, `GET /api/articles` returns `articles[0].slug` equal to `my-first-post`. | anonymous reader | 2 `article` records in state published (seed); 1 `article` in state published (`my-first-post`, created in the test) | seeded-by:backend-articles-read | | `my-first-post` | yes |
| After `jake` publishes `My first post`, `GET /api/articles` returns `articlesCount` equal to 3. | anonymous reader | 2 `article` records in state published (seed); 1 `article` in state published (`my-first-post`, created in the test) | seeded-by:backend-articles-read | | 3 | yes |
| Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles, `GET /api/articles` with no query returns an `articles` array of length 20. | anonymous reader | 2 `article` records in state published (seed); 19 `article` records in state published (`Article 1` to `Article 19`, created by `jake` in the test) | seeded-by:backend-articles-publish | `npm test`, store reset before the test | length 20 | yes |
| Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles, `GET /api/articles` with no query returns `articlesCount` equal to 21. | anonymous reader | 2 `article` records in state published (seed); 19 `article` records in state published (`Article 1` to `Article 19`, created by `jake` in the test) | seeded-by:backend-articles-publish | `npm test`, store reset before the test | 21 | yes |
| Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles back to back with no delay, the 20 items `GET /api/articles` returns with no query have 20 distinct `createdAt` values. | anonymous reader | 2 `article` records in state published (seed); 19 `article` records in state published (`Article 1` to `Article 19`, created by `jake` in a loop with no delay) | seeded-by:backend-articles-publish | `npm test`, store reset before the test | 20 distinct `createdAt` strings | yes |
| Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles back to back with no delay, `articles[0].title` in the `GET /api/articles` response equals the title of the 19th article published. | anonymous reader | 2 `article` records in state published (seed); 19 `article` records in state published (`Article 1` to `Article 19`, created by `jake` in a loop with no delay) | seeded-by:backend-articles-publish | `npm test`, store reset before the test | `Article 19` | yes |
| `POST /api/articles` as `jake` without a `title` field returns status 422 with body `{"errors":{"title":["can't be blank"]}}`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 422, `{"errors":{"title":["can't be blank"]}}` | yes |
| `POST /api/articles` as `jake` with `description` set to an empty string returns status 422 with body `{"errors":{"description":["can't be blank"]}}`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 422, `{"errors":{"description":["can't be blank"]}}` | yes |
| `POST /api/articles` as `jake` without a `body` field returns status 422 with body `{"errors":{"body":["can't be blank"]}}`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 422, `{"errors":{"body":["can't be blank"]}}` | yes |
| `POST /api/articles` as `jake` with an empty `article` object returns status 422 with an `errors` object holding exactly the keys `title`, `description`, `body`, each `["can't be blank"]`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 422, three keys each `["can't be blank"]` | yes |
| `POST /api/articles` as `jake` with body `{}`, which has no `article` object, returns status 422 with an `errors` object holding exactly the keys `title`, `description`, `body`, each `["can't be blank"]`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 422, three keys each `["can't be blank"]` | yes |
| `POST /api/articles` as `jake` with title `!!!` returns status 422 with body `{"errors":{"title":["can't be blank"]}}`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 422, `{"errors":{"title":["can't be blank"]}}` | yes |
| `POST /api/articles` with no `Authorization` header returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | anonymous reader | none | — | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with header `Authorization: Bearer <jake's login token>` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | author | 1 `user` in state registered (`jake`) | seeded-by:backend-auth | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with header `Authorization: Token not-a-jwt` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | anonymous reader | none | — | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with a `jake` token signed with the secret `other-secret` returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | author | a `jake` token signed with `other-secret` | seeded-by:backend-articles-publish | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with an expired `jake` token returns status 401 with body `{"errors":{"token":["is missing or invalid"]}}`. | author | an expired `jake` token | seeded-by:backend-articles-publish | | 401, `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `POST /api/articles` with no `Authorization` header and an empty `article` object returns status 401. | anonymous reader | none | — | | status 401 | yes |
| After `jake` publishes `My first post` against the backend that `bash scripts/env-start.sh` started, and the script then runs again, `GET /api/articles/my-first-post` returns status 404. | anonymous reader | 1 `article` in state published (`my-first-post`, created against the running backend before the second script run) | seeded-by:backend-articles-publish | run `bash scripts/env-start.sh`, sign in as `jake`, publish `My first post`, run the script again, then request the article | status 404 | yes |

## Writes

| Key | Op |
|-----|----|
| `article` | append |

## Reads

| Key | Source |
|-----|--------|
| `user.id` | spec |
| `user.username` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `POST /api/articles` as `jake` with title `My first post`, description `Intro` and body `Hello Conduit` returns status 201. | `user.username` | state | value:jake | spec:backend-auth |
| `POST /api/articles` as `jake` with title `Welcome to Conduit` returns `article.slug` equal to `welcome-to-conduit-2`. | `article.author` | state | value:jane | spec:backend-articles-read |
| `POST /api/articles` as `jake` without a `title` field returns status 422 with body `{"errors":{"title":["can't be blank"]}}`. | `article.title` | input | null | — |
| `POST /api/articles` as `jake` with `description` set to an empty string returns status 422 with body `{"errors":{"description":["can't be blank"]}}`. | `article.description` | input | null | — |
| `POST /api/articles` as `jake` without a `body` field returns status 422 with body `{"errors":{"body":["can't be blank"]}}`. | `article.body` | input | null | — |
