# backend-scaffold-test-data

<!-- planner:testdata-synth v1 -->
<!-- planner:testdata-synth keys: a test app with one route get boom that throws new error boom -->

## Title

Seed test data for backend-scaffold

## Description

## Summary

Seeds the synthetic test data that `backend-scaffold` need before their acceptance criteria can be verified, and adds a verify target that proves the data is in place.

## Enables

**Enables:** O1, O2, O3 — the outcomes `backend-scaffold` deliver. Their acceptance criteria cannot be verified until the records below exist.

## Background / Motivation

No existing seed set, fixture or external party provides these records. The needs come from the consumers' acceptance criteria, grouped here so one ticket owns the data and every consumer reads the same records. The consumer tickets are blocked by this one.

## Proposed Changes

- Add a `seed-backend-scaffold-test-data` Make target that loads every record under Test Data Provided through the factories channel. A second run leaves the same data: upsert by record key, never duplicate.
- Add a `verify-seed-backend-scaffold-test-data` Make target that checks every record key is present in the stated state and exits non-zero when one is not.
- Add a `reset-seed-backend-scaffold-test-data` Make target that removes only the records this ticket seeds.
- Add a README beside the seed scripts that maps each record key to its record and the consumer criterion it serves.

## Seed Commands

Seed command: make seed-backend-scaffold-test-data
Verify command: make verify-seed-backend-scaffold-test-data
Seed channel: factories

Both commands must stay `make <target>` (or `make -C <relpath> <target>`); VERIFY refuses any other shape. Keep the seeding logic in the Makefile target, and keep these target names.

## Test Data Provided

- `td-1794904930-5594-1` — a test app with one route `GET /boom` that throws `new Error('boom')` — for `backend-scaffold`: `GET /boom` on a test app whose only route throws `new Error('boom')`, with `errorHandler` mounted after it, returns status 500
- `td-1794904930-5594-2` — a test app with one route `GET /boom` that throws `new Error('boom')` — for `backend-scaffold`: `GET /boom` on a test app whose only route throws `new Error('boom')`, with `errorHandler` mounted after it, returns the body `{"errors":{"server":["unexpected error"]}}`

## Acceptance Criteria

- [ ] the seed command exits 0 on two consecutive runs
- [ ] the verify command passes
- [ ] Every seeded foreign key resolves to a seeded or existing parent record
- [ ] All seeded data is synthetic or masked, with no production personal data
- [ ] make reset-seed-backend-scaffold-test-data removes only the records this ticket seeds and exits 0
- [ ] A README maps every record key under Test Data Provided to its record and consumer criterion

## Out of Scope

Application behaviour and the consumers' own acceptance criteria. Data that an external party must supply.

## Scope

| Layer | Service   | Area                                          |
| ----- | --------- | --------------------------------------------- |
| BE    | test data | seed, verify and reset scripts               |
| Infra | Makefile  | seed-backend-scaffold-test-data, verify-seed-backend-scaffold-test-data, reset-seed-backend-scaffold-test-data |

## Test User

None — the seed, verify and reset commands run without signing in.

## Labels

planned, INIT-0000000000-2767, chore

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 2,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Seed the listed records through the make targets seed-backend-scaffold-test-data and verify-seed-backend-scaffold-test-data.",
  "AffectedServices": "app backend",
  "TargetSymbols": "seed-backend-scaffold-test-data:Makefile; verify-seed-backend-scaffold-test-data:Makefile",
  "Kind": "enabler",
  "Serves": [],
  "Enables": [
    "O1",
    "O2",
    "O3"
  ],
  "Priority": "High"
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| the seed command exits 0 on two consecutive runs | implementer | none | — | — | exit code 0 on both runs | yes |
| the verify command passes | implementer | none | — | — | exit code 0 | yes |
| Every seeded foreign key resolves to a seeded or existing parent record | implementer | none | — | — | verify target reports no orphan rows | yes |
| All seeded data is synthetic or masked, with no production personal data | reviewer | none | — | — | needs human judgement of the seed scripts, no checkable value | no |
| make reset-seed-backend-scaffold-test-data removes only the records this ticket seeds and exits 0 | implementer | none | — | — | exit code 0 and the verify target then fails | yes |
| A README maps every record key under Test Data Provided to its record and consumer criterion | reviewer | none | — | — | every td-1794904930-5594-n key appears in the README | yes |
