## Summary

Firm administrators can lock a completed financial period so the documents filed in it can no longer change, and can unlock it again when a correction is needed.

## Outcome

**Serves:** O1

**Who:** Firm administrator

**Need:** Once a financial period is closed, its documents must not change without a trace.

**Outcome:** A completed period can be locked; changes to its documents are refused, and every lock and unlock is recorded for audit.

## Background / Motivation

Today a closed period can still be edited. Nothing stops a document being re-filed or replaced after the accounts for that period have been signed off, so the firm cannot show an auditor that its records are final.

## Proposed Behaviour

A firm administrator sees a "Lock period" action on a completed financial period. Once locked, the period's documents are read-only for everyone except a super-admin override. The administrator can unlock the period again. Each lock and unlock appears in the period's history with who did it and when.

## Technical Context

- Add `matters.locked_at` and `matters.locked_by` columns (new migration).
- New `POST /api/matters/{matterId}/lock` and `POST /api/matters/{matterId}/unlock` routes, authorised through new `matters:lock` / `matters:unlock` entries in the `can()` capability map (`lib/authz.ts`).
- Mutating document routes check `matters.locked_at` and return 409 when the period is locked.
- Each transition writes an `audit_log` row (`action = 'matter.lock' | 'matter.unlock'`).

## Errors and Edge Cases

- **Failure:** when the lock or unlock request fails (network failure or a 5xx response), the period page shows "Could not update the period. Try again." and the period keeps its previous state.
- **Check order:** a request without a session gets 401 before any other check; a user without the firm administrator role gets 403 before the period is looked up; an unknown period gets 404.
- **Empty or malformed input:** Not applicable — lock and unlock take no request body.
- **Late or concurrent responses:** a second lock request for a period that is already locked changes nothing and the page shows the period as Locked.
- **Unauthorised viewer:** a user without the firm administrator role sees the period page without the Lock period action.

## Acceptance Criteria

- [ ] [live] A firm administrator can lock a completed financial period from the period page
- [ ] [live] Editing a document in a locked period shows the error "This period is locked"
- [ ] [live] The period history lists the lock with the administrator's name and the time
- [ ] [live] A firm administrator can unlock a locked period
- [ ] [live] A user without the firm administrator role does not see the Lock period action

## Out of Scope

Automatic locking on a schedule. Partial (per-document) locks.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | web     | matter-detail |
| BE    | api     | `lib/authz.ts` |
| BE    | api     | matters (routes, migration) |

## Test User

`firm-admin@example.com` — password `admin`

## Navigation Path

`Clients > Matters > Period detail > Lock period`

## Verify Mode

**Verify mode:** browser — a firm administrator locks and unlocks a period on the period page.

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Lock a completed period | firm admin | Clients > Matters > Period detail | 1 completed period with 3 documents | period shows Locked | ✓ |
| 2 | Edit blocked when locked | firm admin | Clients > Matters > Period detail | locked period from row 1 | "This period is locked" shown | ✓ |
| 3 | Lock recorded in history | firm admin | Clients > Matters > Period detail | locked period from row 1 | history row with admin name and time | ✓ |
| 4 | Unlock a locked period | firm admin | Clients > Matters > Period detail | locked period from row 1 | period shows Open | ✓ |
| 5 | Role gating | staff accountant | Clients > Matters > Period detail | 1 completed period | Lock period action absent | ✓ |

## Test Data Prerequisites

One client with one completed financial period holding three filed documents, plus a staff accountant user without the firm administrator role.

## Related Tickets

None.

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-TEST
**Epic:** EPIC-1
**Confidence:** 0.9
**Strategy:** Balanced
**Decision:** Add a lock state to matters with audited lock/unlock routes
**Affected Services:** web, api
**Target Symbols:** can:lib/authz.ts:91
**Pre-approved:** true
**Generated:** 2026-10-03T00:00:00Z
**Regenerate:** false
**Kind:** business
**Serves:** O1
