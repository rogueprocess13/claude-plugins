## Summary

Accountant reports and exports include only documents that have passed classification, so a report never mixes in documents whose type is still unknown.

## Outcome

**Serves:** O2

**Who:** Accountant

**Need:** Build client reports from documents whose classification is known and trusted.

**Outcome:** Reports and exports leave out documents that have not passed classification.

## Background / Motivation

Reports currently include every document the pipeline has touched, including ones still waiting for classification or confirmation. An accountant can export a report that silently contains unclassified documents and only find out when the totals look wrong.

## Proposed Behaviour

Every accountant report and export lists only documents marked Classified. The report header shows how many documents were left out because they are not yet classified, so the accountant knows the report is incomplete rather than wrong.

## Technical Context

- Report and export routes under `app/api/professional/` filter on `documents.classification_status = 'classified'` instead of the legacy pipeline `status` column.
- The excluded count comes from the same query with the opposite predicate.
- No schema change: `classification_status` already exists (computed column).

## Acceptance Criteria

- [ ] A report for a client with 4 classified and 2 unclassified documents lists exactly 4 documents
- [ ] The report header shows "2 documents not yet classified"
- [ ] The CSV export for the same client contains exactly 4 data rows
- [ ] A report for a client with only classified documents shows no excluded-count message

## Out of Scope

Changing how classification itself works. Showing the excluded documents inside the report.

## Scope

| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | web     | professional-reports |
| BE    | api     | professional reports and exports |

## Test User

`accountant@example.com` — password `admin`

## Navigation Path

`Clients > Client detail > Reports > Document summary`

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Report lists only classified | accountant | Clients > Client detail > Reports | client with 4 classified + 2 unclassified docs | 4 documents listed | ✓ |
| 2 | Excluded count shown | accountant | Clients > Client detail > Reports | same client | "2 documents not yet classified" | ✓ |
| 3 | Export matches report | accountant | Clients > Client detail > Reports | same client | CSV has 4 data rows | ✓ |
| 4 | No message when none excluded | accountant | Clients > Client detail > Reports | client with only classified docs | no excluded-count message | ✓ |

## Test Data Prerequisites

One client with four classified and two unclassified documents, and a second client whose documents are all classified.

## Related Tickets

None.

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-TEST
**Epic:** EPIC-1
**Confidence:** 0.88
**Strategy:** Conservative
**Decision:** Filter reports on classification_status
**Affected Services:** web, api
**Target Symbols:** getFirmStats:lib/db.ts:2947
**Pre-approved:** true
**Generated:** 2026-10-03T00:00:00Z
**Regenerate:** false
**Kind:** business
**Serves:** O2
