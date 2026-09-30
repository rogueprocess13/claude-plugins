## Summary

Add a "Duplicate" action to the handover row menu.

## Background / Motivation

Attorneys frequently create a new handover that is 90% identical to a recent one and currently have to re-enter every field by hand.

## Proposed Behaviour

A "Duplicate" action in the handover row menu creates a new draft handover pre-filled from the source, except its status and timestamps.

## Acceptance Criteria

- [ ] Selecting "Duplicate" creates a new draft handover with the same recipient and items as the source
- [ ] The duplicated handover's status is `draft` regardless of the source's status
- [ ] The duplicated handover's `created_at` is the current time, not the source's

## Scope

| Layer | Service      | Area     |
| ----- | ------------ | -------- |
| FE    | gateway      | handover-list |
| BE    | handover-svc | duplicate |

## Test User

`qa-billing-manager` — password `admin`

## Navigation Path

`Handovers > Row menu > Duplicate`

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Duplicate copies fields | qa-billing-manager | Handovers | 1 seeded handover | new draft matches source | ✓ |
| 2 | Status resets to draft | qa-billing-manager | Handovers | 1 completed handover | duplicate status=draft | ✓ |
| 3 | created_at is fresh | qa-billing-manager | Handovers | 1 seeded handover | new created_at != source | ✓ |

## Test Data Prerequisites

TBD

## Related Tickets

None
