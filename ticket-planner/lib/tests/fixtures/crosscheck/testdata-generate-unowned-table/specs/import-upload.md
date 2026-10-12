# import-upload

## Description

Spreadsheet import fixture spec for the test-data provenance check.

## Acceptance Criteria

- [ ] An operator can upload an import file and see the row count.
- [ ] A rejected file shows the validation error.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| An operator can upload an import file and see the row count. | operator | a 1,000-row import file | generate | row count shown | yes |
| A rejected file shows the validation error. | operator | none (error path uses any file) | — | validation error shown | yes |
