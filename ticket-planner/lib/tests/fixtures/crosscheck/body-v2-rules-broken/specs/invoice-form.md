# invoice-form

## Description

Ticket-body fixture spec.

## Technical Context

- The form lives in `web/src/invoice-form.ts`; totals come from `web/src/totals.ts`.

## Acceptance Criteria

- [ ] Saving the invoice form without a customer shows the error Customer is required.
- [ ] The invoice form title reads New invoice.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | web     | `web/src/invoice-form.ts` |

## Labels

planned, feature

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| Saving the invoice form without a customer shows the error Customer is required. | finance user | none | — | as stated | yes |
| The invoice form title reads New invoice. | finance user | none | — | as stated | yes |
