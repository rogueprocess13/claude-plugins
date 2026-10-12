# test-data-pack

## Description

Spreadsheet import fixture spec for the test-data provenance check.

## Acceptance Criteria

- [ ] An operator can upload an import file and see the row count.
- [ ] A rejected file shows the validation error.

## Verification Notes

1. Role: any authenticated user. Test data: none.

## Test Data Provided

- Generator script for import files of a given row count and size (1,000 rows; 60MB).
- Seed script for clients in each lifecycle state.
