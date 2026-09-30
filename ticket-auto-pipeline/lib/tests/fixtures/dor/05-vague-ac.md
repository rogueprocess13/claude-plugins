## Summary

Improve error handling on the checkout form.

## Background / Motivation

Customers abandon checkout when a payment fails because the form gives no useful feedback about what went wrong.

## Proposed Behaviour

The checkout form surfaces a clear message when payment fails, and the rest of the form stays usable.

## Acceptance Criteria

- [ ] Errors are handled gracefully
- [ ] The form works correctly after a failed payment

## Scope

| Layer | Service     | Area     |
| ----- | ----------- | -------- |
| FE    | gateway     | checkout |
| BE    | billing-svc | payments |

## Test User

`shopper@example.com` — password `admin`

## Navigation Path

`Cart > Checkout > Payment`
