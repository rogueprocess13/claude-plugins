# complexity-drift — Pattern Analysis Template

## Pattern

The appraisal phase declares tickets `simple` that turn out `Rough` or `Hard` — false-simples. Each one skipped both the human approve gate and the delegated investigation, so this is the error direction that costs the most.

## Evidence source

Read `complexity_calibration` from `retro.sh` output:

- `false_simple_tickets` — the named tickets (`ticket`, `outcome`). Start here.
- `false_simple_rate` — false-simples over the `declared=simple` row. `null` when `suppressed` is `true` (the simple row holds fewer than `min_n` tickets) — do not report a pattern from a suppressed window.
- `matrix` — the full declared × outcome counts.

**Do not tune against the `declared=complex` row.** It is listed in `confounded_rows` for a reason: a `complex` ticket gets delegated investigation, an openspec plan, and human review, so a `complex` + `Smooth` outcome may be the treatment working, not a misprediction. Loosening the classifier to "fix" that cell pushes tickets toward `simple` — the expensive direction.

## What to Look For

For each ticket in `false_simple_tickets`, open its `notes.md` `## Complexity` section:

1. **`**Axes fired:**` and `**Weighted score:**`** — which axes fired, and what the total was. A score of 2 means exactly one weak axis fired.
2. **Which axis should have fired and didn't?** Compare the ticket against the Step 2.5 axis table in `ticket-appraise/SKILL.md`. A missed migration, payment path, auth change, or breaking API change is a **Reversibility** miss.
3. **Fast-path tickets** (`**Weighted score:** n/a (fast-path …)`): the keyword scan in `lib/appraise-fast-path.sh`'s `detect_reversibility_trigger` found nothing. Was there a trigger the keyword list doesn't cover?

## Minimal Fix Pattern

Prefer, in order:

1. **Add a trigger** to an existing axis's "Fires when" text in `ticket-appraise/SKILL.md` Step 2.5 (and, for Reversibility, to `detect_reversibility_trigger`'s keyword list).
2. **Raise a weak axis's weight** from 2 to 3 only if the false-simples show it firing alone repeatedly.

Never lower a weight or raise the threshold on the strength of `complex` + `Smooth` counts.

## Related

- `ticket-appraise/SKILL.md` Step 2.5 — the weighted axis table and threshold.
- `lib/appraise-fast-path.sh` — the fast-path Reversibility keyword scan.
- `retro.sh` — `complexity_calibration` (replaced the removed `complexity_accuracy`).
