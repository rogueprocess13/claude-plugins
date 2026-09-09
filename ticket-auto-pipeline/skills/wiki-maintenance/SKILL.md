---
name: wiki-maintenance
description: Incorporates unresolved errata entries from ticket-appraise and ticket-implement feedback into wiki flow files. Reads all ## Errata sections under the project's WIKI_ROOT, applies each gap fix to the relevant flow section, deletes the entry once incorporated (git is the audit trail), lints the result, and commits WIKI_ROOT. Use when wiki errata has accumulated (~5+ unresolved entries), or the user says "maintain wiki", "update wiki from errata", "incorporate errata", or "fix wiki gaps".
---

# Wiki Maintenance — Errata Incorporation

You are maintaining pre-traced call-chain wiki files. Your input is errata entries appended by `ticket-appraise` Step 3c and `ticket-implement` Step 4c — each entry describes a gap found during actual ticket work. Your job is to incorporate those fixes into the flow content, deleting each entry once its fix lands (git already keeps the history), then lint and commit `WIKI_ROOT`.

## Logging (--from-auto)

If `$LOG_FILE` is set (passed by the `ticket-auto` orchestrator): read `~/.claude/skills/pipeline-log-format.md`. Write progress entries at step boundaries. Phase is `MAINTENANCE`.

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
source /tmp/ticket-auto-{TICKET_ID}-env.sh 2>/dev/null || true
```

Use `$WIKI_ROOT` from the environment. If `$WIKI_ROOT` is empty, fall back to reading CLAUDE.md in the current directory — and when you resolve a value that way, `export WIKI_ROOT="<resolved absolute path>"` explicitly. Every later step in this skill (including the Step 4 commit guard) reads `$WIKI_ROOT` as a real shell variable, not by re-parsing this section's prose — an unexported value here reads as "not configured" downstream, which is the safe failure mode but not the correct one if a wiki actually exists.

Stop here if no `WIKI_ROOT` is available — no wiki exists for this project.

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

- **Ticket ID** — the ticket that discovered the gap (provenance tag, e.g. `CRE-47`)
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
| flows/handover.md | CRE-47 | BomFeignClient.getCommission() not in payment flow |
| flows/billing.md | CRE-52 | BodyServiceResourceUsage.reference field use undocumented |
```

**Style rule — applies to every write this skill makes**, both here and in Step 2.5/2.6:
what the code does and where it lives (repo-relative paths, never line numbers — those drift
the moment the file changes); ticket IDs only as `(CRE-XX)`-style provenance tags on the
content they support, never as a standalone changelog entry; no dates, outcome labels
(Smooth/Rough/Hard, predicted-vs-actual), adversarial-review counts, or "not yet
merged/fixed" status lines — this kind of content rots in days (a CRE-69 section once
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

Edit the flow file to incorporate the missing detail directly into the existing flow structure
— a fix is a content change, not a new changelog line. Tag the inserted content with the
source ticket as a trailing provenance marker, `(CRE-XX)`, and nothing else (no date, no
outcome label). Common patterns:

| Gap type | Where to fix | Example change |
|----------|-------------|----------------|
| Missing Feign client call in flow | Add a sub-step to the flow section listing the Feign call | "6. Call `BomFeignClient.charge(reserve=true, usage)` via `POST /body-service-resource-usages/charge` (CRE-47)" |
| Entity field not documented | Add the field to the entity table | `amount` \| `BigDecimal(21,2)` \| Recovery amount (CRE-52) |
| Method signature stale | Update class name or method name in the Key Classes table | Replace `ReportJobService.setStatus()` with correct method |
| Missing endpoint | Add to REST Endpoints table | Add row with method, path, purpose |
| Cross-service dependency undocumented | Add a "## Dependencies" section or note in the flow | "Requires BOM service for commission calculation via `BomFeignClient` (CRE-61)" |

After editing, the flow file must still read as a coherent document — the errata entry
described a fix, but you apply it as part of the regular flow structure, not as an appended note.

**If the fix requires creating a new wiki file** (e.g. a flow that has no wiki page yet):

1. Create the file with YAML frontmatter — use this schema (the freshness fields are the
   contract `lib/wiki-check.sh` lints, see the Freshness contract note at the bottom of this
   skill):
   ```yaml
   ---
   services: [list of microservice names]
   entities: [list of key JPA entities or domain objects]
   flows: [list of flow names this file covers]
   keywords: [searchable terms a ticket description might contain]
   related: ["path/to/related-file.md", ...]
   verified_at: "{today, YYYY-MM-DD}"
   verified_against: {repo: "{repo-slug}", sha: "{HEAD sha of that repo right now}"}
   stale_after: 90
   verified: machine-verified
   ---
   ```
   `verified: machine-verified` is correct for content this skill itself wrote from a
   ticket-implement/appraise finding — reserve `human-reviewed` for content a person actually
   read and confirmed, and `unverified` for content copied in without independent checking.
2. Add a row to the **File Registry** table in `{WIKI_ROOT}/index.md`.
3. Add entries to the **Lookup by Topic** and **Lookup by Service** sections of `index.md`.
4. Add the new file to the `related:` frontmatter field of any existing files it is related to.

**If editing an existing file**, refresh its frontmatter the same way: set `verified_at` to
today and `verified_against` to the sha of the repo the fix was verified against. A fix applied
without updating `verified_at` leaves the file's freshness classification (`lib/wiki-check.sh`,
§5) wrong — it would still show as decayed relative to the *old* verification, undercutting the
work just done.

### 2c — Mark resolved

After incorporating the fix, **delete** the errata entry — do not strike it through and keep
it. Git history is the record of what was fixed and when; the wiki file itself should only ever
show gaps still open. If `## Errata` is empty after removing the entry, remove the empty
heading too.

---

## Step 2.5 — Synthesize ai-context.md findings

In addition to errata (failures), scan recent `ai-context.md` files (successes) across ticket directories. Promote non-obvious findings into consolidated wiki entries.

### 2.5a — Discover ai-context.md files

Find `ai-context.md` files created within the last 90 days:

```bash
find . -path "*/tickets/*/ai-context.md" -newermt "90 days ago" 2>/dev/null | head -50
```

If the `tickets` directory is elsewhere, derive the path from the ticket-auto workspace structure or search from the repo root. If no files are found, skip to Step 3 — Lint before commit (a no-op when nothing changed this run).

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
separate ticket list — a bullet with two contributing tickets carries both: `(CRE-47, CRE-61)`.

### 2.5d — Count and track

Track the number of ai-context.md files processed and the number of findings promoted to wiki. These counts are included in the Step 5 report alongside errata counts.

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

(`$REPOS_ROOT` may be empty in standalone, non-`--from-auto` runs — `wiki-check.sh` degrades
gracefully, skipping only the backticked-class-name check when it's unset.)

`wiki-check.sh` (§5 of the wiki-cross-repo-knowledge-layer change) reports per file: line
count, frontmatter completeness, broken `related:` links, backticked class names that don't
resolve to any known repo, and a freshness classification (`fresh`/`stale`/`decayed`) derived
from `verified_against` + `stale_after` + commit activity since. A file this run just edited
without refreshing `verified_at`/`verified_against` (Step 2b) will show up `decayed` here —
treat that as a signal you skipped the frontmatter refresh, not as noise to ignore. Non-zero
exit does not block the commit — wiki-maintenance logs the findings (`META|wiki-lint|warn|...`
when `--from-auto`) and proceeds; a human incorporates lint fixes on the next pass.

---

## Step 4 — Commit WIKI_ROOT

`WIKI_ROOT` is its own docs repo with no branches — after Steps 1-3 land their edits (and the
lint has run), commit them scoped strictly to that directory. The guard below is a literal
precondition on the commit, not just a rule to reason about: `git -C ""` is documented, standard
git behavior for "leave the working directory unchanged" — it is **not** an error and does
**not** fail to resolve — so an empty or unset `WIKI_ROOT` reaching a bare `git -C "$WIKI_ROOT"
commit` would silently commit against whatever the shell's current working directory happens to
be (potentially a source repo). `[ -z "$WIKI_ROOT" ] || [ ! -d "$WIKI_ROOT/.git" ]` is the
deterministic bash check that makes that impossible regardless of how the empty value got there:

```bash
if [ -z "$WIKI_ROOT" ] || [ ! -d "$WIKI_ROOT/.git" ]; then
  echo "WARNING: WIKI_ROOT not configured or not a git repo — skipping wiki commit" >&2
  [ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|wiki-commit|skip|WIKI_ROOT not configured or not a git repo" >> "$LOG_FILE"
else
  git -C "$WIKI_ROOT" add -A
  if git -C "$WIKI_ROOT" diff --cached --quiet; then
    echo "Nothing staged in WIKI_ROOT — skipping commit."
  else
    git -C "$WIKI_ROOT" commit -m "docs(wiki): {TICKET-ID} {one-line summary of what was incorporated}"
  fi
fi
```

Always use `git -C "$WIKI_ROOT"` — never a bare `git commit` from the pipeline's working
directory, which would catch unrelated changes in a source repo. See
`agents/ticket-maintenance-agent.md` for why this is the one commit this agent is allowed to
make.

---

## Step 5 — Report

```
## Wiki maintenance complete

**Errata processed:** {count}
**ai-context findings promoted:** {count}
**Files modified:** {list}
**Committed:** {commit sha, or "skipped — {reason}"}

**Changes:**
1. {file} — {what was added/changed}
2. ...
```

---

## Notes

- **One entry at a time** — read context, apply fix, delete the entry, then move to the next. Do not batch.
- **Errata format is canonical** — the `### {TICKET-ID}` header identifies the entry (`Gap:`/`Fix:` below it). An entry that's been incorporated is deleted, never left behind struck through.
- **If an errata entry is unclear** — mark it with a comment and skip: `<!-- UNCLEAR: {why} -->` instead of resolving.
- **Source is authoritative** — if an errata entry contradicts the wiki flow, trust the errata (it comes from actual ticket implementation, not pre-computed analysis). Verify by reading the referenced source code if needed.
- **Scope** — writes only to files under `{WIKI_ROOT}/`. Does not modify source code.
- **Freshness contract** — every file this skill writes or edits carries `verified_at`, `verified_against: {repo, sha}`, `stale_after`, and `verified` frontmatter (schema in Step 2b). `lib/wiki-check.sh` (Step 3) is the lint for that contract; `ticket-appraise` Step 3a reads its `decayed` classification the same way it already reads decayed prescan docs.
