# Semantic DoR Block Schema

**Schema-Version: 1**
**Defined by:** `openspec/changes/dor-semantic-evaluator/specs/dor-semantic-evaluation/spec.md`
**Parser:** `lib/dor-semantic-parse.sh`
**Emitted by:** `agents/dor-semantic-agent.md`, via `dor_semantic_prompt scan|audit` (`lib/dor-semantic.sh`)

## Overview

The deterministic Definition-of-Ready check (`lib/dor-check.sh`) proves structural
presence — a section exists, an AC line avoids known vague words. It cannot judge
whether the ACs are the *right* ACs, whether two requirements contradict each other,
whether a scope is meaningful, or whether an autonomous agent could execute the ticket
without asking a human. The semantic evaluator answers those questions, spawned twice
per ticket:

1. **Scan** — reads only the ticket body. Emits `=== DOR_SEMANTIC_SCAN ===`.
2. **Audit** — reads the body plus the deterministic result. Emits
   `=== DOR_SEMANTIC_AUDIT ===`.

The scan never sees the deterministic verdict — LLM judges anchor strongly on a prior
verdict, so isolating the two spawns is a structural defence, not a convenience.

**This file is the source of truth.** The agent prompt supplies parameters; it does not
restate the field set or the grammar.

## Closed code vocabulary (`DOR_SEMANTIC_CODES`)

| Code | Dimension |
|---|---|
| `MISSING_CORE_AC` | `requirement_completeness` |
| `NEEDS_HUMAN_DECISION` | `requirement_completeness` |
| `INTENT_AC_MISMATCH` | `intent` |
| `CONTRADICTORY_REQUIREMENTS` | `acceptance_criteria` |
| `SCOPE_AMBIGUOUS` | `scope` |
| `EDGE_CASE_GAP` | `edge_cases` |
| `TEST_DATA_GAP` | `test_uat` — **advisory only** (see below) |
| `UNSTATED_DEPENDENCY` | `dependencies` |
| `AC_NOT_TESTABLE` | `verification` |

Every dimension above is a member of `DOR_DIMENSION_KEYS` (`lib/dor-check.sh`) — the
deterministic and semantic evaluators share one definition of readiness. An unknown
code rejects the block. The prompt fixes a precedence order (the table order above) and
requires one code per underlying issue — a rerun must not rename the same issue under a
different code.

`TEST_DATA_GAP` (dor-semantic-test-data-gap) fires when an acceptance criterion needs
records, users, files or state to exist before it can be verified, and the Test Data
Prerequisites section neither lists that data nor names its source. It is the semantic
backstop for the planner's keyword test-data heuristic, which misses criteria that imply
data without naming it. A threshold, a timeout, an attempt count or an HTTP status is not
data. `UNSTATED_DEPENDENCY` no longer covers "prior state": a flag, a service or another
ticket is a dependency, test data is `TEST_DATA_GAP`. `DETAIL` is **required** for this code
(what data, in what state, how many) — an empty `DETAIL` rejects the whole block.

Three further codes are **bash-owned** — never emitted by the model, always blocking,
unaffected by `DOR_SEMANTIC_ADVISORY_CODES`:

| Code | Meaning |
|---|---|
| `SEMANTIC_UNAVAILABLE` | The caller could not obtain a valid result, after its own retry. |
| `SEMANTIC_UNVERIFIED` | A finding's quote (or a gap marked `finding`) failed the evidence check. |
| `SEMANTIC_STALE` | The manifest's `body_hash` no longer matches `semantic.body_hash`. |

## Severity is decided by bash

A semantic result never carries a severity field. `_dor_semantic_severity` decides, in
this order: a bash-owned code is `blocking`; a code in the fixed in-code constant
`DOR_SEMANTIC_ADVISORY_ONLY_CODES` (currently `TEST_DATA_GAP`) is `advisory` — no env var,
strict flag or ticket type can make it blocking, and promotion is a code change that
removes it from the constant; otherwise a finding is `blocking` unless its code is listed
in the space-separated env var `DOR_SEMANTIC_ADVISORY_CODES` (default empty), read the same
way as the `DOR_STRICT_*` flags — in which case it is `advisory`. An advisory-only finding
still goes through the quote check: a non-verbatim quote stores `verified: false` and adds
`SEMANTIC_UNVERIFIED`, as for every code.
A blocking finding adds `SEMANTIC_<DIMENSION_UPPER>` (e.g. `SEMANTIC_REQUIREMENT_COMPLETENESS`)
to `ready.missing`, de-duplicated by dimension, not by code — a waiver survives a rerun
that names a sibling code for the same gap. Advisory findings are stored in
`ready.semantic` only, never joining `missing`.

## Format

### Scan block (Schema-Version 1)

```
=== DOR_SEMANTIC_SCAN ===
SCHEMA_VERSION: 1
TICKET: WIL-123
BODY_HASH: sha256:ab12...
FINDING_1_CODE: MISSING_CORE_AC
FINDING_1_QUOTE: the export should work correctly
FINDING_1_DETAIL: no AC states what "correctly" means for a partial-page export
FINDING_2_CODE: CONTRADICTORY_REQUIREMENTS
FINDING_2_QUOTE: all fields are optional
FINDING_2_QUOTE_B: name and email are required
FINDING_2_DETAIL: AC-1 and AC-3 disagree on whether name/email are required
GAP_REQUIREMENT_COMPLETENESS: finding
GAP_REQUIREMENT_COMPLETENESS_REASON: see FINDING_1
GAP_CONTRADICTORY_REQUIREMENTS: finding
GAP_CONTRADICTORY_REQUIREMENTS_REASON: see FINDING_2
GAP_DEEP_SCOPE_AMBIGUITY: clear
GAP_DEEP_SCOPE_AMBIGUITY_REASON: scope table names exactly the two affected screens
GAP_EDGE_CASE_SUFFICIENCY: not-applicable
GAP_EDGE_CASE_SUFFICIENCY_REASON: ticket has no branching behaviour
=== END DOR_SEMANTIC_SCAN ===
```

`FINDING_n_*` is a numbered group, `n` starting at 1 with no required contiguity in the
raw text (the parser sorts by `n`, gaps are tolerated). A finding needs `CODE` and
`QUOTE`; `QUOTE_B` is mandatory for `CONTRADICTORY_REQUIREMENTS` (any other code may
carry it too, harmlessly); `DETAIL` is optional free text.

All four `GAP_*` verdicts are **mandatory on every scan block**, each one of
`clear|finding|not-applicable`, each with a matching `GAP_<NAME>_REASON`. This is the
backstop against a skipped or injected clean result: the model must take an explicit
position on every semantic question, and `dor_semantic_apply` checks that a gap marked
`finding` has a matching finding in that gap's dimension (`GAP_REQUIREMENT_COMPLETENESS`
↔ `requirement_completeness`/`MISSING_CORE_AC` or `NEEDS_HUMAN_DECISION`,
`GAP_CONTRADICTORY_REQUIREMENTS` ↔ `acceptance_criteria`/`CONTRADICTORY_REQUIREMENTS`,
`GAP_DEEP_SCOPE_AMBIGUITY` ↔ `scope`/`SCOPE_AMBIGUOUS`, `GAP_EDGE_CASE_SUFFICIENCY` ↔
`edge_cases`/`EDGE_CASE_GAP`) — a mismatch adds `SEMANTIC_UNVERIFIED`.

### Audit block (Schema-Version 1)

```
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
TICKET: WIL-123
BODY_HASH: sha256:ab12...
AUDIT_1_CODE: AC_VAGUE
AUDIT_1_VERDICT: disputed
AUDIT_1_REASON: "handles errors gracefully" is qualified by AC-4's explicit retry table
AUDIT_1_QUOTE: - [ ] A failed save retries 3 times, then shows the error toast
MISSED_1_CODE: UNSTATED_DEPENDENCY
MISSED_1_REASON: ticket assumes a feature flag exists with no reference to who owns it
SCORE_PLAUSIBLE: yes
SCORE_REASON: 62 matches a ticket with AC present but no verification plan
=== END DOR_SEMANTIC_AUDIT ===
```

`AUDIT_n_*` is a numbered group: `CODE` (a deterministic hard or advisory code),
`VERDICT` (`agree|disputed|uncertain`), `REASON` (mandatory when `VERDICT` is
`disputed`, and must cite ticket text), and an optional `QUOTE` — on a `disputed` entry
only, a single line copied verbatim from the section the code checks (parsed as
`quote`; absent when not given). **Every hard code in the deterministic result's
`missing` list must have an `AUDIT_n` entry** — an unaudited hard code rejects the
block. Audit entries for advisory codes are optional; one omitted advisory line never
rejects the block. `MISSED_n_*` (`CODE`, `REASON`) names a semantic code the model
believes the deterministic pass and its own scan should have caught but didn't;
optional, any count. `SCORE_PLAUSIBLE` (`yes|no`) and `SCORE_REASON` judge the
diagnostic `dor_quality_score`.

A `disputed` verdict is recorded in `ready.semantic.audit` with its reason and, by
default, **never** removes, waives, or demotes the deterministic code — see "A disputed
deterministic code stays blocking" below. The opt-in exception is audit demotion.

## Key syntax

Same framing as `human-hold-schema.md`: keys match `[A-Z][A-Z0-9_]*`, one `KEY: value`
pair per line, values are single-line plain text — no nested JSON, no quoting, no
escaping — a value may contain `"`, `$`, backticks, `$(...)`, `&&`, `;`, and the parser
treats every value as data, never evaluating it. The first `:` separates key from
value, so a value may contain further colons. The block is the **last content of the
agent's return** — write ordinary prose first, then append the block; anything after
the closing marker is ignored. Duplicate keys, keys outside `[A-Z][A-Z0-9_]*`, and a
`SCHEMA_VERSION` other than `1` all reject the block.

## Evidence: quotes are anchors, checked verbatim after normalisation

`QUOTE` must be text that appears in the ticket body. For a finding about *absent*
content (`MISSING_CORE_AC`, `UNSTATED_DEPENDENCY`) the quote is the intent or AC
sentence that implies the missing thing — an anchor, not proof of the gap itself.
`CONTRADICTORY_REQUIREMENTS` requires both `QUOTE` and `QUOTE_B`. Values are single
line; a quote spanning lines in the source is quoted from one of its lines.

`dor_semantic_apply` normalises both the body and the quote before a substring test:
whitespace is collapsed, smart quotes and dashes are folded to ASCII, and markdown
emphasis markers (`*`, `_`, `` ` ``) and leading list/table markers are stripped. A
quote that still does not match makes that finding `verified: false` and adds
`SEMANTIC_UNVERIFIED` — a failed quote check blocks visibly rather than silently
dropping the finding.

## Result binding and versioning

`dor_semantic_apply` rejects (exit 1, nothing written) a result whose `TICKET` differs
from the ticket id it was called with, or whose `BODY_HASH` differs from
`_dor_body_hash` of the body file it is given. `DOR_SEMANTIC_EVALUATOR="dor-semantic-v3"`
is stamped into `ready.semantic.evaluator` on every stored result; it changes whenever
the prompt, code vocabulary, or block schema changes, so a caller can decide whether a
cached verdict is current by comparing body hash and evaluator string. `v2`
(dor-semantic-test-data-gap) added `TEST_DATA_GAP` to the prompt and code vocabulary; the
block schema is unchanged (`SCHEMA_VERSION: 1`, four gaps), so every `v1` block still
parses. The planner's Refinement phase re-runs a cached `v1` verdict once.

`v3` (planner-refinement-convergence) adds finding identity and lineage, per-ticket
rounds, and the scoped-rescan hint; the block schema is again unchanged. A stored `v2`
verdict whose `body_hash` equals the current body is **migrated in place** by
`dor_semantic_migrate_v2 <TID> <body-file>` — no agent runs: bash computes each
finding's units and id, labels every finding `new`, starts `ready.lineage` at round 1,
and stamps `migrated_from: "dor-semantic-v2"` on both. Exit 0 migrated, 2 nothing to
migrate (no verdict, another evaluator, a changed, stale or unavailable verdict), 1
error. A `v2` verdict on a changed body is rescanned as usual, so the bump only
rescans edited tickets.

## Finding identity, lineage and rounds (`v3`)

`dor_semantic_apply` annotates every finding and writes `ready.lineage` through
`set_ticket_lineage` (which `set_ticket_semantic` never touches and
`set_ticket_readiness` copies forward):

- **Units.** `dor-check.sh`'s `_dor_section_records … units`: one unit per `##`
  section, except that each Acceptance Criteria item is its own unit
  (`<heading>/ac:<sha8>`). `_dor_unit_of <body> <quote>` prints every unit whose
  text contains the quote (normalised as for the verbatim check, lowercased, a
  leading checkbox/number marker dropped), in body order; the first is the
  finding's `unit` (anchor), all are its `units`. `QUOTE_B`'s units are appended
  to `units`. An unverified finding has no unit.
- **Identity.** `id = f-<12 hex of sha256(code \n anchor \n normalised quote)>`
  (`_dor_semantic_finding_id`).
- **Round.** 1 with no lineage, another evaluator, or a reset (at least
  `DOR_SEMANTIC_ROUND_RESET_SHARE`, default `0.5`, of the prior non-inert sections
  added, removed or changed — `reset: true`); unchanged on the same body hash (a
  retry, or a body rebased by an inert-only edit); otherwise +1.
- **Lineage label.** `carried` when the id was in the prior lineage (its
  `first_round` copied); `drift` when the id is new, the round is 2 or more, every
  unit is unchanged since the prior lineage, and none of them holds a finding that
  persisted from it; `new` otherwise, and always for an unverified finding. After
  a reset nothing is carried. `lineage.resolved` lists the prior ids now absent.
- **Demotion.** A blocking finding whose code is not in
  `DOR_SEMANTIC_STRUCTURAL_CODES` (default `NEEDS_HUMAN_DECISION
  CONTRADICTORY_REQUIREMENTS UNSTATED_DEPENDENCY INTENT_AC_MISMATCH`) is stored
  `severity: "advisory"` with `demoted: "drift"` when it is drift and
  `DOR_SEMANTIC_DRIFT_DEMOTE=true` (library default `false`), else
  `demoted: "round-limit"` when `DOR_SEMANTIC_MAX_ROUNDS` is a positive integer
  and the round exceeds it (unset: no round-limit demotion). An overridden
  structural list warns on stderr (`dor-semantic: policy override: …`).

```json
"lineage": {
  "round": 2, "reset": false, "evaluator": "dor-semantic-v3",
  "body_hash": "sha256:…", "section_hashes": {"Summary": "sha256:…"},
  "units": {"Acceptance Criteria/ac:1a2b3c4d": "sha256:…"},
  "findings": [{"id": "f-0123456789ab", "code": "EDGE_CASE_GAP",
                "unit": "Acceptance Criteria/ac:1a2b3c4d",
                "units": ["Acceptance Criteria/ac:1a2b3c4d"],
                "first_round": 1, "lineage": "carried"}],
  "resolved": [],
  "counts": {"new": 0, "carried": 1, "drift": 0, "resolved": 0, "unverified": 0},
  "first_audit": {"body_hash": "sha256:…", "evaluator": "dor-semantic-v3", "audit": []},
  "policy": {"structural": ["NEEDS_HUMAN_DECISION", "…"], "overridden": false,
             "drift_demote": false, "max_rounds": null, "round_reset_share": 0.5,
             "inert": ["Related Tickets"],
             "audit_demotable": ["VPLAN_ROW_GAP", "…"], "audit_demotable_overridden": false}
}
```

`lineage.findings` holds verified findings only. `first_audit` is the first audit
applied for a body hash; a later audit on the same hash leaves it unchanged.
`counts.unverified` counts findings with `verified: false`.

**Scoped rescan.** `dor_semantic_prompt scan … --changed-sections "<h1|h2…>"` lists
the changed sections under `**Changed sections**` and asks for findings about them, or
about their conflicts with the rest, quoting the changed section first. The scan stays
blind to the deterministic result.

## `--det-result` file shape

The audit spawn's parse call passes `--det-result <file>`, a JSON file with at minimum
`{"missing": [...], "advisory": [...]}` — the same arrays `check_ticket_ready` sets as
`DOR_MISSING`/`DOR_ADVISORY`. The parser reads only these two arrays, to check that
every hard code in `missing` has a matching `AUDIT_n_CODE` entry.

## Exit codes (`lib/dor-semantic-parse.sh`)

`parse_dor_semantic --kind scan|audit --result-file <path> [--det-result <file>]`:

- **0** — a valid block was parsed. Canonical JSON on stdout.
- **1** — invalid or absent block (closing marker missing, malformed line, duplicate or
  malformed key, unsupported `SCHEMA_VERSION`, a closed-enum violation, a missing gap
  verdict, an unaudited hard code, or no block at all — unlike `human-hold-parse.sh`,
  an absent block is **not** a normal outcome here; a scan/audit run is required to
  produce a usable result on every invocation, so "no block" rejects like any other
  malformed block).
- **2** — the parser could not run (usage error, unreadable file, `jq` missing).

Tolerant at the transport boundary: CRLF, blank lines, indented markers, any field
order, a `claude -p --output-format json|stream-json` envelope. Strict at the contract
boundary: required fields, closed enums, `SCHEMA_VERSION` equality, duplicate keys,
last-complete-block-wins, an unclosed last block is invalid. The parser writes no
pipeline log line — the caller owns its own log grammar (unlike `adr-gate-parse.sh`/
`human-hold-parse.sh`, which write `META|adr-gate`/`META|human-hold` themselves).

`DETAIL`/`REASON` values pass through the same secret-shaped-value redaction as
`human-hold-parse.sh`'s `_hh_redact` before they reach JSON.

**Deliberate deviation from `adr-gate-parse.sh`/`human-hold-parse.sh`:** `set -eo
pipefail` is scoped to the `BASH_SOURCE == $0` CLI block only, not file scope — sourcing
the parser never enables `errexit` in the caller.

## `ready.semantic` shape

Written by `manifest-write.sh`'s `set_ticket_semantic <TID> <semantic_json>` — the third
writer of a ticket manifest's `ready` object, alongside `set_ticket_readiness` and
`waive_ticket_readiness_code`, under the same `_manifest_readiness_lock`:

```json
"ready": {
  "...": "...",
  "semantic": {
    "evaluator": "dor-semantic-v3",
    "checked_at": "2026-10-01T00:00:00Z",
    "body_hash": "sha256:ab12...",
    "findings": [
      {"code": "MISSING_CORE_AC", "dimension": "requirement_completeness",
       "severity": "blocking", "quote": "the export should work correctly",
       "detail": "no AC states what \"correctly\" means for a partial-page export",
       "verified": true}
    ],
    "gaps": {
      "requirement_completeness": {"verdict": "finding", "reason": "see FINDING_1"},
      "contradictory_requirements": {"verdict": "clear", "reason": "..."},
      "deep_scope_ambiguity": {"verdict": "clear", "reason": "..."},
      "edge_case_sufficiency": {"verdict": "not-applicable", "reason": "..."}
    },
    "audit": [
      {"code": "AC_VAGUE", "verdict": "disputed",
       "reason": "qualified by AC-4's explicit retry table"}
    ],
    "missed": [
      {"code": "UNSTATED_DEPENDENCY", "reason": "..."}
    ],
    "score_plausible": true,
    "score_reason": "...",
    "unavailable": false,
    "stale": false
  }
}
```

`set_ticket_semantic` requires an existing `ready` object (exit 3 otherwise) and, in
order: reads `ready.missing`; removes every `SEMANTIC_`-prefixed element; appends
`SEMANTIC_<DIMENSION_UPPER>` for each blocking finding plus any bash-owned code,
de-duplicated; sets `ready.semantic` to the supplied object; recomputes `ready.status`
from `missing - keys(waived)`. It never touches `checked_at`, `advisory`, `waived`,
`score`, `dimensions`, `gaps`, or `body_hash` — `checked_at` stays because
fleet-controller's D-18 detector reads it as the not-ready-since clock.

## Deterministic rescans preserve or invalidate the semantic verdict

When `set_ticket_readiness` rewrites `ready` for a manifest whose existing `ready`
carries `semantic`:

- new `body_hash` equals `semantic.body_hash` → keep `semantic` and every `SEMANTIC_*`
  code from the previous `missing`;
- otherwise → keep `semantic` with `stale: true`, drop the previous `SEMANTIC_*` codes,
  and add the single code `SEMANTIC_STALE`.

`status` is then recomputed as always. A body edited after the semantic verdict was
recorded can therefore never pass dispatch or the entry gate on the deterministic check
alone — it must be re-evaluated. `semantic` remains outside `set_ticket_readiness`'s
allowed extras keys; only `set_ticket_semantic` ever writes it.

## A disputed deterministic code stays blocking

`disputed` is recorded in `ready.semantic.audit` with its reason. By default it never
removes, waives, or demotes the deterministic code — it is a **waiver candidate**:
consumers print the reason and the exact `dor-check.sh --waive <TID> <CODE> "<reason>"`
command. Only a human waives. `BODY_DRIFT` and `BODY_UNVERIFIED` can never be waived:
`waive_ticket_readiness_code` refuses them (exit 3) and points at
`/ticket-planner resume <INIT> --refresh-bodies`.

### Audit demotion (shipped dark)

`dor_audit_demote <TID> <body-file>` (planner-refinement-convergence D5) is the one
exception, and nothing calls it unless the planner runs with
`PLANNER_REFINEMENT_AUDIT_DEMOTE=true`. It reads only `ready.lineage.first_audit`, and
only when that audit and `ready.body_hash` are both for the body file's current hash —
a retried audit on the same body cannot re-roll a dispute. An entry qualifies when:

1. its verdict is `disputed`;
2. its code is not never-demote (`DOR_AUDIT_NEVER_DEMOTE`, a fixed constant: the
   presence codes, the `TEST_DATA_*`/`TEST_USER_*` family, `CATALOG_ABSENT`,
   `VERIFICATION_REQUIRED_NOT_SELF_VERIFYING`, `FLAG_NEEDS_INFO`, `BODY_UNAVAILABLE`,
   `BODY_DRIFT`, `BODY_UNVERIFIED`, and every `SEMANTIC_*` code — checked first) and is in
   `DOR_AUDIT_DEMOTABLE_CODES` (default `VPLAN_ROW_GAP VPLAN_UNVERIFIABLE AC_VAGUE
   AC_IMPLEMENTATION_ONLY NAV_PATH_MISSING`; an override warns at apply time and is
   snapshotted as `lineage.policy.audit_demotable`/`audit_demotable_overridden`);
3. the code is in `ready.missing` and not waived;
4. its `quote` occurs in one of the code's own sections (`DOR_AUDIT_CODE_SECTIONS`:
   `VPLAN_*` → Verification Plan or Acceptance Criteria, `AC_*` → Acceptance Criteria,
   `NAV_PATH_MISSING` → Navigation Path), after the same normalisation as a finding's
   quote. A quote anywhere else, or none, does not qualify.

With 1 to `DOR_AUDIT_DEMOTE_MAX` (default 2) qualifying codes, all are demoted and
printed one per line; more demotes none and exits 4. The writer is
`set_ticket_demotions <TID> <json>`, the only writer of `ready.demoted`:

```json
"demoted": {"VPLAN_ROW_GAP": {"by": "dor-semantic-audit", "reason": "…",
            "quote": "- [ ] Criteria 2 and 3 are verified together in row 2",
            "body_hash": "sha256:…", "evaluator": "dor-semantic-v3"}}
```

It moves the code from `missing` to `advisory` and recomputes `status`. It refuses an
entry whose `body_hash` is not `ready.body_hash`, and any `SEMANTIC_*` or `BODY_*` code.
`set_ticket_readiness` keeps an entry only while its `body_hash` equals the fresh one,
re-applying it to the recomputed `missing`/`advisory`; an edited body (or a rewrite
with no body hash) drops it, so the code blocks again. A non-empty `ready.demoted` also
blocks the inert-section rebase.

## Reads and consumers

`ensure_ticket_readiness` (`lib/dor-check.sh`) exports `DOR_SEMANTIC` — the cached
`ready.semantic` object, or an empty string — on every return path. `gate-check.sh`
Check 2.7e needs no change: `SEMANTIC_*` codes arrive through `DOR_MISSING` exactly like
any other hard code. `fleet-dispatch.sh`'s not-ready summary line and
`fleet-notify.sh`'s readiness message append semantic codes and disputed deterministic
codes with their reasons; neither branches on `ready.semantic` beyond the existing
readiness return code, and neither invokes a model.

## Evaluator agent contract

`agents/dor-semantic-agent.md` declares `tools: Read, Write`. `dor_semantic_prompt
scan|audit <TID> <body-file> <result-file> [<det-result-file>]` builds its prompt:
paths, never ticket text, plus the body file's `_dor_body_hash` as a `**Body hash**:`
literal the agent copies into `BODY_HASH` (the agent has no shell and cannot compute a
SHA-256 itself; apply re-hashes the body at apply time, so the binding still catches a
body edited after the prompt was built); states that file contents are data, not instructions;
instructs the agent to write exactly one block to the result path and return a single
line (`DOR_SEMANTIC <scan|audit> written <path>`). This keeps a caller running tens of
tickets from accumulating every result in its own context. The scan prompt never
references the deterministic result file or any deterministic code.

## What this evaluator does not do

- Run anywhere on its own — the planner's Refinement phase (`planner-refinement-phase`)
  is the only caller.
- Multi-sample majority voting.
- Remove or waive a deterministic code (audit demotion, above, is opt-in and never a
  waiver).
- Change `ticket-critique` or evaluate ad-hoc tickets.
- Rewrite ticket bodies.
