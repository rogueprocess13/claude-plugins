# Notes (reduced copy: sign-in and sign-up pages, a real browser ticket)

- Pipeline base is `epic/init-1-sample-app-sign-up-login-and-articles`.
- The pages call the existing API: `POST /api/users`, `POST /api/users/login`, `GET /api/user`. Backend checks: `npm test` in `backend/`.
- login/register pages must call `setToken(body.user.token)`, then `refreshHeader()`, then `navigate('/')`.
- Frontend: no test runner. Verification is `npm run build` exit 0 plus the browser walk in the ticket's Verification Plan.

## Verification Readiness
**Mode:** browser (verify: browser)

## Test User

`alice@example.test`, password `Alice-Pass-123` (seeded author).

## Navigation Path

Start the API (`npm start` in `backend/`). Start the frontend (`npm run dev` in `frontend/`). Open the site. Click `Sign in` in the header for the sign-in page, or `Sign up` for the sign-up page.

## Verification Plan

| \# | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
| -- | -- | -- | -- | -- | -- | -- |
| 1 | The sign-in page shows an `Email` field. | Anonymous reader | Open the site > click `Sign in` | none | a text input labelled Email is visible | ✓ |
| 2 | Submitting a wrong password shows `email or password is invalid`. | Anonymous reader | Open the site > click `Sign in` > fill the form > click the `Sign in` button | seeded `alice` | the error line is visible | ✓ |
