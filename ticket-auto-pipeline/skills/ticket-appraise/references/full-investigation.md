# ticket-appraise — full investigation (Steps 2, 2.5, 2.6, 3, 3-Agent)

Read only under the condition in SKILL.md Step 1.3e. These are the steps an eligible fast-path run skips. Steps 2.1, 2.7, 2.8 and 3.5 stay in SKILL.md and run between and after these, in SKILL.md order: 2 → 2.1 → 2.5 → 2.6 → 2.7 → 2.8 → 3 or 3-Agent → 3.5. Each step's fast-path note also stays in SKILL.md.

## Contents

- Step 2 — Expand notes.md for appraisal (the notes.md template; the Open Questions tagging rule stays in SKILL.md)
- Step 2.5 — Complexity sweep (persona, scoring run, routing, `## Complexity` record; the scoring rubric stays in SKILL.md)
- Step 2.6 — Prior-art search (claude-mem, local tickets, ai-context.md)
- Step 3 — Investigate the codebase (inline path): 3a prescan and wiki loading (3a.0–3a.4), 3b service CLAUDE.md, 3c call chain (Paths P, A, B and conflict resolution), 3d data availability, 3e validation pass, 3f root cause hypothesis
- Step 3-Agent — Investigate the codebase (delegated path): 3-Agent-a loading, 3-Agent-b Explore agent prompt

---

## Step 2 — Expand notes.md for appraisal

ticket-setup writes a minimal notes.md stub. Replace it with the full appraisal template:

```markdown
# Working Notes — {ISSUE-ID}

## Status
**Appraised:** {today's date}
**Current status:** {Linear status}

## Initial Investigation

{After completing Step 3, summarise your code findings here — relevant files, components, services, suspected root cause or implementation area. When Step 2.5 printed a non-empty `PERSONA_DEBUG`, Step 3f adds a `### Root cause hypothesis` subsection here.}

## Open Questions

- {List anything unclear from the ticket description, each tagged per the scheme below}

## Next Steps

- {First concrete action to move this ticket forward}

## Session Log

### {today's date}
- Ticket appraised and local workspace created.
```

The Open Questions tagging rule and the hand-off to Step 2.1 follow in SKILL.md Step 2.

---

## Step 2.5 — Complexity sweep

Activate the analyzer persona before scoring:

```bash
# --ticket-dir derives the type (manifest `type`, else `bug` from context.md's Labels line, else none)
# and passes it as the selector's --type; it also feeds the selector the ticket text.
eval "$(TICKET_ID="{TICKET-ID}" TICKET_TEXT_FILE="{TICKET-DIR}/context.md" bash ~/.claude/skills/lib/persona-select.sh --repo <repo> --phase appraise --ticket-dir "{TICKET-DIR}")"
for _k in PERSONA_BASE PERSONA_AUTO_INCLUDE PERSONA_TESTDATA PERSONA_DEBUG; do echo "$_k=${!_k:-}"; done
```
Read the persona file at `$PERSONA_BASE`. Inject its content as role context for this step. If `$PERSONA_TESTDATA` is non-empty, read it too: the ticket creates or depends on test data, so score where that data comes from and how it is loaded. Keep the printed `PERSONA_DEBUG` value for Step 3 / Step 3-Agent — **do not read that file here**: the analyzer persona already covers the evidence lens, and the only thing the debugger overlay changes at appraisal is the `### Root cause hypothesis` subsection Step 3 writes.

bash ~/.claude/skills/lib/plog.sh APPRAISE complexity-sweep start "Scoring complexity axes"

Score the ticket on the axes of the scoring rubric in SKILL.md Step 2.5 (kept inline there because the fast path uses it), using only what ticket-setup already returned (title, description, labels, comments, epic). No codebase reads yet.

**If the weighted score is below 3 → proceed to Step 2.6, then Step 3 (inline).**

**If the weighted score is 3 or more → proceed to Step 2.6, then Step 3-Agent (delegated) instead.**

Record the decision in notes.md under a `## Complexity` heading — four fields, in this order:

```markdown
## Complexity
**Score:** {simple | complex}
**Weighted score:** {N} (threshold 3)
**Axes fired:** {comma-separated axis:weight list, e.g. "multi-service:2, reversibility:3" — or "none"}
**Reason:** {one sentence; name the Reversibility trigger when it fired}
```

`**Score:**` stays exactly `simple` or `complex` — it is the line every downstream parser reads. The other three lines are the audit trail: a false `simple` found later by `/ticket-retro` (`false_simple_tickets`) is traced back to the axis that failed to fire through them.

bash ~/.claude/skills/lib/plog.sh APPRAISE complexity-sweep done "{simple|complex}, score: {N}/3, axes: {axis:weight list}"

---

## Step 2.6 — Prior-art search (claude-mem)

bash ~/.claude/skills/lib/plog.sh APPRAISE prior-art start "Searching claude-mem"

Run the `/claude-mem:mem-search` skill with 2–3 keywords derived from the ticket title and description (e.g. component name, feature area, error message fragment). Keep the query tight — one focused search, not multiple.

**Evaluate each hit:**

| Confidence          | Criteria                                                              |
| ------------------- | --------------------------------------------------------------------- |
| **High (≥80%)**     | Same component/service, same symptom or change type, outcome recorded |
| **Medium (40–79%)** | Related area or similar pattern, but different scope or older context |
| **Low (<40%)**      | Superficially related keyword match only                              |

Discard hits below 40% — do not record noise.

**For each kept hit, append to notes.md under a `## Prior Art` heading:**

```markdown
## Prior Art

### {hit title or session ID} — {High | Medium} confidence ({score}%)
**Relevance:** {one sentence: why this hit applies}
**Key finding:** {the specific decision, fix, or pattern from that session}
**Incorporate:** {how this should inform the current investigation or implementation}
```

If no hits score ≥40%, write:

```markdown
## Prior Art
No relevant prior art found.
```

**Also search local tickets:**

Derive 2–3 file or component keywords from the affected area identified so far (e.g. `progress-update`, `AttorneyProfileController`, `HandoverRepository`). Use the ticket directory path from Step 1 as `{TICKET-DIR}`. Then run:

```bash
grep -rl "{keyword1}\|{keyword2}" . --include="notes.md" | grep -v "{TICKET-DIR}" | head -20
```

For each match, read just the `## Status`, `## Initial Investigation`, and `## Complexity` sections of that notes.md. Evaluate confidence using the same High/Medium/Low criteria as the claude-mem hits above. Discard hits below 40%.

Append local hits to the same `## Prior Art` section, tagged `[local-ticket]`:

```markdown
### {TICKET-ID} ({directory name}) — {High | Medium} confidence ({score}%) [local-ticket]
**Relevance:** {one sentence: why this hit applies}
**Key finding:** {what was fixed or changed, with file path if found}
**Incorporate:** {how this affects the current investigation or implementation}
```

If no local hits score ≥40%, do not add a new entry — the section already reflects the claude-mem result.

**Also search ai-context.md files (post-implement documentation):**

Run a second grep for `ai-context.md` files using the same keywords:

```bash
grep -rl "{keyword1}\|{keyword2}" . --include="ai-context.md" | grep -v "{TICKET-DIR}" | head -20
```

For each match, read the full `ai-context.md` file (it is short by design — a single page with named sections). Evaluate confidence using the same High/Medium/Low criteria as the local ticket hits above, with these additional factors:

- **Recency**: newer `ai-context.md` (by the Date header) scores higher. Parse the date from the `**Date:**` metadata line.
- **Keyword density**: more term matches across sections (especially **Watch out for** and **Patterns used**) scores higher.
- **Complexity match**: same complexity level as the current ticket scores higher.

**Staleness threshold:** If an `ai-context.md` file's Date header is older than 90 days from today, tag it `[ai-context-stale]` and assign Low confidence regardless of content match. The Date field uses ISO 8601 format (`YYYY-MM-DD`) — parse it directly. The file is still recorded in Prior Art — stale context is better than no context, but the agent should not weight it heavily.

**Result cap:** If more than 5 `ai-context.md` hits pass the confidence threshold, only the top 5 ranked by confidence receive full file reads and Prior Art entries. The remaining hits are summarized as a single line:

```markdown
- {N} additional ai-context.md hits below cutoff — not read
```

Append ai-context.md hits to the same `## Prior Art` section, tagged `[ai-context]` (or `[ai-context-stale]` if older than 90 days):

```markdown
### {TICKET-ID} ({directory name}) — {High | Medium} confidence ({score}%) [ai-context]
**Relevance:** {one sentence: why this hit applies}
**Key finding:** {the specific patterns, gotchas, or decisions from the ai-context.md that apply}
**Incorporate:** {how this should inform the current investigation or implementation}
```

If no ai-context.md hits score ≥40%, do not add a new entry — the section already reflects the claude-mem and local-ticket results.

bash ~/.claude/skills/lib/plog.sh APPRAISE prior-art done "{N} hits"

Proceed to Step 2.7.

---

## Step 3 — Investigate the codebase (inline path — simple tickets only)

bash ~/.claude/skills/lib/plog.sh APPRAISE codebase-investigation start "Tracing call chain"

Based on the ticket's description and labels, identify which service(s) are involved. Use the codebase map from CLAUDE.md to find the right repository under `{REPOS_ROOT}` (resolved in Step 0.5).

### 3a — Load prescan knowledge (per-repo) and wiki (cross-repo) together

Prescan-agent docs under `REPOS_ROOT/.ticket-auto/<repo-slug>/docs/` are the preferred
**per-repo** knowledge source — pre-built, freshness-tracked, and verified against live source.
`WIKI_ROOT` is the cross-repo counterpart: prescan is scoped to one repo at scan time and
cannot answer a ticket that spans services (billing across bom + credit-report, a handover
export across gateway + debt-collection), or document a convention that cuts across all of
them — no matter how fresh that one repo's prescan is. A ticket that only ever reaches prescan
never sees that knowledge, and prescan can itself go stale on exactly the facts wiki holds
durably: `.ticket-auto/gateway/docs/overview.md` describing a routing layer a service migration
already replaced is a per-repo doc being right about its own repo and wrong about the
cross-cutting picture.

So both are loaded in the same step, not staged as a fallback chain ending in wiki:

**Tier 1 → prescan INDEX.md routing (per-repo)** → **Tier 2 → claude-mem corpus (per-repo,
semantic)** → **wiki (cross-repo — loaded alongside Tier 1 in 3a.0b, routed to as a primary
source whenever the ticket's scope is multi-repo or a wiki index topic matches; also the
fallback when Tiers 1-2 return nothing for a single-repo ticket)** → **Path B from-scratch**

---

#### 3a.0 — Identify affected repos and check prescan freshness

**Deterministic repo enumeration** via `prescan-route.sh` (mode=repos) — no LLM judgment on which repos are affected:

```bash
REPOS=$(bash "$HOME/.claude/skills/lib/prescan-route.sh" --mode repos --repos-root "$REPOS_ROOT")
```

For each repo in the list, derive the slug and check freshness:

1. Derive the repo slug: `_derive_slug() { basename "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }`
2. Run the freshness gate:
   ```bash
   eval $(bash "$HOME/.claude/skills/lib/prescan-check.sh" "$repo" --repos-root "$REPOS_ROOT")
   ```
3. Record the status:
   - `PRESCAN_STATUS=fresh` → trust prescan docs, tag findings `(prescan-confirmed)`
   - `PRESCAN_STATUS=stale` or `decayed` → load prescan docs but treat ALL entries as **unconfirmed** — re-verify every file:line reference against live source before trusting. Demote unverifiable entries to open questions.
   - `PRESCAN_STATUS=missing` → skip prescan entirely for that repo, fall through to the wiki (3a.3).

This list is every repo under `REPOS_ROOT` (it is the freshness sweep's input, not the
ticket's scope). The ticket's affected-repo count for 3a.0b is computed separately by
`wiki-route.sh`, which filters the list to repos the ticket actually names — never count this
list.

---

#### 3a.0b — Always load WIKI_ROOT/index.md, and decide whether to route to it

Regardless of prescan status, if `{WIKI_ROOT}` is set (from Step 0.5), bootstrap it first —
covers the `--from-auto` path, where `WIKI_ROOT` reached this skill via the router's env file
rather than Step 0.5's own CLAUDE.md read, so Step 0.5's bootstrap call never ran this run:

```bash
source "$HOME/.claude/skills/lib/wiki-bootstrap.sh"
wiki_bootstrap "$WIKI_ROOT"
```

No-op on an already-scaffolded wiki. Then read `{WIKI_ROOT}/index.md`
now. It is short by design (~110 lines) — cheap enough to load unconditionally rather than wait
for Tiers 1-2 to come up empty first. Prescan is per-repo and cannot answer a cross-repo
question no matter how fresh it is, so there is nothing to lose by loading the wiki's own index
alongside prescan's.

Then compute the routing decision deterministically — no LLM judgment, and no counting by eye:

```bash
eval "$(bash "$HOME/.claude/skills/lib/wiki-route.sh" \
  --wiki-root "$WIKI_ROOT" --repos-root "$REPOS_ROOT" \
  --ticket-title "{TICKET_TITLE}" --ticket-labels "{TICKET_LABELS}" --ticket-desc "{TICKET_DESC}" \
  --affected-services "{AFFECTED_SERVICES}")"   # Planner Context field; "" when absent
```

It evaluates two signals:

1. **Multi-repo scope** — more than one repo under `REPOS_ROOT` is named (whole word,
   case-insensitive) in the ticket's title, labels or description (`prescan-route.sh --mode repos`
   with the ticket text), or the Planner Context `Affected Services` field lists more than one
   service. A workspace that merely *contains* several repos does not count.
2. **Index topic match** — `prescan-route.sh --mode index` against `{WIKI_ROOT}/index.md`'s
   Lookup by Topic/Service tables (the same case-insensitive substring matching prescan uses).

It emits `WIKI_ROUTE=true|false`, `WIKI_ROUTE_REASON`, `WIKI_ROUTE_REPO_COUNT`,
`WIKI_ROUTE_TOPIC_FILES` and `WIKI_ROUTE_LINE`. If `WIKI_ROUTE=true`, 3a.3 loads wiki files as a
**primary** source, run in addition to Tiers 1-2 rather than only as their fallback (start from
`WIKI_ROUTE_TOPIC_FILES` when the reason is `topic`). If `WIKI_ROUTE=false`, the wiki index stays
loaded only as the fallback path already described in 3a.3 — a single-repo ticket with no topic
match has no reason to pull in cross-repo context.

Record the decision in notes.md under Initial Investigation by writing `$WIKI_ROUTE_LINE`
verbatim (`**Wiki routing:** {multi-repo (N repos) | topic match: {files} | not routed — per-repo ticket}`).

**ADR gate:** If investigation so far has already surfaced a decision candidate that looks
architectural (a cross-cutting constraint the ticket would establish, not a routine
implementation choice), invoke the gate now — see § 8 ADR gate in the shared preamble — rather
than carrying the question forward unexamined into the artifact `ticket-appraise-exec` drafts.
`WIKI_ROOT` is already resolved (Step 0.5) and the index you just loaded above is exactly what
the gate's own candidate discovery consults, so this is the cheapest point in the phase to ask.
Most tickets surface nothing here — this is not a mandatory step per ticket, only per candidate.

---

#### 3a.1 — Tier 1: INDEX.md routing (primary path)

**If `PRESCAN_STATUS` is `fresh`, `stale`, or `decayed`** and `.ticket-auto/<repo-slug>/docs/INDEX.md` exists:

**Deterministic keyword routing** via `prescan-route.sh` (mode=index) — bash parses the table, does case-insensitive substring matching, emits the file list. Zero LLM variance between runs:

```bash
MATCHED=$(bash "$HOME/.claude/skills/lib/prescan-route.sh" --mode index \
  --index "$REPOS_ROOT/.ticket-auto/$slug/docs/INDEX.md" \
  --ticket-title "{TICKET_TITLE}" \
  --ticket-labels "{TICKET_LABELS}" \
  --ticket-desc "{TICKET_DESC_FIRST_500}")
# PRESCAN_ROUTE_COUNT and matched file paths are emitted
```

1. **If `PRESCAN_ROUTE_COUNT > 0`:** bash matched keywords → load the matched files.
2. **Verify against live source**: For every file:line reference found in prescan docs, Grep the source repo to confirm the referenced symbol still exists. Confirmed entries → tag `(prescan-confirmed)`. Unconfirmed entries → tag `(prescan-unconfirmed)` and note as open questions if `PRESCAN_STATUS` is stale/decayed.
3. Set `{PRESCAN_FLOW}` = the shortest non-index matched file (most focused prescan doc). Each doc contains pre-traced call chains with real class names, endpoints, and entity fields. If multiple files match, prefer `services/*.md` over top-level docs because service files are more targeted.
4. Record prescan docs loaded in notes.md under Initial Investigation: `**Prescan bootstrap:** {list of files loaded} ({fresh|stale|decayed}) — routed by prescan-route.sh`
5. **If `PRESCAN_ROUTE_COUNT = 0`:** INDEX.md keyword matching found nothing for this repo → fall through to Tier 2 (claude-mem corpus) for the per-repo search. This is independent of the wiki decision already made in 3a.0b.

---

#### 3a.2 — Tier 2: claude-mem corpus fallback (semantic search)

**If Tier 1 returned no matches**, attempt semantic search via the prescan knowledge corpus:

1. Prime the corpus: `mcp__plugin_claude-mem_mcp-search__prime_corpus(name="prescan-<repo-slug>")`
2. Query semantically: `mcp__plugin_claude-mem_mcp-search__query_corpus(name="prescan-<repo-slug>", question="{ticket title + description}")`
3. If the corpus returns relevant doc references → load and verify those files (same verification as Tier 1 step 3).
4. If corpus query returns nothing, or claude-mem MCP is unavailable → this repo's per-repo search is exhausted; 3a.3 below is where the wiki picks up, either because it was already routed to (3a.0b) or as the fallback here.
5. Record: `**Prescan corpus:** <repo-slug> — {matches found | no match | unavailable}`

**If `PRESCAN_STATUS` is `missing` (no prescan exists) for this repo:** its per-repo search is exhausted immediately; proceed to 3a.3.

---

#### 3a.3 — Wiki context: primary (routed) or fallback

The wiki index was already loaded in 3a.0b. Load the wiki's flow files now in either of two
cases — they are not mutually exclusive with prescan, and not gated on prescan having failed:

- **`WIKI_ROUTE=true`** (3a.0b fired on multi-repo scope or a topic match) — load wiki files as
  a primary source, in addition to whatever Tiers 1-2 found per-repo. A multi-repo ticket needs
  both: prescan for each repo's local implementation detail, wiki for how the repos connect.
- **`WIKI_ROUTE=false` but Tiers 1-2 produced no usable results for a repo** — load wiki files
  as the fallback, same as before this change: a single-repo ticket prescan couldn't answer.

**If neither condition holds** (single-repo ticket, no topic match, and Tier 1 or 2 already
found what's needed) — skip wiki file loading entirely. The index was loaded, cost nothing, and
isn't needed further.

When loading:

1. `{WIKI_ROOT}/index.md`'s **Lookup by Topic** section maps keywords to files, and **Lookup by
   Service** maps services to files. Match the ticket's labels, title, and description (already
   done once for the routing decision in 3a.0b — reuse that match) to identify which wiki files
   to load. The index is the authoritative routing table — do not use any hardcoded keyword list.
2. **Scoped loading**: Grep the wiki root for the ticket's keywords, service names and entity names, and Read only the files (or sections) that match.
3. Set `{WIKI_FLOW}` = the first flow file loaded (or the most relevant). Each file contains pre-traced call chains with real class names, endpoints, and entity fields.
4. Also load `{WIKI_ROOT}/services.md` (service responsibilities and Feign wiring) — outline first, then read only the relevant service sections.
5. Record the wiki files loaded in notes.md under Initial Investigation: `**Wiki bootstrap:** {list of files loaded} ({routed: multi-repo|topic-match | fallback: tiers-1-2-empty})`
6. If no topic in the index matches, or the Grep finds nothing, leave `{WIKI_FLOW}` empty — fall through to full discovery in 3c.

**Freshness gate on each loaded wiki file** — run before trusting any of them, mirroring the
prescan freshness gate in 3a.0:

```bash
bash "$HOME/.claude/skills/lib/wiki-check.sh" --wiki-root "$WIKI_ROOT" --repos-root "$REPOS_ROOT" --file "{loaded-wiki-file}"
```

Read the `freshness=` field from the `WIKI_CHECK|...` line it emits:
- `fresh` → trust the file, tag findings `(wiki-confirmed)` as usual.
- `stale` → load it, but treat entries as **unconfirmed** — re-verify each file:line reference
  against live source before trusting, same as a stale prescan.
- `decayed` → **do not trust blindly.** Demote any claim sourced from this file that you cannot
  independently re-verify to `## Open Questions` (`[agent-resolvable]`, per the tagging rule in
  Step 2) instead of writing it into Initial Investigation as fact. A decayed wiki file is
  exactly the failure mode this whole change exists to close — don't let it re-enter silently
  through the tier that's supposed to be authoritative.

Non-blocking: if `wiki-check.sh` errors (missing script, `WIKI_ROOT` not readable), log a
warning and proceed treating the file as `stale` (the conservative middle ground) rather than
either extreme.

**If `{WIKI_ROOT}` is empty and no prescan docs were found for any affected repo:** skip to 3b. No knowledge base is available for this project.

---

#### 3a.4 — Cross-repo prescan

For tickets spanning multiple repos, also load `REPOS_ROOT/.ticket-auto/system.md` (if it exists). This cross-repo contract map documents FE→BE API contracts, shared types, and service boundaries. Use it to confirm which repo owns each layer of the call chain.

### 3b — Read the service CLAUDE.md

Read the `CLAUDE.md` for every affected repository before touching any code. This sets the architectural context for everything that follows.

### 3c — Trace the full call chain

**Path P — Prescan-bootstrapped (`{PRESCAN_FLOW}` was loaded in 3a.1):**

For each layer listed in the prescan doc, Grep to confirm the file and method still exist at the listed paths. Read only the pinpointed method — do not scan whole files. After confirming each layer, append to Initial Investigation with: `(prescan-confirmed)` for fresh prescans, or `(prescan-verified)` for stale/decayed prescans where you re-verified the reference.

If a symbol was renamed or moved, note the discrepancy and mark the finding `(prescan-stale)`. For stale/decayed prescans, demote unverifiable entries to the Open Questions section.

**Close the loop now — don't just note it and move on.** Appraise already did the work of
finding this; nothing downstream re-derives it for free.
- Append a `source=prescan` CORRECTIONS block to notes.md right now (`corrections-parse.sh`'s
  `append_correction "{ticket-dir}/notes.md" "{stale reference}" "prescan" "{what changed,
  with current file:line}"`) — `wiki-maintenance` Step 2.6 already evaluates `source=prescan`
  corrections for promotion into the wiki.
- If a wiki file is *also* loaded for this ticket (`{WIKI_FLOW}` non-empty — a multi-repo ticket
  running Path P and Path A together per 3a.0b) and that wiki file documents the same symbol,
  append a wiki errata entry directly instead of only writing the correction — appraise already
  has the exact evidence, so route it straight to the durable store rather than through an
  intermediate signal.

Skip the full traversal instructions below — you already have your roadmap.

**Path A — Wiki-bootstrapped (`{WIKI_FLOW}` was loaded in 3a.3):**

For each layer listed in the wiki flow file, Grep to confirm the file and method still exist at the listed paths. Read only the pinpointed method — do not scan whole files. After confirming each layer, append the confirmed path to Initial Investigation with: `(wiki-confirmed)`.

If a class has been renamed or moved, note the discrepancy but continue. The wiki may be slightly stale — your job is to verify and update, not rediscover.

**Close the loop now.** Append an errata entry to the wiki flow file directly, using the
canonical schema from `wiki-maintenance` Step 1:

```markdown
### {TICKET-ID}
**Gap:** {what the wiki said vs. what you found — the renamed/moved symbol}
**Fix:** {the corrected class name, path, or signature}
```

If the file already has an `## Errata` section, append to it; otherwise create it. Do this at
discovery time — do not defer to `ticket-implement`'s mismatch-gated write-back (which may never
fire if this ticket turns out `Smooth`) or to `wiki-maintenance` finding it independently later.

Skip the full traversal instructions below — you already have your roadmap.

**Path B — No prescan or wiki (`{PRESCAN_FLOW}` and `{WIKI_FLOW}` are both empty):**

Do not stop at the first plausible file. Trace the feature end-to-end across all layers involved:

**Frontend tickets:** template → component → service → HTTP call → backend API endpoint
**Backend tickets:** API endpoint → delegate/controller → service → repository/feign client → database or downstream service
**Full-stack tickets:** trace both directions and identify where they meet

For each layer, Grep to locate the specific file and method, then Read only that section — do not scan whole files.

**Write findings to notes.md as you go — do not wait until the end of the step.** After each layer is traced, append what you found to the **Initial Investigation** section immediately.

**Conflict resolution — prescan vs. wiki disagreement:**

On a multi-repo ticket, Path P and Path A can both run (3a.0b routes the wiki in alongside
prescan). When they describe the same cross-cutting fact differently — a different Feign client
method, a different contract shape, a different owning service — do not silently pick one:

1. **Compare freshness.** The prescan side's timestamp is the owning repo's `meta.json`
   `last_scanned_at` (already surfaced as `PRESCAN_STATUS` by `prescan-check.sh` in 3a.0). The
   wiki side's timestamp is the consulted file's frontmatter `verified_at` (the freshness
   contract `lib/wiki-check.sh` lints — §5 of the wiki-cross-repo-knowledge-layer change). A
   wiki file with no frontmatter yet (pre-adoption) is treated as older than any prescan
   timestamp — it has no verified claim to weigh against a dated one.
2. **Trust whichever side is newer.** Tag the finding `(prescan-confirmed)` or
   `(wiki-confirmed)` per the conventions above, based on which source won.
3. **Record the conflict itself** — resolving it silently throws away a signal that one side
   needs fixing:
   ```markdown
   **Conflict:** {prescan file}:{line} says {X} ({prescan repo's last_scanned_at}); {wiki file}
   says {Y} (`verified_at` {date}). Trusted {prescan|wiki} — newer.
   ```
   Append this immediately below the resolved finding in Initial Investigation.
4. **Close the loop on the losing side** the same way Path P/Path A already do above — if
   prescan lost, write the `source=prescan` correction; if the wiki lost, append the wiki
   errata entry directly.

### 3d — Confirm data availability

Explicitly answer: **Is the data already available at the point where the fix needs to happen?**

- For frontend fixes: is the field already on the model/interface? Is it already returned by the API call? Or does the backend need to change?
- For backend fixes: does the required data exist in the DB/entity, or does a migration need to be added?

Document the answer in notes.md. This determines whether the ticket is frontend-only, backend-only, or full-stack — and must be explicit, not assumed.

### 3e — Validation pass

After drafting the Initial Investigation, run a second pass over every finding:

For each bullet point, ask: **"Have I read the actual code that confirms this?"**

- If yes — keep it, ensure the file path and line number are cited.
- If it's inferred — either confirm it now, or rewrite it as an open question.

Remove or demote anything that is assumption rather than confirmed evidence.

### 3f — Root cause hypothesis (bug tickets only)

Only when Step 2.5 printed a non-empty `PERSONA_DEBUG`. Do not read the debugger persona file. After the validation pass, append this subsection at the end of `## Initial Investigation` (a `###` heading, so every reader that stops at the next `## ` still sees it as part of the section):

```markdown
### Root cause hypothesis
- **Hypothesis:** {X} because {Y}
- **Evidence:** {file:line you read that supports it}
- **Disproof check:** {a positive, checkable finding — e.g. "finding a caller of X in Y that passes a non-null value would disprove it"}
- **Confidence:** {high | medium | low}
```

Phrase the disproof check as something that *would be found*, never as an absence ("X does not exist", "nothing calls Y") — Step 3.5 demotes negative existentials to `[needs-human]` and would strip the hypothesis. Use the words "would disprove". One hypothesis only; if the evidence supports none, write `- **Hypothesis:** none — {what is still unknown}` and add the gap to `## Open Questions`.

bash ~/.claude/skills/lib/plog.sh APPRAISE codebase-investigation done "{N} files traced"

---

## Step 3-Agent — Investigate the codebase (delegated path — complex tickets)

bash ~/.claude/skills/lib/plog.sh APPRAISE codebase-investigation start "Delegating to Explore agent"

### 3-Agent-a — Load prescan knowledge and wiki context

Run exactly the same loading logic as Step 3a above — wiki alongside prescan, not after it:

1. **Wiki index (3a.0b):** Always load `{WIKI_ROOT}/index.md` if `{WIKI_ROOT}` is set. Decide `WIKI_ROUTE` from multi-repo scope or an index topic match.
2. **Tier 1 (prescan INDEX.md):** Read `REPOS_ROOT/.ticket-auto/<repo-slug>/docs/INDEX.md`, run `prescan-check.sh` for freshness, match ticket keywords against Lookup by Topic/Service tables, load and verify identified files, tag confirmed entries `(prescan-confirmed)`, set `{PRESCAN_FLOW}` if a relevant doc is found.
3. **Tier 2 (claude-mem corpus):** If Tier 1 misses, prime and query the prescan corpus semantically.
4. **Wiki files (3a.3):** Load wiki flow files as a primary source when `WIKI_ROUTE=true`, or as the fallback when Tiers 1-2 produced nothing. Set `{WIKI_FLOW}` to the most relevant flow file or leave empty.
5. **Cross-repo:** For multi-repo tickets, load `REPOS_ROOT/.ticket-auto/system.md`.

Record all findings in notes.md. This runs for BOTH paths — simple (3a) and complex (here).

### 3-Agent-b — Spawn the Explore agent

Spawn an `Explore` subagent to perform the investigation in isolation. Give it **no opinion** about where the fix should be — only facts and questions.

**Prompt the agent with:**

```
You are investigating a codebase for a ticket. Your job is to trace the code and report only confirmed evidence — no speculation.

Ticket: {ISSUE-ID} — {title}
Description: {description}
Labels: {labels}

Repos to search (under {REPOS_ROOT} — resolved from the project CLAUDE.md codebase map):
{list repos from CLAUDE.md codebase map that are plausibly involved}

{If PRESCAN_FLOW was loaded above, include this paragraph verbatim:}
A prescan doc at `{PRESCAN_FLOW}` contains a pre-traced call chain for this feature area. Read it now. It lists real class names, method signatures, endpoints, and entity fields that were verified against source at scan time. Start by CONFIRMING those paths — do not rediscover from scratch. If a symbol was renamed or moved, note it. For stale/decayed prescans, re-verify every reference against live source; demote unverifiable entries to open questions.

{If WIKI_FLOW was loaded above, include this paragraph verbatim — this can be true alongside the
PRESCAN_FLOW paragraph on a multi-repo ticket, since prescan (per-repo) and wiki (cross-repo)
are loaded together, not one instead of the other:}
A wiki file at `{WIKI_FLOW}` contains a pre-traced call chain for this feature area. Read it now. It lists real class names, method signatures, endpoints, and entity fields. Start by CONFIRMING those paths — do not rediscover from scratch. If a class was renamed or moved, note it but follow the wiki's structure. If this and the PRESCAN_FLOW paragraph above describe the same cross-cutting fact differently, flag it as a conflict rather than silently picking one — the calling appraisal step resolves it by freshness (§3c conflict resolution).

IMPORTANT — Grep to locate symbols, then Read only the pinpointed section — never scan whole files.

Answer each question below with specific file paths and line numbers. If you cannot confirm an answer, say "NOT FOUND" — do not guess.

1. Trace the full call chain end-to-end (frontend → backend or backend → DB). For each layer: file path, method/function name, line number.
2. At the point where the fix needs to happen: is the required data already available, or does it need to come from somewhere else? Where exactly?
3. Are there any existing tests covering this area? If so, list them.
4. If the service uses MapStruct (look for `@Mapper` annotated interfaces): read every mapper file that touches the affected entity and list all `@Mapping` annotations, including any `expression = "java(...)"` strings. These are invisible to symbol-based reference search and must be read directly.
5. List anything you searched for but could not locate.
```

**When the agent returns:**

- Copy its findings verbatim into the **Initial Investigation** section of notes.md
- Append a `**Source:** Explore agent (isolated run)` note
- Do NOT re-interpret or summarise — use the raw evidence as-is
- If Step 2.5 printed a non-empty `PERSONA_DEBUG`, then write the `### Root cause hypothesis` subsection exactly as Step 3f describes, citing only file:line evidence the agent returned

bash ~/.claude/skills/lib/plog.sh APPRAISE codebase-investigation done "{N} files traced"
