# api-article-create

## Title

Signed-in authors can publish an article through the API

## Description

## Summary

Add the author-only endpoint that publishes a new article. The article gets a readable address (a slug) built from its title, and a request without a valid sign-in is refused.

## Outcome

**Serves:** O2, O4

**Who:** Author

**Need:** Publish an article that others can read.

**Outcome:** A signed-in author can publish an article, and it gets its own readable address derived from its title. A publish attempt without a valid sign-in is refused.

## Background / Motivation

Publishing is the one thing only authors may do. The editor page in the frontend sends its form to this endpoint and then opens the new article by its slug, so the slug rule has to be exact. The brief requires `npm test` in `backend/` to cover every endpoint, including each error case.

## Proposed Behaviour

- A signed-in author sends `{"article":{"title","description","body"}}` with `Authorization: Token <jwt>`. The response is status 201 with `{"article":{"slug","title","description","body","createdAt","updatedAt","author":{"username","bio","image"}}}`.
- `title`, `description` and `body` in the response are the submitted values. `author` is the signed-in author.
- `createdAt` is the current time as an ISO 8601 string, and `updatedAt` equals `createdAt`.
- **Slug.** The slug is the title in lower case, with every run of characters that are not letters or digits replaced by `-`, and any leading or trailing `-` removed. If that slug is taken, `-2` is added; if that is taken too, `-3`, and so on.
- A title with no letters or digits gets the slug `article`, and the same `-2`, `-3` rule applies.
- The new article can then be read by its slug, and it is listed first because it is the newest.
- **Blank fields.** A missing, non-string, or whitespace-only `title`, `description` or `body` gets status 422 with `can't be blank` on that field. Every blank field is listed in the same body. A body that is not valid JSON, or that has no `article` object, counts as all three fields blank.
- **Sign-in.** A missing header, a scheme other than `Token`, a token with a bad signature, an expired token, or a token naming an author who is not in the store gets status 401 with `{"errors":{"token":["is missing or invalid"]}}`. The sign-in check runs before the field check.
- No response contains a password or password hash.

## Technical Context

- Builds on `backend-foundation` (`createApp()`, the store with `reset()` and `insertArticle()`, the seed, the error helpers `validationError` and `sendError`, and the JSON parse shim, `request.body.malformed_json`), on `api-user-auth` (`requireAuth` and `signToken` in `backend/src/auth.js`), and on `api-article-reads` (the router in `backend/src/routes/articles.js` and its `toArticle` and `toProfile` serializers, plus the list and single-article endpoints used to check the result).
- Add `POST /api/articles` to `backend/src/routes/articles.js`, behind `requireAuth` (`auth.token.scheme`).
- Add `backend/src/slug.js` with `slugify(title)` (lower case, replace each run of `[^a-z0-9]` with `-`, trim `-` at both ends) and `uniqueSlug(base)` (try `base`, then `base-2`, `base-3`, … until no stored article has it). An empty `slugify` result becomes `article` (`articles.slug.empty_base`).
- Blank rule (`validation.field.blank`): missing, not a string, or empty after `trim()`. Fields are reported in the order title, description, body.
- The new article is added through `store.insertArticle()`, which gives it the next integer `id`. It carries the author's `id`, and `createdAt` and `updatedAt` both set from one `new Date().toISOString()` call (`articles.create.timestamps`).
- Tests: `backend/test/articles-create.test.js`, supertest against `createApp()` with `store.reset()` in `beforeEach`. Tokens come from signing in as the seeded `jake`; the expired token is built in the test with `jsonwebtoken`.

## Acceptance Criteria

- [ ] `jake` creating an article titled "My first post" returns status 201
- [ ] `jake` creating an article titled "My first post" returns the slug `my-first-post`
- [ ] `jake` creating an article with description "Intro" returns `description` "Intro"
- [ ] `jake` creating an article with body "Hello world." returns `body` "Hello world."
- [ ] `jake` creating an article titled "My first post" returns `title` "My first post"
- [ ] `jake` creating an article returns `author` `{"username":"jake","bio":null,"image":null}`
- [ ] `jake` creating an article returns a `createdAt` that is an ISO 8601 timestamp
- [ ] `jake` creating an article returns an `updatedAt` equal to its `createdAt`
- [ ] Creating a second article titled "My first post" returns the slug `my-first-post-2`
- [ ] Creating a third article titled "My first post" returns the slug `my-first-post-3`
- [ ] Creating an article titled "  Hello, World!! " returns the slug `hello-world`
- [ ] Creating an article titled "!!!" returns the slug `article`
- [ ] Creating a second article titled "???" returns the slug `article-2`
- [ ] After `jake` creates "My first post", reading the article `my-first-post` returns status 200
- [ ] After `jake` creates "My first post", the article list shows `my-first-post` first
- [ ] After `jake` creates "My first post", the article list returns `articlesCount` 3
- [ ] The create response contains no `password` key
- [ ] Creating an article with no `Authorization` header returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Creating an article with `Authorization: Bearer <jake's token>` returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Creating an article with a token signed by a different secret returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Creating an article with an expired token for `jake` returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Creating an article with a valid token for user `id` 999 returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Creating an article with no `Authorization` header leaves the article list at `articlesCount` 2
- [ ] `jake` creating an article without a `title` returns status 422 with `{"errors":{"title":["can't be blank"]}}`
- [ ] `jake` creating an article with `description` set to an empty string returns status 422 with `{"errors":{"description":["can't be blank"]}}`
- [ ] `jake` creating an article with `body` set to three spaces returns status 422 with `{"errors":{"body":["can't be blank"]}}`
- [ ] `jake` creating an article with a body that is not valid JSON returns status 422 listing `title`, `description` and `body` as `can't be blank`
- [ ] `npm test` in `backend/` runs the article create tests and exits with code 0
- [ ] Creating an article with no `Authorization` header and an empty `article` object returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`, not status 422
- [ ] A signed-in author creating an article with a valid JSON body that has no `article` object returns status 422 listing `title`, `description` and `body` as `can't be blank`
- [ ] A signed-in author creating an article with `title` set to the number 123 and a valid `description` and `body` returns status 422 with `{"errors":{"title":["can't be blank"]}}`

## Test User

- Author: `jake@conduit.test` / `Jake-Pass-123` (username `jake`).
- Anonymous reader: no credentials, for the refused requests.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| Backend | app | `POST /api/articles`, slug rule, article create tests |

## Navigation Path

No page in the app. Start the API with `npm start` in `backend/`, sign in as `jake` to get a token, then send the requests from an HTTP client to port 3000, or run `npm test` in `backend/`.

## Labels

planned, INIT-0000000000-9899, feature, blocked-by:backend-foundation, blocked-by:api-user-auth, blocked-by:api-article-reads

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 5,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Add an author-only POST /api/articles behind requireAuth, with a slugify and uniqueSlug helper that adds -2, -3 suffixes on collision.",
  "AffectedServices": "app",
  "TargetSymbols": "uniqueSlug (new):app/backend/src/slug.js;slugify (new):app/backend/src/slug.js;articlesRouter (new in api-article-reads):app/backend/src/routes/articles.js;requireAuth (new in api-user-auth):app/backend/src/auth.js;insertArticle (new in backend-foundation):app/backend/src/store.js",
  "Kind": "business",
  "Serves": ["O2", "O4"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| `jake` creating an article titled "My first post" returns status 201 | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 201 | yes |
| `jake` creating an article titled "My first post" returns the slug `my-first-post` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `article.slug` "my-first-post" | yes |
| `jake` creating an article with description "Intro" returns `description` "Intro" | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `article.description` "Intro" | yes |
| `jake` creating an article with body "Hello world." returns `body` "Hello world." | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `article.body` "Hello world." | yes |
| `jake` creating an article titled "My first post" returns `title` "My first post" | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `article.title` "My first post" | yes |
| `jake` creating an article returns `author` `{"username":"jake","bio":null,"image":null}` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `{"username":"jake","bio":null,"image":null}` | yes |
| `jake` creating an article returns a `createdAt` that is an ISO 8601 timestamp | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `createdAt` parses with `Date` and equals its own `toISOString()` | yes |
| `jake` creating an article returns an `updatedAt` equal to its `createdAt` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `updatedAt` string equals `createdAt` string | yes |
| Creating a second article titled "My first post" returns the slug `my-first-post-2` | author | seeded `user` jake with a sign-in token, plus 1 `article` "My first post" created first in the same test | seeded-by:api-article-create | | `article.slug` "my-first-post-2" | yes |
| Creating a third article titled "My first post" returns the slug `my-first-post-3` | author | seeded `user` jake with a sign-in token, plus 2 `article` records titled "My first post" created first in the same test | seeded-by:api-article-create | | `article.slug` "my-first-post-3" | yes |
| Creating an article titled "  Hello, World!! " returns the slug `hello-world` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `article.slug` "hello-world" | yes |
| Creating an article titled "!!!" returns the slug `article` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | `article.slug` "article" | yes |
| Creating a second article titled "???" returns the slug `article-2` | author | seeded `user` jake with a sign-in token, plus 1 `article` titled "!!!" created first in the same test | seeded-by:api-article-create | | `article.slug` "article-2" | yes |
| After `jake` creates "My first post", reading the article `my-first-post` returns status 200 | author | seeded `user` jake with a sign-in token, plus the `article` "My first post" created in the same test | seeded-by:api-article-create | | status 200; `article.title` "My first post" | yes |
| After `jake` creates "My first post", the article list shows `my-first-post` first | anonymous reader | 2 seeded `article` records, plus the `article` "My first post" created in the same test | seeded-by:api-article-create | | `articles[0].slug` "my-first-post" | yes |
| After `jake` creates "My first post", the article list returns `articlesCount` 3 | anonymous reader | 2 seeded `article` records, plus the `article` "My first post" created in the same test | seeded-by:api-article-create | | `articlesCount` 3 | yes |
| The create response contains no `password` key | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | no `password` key at any level | yes |
| Creating an article with no `Authorization` header returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Creating an article with `Authorization: Bearer <jake's token>` returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Creating an article with a token signed by a different secret returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | author | a token for seeded `user` jake signed with the secret `other-secret`, built in the test | seeded-by:api-article-create | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Creating an article with an expired token for `jake` returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | author | an expired token for seeded `user` jake, built in the test | seeded-by:api-article-create | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Creating an article with a valid token for user `id` 999 returns status 401 with `{"errors":{"token":["is missing or invalid"]}}` | author | a correctly signed token naming `user` `id` 999, which the store does not hold, built in the test | seeded-by:api-article-create | | status 401; `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Creating an article with no `Authorization` header leaves the article list at `articlesCount` 2 | anonymous reader | 2 seeded `article` records | seeded-by:backend-foundation | | `articlesCount` 2 after the refused request | yes |
| `jake` creating an article without a `title` returns status 422 with `{"errors":{"title":["can't be blank"]}}` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 422; `{"errors":{"title":["can't be blank"]}}` | yes |
| `jake` creating an article with `description` set to an empty string returns status 422 with `{"errors":{"description":["can't be blank"]}}` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 422; `{"errors":{"description":["can't be blank"]}}` | yes |
| `jake` creating an article with `body` set to three spaces returns status 422 with `{"errors":{"body":["can't be blank"]}}` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 422; `{"errors":{"body":["can't be blank"]}}` | yes |
| `jake` creating an article with a body that is not valid JSON returns status 422 listing `title`, `description` and `body` as `can't be blank` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 422; `errors` has `title`, `description`, `body`, each `["can't be blank"]` | yes |
| `npm test` in `backend/` runs the article create tests and exits with code 0 | developer | none | — | terminal in `backend/` | exit code 0 with `articles-create.test.js` listed | yes |
| Creating an article with no `Authorization` header and an empty `article` object returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`, not status 422 | anonymous reader | none | — | | status 401; `{"errors":{"token":["is missing or invalid"]}}`; no `title`, `description` or `body` key in `errors` | yes |
| A signed-in author creating an article with a valid JSON body that has no `article` object returns status 422 listing `title`, `description` and `body` as `can't be blank` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 422; `errors` has `title`, `description`, `body`, each `["can't be blank"]` | yes |
| A signed-in author creating an article with `title` set to the number 123 and a valid `description` and `body` returns status 422 with `{"errors":{"title":["can't be blank"]}}` | author | seeded `user` jake with a sign-in token | seeded-by:backend-foundation | | status 422; `{"errors":{"title":["can't be blank"]}}` | yes |

## Test Data Provided

- Test-only `article` records that `backend/test/articles-create.test.js` creates through the endpoint as `jake`: one or two articles titled "My first post" before the collision checks, and one titled "!!!" before the `article-2` check.
- Test-only tokens built with `jsonwebtoken`: a token for `jake` signed with the secret `other-secret`, an already expired token for `jake`, and a correctly signed token naming user `id` 999.

## Writes

| Key | Op |
|-----|----|
| `article.id` | append |
| `article.slug` | append |
| `article.title` | append |
| `article.description` | append |
| `article.body` | append |
| `article.created_at` | append |
| `article.updated_at` | append |
| `article.author_id` | append |

## Reads

| Key | Source |
|-----|--------|
| `user.id` | spec |
| `user.username` | spec |
| `user.bio` | spec |
| `user.image` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| `jake` creating an article titled "My first post" returns status 201 | `user.username` | state | value:jake | spec:backend-foundation |
| `jake` creating an article without a `title` returns status 422 with `{"errors":{"title":["can't be blank"]}}` | `article.title` | input | null | — |
