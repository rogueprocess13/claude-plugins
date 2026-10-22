# audit-log

## Description

Test-data synthesis fixture spec.

## Acceptance Criteria

- [ ] The audit log lists the recorded event.
- [ ] The page title reads Billing.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| The audit log lists the recorded event. | finance user | one `audit-event` record | generate | as stated | yes |
| The page title reads Billing. | finance user | none | — | as stated | yes |
