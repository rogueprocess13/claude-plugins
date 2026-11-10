---
name: wiki-maintenance
description: Incorporates unresolved errata entries from ticket-appraise and ticket-implement feedback into wiki flow files. Reads all ## Errata sections under the project's WIKI_ROOT, applies each gap fix to the relevant flow section, deletes the entry once incorporated (git is the audit trail), simplifies the prose of every touched file with the simple-english skill, lints the result, and commits WIKI_ROOT. Use when wiki errata has accumulated (~5+ unresolved entries), or the user says "maintain wiki", "update wiki from errata", "incorporate errata", or "fix wiki gaps".
---

# Wiki Maintenance — Errata Incorporation

You are maintaining pre-traced call-chain wiki files. Your input is errata entries appended by `ticket-appraise` Step 3c and `ticket-implement` Step 4c — each entry describes a gap found during actual ticket work. Your job is to incorporate those fixes into the flow content, deleting each entry once its fix lands (git already keeps the history), run the prose through the `simple-english` skill before it ships, then lint and commit `WIKI_ROOT`.

## Logging (--from-auto)

If `$TAP_LOG` is set (passed by the `ticket-auto` orchestrator): read `~/.claude/skills/pipeline-log-format.md`. Write progress entries at step boundaries. Phase is `MAINTENANCE`.

## Heartbeat (--from-auto)

If `$HB_LOG_FILE` is set (passed by the orchestrator): call `~/.claude/skills/lib/hb-wrap.sh` then write heartbeat entries at these points:
- **Wiki bootstrap**: if WIKI_ROOT not set in environment or CLAUDE.md, write `hb-wrap.sh fallback "wiki-bootstrap" "fail" "WIKI_ROOT not configured" '{"reason":"no WIKI_ROOT configured"}'`
- **Errata discovered**: after scanning all wiki files, write `hb-wrap.sh decision "errata-count" "info" "{N} unresolved entries found" '{"count":"{N}"}'`; if none found, write `hb-wrap.sh decision "errata-count" "info" "all errata resolved"`
- **New file created**: if a fix requires creating a new wiki file, write `hb-wrap.sh decision "wiki-file-created" "fired" "created {filename}" '{"file":"{filename}"}'`
- **Unclear entry**: if an errata entry is unclear and skipped, write `hb-wrap.sh decision "errata-skipped" "warn" "unclear entry skipped" '{"ticket":"{TICKET-ID}"}'`
- **Maintenance complete**: after all entries processed, write `hb-wrap.sh decision "maintenance-complete" "fired" "{N} errata processed, {M} ai-context findings promoted, {K} files modified" '{"errata_processed":"{N}","ai_context_findings":"{M}","modified":"{K}"}'`

---

## Step 0 — Load project context

If `--from-auto` is set: source the project context env file instead of reading CLAUDE.md.

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}
```

Use `$WIKI_ROOT` from the environment. If `$WIKI_ROOT` is empty, fall back to reading CLAUDE.md in the current directory. Each Bash call is a fresh shell, so note the resolved absolute path: later calls take it as `{WIKI_ROOT}` (Step 4) or re-source the env file.

Stop here if no `WIKI_ROOT` is available — no wiki exists for this project.

**Concurrency guard — acquire the WIKI_ROOT lock before any write.** `WIKI_ROOT` is one repo
shared by every concurrent pipeline on the host, and everything from the bootstrap below through
the Step 4 commit writes under it. Take the lock here, before any of it (why a lock directory and
not a `flock`: `lib/wiki-lock.sh` header):

```bash
bash "$HOME/.claude/skills/lib/wiki-lock.sh" acquire --wiki-root "$WIKI_ROOT" --ticket "{TICKET-ID}" --log-file "${TAP_LOG:-}"
echo "WIKI_LOCK_RC=$?"
```

Route on `WIKI_LOCK_RC` — this is a literal precondition, not a judgement call:

- **`0`** — you hold the lock. Continue.
- **`3`** — another ticket holds it; this call waited `WIKI_LOCK_WAIT_SECS` (default 90s) and
  logged `META|wiki-contention|warn` once. Run the **same** block again, and keep re-running it
  while it returns `3`. The total wait is bounded by the lib itself across calls, so this loop
  always ends. Do not read or edit anything under `WIKI_ROOT` meanwhile.
- **`4`** — gave up after `WIKI_LOCK_MAX_WAIT_SECS` (default 1h, already logged as
  `META|wiki-contention|fail`). Make no `WIKI_ROOT` writes this run: skip to Step 5 and report
  `Committed: skipped — WIKI_ROOT lock held by {WIKI_LOCK_HOLDER}`. The errata stay in place for
  the next run.
- **`2`** — usage error (unresolved `WIKI_ROOT`). Treat as "no wiki" and stop.
- **`7`** — unsafe lock location (non-git wiki only): the private per-user lock base is a
  symlink, owned by another user, or cannot be created. The lib has already printed why. Make no
  `WIKI_ROOT` writes: skip to Step 5 and report `Committed: skipped — unsafe WIKI_ROOT lock
  location`. Do not try to work around it.

**Release on every exit.** Step 4's `wiki-finalize.sh` releases the lock on all of its own
paths. Every earlier exit (the Step 2.5c `HUMAN_HOLD`/`ADR_CONFLICT` stops, or any other abort)
releases it here:

```bash
bash "$HOME/.claude/skills/lib/wiki-lock.sh" release --wiki-root "$WIKI_ROOT" --ticket "{TICKET-ID}"
```

Release only removes a lock this ticket owns, so it is safe to run more than once.

**Bootstrap (adr-governance-gate):** before reading anything under `WIKI_ROOT`, scaffold what's
missing — a wiki that has never been through this skill before may have flow files but no
`index.md`/`decisions/`/`glossary.md` yet:

```bash
source "$HOME/.claude/skills/lib/wiki-bootstrap.sh"
wiki_bootstrap "$WIKI_ROOT"
```

No-op on an already-scaffolded wiki; scaffolds only what's missing on a partial one.

After resolving:
```
WIKI_ROOT = {resolved absolute path}
```

---

## Step 1 — Discover unresolved errata

List all markdown files under `{WIKI_ROOT}` recursively, excluding `index.md`:

```bash
find {WIKI_ROOT} -name "*.md" ! -name "index.md" | sort
```

For each file, grep for `## Errata` — if found, read the errata section. Parse each entry to identify:

- **Ticket ID** — the ticket that discovered the gap (provenance tag, e.g. `ABC-47`)
- **Gap** — what was missed, in terms of code/paths — not dates, not outcome labels
- **Fix** — what should be added/changed

Every entry under `## Errata` is unresolved by construction — once an entry is incorporated it is
deleted (see Step 2c), not struck through. Git history is the audit trail for what was fixed and
when; the wiki file itself only ever shows current, actionable gaps.

If no unresolved entries exist across all files, report:
```
No unresolved errata — skipping to Step 2.5 (ai-context.md synthesis).
```
then proceed directly to **Step 2.5** — do NOT stop the skill here. Step 2.5's
ai-context.md promotion must run independently of whether any ticket in this
window logged an errata gap; gating it on errata existence silently drops
successful-ticket findings (patterns/decisions/gotchas) whenever no sibling
ticket happened to also log a failure in the same window.

If entries exist, summarize:
```
## Unresolved errata

| File | Ticket | Gap (summary) |
|------|--------|---------------|
| flows/handover.md | ABC-47 | BomFeignClient.getCommission() not in payment flow |
| flows/billing.md | ABC-52 | BodyServiceResourceUsage.reference field use undocumented |
```

**Style rule — applies to every write this skill makes**, both here and in Step 2.5/2.6:
what the code does and where it lives (repo-relative paths, never line numbers — those drift
the moment the file changes); ticket IDs only as `(ABC-XX)`-style provenance tags on the
content they support, never as a standalone changelog entry; no dates, outcome labels
(Smooth/Rough/Hard, predicted-vs-actual), adversarial-review counts, or "not yet
merged/fixed" status lines — this kind of content rots in days (a ABC-69 section once
described a fix mechanism that was never merged in that form, and stayed wrong for months
because nothing re-checked it). If you're about to write something that will read as false in
three months, cut it.

Proceed to Step 2.

---

## Step 2 — Process entries (one at a time)

Work through unresolved entries in order. For each:

### 2a — Read the context

1. Read the errata entry's `Fix:` line — this tells you what to add.
2. Read the relevant section of the flow file that the errata references. The `Gap:` line tells you where.

### 2b — Apply the fix

Only when Step 1 found unresolved errata, or Step 2.6 has a `source=wiki` or `source=prescan` correction to incorporate: run `bash ~/.claude/skills/lib/skill-ref.sh wiki-maintenance references/errata-fix.md`, read the printed path in full and follow it (gap-type patterns, new-file frontmatter, the `verified_at` refresh). If `skill-ref.sh` exits non-zero, run `bash ~/.claude/skills/lib/plog.sh META reference-missing fail "references/errata-fix.md"` and leave every errata entry and correction in place for the next run: never apply a fix from memory.

### 2c — Mark resolved

After incorporating the fix, **delete** the errata entry — do not strike it through and keep
it. Git history is the record of what was fixed and when; the wiki file itself should only ever
show gaps still open. If `## Errata` is empty after removing the entry, remove the empty
heading too.

---

## Step 2.5 — Synthesize ai-context.md findings

In addition to errata (failures), scan recent `ai-context.md` files (successes) across ticket directories. Promote non-obvious findings into consolidated wiki entries.

### 2.5a — Discover ai-context.md files

Find the `ai-context.md` files written in the last 90 days (run from the tickets root):

```bash
bash ~/.claude/skills/lib/ai-context-find.sh
```

Exit 1 means `date` or `find` failed: log it and treat the list as incomplete, never as "no recent files". If the `tickets` directory is elsewhere, pass `--root <dir>`. If the list is empty (exit 0), skip to Step 3 — Lint before commit (a no-op when nothing changed this run).

### 2.5b — Read and evaluate each file

Read each `ai-context.md` file. It is short by design (a single page with named sections). For each file, evaluate findings against these criteria:

**Inclusion criteria** (promote to wiki):
- New conventions or patterns not already documented in the wiki — discovered from the **Patterns used** section
- Gotchas involving undocumented invariants or hidden coupling — from the **Watch out for** section
- Decisions with non-obvious rationale — from the **Decisions** section
- Cross-cutting changes that touch multiple modules — derived from the **What changed** and **Key files** sections

**Exclusion criteria** (stay in ai-context.md only):
- File-by-file change summaries from **What changed** — too granular for wiki
- Findings already covered by an existing wiki entry — check before creating
- Trivial-change one-liners ("Trivial change — no architectural impact")
- Findings from files tagged `[ai-context-stale]` (already marked stale by appraise)

### 2.5c — Write or update wiki entries

For each finding that meets inclusion criteria, check if the wiki already has a relevant entry. Read the most relevant wiki file(s) identified via `{WIKI_ROOT}/index.md`.

**Idempotency check (task 6.3), before any promotion write below:** if the relevant wiki entry
already carries this finding's source ticket id in its provenance tag (e.g. an existing line
already ends `(WIL-67)`), skip this finding entirely — it was already promoted in an earlier
maintenance run. `ticket-appraise` Step 0.5's `wiki-bootstrap.sh` run means `{WIKI_ROOT}/index.md`
always exists by this point, so this check has something to read against even on a fresh wiki.
This is ticket-scoped: it catches the same `ai-context.md` resurfacing across runs (2.5a's
90-day discovery window), not content similarity — a genuinely new finding about the same topic
from a *different* ticket is not a duplicate.

**Findings from the Decisions section route through the ADR gate, not directly to prose.**
Everything else below this point (Patterns used, Watch out for, cross-cutting findings) is
unchanged from before this capability existed — write or update prose exactly as already
described.

#### Decisions-section findings (adr-governance-gate)

Only when a surviving finding comes from the Decisions section: run `bash ~/.claude/skills/lib/skill-ref.sh wiki-maintenance references/adr-decisions.md`, read the printed path in full and follow it to route each such finding by its ADR gate verdict. If `skill-ref.sh` exits non-zero, run `bash ~/.claude/skills/lib/plog.sh META reference-missing fail "references/adr-decisions.md"` and skip the Decisions-section findings this run (a later run picks them up): never route them, or write prose for them, from memory.

#### Ordinary prose path (Patterns used, Watch out for, cross-cutting — unchanged)

**If the finding is already documented:** update the existing entry with the additional source ticket reference (e.g., add `(WIL-67)` to an existing line). Do NOT create a duplicate entry.

**If the finding is new:** add it to the appropriate wiki file as one section — a single
audience reads this file (appraise, and any human skimming alongside it), so a duplicated
human/AI pair is just two places for the same fact to go stale:

```markdown
### {topic}

**Summary:** {what's true about this area now — terse, skimmable}
**File paths:** {relevant files with one-line role descriptions}
**Conventions / gotchas:** {conventions and watch-out items as flat bullets, each ending in a
`(TICKET-ID)` provenance tag — no separate changelog}
```

Omit any subsection with nothing to say — a two-line entry with just Summary and one
convention bullet is complete on its own. Provenance lives on the bullet it supports, not in a
separate ticket list — a bullet with two contributing tickets carries both: `(ABC-47, ABC-61)`.

### 2.5d — Count and track

Track the number of ai-context.md files processed and the number of findings promoted to wiki. Also track the number of ADRs created (`CREATED_PROPOSED`/`SUPERSEDE_REQUIRED` verdicts from 2.5c above) and the number of Decisions-section findings that were `GOVERNED` (pointer-only, no new ADR). These counts are included in the Step 5 report alongside errata counts.

### 2.5e — Glossary maintenance

Follow [docs/glossary-schema.md](../../docs/glossary-schema.md): add a glossary entry for each concept
term a Step 2 fix or a 2.5c ADR introduced that `{WIKI_ROOT}/glossary.md` lacks, then run the
term-drift check and resolve each `TERM_DRIFT` line as that doc describes (correct the usage, or
split the entry when the synonym is a different concept):

```bash
source "$HOME/.claude/skills/lib/wiki-bootstrap.sh"
wiki_term_drift_check "$WIKI_ROOT"
```

Track the number of glossary entries added and term-drift violations resolved. Include both in the Step 5 report.

---

## Step 2.6 — Incorporate CORRECTIONS from ai-context.md

When `ticket-document` writes ai-context.md, it carries forward CORRECTIONS blocks written by `ticket-appraise` and `ticket-implement`. These corrections identify a specific fact that turned out wrong or missing, tagged with a source (`appraise`, `exec`, `prescan`, or `wiki`). This step processes corrections alongside errata entries — but only the sources that are actually wiki-material:

1. **source=wiki**: Treat these as direct wiki errata — they describe gaps in wiki flow files discovered during appraisal or implementation. Apply the same fix workflow as Step 2b (read context, apply fix to the appropriate wiki file, refresh its `verified_at`/`verified_against`). If the fix lands cleanly, delete the correction. If unclear, append a `<!-- UNCLEAR: {why} -->` comment and skip.

2. **source=prescan**: Describes a prescan-doc investigation gap, not a wiki-file defect on its own. Evaluate it: if it reveals a reproducible pattern the wiki should warn about (e.g., "entity X always needs field Y but the wiki doesn't mention it"), promote it into the appropriate wiki flow file using the same fix workflow as Step 2b. If it is a one-off ticket-specific miss, skip — it is not actionable for the wiki.

3. **source=appraise**: This is complexity-calibration feedback — predicted vs. actual outcome for `ticket-appraise`'s own scoring, not a codebase or wiki fact. **Never promote it to the wiki.** `ticket-retro` Step 1.6 is the consumer for these entries, reading them directly from each ticket's notes.md — leave them there and skip here.

4. **source=exec**: Describes a plan-artifact gap. Skip — exec-level corrections are plan-specific, not wiki-material.

For every correction actually incorporated (sources 1 and 2 above), no further write is needed
once Step 2b's edit lands — the fix itself, committed to `WIKI_ROOT` (§4), is the audit trail.
Do not create a separate struck-through record in the wiki for it, and do not edit the
originating `ai-context.md`/notes.md — those are immutable per-ticket historical records, not a
work queue this skill maintains.

Track resolved correction count separately from errata count. Include both in the Step 5 report.

---

## Step 3 — Lint before commit

Before committing (Step 4), run the freshness/completeness lint over every file this run
touched:

```bash
bash "$HOME/.claude/skills/lib/wiki-check.sh" --wiki-root "$WIKI_ROOT" --repos-root "$REPOS_ROOT" --changed-only
```

What it checks: `lib/wiki-check.sh` header. A file this run edited that shows `decayed` means
Step 2b's `verified_at`/`verified_against` refresh was skipped. A non-zero exit does not block
the commit: log the findings (`META|wiki-lint|warn|...` when `--from-auto`) and proceed.

---

## Step 3.5 — Plain-English pass

Run the `simple-english` skill (Plain mode) on the prose this run wrote or edited in Steps 2,
2.5 and 2.6, not on whole files, so untouched sections keep their wording. Its "never touch"
rule applies literally (code, identifiers, paths, `(TICKET-ID)` tags, frontmatter). Skip fixes
that are only a table row or list item; there is no prose to simplify. It runs after Step 3
because the lint checks nothing a wording pass changes.

---

## Step 4 — Commit WIKI_ROOT, then verify the store

`WIKI_ROOT` is its own docs repo with no branches. One call refreshes the Step 0 lock, refuses
the commit when `adr-check.sh` finds an edit to an Accepted ADR (exit 1: revert it and draft a
superseding ADR instead), makes the scoped commit of this run's own paths, releases the lock on
every exit path, then runs the whole-store `wiki-verify.sh` pass. Fill `{WIKI_ROOT}` with the
absolute path from Step 0; empty means not configured and nothing is committed:

```bash
bash ~/.claude/skills/lib/wiki-finalize.sh --wiki-root "{WIKI_ROOT}" --ticket "{TICKET-ID}" --message "docs(wiki): {TICKET-ID} {one-line summary of what was incorporated}"
```

Log lines and return codes: `lib/wiki-finalize.sh` header. A lock another run broke as stale
skips the commit (`wiki-commit|skip`). `wiki-verify.sh` findings are non-blocking (design.md
D13): they warn, the report carries the count, and a human handles them on a later pass. See
`agents/ticket-maintenance-agent.md` for why this is the one commit this agent may make.

---

## Step 5 — Report

```
## Wiki maintenance complete

**Errata processed:** {count}
**ai-context findings promoted:** {count}
**ADRs created:** {count} ({count} GOVERNED — pointer only, no new ADR)
**Glossary entries added:** {count} · **Term-drift violations resolved:** {count}
**Files modified:** {list}
**Committed:** {commit sha, or "skipped — {reason}"}
**Wiki-verify:** {count} violation(s) — see log, or "clean"

**Changes:**
1. {file} — {what was added/changed}
2. ...
```

---

## Notes

- **If an errata entry is unclear** — mark it with `<!-- UNCLEAR: {why} -->` and skip it instead of resolving.
- **Source is authoritative** — if an errata entry contradicts the wiki flow, trust the errata (it comes from actual ticket implementation). Verify by reading the referenced source code if needed.

