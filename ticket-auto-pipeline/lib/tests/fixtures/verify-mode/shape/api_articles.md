# Notes (reduced copy: an articles API ticket whose Navigation Path says "No screen")

- Pipeline base is `epic/init-1-sample-app-sign-up-login-and-articles`. The auth ticket is merged on top of it.
- Implement: `git fetch origin` and branch from `origin/epic/init-1-sample-app-sign-up-login-and-articles`, not local `develop`.
- No rate limiting on login. Out of scope per the ticket.

Navigation path for every row: API only, no screen. Run `npm test` in `sample-app/backend/` (`test/articles.test.js`), or send the request by hand to a freshly started API (`npm start` in `backend/`, port 3000).

## Verification Readiness
**Mode:** browser (verify: browser)

**Outcome:** A signed-in author can publish an article, and anyone can open a published article or see the list of articles, newest first.

## Test User

`alice@example.test`, password `Alice-Pass-123` (seeded author) for publishing. Reading and listing need no account. The token comes from the login endpoint.

## Navigation Path

No screen. This ticket is API only: each check is an HTTP request to the API, run by `npm test` in `backend/`, or sent by hand to a freshly started API (`npm start` in `backend/`).

## Verification Plan

| \# | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
| -- | -- | -- | -- | -- | -- | -- |
| 1 | `POST /api/articles` with the token of `alice`, title `My first post` returns 201. | Author (`alice`) | No screen. This ticket is API only: each check is an HTTP request to the API, run by npm test in backend/ | 1 seeded `user` | 201 | ✓ |
| 2 | `POST /api/articles` with no `Authorization` header returns 401. | API client with no account | No screen. This ticket is API only: each check is an HTTP request to the API, run by npm test in backend/ | none | 401 | ✓ |
