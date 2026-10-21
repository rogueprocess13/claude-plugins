# invoice-list

## Description

Fixture spec whose data is sourced; only the inventory is missing.

## Acceptance Criteria

- [ ] The list shows the paid invoices.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| The list shows the paid invoices. | finance user | 3 paid invoices | exists:staging seed set invoices.sql | 3 rows | yes |
