---
name: adr-gate
description: Reusable architectural governance primitive. Classifies whether a reported decision candidate needs an ADR and returns one of NOT_ARCHITECTURAL/GOVERNED/CREATED_PROPOSED/CONFLICT/SUPERSEDE_REQUIRED, drafting a Proposed ADR when one is warranted. Never stops the pipeline itself — the calling phase routes on the returned verdict. Invoked by any ticket-auto-pipeline phase (via the shared preamble) and by ticket-planner, as a plain skill invocation with no cross-plugin bash dependency.
---

# ADR Gate

Given a reported decision candidate, determine whether it is architectural and, if so, whether it is already governed, conflicts with something already governed, or is new territory requiring a Proposed ADR. This runs on the request text and the ADR store only — no ticket fetch, no Linear access, no code changes.

**The gate owns the classification.** A caller reports an observation — it never decides whether an ADR is required, and this skill does not defer that judgment back to the caller, however the caller framed the request.

---

## Input

Invoked as:

```
/adr-gate --request-file <path> [--wiki-root <path>] [--log-file <path>]
```

- `--request-file <path>` — required. Path to a file containing exactly one `=== ADR_GATE_REQUEST ===` … `=== END ADR_GATE_REQUEST ===` block (see [docs/adr-gate-schema.md](../../docs/adr-gate-schema.md)). The caller composes this file itself before invoking the gate — write it as a heredoc, since the fields carry multi-sentence prose unsuitable for a one-line CLI argument. The request is read as ordinary text and reasoned about directly; it is not bash-parsed (`docs/adr-gate-schema.md` states plainly that the request is composed by the caller, not parsed by bash — only the *result* has a deterministic parser).
- `--wiki-root <path>` — optional. Falls back to `$WIKI_ROOT`, then to the `WIKI_ROOT` field in the caller's `CLAUDE.md` if one is in scope. If none resolves, stop and return `NOT_ARCHITECTURAL` with `RATIONALE: no WIKI_ROOT configured — the store cannot be consulted` rather than guessing a path.
- `--log-file <path>` — optional. Forwarded to `adr-gate-parse.sh` at the end of this skill's own run so the verdict is recorded regardless of whether the calling phase re-parses the block itself (see § Act on results, step 4).

Read the request file. If it does not contain a well-formed `ADR_GATE_REQUEST` block (missing open or close marker, no `DECISION_CANDIDATE`, no `IDENTIFIED_REASON`), stop and report the malformed input in prose — do not fabricate field values, and do not proceed to classification on an incomplete request.

### Unnarrowed discovery

When `AFFECTED_COMPONENTS` is absent from the request, do not refuse it. Proceed using the remaining fields and record — in the eventual `RATIONALE` — that candidate discovery ran unnarrowed, against the whole `decisions/index.md` rather than a component-filtered subset.

---

## Checks

### 1. Bootstrap the wiki

Before reading anything, guarantee the store exists:

```bash
source "${CLAUDE_PLUGIN_ROOT:-.}/lib/wiki-bootstrap.sh" 2>/dev/null || source lib/wiki-bootstrap.sh
wiki_bootstrap "$WIKI_ROOT"
```

This is a no-op on an already-scaffolded wiki and inert when `WIKI_ROOT` is unset (see § Input above for the no-`WIKI_ROOT` case).

### 2. Read the glossary

```bash
cat "$WIKI_ROOT/glossary.md"
```

Read this before drafting any ADR prose. Use the glossary's preferred terms, never a new synonym for a concept it already names (`docs/glossary-schema.md` § Glossary informs ADR drafting).

### 3. Classify significance

**`NOT_ARCHITECTURAL` is the default disposition.** Apply the reversibility test as the actual justification, not a vibe check: would reversing this decision materially change the architecture or constrain future implementation? If reversing it is cheap and local, it is not architectural, regardless of how the caller framed the request.

The following do **not** qualify on their own, however the caller described them:

- Library or dependency choice for a single component
- Introducing a class, module, or file
- Method-level design (signature, parameter shape, internal algorithm)
- Naming
- A routine bug fix, including one that changes behavior at a boundary
- A local implementation choice with no cross-cutting effect

A matter qualifies as architectural when it establishes a constraint other components or future work must follow — a cross-service contract, a shared data-access pattern, a security boundary, a policy every caller must obey.

If the matter is not architectural, skip straight to § Determine verdict → `NOT_ARCHITECTURAL` — do not run candidate discovery for a matter that was never going to reach the store.

### 4. Candidate discovery

Only for a candidate that passed step 3.

- If `AFFECTED_COMPONENTS` is present:
  ```bash
  bash lib/adr-store.sh query --wiki-root "$WIKI_ROOT" --components "<affected-components>"
  ```
- If absent: read `$WIKI_ROOT/decisions/index.md` in full (unnarrowed discovery).

**The index is not the source of truth.** `decisions/index.md` (and `adr_query_by_component`, which reads the same frontmatter) is for cheap candidate discovery only — by component overlap and title match. Before returning `GOVERNED`, `CONFLICT`, or `SUPERSEDE_REQUIRED`, **read every candidate ADR document itself**. An index row that looks unrelated but whose body actually governs the reported decision still produces `GOVERNED` once read; a pre-filter never determines architectural significance on its own.

---

## Determine verdict

Exactly one of the five closed values. Populate `RATIONALE` on every branch — every classification decision gets a stated reason, regardless of which verdict.

### `NOT_ARCHITECTURAL`

The default. No candidate discovery was needed, or discovery found nothing that changes the classification. `ADR_REQUIRED: false`, `HUMAN_DECISION_REQUIRED: false`, `ADR_ID` empty. `RATIONALE` states the reversibility justification (task 4.3's stated basis for the disposition).

### `GOVERNED`

A candidate ADR, once read, is `status: accepted` and already answers the reported decision. `ADR_REQUIRED: true`, `ADR_ID` and `GOVERNING_ADR` both set to that ADR's id, `HUMAN_DECISION_REQUIRED: false`. `RATIONALE` states the relevant constraint itself, not just a pointer — the gate has already read the file, so the caller does not have to go read it before it can act.

Create no ADR.

### `CONFLICT`

A candidate ADR, once read, is `status: accepted` and the request's `PROPOSED_APPROACH` contradicts it. `ADR_REQUIRED: true`, `ADR_ID` set to the contradicted ADR, `CONFLICT` states the contradiction in one or two sentences, `HUMAN_DECISION_REQUIRED: true`. Both `ADR_ID` and `CONFLICT` are mandatory whenever this verdict is used — `adr-gate-parse.sh` rejects a `CONFLICT` result carrying either empty, precisely so an unsupported conflict claim can never halt a pipeline.

Create no ADR — do not draft an independent record that would hide the contradiction behind a fresh proposal.

### `CREATED_PROPOSED`

No Accepted ADR governs this, and it is new territory. Draft and write a `proposed` ADR (§ Act on results, step 1), then set `ADR_REQUIRED: true`, `ADR_ID` to the new id, `HUMAN_DECISION_REQUIRED: true`. `RATIONALE` explains why this is architectural and why no existing ADR covers it.

### `SUPERSEDE_REQUIRED`

An Accepted ADR governs the *topic*, but the request's `PROPOSED_APPROACH` would change what that ADR decided — not contradict it in the sense `CONFLICT` means (a live, forbidden clash), but propose evolving the decision itself. Draft and write a `proposed` replacement ADR with `supersedes` naming the original (§ Act on results, step 1) — the original stays `accepted` and untouched; its file is never written by this skill. Set `ADR_REQUIRED: true`, `ADR_ID` to the new replacement's id, `HUMAN_DECISION_REQUIRED: true`. `RATIONALE` explains what is changing and why.

---

## Act on results

### 1. Draft and write the ADR (`CREATED_PROPOSED` / `SUPERSEDE_REQUIRED` only)

Compose the body starting at `## Context`, using the required sections from [docs/adr-schema.md](../../docs/adr-schema.md) (`## Context`, `## Decision`, `## Considered Options`, `## Consequences`, `## Affected Components`) and the glossary's settled terms from Checks step 2. The heading rule applies: the title states the decision, not the topic (`# ADR-NNNN: <imperative decision>`, not a subject label).

Run the `simple-english` skill in Plain mode over the drafted prose. If it is unavailable, apply its core rules inline instead of skipping the pass: plain words, state the decision as a fact rather than a suggestion, and never let `## Decision` contain a hedging modal (`should`/`would`/`may`/`might`/`could` — only `can`/`will`/`must` are permitted there). This pass applies to `proposed` ADRs only, matching the ordering constraint in `docs/adr-schema.md`.

Write it:

```bash
bash lib/adr-store.sh write --wiki-root "$WIKI_ROOT" \
  --title "<imperative decision>" \
  --components "<comma-separated components>" \
  (--initiative "<id>" | --ticket "<id>" | --manual "<id>") \
  --body-file <path-to-drafted-body> \
  --status proposed \
  [--supersedes <ADR-NNNN>]   # SUPERSEDE_REQUIRED only
```

Use whichever of `--initiative`/`--ticket`/`--manual` matches the request's provenance — never more than one, per the store's exactly-one-of validation. `adr_write` is idempotent on that source id: a re-run for the same source never creates a duplicate, even under a different title/slug.

### 2. Emit `=== ADR_GATE_RESULT ===`

Per [docs/adr-gate-schema.md](../../docs/adr-gate-schema.md), populating only the fields applicable to the verdict reached (leave the rest present but empty — never omit a known field, since the parser treats a present-but-empty field differently from an absent one only for the four required fields). This block is the **last content of this skill's return** — write the classification reasoning as ordinary prose first, then append the block.

```
=== ADR_GATE_RESULT ===
SCHEMA_VERSION: 1
ADR_REQUIRED: <true|false>
ADR_VERDICT: <one of the five closed values>
ADR_ID: <ADR-NNNN or empty>
GOVERNING_ADR: <ADR-NNNN or empty — GOVERNED only>
CONFLICT: <explanation or empty — CONFLICT only>
HUMAN_DECISION_REQUIRED: <true|false>
RATIONALE: <one or two sentences, always populated>
=== END ADR_GATE_RESULT ===
```

### 3. Confirm no stop mechanism was used

This skill SHALL NOT emit a `=== HUMAN_HOLD ===` block, a gate-stop log entry, or any tracker (Linear) mutation. The calling phase — not this skill — owns the stop: on `CREATED_PROPOSED`/`SUPERSEDE_REQUIRED` it emits the human hold with `REASON: ARCH_COMMITMENT`; on `CONFLICT` it emits the `ADR_CONFLICT` gate-stop. This skill's only side effects are the `adr_write` call in step 1 (when applicable) and the log entry in step 4 below.

### 4. Record the verdict

Write the block from step 2 to a scratch file and self-parse it, so every invocation is recorded regardless of whether — or how promptly — the calling phase separately routes on it:

```bash
_adr_gate_scratch="$(mktemp)"
cat >"$_adr_gate_scratch" <<'RESULT'
=== ADR_GATE_RESULT ===
... (the exact block emitted in step 2) ...
=== END ADR_GATE_RESULT ===
RESULT
bash lib/adr-gate-parse.sh --result-file "$_adr_gate_scratch" ${LOG_FILE:+--log-file "$LOG_FILE"}
rm -f "$_adr_gate_scratch"
```

This writes `META|adr-gate|info|{json}` once per invocation, on every path including `NOT_ARCHITECTURAL` — park rate is measurable from the first run, not only once Group 5's per-phase wiring lands. The calling phase, reading this skill's return within its own turn, can read the `ADR_GATE_RESULT` fields directly from the visible block for its own routing decision — it does not need to invoke `adr-gate-parse.sh` a second time, which would duplicate the log entry.
