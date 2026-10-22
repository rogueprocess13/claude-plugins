## Summary

Tighten sign-in session and lockout limits.

## Background / Motivation

An audit found that idle sessions stay open for a full day and that sign-in attempts are never limited, which leaves shared terminals exposed.

## Proposed Behaviour

Idle sessions expire after a fixed period, and repeated failed sign-in attempts lock the account.

## Acceptance Criteria

- [ ] The session expires after 15 minutes of inactivity
- [ ] The account locks after 5 failed sign-in attempts
- [ ] A sign-in to a locked account returns HTTP 423

## Scope

| Layer | Service  | Area          |
| ----- | -------- | ------------- |
| FE    | gateway  | sign-in       |
| BE    | auth-svc | SessionPolicy |

## Test User

`operator@example.com` — password `admin`

## Navigation Path

`Sign in`

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|------------|-----------------|------------------|-------------------|------------|
| 1 | The session expires after 15 minutes of inactivity | operator | Sign in | none | redirected to sign-in after 15 minutes idle | ✓ |
| 2 | The account locks after 5 failed sign-in attempts | operator | Sign in | none | the sixth attempt is refused | ✓ |
| 3 | A sign-in to a locked account returns HTTP 423 | operator | Sign in | none | HTTP 423 | ✓ |

## Test Data Prerequisites

- None — no acceptance criterion needs test data.

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-TEST
**Epic:** EPIC-1
**Confidence:** 0.9
**Strategy:** Balanced
**Decision:** Enforce idle expiry and sign-in lockout
**Affected Services:** gateway, auth-svc
**Target Symbols:** SessionPolicy:src/auth/SessionPolicy.java:20
**Pre-approved:** true
**Generated:** 2026-10-12T00:00:00Z
**Regenerate:** false
**Kind:** business
**Serves:** O1
