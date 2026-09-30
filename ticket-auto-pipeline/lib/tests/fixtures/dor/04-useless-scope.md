## Summary

Tidy up the reporting module.

## Background / Motivation

The reporting module has accumulated dead code and inconsistent formatting over several quarters, which slows down onboarding new engineers.

## Proposed Behaviour

The reporting module's dead code is removed and its formatting matches the rest of the codebase.

## Acceptance Criteria

- [ ] Reporting module has no unused exports, verified by the `depcheck` CLI reporting zero findings under `src/reporting`
- [ ] Reporting module passes `npm run lint` with zero warnings

## Scope

| Layer   | Service | Area      |
| ------- | ------- | --------- |
| Various | Everything | TBD    |

## Test User

`eng@example.com` — password `admin`

## Navigation Path

`Admin > Reports`
