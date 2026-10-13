## Summary

Validate bulk client uploads before import.

## Background / Motivation

Operators upload client files that silently import malformed rows, and the errors only surface at month-end reconciliation.

## Proposed Behaviour

The upload page validates every row before import and rejects the file with a per-row error list when any row is invalid.

## Acceptance Criteria

- [ ] Uploading a valid 1,000-row file imports all 1,000 rows and shows "1000 rows imported"
- [ ] Uploading a file with an invalid row shows an error message naming the row number and imports nothing

## Scope

| Layer | Service    | Area             |
| ----- | ---------- | ---------------- |
| FE    | gateway    | client-upload    |
| BE    | client-svc | UploadController |

## Test User

`ops-lead@example.com` — password `admin`

## Navigation Path

`Clients > Upload`

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|-----------|------------|-----------------|------------------|-------------------|------------|
| 1 | Uploading a valid 1,000-row file imports all 1,000 rows and shows "1000 rows imported" | ops-lead | Clients > Upload | a 1,000-row valid upload file (Source: seeded-by:upload-test-data-pack) | "1000 rows imported" shown | ✓ |
| 2 | Uploading a file with an invalid row shows an error message naming the row number and imports nothing | ops-lead | Clients > Upload | a file with one invalid row (Source: generate) | error names the row, nothing imported | ✓ |

## Test Data Prerequisites

- A 1,000-row valid upload file. Source: seeded-by:upload-test-data-pack
- A file with one invalid row. Source: generate

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-TEST
**Epic:** EPIC-1
**Confidence:** 0.9
**Strategy:** Balanced
**Decision:** Validate uploads row by row before import
**Affected Services:** gateway, client-svc
**Target Symbols:** UploadController:src/upload/UploadController.java:40
**Pre-approved:** true
**Generated:** 2026-10-12T00:00:00Z
**Regenerate:** false
**Kind:** business
**Serves:** O1
