# overdue-job

## Description

Ownership fixture spec.

## Writes

| Key | Op |
|-----|----|
| `invoice.status` | transition:sent->overdue |
| `invoice_history` | append |
| `email.invoice_overdue` | fire |

## Reads

| Key | Source |
|-----|--------|
| `invoice.due_date` | spec |

## Acceptance Criteria

- [ ] The job page title reads Reminders.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| The job page title reads Reminders. | finance user | none | — | as stated | yes |
