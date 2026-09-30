## Summary

Harden the password reset token flow against abuse.

## Background / Motivation

A security review found the password reset flow does not handle several abuse cases around token reuse and expiry.

## Proposed Behaviour

The password reset flow rejects tokens that are expired, already used, or malformed, with a clear error in each case.

## Acceptance Criteria

- [ ] An expired reset token returns a 410 error with message `token expired`
- [ ] A reused reset token returns a 409 error with message `token already used`
- [ ] A malformed reset token returns a 400 error with message `invalid token`

## Scope

| Layer | Service  | Area  |
| ----- | -------- | ----- |
| FE    | gateway  | login |
| BE    | auth-svc | reset |

## Test User

`user@example.com` — password `admin`

## Navigation Path

`Login > Forgot Password > Reset`
