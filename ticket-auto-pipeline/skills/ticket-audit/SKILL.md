---
name: ticket-audit
description: Proactive cross-ticket audit within a milestone or parent/epic. Detects duplicates, overlaps, empty tickets, goal misalignment, stale tickets, split candidates, and wiki misalignment. Produces a recommendation checklist consumed by ticket-audit-exec. Never mutates Linear. Modes: --milestone {id}, --parent {id}. Flags: --force, --summary, --include-completed.
---

# Ticket Audit

Proactive, batch, pre-pipeline audit of all tickets under a milestone or parent/epic. Detects quality issues across the full ticket group before pipeline processing begins — duplicates, overlaps, empty tickets, goal misalignment, insufficient info, and split candidates.

**Modes:**
- `--milestone <id>` — audit all issues in a Linear milestone
- `--parent <id>` — audit all children of a parent/epic ticket

**Flags:**
- `--force` — bypass scan cache, discard previous recommendation, re-derive everything
- `--summary` — lightweight goal + bullet-point ticket list to stdout only (no file, no checks, no persona)
- `--include-completed` — include Done/Canceled tickets (default: active only)

**Output:** Recommendation checklist at `{AUDIT_DIR}/recommendations/{context}-{date}.md`. This IS the report. Consumed by `/ticket-audit-exec` for application.

---

## Step 0: Parse args and check for summary mode

Parse all arguments:
- `--milestone <id>` → mode=milestone, target=$id
- `--parent <id>` → mode=parent, target=$id
- `--force` → FORCE=true
- `--summary` → SUMMARY=true
- `--include-completed` → INCLUDE_COMPLETED=true

If neither `--milestone` nor `--parent` is provided, exit with an error message showing usage.

### Summary mode fast path (task 4.0)

If `--summary` is set:

1. Source `lib/linear-api.sh` and `lib/config.sh`
2. Fetch tickets: if mode=milestone, call `get_milestone_issues $target`; if mode=parent, call `get_parent_with_children $target`
3. Extract the goal: for milestone, use `meta.name` + `meta.description`; for parent, use `parent.title` + `parent.description`
4. Print to stdout:
```
Goal: <1-2 sentence synthesis of the target's purpose>

Tickets:
• WIL-123 [Todo] — Title of ticket
• WIL-124 [In Progress] — Title of ticket
...
```
5. Exit 0 — no file written, no per-ticket checks, no persona dispatch.

---

## Step 1: Guard

1. Source `lib/linear-api.sh` (this verifies `LINEAR_API_KEY` via `check_api_key`)
2. Source `lib/config.sh`
3. Create output directories if absent:
   ```bash
   mkdir -p "${AUDIT_DIR}/recommendations" "${AUDIT_DIR}/archive"
   ```
4. **Scan cache check** (`MODE` and `TARGET_ID` come from Step 0):
   - Cache file: `{AUDIT_DIR}/.scan-cache.json`
   - If the file exists, read it: `jq -r --arg tid "$TARGET_ID" '.[$tid] // empty' "$AUDIT_DIR/.scan-cache.json"`
   - If cache entry found AND not `--force`:
     - Print "Audit already run on {scanned_at}, use --force to rescan"
     - Load embedded context from the cached `report_file`:
       - Extract `## Goal Context` section
       - Extract `## Ticket Inventory` table
     - Skip to Step 4 (delta mode — drift check only)
   - If `--force` or no cache entry: proceed to Step 2 (full run)

---

## Step 2: Determine mode and extract target ID

The target ID must be non-empty; the fetch itself is Step 3a.

---

## Step 3: Fetch goal context from Linear + wiki

### 3a: Fetch target context
- **Milestone mode**: Call `get_milestone_issues $TARGET_ID`. Extract `.meta.name` and `.meta.description`.
- **Parent mode**: Call `get_parent_with_children $TARGET_ID`. Extract `.parent.title` and `.parent.description`.

### 3b: Synthesize goal
From the target description, synthesize:
- **Goal**: 1-2 sentence summary of what the milestone/parent aims to achieve
- **Bigger picture**: 2-3 sentence statement of what the cumulative set of tickets achieves together

### 3c: Wiki load
- Resolve `WIKI_ROOT` from env or config
- If set and `{WIKI_ROOT}/index.md` exists:
  - Read the index
  - Extract service/component names (look for headings, bold terms, or explicit service lists)
  - Build a service vocabulary array for use in split detection and wiki misalignment checks
  - Record: "Wiki services identified: {list}"
- If unset or missing: record "Wiki unavailable — scope validation skipped"

Store goal context for embedding in the report file.

---

## Step 4: Fetch tickets

### Fresh run (no cache hit):
- **Milestone mode**: `get_milestone_issues $TARGET_ID` → extract `.issues` array
- **Parent mode**: `get_parent_with_children $TARGET_ID` → extract `.children` array
- If `INCLUDE_COMPLETED` is not set: filter out tickets with state type "completed" or "canceled"
- Cap at `TICKET_AUDIT_MAX_TICKETS` (default 30). If more, include truncation warning.
- If zero tickets: report "No tickets found" and exit 0.

### Re-run / delta mode (cache hit, no --force):
- Load snapshot inventory from cached report file's `## Ticket Inventory` table
- Fetch current tickets from Linear (same as fresh run)
- Run `audit-drift-check.sh`:
  ```bash
  # Prepare snapshot JSON ([{"id":"<identifier e.g. WIL-78>","updatedAt":"<Last Updated cell>"}])
  # and current JSON (the Linear array as-is — the check keys on .identifier,
  # falling back to .id; a legacy date-only Last Updated compares at date precision), then call
  source lib/audit-drift-check.sh
  audit_drift_check snapshot.json current.json
  ```
- If `$CHANGED_IDS` and `$NEW_IDS` are both empty: print "No drift detected since {snapshot date}", exit 0
- If candidates exist: for each ticket in `CHANGED_IDS` + `NEW_IDS`, run LLM drift check against persisted `## Goal Context`:
  - Compare current description/ACs against the goal
  - If ticket no longer addresses the milestone goal → flag as drift
  - Append drift findings under `## Drift` section with `- [ ] drift:` prefix
  - Existing `## Needs Info` and `## Structural` sections remain untouched

---

## Step 5: Load product owner persona

Write the Step 3b goal plus every fetched ticket's title and description to `T="$(bash ~/.claude/skills/lib/ticket-tmp.sh)/audit-text.txt"` (private scratch dir; this file is its ticket text), then run `TICKET_TEXT_FILE="$T" lib/persona-select.sh --repo <repo> --phase audit` and read the persona file at `$PERSONA_BASE`. If `$PERSONA_AUTO_INCLUDE` is non-empty (security keywords in the batch), read it too. Inject its content as role context for this step. This persona remains active through Steps 6 and 7 (per-ticket + cross-ticket analysis). The PO has the widest business view for detecting duplicates, merge candidates, and goal misalignment across all ticket types.

This is one of maximum two persona invocations per audit run.

---

## Step 6: Per-ticket audit (deterministic-first, LLM for borderline)

For each ticket in the fetched list (capped at `TICKET_AUDIT_MAX_TICKETS`), write its Linear issue object to a file and run the deterministic checks first. **Bash handles clear cases; the LLM reviews only borderline results.**

```bash
bash ~/.claude/skills/lib/audit-run-checks.sh --ticket-json "{ticket.json}" --wiki-services "{wiki_services_csv}" --extra-patterns "{extra_patterns}"
```

It strips the `## Planner Context` block (the planner's own mandated metadata, e.g. 3+ `Affected Services`) before Checks 4 and 6 and split detection, runs Checks 2, 3, 4, 5, 6 and 8 and split detection in that order, prints each check's raw output, then one `FINDING=<BLOCKER|WARNING>|<text>` line per deterministic finding (record each verbatim) and a `REVIEW=CHECK_2|…` / `REVIEW=CHECK_3|…` line when the LLM has flagged text to confirm. `lib/audit-run-checks.sh` header: inputs and the exact messages.

### Check 1: Multi-role credential gaps (BLOCKER — LLM)

Requires semantic understanding of role mentions vs credential availability. LLM evaluates the ticket description for distinct role requirements and checks CLAUDE.md for matching credentials. Flag as BLOCKER if roles > credential sets.

### Check 2: Untestable acceptance criteria (WARNING — bash → LLM confirm)

Only on `REVIEW=CHECK_2`: review just the ACs it lists. If you confirm any are genuinely untestable, record a WARNING with the specific AC text.

### Check 3: Missing test data assumptions (WARNING — bash → LLM confirm)

Only on `REVIEW=CHECK_3`: review just the assumption patterns it lists. If they are genuine gaps, record a WARNING.

### Checks 4, 5, 6: Scope identifiable, bug without repro steps (WARNING), empty ticket (BLOCKER — bash)

Fully deterministic: their `FINDING=` lines are the result.

### Check 7: Goal misalignment (WARNING — LLM)

Requires semantic comparison against the milestone/parent goal context. LLM evaluates whether the ticket's description and ACs address the persisted `## Goal Context`. If the ticket does not address the goal, flag as WARNING.

### Check 8: Stale ticket (WARNING — bash)

Not updated in `TICKET_AUDIT_STALE_DAYS`+ days and still in Backlog/Todo: its `FINDING=` line is the result.

### Check 9: Wiki misalignment (WARNING — LLM, requires WIKI_ROOT)

Requires semantic comparison of ticket's claimed service references against wiki service vocabulary. LLM evaluates if the ticket claims functionality the wiki assigns to a different service. If mismatch found, flag as WARNING.

### Split detection (bash-first with templated suggestions)

1. Bash signal detection runs in `audit-run-checks.sh` (AC count, word count, wiki service count over the stripped description, so the planner's `Affected Services` cannot inflate it). With 2+ signals it prints `FINDING=WARNING|Split candidate: <SPLIT_SUGGESTION>`.
2. The templated suggestion covers 80%+ of split cases without the LLM; use it directly unless step 4 applies.
3. **LLM persona only for complex splits:** If the ticket has FE AND BE signals (detected by keyword matching on title + description), write the title, stripped description and ACs to `T="$(bash ~/.claude/skills/lib/ticket-tmp.sh)/audit-split.txt"`, run `TICKET_TEXT_FILE="$T" lib/persona-select.sh --repo <repo> --layer <FE|BE>` and read the persona file at `$PERSONA_BASE` for a layer-informed refinement of the templated suggestion. Otherwise, use the templated suggestion directly.
   - **Backend signal keywords**: API, endpoint, service, migration, model, query, repository, controller, DTO, Feign, job, cron, async
   - **Frontend signal keywords**: component, page, form, modal, button, hook, route, CSS, React, TypeScript, layout, view
4. This counts as the second persona invocation (max reached — no more FE/BE switches).
5. No Linear ticket creation — suggestions are report/checklist items only.

### Record findings

For each ticket with findings, record under the appropriate section:
- `## Needs Info` — for checks 1-5 BLOCKERs, empty ticket, and goal misalignment that needs human clarification
- `## Structural` — for split candidates, stale tickets, wiki misalignment

---

## Step 7: Cross-ticket analysis

Under the PO persona (still active from Step 5), analyze across all tickets:

### Duplicate detection

For every pair of tickets:
1. Call `audit-title-similarity.sh`:
   ```bash
   score=$(bash lib/audit-title-similarity.sh "$title1" "$title2")
   ```
2. Route by Jaccard tier:
   - **>80%**: emit `## Structural` item: `- [ ] {ID1} — merge candidate: duplicate of {ID2} (Jaccard: {score}%)`
   - **50-80%**: LLM confirmation pass — compare descriptions/ACs. If LLM confirms duplicate: report-only finding (not exec-applied). If LLM rejects: suppress.
   - **<50%**: silent (not reported)

### Overlap detection

For each pair referencing the same wiki service:

1. **Bash pre-filter — Jaccard on AC text:**
   ```bash
   source lib/audit-overlap-check.sh
   audit_overlap_check "$ac_text_a" "$ac_text_b"
   ```
2. Route by overlap score:
   - **≥50%** (`OVERLAP_THRESHOLD=above`): LLM confirmation pass — shared terms in `$OVERLAP_SHARED_TERMS` provide context. If LLM confirms overlap, flag under Cross-Ticket Findings as "Potentially overlapping: both target {service} (Jaccard: {score}%)"
   - **<50%** (`OVERLAP_THRESHOLD=below`): silent (not reported)
3. No LLM involved when overlap score is <50% — the bash pre-filter eliminates clear non-overlaps.

### Orphan detection (parent mode only)

When auditing a parent:
- Check each child's `parent.id` matches the audit target
- If a child's parent points elsewhere → flag as orphan under Cross-Ticket Findings

---

## Step 8: Synthesizer + write report

### Synthesize

Combine findings from Steps 6 and 7 into a 2-3 sentence summary:
- Total findings by type (BLOCKERs, WARNINGs, split candidates, duplicates, drift)
- Notable patterns (e.g., "3 tickets reference attorney-service with overlapping ACs")
- Whether drift was detected (re-run only)

### Write recommendation checklist

### Post-audit: Record verifier result (Phase 0 RLVR)

After generating the audit recommendations, record the result:
```bash
source ~/.claude/skills/lib/verifier-result.sh
write_verifier_result verifier=audit verdict=<PASS|WARN> criteria_met=<clean_count> criteria_total=<total_tickets> attempt=1 phase=APPRAISE
```

Write to `{AUDIT_DIR}/recommendations/{context}-{date}.md`:

```markdown
# Audit Recommendations: {context} ({date})
Source: {mode}-{target-id}
Generated: {ISO timestamp}
Phase: needs-info

## Audit Summary
[2-3 sentence synthesizer output]

## Goal Context
**Milestone/Parent:** {name}
**Goal:** [1-2 sentence goal summary]
**Bigger picture:** [2-3 sentence cumulative scope statement]
**Wiki services identified:** {list or "N/A — wiki unavailable"}

## Ticket Inventory (snapshot at audit time)
| ID | Title | State | Assignee | Last Updated |
|---|---|---|---|---|
| WIL-78 | Attorney assignment UI | Todo | — | 2026-05-01T14:22:05.000Z |

## Needs Info (run 1 — delegate to ticket-critique)
- [ ] WIL-123 — needs-info: missing repro steps

## Structural (run 2 — post comments only)
- [ ] WIL-78 — merge candidate: duplicate of WIL-79 (Jaccard: 88%)
- [ ] WIL-100 — split candidate: 6 ACs, 2 services. Suggested: API + UI

## Drift
- [ ] WIL-55 — drift: description now references payment flow; milestone goal is attorney assignment
```

### Update scan cache

```bash
# Read existing cache (or create empty object)
cache=$(cat "${AUDIT_DIR}/.scan-cache.json" 2>/dev/null || echo "{}")
# Update entry for this target
updated=$(echo "$cache" | jq --arg tid "$TARGET_ID" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg file "$report_path" \
  '.[$tid] = {scanned_at: $date, report_file: $file}')
echo "$updated" > "${AUDIT_DIR}/.scan-cache.json"
```

### Output

Print the file path and brief summary to stdout:
```
Audit complete: {report_path}
Findings: N needs-info, M structural, D drift
```
