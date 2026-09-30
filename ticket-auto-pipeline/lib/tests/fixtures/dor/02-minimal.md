## Summary

Fix the stale "Last updated" timestamp on the customer profile page.

## Background / Motivation

The "Last updated" label on the customer profile page shows the record's creation date instead of its last-modified date, which is wrong.

## Proposed Behaviour

The label reads the record's `updated_at` field instead of `created_at`.

## Acceptance Criteria

- [ ] The "Last updated" label displays the value of `updated_at`, formatted as `YYYY-MM-DD`

## Scope

| Layer | Service | Area            |
| ----- | ------- | --------------- |
| FE    | gateway | customer-profile |

## Test User

`support@example.com` — password `admin`

## Navigation Path

`Customers > Profile`
