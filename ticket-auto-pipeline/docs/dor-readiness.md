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
| `NAV_PATH_MISSING` | No actual click path: a `## Navigation Path` heading with real (non-placeholder) content, a `**Navigation Path:**` label with text, a backticked `` `A > B` `` path, or a Verification Plan `Navigation path` cell holding `A > B`. The bare phrase "navigation path" — including the Verification Plan column header — does not count | Non-backend-only tickets |
| `TEST_USER_MISSING` | No Test User section | Non-backend-only tickets |
| `AC_MISSING` | No Acceptance Criteria section/checkboxes | Always |
| `AC_VAGUE` | Any AC line matches a vague-language pattern (original `audit_ac_testability` set, or the widened DoR-only set below) | Always |
| `REPRO_MISSING` | No reproduction steps | `type: bug` only |
| `FLAG_NEEDS_INFO` | Manifest `flags` contains `needs-info` (live — re-derived on every cache hit, see Body-hash caching) | Always |
| `INTENT_MISSING` | Body states neither a *why* nor a *desired outcome* with substantive content | Always |
| `REPRO_NO_EXPECTED_ACTUAL` | `Expected Behaviour`/`Actual Behaviour` missing or placeholder | `type: bug` only, independent of `REPRO_MISSING` |

`DOR_STATUS` is `not-ready` iff at least one hard code fails and is not waived (`ready.waived` in
the manifest). No score, dimension value, or gap ever affects `DOR_STATUS`.

### `INTENT_MISSING`

The body must state **both**:

- a **why**: `## Background / Motivation` (or an alias heading — `Motivation`, `Problem`, `Why`,
  `Context`, `Impact`); for a bug, `## Actual Behaviour` counts as the why.
- an **outcome**: `## Proposed Behaviour` / `Proposed Changes` (or an alias — `Desired Outcome`,
  `Goal`, `Desired Behaviour`, `Desired Behavior`); for a bug, `## Expected Behaviour` counts as
  the outcome.

Every shipped template carries a passing pair under its own headings: feature `Background /
Motivation` + `Proposed Behaviour`, improvement `Motivation` + `Desired Behaviour`, chore
`Background / Motivation` + `Proposed Changes`, security `Impact` + `Proposed Changes`, bug
`Actual Behaviour` + `Expected Behaviour`.

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
| `TEST_DATA_MISSING` | No Test Data section. **Hard by default on a body that carries the Source contract** (except `chore`/`security`) — see below. | `DOR_STRICT_TEST_DATA` (legacy body); an explicit `DOR_STRICT_TEST_DATA=false` demotes the contract case to advisory |
| `TEST_DATA_UNSEEDED` | Test Data section present but has no concrete detail. **Hard by default on a contract body** (except `chore`/`security`). | as `TEST_DATA_MISSING` |
| `TEST_DATA_UNSOURCED` | Test data is described, but at least one item does not say where it comes from — see below. **Hard by default on a body that carries the Source contract.** | `DOR_STRICT_TEST_DATA` (legacy body); `DOR_STRICT_TEST_DATA_SOURCE=false` demotes the contract case to advisory |
| `VPLAN_MISSING` | No Verification Plan table (unless ≥ half of unique AC lines are self-verifying — see below) | `DOR_STRICT_VPLAN` |
| `VPLAN_ROW_GAP` | Verification Plan table has fewer rows than acceptance criteria | `DOR_STRICT_VPLAN` |
| `VPLAN_UNVERIFIABLE` | No table row marked verifiable: no row's Verifiable-column cell is `✓`, `✔`, `Y` or `Yes` (other cells are never read; a table with no Verifiable column counts as none marked) | `DOR_STRICT_VPLAN` |
| `AC_IMPLEMENTATION_ONLY` | Every unique AC line describes implementation activity with no observable outcome | `DOR_STRICT_AC_IMPL` |
| `VERIFICATION_REQUIRED_NOT_SELF_VERIFYING` | No Verification Plan and no AC line carries a concrete expected value/result | `DOR_STRICT_VERIFICATION` |

All five strict flags default `false`, preserving default behaviour on every host, with one
exception: on a body that carries the Source contract, an unset `DOR_STRICT_TEST_DATA` counts as
`true` for `TEST_DATA_MISSING`/`TEST_DATA_UNSEEDED` (see below).
`DOR_STRICT_TEST_DATA_SOURCE` is the one switch that defaults `true`; it only affects
`TEST_DATA_UNSOURCED` on a body that carries the Source contract (see below).
`DOR_STRICT_VPLAN` (planner-ready-by-construction) promotes all three `VPLAN_*` codes together —
it does not affect the `satisfied-by-ac` self-verifying escape hatch below, and is independent of
`DOR_STRICT_VERIFICATION`: a host can enforce the "something self-verifying exists" floor
immediately while still observing planner-written Verification Plan tables advisory-only until it
trusts their quality on real tickets.

### `TEST_DATA_MISSING` / `TEST_DATA_UNSEEDED` on a contract body (planner-test-data-derivation)

A body carries the Source contract when at least one item — a Test Data Prerequisites item **or**
a Verification Plan `Test data needed` cell — has a `Source:` of a known kind (the same detection
as `TEST_DATA_UNSOURCED` below). Because the Verification Plan cell counts, a contract body with
no `## Test Data Prerequisites` section at all is still recognised as one.

| Body | `DOR_STRICT_TEST_DATA` unset | `=true` | `=false` |
|---|---|---|---|
| contract, type not `chore`/`security` | **hard** | hard | advisory |
| contract, `chore` or `security` | advisory | hard | advisory |
| legacy (no known Source anywhere) | advisory | hard | advisory |

The default lives in code, for the same reason as `TEST_DATA_UNSOURCED`'s: the planner's
Refinement caches the verdict and ticket-auto's gate may recompute it in another process, so both
must agree without a shared env var. `chore` and `security` are exempt from the contract default
because `planned-ticket-body-check.sh` does not require their Test Data Prerequisites section
either; a synthesized test-data chore (which provides data rather than consuming it) must never
fail readiness on its own missing section. The planner's composer always writes the section on
planned tickets, using `None — no acceptance criterion needs test data.` when nothing needs data;
that line is concrete, so it passes both codes.

### `TEST_DATA_UNSOURCED` (issue #505)

`TEST_DATA_MISSING`/`TEST_DATA_UNSEEDED` measure whether the Test Data section exists and says
something. Neither asks whether a verifier can actually obtain what it describes, so a long,
concrete description of data that nothing creates used to pass. `TEST_DATA_UNSOURCED` reads the
`Source: <kind>[:<value>]` field defined in
[ticket-planner/docs/test-data-source.md](../../ticket-planner/docs/test-data-source.md) — that
file is the contract; change the grammar there first.

**Items.** Each item is one of:

- a list item (`-`, `*`, `+`, `1.`, `1)`) under `## Test Data Prerequisites` (or any `## Test Data…`
  heading) — the planner writes `- <what>. Source: <source>`. Nesting:
  - a wrapped continuation line, and a nested sub-bullet **without** its own `Source:`, are detail
    of the item above them and are joined to it;
  - a nested sub-bullet **with** its own `Source:` is an item of its own. Joining it would let a
    sibling's Source hide a `generate`, since the last Source on a line wins. Its parent stays an
    item (unsourced unless it has its own Source), except a lead-in parent — its own text ends in
    `:` and has no Source, like `- Upload files:` — which is dropped so only its children count;
  - an unindented line directly under an item (no blank line) joins it when it is a mid-sentence
    wrap (the item does not end in `.!?:;` and the line starts lower-case); an unindented line
    that starts a new sentence and carries its own Source is an item of its own;
- a data row of a table under that heading;
- a non-empty `Test data needed` cell of the Verification Plan table — the planner writes
  `<what> (Source: <source>)`. The #499 composer writes `not recorded in spec` for an AC no
  Verification Notes entry covers; that item is unsourced with the reason
  `verification note not recorded`;
- in either table, a column headed `Source` is read as the item's Source (it overrides an inline
  one). Cells split on unescaped `|` only — `\|` inside a cell does not shift the columns;
- when the Test Data section has no list or table at all, each prose line (a legacy free-text section).

Fenced code blocks are ignored.

**Reading a Source** follows the contract's reader rules, mirroring Crosscheck's parser
(`ticket-planner/lib/planner-crosscheck-testdata.sh`): the marker matches case-insensitively,
`*` is removed and `_` is removed where it wraps a word, the **last** `Source:` on an item wins,
backticks are ignored, trailing `.,;:!` is stripped (also around the closing paren of the cell
form, so `(Source: seeded-by:pack).` parses), the kind is lowercased, and a `seeded-by` value is cut
at its first whitespace, as Crosscheck does. A bare `—`/`–` cell counts as none. One deliberate
difference: the marker must not follow a letter, so `Resource: …` is not a Source.

| Item | Verdict |
|---|---|
| `exists:<non-empty>`, `external:<non-empty>`, `seeded-by:<slug>` (`[A-Za-z0-9_-]+`) | sourced |
| no `Source:`, `generate`, an unknown kind, an empty value, `Source: none` on real data | unsourced |
| the test data itself is none (`none`, `n/a`, `no test data…`, … — the contract's list) | not applicable |

At ticket level `seeded-by:<slug>` is not resolved against specs (they live with the initiative,
not the ticket); its presence is enough. Crosscheck already checked the reference at plan time.

**Severity depends on whether the body carries the contract** — at least one item's `Source:`
parses to a known kind (`exists`, `seeded-by`, `external`, `generate`, `none`). Informal text such
as `Data source: billing team` or `Source: the staging DB` does not make a contract body, so it
cannot hard-fail `/ticket-create`. A `## Planner Context` block does not either: the planner writes
Source fields from 0.17.0 on, and those are what opt a body in.

- **Contract body** — every item must be sourced. The code is **hard by default**, so the
  planner's Refinement scan and ticket-auto's planned-ticket gate hold it strictly without either
  having to set a flag. A host can set `DOR_STRICT_TEST_DATA_SOURCE=false` to observe it
  advisory-only. A data need the operator deliberately left as `generate` (for example a
  `--accept`ed `TEST_DATA_UNOWNED`) is cleared per ticket with
  `dor-check.sh --waive <TID> TEST_DATA_UNSOURCED "<reason>"`.
- **Legacy body** (neither) — advisory, promoted to hard only by the existing
  `DOR_STRICT_TEST_DATA`. A legacy item counts as sourced when it carries informal `Source:` text
  or a conservative prose marker: `seeded/provided/generated/created/supplied/loaded/imported by
  <party>` (the party, after an optional the/a/an, not a placeholder such as `someone`, `TBD` or
  `the business` — rejected only when that word is the whole party, so `the business team`
  counts); a path (contains `/` plus a file extension, starts with `./`, `../` or `/`, ends in `/`,
  or is a URI such as `s3://…`); or a tracker id (2-10 uppercase letters and a number, excluding
  standards and product-code prefixes such as `COVID-19`, `SKU-123`, `UTF-8`). These markers are never consulted on a contract
  body, so this check cannot disagree with Crosscheck on one.

**What fails by default.** Only a body that uses the contract — at least one Source of a known
kind — and still has an unsourced item. In practice that is a ticket written by ticket-planner
0.17.0 or later (or by hand in that shape) with a `generate`, an empty or unknown Source, a missing
Source on one item, or a `not recorded in spec` Verification Plan cell. Hand-written tickets with no
Source fields, and planned tickets created before 0.17.0 (a Planner Context block but no Source
fields — in flight when this shipped), are legacy bodies: they get the advisory and never fail by
default. Remedy a contract body per ticket with `--waive`, or per host with
`DOR_STRICT_TEST_DATA_SOURCE=false`.

**Why a separate switch, not `DOR_STRICT_TEST_DATA`.** Issue #505 asked for "the same
advisory/strict switch as the existing test-data codes". This deliberately differs: a readiness
verdict is computed in one process (Refinement, which caches it in the manifest) and may be
recomputed in another (ticket-auto's gate, `/ticket-create`). An opt-in env var set in one and not
the other would give two verdicts for the same body. The contract case is therefore strict by
default with an opt-out, so the verdict is the same everywhere unless a host opts out everywhere.
The legacy case keeps the issue's switch.

The code is `inapplicable` when `TEST_DATA_MISSING` or `TEST_DATA_UNSEEDED` already fired, and
passes when every item says its test data is none. The detail names each unsourced item —
`tdp#<n>` for a Test Data item, `vplan#<n>` for a Verification Plan row — with its reason, at
most 10, with `|`, CR and LF removed.

The `test_uat` score dimension gives the test-data component half credit when this code fires.

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

**`FLAG_NEEDS_INFO` is the one exception to trusting the cache.** It mirrors the manifest's live
`flags`, not the body, so a body-hash match says nothing about it. A verdict computed while the
flag was set cached `FLAG_NEEDS_INFO` in `missing`; once `needs-info-resolved` cleared the flag
(a released human hold, `/ticket-approve`), an unchanged-body cache hit kept reporting it and the
ticket stayed not-ready until a full re-appraisal rewrote the verdict. On every cache hit
`_dor_reconcile_cached_needs_info` now re-derives that one code from the live flag and, when it
differs from the cache, writes the corrected verdict back through `set_ticket_readiness` — so
`status` is recomputed against preserved waivers, a semantic verdict whose `body_hash` still
matches is carried forward, and a raw `ticket_is_ready` read agrees afterwards. No other code is
touched.

**What clears the flag.** `needs-info` is added by `ticket-critique` and by fleetd when it creates a
human hold (`post_human_hold_comment`). It is cleared only by the `needs-info-resolved` trigger,
which has two callers: `/ticket-approve` (`approve.sh`) and fleetd's hold-reconcile pass when a
`human` hold is released by a qualifying answer (`gate_hold.clear_needs_info_on_release`, called
from `Supervisor._hold_reconcile_pass` after the store release succeeds). An answer typed in
Linear with no hold to release — e.g. a reply to a `ticket-critique` comment — still needs
`/ticket-approve`; the manifest flag is authoritative and the tracker only receives its
projection.

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
`dependencies`, `constraints`, `edge_cases`, `completion`, `requirement_completeness`.

**Implemented (dor-semantic-evaluator).** The semantic evaluator is `dor-semantic-v2`
(`lib/dor-semantic.sh`, `lib/dor-semantic-parse.sh`, `agents/dor-semantic-agent.md`) — full contract
in [docs/dor-semantic-schema.md](dor-semantic-schema.md). In outline: an agent is spawned twice per
ticket, scan (body only) then audit (body plus the deterministic result), each writing one result
block; `dor_semantic_apply` validates every finding's quote against the body (verbatim, after
normalisation) before storing anything, so an unverifiable claim blocks visibly
(`SEMANTIC_UNVERIFIED`) rather than passing silently. A blocking finding joins `ready.missing` as
`SEMANTIC_<DIMENSION_UPPER>` under the exact same status/waiver rule `set_ticket_readiness` already
applies — no consumer or waiver mechanism needed to change:

```json
"ready": {
  "...": "...",
  "semantic": {
    "evaluator": "dor-semantic-v2",
    "checked_at": "2026-10-01T00:00:00Z",
    "body_hash": "sha256:ab12...",
    "findings": [
      {"code": "MISSING_CORE_AC", "dimension": "requirement_completeness", "severity": "blocking",
       "quote": "...", "detail": "...", "verified": true}
    ],
    "gaps": {"requirement_completeness": {"verdict": "finding", "reason": "..."}, "...": "..."},
    "audit": [{"code": "AC_VAGUE", "verdict": "disputed", "reason": "..."}],
    "missed": [], "score_plausible": true, "score_reason": "..."
  }
}
```

`ready.semantic` is written only by `manifest-write.sh`'s `set_ticket_semantic` — the third writer of
`ready`, alongside `set_ticket_readiness` and `waive_ticket_readiness_code`, under the same readiness
lock. A deterministic rescan (`set_ticket_readiness`) preserves `semantic` when the fresh body hash
still matches `semantic.body_hash`, or replaces every prior `SEMANTIC_*` code with the single code
`SEMANTIC_STALE` when it doesn't — a ticket edited after its semantic verdict can never pass on the
deterministic check alone. `ensure_ticket_readiness` exports the cached verdict as `DOR_SEMANTIC` on
every return path. **The only caller today is the planner's Refinement phase**
(`planner-refinement-phase`) — no ticket carries a `SEMANTIC_*` code until that phase runs the
evaluator on it; `ticket-critique`'s overlapping checks (AC testability, scope, edge cases) are
unchanged and uncoordinated with this pass, a noted follow-up.

**Advisory test-data backstop (dor-semantic-test-data-gap).** `TEST_DATA_GAP` (dimension
`test_uat`) catches an acceptance criterion that needs data to exist before it can be verified
when the Test Data Prerequisites section neither lists that data nor names its source — the case
the planner's keyword heuristic misses, including an all-`none` planner body that this deterministic
check treats as legacy. It is **advisory only**, fixed in code by `DOR_SEMANTIC_ADVISORY_ONLY_CODES`:
it never joins `ready.missing` and never blocks dispatch. Refinement surfaces it instead, as a
`META|refinement-testdata|warn` line and an `Advisory (does not block)` summary. Promotion to
blocking waits on a live golden sweep (`lib/tests/fixtures/dor/README.md`, Semantic expectation).

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
