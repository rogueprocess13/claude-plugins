## Summary

Let site supervisors duplicate and archive shift handovers.

## Background / Motivation

Supervisors re-type the same handover line items at every shift change, and old handovers crowd the list because nothing can be archived.

## Proposed Behaviour

The handover list gains a Duplicate action that creates a draft copy of the chosen handover, and the handover detail page gains an Archive action.

## Acceptance Criteria

- [ ] Duplicating a handover from the list creates a draft copy with the same line items
- [ ] Archiving a handover from its detail page moves it to the Archived tab
- [ ] A user without the supervisor role does not see the Duplicate action

## Scope

| Layer | Service      | Area               |
| ----- | ------------ | ------------------ |
| FE    | gateway      | handover-list      |
| BE    | handover-svc | HandoverController |

## Test User

`supervisor@example.com` — password `admin`

## Navigation Path

`Operations > Handovers`

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|------------|-----------------|------------------|-------------------|------------|
| 1 | Duplicating a handover from the list creates a draft copy with the same line items | supervisor | Operations > Handovers | none | a new draft with the same line items | ✓ |
| 2 | Archiving a handover from its detail page moves it to the Archived tab | supervisor | Operations > Handovers | none | the handover is listed under Archived | ✓ |
| 3 | A user without the supervisor role does not see the Duplicate action | operator | Operations > Handovers | none | Duplicate action absent | ✓ |

## Test Data Prerequisites

- None — no acceptance criterion needs test data.

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-TEST
**Epic:** EPIC-1
**Confidence:** 0.9
**Strategy:** Balanced
**Decision:** Add Duplicate and Archive actions to handovers
**Affected Services:** gateway, handover-svc
**Target Symbols:** HandoverController:src/handover/HandoverController.java:40
**Pre-approved:** true
**Generated:** 2026-10-12T00:00:00Z
**Regenerate:** false
**Kind:** business
**Serves:** O1
