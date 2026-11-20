# Notes (reduced copy: an in-memory store ticket, no endpoint, no page)

- The pipeline base for this ticket is `epic/init-1-sample-app-sign-up-login-and-articles` (pipeline log `META|branch-context`).
- Is the scaffold (`backend/src/app.js`, `backend/src/server.js`) present on this ticket's base branch? **Resolved:** yes on the remote, `origin` `refs/heads/epic/init-1-sample-app-sign-up-login-and-articles`.

| Feature | Roles | Scope | Confidence | Evidence |
| -- | -- | -- | -- | -- |
| In-memory store and seed (backend module, no endpoint, no page) | all (developer runs `npm test`; no user role is involved) | global | high | explicit mention (ticket "Test User: None ... A developer runs `npm test` in `backend/`") |

## Verification Readiness
**Date:** 2026-01-01
**Status:** CLEAR
**Mode:** browser (verify: browser)

- Base: origin/epic/init-1-sample-app-sign-up-login-and-articles at 0000000 (fetched before branching)
- **User:** developer (no login; ticket Test User: None)

## Test User

None. This ticket has no endpoint and no page. A developer runs `npm test` in `backend/`.

## Verification Plan

| \# | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
| -- | -- | -- | -- | -- | -- | -- |
| 1 | A new store lists exactly 2 users, `alice` then `bob`. | Developer | n/a | 2 seeded `user` records | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | ✓ |
| 2 | In a new store, `alice` has id 1. | Developer | n/a | 1 seeded `user` | the store test asserting this passes; `npm test` in `backend/` exits with code 0 | ✓ |
