# Consensus — INIT-0000000000-5702

**Subject:** Conduit-lite sign-up, login and articles
**Resolves:** `artifacts/review.md` (verdict needs-revision, no blocker, 14 findings)
**Result:** 12 findings taken up, 2 turned down with a reason. The plan keeps eight tickets.

## Findings Addressed

### F1 — major — Tickets 6 and 7 are declared independent but both write `frontend/src/router.js` — accepted

The parallel claim is withdrawn. The proposal now states one rule for both packages: two tickets that edit one file never run at the same time.

The sign-in and sign-up pages ticket now carries `blocked-by:read-pages`, so the three tickets that edit the route table run in the order read pages, sign-in and sign-up pages, editor page. Its Technical Context says why, and its Signals list the home page file as new in the read pages ticket. `INDEX.md` and the Work Breakdown table show the new edge.

No acceptance criterion changed: the edit is an ordering fact, not a behaviour.

### F2 — major — Server lifecycle between ticket verifications is not owned by any ticket or risk row — accepted

Decision: each frontend ticket owns the fresh start of its own verification. No stop script is added, because the repository has no process manager and the intent asks for none.

The rule is written once in the proposal (Technical Approach, "Verification environment") and repeated where a verifier reads it: the Navigation Path of each of the four frontend specs now starts with "Stop any process that is listening on port 3000, then start the API", and names the message `Port 3000 is already in use` as the sign that an older API is still serving. Each spec's Technical Context says that the API does not reload its code and keeps its data.

R1 now covers every browser check that changes data, not only the walk: the second publish of "My first post", the second sign-up of `newauthor`, the `<b>bold</b>` user, and the `<b>bold</b>` article that makes the home page hold 3 articles. R2 now has a mitigation for the stale process.

The read pages spec states the order of its own checks: the two `<b>bold</b>` checks run after every seed-only check, and their Verification Notes rows say so in the Test data cell. The frontend shell spec's `<b>bold</b>` row says the account is created on an API started fresh for the ticket.

No acceptance criterion changed. The edits are verification steps and test-data cells; the criteria that need a fresh API already begin "On a freshly started API".

### F3 — major — `article-endpoints` is oversized — rejected

The ticket stays one ticket. The content of its criteria was not questioned.

Reasons, now in the proposal's Work Breakdown notes: both halves of a split would edit `backend/src/routes/articles.js`, so they would run one after the other; the read pages ticket needs the list endpoint and the read-one endpoint together, and the editor page ticket needs the read pages ticket, so no later ticket could start sooner; the criteria are short HTTP checks on one router, one serializer and one test setup. A split made after Specify also changes the recorded spec list, which stops Crosscheck for a manual scope audit.

The size is recorded as risk R16. The ticket has 71 criteria after F4.

### F4 — minor — The malformed-JSON default collides with a real field name and is untested on the article endpoint — accepted

Two decisions.

The error key changes from `body` to `json`: a body that is not valid JSON gets 422 with `{"errors":{"json":["is not valid"]}}`. The key `body` is a real field of the create-article request. The account endpoints spec is updated in its behaviour sentence, its criterion (`POST /api/members` with the body text `{not json`) and that criterion's Verification Notes row.

A malformed body sent to `POST /api/articles` gets that 422 with a valid token and with no token. The app reads the body before the token, as Architecture placed the parser. "Token before the body" is narrowed to "token before the fields are validated": a request with no token and an empty JSON object still gets 401.

Criteria added to the article endpoints spec, each with a Verification Notes row:

- `POST /api/articles` with the token of `jake`, the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`.
- `POST /api/articles` with no `Authorization` header, the body text `{not json` and content type `application/json` returns 422 with body `{"errors":{"json":["is not valid"]}}`.

The first also has a Preconditions row (`user.username`, value `jake`). The spec's Writes and Reads tables are unchanged: the edit adds no stored key.

### F5 — minor — R12 understates the cost of the assumptions — accepted

R12 now says that each assumption becomes tested behaviour once its ticket merges, and its impact is raised from low to medium. Each assumption in the list under the Risk Register names the spec that carries it. The "blank" assumption says that it widens the intent's "missing or empty field". No spec changed.

### F6 — minor — `frontend-shell` is an enabler presented as a business ticket — accepted

The Kind is confirmed as business and the reason is now a Work Breakdown note: the two header states are item 7 of the intent's scope, and the signed-out state is part of acceptance check 2 and is seen through the product itself. The note also states that the signed-in state is checked with a hand-placed login token until the sign-in page exists. The spec already says this in its Test User and Navigation Path sections. No spec changed.

### F7 — minor — No sign-out control and no home link: read as stricter than the intent — accepted

The assumption stays in the list, now worded as a narrowing of the intent, with the two manual steps named (Back button or typed address; fresh window or removing the `jwt` key). It is raised to the operator under Open Questions. No spec changed.

### F8 — minor — The dev-proxy check depends on the `X-Powered-By` header — accepted

The header is dropped from the check. Status 404 alone shows that the request reached the API, because the dev server would answer the same path with the page shell and status 200.

Criterion changed in the scaffold spec: "With both servers running, `GET http://localhost:5173/api/ping` returns status 404." Its Verification Notes row and the Proposed Changes sentence were changed with it.

### F9 — minor — A risk from Architecture was dropped, and versions are not pinned — accepted

Risk R14 (dependency drift) is restored. It states that no package version and no Node version is fixed by number, that the two committed lock files fix the installed versions from the scaffold onward, and that no Node pin is added. Risk R15 covers the npm registry being out of reach. No spec changed.

### F10 — minor — O1's measure does not exercise registration — accepted

The Measure of O1 now says that the walk registers nobody and that registration is measured by acceptance check 1. The outcome id and every spec's Serves list are unchanged.

### F11 — minor — Target Symbols list is incomplete for files the proposal itself changes — accepted

Added to the proposal's Target Symbols: lines 26, 27, 42, 43 and 44 of the repository `CLAUDE.md`, both `package.json` files, `frontend/src/style.css` and the five backend test files. Key files names the same files. No spec changed.

### F12 — nit — Duplicate ownership of one criterion — accepted

The criterion "With no `jwt` key in local storage, the header shows no `New Article` link." has one owner, the frontend shell spec. It is removed from the editor page spec together with its Verification Notes row and its Preconditions row. The editor page's behaviour sentence "The header shows no `New Article` link." was replaced by a sentence that says the signed-out header is built and checked in the frontend shell ticket, because the editor ticket does not change the header and so had nothing of its own to check. The editor page spec has 19 criteria.

### F13 — nit — Parameter source for the list defaults — accepted

The Source of `list_default_limit` and `list_default_offset` now quotes the intent. Values are unchanged.

### F14 — nit — Blocked-by lists repeat transitive edges — rejected

The lists stay complete. The readiness check reads one ticket at a time and cannot follow a chain, so each spec names every earlier ticket whose files, routes or seed data its text uses. The review asked for no change. A Work Breakdown note now lists the edges that carry a new need.

## Changes from Original Proposal

- **Order:** the sign-in and sign-up pages ticket is now blocked by the read pages ticket. One "same file, so serial" rule covers backend and frontend.
- **Verification:** a "Verification environment" paragraph states the stop-then-start rule for the API. The four frontend specs carry it in their Navigation Path.
- **Malformed JSON:** the error body is `{"errors":{"json":["is not valid"]}}`. The article create endpoint has two new criteria for it.
- **Dev-proxy check:** status 404 only.
- **Duplicate criterion:** removed from the editor page spec.
- **Outcome O1:** its Measure names acceptance check 1 for registration.
- **Parameters:** the two list defaults cite the intent.
- **Target Symbols and Key files:** eleven entries added.
- **Risk Register:** R1 and R2 rewritten, R12 reworded, R14, R15 and R16 added. Each assumption names its spec.
- **Unchanged:** the eight tickets, their titles, types and kinds, both outcomes, every parameter value, the scope and the strategy.

Criteria count per spec after this phase: scaffold 20, store 30, account endpoints 56, article endpoints 71, frontend shell 21, read pages 20, sign-in and sign-up pages 29, editor page 19.

## Deferred Items

- **Size of the article endpoints ticket (F3).** Kept as one ticket and carried as risk R16. If the ticket fails more than once at implementation, the natural cut is the list endpoint with its paging and author-filter criteria.
- **Node and package versions (F9).** No version is fixed by number. The lock files are the only pin. A Node pin would be a new behaviour of the scaffold that the intent does not ask for.
- **A stop script for the API (F2).** Not built. The stop step is a written verification step.
- **Appraisal U10.** The "FE type check" label on line 44 of the repository `CLAUDE.md` names a Vite build. It is left as it is, as Architecture decided.

## Open Questions

None of these blocks the plan. Each is an assumption the specs state as behaviour, and only the owner can confirm it.

- The header has no sign-out control and no home link. Is that what the owner wants, or should the header carry one or both? Today the walk uses the Back button or a typed address to return to the list, and a fresh window or a removed `jwt` key for its signed-out checks.
- "Blank" also covers a value that is not a string and a value made only of spaces, so a password of spaces is refused. Is that wider rule wanted?
- A body that is not valid JSON gets 422 with the key `json`, also on the create-article endpoint with no token. Is that the wanted answer?
- The other assumptions listed under the proposal's Risk Register (landing page after sign-in, `/register` path, slug and list edge cases, page labels) are unconfirmed.

## Readiness

ready-for-spec

No blocker was raised. The three major findings each have a decision, and every changed behaviour sentence has a criterion and a Verification Notes row.

## Goldfish Findings Addressed

Goldfish review: disabled
