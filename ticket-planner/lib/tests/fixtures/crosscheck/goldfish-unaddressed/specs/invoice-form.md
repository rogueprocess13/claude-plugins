# invoice-form

## Description

AC precondition fixture spec.

## Acceptance Criteria

- [ ] Saving the invoice form without a customer shows the error Customer is required.
- [ ] The invoice form title reads New invoice.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| Saving the invoice form without a customer shows the error Customer is required. | finance user | none | — | as stated | yes |
| The invoice form title reads New invoice. | finance user | none | — | as stated | yes |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| Saving the invoice form without a customer shows the error Customer is required. | `invoice.customer_id` | input | null | — |
| The invoice form title reads New invoice. | `invoice.status` | given | value:draft | code:billing/src |
