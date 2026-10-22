# invoice-list

## Description

Test-data synthesis fixture spec.

## Acceptance Criteria

- [ ] The list shows 5 paid invoices.
- [ ] The page title reads Billing.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| The list shows 5 paid invoices. | finance user | 5 paid `invoice` records | generate | as stated | yes |
| The page title reads Billing. | finance user | none | — | as stated | yes |
