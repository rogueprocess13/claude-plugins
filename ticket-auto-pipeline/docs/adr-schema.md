# ADR File Schema

**Schema-Version: 1**
**Defined by:** `openspec/changes/adr-governance-gate/specs/adr-store/spec.md`, `specs/adr-governance/spec.md`
**Store / validator:** `lib/adr-store.sh`, `lib/adr-check.sh`
**Written by:** `skills/adr-gate/SKILL.md`, `skills/wiki-maintenance/SKILL.md` (promotion path)

## Overview

An Architecture Decision Record (ADR) is a durable governance record under
`{WIKI_ROOT}/decisions/{NNNN}-{slug}.md`. It exists to make an architectural
commitment discoverable by later work and to make "an architectural decision
requires human ratification" a property the pipeline enforces rather than a
convention it merely states. Every ADR is produced by the [ADR gate](adr-gate-schema.md)
or by `wiki-maintenance`'s decision-promotion path — never authored free-hand
by a pipeline phase.

## `architecture.md` is not an ADR

`ticket-planner` Phase 3 writes `architecture.md` — an **initiative-scoped
working design** artifact consumed by planner Phase 4. It is never
auto-promoted into an ADR: the two artifacts have different lifetimes and
different authority. `architecture.md` reflects one initiative's reasoning
and can be wrong, abandoned, or superseded within the planning session
itself; an ADR is a durable record that binds *future* work across the
repository. When the planner identifies an architectural commitment inside
Phase 3, it invokes the gate — a classification request, exactly like any
other phase's — rather than publishing Phase 3's output directly. An
initiative that dies before the gate is invoked leaves no ADR, and that is
accepted: the store is a record of governing decisions, not a complete
planning archive.

## Format

### Schema-Version 1

```
---
id: ADR-0007
status: proposed
date: 2026-09-11
components: [billing-service, ledger]
ticket: CRE-142
deciders: []
supersedes: ""
superseded_by: ""
---

# ADR-0007: Use PostgreSQL row-level security to enforce tenant isolation

## Context

...

## Decision

...

## Considered Options

...

## Consequences

...

## Affected Components

...
```

## Frontmatter fields

| Field | Required | Description |
|---|---|---|
| `id` | Yes | `ADR-NNNN`, four digits, assigned by `_next_adr_number()` — never agent-chosen. |
| `status` | Yes | One of the five values in § Status transitions. |
| `date` | Yes | `YYYY-MM-DD`, the date the file was written. |
| `components` | Yes | List of affected component/service names, used for the gate's candidate-discovery pre-filter. |
| `initiative` / `ticket` / `manual` | Exactly one | The idempotency source key — see § Idempotency below. Whichever is absent is omitted from the file entirely, not written empty. |
| `deciders` | Required when `status: accepted`, else `[]` | Non-empty list of human decider names/handles once accepted. An ADR cannot become `accepted` with an empty list. |
| `supersedes` | No | The `ADR-NNNN` id this ADR replaces, set only when drafting a replacement (§ Supersession). |
| `superseded_by` | No | Set only once this ADR has itself been superseded — see § Superseded and Deprecated are distinct. |

### Idempotency

The idempotency key is the frontmatter source value, **not the filename**.
Titles — and therefore slugs — legitimately change between a draft and a
re-run, while the source id is stable. `_adr_exists_for <id>` greps
frontmatter across the store before any write, so a re-run for the same
`initiative:`/`ticket:`/`manual:` value never creates a duplicate file, even
under a different slug.

## Required and optional sections

Required (non-empty on every ADR): `## Context`, `## Decision`,
`## Considered Options`, `## Consequences`, `## Affected Components`.

Optional: `## Decision Drivers`, `## Rationale`, `## Constraints`,
`## Related ADRs`. `## Constraints` is kept optional rather than required
because it substantially overlaps `## Consequences → Negative`; requiring
both would produce the same sentence twice.

`## Considered Options` records only options that were genuinely considered
or are necessary to explain the decision — a single real option is a valid,
complete entry. Fabricating alternatives to make an ADR look more thorough
than the decision actually was is a defect, not thoroughness.

## The title states a decision, not a topic

The heading SHALL take the form `# ADR-NNNN: <imperative decision>`.

**Good:** `# ADR-0007: Use PostgreSQL row-level security to enforce tenant isolation`

**Bad:** `# ADR-0007: Tenant isolation` — this names a subject area, not a
decision, and is rejected by `adr-check.sh`.

## Status transitions

An ADR is created with status `proposed`. The only valid transitions:

```
proposed  → accepted
proposed  → rejected      (terminal)
accepted  → superseded    (terminal)
accepted  → deprecated    (terminal)
```

`rejected`, `superseded`, and `deprecated` are all terminal — there is no
onward edge from any of them, including from `deprecated` back to
`accepted` or forward to any other value. Any transition not listed above
(`proposed → superseded`, `accepted → proposed`, etc.) is rejected by
`adr-check.sh`.

## Superseded and Deprecated are distinct

- **`superseded`** means a specific newer ADR replaces this decision. The
  superseded ADR SHALL carry `superseded_by` naming that ADR. `superseded`
  with an empty `superseded_by` is invalid.
- **`deprecated`** means the decision no longer applies and no replacement
  is asserted. `deprecated` SHALL NOT carry `superseded_by`. A `deprecated`
  ADR with a non-empty `superseded_by` is invalid.

Conflating the two loses information a later reader needs: "this was wrong,
here's what replaced it" is a different fact from "this stopped mattering."

## Authority model — agents propose, humans accept

An agent (the gate, or the maintenance promotion path) can identify a
potential architectural decision, research it, identify alternatives,
create an ADR with status `proposed`, identify conflicts with existing
ADRs, and recommend whether an ADR is required. An agent SHALL NOT mark an
ADR `accepted`, modify an Accepted ADR, supersede an Accepted ADR, invent
architectural policy, or create an Accepted ADR on any path. `adr_accept`
(in `lib/adr-store.sh`) rejects invocation from an agent context outright.

## Accepted ADRs are immutable in meaning

An Accepted ADR SHALL NOT be silently edited. Changing an accepted decision
requires, strictly in order:

1. A new Proposed ADR.
2. Explicit identification of the ADR being replaced (`supersedes`).
3. An explanation of why the previous decision is no longer appropriate.
4. Human approval (`adr-store.sh accept` on the replacement).
5. Only then, the previous ADR's transition to `superseded`.

`adr-check.sh` detects a body change to an Accepted ADR with no
corresponding supersession and reports it as an immutability violation —
this holds regardless of the editor's intent, including a well-meant
wording fix. A wording improvement to an Accepted ADR still requires a
superseding ADR; there is no "cosmetic edit" exception.

## Supersession procedure

A replacement ADR is created as `proposed` with `supersedes` naming the
Accepted original. The original remains `accepted` and untouched — its file
is never written — until a human accepts the replacement, at which point
`adr_supersede` sets `superseded_by` on the original and flips its status to
`superseded` in the same operation. This is permitted only once the
replacement is itself `accepted`; a `proposed` replacement never triggers
supersession of the original.

## ADR prose is plain English

An ADR's prose sections pass through the `simple-english` skill in Plain
mode before the file is written. The pass applies **only** to ADRs with
status `proposed` — an Accepted ADR is never reworded, because rewording a
ratified decision is exactly what supersede-don't-edit forbids, sealed or
not. The pass never touches frontmatter, code identifiers, component or
service names, ADR ids, or provenance tags (ticket ids, initiative ids).

This ordering constraint — plain-English pass happens *before* the write,
and only on the `proposed` path — is what makes the "a decision must be
unambiguous" rule mechanically checkable: `simple-english` permits only
`can`/`will`/`must` and bans `should`/`would`/`may`/`might`/`could` in
committed prose, so `adr-check.sh` can reject a `## Decision` section
containing a hedging modal (see [adr-validation](../openspec/changes/adr-governance-gate/specs/adr-validation/spec.md))
as a purely mechanical check, without ever re-deriving what "unambiguous"
means.

### `simple-english` fallback

`simple-english` is a host-side skill and is not vendored inside this
plugin. If it is unavailable at draft time, its core rules (write in plain
words; state the decision as a fact, not a suggestion; ban hedging modals in
`## Decision`) are applied inline by the drafting agent rather than the pass
being skipped. The `## Decision` hedging check in `adr-check.sh` runs either
way, so an ADR that skipped the full skill still cannot ship with a hedged
decision.

## Enforcement

`adr-check.sh` (schema, id validity/uniqueness, required fields and
sections, status/transition validity, `supersedes` reciprocity,
new-ADRs-are-Proposed, Accepted-ADR immutability, the `## Decision`
hedging-modal check) is the whole-store validator. It is enforced in three
places, each covering different content:

1. **This repo's CI** runs it against a small, committed fixture ADR store
   (`ticket-auto-pipeline/lib/tests/fixtures/adr-store/`) — a regression
   check on the validator's own behaviour, independent of the bash unit-test
   harness.
2. **`wiki-maintenance`'s commit step** (Step 4) runs it against the live
   `WIKI_ROOT` before every commit this pipeline makes, and refuses the
   commit outright on an `ACCEPTED_ADR_MODIFIED` finding.
3. **The wiki repo's own CI**, if it adopts
   [the template](wiki-repo-ci-template.yml), runs it against every push and
   pull request to that repo — unlike `wiki-verify.sh`'s non-blocking
   posture inside this pipeline (no safe fallback tier below a structural
   warn — design.md D13), a schema violation caught in the wiki repo's own
   CI has an obvious safe response: don't merge it.

**The accepted gap:** `WIKI_ROOT` is a separate repository this repo's CI
does not check out and cannot gate. A hand edit committed directly to the
wiki repo, outside `wiki-maintenance` and without that repo adopting (3),
reaches `WIKI_ROOT` unguarded — no `adr-check.sh` run sees it until the next
`wiki-maintenance` run's Step 4, which checks the state left behind, not the
edit that produced it. Closing this fully would mean content-hash sealing
(reusing `grill-me/lib/grill-seal.sh`'s canonicalisation) — deferred until
CI-plus-commit-step enforcement proves insufficient in practice (design.md
D12).

## Related

- [ADR gate schema](adr-gate-schema.md) — the request/result contract that produces ADRs
- [Wiki repo CI template](wiki-repo-ci-template.yml) — adoptable `adr-check.sh` workflow for the separate `WIKI_ROOT` repository
- [Glossary schema](glossary-schema.md) — the term vocabulary ADR prose draws from
- [Human Hold schema](human-hold-schema.md) — how a `CREATED_PROPOSED`/`SUPERSEDE_REQUIRED` verdict parks a phase
- `../CLAUDE.md` — repository-wide governance and determinism-boundary framing
