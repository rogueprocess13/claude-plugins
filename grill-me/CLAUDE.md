# CLAUDE.md — grill-me

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Pre-work readiness gate. Any agent can invoke it before acting on an input — it assesses the input against a profile-driven dimension model, scores readiness deterministically in bash, produces a cryptographically sealed Validated Business Intent document, and (in interactive mode) asks ranked clarification questions to close gaps.

## Directory layout

```
grill-me/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/grill-me/SKILL.md        # Single skill: /grill-me
  lib/                            # Shared bash libraries (6 files)
  lib/tests/                      # Test suites (6 files)
  profiles/                       # Dimension profiles (JSON)
  docs/                           # Architecture and reference docs
  README.md                       # Marketplace entry point
```

## Skill

| Skill | Type | Purpose |
|-------|------|---------|
| [grill-me](skills/grill-me/SKILL.md) | Quality Gate | Assesses input readiness, asks ranked clarification questions, produces sealed Validated Business Intent document |

## Determinism boundary

- **Bash side (deterministic):** Profile validation, assessment JSON validation, readiness computation, recommendation resolution, question ranking, document rendering, seal generation, seal verification.
- **Agent side (LLM):** Dimension assessment (present/partial/missing judgements with evidence and gap text), question formulation, flag detection.

The agent emits judgement only — it never computes a score. The bash scorer computes the number. This is the same boundary used throughout the repo: bash orchestrates and decides; agents reason.

## Scoring contract

The agent produces an `assessment.json` with:
- `profile`, `subject`, `round`
- A `dimensions` array of `{id, status: present|partial|missing, evidence, gap}`
- A `flags` map of `{flag_id: true}`
- `assumptions`, `risks`, and `questions` arrays

`grill-score.sh` validates all of that, then computes:
- `readiness = sum(weight * status_factor) - flag_penalties`, clamped to 0–100
- `recommendation` from critical-missing → thresholds → flag caps
- `questions` ranked by `weight * (1 - status_factor)` descending, capped at `max_questions`

The agent SHALL NOT contain a computed score. Every scoring rule is a unit-testable assertion.

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `grill-input.sh` | `grill_sanitize_input` — input sanitization: length cap (`GRILL_INPUT_MAX_LENGTH`, default 16000; longer input exits 2, never truncated), whitespace normalization, zero-width and bidi stripping, injection-pattern screening (exit 1). `grill_brief_verbatim` — the brief with its line structure kept (CR/zero-width/bidi/control characters and trailing spaces removed) for the sealed `## Original Brief` |
| `grill-profile.sh` | `grill_profile_load`, `grill_profile_validate` — profile loading and structural validation |
| `grill-score.sh` | `grill_score` — assessment JSON validation, readiness computation, recommendation resolution, question ranking, `KEY=value` + `result.json` output |
| `grill-render.sh` | `grill_render <result> <assessment> [out] [brief-file]` — document rendering with fixed section order, tabular gap and score reporting; a non-empty brief file adds `## Original Brief` as the last body section |
| `grill-seal.sh` | `grill_seal_generate`, `grill_seal_verify` — seal block generation and verification with exit-code contract |
| `grill-hold.sh` | Headless question rounds (planner-headless-questions). `grill_work_dir` (`GRILL_WORK_DIR` → `${REPOS_ROOT}/.grill/<id>`, `<id>` = `--id` or 12 hex of the brief's sha256; fails naming both variables when neither is set), `grill_hold_emit` (ranked `result.json` questions → `round-N.hold`, a human-hold v2 block with `KIND: input`, `AUDIENCE: client`, `grill:<dimension>` bindings, plus `state.json`), `grill_answers_fold` (validate round/ids/roles, sanitise, fold into `assessment.json` `resolved[]` with attribution; same exit codes as ticket-planner's answers intake), `grill_answers_prompt` (answers fenced as verbatim human data for the re-assessment), `grill_next_step` (`NEXT=seal\|emit\|cap`), `grill_hold_cap_emit` (round cap with a critical dimension unresolved → one operator approval, `seal-with-gaps\|abort`), `grill_seal_with_gaps_prepare` (a gap seal is never `ready`) |

## Seal canonicalization

The hash covers every byte from offset 0 up to and including the newline terminating the line immediately before the `**Content-Hash:**` line. All seal metadata (Readiness, Recommendation, Profile, etc.) falls inside the hashed region. Editing `**Readiness:** 22` to `**Readiness:** 95` breaks the hash exactly as editing the body does.

The `**Content-Hash:**` line must be the last non-empty line of the file. Trailing whitespace after it is ignored by verification.

## Known sharp edges

- **Ported sanitizer:** `grill-input.sh` reimplements `planner_sanitize_input` from `ticket-planner/lib/planner-phase-prompts.sh` rather than sourcing it, because grill-me must install standalone. The two copies can drift. The consequence of drift is low — sanitization is defense-in-depth, not a correctness contract between the plugins. Recorded as design decision D6.
- **Seal is tamper-evident, not tamper-proof:** An unkeyed SHA-256 hash can be recomputed by anyone. The threat model is accidental drift and casual hand-editing, not an adversarial operator who can simply re-run grill-me. `GRILL_SEAL_KEY` HMAC is noted as a future option and deliberately not built.
- **Unattended callers grill through files:** `--non-interactive` scores and seals with no questions, so a fleet-controller or cron caller can gate on `GRILL_RECOMMENDATION` without a human present. `--emit-questions` / `--answers` run the full question loop through an external transport (`lib/grill-hold.sh`); only the re-assessment between rounds is an LLM step.
- **Every mode needs a work directory (0.2.0+):** `GRILL_WORK_DIR` or `REPOS_ROOT` must be set, interactive runs included. Headless rounds span processes, so the work directory is the only state they share — there is deliberately no temporary-directory fallback.
- **Extra profile dimensions render generically (0.3.0+):** `grill-render.sh` has fixed sections for the ten v1 dimension ids. Any other dimension in `result.dimensions[]` (today only `test_data`) renders as `## <label>` plus its evidence (or `_None identified_`), between Edge Cases and Assumptions, in profile order. The label is sanitised: CR/LF removed, leading `#` and spaces stripped. When there are no extra dimensions the block is omitted and the output is byte-identical to a v1 render (`lib/tests/fixtures/render-v1-golden.md`). The seal needs no change — the section is inside the hashed bytes.
- **`_No prepared data needed_` sentinel:** the `test_data` probe tells the agent to use this exact evidence when verifying the idea needs no data to exist beforehand. ticket-planner's Discovery prompt treats it, like `_None identified_`, as "no test-data statement" and adds nothing.
- **The brief is sealed verbatim (0.4.0+, grill-me-verbatim-brief):** the sections are rendered from the assessor's `evidence`, which paraphrases — seed titles, field sets and request/response shapes were lost that way in the dispatch rehearsal. Step 2 writes `${work_dir}/brief.md` (`grill_brief_verbatim`) and Step 6 passes it to `grill_render`, which appends `## Original Brief` after Category Scores with every line prefixed `> ` (an empty line is `>`), so no brief line can open a heading or forge `## Intent Seal`/`**Content-Hash:**`. It is inside the hashed bytes, so editing it breaks the seal. ticket-planner (`planner_intent_brief`) takes the last such heading before the seal and strips the prefix to recover the brief byte for byte. With no brief file the output is byte-identical to before (golden test). Over-long input is refused (exit 2) instead of truncated, so the sealed brief is never silently cut.
- **Weights and thresholds are initially unvalidated guesses:** They live in one JSON file and are overridable per-run by environment variable, so tuning needs no code change. Calibration comes from the three worked examples and real use.
