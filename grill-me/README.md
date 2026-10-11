# grill-me — Pre-Work Readiness Gate

Ask your idea the hard questions before you build anything. `/grill-me` assesses a business idea against a profile-driven dimension model, interactively grills you on the gaps, and produces a cryptographically sealed Validated Business Intent document that downstream consumers (like `ticket-planner`) can gate on.

## Quick start

```
/grill-me "Add real-time collaboration to the document editor"
```

Or from a file:

```
/grill-me --file ./brief.md
```

## What it does

1. **Assesses** your idea against 10 quality dimensions (objective, users, success criteria, scope, acceptance criteria, constraints, dependencies, risks, edge cases, assumptions)
2. **Scores** readiness deterministically from 0–100 (bash, not an LLM guessing at arithmetic)
3. **Asks** ranked clarification questions for the highest-impact gaps — each question tells you *why* the information is required
4. **Produces** a sealed Validated Business Intent document with a SHA-256 content hash
5. **Refuses** to let downstream tools accept a tampered or under-specified intent

## Modes

| Mode | Flag | Use case |
|------|------|----------|
| Interactive | (default) | Human refining an idea — asks up to `--max-rounds` rounds of questions |
| Non-interactive | `--non-interactive` | Agent-to-agent — scores and seals without asking questions |
| Headless | `--emit-questions <dir>` / `--answers <file>` | No terminal, but a person answers through another channel (Slack, a dashboard) — see below |

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--profile <id>` | `product-idea` | Dimension profile to assess against |
| `--file <path>` | — | Read input from file |
| `--out <path>` | `.ticket-auto/intents/{slug}-{date}.md` | Output path for the sealed document |
| `--non-interactive` | off | Score, render, seal — never ask questions |
| `--max-rounds N` | 3 | Maximum grill question rounds |
| `--id <id>` | brief hash | Work-directory id (`${REPOS_ROOT}/.grill/<id>`); pass the same one on every headless round |
| `--emit-questions <dir>` | off | Headless: score, then seal if ready or write `round-N.hold` and exit |
| `--answers <file>` | off | Headless: fold answers, re-score, then seal or emit the next round |

## Environment overrides

| Variable | Overrides | Description |
|----------|-----------|-------------|
| `GRILL_THRESHOLD_READY` | profile `ready` threshold | Lower/raise the ready bar |
| `GRILL_THRESHOLD_WARN` | profile `warn` threshold | Lower/raise the warn bar |
| `GRILL_MAX_QUESTIONS` | profile `max_questions` | More/fewer questions per round |

`GRILL_WORK_DIR` or `REPOS_ROOT` must be set in every mode (since 0.2.0). The work
directory holds the assessment, the score and the question rounds; grill-me refuses
to run without one rather than guess.

## Headless / orchestrated use

For a caller with no terminal — an orchestrator running `claude -p` and relaying
questions over Slack, say:

1. `/grill-me --file brief.md --id wf-42 --emit-questions ./out` assesses and scores.
   If the brief is ready it seals and prints `sealed=<path>`. Otherwise it writes
   `round-1.hold` — a [human-hold Schema-Version 2](../ticket-auto-pipeline/docs/human-hold-schema.md#schema-version-2)
   block, one client question per gap, each with an id — and exits.
2. The caller collects answers and writes an answers file: the round, plus `id`,
   `value`, `answered_by`, `role` and `ts` per answer.
3. `/grill-me --id wf-42 --answers answers.json` folds the answers into the
   assessment as quoted data, re-assesses and re-scores, then seals or writes
   `round-2.hold`.

When the round cap is reached and a critical dimension is still unresolved, the next
hold is one operator question — `seal-with-gaps` or `abort` — instead of a silent
seal. A seal with gaps lists them under Open Gaps and is never `ready`.

Answers to a stale round or to an unknown question id are rejected with nothing
changed. Answer text is capped, stripped of control characters and code fences, and
always shown to the model as verbatim data, never as instructions.

## Recommendation tiers

| Recommendation | Meaning | Consumer behavior |
|----------------|---------|-------------------|
| `ready` | Well-specified, all critical dimensions present | Proceed |
| `proceed-with-warnings` | Has gaps but passable | Proceed with warning surfaced |
| `do-not-proceed` | Under-specified or critical dimensions missing | Hard stop — re-grill |

## How downstream agents consume this

1. **Verify the seal:** `grill_seal_verify <file>`
   - Exit 0 + `VALID` → proceed
   - Exit 3 `NO_SEAL` → "This is not a grill-me intent file"
   - Exit 4 `MISMATCH` → "This file was edited since validation"
2. **Read the verdict:** `GRILL_RECOMMENDATION` from verifier output
3. **Treat the document as authoritative:** The Objective, Scope, and Acceptance Criteria sections are the agreed-upon specification — never re-derive them from the raw idea

## Architecture

See [docs/grill-me.md](docs/grill-me.md) for the full architecture, determinism boundary, and worked examples. See [docs/intent-seal-schema.md](docs/intent-seal-schema.md) for the seal format and canonicalization rule.

## Dependencies

- `bash` (required)
- `jq` (required)
- `sha256sum` (required)
- No new runtime dependencies beyond what the existing plugins already require

## Version

0.2.0 — headless question rounds (`--emit-questions` / `--answers`); a work directory is now required in every mode.

0.1.0 — initial release with `product-idea` profile.

## License

UNLICENSED — proprietary. See repository root.
