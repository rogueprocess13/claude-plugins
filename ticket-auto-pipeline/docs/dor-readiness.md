# DoR readiness — hard gates, advisory codes, and the diagnostic quality score

`ticket-auto-pipeline/lib/dor-check.sh` evaluates a ticket's body alone — no tracker mutation, no
model invocation — and answers two separate questions:

1. **Is this ticket structurally eligible to be dispatched to an autonomous agent?** (`DOR_STATUS`,
   decided solely by hard codes and waivers.)
2. **How complete and specific is the evidence this ticket carries, and what could a human or a
   future semantic evaluator still usefully look at?** (`dor_quality_score`, `DOR_DIMENSIONS`,
   `DOR_GAPS` — diagnostic only, **never** part of question 1's answer.)

This document covers both. See [`ticket-readiness-gate` spec](../../openspec/specs/ticket-readiness-gate/spec.md)
and [`readiness-quality-score` spec](../../openspec/changes/dor-quality-score/specs/readiness-quality-score/spec.md)
(promoted to `openspec/specs/` once `dor-quality-score` archives) for the full requirement text.

## Hard codes (decide `ready`/`not-ready`)

| Code | Fires when | Applicability |
|---|---|---|
| `SCOPE_MISSING` | No `## Scope` table with a `Layer` column | Always |
| `NAV_PATH_MISSING` | No Navigation Path section | Non-backend-only tickets |
| `TEST_USER_MISSING` | No Test User section | Non-backend-only tickets |
| `AC_MISSING` | No Acceptance Criteria section/checkboxes | Always |
| `AC_VAGUE` | Any AC line matches a vague-language pattern (original `audit_ac_testability` set, or the widened DoR-only set below) | Always |
| `REPRO_MISSING` | No reproduction steps | `type: bug` only |
| `FLAG_NEEDS_INFO` | Manifest `flags` contains `needs-info` (live, never cached) | Always |
| `INTENT_MISSING` | Body states neither a *why* nor a *desired outcome* with substantive content | Always |
| `REPRO_NO_EXPECTED_ACTUAL` | `Expected Behaviour`/`Actual Behaviour` missing or placeholder | `type: bug` only, independent of `REPRO_MISSING` |

`DOR_STATUS` is `not-ready` iff at least one hard code fails and is not waived (`ready.waived` in
the manifest). No score, dimension value, or gap ever affects `DOR_STATUS`.

### `INTENT_MISSING`

The body must state **both**:

- a **why**: `## Background / Motivation` (or an alias heading — `Motivation`, `Problem`, `Why`,
  `Context`); for a bug, `## Actual Behaviour` counts as the why.
- an **outcome**: `## Proposed Behaviour` / `Proposed Changes` (or an alias — `Desired Outcome`,
  `Goal`); for a bug, `## Expected Behaviour` counts as the outcome.

Each section's content must survive placeholder stripping (blank, `TBD`, `TODO`, `N/A`, `none`, an
unfilled `{...}` template token) and must not be a near-restatement of the `## Summary` line (token
Jaccard similarity ≥ 0.8). A `Summary: Implement password reset.` with no motivation or proposed
behaviour fails.

### `REPRO_NO_EXPECTED_ACTUAL`

Bug tickets only. Passes when both `Expected Behaviour` and `Actual Behaviour` are present with
non-placeholder content. Evaluated independently of `REPRO_MISSING` — a bug can fail either, both,
or neither.

## Advisory codes (reported, never block)

| Code | Fires when | Strict flag (promotes to hard) |
|---|---|---|
| `TEST_USER_UNRESOLVED` | Named test user/role does not resolve against the test-user catalog | `DOR_STRICT_CATALOG` |
| `TEST_DATA_MISSING` | No Test Data section | `DOR_STRICT_TEST_DATA` |
| `TEST_DATA_UNSEEDED` | Test Data section present but has no concrete detail | `DOR_STRICT_TEST_DATA` |
| `VPLAN_MISSING` | No Verification Plan table (unless ≥ half of unique AC lines are self-verifying — see below) | — |
| `VPLAN_ROW_GAP` | Verification Plan table has fewer rows than acceptance criteria | — |
| `VPLAN_UNVERIFIABLE` | No table row marked verifiable | — |
| `AC_IMPLEMENTATION_ONLY` | Every unique AC line describes implementation activity with no observable outcome | `DOR_STRICT_AC_IMPL` |
| `VERIFICATION_REQUIRED_NOT_SELF_VERIFYING` | No Verification Plan and no AC line carries a concrete expected value/result | `DOR_STRICT_VERIFICATION` |

All four strict flags default `false`, preserving default behaviour on every host.

### `AC_IMPLEMENTATION_ONLY`

Per deduplicated AC line: *impl* when it matches an implementation-verb pattern (`add`, `create`,
`implement`, `refactor`, `migrate`, `wire`, `introduce`, `update`, `extract`, `rename`, `install`,
`configure`) **and** no observable-outcome marker is present (a returned/displayed result, an HTTP
status code, a measurable bound like "within 200 ms", a resulting state, or what a user can/cannot
do). The code fires only when **every** AC line is impl — a single outcome-bearing line, even mixed
with implementation detail ("add an index on `customer_id` so the query returns within 200 ms"),
passes the whole set.

### `VERIFICATION_REQUIRED_NOT_SELF_VERIFYING` and the `VPLAN_MISSING` self-verifying rule

An AC line is *self-verifying* when it carries a concrete expected value (a status code, a
measurable bound, a quoted literal, an explicit "user can/cannot"). When at least half of the
unique AC lines are self-verifying and no Verification Plan exists, `VPLAN_MISSING` is recorded as
`pass: null, class: "satisfied-by-ac"` — it does **not** appear in `DOR_ADVISORY`. Otherwise, a
missing plan with fewer than half self-verifying lines is a genuine `VPLAN_MISSING` advisory, and
`VERIFICATION_REQUIRED_NOT_SELF_VERIFYING` fires only when there is *no* Verification Plan **and**
*zero* self-verifying AC lines.

### Widened `AC_VAGUE`

In addition to `audit_ac_testability`'s existing patterns (shared with `ticket-audit`, never
modified by this capability), `dor-check.sh` runs a second, DoR-only pass detecting `appropriate(ly)`,
`reasonabl[ey]`, `sufficient(ly)`, `robust(ly)`, `intuitive(ly)`, `seamless(ly)`, `graceful(ly)`, and
`(is|are|be|gets?) handled`, word-bounded. A line carrying a self-verifying marker is exempt — "a
duplicate submission is handled: the API returns 409 with message `already submitted`" passes.
Matches merge into the single `AC_VAGUE` code.

## `dor_quality_score` — what it is, and what it is not

`DOR_SCORE` (0–100, integer) and `DOR_DIMENSIONS` (per-dimension earned points or `null` for an
inapplicable dimension) measure the **completeness and specificity of observable readiness
evidence**. They are:

- **Diagnostic only.** No consumer in this codebase branches on them. There is no threshold that
  maps a score to `ready`/`not-ready`. A ticket can score 25 and still be `ready`; a ticket can
  score 95 on every other dimension and still be `not-ready` because it fails `INTENT_MISSING`.
- **Never a probability, confidence, or likelihood of successful execution.** Do not display it as
  a percentage chance of anything. It says how much evidence is present and specific, not whether
  that evidence is correct.
- **Immune to volume and repetition.** Every dimension is computed from presence checks and ratios
  over *deduplicated* acceptance criteria, each fraction capped at 1. Repeating an AC line, adding
  prose to Background / Motivation, or padding an implementation guide does not raise the score.

### Dimensions and weights

| Dimension | Weight | Inapplicable when |
|---|---:|---|
| `acceptance_criteria` | 20 | never |
| `verification` | 18 | never |
| `scope` | 15 | never |
| `intent` | 10 | never |
| `test_uat` | 10 | Scope table is backend-only |
| `context` | 8 | never |
| `completion` | 5 | never |
| `dependencies` | 5 | never |
| `constraints` | 5 | never |
| `edge_cases` | 4 | never |
| `requirement_completeness` | — | always (scored only by a future semantic evaluator) |

`DOR_SCORE = round(100 * Σ(earned) / Σ(weight of applicable dimensions))`. A dimension reported
`null` is excluded from **both** the numerator and the denominator — a backend-only ticket is never
penalised for lacking a Test User/Navigation Path section it has no use for, and its `context`
dimension is evaluated against backend signals (an endpoint, controller, service, job, cron, worker,
consumer, queue, CLI, or command reference) instead of a navigation path.

Exact per-dimension fractions are implementation-tunable — the spec fixes the weights, the exclusion
rule, and the anti-volume property, not exact numbers except for the all-perfect and all-empty
fixtures. See `lib/tests/fixtures/dor/README.md` for worked examples and the actual scores they
produce.

## `semantic_coverage_gaps`

`DOR_GAPS` names the readiness questions deterministic evaluation could not answer, drawn only from
a fixed, closed set:

| Gap | Included when |
|---|---|
| `requirement_completeness` | Acceptance criteria are present |
| `contradictory_requirements` | ≥ 2 unique AC lines exist |
| `deep_scope_ambiguity` | A Scope table is present |
| `edge_case_sufficiency` | The `edge_cases` dimension earned any points |

A gap is never emitted when its triggering condition is absent — a ticket that fails `AC_MISSING`
reports no `requirement_completeness` gap (the hard failure already says more). The absence of a
hard failure is never documented or displayed as proof of semantic correctness: contradiction
detection, requirement-completeness proof, and deep-scope-ambiguity resolution are all things this
deterministic check explicitly does **not** attempt — it only names that they remain open.

## Body-hash caching

`ensure_ticket_readiness` is the single resolution path every consumer should use instead of a raw
manifest read. On a cache hit it resolves the ticket body from **local sources only** (an explicit
`--body` file, then the planner's `body.md` — never a live tracker fetch, so a cache hit never costs
a Linear read). If a local body resolves, the cache carries a `body_hash`, and the two hashes
differ, it recomputes and recaches (waivers are preserved — see `set_ticket_readiness` below).
Otherwise (no local body, or a legacy cache with no `body_hash`) it trusts the cached verdict as-is
— a legacy cache is deliberately never retroactively invalidated by a newer, stricter hard code.

## Manifest `ready` object

```json
{
  "status": "ready" | "not-ready",
  "checked_at": "2026-09-30T00:00:00Z",
  "missing": ["INTENT_MISSING"],
  "advisory": ["VPLAN_MISSING"],
  "waived": {"AC_VAGUE": {"by": "jwillard", "reason": "..."}},
  "score": 72,
  "dimensions": {"intent": 10, "scope": 15, "test_uat": null, "...": "..."},
  "gaps": ["requirement_completeness", "deep_scope_ambiguity"],
  "body_hash": "sha256:ab12..."
}
```

`score`, `dimensions`, `gaps`, and `body_hash` are all optional — a manifest predating this
capability, or a legacy-backfill waiver, simply has no `score` key. `set_ticket_readiness <TID>
<status> <missing_json> <advisory_json> [<extras_json>]`'s optional 5th argument carries these four
fields; any other key is rejected with exit 3, and extras omitted from a call are **absent** from
the written object — a fresh verdict never carries a previous verdict's stale score.

## Semantic-evaluator seam

`DOR_DIMENSION_KEYS` (`lib/dor-check.sh`) is the single source of the readiness dimension
vocabulary: `intent`, `scope`, `acceptance_criteria`, `verification`, `context`, `test_uat`,
`dependencies`, `constraints`, `edge_cases`, `completion`, `requirement_completeness`. A future
semantic evaluator (JEV) writes:

```json
"ready": {
  "...": "...",
  "semantic": {
    "evaluator": "jev-v1",
    "checked_at": "2026-10-01T00:00:00Z",
    "body_hash": "sha256:ab12...",
    "findings": [
      {"dimension": "requirement_completeness", "severity": "blocking", "code": "MISSING_CORE_AC", "detail": "..."}
    ]
  }
}
```

A `blocking` finding joins `ready.missing` as `SEMANTIC_<DIMENSION_UPPER>` under the exact same
status/waiver rule `set_ticket_readiness` already applies — no consumer or waiver mechanism needs to
change. **This capability reserves and documents this shape only; no code in this repository reads
or writes `ready.semantic` yet.**

## What stays outside deterministic evaluation

This check can prove structural presence and apply keyword heuristics. It cannot, and does not
attempt to:

- Prove that acceptance criteria are complete (only that they are present and not obviously vague).
- Detect contradictory requirements (surfaced only as the `contradictory_requirements` gap, never a
  code).
- Judge whether a Scope table's content is meaningful, only whether one exists (a Scope table whose
  only row reads `Various | Everything | TBD` passes `SCOPE_MISSING`; `deep_scope_ambiguity` is the
  honest signal).
- Invoke a model, or make any judgement requiring semantic understanding beyond keyword/structure
  matching.

## Related docs

- [`ticket-auto-pipeline/CLAUDE.md`](../CLAUDE.md) — `dor-check.sh` row, `ready` manifest schema
- [`pipeline-log-format.md`](../pipeline-log-format.md) — `dor_quality_score` in `runs.jsonl`
- `lib/tests/fixtures/dor/README.md` — the 19 adversarial fixtures and their actual output
