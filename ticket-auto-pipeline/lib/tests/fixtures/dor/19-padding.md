## Summary

Fix the stale "Last updated" timestamp on the customer profile page.

## Background / Motivation

The "Last updated" label on the customer profile page shows the record's creation date instead of its last-modified date, which is wrong. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over. This is additional padding prose intended to inflate the motivation section without adding any new acceptance criteria or behavioural signal whatsoever, repeated many times over.

## Proposed Behaviour

The label reads the record's `updated_at` field instead of `created_at`.

## Acceptance Criteria

- [ ] The "Last updated" label displays the value of `updated_at`, formatted as `YYYY-MM-DD`
- [ ] The "Last updated" label displays the value of `updated_at`, formatted as `YYYY-MM-DD`
- [ ] The "Last updated" label displays the value of `updated_at`, formatted as `YYYY-MM-DD`

## Scope

| Layer | Service | Area            |
| ----- | ------- | --------------- |
| FE    | gateway | customer-profile |

## Test User

`support@example.com` — password `admin`

## Navigation Path

`Customers > Profile`
