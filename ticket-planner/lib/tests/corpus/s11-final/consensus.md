# Consensus — INIT-0000000000-5252 (Conduit-lite)

The review's verdict was needs-revision, with two major findings (F1, F2) and no blocker. All thirteen findings are accepted. The plan keeps its nine tickets and its scope. The main addition is `scripts/env-start.sh` in `app`. The pipeline's verify step needs this script to bring the app stack up, and because the script always restarts the backend, every verify attempt starts from the seed data.

## Findings Addressed

### F1 — major — Browser verification has no working way to start the stack — accepted

The verify step runs `env-start.sh` from the workspace root and waits for it to exit (`ticket-verify` Step 1.6b, `verify-env-up.sh`). The proposal did not provide one. Changes:

- `backend-scaffold` now creates `scripts/env-start.sh`. The script ignores its arguments and serves the checkout named by `VERIFY_REPO_PATH_APP`. It always restarts the backend on port 3000, installs packages when `node_modules/` is missing, and waits until `/api/unknown` answers 404. When the backend cannot start, it prints `backend did not start on port 3000` and exits 1. New criteria in `backend-scaffold`:
  - the script exits 0 with nothing on port 3000;
  - port 3000 answers 404 afterwards;
  - a second run leaves a different process ID on port 3000;
  - the script exits 0 with `backend/node_modules/` deleted;
  - the script exits 0 with the verify step's `--restart app gateway-fe` arguments;
  - the port 3000 process runs from the clone that `VERIFY_REPO_PATH_APP` names;
  - the script prints `frontend: skipped` while no `frontend/package.json` exists;
  - with `backend/server.js` deleted, the script exits 1;
  - with `backend/server.js` deleted, the script prints `backend did not start on port 3000`.
- `frontend-scaffold` replaces the `frontend: skipped` step with the same start sequence for `npm run dev` on port 5173. New criteria in `frontend-scaffold`:
  - port 5173 answers 200 after the script;
  - `/api/unknown` through port 5173 answers 404 after the script;
  - the script prints no `frontend: skipped`;
  - a second run leaves a different process ID on port 5173;
  - the script exits 0 with `frontend/node_modules/` deleted;
  - the port 5173 process runs from the clone that `VERIFY_REPO_PATH_APP` names;
  - with the `dev` script set to `exit 1`, the script exits 1;
  - with the `dev` script set to `exit 1`, the script prints `frontend did not start on port 5173`.
- Several specs now name the script in their Signals as `envStart (new in backend-scaffold)`: `backend-auth`, `backend-articles-publish`, `frontend-scaffold`, `frontend-reading-pages` and `frontend-editor`. Each of them already carried `blocked-by:backend-scaffold`.
- The workspace-root `env-start.sh` sits under `REPOS_ROOT`, outside every repo, so no ticket can commit it. It is a one-line wrapper that the operator installs (see Open Questions).
- The Risk Register row that credited the `repo-docs` documentation row is restated. A second row covers a missing wrapper. `repo-docs` now says its row is documentation for agents only.
- New parameter `env.start_timeout` (duration, 60 seconds). Both scaffold specs name it in their Technical Context.

### F2 — major — An in-memory backend makes browser criteria fail when they run a second time — accepted

Because the script from F1 always restarts the backend, each verify attempt starts with only the seed data. Every affected spec now states that start state as an action the verifier can take:

- `frontend-auth-pages`: the Navigation Path starts each attempt from a stack started by `bash scripts/env-start.sh` and registers `alice` once per attempt. The two `alice` sign-up Verification Notes rows now name their test data: 2 `user` records (`jake`, `jane`) and no `alice`, from a backend that `bash scripts/env-start.sh` restarted at the start of the attempt.
- `frontend-reading-pages`: the row for "Signed out, opening `http://localhost:5173/` shows exactly 2 article previews" replaces "on a freshly started backend" with the same restart action and "no other article". The Technical Context notes that no criterion in this ticket publishes.
- `frontend-editor`: the row for "publishing title `My first post` … changes the address bar to `http://localhost:5173/article/my-first-post`" now names the restart action and "no `my-first-post`". The Technical Context and Navigation Path say the criteria run in the listed order on one backend start, so the second `My first post` lands on `my-first-post-2`.
- `backend-auth`: the restart criterion now reads "After `alice` registers against the backend that `bash scripts/env-start.sh` started, and the script then runs again, `POST /api/members/login` with email `alice@conduit.test` and password `Alice-Pass-123` returns status 401". Its Navigation Path no longer offers ad hoc live registration against `npm start`.
- `backend-articles-publish`: the restart criterion now reads "After `jake` publishes `My first post` against the backend that `bash scripts/env-start.sh` started, and the script then runs again, `GET /api/articles/my-first-post` returns status 404". Its Navigation Path changes the same way.

### F3 — minor — The error-handling decision was dropped between Architecture and the specs — accepted

The handler from Architecture option A is restored in `backend-scaffold`, and the input cases now have owners:

- `backend-scaffold`: `app.js` adds a 404 handler with the body `{"errors":{"route":["not found"]}}`, and an error handler that turns a malformed JSON body into 400 `{"errors":{"body":["is not valid JSON"]}}`. New criteria: "a GET request to `http://localhost:3000/api/unknown` receives the body `{"errors":{"route":["not found"]}}`", "a POST … with body `{bad` receives status 400", and "… receives the body `{"errors":{"body":["is not valid JSON"]}}`". The smoke test asserts both.
- `backend-auth`: the handlers read `(req.body && req.body.user) || {}`. A missing `user` object, or no body at all, counts as every field blank. New criteria: "`POST /api/members` with body `{}`, which has no `user` object, returns status 422 …" (three keys), "`POST /api/members` with no request body and no `Content-Type` header returns status 422 …" (three keys), and "`POST /api/members/login` with body `{}` … returns status 422 …" (two keys).
- `backend-articles-publish`: the same rule applies to the `article` object. New criterion: "`POST /api/articles` as `jake` with body `{}`, which has no `article` object, returns status 422 …" (three keys).

### F4 — minor — Criteria depend on routes that are not registered yet, and unmatched routes are undefined — accepted

`frontend-scaffold` owns the router, so it now defines unmatched-route behaviour: the header stays and the main area shows "Page not found". Until the page tickets land, this is what `/login` and `/editor` show, so the scaffold's `/login` header criterion and the `frontend-auth-pages` "New Article" criterion no longer depend on undefined behaviour. New criteria in `frontend-scaffold`: "Opening `http://localhost:5173/settings` shows the text "Page not found"" and "Opening `http://localhost:5173/settings` shows the header "Sign in" link".

### F5 — minor — Target Symbols in the proposal are incomplete and partly contradict the specs — accepted

The proposal's `## Target Symbols` is now the union of the specs' Signals. It adds `errors.js`, `serializers.js` (`toUserJSON` and `toArticleJSON`), every backend test file, `scripts/env-start.sh` and every frontend module. The contradictory `Build:app/CLAUDE.md:42-44` entry is gone from both the proposal and `repo-docs`, because those lines must stay byte-identical. `repo-docs` now targets the lines it changes, including `empty:app/CLAUDE.md:54` (see F11). The Technical Approach now names `serializers.js`. The `backend-articles-read` → `backend-auth` edge stays: the seed articles need the seed users' `id`, and that part of the edge is genuine.

### F6 — minor — Parallel tickets edit the same frontend files — accepted

Two changes:

- `frontend-scaffold` defines one route list in `src/main.js`. Each page ticket adds its own `addRoute` lines there. `frontend-auth-pages`, `frontend-reading-pages` and `frontend-editor` each say this in their Technical Context.
- `frontend-reading-pages` now carries `blocked-by:frontend-auth-pages`, because its Technical Context builds on the route list and `src/api.js` as `frontend-auth-pages` leaves them. The two tickets therefore never edit those files on parallel branches.

The proposal's Work Breakdown and `specs/INDEX.md` now show the new order, 1 → (2, 5, 9) → (3, 6) → (4, 7) → 8. This change adds no criterion: it changes the order of work, not what the app does.

### F7 — minor — Some criteria may not be reachable, depending on implementation — accepted

Native browser validation is now forbidden. In `frontend-auth-pages` and `frontend-editor`, forms carry `novalidate`, no field has `required`, `minlength` or `pattern`, and the email input is `type="text"`. The existing blank-field criteria check this rule, because they fail if the browser blocks the submit: "On `/login`, submitting an empty email … shows the text "email can't be blank"", "On `/register`, … an empty password shows the text "password can't be blank"", "publishing with an empty title shows the text "title can't be blank"" and "publishing with an empty body shows the text "body can't be blank"". The Technical Context of both specs says so.

### F8 — minor — Ambiguous or under-specified test criteria — accepted

- `backend-articles-publish`: the page-size criteria now read "Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles, `GET /api/articles` with no query returns an `articles` array of length 20" and "… returns `articlesCount` equal to 21". The test data names the 19 titles, `Article 1` to `Article 19`.
- `backend-auth`: `JWT_SECRET` is now read inside `signToken` and `requireAuth` on every call, never at module load. The two secret tests save the variable, set or delete it, and restore it afterwards, so one Jest run tests both cases and the host's own value never decides the result. The Proposed Behaviour says the secret is read each time a token is signed or checked. The criteria "With `JWT_SECRET` unset, the token from a `jake` login verifies with the secret `conduit-dev-secret`" and "With `JWT_SECRET=test-secret` set, … verifies with the secret `test-secret`" check this, and their Verification Notes rows now say both run in the same `npm test` run.
- The restart criteria are now live checks that run `bash scripts/env-start.sh` again (see F2), not `store.reset()`.

### F9 — minor — A known ordering risk was dropped, and its mitigation does not work — accepted

`backend-articles-publish` now makes each new `createdAt` later than every existing `createdAt`. When the clock has not moved past the newest one, it adds 1 ms, so the newest-first sort in `backend-articles-read` never meets a tie. New criteria: "Starting from a store holding only the 2 seed articles, after `jake` publishes 19 articles back to back with no delay, the 20 items `GET /api/articles` returns with no query have 20 distinct `createdAt` values" and "… `articles[0].title` in the `GET /api/articles` response equals the title of the 19th article published". The "Ordering ties in the article list" risk is back in the Risk Register with this mitigation.

### F10 — minor — The CLAUDE.md protection criterion is weaker than the risk it covers — accepted

`repo-docs` criteria now cover both added and removed lines, and the row's position:

- "`git diff --numstat 200f5a4 -- CLAUDE.md` in `app` reports exactly 3 removed lines".
- "… reports exactly 4 added lines".
- "In `CLAUDE.md`, the line directly after the `FE type check` row is the row whose command is `npm start` (run from `backend/`)".

The existing criterion about removed lines now also allows the Conventions line from F11. With exact counts, an extra line added anywhere, for example next to `BE_TEST_CMD`, fails.

### F11 — nit — Wording that goes stale is not addressed — accepted

Both statements become false once `backend-scaffold` lands, and the pipeline reads this file before every ticket, so both change:

- `repo-docs` drops the "intentionally empty at the start" clause from line 7 and keeps the statement that `user Sandbox` Linear tickets drive development.
- It rewrites line 54 to "The pipeline builds the app ticket by ticket in `backend/` and `frontend/`."
- Line 53 stays byte-identical. The proposal's out-of-scope line now protects "Conventions line 53" instead of all of Conventions.

New criteria: "`grep -c "empty at the start" CLAUDE.md` in `app` prints `0`" and "The `CLAUDE.md` Purpose paragraph contains the text `user Sandbox`".

### F12 — nit — O1's Measure does not measure O1's Outcome — accepted

O1's Measure is now: "In the browser at `http://localhost:5173`, `jake` signs in and the header shows `jake`; a new author `alice` signs up and the header shows `alice`." The O1 id and its Outcome text are unchanged, so no spec's `Serves` or `Enables` changes. The `frontend-auth-pages` criteria already check this Measure: "After `jake` signs in, the header shows the text `jake`" and "After `alice` signs up, the header shows the text `alice`". The brief's backend-suite criterion is still covered by the backend tickets' `npm test` criteria.

### F13 — nit — No sign-out, but criteria need a signed-out browser after sign-in — accepted

The reset step is now written down. The verifier runs `localStorage.removeItem('jwt')` in the page and reloads:

- `frontend-editor`: in the Navigation Path, and in the Verification Notes row for "Signed out, opening `http://localhost:5173/editor` changes the address bar to `http://localhost:5173/login`".
- `frontend-auth-pages`: in the Navigation Path, and in the rows for the wrong-password, blank-email and every `/register` criterion. These run after `jake` has signed in, and the signed-in header hides "Sign in" and "Sign up".
- `frontend-reading-pages`: in the Navigation Path, and in the "exactly 2 article previews" row.

## Changes from Original Proposal

- **New deliverable:** `scripts/env-start.sh`. `backend-scaffold` creates it with the backend half and `frontend-scaffold` adds the frontend half. It is the repo side of the verify step's stack start, and it always restarts both servers. Scope and Technical Approach are updated. The out-of-scope "root process manager" line now says this script is not one.
- **Backend error envelope:** JSON 404 for unknown `/api` routes and JSON 400 for malformed bodies (`backend-scaffold`). A missing `user` or `article` object counts as blank fields (`backend-auth`, `backend-articles-publish`).
- **Timestamps:** each new `createdAt` is later than every existing `createdAt` (`backend-articles-publish`).
- **Frontend:** "Page not found" for unmatched paths and one route list in `src/main.js` (`frontend-scaffold`). No native form validation (`frontend-auth-pages`, `frontend-editor`).
- **Dependency:** `frontend-reading-pages` is now blocked by `frontend-auth-pages`.
- **`repo-docs`:** also changes `CLAUDE.md` line 54 and the empty-repo clause on line 7. Its diff criteria now check exact added and removed counts and the position of the new row.
- **Business Outcomes:** O1's Measure is replaced (F12). Ids, Who, Need and Outcome texts are unchanged.
- **Parameters:** two new rows, `articles.seed_updated_at` (from Architecture) and `env.start_timeout` (60 seconds, tuning default). No existing row changed.
- **Target Symbols:** the union of the specs' Signals. The `CLAUDE.md:42-44` entry is removed.
- **Risk Register:** the verification row is restated. New rows: missing workspace wrapper, leftover in-memory data, ordering ties, bcrypt cost, slug collision race, parallel frontend edits, and native form validation.

## Deferred Items

- **Day-to-day developer convenience.** `scripts/env-start.sh` is built for the verify step: it always restarts and kills whatever holds ports 3000 and 5173. A gentler start command for developers was not added, because the brief does not ask for one and the scope stays literal.
- **Transitive `blocked-by` edges.** `frontend-editor` lists blockers that are also reachable through its other blockers. They are kept on purpose, because the readiness evaluator reads one ticket at a time.
- **Purpose of the slice (baseline or release).** The brief still does not say. The plan follows the brief literally, as before.

## Open Questions

- The pipeline's verify step runs `env-start.sh` from its tickets root, which for this workspace appears to be `REPOS_ROOT` (`~/work/e2e-conduit`). That file is outside every repo, so no ticket can create it. Will you install this one-line wrapper there before the first verify run: `exec bash "${VERIFY_REPO_PATH_APP:-~/work/e2e-conduit/app}/scripts/env-start.sh" "$@"`? If the verify step uses a different tickets root for this workspace, put the wrapper there instead. Without it, the live and browser criteria in every ticket stop at the stack start.

## Readiness

ready-for-spec

All thirteen findings are resolved in the proposal and specs. The wrapper in Open Questions is an operator setup step outside the repos. It does not block spec or ticket generation, but it must be in place before the first verify run.

The `repo-docs` criteria act on the repository's own `CLAUDE.md` and `README.md`, which the ticket itself edits, so they need no prepared data:

TESTDATA_CONFIRM: `repo-docs` [0fc6f2f6] — Answer: none

## Goldfish Findings Addressed

Goldfish review: disabled
