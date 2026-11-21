# Consensus — INIT-0000000000-9899

**Subject:** Conduit-lite sign-up, login and articles
**Inputs:** `artifacts/proposal.md` (Specify version), `artifacts/review.md` (verdict needs-revision, no blockers), `artifacts/specs/*.md`
**Output:** `artifacts/proposal.md` (finalized), edited specs, this digest.

## Findings Addressed

### F1 — major — Browser verification needs two live servers and a fresh store; neither is planned — accepted

Every frontend spec (`frontend-shell`, `frontend-read-pages`, `frontend-auth-pages`, `frontend-editor`) now has the same Navigation Path step 1: before every verification attempt, including a retry, stop any process on port 3000 or 5173, then start the API (`npm install`, `npm start` in `backend/`) and the app (`npm install`, `npm run dev` in `frontend/`) from the ticket's branch checkout, and check the app at `http://localhost:5173`. The restart re-seeds the in-memory store. The "restart the API before repeating" notes in the Test User sections of `frontend-auth-pages` and `frontend-editor` now point at that step, so a retry signs up `alice` again and publishes to `my-first-post` again. The proposal's Technical Approach has a "Verification of frontend tickets" paragraph, and the Risk Register has a row for stale-state retries. No acceptance criterion changed: the setup is a verification procedure, not product behaviour. Whether the verify environment allows the agent to stop and start these processes, and whether it targets port 5173, is an environment fact this phase cannot confirm, so it is raised under Open Questions.

### F2 — major — No shared contract for adding records to the store — accepted

`backend-foundation` now defines the store's single write interface. `insertUser(fields)` and `insertArticle(fields)` give each new record the next integer id from a per-kind counter and return the stored record. `reset()` empties the existing arrays in place, so their identity never changes, refills them from the seed and sets the counters so the next id is 3. Seed ids are stated. New criteria in `backend-foundation`: "After `store.reset()`, `store.insertArticle` returns a new `article` record with `id` 3", "After `store.reset()`, `store.insertUser` returns a new `user` record with `id` 3", and "A reference to `store.articles` taken before `store.reset()` holds 2 `article` records after the reset", each with a Verification Notes row. `api-user-auth` (registration), `api-article-create` (create) and `api-article-reads` (the extra test articles) now name these functions in Technical Context and in `TargetSymbols` with the `(new in backend-foundation)` marker. Writes and Reads tables are unchanged: the keys and ops written are the same.

### F3 — major — The skip-worktree procedure on `CLAUDE.md` is risky for an unordered ticket — accepted

`docs-conduit-description` no longer clears or sets the flag. It never runs `git update-index` on `CLAUDE.md` and never edits the operator clone's working copy. It edits and commits in a separate git worktree created from the base branch, where `CLAUDE.md` is the committed file with no flag and no local path edits. The ticket is also sequenced last: it is now blocked by `api-user-auth` and `frontend-editor`, so it is never active at the same time as other tickets in this initiative. New criteria: "The committed `CLAUDE.md` still names `REPOS_ROOT` as `~/repos`" and "After this ticket's commit, `git ls-files -v CLAUDE.md` in the operator's `app` clone still starts with `S`", each with a Verification Notes row. The Risk Register row for the `CLAUDE.md` edit now records the worktree rule and the sequencing.

### F4 — major — Proposal Target Symbols are malformed and incomplete — accepted

The proposal's `## Target Symbols` is now the union of every spec's `TargetSymbols`, all in `symbol:path` form, covering the backend, the frontend and the docs. The docs entries now point at `CLAUDE.md:7`, `CLAUDE.md:15` and `README.md:2`. They use the symbols `Purpose`, `Calculator` and `calculator`, which the citation linter finds in those lines. The same fix applies to `docs-conduit-description`'s Signals. The citation linter passes on all 10 files. No acceptance criterion changed.

### F5 — minor — Parallel backend tickets both edit `createApp()` — accepted

The overlap is recorded, but the order is unchanged. `api-article-reads` Technical Context says that `api-user-auth` also adds a mount line in parallel, and that the second branch to merge keeps both lines. The proposal records this under the Work Breakdown and adds a Risk Register row. No acceptance criterion changed: both tickets already have criteria that their endpoints answer.

### F6 — minor — `frontend-shell` has an avoidable dependency on `api-article-reads` — accepted

The edge is removed. `frontend-shell` is now blocked by `backend-foundation` and `api-user-auth` only, in its Labels, the proposal Work Breakdown and INDEX.md. These three lists now agree. The proxy criterion now reads "With the API running, a browser request without a token to `/api/user` on port 5173 returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`", replacing the `/api/articles` criterion, and its Verification Notes row changed with it. `article.slug` is removed from `frontend-shell`'s Reads because the ticket no longer touches article data. Its Technical Context no longer cites the article endpoints.

### F7 — minor — `frontend-shell` AC goes stale once home is replaced — accepted

The shell's placeholder headings are now named ("Home", "Article", "Sign up", "Sign in", "Editor"). The shell criterion now reads "Opening `/no-such-page` directly on port 5173 shows the heading "Home"", which is checked when the shell is verified. `frontend-read-pages` gets the version that still holds after the home page exists: a new behaviour sentence ("Opening an address the app does not know, such as `/no-such-page`, shows the home page with its article previews") and a new criterion "Opening `/no-such-page` directly on port 5173 shows 2 article previews", with a Verification Notes row.

### F8 — minor — Untested behaviour that downstream tickets depend on — accepted

`backend-foundation` now names its helpers. `validationError(res, fields)` and `sendError(res, status, field, message)` are in `errors.js`. The final error handler is exported as `errorHandler` and answers status 500 with `{"errors":{"server":["unexpected error"]}}`. `server.js` calls `store.reset()` before it listens and prints `Seeded 2 users and 2 articles`. New criteria, each with a Verification Notes row:

- "While `npm start` runs in `backend/`, a POST to `/api/no-such-route` with `Content-Type: application/json` and the body `{not json` gets status 404" checks the parse shim.
- The `validationError` criterion (status 422 with both fields blank).
- The `sendError` criterion (status 404, `article`, `not found`).
- The `errorHandler` criterion (status 500 body).
- "Running `npm start` in `backend/` prints `Seeded 2 users and 2 articles`" checks the seed-on-start sentence, which had no criterion before.

`api-article-create` gets "Creating an article with a valid token for user `id` 999 returns status 401 with `{"errors":{"token":["is missing or invalid"]}}`", with a Verification Notes row and a Test Data Provided entry.

### F9 — minor — Frontend behaviour when the API is unreachable or rejects a token mid-session — deferred

(b) is partly accepted. `frontend-editor` already said that a 401 from the create call is shown as "token is missing or invalid", but nothing tested it. It now has the criterion "Signed in as `jake`, with `jwt` replaced by `not-a-valid-token` after the editor opens, publishing shows the error line "token is missing or invalid"", with a Verification Notes row and a Test Data Provided fixture. Clearing the token at publish time, and the header state when the API is unreachable on boot (a), are deferred. Both are listed as accepted gaps in the Risk Register's assumption row. See Deferred Items.

### F10 — nit — `frontend-shell` is labelled business but delivers no outcome by itself — accepted

`frontend-shell` is now Kind `enabler`. Its `## Outcome` block became `## Enables` (O1, O4), and its Signals now show `Kind: enabler`, `Serves: []` and `Enables: ["O1","O4"]`. The proposal Work Breakdown and INDEX.md also say `enabler`. No business outcome was added, removed or renumbered, and no other spec's Serves or Enables changed.

### F11 — nit — Docs ticket documents behaviour that may not exist yet — accepted

`docs-conduit-description` is now blocked by `api-user-auth`, which adds the `JWT_SECRET` / `conduit-dev-secret` signing that the README note describes. It is also blocked by `frontend-editor` (see F3), so it runs last, as Architecture intended. Its Technical Context says why. No acceptance criterion changed for this finding.

### F12 — nit — Copy-paste Signals — accepted

`symbols_resolved` in every spec now equals the number of entries in that spec's `TargetSymbols`: backend-foundation 9, api-user-auth 5, api-article-reads 5, api-article-create 5, frontend-shell 5, frontend-read-pages 3, frontend-auth-pages 3, frontend-editor 3, docs-conduit-description 3. The `complexity` values were left as Specify set them, because they already differ by spec. No acceptance criterion changed.

**Missing from Proposal (review section):** these items were accepted.

- The Risk Register now has rows for the deep link to `/article/<slug>` and for slow tests from bcrypt cost 10, both from Architecture.
- The Node runtime is now the `fixed` Parameter `runtime.node.version` (discovery-sourced) and is named in `backend-foundation`. A Risk Register row records that the lockfiles pin `express`, `jest` and `vite`.
- Architecture choices #10–#12 and #16–#19 are now Parameters with architecture-quoted sources: `auth.email.compare`, `auth.username.compare`, `auth.token.scheme`, `articles.list.author_match`, `articles.list.tie_break`, `articles.create.timestamps` and `request.body.malformed_json`. The specs that use them name the keys in Technical Context. Existing rows are unchanged.
- The note on sign-out and the signed-out walkthrough was added to the Risk Register's assumption row: that step starts from a cleared `localStorage`.

## Changes from Original Proposal

- Work Breakdown:
  - Row 5 (`frontend-shell`) is now `enabler`, blocked by `backend-foundation` and `api-user-auth`. It no longer waits for `api-article-reads`.
  - Row 9 (`docs-conduit-description`) is now blocked by `api-user-auth` and `frontend-editor`.
  - A note records the shared `createApp()` mount lines and why docs runs last.
- Technical Approach:
  - The store has a single write interface (`insertUser`, `insertArticle`), and `reset()` keeps the arrays' identity.
  - The named error helpers are `validationError` and `sendError`, plus `errorHandler` with a status 500 body.
  - The server seeds the store before it listens.
  - The docs edit is made in a separate worktree.
  - A new paragraph says how frontend verification starts both servers on every attempt.
- Parameters: 8 new rows (7 `policy` rows sourced from Architecture, 1 `fixed` row sourced from Discovery). No existing row changed, and there are no `human:` rows.
- Target Symbols: rewritten as the union of the spec symbols in `symbol:path` form.
- Risk Register:
  - New rows: stale-state verify retries, the parallel `createApp()` mount lines, id allocation, the deep link, bcrypt test cost, and unpinned versions.
  - The `CLAUDE.md` row is rewritten.
  - The assumption row now lists the F9 gaps and the signed-out walkthrough note.
- Specs edited: all nine, plus INDEX.md. Every behaviour sentence added or changed has a criterion and a Verification Notes row: F2, F3, F6, F7, F8 and F9(b) above. Business Outcomes O1–O4 are unchanged.

## Deferred Items

- **F9 (a): header state when the API is unreachable on boot.** With a stored `jwt`, if `GET /api/user` fails with a network error or a 5xx, this slice does not specify whether the token is kept or which header shows. Specifying it would add a stop-the-API browser check to `frontend-shell`. That case is outside the brief's acceptance walkthrough, which always runs with the API up. It is recorded as an accepted gap.
- **F9 (b), second half: clearing a token that is rejected at publish time.** The editor shows "token is missing or invalid", but the token stays stored until the next app boot, which clears it under `frontend.session.stale_token`. Clearing it from the editor would give `browser_session.jwt` a second writer for the same transition that `frontend-shell` owns. The case only happens when a token outlives its author's id. It is recorded as an accepted gap rather than moving ownership for an edge case.

## Open Questions

- **Verify environment for frontend tickets (F1).** The frontend specs require the verifier to stop anything on ports 3000 and 5173 before every attempt and start the API and the Vite app from the ticket's branch checkout, then check `http://localhost:5173`. Can the pipeline's verify step on the app host do this, and does the environment's `LOCAL_URL` for this repo point at `http://localhost:5173`? If it cannot, the frontend tickets' retries will fail on `alice` and `my-first-post` by design. This needs an operator answer before the frontend tickets are dispatched, not before ticket generation.

## Readiness

ready-for-spec

All four major findings are resolved in the proposal and specs. No blocker was raised. The one open question concerns the verify environment for the frontend tickets, and it does not change any spec. The citation linter, parameter check, ownership check, AC coverage and AC-precondition checks were run after the last edit and pass.

## Goldfish Findings Addressed

Goldfish review: disabled
