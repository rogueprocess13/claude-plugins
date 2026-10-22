## Summary

Show save feedback on the handover settings page.

## Background / Motivation

Attorneys report the Save button failing silently, so they re-enter handovers they already saved.

## Proposed Behaviour

Every save shows a result: a confirmation on success, an error toast with a Retry action on failure.

## Acceptance Criteria

- [ ] Saving a handover stores it and shows "Saved"
- [ ] A failed save shows an error toast naming the field that failed
- [ ] The error toast offers a Retry action that re-submits the form
- [ ] Criteria 2 and 3 are verified together in Verification Plan row 2

## Scope

| Layer | Service | Area              |
| ----- | ------- | ----------------- |
| FE    | gateway | handover-settings |

## Test User

`attorney@example.com` — password `admin`

## Navigation Path

`Settings > Handovers`

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Save stores the handover | attorney | Settings > Handovers | none | "Saved" shown, handover listed | ✓ |
| 2 | Failed save toast with Retry | attorney | Settings > Handovers | none | toast names the field; Retry re-submits | ✓ |

## Test Data Prerequisites

- None — no acceptance criterion needs test data.
