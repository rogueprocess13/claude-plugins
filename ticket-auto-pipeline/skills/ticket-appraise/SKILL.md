---
name: ticket-appraise
description: Investigation planner for a Linear ticket. Fetches the issue, creates the local directory structure, runs a complexity sweep, searches prior art, and traces the full codebase call chain. Supports fast-path for planned tickets (planned label + Planner Context block) — skips complexity sweep, prior art, and codebase investigation when planner metadata is available. Writes findings to notes.md. Use when the user says "appraise ticket {ID}", "/ticket-appraise {ID}", or "take on ticket {ID}". After this completes, run /ticket-appraise-exec to create artifacts and update Linear.
---

# Ticket Appraise — Planner

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the investigation sequence below in order. This skill ends with notes.md fully populated. The executor skill (`/ticket-appraise-exec`) handles artifact creation and Linear updates.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=APPRAISE, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,get_comments, HAS_LOGGING=true, HAS_HEARTBEAT=true. Before starting, source the project context: `source ~/.claude/skills/lib/ticket-env.sh {TICKET_ID}`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=APPRAISE, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,get_comments, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT,ISSUE_PREFIX,BE_SERVICES,WIKI_ROOT, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
Fast-path decisions are written inline in Step 1.3. Also write (event schema: `pipeline-heartbeat-format.md`):
- after the complexity sweep (or fast-path complexity): `hb-wrap.sh decision "complexity-score" "fired" "...score..." '{"axes":"...","score":"..."}'`
- after codebase investigation: `hb-wrap.sh decision "blast-radius" "fired" "...N files..." '{"file_count":"N"}'`
- prior art: `hb-wrap.sh decision "prior-art" "fired" "...N matches..."`, or `hb-wrap.sh decision "prior-art" "info" "no prior art found"`
- WIKI_ROOT absent from CLAUDE.md, default path used: `hb-wrap.sh fallback "wiki-bootstrap" "fired" "using default wiki path" '{"reason":"WIKI_ROOT not in CLAUDE.md"}'`
- gitnexus impact unavailable: `hb-wrap.sh fallback "impact-data" "fired" "using local grep" '{"reason":"MCP tool unavailable"}'`

### Step dispatch
Also: if `--from-step` is set, **suppress Resume Mode** in Step 1 — the workspace exists by definition, and re-evaluation is not needed.

| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `setup-workspace` | Step 1.3 (fast-path check) | ticket-setup output already in notes.md |
| `fast-path` | Step 2.7 (readiness critique) | Fast-path already populated notes.md — skip to critique |
| `critique` | Step 2.8 (blast radius) | Readiness critique already completed; Step 3 / 3-Agent then needs `references/full-investigation.md` per Step 1.3e |
| `blast-radius` | Step 3 or 4 (codebase/ticket update) | Blast radius already completed; Step 3 / 3-Agent needs `references/full-investigation.md` per Step 1.3e |
| `complexity-sweep` | Step 2.6 (prior art) | `## Complexity` in notes.md; read `references/full-investigation.md` first (Step 1.3e) |
| `prior-art` | Step 3 (codebase investigation) | `## Prior Art` in notes.md; read `references/full-investigation.md` first (Step 1.3e) |
| `codebase-investigation` | Step 3.5 (claim verification) | `## Initial Investigation` in notes.md |
| `claim-verify` | Step 4 (ticket update) | Claim verification already completed |
| `handoff` | End — skill already complete | — |

---

## Step 1 — Set up local workspace

bash ~/.claude/skills/lib/plog.sh APPRAISE setup-workspace start "Creating ticket workspace"

Run `/ticket-setup {TICKET-ID}` and wait for it to complete.

- If ticket-setup reports **workspace already exists** → skip to **Resume mode** at the bottom of this skill.
- If ticket-setup reports **workspace created** → continue to Step 2.

The ticket-setup output provides: directory path, title, user, status, priority, labels, epic, environment. Use these values throughout the remaining steps — do not re-fetch from Linear.

bash ~/.claude/skills/lib/plog.sh APPRAISE setup-workspace done "Workspace ready"

---

## Step 1.3 — Fast-Path Check (planned tickets)

bash ~/.claude/skills/lib/plog.sh APPRAISE fast-path start "Checking planned ticket eligibility"

**Before the task tracker and any LLM investigation**, check whether this ticket qualifies for accelerated appraisal via Planner Context metadata.

### 1.3a — Run eligibility check

Source the fast-path library and check eligibility:

```bash
source "$HOME/.claude/skills/lib/planned-ticket-check.sh"
source "$HOME/.claude/skills/lib/appraise-fast-path.sh"
check_fast_path_eligible "{TICKET-ID}"
```

This calls `get_issue` to fetch the ticket, checks for the `planned` label, validates the `## Planner Context` block, and determines eligibility based on Pre-approved status and Confidence.

### 1.3b — Act on result

| Exit | FAST_PATH_ELIGIBLE | FAST_PATH_REASON | Action |
|------|-------------------|-------------------|--------|
| 0 | `true` | `pre_approved` or `confidence_met` | **Fast-path active.** Continue to Step 1.3c. |
| 1 | `false` | `not_planned` | No `planned` label. Proceed normally to Step 1.5. |
| 1 | `false` | `malformed_block` | `planned` label present but Planner Context is missing or invalid. Log a warning and proceed normally — the planner enrichment is degraded but the ticket is still valid. |
| 2 | `false` | `low_confidence_not_preapproved` | Confidence below threshold AND not pre-approved. Log a warning and proceed normally — this ticket needs full human review. |
| 2 | `false` | `confidence_below_threshold` | Confidence below fast-path threshold (0.85). Proceed normally — the planner was uncertain. |

### 1.3c — Fast-path active: populate notes.md from Planner Context

If `FAST_PATH_ELIGIBLE=true`:

1. **Generate fast-path notes.md:**

   ```bash
   generate_fast_path_notes "{ticket-dir}" "{TICKET-ID}"
   ```

   This writes notes.md with:
   - `## Complexity` — derived from Strategy field (Conservative → simple, Balanced/Innovative → complex), then escalated to `complex` when `detect_reversibility_trigger` finds a Reversibility keyword in the description (schema DDL, migration tooling, destructive data change, payment/billing, auth, breaking API, no-revert). Escalation-only — it never lowers a Strategy-derived `complex`. The result, fired or not, is recorded in `**Axes fired:**`.
   - `## Prior Art` — skipped (planner-provided context)
   - `## Initial Investigation` — populated from Affected Services + Target Symbols + Decision

   Then run **Step 2.1** (Refinement carry-over and body drift) on the notes.md just written. `generate_fast_path_notes` overwrites notes.md, so Step 2.1 must run after it, never before.

2. **Write heartbeat:**

   ```bash
   bash ~/.claude/skills/lib/hb-wrap.sh decision "fast-path" "fired" "eligible" \
     '{"eligible":"true","reason":"'"$FAST_PATH_REASON"'","strategy":"'"$FAST_PATH_STRATEGY"'","confidence":"'"$FAST_PATH_CONFIDENCE"'"}'
   ```

3. **Write pipeline log:**

   ```bash
   bash ~/.claude/skills/lib/plog.sh APPRAISE fast-path done "Eligible — ${FAST_PATH_REASON}, Strategy=${FAST_PATH_STRATEGY}, Confidence=${FAST_PATH_CONFIDENCE}"
   # G3: write from-planned marker so downstream consumers (Phase 1 inspector,
   # trajectory) can confidence-weight verifier results from planned tickets
   bash ~/.claude/skills/lib/plog.sh META from-planned info "true"
   ```

4. **Skip to Step 2.7 (Readiness critique).** The following steps are COVERED by fast-path:
   - Step 2 (Expand notes.md) — fast-path already wrote it
   - Step 2.5 (Complexity sweep) — derived from Strategy, plus the Reversibility check below
   - Step 2.6 (Prior-art search) — planner-provided context
   - Step 3 (Codebase investigation) — Target Symbols provide starting points

   **Reversibility judgement (escalation-only).** The keyword scan is the deterministic floor, not the whole axis. If `## Complexity` still reads `**Score:** simple`, read the description and Planner Context against the full Step 2.5 **Reversibility** trigger list. If any trigger applies that the scan missed (e.g. "make the `email` field required on the public API" — a breaking contract change with no keyword), rewrite the section: `**Score:** complex (escalated from simple — reversibility: {trigger})`, `**Weighted score:** 3 (threshold 3)`, `**Axes fired:** reversibility:3 (judged — {trigger})`. Never lower a `complex` score, and never touch a score the scan already escalated.

   **Still required** (run these normally):
   - Step 2.7 (Readiness critique) — validates ticket completeness regardless of planner metadata
   - Step 2.8 (Blast Radius Analysis) — provides real impact data the planner couldn't have
   - Step 4 (Update ticket in Linear) — claim + label
   - Step 5 (Hand off) — report to user

5. **Exploration depth consumption** — adjust investigation scope based on `Exploration Depth` field (Schema-Version 2). Read from the Planner Context block:

   | Depth | Behavior |
   |---|---|
   | `deep` | Trust the planner's investigation. Skip full codebase grep. Use `Code Paths Traced` and `Target Symbols` as the complete investigation surface. Verify that listed API contracts still match current code (contracts may have drifted). |
   | `standard` (or absent) | Use `Target Symbols` as primary investigation path. Supplement with targeted grep on affected files. Do NOT do a full codebase sweep — the planner already traced key call chains. |
   | `quick-scan` | Treat `Target Symbols` as hints only. Do a full codebase investigation — the planner only did a surface scan. The `quick-scan` depth means the planner may have missed relevant code paths. Load `references/full-investigation.md` as Step 1.3e says and run its Step 3 or Step 3-Agent after Step 2.8; fast-path stays active for the other steps. |

   If `Open Questions` is non-empty, treat each question as an investigation prompt during blast radius analysis (Step 2.8). Surface answers (or lack thereof) in notes.md.

### 1.3d — Fast-path skipped: proceed normally

If `FAST_PATH_ELIGIBLE=false`:

```bash
bash ~/.claude/skills/lib/hb-wrap.sh decision "fast-path" "fired" "skipped" \
  '{"eligible":"false","reason":"'"$FAST_PATH_REASON"'"}'
bash ~/.claude/skills/lib/plog.sh APPRAISE fast-path skip "Not eligible — ${FAST_PATH_REASON}"
```

Continue to Step 1.3e, then Step 1.5 normally.

### 1.3e — Full-investigation reference (load condition)

**If fast-path is NOT active** (`FAST_PATH_ELIGIBLE=false`), **or** it is active with `Exploration Depth` `quick-scan`: before running Step 2, 2.5, 2.6, 3 or 3-Agent, or resuming at or into any of them via `--from-step` (`complexity-sweep`, `prior-art`, `critique`, `blast-radius`), or re-running Step 2.5 from Resume mode, run `bash ~/.claude/skills/lib/skill-ref.sh ticket-appraise references/full-investigation.md`, then Read the printed path in full. Do not continue until you have read it. If `skill-ref.sh` exits non-zero, run `bash ~/.claude/skills/lib/plog.sh META reference-missing fail "references/full-investigation.md"` and stop: never run those steps from memory.

A `--from-step` resume and Resume mode both skip Step 1.3. A `complexity-sweep` or `prior-art` resume and Resume mode always read it: only a non-fast-path run writes those checkpoints, and Resume mode never evaluates fast-path. A `critique` or `blast-radius` resume reads it before Step 3 / 3-Agent unless notes.md `## Prior Art` says `(fast-path — planner-provided context)` and the Planner Context `Exploration Depth` is not `quick-scan`. An eligible fast-path run with `standard`, `deep` or no `Exploration Depth` never reads it: Step 1.3c covers those steps, and the Step 2.5 scoring rubric and the Step 2 Open Questions tagging rule it needs stay in this file. After a context compaction, read it again before continuing any of those steps.

---

## Step 1.5 — Create task tracker

**Before proceeding further**, create a TaskCreate for every remaining step in this skill. Each task subject = the step heading (e.g. "Step 2: Expand notes.md for appraisal"). This ensures no step is skipped even when context scrolls.

**If fast-path is active** (Step 1.3c), only create tasks for: Step 2.7 (Readiness critique), Step 2.8 (Blast Radius Analysis), Step 4 (Update ticket), Step 5 (Hand off). Skip Steps 2, 2.5, 2.6, and 3 — they are covered by planner metadata.

After each step is fully done (including all sub-steps), mark it completed with TaskUpdate. At session end, write a trace file to the ticket directory:

```bash
cat > {ticket-dir}/appraise-session.md << 'TRACE'
# appraise session — {ISSUE-ID}
**Date:** {today}
**Complexity:** {simple|complex}
**Fast-path:** {yes — reason|no}

## Step trace
- [x] Step 1.3: Fast-path check — {eligible|skipped} ({reason})
- [x] Step 2: Expand notes.md — {done|skipped (fast-path)}
- [x] Step 2.5: Complexity sweep — {score}, axes: {list|skipped (fast-path: Strategy={strategy})}
- [x] Step 2.6: Prior-art search — {hits} hits|skipped (fast-path)
- [x] Step 2.7: Readiness critique — {BLOCKED|WARNINGS|CLEAR}
- [x] Step 3: Investigate codebase — {N} files traced|skipped (fast-path: {N} target symbols)
- [x] Step 4: Label ticket — {complexity} label applied
- [x] Step 5: Hand off — reported to user
TRACE
```

---

## Step 2 — Expand notes.md for appraisal

> **Fast-path:** Skip this step if fast-path is active (Step 1.3c). notes.md was already written by `generate_fast_path_notes`.

Moved to `references/full-investigation.md` (the appraisal notes.md template), read per the Step 1.3e condition. The Open Questions tagging rule below stays here because later steps on both paths apply it.

**Open Questions tagging.** Every bullet appended to `## Open Questions` — here or in any later step (2.6, 2.8, 3, 3-Agent) — MUST start with one of two tags:

- **`[needs-human]`** — a judgment call, business decision, or trade-off with no single correct answer. Left open for a human to answer via Linear comment; `ticket-gate-reconcile` holds on these.
- **`[agent-resolvable]`** — a factual lookup with a determinate answer in the codebase (e.g. "does anything read X?", "does this file exist?"). Step 3.5 below resolves these inline before the ticket ever reaches Linear — they must never be tagged and left open.

An untagged bullet is a defect in whichever step wrote it — fix it there, don't let it reach Step 3.5.

Then run **Step 2.1** on the expanded notes.md.

---

## Step 2.1 — Refinement carry-over and body drift (planned tickets)

Runs on both paths, and is safe to repeat: after `generate_fast_path_notes` (Step 1.3c) and after the Step 2 template is written. Both functions are deterministic bash, read only the local manifest and planner directory, and are no-ops for an ad-hoc ticket. Run exactly this block — do not edit the sections they write by hand:

```bash
source "$HOME/.claude/skills/lib/linear-api.sh" 2>/dev/null || true
source "$HOME/.claude/skills/lib/refinement-carryover.sh"
NOTES_FILE="{ticket-dir}/notes.md"
# Carry Refinement's non-blocking leftovers into ## Refinement Carry-over.
refinement_carryover_append "$NOTES_FILE" "{TICKET-ID}" || echo "refinement carry-over: append failed (non-fatal)"
# Hold a ready planned ticket whose Linear text drifted from the body Refinement evaluated.
BODY_DRIFT_CLASS=$(refinement_carryover_drift_check "{TICKET-ID}" "$NOTES_FILE") || BODY_DRIFT_CLASS="skip:error"
echo "BODY_DRIFT_CLASS=$BODY_DRIFT_CLASS"
```

Both functions' contracts are in `lib/refinement-carryover.sh`'s header. What this step does with the results:

- `[agent-resolvable]` carry-over items are investigation prompts for blast radius (Step 2.8) and investigation (Step 3). Step 3.5 does not have to close them, and **they never add `needs-info` or hold the ticket by themselves**.
- `[needs-human]` items are already mirrored into `## Open Questions`, so the gate holds through the Open Questions rule and `ticket-gate-reconcile` releases it on an answer.
- `### Test candidates` are left for `ticket-implement` and `ticket-verify`.
- `BODY_DRIFT_CLASS`: nothing to do for any value — on `adopt`, `conflict` or `local-ahead` the function has already added the `[needs-human]` Open Question and logged it. Never write the planner's `body.md` yourself.

---

## Step 2.5 — Complexity sweep

> **Fast-path:** Skip this step if fast-path is active. Complexity is derived from the Planner Context Strategy field (Conservative → simple, Balanced/Innovative → complex), then escalated by the Reversibility axis — see Step 1.3c. The `## Complexity` section in notes.md was already written.

Moved to `references/full-investigation.md` (persona, scoring run, routing and the `## Complexity` record), read per the Step 1.3e condition. The scoring rubric below stays here: Step 1.3c and Step 2.8 use it on the fast path.

**Scoring rubric.** Each axis that fires adds its **weight**; a total of **3 or more** classifies `complex`, below 3 classifies `simple`. Weak axes weigh 2 (one alone stays `simple`, any two escalate); strong axes weigh 3 (each escalates on its own).

| Axis                | Weight | Fires when                                                                                                                                             |
| ------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Multi-service**   | 2      | Description mentions more than one service, or the affected area is ambiguous (e.g. "payment flow", "attorney assignment", "reporting")                |
| **Cross-layer**     | 2 (3 with the framework-migration marker) | Fix clearly requires both frontend AND backend changes, OR touches Feign clients, PDF generation, async jobs, or framework-version migrations (Spring Boot / Java upgrade) that touch `@Configuration`, security, or bean-wiring classes |
| **Reversibility**   | 3      | Any of: a database schema migration; a destructive or irreversible change to persisted data (backfills, deletions); a change on the payment or billing execution path; a breaking change to a public or externally-consumed API contract (removed endpoint or field, changed response shape); a change to authentication or authorization rules; any change with no revert path, or one needing a coordinated multi-service deploy to revert |
| **Prior rejection** | 3      | Comments contain a previous appraisal that was marked `rejected`, or the ticket description says "tried X, didn't work"                                |
| **Blast radius**    | 3      | Scored later, in Step 2.8 — fires exactly when `get_blast_radius_override` reports `BLAST_OVERRIDE=complex`. Not judged here.                          |

**Reversibility is size-independent.** A three-line `DROP COLUMN` fires it; a 600-line refactor confined to one service with no migration, payment path, public contract change, or auth change does not. When in doubt about a listed trigger, fire it — a false escalation costs one human gate, a false `simple` skips the gate and the delegated investigation both.

**No double-counting.** Migrations and payment-path changes are Reversibility triggers only. A ticket whose only signal is a schema migration fires Reversibility (3) and SHALL NOT also fire Cross-layer on that basis — its score is 3, not 5.

**Framework-migration marker.** When `cross-layer` fires on the framework-version-migration trigger, record it as `cross-layer (framework-migration):3` rather than `cross-layer:2`. This bug class is an *absence* (a missing or misordered `@Configuration` annotation), so there is no graph edge for blast radius to count and a LOW blast-radius result must not be read as a clean bill of health — the weight of 3 is what escalates it, regardless of what Step 2.8 finds.

---

## Step 2.6 — Prior-art search (claude-mem)

> **Fast-path:** Skip this step if fast-path is active. Prior art context is provided by the Planner Context block (Decision, Affected Services, and Target Symbols fields). The `## Prior Art` section in notes.md was already written.

Moved to `references/full-investigation.md`, read per the Step 1.3e condition.

---

## Step 2.7 — Readiness critique

bash ~/.claude/skills/lib/plog.sh APPRAISE critique start "Validating ticket completeness"

Run:

```
/ticket-critique {TICKET-ID} --from-appraise
```

- If the skill reports **BLOCKED** → the ticket is missing required information. Stop here — do not proceed to Step 3. The skill has already posted a comment to Linear and added `needs-info`.
- If the skill reports **WARNINGS** or **CLEAR** → proceed to Step 3 or Step 3-Agent per the complexity decision from Step 2.5.

bash ~/.claude/skills/lib/plog.sh APPRAISE critique done "{BLOCKED|WARNINGS|CLEAR}"

---

## Step 2.8 — Blast Radius Analysis (GitNexus)

bash ~/.claude/skills/lib/plog.sh APPRAISE blast-radius start "Running impact analysis"

Derive target symbols from the ticket title, description, and labels. Extract at minimum: the primary component/module name, any mentioned API endpoints, and any class or file names referenced in the ticket. Use these as targets for `impact()`.

Call `mcp__gitnexus__impact` for each target symbol:
- `target`: the symbol name (function, class, file, or component)
- `direction`: `"upstream"` (what depends on this)
- `maxDepth`: 3

If the symbol is ambiguous (multiple candidates), pick the highest-relevance result and record all candidates.

**Record results in notes.md** under a `## Blast Radius` section:

```markdown
## Blast Radius

| Target | Risk | d=1 (WILL BREAK) | d=2 (LIKELY AFFECTED) | Affected Flows | Edit |
|--------|------|-------------------|------------------------|----------------|------|
| `{symbol}` | LOW/MEDIUM/HIGH/CRITICAL | {count} callers | {count} indirect | {comma-separated flow names, or none} | additive/modifying |

**Analysis:** {one sentence summarizing what the blast radius means for this ticket}
```

**Edit column:** record `additive` only when the planned edit to that target is purely additive — new union members, new `case`/`switch` arms placed before an unchanged `default`, new optional parameters, or new exports — so that no existing caller's inputs or outputs can change. Anything else (changed signature, changed return value, changed branch an existing input already reaches, removed member, reordered arms) is `modifying`. When unsure, write `modifying`.

**Re-evaluate complexity:** the thresholds are applied by bash, not by judgement. Run:

```bash
eval "$(bash -c "source ~/.claude/skills/lib/notes-parse.sh; get_blast_radius_override '{ticket-dir}'")"
```

The thresholds are in `get_blast_radius_override`'s header (`lib/notes-parse.sh`). `BLAST_OVERRIDE=complex` **is** the Step 2.5 **Blast radius** axis (weight 3) firing; do not re-judge it. When it fires, add `blast-radius:3` to `**Axes fired:**`, add 3 to `**Weighted score:**`, and recompute `**Score:**` against the threshold (any score with blast radius fired is ≥ 3, so `complex`). Append `BLAST_REASON` to `**Reason:**`. **Fast-path interaction:** If fast-path set complexity to `simple` (from Conservative strategy), blast radius still runs and can escalate to `complex`. It reads from notes.md and applies regardless of how complexity was originally set; on a fast-path `**Weighted score:** n/a` line, write `3 (threshold 3)`.

```markdown
**Score:** complex (escalated from simple — blast radius: {BLAST_REASON})
**Weighted score:** {N+3} (threshold 3)
**Axes fired:** {existing list}, blast-radius:3
```

**Additive-change exemption (caller-count trigger only):** if `BLAST_ADDITIVE_SKIP` is non-empty, record it in `## Complexity`:

```markdown
**blast-radius:** additive — caller-count override skipped ({BLAST_ADDITIVE_SKIP})
```

**Framework-migration:** no separate override any more. The `cross-layer (framework-migration):3` entry from Step 2.5 already scored `complex` on its own, so a LOW blast-radius result here changes nothing — the `impact()` thresholds are edge counts, and this class of defect has no edge. Such tickets take the Step 3-Agent (delegated) path so the bean-wiring surface is planned adversarially rather than inline.

**Non-blocking fallback:** If the `mcp__gitnexus__impact` tool is unavailable or returns an error, log a warning and proceed:

```bash
bash ~/.claude/skills/lib/plog.sh APPRAISE blast-radius warn "GitNexus unavailable — falling back to manual tracing"
```

Do NOT block the pipeline on GitNexus availability. If blast radius data is unavailable, the Blast radius axis does not fire and the complexity classification from Step 2.5 stands.

bash ~/.claude/skills/lib/plog.sh APPRAISE blast-radius done "Risk: {highest-risk}, d=1: {max-d1-callers}"

---

## Step 3 — Investigate the codebase (inline path — simple tickets only)

> **Fast-path:** Skip this step if fast-path is active, unless `Exploration Depth` is `quick-scan` (Step 1.3c item 5). The Planner Context provides Target Symbols as investigation starting points. The `## Initial Investigation` section in notes.md was already populated. A lightweight pass is still recommended: Grep to confirm each target symbol exists at its listed path, and note any discrepancies in `## Open Questions`. But do NOT run the full multi-tier investigation (3a–3e).

Moved to `references/full-investigation.md` (3a–3f), read per the Step 1.3e condition.

---

## Step 3-Agent — Investigate the codebase (delegated path — complex tickets)

Moved to `references/full-investigation.md` (3-Agent-a and 3-Agent-b), read per the Step 1.3e condition.

---

## Step 3.5 — Verify factual claims and resolve agent-resolvable questions

Runs after both Step 3 and Step 3-Agent — codebase investigation always produces this step's input regardless of which path ran. Nothing here reasons about the ticket itself; it only checks whether things already written in notes.md are actually true.

bash ~/.claude/skills/lib/plog.sh APPRAISE claim-verify start "Verifying negative-existential claims"

### 3.5a — Enforce Open Questions tagging

Read `## Open Questions`. Every bullet must already carry `[needs-human]` or `[agent-resolvable]` (see the tagging rule in Step 2). If any bullet is untagged, tag it now based on its content — do not proceed with an untagged bullet.

### 3.5b — Collect claims to verify

Build one combined list of claims needing independent verification:

1. **Negative existentials** from `## Initial Investigation` and `## Blast Radius` — any claim that something does NOT exist or is NOT referenced. Match patterns like "does not exist", "no ... anywhere", "nothing reads/references/consumes", "there are no", "not referenced", "not found", "no callers". A single grep can confirm presence but never absence, so these are the one claim class where the original author's confidence is structurally unjustified.
2. **`[agent-resolvable]` open questions** — each one is itself a claim to be settled with evidence before it can be closed.

If both are empty, skip straight to 3.5d (nothing to verify) and log `done|0 claims to verify`.

### 3.5c — Spawn the claim-verifier agent

Spawn a read-only `Explore` subagent — no code changes, no branches, no Linear mutations:

```
You are an independent fact-checker. Verify ONLY the claims below — do not evaluate anything else about the ticket, and do not propose fixes.

Ticket: {ISSUE-ID} — {title}
Repos: {REPOS_ROOT}

Claims to verify (each is either a negative existential — something claimed to NOT exist or NOT be referenced — or an open question needing a factual answer):
{numbered list: claim text, plus its original citation if any}

For each claim, run a genuinely BROADER search than a single grep would give the original claim: try multiple spellings/casings, search both {REPOS_ROOT} and any path the ticket itself names, and do NOT narrow with --include filters. Then classify:

- CONFIRMED — your broader search still found nothing (negative existential) or produced a definite answer (open question). State the exact command(s) you ran.
- REFUTED — you found a hit that contradicts the claim. Give the file:line and the exact matching text.
- UNVERIFIABLE — you could not search exhaustively (e.g. repo unavailable, question has no determinate codebase answer). Explain why.

Report one verdict block per claim, in this exact format:
### Claim N: {claim text}
Verdict: CONFIRMED|REFUTED|UNVERIFIABLE
Command: {command(s) run}
Evidence: {output, or file:line and matching text}
```

### 3.5d — Apply verdicts

For each claim verdict, write one log entry:

```bash
bash ~/.claude/skills/lib/plog.sh META claim-verify info "Claim ${N}: ${VERDICT} — ${claim_text}"
```

Then act on it:

- **Negative existential, CONFIRMED** — leave the claim in Initial Investigation/Blast Radius as-is.
- **Negative existential, REFUTED** — correct the claim in place using the agent's evidence, citing the refuting `file:line`. Do not just delete it — a wrong premise that's silently removed can resurface unexamined later.
- **Negative existential, UNVERIFIABLE** — demote it: remove the assertion from Initial Investigation/Blast Radius and add it as a new `- [needs-human]` bullet in Open Questions instead. An unconfirmed negative existential must never stand as fact.
- **`[agent-resolvable]` question, CONFIRMED** — close it now: `- ~~[agent-resolvable] {question}~~ **Resolved:** {answer} ({file:line citation(s) from the agent's evidence})`. A citation is mandatory — a resolution without one is a validation error (see 3.5e).
- **`[agent-resolvable]` question, REFUTED or UNVERIFIABLE** — it cannot be safely self-closed. Re-tag it `[needs-human]` and leave it open; do not strike it through.

### 3.5e — Validation gate

Before continuing to Step 4, re-scan `## Open Questions`:

- Every bullet has a `[needs-human]` or `[agent-resolvable]` tag → if not, this is a hard validation error. Fix it and re-check.
- No `[agent-resolvable]` bullet remains both open (not struck through) — every one was either closed with a citation in 3.5d or re-tagged `[needs-human]`. An open, uncited `[agent-resolvable]` bullet reaching Step 4 is a hard validation error.

If any REFUTED negative existential required a correction, re-run 3.5c against just the corrected text to confirm the fix holds before moving on.

```bash
bash ~/.claude/skills/lib/plog.sh META gate-result "{pass|fail}" "claim-verify: {N} confirmed, {M} refuted, {K} unverifiable"
```

bash ~/.claude/skills/lib/plog.sh APPRAISE claim-verify done "{N} confirmed, {M} refuted, {K} unverifiable"

---

## Step 4 — Update ticket in Linear

When called via `/ticket-auto`, the ticket was already claimed (Backlog → Todo + `claimed`) before the appraise agent spawned. This call is a **corrective idempotent pass** — it ensures the complexity label matches the actual investigation result. When called standalone (not via ticket-auto), this is the initial claim.

Delegate to the flow executor (safe to re-call — `flow.sh` skips if nothing changed):

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" {TICKET-ID} appraise-start --data complexity={simple|complex}
_rc=$?
# flow-run.sh has already logged any non-zero exit (META|flow-error + heartbeat).
# appraise-start carries no verdict_gate, so exit 11 cannot occur; a failure is non-fatal — continue.
```

This sets state → `Todo`, assignee → `me`, and adds `claimed` + the complexity label. If the ticket was already claimed by the router, only the complexity label is corrected (if different from the default `simple`).

---

## Step 5 — Hand off to executor

bash ~/.claude/skills/lib/plog.sh APPRAISE handoff start "Writing final report"

**Pre-handoff completeness gate** — before reporting, verify `notes.md` is ready for the executor (a `## Complexity` Score line, and an `## Initial Investigation` with content beyond the template stub):

```bash
bash ~/.claude/skills/lib/appraise-handoff-check.sh "{ticket-dir}"
```

Exit 1: it logged which section is incomplete. Stop and tell the user; do not run `/ticket-appraise-exec` — it would fail at its own guard with a less specific error.

Tell the user:

```
## {TICKET-ID} — investigation complete

**Complexity:** {simple | complex} (weighted score {N}, threshold 3)
**Axes fired:** {axis:weight list or "none"}

**Key findings:**
{2-4 bullets from Initial Investigation}

**Open questions:**
{bullets or "None"}

notes.md is fully populated. Review it, then run:

/ticket-appraise-exec {TICKET-ID}

This will create the change artifacts and update Linear.
```

bash ~/.claude/skills/lib/plog.sh APPRAISE handoff done "Reported to user"

---

## Resume mode (ticket directory already exists)

If ticket-setup reported workspace already exists in Step 1:

1. Read `context.md` and `notes.md` from the existing directory.
2. Fetch the current state from Linear (`get_issue` + `get_comments`, shared preamble § 2).
3. **Diff comments** — compare Linear's current comments against the Comments section in `context.md`:
   - Count comments in `context.md` (count `**` bold author lines under `## Comments`). If Linear has more, or if any comment body/timestamp differs materially — new activity exists.
   - **If no new comments:** tell the user current status and last session notes. Ask: "Want to continue where you left off, or re-investigate?" Skip the rest of this section.
   - **If new comments found:** continue to step 4.
4. **Present new comments** — show the user what's new (author, timestamp, body excerpt).
5. **Append to notes.md** under a new `### {today's date} — comments update` session log entry:
   ```markdown
   ### {today's date} — comments update
   - New comments from Linear (N since last appraisal):
     - **{author}** ({timestamp}): {body excerpt}
   ```
6. **Re-evaluate complexity** — first load `references/full-investigation.md` as Step 1.3e says (it holds the Step 2.5 procedure), then run Step 2.5 (complexity sweep) again, considering the new comments as additional input. If the score changes, update the `## Complexity` section in notes.md and note the change in the session log.
7. **Check artifact staleness:**
   ```bash
   bash ~/.claude/skills/lib/ticket-dir.sh plan "{TICKET-ID}" --root . --ticket-dir "{ticket-dir}"
   ```
   (The one plan-artifact resolver — whole-ID match, so `TEST-7` never sees `TEST-77`'s change.)
   If it exits 0 (or 2 — several change dirs match), an artifact exists and the plan may be stale. Append to notes.md session log:
   ```
   - ⚠️ Artifacts exist (simple-fix.md / openspec change). New comments may require plan updates.
   ```
8. **Record re-appraisal marker in notes.md.** Append a `## Re-appraisal` section:
   ```markdown
   ## Re-appraisal
   **Date:** {today}
   **Changes detected:** {yes | no}
   **Reason:** {e.g. "N new comments since last appraisal" or "no new activity — nothing to update"}
   ```
   Set `Changes detected: yes` if: new comments found, complexity score changed, or artifacts are stale. Otherwise `no`.

9. **Tell the user:**
   ```
   ## {TICKET-ID} — re-appraisal

   **Changes detected:** {yes | no}
   {If yes: list what changed}

   **Complexity:** {unchanged | changed: {old} → {new}}
   **Artifacts:** {up to date | ⚠️ may be stale — re-run `/ticket-appraise-exec {TICKET-ID}` to regenerate}
   ```

10. Do NOT overwrite `context.md`. The comments section there is a snapshot from initial intake. You may append to `notes.md`.
