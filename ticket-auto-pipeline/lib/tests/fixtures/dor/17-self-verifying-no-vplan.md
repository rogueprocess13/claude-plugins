## Summary

Enforce a maximum refund amount on the refunds API.

## Background / Motivation

A bug in the refunds API let a support agent refund more than the original charge amount, which finance had to manually reverse.

## Proposed Behaviour

The refunds API rejects any refund request whose amount exceeds the original charge.

## Acceptance Criteria

- [ ] `POST /refunds` with an amount above the original charge returns 422 with code `REFUND_EXCEEDS_CHARGE`
- [ ] `POST /refunds` with an amount equal to the original charge returns 201
- [ ] `POST /refunds` with an amount below the original charge returns 201

## Scope

| Layer | Service     | Area    |
| ----- | ----------- | ------- |
| BE    | billing-svc | refunds |

## Related Tickets

None
