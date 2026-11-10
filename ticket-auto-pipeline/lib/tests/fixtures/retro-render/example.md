## Failure Histogram

Sources scanned: ticket-auto 5 log(s), planner 1 log(s).

| Code | Count |
|------|-------|
| EXEC_NO_ARTIFACT | 4 |
| APPROVAL_REVOKED | 2 |

## Complexity Calibration

| Declared \ Outcome | Smooth | Rough | Hard |
|--------------------|--------|-------|------|
| simple             | 6      | 1     | 1    |
| complex ⚠ confounded | 3    | 1     | 0    |

**False-simple rate:** 0.250 (2 of 8 simple tickets went Rough/Hard; lower is better)
**False-simples:** ABC-47 (Hard), ABC-52 (Rough)
**Unscoreable:** 1 missing declared, 0 missing outcome

The complex row is shown for completeness only: a complex classification changes the
treatment, so its outcomes are not scored.

## Complexity Calibration Notes

| Ticket | Source | Gap |
|--------|--------|-----|
| ABC-47 | appraise | Complexity sweep underestimated — undiscovered Feign dependency |
| ABC-48 (complex, confounded) | exec | Plan artifact missed a required DB migration |

**Corrected:**
- ABC-47: Feign client to billing is in scope
- ABC-48: Add the V12 migration

