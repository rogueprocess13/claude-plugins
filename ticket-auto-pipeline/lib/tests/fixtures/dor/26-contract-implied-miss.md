## Summary

Let site supervisors duplicate a shift handover.

## Background / Motivation

Supervisors re-type the same handover line items at every shift change, which takes ten minutes per shift and drops items when the list is long.

## Proposed Behaviour

The handover list gains a Duplicate action that creates a draft copy of the chosen handover, so the next shift only edits what changed.

## Acceptance Criteria

- [ ] Opening the handover list shows the 25 most recent handovers for the site
- [ ] Duplicating a handover from the list creates a draft copy with the same line items
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
| 1 | Opening the handover list shows the 25 most recent handovers for the site | supervisor | Operations > Handovers | 25 handovers for one site (Source: seeded-by:handover-test-data-pack) | 25 rows, newest first | ✓ |
| 2 | Duplicating a handover from the list creates a draft copy with the same line items | supervisor | Operations > Handovers | none | a new draft with the same line items | ✓ |
| 3 | A user without the supervisor role does not see the Duplicate action | operator | Operations > Handovers | none | Duplicate action absent | ✓ |

## Test Data Prerequisites

- 25 handovers for one site. Source: seeded-by:handover-test-data-pack

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-TEST
**Epic:** EPIC-1
**Confidence:** 0.9
**Strategy:** Balanced
**Decision:** Add a Duplicate action to the handover list
**Affected Services:** gateway, handover-svc
**Target Symbols:** HandoverController:src/handover/HandoverController.java:40
**Pre-approved:** true
**Generated:** 2026-10-12T00:00:00Z
**Regenerate:** false
**Kind:** business
**Serves:** O1
