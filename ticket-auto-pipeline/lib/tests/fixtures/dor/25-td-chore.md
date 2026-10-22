<!-- planner:testdata-synth -->
## Summary

Seed the synthetic upload test data that the client-upload tickets verify against.

## Background / Motivation

The client-upload acceptance criteria need a 1,000-row valid upload file and a client with no configuration. Nothing in the repository creates them, so verification of those tickets would run against missing data.

## Proposed Behaviour

A repeatable seed target loads synthetic upload fixtures into the local environment, and a verify target confirms they are present.

## Acceptance Criteria

- [ ] The seed command exits 0 on two consecutive runs
- [ ] The verify command passes
- [ ] Every seeded client row references an existing tenant (foreign keys hold)
- [ ] The seed data is synthetic only and contains no production PII

## Scope

| Layer | Service    | Area         |
| ----- | ---------- | ------------ |
| BE    | client-svc | seed-fixtures |

## Test Data Provided

- `td-INIT-9-1` — a 1,000-row valid upload file (for upload-validate AC 1)
- `td-INIT-9-2` — a client with no configuration (for upload-validate AC 2)

Seed command: `make seed-upload-test-data`
Verify command: `make verify-seed-upload-test-data`
Seed channel: files

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Seed is idempotent | — | — | none (Source: none) | exit 0 twice | ✓ |
| 2 | Verify passes | — | — | none (Source: none) | exit 0 | ✓ |
| 3 | Foreign keys hold | — | — | none (Source: none) | verify reports 0 orphan rows | ✓ |
| 4 | Synthetic only | — | — | none (Source: none) | verify reports no production-shaped emails | ✓ |

## Test Data Prerequisites

None — no acceptance criterion needs test data.
