# ADR Gate Request/Result Block Schema

**Schema-Version: 1**
**Defined by:** `openspec/changes/adr-governance-gate/specs/adr-gate/spec.md`
**Parser:** `lib/adr-gate-parse.sh` (result block only — the request is composed by the caller, not parsed by bash)
**Emitted by:** any pipeline phase (request), `skills/adr-gate/SKILL.md` (result)

## Overview

The ADR gate is the one reusable primitive every pipeline phase invokes when
it meets a potential architectural decision. **The gate owns the
classification** — a caller reports an observation and never decides whether
an ADR is required; deciding that is the gate's entire job. This mirrors
[human-hold-schema.md](human-hold-schema.md)'s framing exactly: the durable
machine contract is the **field set** below, not the marker envelope. The
`=== ADR_GATE_REQUEST ===` / `=== ADR_GATE_RESULT ===` envelopes and their
`KEY: value` bodies are transport, chosen for the same reason human-hold's
are — nothing in the bash path offers constrained decoding, and the text
crosses a boundary where a model composes a shell command.

## Request format

```
=== ADR_GATE_REQUEST ===
SCHEMA_VERSION: 1
PHASE: IMPLEMENT
DECISION_CANDIDATE: Route all outbound webhook delivery through a single retry queue instead of per-caller retry logic
IDENTIFIED_REASON: Every caller currently reimplements its own backoff, and a shared queue would change the failure contract webhook consumers see
AFFECTED_COMPONENTS: webhook-dispatcher, notification-service
EVIDENCE: lib/webhook-client.rb:44-80, lib/notifier/backoff.rb
CURRENT_APPROACH: per-caller inline retry with exponential backoff
PROPOSED_APPROACH: single shared retry queue with a dead-letter path
=== END ADR_GATE_REQUEST ===
```

### Request field reference

| Field | Required | Description |
|---|---|---|
| `SCHEMA_VERSION` | Yes | Current version: `1`. |
| `PHASE` | Yes | The emitting phase — any of `APPRAISE`, `EXEC`, `GATE`, `IMPLEMENT`, `VERIFY`, `PR-REVIEW`, `MAINTENANCE`, or the `ticket-planner` phase name. |
| `DECISION_CANDIDATE` | Yes | Plain description of the matter the caller observed — not a request for a specific verdict. |
| `IDENTIFIED_REASON` | Yes | Why this looked worth raising. The caller's observation, never its conclusion. |
| `AFFECTED_COMPONENTS` | No | Component/service names, used for candidate-discovery pre-filtering. Absence does not block the request — see § Unnarrowed discovery. |
| `EVIDENCE` | No | File:line references or other pointers supporting the candidate. |
| `CURRENT_APPROACH` | No | What exists today, when the candidate concerns changing something. |
| `PROPOSED_APPROACH` | No | What the caller is about to do, when applicable. |

### Unnarrowed discovery

When `AFFECTED_COMPONENTS` is absent, the gate does not refuse the request —
it proceeds using the remaining evidence and records that candidate
discovery ran unnarrowed (against the full `decisions/index.md` rather than
a component-filtered subset). A caller that cannot yet name components has
still demonstrated the matter is worth classifying.

## Result format

```
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: true
ADR_VERDICT: CREATED_PROPOSED
ADR_ID: ADR-0012
GOVERNING_ADR:
CONFLICT:
HUMAN_DECISION_REQUIRED: true
RATIONALE: No existing ADR addresses webhook retry strategy; this establishes a cross-cutting constraint on every future webhook caller
=== END ADR_GATE_RESULT ===
```

### Result field reference

| Field | Required | Description |
|---|---|---|
| `SCHEMA_VERSION` | Yes | Current version: `1`. |
| `ADR_REQUIRED` | Yes | `true`/`false` — whether the matter needed governance at all. `false` only on `NOT_ARCHITECTURAL`. |
| `ADR_VERDICT` | Yes | Exactly one of the five closed values — see § Closed verdict set. |
| `ADR_ID` | Verdict-dependent | The ADR this result concerns: the newly drafted id on `CREATED_PROPOSED`/`SUPERSEDE_REQUIRED`, the governing id on `GOVERNED`, the contradicted id on `CONFLICT`. Empty on `NOT_ARCHITECTURAL`. |
| `GOVERNING_ADR` | `GOVERNED` only | The Accepted ADR id, duplicated from `ADR_ID` for readability at the call site. |
| `CONFLICT` | `CONFLICT` only | A short explanation of the contradiction. Mandatory whenever `ADR_VERDICT: CONFLICT` — see § CONFLICT requires a named ADR. |
| `HUMAN_DECISION_REQUIRED` | Yes | `true`/`false` — `true` for `CREATED_PROPOSED` and `SUPERSEDE_REQUIRED`, `false` otherwise. This is what a caller routes on to decide whether to emit a hold. |
| `RATIONALE` | Yes | One or two sentences explaining the verdict, always populated regardless of which verdict — every verdict is a classification decision and every classification decision gets a stated reason. |

The block is the **last content of the gate's return** — write ordinary
prose first (the classification reasoning), then append the block.

## Closed verdict set

Exactly one of:

| Verdict | Meaning | Creates an ADR | Blocks the phase |
|---|---|---|---|
| `NOT_ARCHITECTURAL` | Refused — the default disposition (see § below). | No | No |
| `GOVERNED` | An Accepted ADR already answers this. | No | No — continues subject to the named ADR. |
| `CREATED_PROPOSED` | New territory; a Proposed ADR now records it. | Yes (`proposed`) | Yes — human hold. |
| `CONFLICT` | The proposed approach contradicts an Accepted ADR. | No | Yes — gate-stop. |
| `SUPERSEDE_REQUIRED` | The proposal would change an Accepted decision. | Yes (`proposed`, `supersedes` set) | Yes — human hold. |

A result carrying `ADR_VERDICT` outside this set is rejected by
`adr-gate-parse.sh` as unusable — never treated as any particular verdict,
blocking or not.

## `NOT_ARCHITECTURAL` is the default and the load-bearing verdict

The gate returns `NOT_ARCHITECTURAL` unless reversing the decision would
materially change the architecture or constrain future implementation —
that reversibility test is the gate's actual justification, not a vibe
check. Library choices, class introductions, method-level design, naming,
routine bug fixes, and local implementation choices do not qualify on their
own, however the caller described them. A caller describing a library
choice as "architectural" does not make the gate agree — see the routing
contract below.

## Routing contract per verdict

- **`NOT_ARCHITECTURAL`** — the phase continues immediately. No log entry
  beyond the standard `META|adr-gate` verdict record (see § Every verdict is
  recorded). No ADR, no hold, no gate-stop.
- **`GOVERNED`** — the phase continues, bound by the named ADR's constraint.
  No new ADR, no hold.
- **`CREATED_PROPOSED`** — the phase emits a `=== HUMAN_HOLD ===` block with
  `REASON: ARCH_COMMITMENT`, `BLOCKS` naming the new ADR's path and its
  `## Decision` section (see [human-hold-schema.md](human-hold-schema.md)).
  The phase does not proceed toward implementation or merge on the strength
  of this decision until the ADR is accepted. The ticket also gets the
  `needs-adr` label.
- **`CONFLICT`** — the phase emits the structural gate-stop `ADR_CONFLICT`
  and the run halts. This is not a park: "you are wrong" needs rethinking,
  not ratifying, and resumes differently than a hold does. The ticket also
  gets `needs-adr`.
- **`SUPERSEDE_REQUIRED`** — same hold mechanics as `CREATED_PROPOSED`,
  `BLOCKS` naming the replacement ADR. The original Accepted ADR is left
  untouched pending acceptance of the replacement.

## `GOVERNED` returns the constraint, not just the id

A `GOVERNED` result names the governing ADR **and** states the relevant
constraint in `RATIONALE`, because a caller that only learns an id still has
to go read the file before it can act — the gate has already read it, so it
states the constraint inline.

## `CONFLICT` requires a named ADR

A `CONFLICT` verdict with an empty `ADR_ID`/`CONFLICT` is rejected by the
parser as unusable rather than treated as a valid blocking verdict — an
LLM-issued conflict claim with nothing to point at could otherwise halt a
pipeline on a hallucination. A rejected result never halts anything; it
degrades to "the gate result could not be used," and the caller proceeds as
if no gate-stop-worthy result was returned (logged, not silently dropped).

## Search discipline — the index is not the source of truth

`{WIKI_ROOT}/decisions/index.md` is used only for cheap candidate discovery
by component overlap and title match. It is never sufficient on its own to
issue `GOVERNED`, `CONFLICT`, or `SUPERSEDE_REQUIRED` — the gate reads the
candidate ADR **documents** before any of those three verdicts, because a
one-line index summary cannot carry the constraint text `GOVERNED` must
return or the reasoning `CONFLICT` must justify. An ADR whose index row
looks unrelated but whose body actually governs the reported decision still
produces `GOVERNED` once the gate has read it.

## The gate never stops the pipeline itself

The gate SHALL NOT emit a human-hold block, a gate-stop entry, or a tracker
mutation. It writes the ADR (on `CREATED_PROPOSED`/`SUPERSEDE_REQUIRED`) and
returns a verdict; the **calling phase** owns the stop. This keeps one owner
for the stop mechanism, matching the human-hold protocol's own design where
the phase agent emits the block and fleetd/the parser consume it — the gate
runs inside the caller's turn, and the block must be the last content of the
*phase's* return, not the gate's.

## Every verdict is recorded

Every gate invocation writes `META|adr-gate|info|{json}` to the pipeline log
regardless of verdict, carrying at minimum `verdict`, `adr_id` (may be
empty), and `phase`. This is what makes park rate measurable from the first
run — see `design.md` D3 and the over-parking risk mitigation.

## Tolerant transport, strict contract

Same posture as `human-hold-parse.sh`: tolerated silently are leading/
trailing whitespace, CRLF line endings, blank lines inside the block, fields
in any order, and any well-formed key outside the known set. Rejected at the
contract boundary:

- A line inside the block that is not `KEY: value`.
- A missing or empty required field (`SCHEMA_VERSION`, `ADR_REQUIRED`,
  `ADR_VERDICT`, `HUMAN_DECISION_REQUIRED`, `RATIONALE`).
- `ADR_VERDICT` outside the closed set.
- `ADR_VERDICT: CONFLICT` with an empty `ADR_ID` or `CONFLICT`.
- A missing `=== END ADR_GATE_RESULT ===` closing marker.

An unusable result never halts the pipeline and is never reported as a
success — see [adr-gate-invocation spec](../openspec/changes/adr-governance-gate/specs/adr-gate-invocation/spec.md).

## Related

- [ADR schema](adr-schema.md) — what the gate writes on `CREATED_PROPOSED`/`SUPERSEDE_REQUIRED`
- [Human Hold schema](human-hold-schema.md) — the sibling contract this reuses for parking
- [Pipeline log format](../pipeline-log-format.md) — the `META|adr-gate` channel and the `ADR_CONFLICT` gate-stop code
