## Summary

Refactor the billing service's payment retry logic.

## Background / Motivation

The payment retry logic is duplicated across three call sites with slightly different backoff constants, which makes it easy to introduce a bug when tuning retry behaviour.

## Proposed Behaviour

The retry logic is consolidated into a single `PaymentRetryPolicy` class that every call site uses.

## Acceptance Criteria

- [ ] Add a `PaymentRetryPolicy` class in `billing-svc`
- [ ] Refactor `PaymentProcessor` to use `PaymentRetryPolicy`
- [ ] Refactor `InvoiceRetryJob` to use `PaymentRetryPolicy`

## Scope

| Layer | Service     | Area         |
| ----- | ----------- | ------------ |
| BE    | billing-svc | retry-policy |

## Related Tickets

None
