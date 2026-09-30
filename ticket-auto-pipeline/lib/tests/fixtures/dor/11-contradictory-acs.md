## Summary

Tighten the idle session timeout on the admin console.

## Background / Motivation

Security review flagged that the admin console's session never expires, which is a risk if an admin walks away from an unlocked machine.

## Proposed Behaviour

The admin console session expires after a fixed period of inactivity and the user is redirected to the login page.

## Acceptance Criteria

- [ ] Session expires after 15 minutes of inactivity
- [ ] Session expires after 30 minutes of inactivity
- [ ] An expired session redirects to `/login` with a "Session expired" message

## Scope

| Layer | Service | Area  |
| ----- | ------- | ----- |
| FE    | gateway | admin-console |
| BE    | auth-svc | session |

## Test User

`admin@example.com` — password `admin`

## Navigation Path

`Admin Console > (any page)`
