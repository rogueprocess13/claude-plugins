# store-and-seed

## Title

Add the in-memory store with the seeded authors and articles

## Description

## Summary

Add the in-memory store the API keeps users and articles in, and the seed it starts with: the authors `jake` and `jane` and their two articles.

## Enables

**Enables:** O1, O2 — authors can sign in and publish, and anonymous readers can read the seeded articles.

Storage is in memory and re-seeded on every server start. The endpoints for accounts and articles need a place to keep records, and the acceptance checks rely on the two seeded authors and the two seeded articles being present with fixed values.

## Background / Motivation

There is no database in this slice. All users and articles live in memory and are lost on restart, and a restart is also the reset: after it the store holds only the seed. The brief gives the seed in full, including plain-text passwords and fixed creation times, so that article ordering is the same on every start.

The backend tests need a fresh seeded store for each test. A store that tests share would let one test's records change another test's result.

## Proposed Changes

A store is created already holding the seed. Each call that creates a store returns a new one, and two stores share no records.

Seeded users, in this order:

| id | username | email | password | bio | image |
|----|----------|-------|----------|-----|-------|
| 1 | `jake` | `jake@conduit.test` | `Jake-Pass-123` | null | null |
| 2 | `jane` | `jane@conduit.test` | `Jane-Pass-123` | null | null |

The store keeps a bcrypt hash of each password, made with cost 10. It never keeps the plain-text password.

Seeded articles:

| slug | title | author | createdAt |
|------|-------|--------|-----------|
| `how-to-train-your-dragon` | How to train your dragon | jake | `2026-01-01T10:00:00.000Z` |
| `welcome-to-conduit` | Welcome to Conduit | jane | `2026-01-02T10:00:00.000Z` |

Both have the description `Seed article` and the body `Seed body text.` For each, `updatedAt` equals `createdAt`. The creation times are these fixed values on every start. They are never replaced by the start time.

Lookups:

- A user is found by id, by email compared without regard to case, and by username compared exactly. `JAKE@conduit.test` finds `jake`. The username `Jake` finds nothing.
- An article is found by its slug. An unknown slug finds nothing.

Inserts:

- A user added to the store gets the next integer id. The first user added after the seed gets id 3.
- The server builds one store at start and uses it until it stops.

## Technical Context

All paths are under `app/backend/`. `src/app.js` and `src/server.js` come from the scaffold ticket.

- New `src/store.js` exports `createStore()`. It returns a store with a users array, an articles array, a user id counter and an article insertion-sequence counter, plus the lookup and insert functions: user by id, user by lower-cased email, user by username, article by slug, add user, add article, list articles. The store is returned already seeded.
- New `src/seed.js` holds the two users and two articles above. It hashes the two seed passwords with `bcryptjs` at the cost named by `bcrypt_cost` (10) once per process and reuses the hashes for every `createStore()` call, so a test run does not pay for two hashes per test.
- A stored user has the fields id, username, email, passwordHash, bio and image. A stored article has slug, title, description, body, createdAt, updatedAt, the author's user id and an insertion sequence number. Seeded articles take sequence 1 (`how-to-train-your-dragon`) and 2 (`welcome-to-conduit`).
- `src/app.js`: `createApp({ store } = {})` creates a store with `createStore()` when none is passed and keeps it for its routers. `src/server.js` calls `createApp()` once, so the running API holds exactly one store.
- New `test/store.test.js` (`node:test`) covers every acceptance criterion below by calling `createStore()` directly. Password checks use `bcryptjs` `compare` and `getRounds`.
- No endpoint is added here. The store is reachable only from tests until the account and article endpoints land.

## Acceptance Criteria

- [ ] A new store lists exactly 2 users, `jake` then `jane`.
- [ ] In a new store, `jake` has id 1.
- [ ] In a new store, `jane` has id 2.
- [ ] In a new store, `jake` has the email `jake@conduit.test`.
- [ ] In a new store, `jane` has the email `jane@conduit.test`.
- [ ] In a new store, `bio` is null for both seeded users.
- [ ] In a new store, `image` is null for both seeded users.
- [ ] A bcrypt comparison of `Jake-Pass-123` with the stored hash of `jake` succeeds.
- [ ] A bcrypt comparison of `Jane-Pass-123` with the stored hash of `jane` succeeds.
- [ ] A bcrypt comparison of `wrong-password` with the stored hash of `jake` fails.
- [ ] The stored password hash of each seeded user reports cost 10.
- [ ] No user record in a new store holds the text `Jake-Pass-123`.
- [ ] No user record in a new store holds the text `Jane-Pass-123`.
- [ ] A new store lists exactly 2 articles, with the slugs `how-to-train-your-dragon` and `welcome-to-conduit`.
- [ ] In a new store, the article `how-to-train-your-dragon` has the title `How to train your dragon`.
- [ ] In a new store, the article `how-to-train-your-dragon` has `jake` as its author.
- [ ] In a new store, the article `how-to-train-your-dragon` has the `createdAt` value `2026-01-01T10:00:00.000Z`.
- [ ] In a new store, the article `welcome-to-conduit` has the title `Welcome to Conduit`.
- [ ] In a new store, the article `welcome-to-conduit` has `jane` as its author.
- [ ] In a new store, the article `welcome-to-conduit` has the `createdAt` value `2026-01-02T10:00:00.000Z`.
- [ ] In a new store, both seeded articles have the description `Seed article`.
- [ ] In a new store, both seeded articles have the body `Seed body text.`
- [ ] In a new store, `updatedAt` equals `createdAt` for both seeded articles.
- [ ] A user added to one store does not appear in a second store created before or after it.
- [ ] An article added to one store does not appear in a second store.
- [ ] The first user added to a new store gets id 3.
- [ ] Looking up the email `JAKE@conduit.test` in a new store returns the user `jake`.
- [ ] Looking up the username `Jake` in a new store returns no user.
- [ ] Looking up the slug `welcome-to-conduit` in a new store returns the article titled `Welcome to Conduit`.
- [ ] Looking up the slug `no-such-article` in a new store returns no article.

## Out of Scope

Any endpoint, token handling, input validation, slug generation and list paging. A persistent database, a reset endpoint and a way to change or delete a stored record are not added.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| BE | app | `backend/src/store.js`, `backend/src/seed.js`, `backend/src/app.js`, `backend/test/store.test.js` |

## Test User

None. This ticket has no endpoint and no page. A developer runs `npm test` in `backend/`.

## Labels

planned, INIT-0000000000-5702, chore, blocked-by:scaffold-packages

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
  "TargetSymbols": "BE_TEST_CMD:app/CLAUDE.md:46;backend:app/CLAUDE.md:53;createStore (new):app/backend/src/store.js;seed (new):app/backend/src/seed.js;createApp (new in scaffold-packages):app/backend/src/app.js;storeTest (new):app/backend/test/store.test.js",
  "Kind": "enabler",
  "Serves": [],
  "Enables": [
    "O1",
    "O2"
  ]
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|---|---|---|---|---|---|---|
| A new store lists exactly 2 users, `jake` then `jane`. | Developer | 2 `user` records in state seeded author (`jake`, `jane`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, `jake` has id 1. | Developer | 1 `user` in state seeded author `jake` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, `jane` has id 2. | Developer | 1 `user` in state seeded author `jane` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, `jake` has the email `jake@conduit.test`. | Developer | 1 `user` in state seeded author `jake` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, `jane` has the email `jane@conduit.test`. | Developer | 1 `user` in state seeded author `jane` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, `bio` is null for both seeded users. | Developer | 2 `user` records in state seeded author (`jake`, `jane`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, `image` is null for both seeded users. | Developer | 2 `user` records in state seeded author (`jake`, `jane`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| A bcrypt comparison of `Jake-Pass-123` with the stored hash of `jake` succeeds. | Developer | 1 `user` in state seeded author `jake` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| A bcrypt comparison of `Jane-Pass-123` with the stored hash of `jane` succeeds. | Developer | 1 `user` in state seeded author `jane` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| A bcrypt comparison of `wrong-password` with the stored hash of `jake` fails. | Developer | 1 `user` in state seeded author `jake` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| The stored password hash of each seeded user reports cost 10. | Developer | 2 `user` records in state seeded author (`jake`, `jane`) | seeded-by:store-and-seed |  | `getRounds` returns 10 for both hashes; the store test passes | yes |
| No user record in a new store holds the text `Jake-Pass-123`. | Developer | 2 `user` records in state seeded author (`jake`, `jane`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| No user record in a new store holds the text `Jane-Pass-123`. | Developer | 2 `user` records in state seeded author (`jake`, `jane`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| A new store lists exactly 2 articles, with the slugs `how-to-train-your-dragon` and `welcome-to-conduit`. | Developer | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, the article `how-to-train-your-dragon` has the title `How to train your dragon`. | Developer | 1 `article` in state seeded `how-to-train-your-dragon` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, the article `how-to-train-your-dragon` has `jake` as its author. | Developer | 1 `article` in state seeded `how-to-train-your-dragon` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, the article `how-to-train-your-dragon` has the `createdAt` value `2026-01-01T10:00:00.000Z`. | Developer | 1 `article` in state seeded `how-to-train-your-dragon` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, the article `welcome-to-conduit` has the title `Welcome to Conduit`. | Developer | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, the article `welcome-to-conduit` has `jane` as its author. | Developer | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, the article `welcome-to-conduit` has the `createdAt` value `2026-01-02T10:00:00.000Z`. | Developer | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, both seeded articles have the description `Seed article`. | Developer | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, both seeded articles have the body `Seed body text.` | Developer | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| In a new store, `updatedAt` equals `createdAt` for both seeded articles. | Developer | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| A user added to one store does not appear in a second store created before or after it. | Developer | 2 `user` records in state seeded author (`jake`, `jane`) | seeded-by:store-and-seed |  | the second store still lists exactly 2 users; the store test passes | yes |
| An article added to one store does not appear in a second store. | Developer | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | the second store still lists exactly 2 articles; the store test passes | yes |
| The first user added to a new store gets id 3. | Developer | 2 `user` records in state seeded author (`jake`, `jane`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| Looking up the email `JAKE@conduit.test` in a new store returns the user `jake`. | Developer | 1 `user` in state seeded author `jake` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| Looking up the username `Jake` in a new store returns no user. | Developer | 1 `user` in state seeded author `jake` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| Looking up the slug `welcome-to-conduit` in a new store returns the article titled `Welcome to Conduit`. | Developer | 1 `article` in state seeded `welcome-to-conduit` | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |
| Looking up the slug `no-such-article` in a new store returns no article. | Developer | 2 `article` records in state seeded (`welcome-to-conduit`, `how-to-train-your-dragon`) | seeded-by:store-and-seed |  | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | yes |

## Test Data Provided

The seed this ticket writes into every new store, and so into the API on every start:

- 2 `user` records in state seeded author: `jake` (`jake@conduit.test` / `Jake-Pass-123`, id 1) and `jane` (`jane@conduit.test` / `Jane-Pass-123`, id 2), both with `bio` and `image` null.
- 2 `article` records in state seeded: `how-to-train-your-dragon` (title How to train your dragon, author jake, createdAt `2026-01-01T10:00:00.000Z`) and `welcome-to-conduit` (title Welcome to Conduit, author jane, createdAt `2026-01-02T10:00:00.000Z`), both with description `Seed article` and body `Seed body text.`

Restarting the API (`npm start` in `backend/`) discards everything else and leaves exactly these records.

## Writes

| Key | Op |
|---|---|
| `user` | create |
| `article` | create |

## Reads

None.

## Preconditions

None.
