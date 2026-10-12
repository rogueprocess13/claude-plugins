## Summary

Validate bulk client uploads before import.

## Background / Motivation

Operators upload client files that silently import malformed rows, and the errors only surface at month-end reconciliation.

## Proposed Behaviour

The upload page validates every row before import and rejects the file with a per-row error list when any row is invalid.

## Acceptance Criteria

- [ ] Uploading a valid 1,000-row file imports all 1,000 rows and shows "1000 rows imported"
- [ ] Uploading a file with an invalid row shows an error message naming the row number and imports nothing
- [ ] A user without the ops role does not see the Upload menu item

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
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Valid file imports | ops-lead | Clients > Upload | a 1,000-row valid upload file (Source: seeded-by:upload-test-data-pack) | "1000 rows imported" shown | ✓ |
| 2 | Invalid row rejected | ops-lead | Clients > Upload | a client with no configuration (Source: exists:staging seed set, clients.sql) | error names the row, nothing imported | ✓ |
| 3 | Role gating | non-ops | Clients | none | menu item absent | ✓ |

## Test Data Prerequisites

- A 1,000-row valid upload file. Source: seeded-by:upload-test-data-pack
- A client with no configuration. **Source:** `exists:staging seed set (clients.sql)`.
- The regional client template. _Source:_ external:onboarding team
