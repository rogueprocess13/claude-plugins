## Summary

Add CSV export to the invoice list so finance can reconcile against the ERP without re-typing rows.

## Background / Motivation

Finance currently re-types every invoice row into the ERP by hand each month-end because the invoice list has no export. This costs about six hours per close and has caused at least two transcription errors traced back through support tickets.

## Proposed Behaviour

An "Export CSV" button appears above the invoice table. Clicking it downloads a CSV of the currently filtered rows with columns: invoice_id, customer, amount, due_date, status.

## Acceptance Criteria

- [ ] Clicking "Export CSV" downloads a file named invoices-{date}.csv
- [ ] The exported CSV row count matches the currently filtered table row count
- [ ] Exporting with zero rows visible shows an error message "No rows to export" and downloads nothing
- [ ] Exporting 5000 rows completes within 3s on the seeded dataset
- [ ] A user without the finance role does not see the Export CSV button

## Out of Scope

Scheduled/recurring exports. XLSX format. Emailing the export.

## Scope

| Layer | Service     | Area              |
| ----- | ----------- | ----------------- |
| FE    | gateway     | invoice-list       |
| BE    | billing-svc | InvoiceController   |

## Test User

`finance-lead@example.com` — password `admin`

## Navigation Path

`Billing > Invoices > Export CSV`

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Export downloads named file | finance | Billing > Invoices | 5 seeded invoices | invoices-{date}.csv downloaded | ✓ |
| 2 | CSV row count matches filter | finance | Billing > Invoices | 5 seeded invoices | row counts equal | ✓ |
| 3 | Empty export shows error | finance | Billing > Invoices | filter with 0 matches | "No rows to export" shown | ✓ |
| 4 | Large export performance | finance | Billing > Invoices | 5000 seeded invoices | completes under 3s | ✓ |
| 5 | Role gating | non-finance | Billing > Invoices | none | button absent | ✓ |

## Test Data Prerequisites

At least 5 seeded invoices across two customers, plus a 5000-row dataset for the performance criterion.

## Constraints

Export must complete within 3 seconds for 5000 rows (see AC above).

## Related Tickets

CRE-101 (billing-svc invoice read API)
