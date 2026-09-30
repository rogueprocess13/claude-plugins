## Summary

Add a nightly reconciliation job for pending payouts.

## Background / Motivation

Payouts occasionally get stuck in `pending` when the payment processor's webhook is dropped, and nobody notices until a customer complains.

## Proposed Behaviour

A nightly job scans payouts stuck in `pending` for more than 24h and re-queries the processor for their real status.

## Acceptance Criteria

- [ ] Job runs nightly
- [ ] Mismatched payouts are corrected

## Scope

| Layer | Service     | Area          |
| ----- | ----------- | ------------- |
| BE    | billing-svc | payout-reconciler |

## Related Tickets

None
