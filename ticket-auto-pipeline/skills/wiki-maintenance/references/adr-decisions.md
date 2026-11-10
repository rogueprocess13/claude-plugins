# wiki-maintenance — Step 2.5c: Decisions-section findings (adr-governance-gate)

Read by Step 2.5c only when a surviving finding comes from the Decisions section.

For each surviving Decisions-section finding, invoke the gate — see § 8 ADR gate in the shared
preamble — with `PHASE: MAINTENANCE`, `DECISION_CANDIDATE` and `IDENTIFIED_REASON` drawn from
the finding, and `AFFECTED_COMPONENTS` from whatever the finding's source ticket named. Route on
the verdict:

- **`NOT_ARCHITECTURAL`** — this finding is decision-rationale worth capturing, but the gate
  determined it isn't governance-worthy. Fall through to the ordinary prose path below (same
  template as Patterns/Watch-out) rather than discarding it — a documented rationale is still
  valuable even when it doesn't rise to an ADR.
- **`GOVERNED`** — do not write new prose. Instead, ensure the relevant wiki file's entry (or a
  new one, if none exists yet) references the governing ADR by id
  (`**Decision:** See [ADR-NNNN](../decisions/{NNNN}-{slug}.md) — {one-line summary of the
  constraint}.`) rather than restating it — the ADR is the source of truth, the wiki entry is a
  pointer into it.
- **`CREATED_PROPOSED`** or **`SUPERSEDE_REQUIRED`** — the gate already wrote a `proposed` ADR.
  Emit the `=== HUMAN_HOLD ===` block per § 7/§ 8 with `REASON: ARCH_COMMITMENT`. Do not write a
  wiki entry for this finding yet — there is nothing settled to point to until the ADR is
  accepted; a future maintenance run's re-classification (now `GOVERNED`) is what adds the
  pointer entry above. Release the `WIKI_ROOT` lock (Step 0) before you exit.
- **`CONFLICT`** — the finding describes something that contradicts an Accepted ADR. Emit the
  `ADR_CONFLICT` gate-stop per § 8. This maintenance run does not silently continue past a
  discovered contradiction — someone needs to look at it. Release the `WIKI_ROOT` lock (Step 0)
  before you exit.
