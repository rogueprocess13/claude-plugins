# DoR adversarial fixtures (dor-quality-score)

One `.md` ticket body per case, proving the gate/score separation and that
documentation volume is never rewarded. Values below are the actual output of
`check_ticket_ready` against each fixture with `--no-fetch` and no
`--catalog` (i.e. `CATALOG_ABSENT` applies wherever a Test User section
exists), captured on the branch that introduced this table — re-run
`lib/tests/test-dor-check.sh` if a later change to `dor-check.sh` is meant to
move these numbers; the score values are illustrative of *relations*
(design.md: "the spec fixes the weights, the exclusion rule and the
anti-volume properties... not exact numbers except for the all-perfect and
all-empty fixtures"), not a frozen contract.

| # | File | Type | Status | Hard (missing) | Advisory | Gaps | Score |
|---|------|------|--------|-----------------|----------|------|------:|
| 01 | `01-excellent.md` | feature | ready | — | — | requirement_completeness, contradictory_requirements, deep_scope_ambiguity, edge_case_sufficiency | 95 |
| 02 | `02-minimal.md` | feature | ready | — | TEST_DATA_MISSING | requirement_completeness, deep_scope_ambiguity | 77 |
| 03 | `03-missing-intent.md` | feature | not-ready | INTENT_MISSING | VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING, TEST_DATA_MISSING | requirement_completeness, deep_scope_ambiguity | 49 |
| 04 | `04-useless-scope.md` | feature | ready | — | VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING, TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 61 |
| 05 | `05-vague-ac.md` | feature | not-ready | AC_VAGUE | VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING, TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 41 |
| 06 | `06-backend-no-verification.md` | chore | ready (not-ready under `DOR_STRICT_VERIFICATION=true`) | — | VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING, TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 64 |
| 07 | `07-fe-no-test-user.md` | feature | not-ready | TEST_USER_MISSING | TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 73 |
| 08 | `08-fe-no-nav-path.md` | feature | not-ready | NAV_PATH_MISSING | TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 75 |
| 09 | `09-backend-no-ui.md` | chore | ready | — | TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 84 |
| 10 | `10-bug-no-expected-actual.md` | bug | not-ready | INTENT_MISSING, REPRO_NO_EXPECTED_ACTUAL (never REPRO_MISSING — repro steps ARE present) | VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING | requirement_completeness, deep_scope_ambiguity | 56 |
| 11 | `11-contradictory-acs.md` | feature | ready | — | VPLAN_MISSING, TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity, edge_case_sufficiency | 69 |
| 12 | `12-unseeded-test-infra.md` | feature | ready | — | TEST_USER_UNRESOLVED, TEST_DATA_UNSEEDED | requirement_completeness, contradictory_requirements, deep_scope_ambiguity, edge_case_sufficiency | 81 |
| 13 | `13-impl-only-acs.md` | chore | ready (not-ready under `DOR_STRICT_AC_IMPL=true`) | — | AC_IMPLEMENTATION_ONLY, VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING, TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 41 |
| 14 | `14-typo-fix.md` | feature | ready | — | VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING, TEST_DATA_MISSING | requirement_completeness, deep_scope_ambiguity | 59 (< fixture 02's score) |
| 15 | `15-impl-guide-no-behavior.md` | chore | ready | — | AC_IMPLEMENTATION_ONLY, VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING, TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 41 (`acceptance_criteria` dimension == 0) |
| 16 | `16-edge-cases-missing-core.md` | feature | ready | — | TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity, edge_case_sufficiency | 83 |
| 17 | `17-self-verifying-no-vplan.md` | chore | ready | — | TEST_DATA_MISSING (never VPLAN_MISSING — satisfied by self-verifying AC) | requirement_completeness, contradictory_requirements, deep_scope_ambiguity | 84 |
| 18 | `18-backend-twin.md` | chore | ready | — | TEST_DATA_MISSING | requirement_completeness, contradictory_requirements, deep_scope_ambiguity, edge_case_sufficiency | 86 (`test_uat` dimension is `null`; score is not lower than an equivalent frontend ticket — see test-dor-check.sh) |
| 19 | `19-padding.md` | feature | ready | — | TEST_DATA_MISSING | requirement_completeness, deep_scope_ambiguity | 77 (== fixture 02's score — every AC line tripled + ~500 extra words in Background / Motivation change nothing) |

## Scenario mapping

- **01** — excellent ticket: substantive intent, layered Scope, outcome-bearing ACs (including an error case), a full Verification Plan, resolvable test user, nav path, constraints, related tickets. `DOR_SCORE` >= 90.
- **02** — minimal-but-executable: passes every hard code with the least content possible.
- **03** — missing intent: `Summary` only, no `Background / Motivation` / `Proposed Behaviour`.
- **04** — semantically useless scope: a Scope table whose only row is `Various | Everything | TBD` — `SCOPE_MISSING` does not fire (a table is present), but `deep_scope_ambiguity` is a gap.
- **05** — vague AC, including a widened term (`works correctly`, `handled gracefully`).
- **06** — backend reconciliation job with no meaningful verification: no self-verifying AC, no Verification Plan.
- **07** — frontend ticket missing its Test User section.
- **08** — frontend ticket missing its Navigation Path section.
- **09** — backend-only ticket with no UI context at all — ready, `test_uat` is `null`.
- **10** — bug with reproduction steps but no `Expected Behaviour` section.
- **11** — two acceptance criteria that directly contradict each other, otherwise a complete ticket — passes every hard/advisory deterministic check; `contradictory_requirements` is a gap, never a code.
- **12** — otherwise-excellent ticket whose test user role and test data are not concretely seeded.
- **13** — every AC line is pure implementation activity (`Add a PaymentRetryPolicy class...`) with no observable outcome.
- **14** — small, structurally complete ticket with one plain AC and no verification signal — scores below fixture 02.
- **15** — a long, six-item implementation checklist read like a migration runbook, with zero behavioural ACs.
- **16** — thorough edge-case ACs (expired/reused/malformed token) that never state the core requirement (a valid token actually resets the password).
- **17** — every AC states a concrete expected result (`returns 422`, `returns 201`); no Verification Plan table exists, and none is required.
- **18** — backend-only twin used to prove denominator fairness: an equivalent frontend ticket (built inline in the test from this fixture, with a Test User/Navigation Path added and no Test Data Prerequisites) scores no higher on account of the sections a backend ticket has no use for.
- **19** — padding: fixture 02 with every AC line tripled and ~500 extra words appended to Background / Motivation. Proves volume/repetition cannot raise `DOR_SCORE`.
