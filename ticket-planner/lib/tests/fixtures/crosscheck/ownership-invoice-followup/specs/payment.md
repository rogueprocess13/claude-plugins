# payment

## Description

Ownership fixture spec.

## Writes

| Key | Op |
|-----|----|
| `invoice.status` | transition:sent,overdue->paid |
| `invoice_history` | append |
| `payment` | create |
| `email.payment_receipt` | fire |

## Reads

| Key | Source |
|-----|--------|
| `user.id` | framework:auth_user |

## Acceptance Criteria

- [ ] The payment page title reads Payments.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| The payment page title reads Payments. | finance user | none | — | as stated | yes |
