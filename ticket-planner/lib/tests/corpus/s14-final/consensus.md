# Consensus — INIT-0000000000-2767 (Conduit-lite)

The review found no blocker, two major findings and eight minor or nit findings. All ten are resolved below. The finalized plan is in `artifacts/proposal.md`. The edited specs are `backend-scaffold`, `user-accounts-api`, `articles-api`, `frontend-shell`, `sign-up-and-sign-in-pages`, `reader-pages`, `article-editor-page` and `conduit-repo-docs`.

## Findings Addressed

### F1 — major — Tie-break criterion fails when `Date` is frozen at its default — accepted

The tie-break test now freezes `Date` at a stated instant, `2030-01-01T00:00:00.000Z`, which is later than both seed articles. The two tie articles are then the two newest rows in the list. The `articles-api` Technical Context gives the exact call: `mock.timers.enable({ apis: ['Date'], now: Date.parse('2030-01-01T00:00:00.000Z') })`, followed by `mock.timers.reset()`.

- Changed criterion: "When `jake` creates `Tie one` then `Tie two` with `Date` frozen at `2030-01-01T00:00:00.000Z`, `GET /api/articles` returns `articles[0].slug` equal to `tie-two`".
- Added criterion: "When `jake` creates `Tie one` then `Tie two` with `Date` frozen at `2030-01-01T00:00:00.000Z`, `GET /api/articles` returns `articles[1].slug` equal to `tie-one`".
- The Verification Notes rows and Test Data Provided name the same instant. The proposal Risk Register row for wall-clock ordering names it as well.

### F2 — major — Browser criteria depend on a fresh backend, and nothing guarantees one — accepted

Each frontend spec now has a verification setup line in its Technical Context. Before each browser verification attempt, including every verify retry, the process on port 3000 is stopped and the backend is started again with `npm start` in `backend/`. A fresh start reseeds the 2 users and 2 articles and drops everything created at runtime. Then `npm run dev` runs in `frontend/`. The line is in `frontend-shell`, `sign-up-and-sign-in-pages`, `reader-pages` and `article-editor-page`. Each Test User section points to it and says what the restart protects: `newauthor` does not exist yet, the home page holds only the 2 seeded articles, and the published slug is `my-first-post`, not `my-first-post-2`.

- This is a verification precondition, not product behaviour, so no criterion was added for it. The existing criteria it protects are unchanged: "Signed out, the home page lists 2 article previews", "Submitting the sign-up form with username `newauthor` ... changes the address to `/`", and "Signed in as `jake`, publishing title `My first post` ... changes the address to `/article/my-first-post`".
- The setup runs `npm start` from `backend-scaffold`. `sign-up-and-sign-in-pages`, `reader-pages` and `article-editor-page` therefore now carry `blocked-by:backend-scaffold` directly, and their Technical Context names it. The proposal Work Breakdown, the DAG line and `specs/INDEX.md` were updated to match. This adds no new ordering constraint, because each of the three tickets already depended on `backend-scaffold` through its other blockers.
- A new Risk Register row records the in-memory storage and verify-retry hazard and its mitigation.

### F3 — minor — Scaffold spec drops the JSON 404 and JSON 500 handlers from architecture — accepted

Architecture choice 7 is restored. `backend-scaffold` now has a JSON 404 fallback, `{"errors":{"path":["not found"]}}`, and an exported `errorHandler`. The handler maps the parse error to 422 and every other error to 500 `{"errors":{"server":["unexpected error"]}}`. Two Parameters rows were added: `api.unknown_route` (404 path not found, source architecture "404 JSON fallback") and `api.unhandled_error` (500 server unexpected error, source architecture "Any other unhandled error"). Architecture does not state the 404 body key. `path` is a planner default and follows the brief's `{"errors":{"<field>":[...]}}` shape.

- Added criteria: "`GET /api/does-not-exist` on an app from `createApp()` returns the body `{"errors":{"path":["not found"]}}`"; "`GET /api/does-not-exist` on an app from `createApp()` returns a `Content-Type` header that starts with `application/json`"; "`GET /boom` on a test app whose only route throws `new Error('boom')`, with `errorHandler` mounted after it, returns status 500"; "... returns the body `{"errors":{"server":["unexpected error"]}}`".
- The Verification Notes rows for the two `/boom` criteria use Source `generate`, because the test builds that app itself.

### F4 — minor — Expired and unknown-id tokens are not tested on `POST /api/articles` — accepted

The narrowed coverage is not acceptable, because the brief asks for every error case on every endpoint. `articles-api` now lists all five 401 cases in its behaviour text. Its Technical Context says `POST /articles` sits behind the same `requireAuth` middleware that `GET /api/user` uses, and gives the token recipes (`expiresIn: -10`; `{ id: 9999, username: 'ghost' }` signed with the real secret).

- Added criteria: "`POST /api/articles` with a `jake` token whose `exp` is in the past returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`"; "`POST /api/articles` with a validly signed token for `id` 9999 returns status 401 with the body `{"errors":{"token":["is missing or invalid"]}}`".
- The proposal Risk Register auth-bypass row now names all five cases.

### F5 — minor — The scaffold's router shape conflicts with the store-passing design — accepted

The router contract is now explicit in `backend-scaffold`. `backend/src/routes/members.js` and `backend/src/routes/articles.js` each export a factory, `usersRouter(store)` and `articlesRouter(store)`, that returns a new `express.Router()` on every call. `createApp()` calls each factory once per app. A module-level shared `Router` is not allowed. In the scaffold ticket the store argument is `null`. `user-accounts-api` now says it passes `createStore()` to both factories in place of `null`. `articles-api` now says it adds its routes inside `articlesRouter(store)`. The proposal Risk Register row was corrected: it no longer claims that later tickets touch only their own files, and it names the earlier modules that `articles-api` extends. TargetSymbols names are unchanged (`usersRouter`, `articlesRouter`), so no sibling citation moved.

- No new criterion was added, because the factory shape is internal. The observable result, which is that apps do not share state, is checked by the existing `user-accounts-api` criterion "After registering `newauthor` then rebuilding the app, `POST /api/members/login` with email `newauthor@conduit.test`, password `New-Pass-123` returns status 401". The scaffold's own 404 and 422 criteria check that the mounted factories serve requests.

### F6 — minor — Browser-native form validation can hide the API errors under test — accepted

HTML validation attributes are not allowed on these inputs. `sign-up-and-sign-in-pages` and `article-editor-page` now state in Technical Context that the inputs have no `required`, `minlength`, `maxlength` or `pattern`. The `Email` inputs use `type="text"`. The proposal Technical Approach records the same rule. The existing criteria check this behaviour, because each one fails if the browser blocks the submit:

- `sign-up-and-sign-in-pages`: "Submitting the sign-in form with an empty email, password `Jake-Pass-123` shows the error `email can't be blank`" and "Submitting the sign-up form with an empty username, email `x@conduit.test`, password `Pass-123` shows the error `username can't be blank`".
- `article-editor-page`: "Signed in as `jake`, publishing an empty title, description `d`, body `b` shows the error `title can't be blank`" and "Signed in as `jake`, publishing an empty form shows an error list of 3 items".

### F7 — minor — `user-accounts-api` is large — rejected

The merge of architecture steps 2 and 3 stays. The store, seed, auth, error and serializer modules have no observable behaviour until the account endpoints exist. A separate core ticket could be verified only through tests of internal functions, which the acceptance checklist rules out. The ticket serves one outcome (O1) in one service, and all of its criteria run in `npm test`. The reason is now in the proposal Work Breakdown, and a Risk Register row records the critical-path size. No criterion changed.

### F8 — minor — No spec defines what happens when the session check cannot reach the API — accepted

Decision: any answer other than 200 or 401, including no answer at all, keeps `localStorage.jwt`. The header shows the signed-out state for that page load, and boot continues so the router renders the route. `session.init()` resolves instead of throwing. The rule is in `frontend-shell` Proposed Changes and Technical Context, and in the proposal Technical Approach. It is a spec rule, not a Parameters row: no upstream artifact states it, and it changes no stored data.

- Added criteria: "With the backend stopped and a `jake` token in `localStorage.jwt`, loading `/` shows a `Sign in` link in the header"; "With the backend stopped and a `jake` token in `localStorage.jwt`, loading `/` keeps `localStorage.jwt` equal to that token"; "With the backend stopped and a `jake` token in `localStorage.jwt`, opening `http://localhost:5173/no-such-page` shows the text `Page not found`".
- `frontend-shell` Writes and Reads are unchanged, because the kept-token path writes nothing.

### F9 — nit — `conduit-repo-docs` Signals do not match its Enables text — accepted

The Enables prose now reads `O1, O2, O3`, and Signals `Enables` is `["O1", "O2", "O3"]`. Signals `TargetSymbols` now includes `Backend (Conventions):app/CLAUDE.md:53-54`, so it lists 6 symbols and matches `symbols_resolved` and the proposal Target Symbols. No criterion changed.

### F10 — nit — The Q8/Q9 defaults were chosen without authorization — accepted

The override window is confirmed as acceptable. A person may change any planner default before tickets are created, and each default is one Parameters row or one spec sentence. The proposal Boundaries section now records this confirmation. No criterion changed.

## Changes from Original Proposal

- Parameters: added `api.unknown_route` and `api.unhandled_error`. No existing row changed.
- Technical Approach: added the router factory contract, the all-JSON error rule, the unreachable-session rule, the no-HTML-validation rule and the fresh-backend verification setup.
- Work Breakdown: `sign-up-and-sign-in-pages`, `reader-pages` and `article-editor-page` now name `backend-scaffold` as a direct blocker. The DAG line was updated. The reason for keeping `user-accounts-api` as one ticket was added.
- Risk Register: the router-mounting, auth-bypass and wall-clock rows were corrected. Rows were added for the fresh-backend hazard and for the size of `user-accounts-api`.
- Boundaries: the override window for planner defaults is confirmed.
- Specs: `backend-scaffold` has 4 new criteria (9 total). `articles-api` has 3 new criteria and 1 changed criterion (55 total). `frontend-shell` has 3 new criteria (27 total). `user-accounts-api`, `sign-up-and-sign-in-pages`, `reader-pages`, `article-editor-page` and `conduit-repo-docs` have changes to Technical Context, Test User, Labels or Signals only. Every criterion has one Verification Notes row.
- Business Outcomes O1–O3 are unchanged.

## Deferred Items

None. Every review finding was accepted or rejected with a reason.

## Open Questions

None from this phase. Discovery's Cited Artifacts list has no NOT FOUND entries, so no cited-artifact question applies.

## Readiness

ready-for-spec

## Goldfish Findings Addressed

Goldfish review: disabled
