## Summary

Save button stays disabled after fixing a validation error on the handover form.

## Steps to Reproduce

1. Log in as `attorney@example.com` (password: `admin`)
2. Navigate via `Handovers > New Handover` — do NOT paste a URL
3. Leave the "Recipient" field blank and click Save
4. Fill in the "Recipient" field with a valid value

## Acceptance Criteria

- [ ] The Save button is enabled once all required fields are valid

## Scope

| Layer | Service   | Area      |
| ----- | --------- | --------- |
| FE    | gateway   | handover-form |
| BE    | handover-svc | validation |

## Test User

`attorney@example.com` — password `admin`

## Environment

- [ ] Local (`http://localhost:9000`)
- [ ] UAT (`https://uat.credit-network.biz/`)

## Test Data Prerequisites

At least one draft handover in progress.
