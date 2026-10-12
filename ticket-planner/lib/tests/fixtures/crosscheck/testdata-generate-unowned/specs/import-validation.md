# import-validation

## Description

Spreadsheet import fixture spec for the test-data provenance check.

## Acceptance Criteria

- [ ] An operator can upload an import file and see the row count.
- [ ] A rejected file shows the validation error.

## Verification Notes

1. Role: operator. Test data: a 60MB import file. Source: generate.
2. Role: admin. Test data: a client record in Archived state. Source: exists:staging seed set clients.sql.

