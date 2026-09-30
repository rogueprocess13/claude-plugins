## Summary

Add a retry queue for failed webhook deliveries.

## Background / Motivation

Outbound webhook deliveries to customer endpoints occasionally fail transiently (DNS blip, 502 from their edge), and today a single failure drops the event forever.

## Proposed Behaviour

A failed webhook delivery is retried up to 5 times with exponential backoff via the `webhook-retry` queue consumer before being moved to a dead-letter topic.

## Acceptance Criteria

- [ ] A delivery that returns a 5xx is retried up to 5 times with exponential backoff
- [ ] A delivery still failing after 5 attempts is moved to the `webhook-dead-letter` topic
- [ ] A delivery that returns a 2xx on any attempt is not retried again

## Scope

| Layer | Service     | Area          |
| ----- | ----------- | ------------- |
| BE    | webhook-svc | retry-consumer |

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Retries on 5xx | n/a | n/a | mock endpoint returning 500 | 5 retries observed | ✓ |
| 2 | Dead-letters after exhaustion | n/a | n/a | mock endpoint always 500 | message on webhook-dead-letter | ✓ |
| 3 | No retry on success | n/a | n/a | mock endpoint returning 200 | single delivery attempt | ✓ |

## Related Tickets

None
