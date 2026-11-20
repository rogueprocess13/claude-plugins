# invoice-form

## Description

Ticket-body fixture spec.

## Technical Context

- The form lives in `web/src/invoice-form.ts`; totals come from `web/src/totals.ts`.

## Errors and Edge Cases

- **Failure:** a failed save shows the error Could not save the invoice.
- **Check order:** Not applicable — the form calls one endpoint with one check.
- **Empty or malformed input:** saving without a customer shows the error Customer is required.
- **Late or concurrent responses:** Not applicable — the Save button is disabled while a save runs.
- **Unauthorised viewer:** Not applicable — access to the form does not change.

## Acceptance Criteria

- [ ] [live] Saving the invoice form without a customer shows the error Customer is required.
- [ ] [live] The invoice form title reads New invoice.
- [ ] [unit] A save that fails in storage shows the error Could not save the invoice.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | web     | `web/src/invoice-form.ts`, `web/src/totals.ts` (read-only) |

## Verify Mode

**Verify mode:** browser — a finance user fills in the invoice form.

## Labels

planned, feature

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| [live] Saving the invoice form without a customer shows the error Customer is required. | finance user | none | — | as stated | yes |
| [live] The invoice form title reads New invoice. | finance user | none | — | as stated | yes |
| [unit] A save that fails in storage shows the error Could not save the invoice. | finance user | none | — | the test for a failed save passes | yes |
