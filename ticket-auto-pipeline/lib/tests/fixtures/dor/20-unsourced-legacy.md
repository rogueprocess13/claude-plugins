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

## Test Data Prerequisites

- A 1,000-row valid upload file
- A client with no configuration
