# Notes (reduced copy: an account normalisation ticket, "No screen, API only")

- Login: `backend/src/routes/users.js:41-54`. Blank check `['email','password']`, then `store.findUserByEmail(input.email)`; 401 on a wrong password.
- Frontend: `frontend/src/pages/register.js` and `login.js` contain no `trim` call and already render API 422 errors. No FE change (ticket Out of Scope).
- A person registers with an existing author's email plus a trailing space.

**Reason:** Changes authentication rules: production signing-secret enforcement at start-up, plus register/login identity matching on the public POST /api/users contract.

| Feature | Roles | Scope | Confidence | Evidence |
| -- | -- | -- | -- | -- |
| Account register/login normalisation (`POST /api/users`, `POST /api/users/login`) | all (anonymous callers) | global | high | code path: both endpoints are unauthenticated |

All checks are API-only (ticket Navigation Path: "No screen"), run as supertest requests by `npm test` in `backend/`. Each test builds its own `createApp()`.

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
| -- | -- | -- | -- | -- | -- | -- |
| 6 | After #5, login `new.author@example.test ` + same password | global | `POST /api/users/login` (same app as #5) | account from #5 | 200 | ✓ |
| 7 | Login ` alice@example.test` / `Alice-Pass-123` | global | `POST /api/users/login` | seeded `alice` | 200 | ✓ |

## Verification Readiness
**Mode:** browser (verify: browser)

## Navigation Path

No screen. This ticket is API only: each check is an HTTP request to the API, run by `npm test` in `backend/`. The tests build their own sign-up payloads.
