## Summary

Add a rate limit to the public quote API.

## Background / Motivation

The public quote API has no rate limiting, and a single misbehaving integration has twice pushed the endpoint's error rate high enough to page on-call.

## Proposed Behaviour

The quote API rejects requests over 60 per minute per API key with a 429 response.

## Acceptance Criteria

- [ ] A client exceeding 60 requests per minute receives a 429 response
- [ ] The 429 response includes a `Retry-After` header
- [ ] A client under the limit is never rate limited

## Scope

| Layer | Service   | Area      |
| ----- | --------- | --------- |
| BE    | quote-svc | rate-limit |

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Over-limit client gets 429 | n/a | n/a | API key with 61 requests/min | 429 returned | ✓ |
| 2 | Retry-After present | n/a | n/a | API key with 61 requests/min | header present | ✓ |
| 3 | Under-limit client unaffected | n/a | n/a | API key with 30 requests/min | 200 returned | ✓ |

## Related Tickets

None
