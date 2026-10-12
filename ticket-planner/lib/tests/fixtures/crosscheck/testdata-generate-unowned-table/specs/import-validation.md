# import-validation

## Description

Spreadsheet import fixture spec for the test-data provenance check.

## Acceptance Criteria

- [ ] An operator can upload an import file and see the row count.
- [ ] A rejected file shows the validation error.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| An operator can upload an import file and see the row count. | operator | a 60MB import file | generate | rejected as too large | yes |
| A rejected file shows the validation error. | admin | a client record in Archived state | exists:staging seed set clients.sql | validation error shown | yes |
