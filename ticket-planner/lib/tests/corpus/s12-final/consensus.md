# Consensus — INIT-0000000000-5856

Inputs: `artifacts/proposal.md` (Specify version) and `artifacts/review.md` (verdict needs-revision, no blockers, 4 major, 5 minor, 2 nit). The finalized plan is in `artifacts/proposal.md`.

## Findings Addressed

### F1 — major — Work Breakdown dependencies disagree with the specs — accepted

The proposal now matches the spec set. Work Breakdown row 6 (`auth-pages`) lists `reader-pages` as a blocker, as `specs/auth-pages.md` and `specs/INDEX.md` already did. `## Technical Approach` has a new paragraph, "Shared new files and their owners", that names the owner of every shared new file. `frontend/src/errors.js` stays with `reader-pages`, because the article page's `article not found` message is its first user and is already checked there ("Opening `/article/placeholder-slug` shows the text "article not found""). No spec behaviour changed, so no acceptance criterion was added.

### F2 — major — No ticket or parameter says how the API is running during frontend browser verification — accepted

The four browser-verified specs (`frontend-shell`, `reader-pages`, `auth-pages`, `editor-page`) each have a new `## Environment` section. It says that the verifier runs `npm install` and `npm start` in `backend/` before `npm run dev` in `frontend/`. Each `## Navigation Path` now starts with the same step. The repository's pipeline configuration lines are not changed, so the Boundary holds. The proposal's `## Technical Approach` has a paragraph, "Running the app for browser verification", and `## Risk Register` has a row for the missing API, owned by each browser-verified ticket. This is a verification setup step, not product behaviour, so no acceptance criterion was added. The existing criterion "A browser request to `http://localhost:5173/api/user` with no token returns status 401 ..." in `frontend-shell` already fails when the API is down.

### F3 — major — Browser criteria assume a freshly seeded store, but the store is shared and mutated across tickets and retries — accepted

The same `## Environment` sections state the reset assumption: the store is seeded again only when the API starts, so each verification attempt, retries included, starts the API afresh and uses a browser profile with empty `localStorage`. The proposal's `## Risk Register` has a new row for shared server state (a second publish gets `my-first-post-2`; a second `alice` sign-up is rejected), owned by each browser-verified ticket. No criterion changed: the exact-count and exact-slug criteria stay correct under the stated reset. No `## Preconditions` row was added, because the preconditions grammar has no key for "fresh process start" and inventing one would fail Crosscheck. The assumption is carried in the Environment section instead.

### F4 — major — Frontend page chain is serialised with at least one false or unexplained dependency — accepted

The proposal now gives a reason for every page-to-page edge, in the `## Technical Approach` paragraph "Why the page tickets run in a chain". `auth-pages` after `reader-pages` is a file-ownership edge (`renderErrors` in `frontend/src/errors.js`, and the shared path table in `frontend/src/router.js`). `editor-page` after `reader-pages` and after `auth-pages` are behaviour edges (landing on the article page, the home page check, sign-in through the sign-in page, and the guard). The proposal states that this departs from architecture's parallel layout, and why. The same reasons were added to the `## Technical Context` of `specs/auth-pages.md` and `specs/editor-page.md`. No blocker was removed, so no acceptance criterion changed.

### F5 — minor — `frontend-shell` is classed as business but delivers no reachable user outcome on its own — rejected

The ticket ships the observable part of O2's outcome, "the app then shows them as signed in": the header's signed-in and signed-out states, the rejected-token fallback and deep-link loading, each with its own acceptance criterion. Re-classing it as an enabler would change its labels, its `## Outcome` section and O2's coverage, for no gain in what gets built or checked. The reliance on an API sign-in to reach the signed-in state is already stated in its `## Navigation Path`.

### F6 — minor — O2 has no measure even though the brief supplies one — accepted

O2's measure now cites the brief's Acceptance step "`jake` signs in": in the browser at `http://localhost:5173`, `jake` signs in, lands on `/`, and the header shows `jake` and a "New Article" link. The outcome id is unchanged. The measure is checked by existing criteria in `auth-pages` ("Signing in as `jake@conduit.test` with password `Jake-Pass-123` changes the address bar path to `/`", "After jake signs in, the header shows the text "jake"", "After jake signs in, the header shows a link with the text "New Article"").

### F7 — minor — No ticket owns repository hygiene for two new npm projects — accepted

`backend-foundation` now owns a repository-root `.gitignore` with the single line `node_modules/`, which covers both projects, and commits `backend/package-lock.json`. `frontend-shell` commits `frontend/package-lock.json` and relies on the root `.gitignore` (it is already blocked by `backend-foundation`). New acceptance criteria, each with a Verification Notes row:

- `backend-foundation`: "After `npm install` in `backend/`, `git status --porcelain` run at the repository root lists no path under `backend/node_modules/`" and "`git ls-files backend/package-lock.json` run at the repository root prints `backend/package-lock.json`".
- `frontend-shell`: "After `npm install` in `frontend/`, `git status --porcelain` run at the repository root lists no path under `frontend/node_modules/`" and "`git ls-files frontend/package-lock.json` run at the repository root prints `frontend/package-lock.json`".

### F8 — minor — Proposal-level Target Symbols mix unchanged constraint lines with change targets, and omit most new symbols — accepted

The proposal's `## Target Symbols` now lists every new symbol the specs create, plus the three repository-text lines `repo-docs-conduit` rewrites. The four pipeline-configuration lines (`LOCAL_URL`, `UAT_URL`, `BE_TEST_CMD`, `REPOS_ROOT`) were removed from it, and `## Boundaries` now says they are read-only constraints. The same read-only entries were removed from the `TargetSymbols` of `specs/frontend-shell.md` (`LOCAL_URL`, `UAT_URL`) and `specs/backend-foundation.md` (`BE_TEST_CMD`). They stay in `specs/repo-docs-conduit.md`, because that ticket edits `app/CLAUDE.md` and its criteria guard those lines. Their prose citations in each spec's `## Technical Context` are unchanged. No acceptance criterion changed.

### F9 — minor — `api.malformed_json` error field collides with the article `body` field — accepted

The `api.malformed_json` parameter now reads `422 with errors.request "is invalid"`. `specs/backend-foundation.md` was updated in its `## Proposed Changes`, its `## Technical Context` parameter list, the criterion "A `POST` to `http://localhost:3000/api/members` with header `Content-Type: application/json` and the body `{bad json` returns the body `{"errors":{"request":["is invalid"]}}`" and that criterion's Verification Notes row. No other spec held the old value.

### F10 — nit — "letters or digits" is undefined for non-ASCII titles — accepted

A new parameter row, `articles.slug_charset`, says that letters or digits means ASCII `a` to `z` and `0` to `9` after lower-casing. This is the class the `slugify` regex in `specs/articles-api.md` already used. The slug and empty-slug sentences in `specs/articles-api.md` now say "ASCII letters or digits", and the spec lists the new parameter. New acceptance criteria, each with a Verification Notes row: "`POST /api/articles` as jake with title `Café` returns `article.slug` equal to `caf`" and "`POST /api/articles` as jake with title `日本語` returns status 422 with body `{"errors":{"title":["is invalid"]}}`".

### F11 — nit — Express 5 path syntax for the `/api/*` 404 parameter — accepted

`specs/backend-foundation.md` `## Proposed Changes` now describes the 404 as a prefix handler mounted on `/api` after the routers, and says not to use a `*` route pattern, which Express 5 rejects at start-up. The proposal's `## Technical Approach` says the same. The `api.unknown_route` parameter value never held a route pattern, so it is unchanged. Behaviour is unchanged, and the existing criteria for `GET http://localhost:3000/api/no-such-route` (status 404 and body `{"errors":{"route":["not found"]}}`) check it.

## Changes from Original Proposal

- **Business Outcomes:** O2 has a measure from the brief (F6). O1 and O3 are unchanged; no id was added, removed or renumbered.
- **Parameters:** `api.malformed_json` Value changed to `errors.request` (F9). Four rows added: `articles.collision_scope` and `articles.tie_order` (architecture defaults 8 and 9, listed under the review's "Missing from Proposal"), `articles.slug_charset` (F10) and `api.express_major` (architecture default 1, same list). No `human:` row exists or was changed.
- **Technical Approach:** new paragraphs for shared-file ownership (F1), the reason for each page-to-page edge (F4) and how the API runs during browser verification, including the empty-profile assumption that the signed-out checks rely on, since there is no "Sign out" control (F2, F3, architecture default 14). It also covers the `request` error key (F9), the `/api` prefix 404 (F11) and the `.gitignore` and lockfile policy (F7).
- **Work Breakdown:** `auth-pages` row now lists `reader-pages` as a blocker (F1).
- **Target Symbols:** complete new-symbol list, constraint lines removed (F8).
- **Risk Register:** four new rows: API not running during browser checks (F2), shared server state (F3), host Node version (discovery runtime observation), and the end-to-end acceptance run (deferred).
- **Specs edited:** `backend-foundation` (F7, F8, F9, F11; 2 criteria added, 1 changed), `frontend-shell` (F2, F3, F7, F8; 2 criteria added), `reader-pages` (F2, F3), `auth-pages` (F2, F3, F4), `editor-page` (F2, F3, F4), `articles-api` (F10 and architecture default 9; 3 criteria added: the `Café` slug, the `日本語` title, and "`npm test` in `backend/` reports a passing list-order test in which two articles stored with the same `createdAt` are listed with the later-inserted one first"). `user-auth-api`, `repo-docs-conduit` and `INDEX.md` are unchanged.
- **Behaviour walk:** every behaviour sentence added or changed in `articles-api` (ASCII slug class, ASCII empty-slug rule, equal-`createdAt` order) and in `backend-foundation` (`request` error key, `.gitignore`, backend lockfile) maps to a criterion above. The `frontend-shell` lockfile and ignore sentence maps to its two new criteria. The `## Environment` and dependency-reason text adds no product behaviour.
- The citation linter (`planner_crosscheck_citations`) and the parameter linter (`planner_crosscheck_params`) both pass after the edits.

## Deferred Items

- **End-to-end acceptance run on one server** (review "Missing from Proposal", architecture Dependency Order step 6). Each step of the brief's Acceptance section is owned by one ticket. A combined run across tickets is an epic-level integration check, not a ticket of its own. It is recorded as a Risk Register row. It interacts with F3: a combined run must also start from a fresh API.
- **A precondition key for "fresh API start"** (part of F3). The assumption is stated in each browser spec's `## Environment` section. A structured precondition would need a new key in the preconditions grammar, which is outside this phase.

## Open Questions

None from this phase. Discovery listed no cited artifact it could not retrieve, so there are no cited-artifact questions.

## Readiness

ready-for-spec

## Goldfish Findings Addressed

Goldfish review: disabled
