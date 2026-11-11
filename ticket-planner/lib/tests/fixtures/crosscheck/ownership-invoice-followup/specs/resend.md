# resend

## Description

Ownership fixture spec.

## Writes

| Key | Op |
|-----|----|
| `email.invoice_overdue` | trigger |

## Reads

| Key | Source |
|-----|--------|
| `invoice.status` | spec |

## Acceptance Criteria

- [ ] The resend button label reads Resend.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| The resend button label reads Resend. | finance user | none | — | as stated | yes |
