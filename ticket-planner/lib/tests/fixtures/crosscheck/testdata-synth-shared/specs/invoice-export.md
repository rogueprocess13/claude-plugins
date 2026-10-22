# invoice-export

## Description

Test-data synthesis fixture spec.

## Acceptance Criteria

- [ ] The export includes 3 paid invoices.
- [ ] The page title reads Billing.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| The export includes 3 paid invoices. | finance user | 3 paid `invoice` records | generate | as stated | yes |
| The page title reads Billing. | finance user | none | — | as stated | yes |
