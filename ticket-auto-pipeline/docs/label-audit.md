# Tracker label audit

**Audit date:** 2026-09-19
**Taken against commit:** `b888d2fefb74e299096f03bb12bf1a2460816124`
**Source:** `openspec/changes/tracker-label-audit/` (proposal, design, spec, tasks)
**Scope:** every label declared in `ticket-auto-pipeline/skills/ticket-flow/state-machine.json` —
`well_known_labels`, `planner_labels`, and every label named in a trigger's `adds`/`removes`
(placeholders `{complexity}`, `{complexity-opposite}`, `{outcome}` expanded to concrete values).

This file is the durable record required by the `tracker-label-inventory` capability. It classifies
every declared label as `control`, `human-signal`, or `vestigial`, cites the evidence for each
classification, and states saved-view impact. **Removal of any `vestigial` label requires explicit
operator confirmation — see § Operator confirmation gate at the end of this file — and has NOT
happened as of this writing.** This document only records the classification; no label has been
removed from `state-machine.json` yet.

If this file is more than a few months old relative to `state-machine.json`'s current git history,
treat it as possibly stale — re-run the searches below before trusting a classification, per design
R5 (staleness must be visible, not silently trusted).

**Filename note (2026-09-19, tracker-event-vocabulary-and-emitter):** `state-machine.json` was
renamed to `workflow.json` the same day this audit was taken — the `triggers`/`well_known_labels`/
`planner_labels` content this audit describes is unchanged, only the filename differs. Every
`state-machine.json` reference below (including git-log citations) describes evidence gathered under
that filename and is left as written rather than rewritten after the fact; read `state-machine.json`
in this file as `workflow.json` on disk.

## Summary table

| Label | Classification | One-line justification |
|---|---|---|
| `bug` | control | Type label — resolves template + gates `NO_TEMPLATE_FOR_TYPE`/`PLANNED_BODY_INCOMPLETE` for planned tickets (`gate-check.sh`) |
| `feature` | control | Same mechanism as `bug` |
| `improvement` | control | Same mechanism as `bug` |
| `security` | control | Same mechanism as `bug` |
| `chore` | control | Same mechanism as `bug` |
| `planned` | control | Read at 7+ decision sites across appraise, gate, epic-branch, and fleet-dispatch |
| `INIT-*` | control | Filters initiative feedback aggregation (`fleet-feedback.sh`) |
| `blocked-by:*` | control | Gates dispatch and feeds the blocked-by-resolution detector (`fleet-dispatch.sh`, `fleet-detect.sh`) |
| `state:execution` | control | Gates initiative dispatch validation (`fleet-dispatch.sh`) |
| `approved` | control | Read at 4+ gate/detector sites to decide auto-approve, manual override, and stall detection |
| `Smooth` / `Rough` / `Hard` | control | Self-check read for auto-merge eligibility (`outcome-label-check.sh`), per design D4 — redundant with local `META\|outcome-label` but a real decision read |
| `claimed` | **vestigial** | Zero readers repo-wide; fully redundant with visible ticket state + assignee |
| `simple` / `complex` | **vestigial (evidence confirmed, removal deferred)** | Complexity is read from `notes.md` everywhere it matters, never from the label; no human-consumer instruction found — see § Final disposition for why removal is parked |
| `pre-approved` | **human-signal (reserved)** | No current decision read, but `ticket-planner/CLAUDE.md` and `docs/ticket-planner.md` document it as a deliberately-reserved contract label for the dormant `planned-entry-gate` feature — reclassified from vestigial, see § Final disposition |
| `needs-info` | human-signal | Written by `fleetd/gate_hold.py`; explicit human-resolve instruction in `ticket-audit-exec/SKILL.md` and `ticket-appraise/SKILL.md` |
| `needs-adr` | human-signal | Written via ADR gate flow; explicit "how a human triaging the queue finds it" instruction in `skill-preamble-auto.md` |
| `rejected` | human-signal (weaker evidence) | No decision read found; legend documents non-redundant status distinct from ticket state — flagged for operator judgment |
| `reviewed` | human-signal (weaker evidence) | No decision read found; legend gives detailed operator guidance including an explicit anti-pattern warning — flagged for operator judgment |
| `repro-failed` | human-signal (weaker evidence) | Zero writers found anywhere in code — likely a manually-applied human signal; documented meaning is specific, not generic |

**Proposed vestigial list for operator confirmation (as originally classified):** `claimed`,
`simple`, `complex`, `pre-approved`. See § Operator confirmation gate for the confirmation record
and § Final disposition for how this list changed after removal execution surfaced new evidence.

---

## Per-label detail

### `bug`, `feature`, `improvement`, `security`, `chore` — control

- **Writers:** `state-machine.json` `planner_labels` — set by ticket-planner at ticket creation,
  never removed by any trigger.
- **Decision readers:** `ticket-auto-pipeline/lib/gate-check.sh:555` (`_resolve_type_label`, defined
  at `gate-check.sh:730-756`) extracts the Type label from the issue's label set for planned
  tickets, then `ticket-auto-pipeline/lib/template-select.sh:20,32-40` (`resolve_template`) maps it
  to a template file. `gate-check.sh:559-564` emits gate-stop `NO_TEMPLATE_FOR_TYPE` when resolution
  fails; `gate-check.sh:568-575` emits `PLANNED_BODY_INCOMPLETE` based on the resolved type. This
  only fires for `planned`-labeled tickets (Check 2.7), but it is a genuine branch on which Type
  label is present.
- **Saved-view impact:** none known.

### `planned` — control

- **Writers:** ticket-planner at ticket creation (`planner_labels`). Never removed by any trigger
  (`removed_by: []`).
- **Decision readers (file:line):**
  - `ticket-auto-pipeline/lib/gate-check.sh:538` — gates the whole planned-ticket validation branch
    (Check 2.7).
  - `ticket-auto-pipeline/lib/appraise-fast-path.sh:84` — fast-path eligibility gate.
  - `ticket-auto-pipeline/lib/planner-artifacts.sh:45` — resolves the planner artifact directory.
  - `ticket-auto-pipeline/lib/planned-ticket-check.sh:78` and
    `ticket-auto-pipeline/lib/planned-ticket-body-check.sh:78` — same has-planned-label gate,
    independently implemented in each validator.
  - `ticket-auto-pipeline/lib/epic-branch.sh:442-446` — epic readiness only counts children that
    carry `planned` (`epic_branch_children_done`).
  - `fleet-controller/lib/fleet-dispatch.sh:656-658` — dispatch requires `planned` + `Backlog`.
  - `fleet-controller/lib/fleet-detect.sh:1222-1228` — initiative-dispatch-readiness detector uses
    the same `planned` + `Backlog` test.
- **Saved-view impact:** none known.

### `INIT-*` — control

- **Writers:** ticket-planner at ticket creation (`planner_labels`, wildcard pattern). Never removed.
- **Decision readers:** `fleet-controller/lib/fleet-feedback.sh:26` (`_get_initiative_labels`)
  filters an issue's labels by the `INIT-` prefix to attribute pipeline feedback to an initiative —
  this is the input to per-initiative feedback aggregation, a real decision (which initiative a
  result rolls up to).
- **Saved-view impact:** none known.

### `pre-approved` — human-signal (reserved) — reclassified, see § Final disposition

- **Writer:** `ticket-planner/lib/planner-phase-prompts.sh:1343` —
  `[ "$pre_approved" = "true" ] && LABELS=$(echo "$LABELS" | jq -c '. + ["pre-approved"]')`.
  Removed by `human-reject` and `re-claim` triggers.
- **Not a decision read — existence preflight only:** `ticket-planner/lib/planner-doctor.sh:51`
  lists `pre-approved` among 4 "static contract labels" whose *existence on the Linear team* is
  checked before the planner runs (`planner_linear_resolve_label_ids` hard-fails on an unknown
  label name). This never inspects whether a given ticket carries the label — it is a team-config
  preflight, not a per-ticket branch.
- **Every actual decision reads a different field, not this label:**
  - `ticket-auto-pipeline/lib/appraise-fast-path.sh:120-121,125-132` — reads `Pre-approved` out of
    the `## Planner Context` **description text** via `_extract_field_from_block`, not the Linear
    label.
  - `ticket-auto-pipeline/lib/planned-ticket-check.sh:222-227` — same: `_extract_field "Pre-approved"`
    against the description block text.
  - `ticket-planner/lib/planner-ticket-validate.sh:98` — calls into `planned-ticket-check.sh`, same
    description-field source.
  - Confirmed by design doc's own citation and verified directly: the Linear **label** and the
    description's **`Pre-approved:` field** are two separately-written copies of the same boolean
    (both set by `planner-phase-prompts.sh` at ticket creation), and only the description copy is
    ever read to make a decision.
- **Human-consumer search:** searched `ticket-planner/CLAUDE.md`, `ticket-planner/docs/ticket-planner.md`,
  `ticket-planner/README.md`, `ticket-planner/skills/ticket-planner/SKILL.md`,
  `ticket-auto-pipeline/CLAUDE.md`. All mentions are descriptive ("Accelerates fast-path", "Removed
  by human-reject") — none instructs a person to look for or act on the *label* specifically (as
  opposed to the ticket's actual fast-path behavior, which a human observes independently of the
  label chip). No instruction found.
- **Recommendation (superseded — see § Final disposition):** this section originally recommended
  `vestigial` on the strength of "the label is a write-only duplicate of the description field."
  That evidence about *current* reads still holds, but removal execution surfaced documented
  project intent to *reserve* this label for a specified-but-dormant future feature
  (`planned-entry-gate`). The operator has reclassified `pre-approved` as `human-signal (reserved)`.
  No spec delta is needed — the label is not being removed, so `planner-labels` is unaffected.
- **Saved-view impact:** none known. Moot — the label is retained, not removed.

### `blocked-by:*` — control

- **Writers:** ticket-planner at ticket creation (wildcard, e.g. `blocked-by:CRE-100`).
  `state-machine.json` declares `"auto_remove_when": "blocker_reaches_done"`, but **no
  implementation of this auto-removal was found anywhere in the repository** — grepped
  `auto_remove_when` and `blocker_reaches_done` across all five plugins, zero hits outside the JSON
  declaration itself. This is a separate finding from the label's classification (see § Additional
  findings below) — it does not change that the label is actively read.
- **Decision readers:**
  - `fleet-controller/lib/fleet-dispatch.sh:660-679` — extracts `blocked-by:ID` patterns from a
    dispatch candidate's labels and skips dispatch until every named blocker reaches `Done`.
  - `fleet-controller/lib/fleet-detect.sh:1088-1140` (pattern match at `:1122`) — the
    blocked-by-resolution detector re-derives the same blocker-state check to report resolved
    blockers.
- **Additional human value:** names the specific blocking ticket on the card, which the `Blocked`
  Linear state alone does not convey (matches design doc's framing).
- **Saved-view impact:** none known.

### `state:execution` — control

- **Writers:** ticket-planner, epic-only (`precondition: must_be_epic`). Never removed.
- **Decision readers:** `fleet-controller/lib/fleet-dispatch.sh:517-524` — an initiative epic must
  carry `state:execution` before `fleet_dispatch_initiative` will validate and process it; absence
  is a clean early return (not an error), so this is a genuine per-ticket gate, not just an
  existence check.
- **Saved-view impact:** none known.

### `approved` — control

- **Writers:** `human-approve` and `pr-iterate` triggers. Removed by `implement-complete` and
  `re-claim`.
- **Decision readers:**
  - `ticket-auto-pipeline/lib/gate-check.sh:601,621,644,688` — four separate checks (auto-approve
    override for complex+auto/semi-auto, manual-mode override at gate entry, and reapprove-mode
    verification) all branch on this label's presence.
  - `ticket-auto-pipeline/skills/ticket-detect-resume/detect-resume.sh:485` — resume-state detection
    branches on whether `approved` is present.
  - `fleet-controller/lib/fleet-detect.sh:1621` — the stalled-ticket detector requires `approved`
    before flagging a ticket as an automation stall (explicit comment there: "the `approved` label
    is what the state machine actually requires... a child a human moved into [a state] by hand
    ahead of approval... would be misclassified" without this check).
- **Saved-view impact:** none known.

### `Smooth`, `Rough`, `Hard` — control (per design D4, redundant read)

- **Writer:** `implement-outcome` trigger, invoked by `ticket-auto-pipeline/lib/outcome-label-check.sh`.
- **Decision reader:** `ticket-auto-pipeline/lib/outcome-label-check.sh:100-130` —
  `_has_outcome_label` (verified at `:114-118`) re-fetches the issue and checks whether the outcome
  label is already present before deciding whether to apply it; the same script's comment at
  `:127-129` names the confirmed Linear label authoritative for auto-merge eligibility.
- **Finding (per design D4, confirmed):** this is a redundant round trip — `META|outcome-label` is
  already written locally to the pipeline log with the same value at the point the label is applied
  (`outcome-label-check.sh:127`), so the re-fetch-and-check pattern re-derives from Linear a fact
  already known locally. Still classified `control` because a real decision (skip-vs-apply, and
  auto-merge eligibility per the cited comment) depends on it. Replacing this read is explicitly out
  of scope for this change (design D4) — it belongs with the read-failure-policy work.
- **Saved-view impact:** none known.

### `claimed` — vestigial (confirmed)

- **Writer:** `appraise-start` trigger. Removed by `human-approve`, `pr-review-pass-done`, `uat-pass`.
- **Decision readers:** none found. Searched all five plugins for `.labels.nodes`/`label_names`
  patterns (see § Method below) plus whole-word `claimed` across `*.sh`/`*.py` outside tests and
  `state-machine.json` — every hit is an unrelated use of the English word ("claimed the lock" in
  `verify-lock.sh`, "agent's claimed verdict" in `inspect-verifiers.sh`/`phase_dispatch.py`,
  knowledge-curator's unrelated `kc-item.sh` claim/complete/release lifecycle). Zero readers of the
  Linear label itself, confirming the design doc's premise exactly.
- **Human-consumer search:** appears only in `ticket-flow/SKILL.md:55`'s legend
  ("Actively being worked (set at appraisal start, cleared at Done)") — purely descriptive, and
  fully redundant with information already visible via the ticket's Linear *state* (`Todo`) and
  *assignee* field. No instruction to act on it found anywhere.
- **Saved-view impact:** none known.

### `simple`, `complex` — vestigial candidates

- **Writers:** `appraise-start` trigger sets one of the pair; the trigger's `removes` clears the
  opposite.
- **Not a decision read:** `ticket-auto-pipeline/lib/gate-check.sh:97-108` (`_get_complexity`) —
  complexity used by every gate check in this file comes from `get_complexity()`
  (`lib/notes-parse.sh`, reading `notes.md`'s `## Complexity` section), never from the Linear label.
  `ticket-auto-pipeline/skills/ticket-overseer/report.py:178-179,297` (the human-facing dashboard)
  reads complexity the same way — from `notes.md` text, not the label. Grepped all five plugins for
  a decision branch on the literal `simple`/`complex` label value: none found (both words are also
  common English, so most hits were unrelated code/prose, correctly excluded).
- **Human-consumer search:** `ticket-flow/SKILL.md:59-60` legend entries ("Predicted
  simple/complex (set by appraise)") are purely descriptive and duplicate information the operator
  dashboard (`ticket-overseer`) already surfaces from `notes.md` — the actually-consulted source.
  No instruction to act on the *label* found; the same redundancy argument that confirmed `claimed`
  vestigial applies here.
- **Recommendation:** vestigial — flagged as a *candidate* since the design doc left this an open
  question rather than a confirmed finding; the evidence here resolves it, but the operator should
  confirm.
- **Saved-view impact:** none known.

### `rejected` — human-signal (weaker evidence — flagged for operator judgment)

- **Writers:** `pr-review-fail`, `uat-fail`. Removed by `human-approve`, `pr-review-pass-done`,
  `pr-review-pass-uat`, `pr-iterate`.
- **Decision readers:** none found. Grepped whole-word `rejected` across all five plugins outside
  tests/state-machine.json — every hit is unrelated (ADR status enum in `adr-check.sh`, Slack
  transport-failure strings in `fleet-notify.sh`, planner consensus-log prose, knowledge-curator
  test names).
- **Human-consumer search:** `ticket-flow/SKILL.md:57` — "PR review found gaps OR UAT verification
  failed — ticket needs rework." Unlike `claimed`, this is **not** redundant with visible ticket
  state: a ticket bounced back to `Ready` (via `uat-fail`) or sitting in `Review` after
  `pr-review-fail` (no state change) looks identical, on state alone, to a ticket that has never
  been reviewed — the label is the only board-visible signal distinguishing "this was already
  rejected once" from "fresh." That is closer to `needs-info`'s affordance than to `claimed`'s.
- **Why "weaker evidence" rather than a clean human-signal:** no operator doc contains an imperative
  instruction ("resolve this", "a human acts on this") the way `needs-info`/`needs-adr` do — the
  evidence here is a legend entry plus an inference about board legibility, not a documented
  workflow step. Recorded as human-signal on the strength of that legibility argument, but the
  operator should weigh in rather than treat this as settled.
- **Saved-view impact:** none known.

### `reviewed` — human-signal (weaker evidence — flagged for operator judgment)

- **Writers:** `pr-review-pass-done`, `pr-review-pass-uat`. Removed by `pr-iterate`, `uat-pass`,
  `uat-fail`.
- **Decision readers:** none found (same grep sweep as `rejected`; the few whole-word hits — persona
  `last-reviewed` field, `wiki-check.sh`'s `human-reviewed` frontmatter enum value — are unrelated).
- **Human-consumer search:** `ticket-flow/SKILL.md:58` gives unusually detailed operator guidance:
  "PR review passed. Under `per-ticket` UAT policy this means 'awaiting QA'... **Under `UAT Policy:
  epic` it does not mean that** — the child goes straight to `Done` and retains the label... Do not
  key an 'in flight' heuristic on it." This is a documented anti-pattern warning, which is stronger
  signal of real operator-facing significance than a plain glossary line, but it reads as guidance
  to whoever *builds* a future heuristic/detector, not a standing instruction to a human triaging
  tickets day to day.
- **Why "weaker evidence":** same caveat as `rejected` — no imperative "a person does X" instruction,
  just a documented meaning plus a warning against misuse. Flagged for operator judgment.
- **Saved-view impact:** none known.

### `needs-info` — human-signal (confirmed)

- **Writer:** `fleetd/gate_hold.py:490-492` — applies the label via
  `bash flow.sh {tid} needs-info` as part of the human-hold comment-and-label sequence. Also
  reachable via `/ticket-flow {TICKET-ID} needs-info` from `ticket-critique` (per
  `ticket-critique/SKILL.md:394-397`).
- **Human consumer (file:line):**
  - `ticket-auto-pipeline/skills/ticket-audit-exec/SKILL.md:11` — "Human resolves flagged tickets
    before run 2," and again at `:192,304`: "Resolve needs-info tickets, then re-run
    ticket-audit-exec for structural phase."
  - `ticket-auto-pipeline/skills/ticket-appraise/SKILL.md:362` — instructs the agent itself to stop
    and not proceed once `needs-info` has been applied, i.e. the pipeline treats this as a genuine
    park-for-a-human state.
- **Citation correction:** the openspec proposal/tasks cite
  `skills/ticket-appraise-exec/SKILL.md:751-753` as the human instruction for `needs-info`. That
  range currently documents the `[needs-human]`-tagged Open Questions warning about the **`approved`**
  label, not `needs-info` — a different (also human-signal-relevant, but unrelated) mechanism. The
  citation above (`ticket-audit-exec/SKILL.md` and `ticket-appraise/SKILL.md:362`) is the verified
  evidence; the classification itself is unaffected.
- **Saved-view impact:** none known.

### `needs-adr` — human-signal (confirmed)

- **Writer:** applied via `/ticket-flow {TICKET-ID} needs-adr`, invoked by the ADR gate flow per
  `ticket-auto-pipeline/lib/skill-preamble-auto.md:326-333` on `CREATED_PROPOSED`,
  `SUPERSEDE_REQUIRED`, and `CONFLICT` verdicts. Cross-referenced in
  `ticket-auto-pipeline/docs/adr-gate-schema.md:123-131`.
- **Human consumer:** `ticket-auto-pipeline/lib/skill-preamble-auto.md:326-327` — "Also apply the
  label: `/ticket-flow {TICKET-ID} needs-adr`... the label is still how a human triaging the queue
  finds it." This is an explicit statement that the label exists for a human to find flagged
  tickets, distinct from the `HUMAN_HOLD` mechanism that also fires alongside it.
- **Citation refinement:** the proposal cites `lib/skill-preamble-auto.md:344-356`; that range is the
  bash snippet showing the `/ticket-flow` invocation and its error-handling wrapper, not the
  human-instruction prose itself. The actual human-consumer sentence is two paragraphs earlier, at
  `:326-327` (quoted above). Classification is unaffected — same file, same mechanism, more precise
  line.
- **Saved-view impact:** none known.

### `repro-failed` — human-signal (weaker evidence — flagged for operator judgment)

- **Writers:** **none found anywhere in the repository.** `repro-failed` is declared in
  `well_known_labels` but does not appear in any trigger's `adds`/`removes`, and no lib/skill file
  applies it via `flow.sh`, `update_issue`, or any other write path. `ticket-reproduce/SKILL.md`
  (the skill whose name suggests it would apply this label) only posts a comment
  (`save_comment`) — it never touches this label. This is a genuine anomaly: a declared label with
  zero automated writers, meaning it can only ever appear on a ticket via manual application in the
  Linear UI.
- **Decision readers:** none found.
- **Human-consumer search:** `ticket-flow/SKILL.md:67` — "Bug could not be reproduced." Specific,
  non-generic meaning. Given it has zero code writers, if it is used at all it is used exclusively
  by a human manually tagging a ticket for other humans — which is the purest form of human-signal,
  but there is no positive evidence (comment, doc instruction, or usage record) that anyone actually
  does this.
- **Why "weaker evidence":** the search found a documented *meaning* but no documented *usage* or
  *instruction to act*. Unlike `pre-approved`/`simple`/`complex`, there is no redundant alternate
  source proving the underlying fact is tracked elsewhere — if a human doesn't use this label, the
  "could not reproduce" signal genuinely has no record anywhere. That asymmetry (per design D2,
  burden of proof sits on removal) argues for retaining it as human-signal rather than reclassifying
  vestigial on an absence-of-evidence basis alone. Flagged for operator judgment regardless, since
  the operator is in the best position to say whether anyone has ever actually applied it.
- **Saved-view impact:** none known.

---

## Additional findings (outside this audit's classification scope, recorded for later work)

1. **`planner_labels` entry count discrepancy.** The proposal and design docs both state
   `planner_labels` has "11 entries." The actual `state-machine.json` (verified at commit
   `b888d2fefb74e299096f03bb12bf1a2460816124`) has 10 keys: `planned`, `INIT-*`, `pre-approved`,
   `blocked-by:*`, `state:execution`, `bug`, `feature`, `improvement`, `security`, `chore`. This
   does not affect the audit's completeness (all 10 are covered above) but the planning documents'
   count is off by one.

2. **`validate-linear-config.sh`'s expected-label set is narrower than the full declared set.**
   The script (`ticket-auto-pipeline/skills/ticket-flow/validate-linear-config.sh:40-48`) derives
   its expected labels from `well_known_labels` plus every trigger's `adds`/`removes`
   (placeholder-expanded) — 15 labels total: `claimed`, `simple`, `complex`, `approved`, `rejected`,
   `pre-approved`, `Smooth`, `Rough`, `Hard`, `reviewed`, `needs-info`, `needs-adr`, `bug`,
   `feature`, `repro-failed`. It does **not** include 7 labels that are declared in `planner_labels`
   but never appear in a trigger's `adds`/`removes`: `planned`, `INIT-*`, `blocked-by:*`,
   `state:execution`, `improvement`, `security`, `chore`. The validator will not report a missing
   Linear label for any of these 7 even though code depends on several of them
   (`planned`, `blocked-by:*`, `state:execution` are all `control`). This is a real gap in the
   validator, not an audit-enumeration miss (task 1.2's cross-check surfaced it) — worth fixing
   separately (would extend task 6.2's scope, or a standalone follow-up), but out of scope for this
   change per the design's non-goal "no read site is modified." Also note: `INIT-*` and
   `blocked-by:*` are wildcard patterns, not literal label names — a naive fix that just adds them
   to the expected-label list would look for a literal Linear label named `INIT-*`, which cannot
   exist. Any fix needs wildcard-aware handling, not a straight list append.

3. **`blocked-by:*`'s declared `auto_remove_when: blocker_reaches_done` has no implementation.**
   Grepped `auto_remove_when` and `blocker_reaches_done` across all five plugins — zero hits outside
   the JSON declaration itself. The label is removed only if something explicitly calls
   `flow.sh <TID> <trigger>` with it in `removes`, and no trigger currently removes it. This does
   not change the label's `control` classification (it is still read to gate dispatch), but the
   declared auto-removal behavior appears to be aspirational/unimplemented — worth a separate ticket
   if the auto-removal is actually wanted.

4. **An undeclared-but-load-bearing label exists outside this audit's scope.**
   `ticket-auto-pipeline/lib/epic-precondition.sh:14` defines `EPIC_MARKER_LABEL="${EPIC_MARKER_LABEL:-epic}"`
   — the literal string `"epic"` is a `control` label (it's the primary epic/non-epic discriminator
   for every `must_be_epic`/`must_not_be_epic` precondition check in `flow.sh`), but it is **not**
   declared anywhere in `state-machine.json` (`well_known_labels`, `planner_labels`, or any trigger).
   This audit's scope (per tasks.md 1.1) is limited to labels declared in the state machine, so
   `epic` is out of scope for classification here, but it is real, load-bearing, and completely
   undocumented in the label declarations. Worth surfacing for whoever does the later local-state
   migration design (design D3 — this file is meant to be that work's input) since it's a label the
   state machine doesn't even know it depends on.

## Method

- Enumerated labels by reading `state-machine.json` in full and expanding placeholders the same way
  `validate-linear-config.sh:40-48` does (verified by reading that script's `sed` expansion).
- Found candidate writer/reader files via
  `grep -rln -iE '\.labels(\.nodes)?|label_names|has_label|labelIds|addLabelIds|removeLabelIds'`
  across all `*.sh`/`*.py` files in `ticket-auto-pipeline/`, `ticket-planner/`, `fleet-controller/`,
  `knowledge-curator/`, `grill-me/`, excluding `tests/` — 20 files matched, all read in full at the
  relevant sections.
- For labels with no decision read, searched `skills/*/SKILL.md` prose, `lib/skill-preamble*.md`,
  plugin `README.md`/`CLAUDE.md` files, and `ticket-flow/SKILL.md`'s label legend
  (`grep -rn "<label>"` scoped to `.md` files, reviewed manually for actual instructional content vs.
  incidental mention).
- For generic-English-word labels (`simple`, `complex`, `bug`, `feature`, `security`, `chore`,
  `claimed`, `rejected`, `reviewed`), whole-word/quoted greps returned substantial noise from
  unrelated code and prose; every hit was read in context and excluded unless it was an actual
  Linear-label read.
- No Linear saved-view or filter data is available to this audit — every "saved-view impact: none
  known" line reflects absence of information, not a confirmed absence of dependency, per design R2
  (accepted residual risk).

## Operator confirmation gate

**Proposed vestigial list:** `claimed`, `simple`, `complex`, `pre-approved`.

**Weaker-evidence human-signal list, included for awareness (not proposed for removal, but the
evidence for retaining them is thinner than `needs-info`/`needs-adr`):** `rejected`, `reviewed`,
`repro-failed`.

No known saved Linear view or filter dependency was found for any of the above (no such data was
available to search). Per spec ("Removals are confirmed against existing saved views") and design
R1/R2, **no label should stop being written until the operator confirms this list and any
reclassification is recorded below.**

- [x] Operator confirms the vestigial list above (or reclassifies specific labels)
- [x] Any reclassification recorded here with the operator's reasoning
- [x] Only then does task 6 (removal) proceed, one label per commit

## Operator confirmation record (2026-09-19)

The operator confirmed removal of all four proposed vestigial labels — `claimed`, `simple`,
`complex`, `pre-approved` — as classified above, with no reclassification.

The weaker-evidence human-signal group (`rejected`, `reviewed`, `repro-failed`) was explicitly
**not** decided in this pass. The operator asked for further investigation before ruling on those
three, rather than accepting the fork's classification or folding them into the removal list.
They remain `human-signal` (retained, written as before) pending that follow-up — this document
does not yet reflect a settled answer for them.

Removal execution status:
- `claimed` — removed. See commit history for `state-machine.json`, `SKILL.md`, and
  `skills/ticket-flow/tests/phase1.sh`.
- `simple` / `complex` — **paused, not removed.** See § Removal complications below.
- `pre-approved` — **paused, not removed — classification itself is now in question.** See
  § Removal complications below. This is not a mechanical-risk pause like the complexity pair;
  new evidence surfaced during removal that the `vestigial` classification may be wrong.

## Removal complications (found during execution, 2026-09-19)

Two of the four confirmed labels hit complications serious enough to stop on, per the
executing agent's guardrail to pause per-label rather than force a risky change through. Neither
`state-machine.json` nor any other file was modified for these two labels — only `claimed` was
actually removed in this pass.

### `pre-approved` — the vestigial classification is contradicted by documented project decisions

The audit's classification (no decision read → vestigial) only checked whether the label is
*currently* read. It did not check whether the label is *reserved* for documented future use —
and it is.

- `ticket-planner/CLAUDE.md` states as a Key Design Decision: **"`planned-entry-gate` stays
  dormant by decision. Specified but deliberately unimplemented. Confidence ≥ 0.85 + `pre-approved`
  would bypass human approval gate. Revisit only after: ≥ 10 completed initiatives with real
  feedback data, drift consistently ≤ 0.10 at confidence ≥ 0.85, zero incidents from auto-approved
  tickets, and explicit operator opt-in."**
- `ticket-planner/docs/ticket-planner.md:470-487` (§ Planned-Entry Gate Dormancy) confirms this in
  detail: the capability "is specified in `ticket-planner-enrichment` but deliberately
  unimplemented," lists three reasons it stays dormant (independent dispatch/approval controls,
  real cost per ticket, unproven confidence calibration) and four concrete conditions that would
  reopen it. It closes with: **"The capability is left specified rather than removed so the design
  rationale is preserved. Removing it would invite someone to re-specify it without understanding
  why it was deferred."**
- `ticket-planner/CLAUDE.md`'s plugin-purpose section additionally states the planner "Produces
  against frozen consumption-side contracts: Planner Context block schema, `planned`/`pre-approved`/
  `Type` labels, artifact plane, and feedback aggregation. Does not re-specify them" — `pre-approved`
  is named explicitly as one of these frozen contract labels.
- `planner-linear-api.sh`'s doc comment (quoted in `ticket-planner/CLAUDE.md`) calls `pre-approved`
  one of "the 4 static contract labels ... which are assumed pre-existing," and
  `planner-doctor.sh:51`'s `_PLANNER_DOCTOR_STATIC_LABELS` preflight-checks that it exists on the
  Linear team, independent of whether any ticket currently carries it.

This does not mean `pre-approved` is secretly `control` today — the audit's original finding that
no code branches on the *label itself* (only on the description's `Pre-approved:` field) still
holds. But `vestigial` requires positive evidence that *no consumer* exists, and there is
affirmative, explicit, written project intent to consume this exact label later, once specific
measurable conditions are met. That is the opposite of the "zero readers, fully redundant"
evidence that confirmed `claimed`. The three-way `control`/`human-signal`/`vestigial` taxonomy has
no category for "reserved for a specified-but-dormant future feature" — this is a real gap the
classification rule didn't anticipate, not a judgment call within it.

**Recommendation:** do not remove `pre-approved`. Its write path
(`planner-phase-prompts.sh:1343`) and existence preflight (`planner-doctor.sh:51`) should stay
exactly as-is until `planned-entry-gate` is either implemented or the ticket-planner team
explicitly retires that specification. The operator should be aware this reverses this document's
own earlier recommendation — the earlier evidence wasn't wrong, it was incomplete.

### `simple` / `complex` — removal is not a JSON-only change

Unlike `claimed`, `pre-approved`, these two labels are entangled with real, tested logic in
`flow.sh` beyond `state-machine.json`'s declarations:

- `flow.sh:139-151` computes `COMPLEXITY_OPPOSITE` and documents (in its own comment) a real
  historical bug: "Simple and Complex are members of a mutually-exclusive Linear label group, so a
  stale label left behind by an abandoned appraisal session makes the whole mutation fail" — this
  is the fix for issue #170. Removing the labels makes this whole mechanism dead code, not just an
  unused JSON entry.
- `skills/ticket-flow/tests/phase1.sh` has three tests
  (`test_flow_appraise_start_drops_stale_opposite_label`,
  `test_flow_appraise_start_drops_stale_complex_label`,
  `test_flow_appraise_start_no_prior_complexity_label`) that exist specifically to pin that #170
  fix. Per design R4 these would need to be deleted (not adapted) once the labels are gone — but
  that means deleting the only regression coverage for a real, previously-shipped bug, which is a
  bigger and different decision than deleting a test that merely asserted a vestigial label was
  written.
- Every other `simple`/`complex` string match found in the test suite (`test-notes-parse.sh`,
  `test-gate-check.sh`, `test-gate-no-template.sh`, `test-pipeline-phases.sh`,
  `test-appraise-fast-path.sh`) is testing the **complexity value** mechanism (`notes.md` /
  `get_complexity()` / `lib/notes-parse.sh`), which is completely separate from the Linear label
  and is explicitly staying (per this change's non-goals). Those are not in scope and were not
  touched.

**Recommendation:** removing `simple`/`complex` is still justified by the evidence (the label
itself has no reader — only the complexity *value*, sourced from `notes.md`, does) but should be
done as a deliberate follow-up that explicitly also removes `flow.sh`'s now-dead
`COMPLEXITY_OPPOSITE` mutual-exclusion logic and the three `phase1.sh` tests that pin it, with that
tradeoff (losing #170's regression coverage) called out to the operator at that time — not folded
silently into a JSON-only removal commit.

## Follow-up investigation: rejected / reviewed / repro-failed (2026-09-19)

Requested by the operator after the initial pass classified these three `human-signal` on
thin evidence (a legend mention, no imperative instruction). This section extends, not replaces,
their rows above. Searched: full git history of `state-machine.json` (`git log --all -p`) for
context behind each label's original addition; full-text reads (not grep) of
`ticket-pr-review/SKILL.md`, `ticket-pr-iterate/SKILL.md`, `ticket-verify/SKILL.md`,
`ticket-retro/SKILL.md`, `ticket-critique/SKILL.md`, `ticket-reproduce/SKILL.md`; a second grep
pass for alternate label-array read syntax (`contains([...])`, `index(...)`, `label_names[] ==`)
across all five plugins; `dashboard.py` and `ticket-overseer`'s report script for board-rendering
reads; and whether any trigger's `from` condition or `flow.sh`/`epic-precondition.sh`'s
precondition mechanism gates on these three labels' presence (it doesn't — preconditions only
ever test the `epic` marker label).

**`rejected` — human-signal, confirmed (evidence upgraded).** No decision read found anywhere
(a repeat grep including alternate jq syntax turned up nothing; every whole-word hit outside
state-machine.json/tests is unrelated — ADR status enum, Slack transport-failure strings, planner
consensus prose). Git history shows the label's write sites have always been `pr-review-fail`
and `uat-fail`, never the `human-reject` trigger (a coincidentally-identical description string,
"Human rejected the plan," belongs to `human-reject`, which has never added or removed the
`rejected` *label* — it only ever cleared it, alongside `claimed`, when returning a ticket to
`Todo`, and today doesn't touch it at all). The strongest citation is the board-legibility
argument already on record: a ticket sitting in `Review` after `pr-review-fail` (no state change)
is indistinguishable, by state alone, from a ticket never yet reviewed — `rejected` is the only
board-visible signal carrying that distinction, which is a real operator affordance even without
an imperative instruction. Verdict unchanged (`human-signal`) but no longer "weaker evidence" —
treat as confirmed on the strength of this citation.

**`reviewed` — human-signal, confirmed (evidence upgraded).** Same result: no decision read
(repeat grep clean), and `ticket-pr-review/SKILL.md:377` confirms the label is applied only as a
write action ("This adds `reviewed` or `rejected`... only when `_rc` is `0`") — never read back
by that skill or any other to branch on. The existing citation
(`ticket-flow/SKILL.md:58`'s explicit anti-pattern warning: "Under `UAT Policy: epic` [`reviewed`]
does not mean [awaiting QA]... Do not key an 'in flight' heuristic on it") is a genuine documented
warning aimed at whoever builds future tooling, which is stronger than an incidental mention.
Verdict unchanged (`human-signal`), evidence upgraded from "weaker" to confirmed.

**`repro-failed` — human-signal, but genuinely the weakest case; still no positive usage
evidence found.** Confirmed again: zero writers anywhere in the repository (including
`ticket-reproduce/SKILL.md`, whose name suggests it would apply this label — it only posts a
comment via `save_comment`, never touches the label). No decision read. No dashboard or overseer
report renders it. The only citation is the one-line legend definition
(`ticket-flow/SKILL.md:67`, "Bug could not be reproduced") — the harder search (git history,
broader skill-prose reads, dashboard/report code) found nothing beyond that same line. This
differs from `rejected`/`reviewed` in kind: those two have an automated writer and a documented
reason a human needs the distinction; `repro-failed` has no automated writer at all, meaning its
only possible use is a human manually applying it in the Linear UI, and there is no evidence
(comment convention, doc instruction, board process) that anyone does. The evidence for
`human-signal` here rests entirely on "the label has a defined meaning a human could act on,"
not on any trace of actual use. Recorded as `human-signal` per the design's asymmetric
burden-of-proof rule (D2) — a definition with no disproving evidence doesn't clear the bar for
`vestigial` either — but this is the one of the three where the operator's own judgment matters
most: nothing further exists to search.

**Net effect on the operator confirmation gate:** the proposed vestigial list is unchanged
(`claimed`, `simple`, `complex`, `pre-approved`). `rejected` and `reviewed` should be read as
settled `human-signal` retentions. `repro-failed` remains a `human-signal` retention by the
letter of the classification rule, but the operator may reasonably decide differently — the
evidence is exhausted, not just thin.

## Final disposition (2026-09-19, after removal execution)

Removal execution (task 6) surfaced evidence the original audit pass didn't have, on two of the
four confirmed labels. The operator reviewed the § Removal complications findings above and
decided, per label:

- **`claimed` — removed.** No new evidence; the original `vestigial` finding (zero readers
  repo-wide) stood unchallenged. Shipped in commit `a2314c4`.
- **`pre-approved` — reclassified `human-signal (reserved)`, retained.** The audit's original
  `vestigial` finding was correct about *current* reads (no code branches on the label itself,
  only on the description's `Pre-approved:` field) but incomplete: it never checked for
  documented *future* intent. `ticket-planner/CLAUDE.md` and `docs/ticket-planner.md` state, in
  writing, that this label is deliberately reserved for the specified-but-dormant
  `planned-entry-gate` feature, with explicit numeric revisit criteria. That is affirmative
  evidence of a consumer (the planner team's own documented design), which the `vestigial`
  bar (design D2: positive evidence of *no* consumer) cannot survive. The label's write path
  (`planner-phase-prompts.sh:1343`) and existence preflight (`planner-doctor.sh:51`) are
  untouched. No `planner-labels` spec delta is needed, since nothing is being removed.
- **`simple` / `complex` — evidence stands, removal deferred as separate follow-up work.** The
  operator agreed the labels themselves are vestigial (complexity is read from `notes.md`
  everywhere it matters) but chose not to fold the removal into this change, because it is
  entangled with `flow.sh`'s issue #170 stale-opposite-label fix and the three `phase1.sh`
  regression tests pinning it — deleting those tests to remove a label is a materially different
  decision than a JSON-only removal, and deserves its own review rather than being decided as a
  side effect of this audit. **This is not a rejection of the classification — `docs/label-audit.md`
  continues to record `simple`/`complex` as vestigial** — it is a deferral of the removal
  mechanics to a later, explicitly-scoped change. Both labels continue to be written exactly as
  before until that follow-up happens.

**Updated proposed-for-removal-but-not-yet-removed list:** `simple`, `complex` (follow-up work,
not part of this change's execution). **Confirmed removed:** `claimed`. **Confirmed retained
(reclassified):** `pre-approved`.

## Re-audit addendum (2026-09-23, `tracker-local-facts-write-migration` / Track B Phase B3b)

Triggered by `tracker-local-facts-read-migration` (B3a, PR #397, merged 2026-09-23), which
relocated every decision read this file cited as `control` evidence for six labels — `planned`,
`blocked-by:*`, `state:execution`, the five type labels, `Smooth`/`Rough`/`Hard` — onto a local
per-ticket/per-epic manifest. Per this file's own preamble ("re-run the searches below before
trusting a classification") and the `tracker-label-inventory` capability's new requirement ("a
relocated read triggers reclassification, not just a write-side note"), this addendum re-runs the
code-reader and documented-consumer searches for exactly those six labels. `approved`, `INIT-*`,
`needs-info`, `needs-adr`, `rejected`, `reviewed`, `repro-failed` are untouched by B3a and are not
re-examined here.

**Method:** re-read every site B3a's own commit cites as a migrated call site (`gate-check.sh`,
`appraise-fast-path.sh`, `planner-artifacts.sh`, `planned-ticket-check.sh`,
`planned-ticket-body-check.sh`, `epic-branch.sh`, `fleet-controller/lib/fleet-dispatch.sh`,
`fleet-controller/lib/fleet-detect.sh`, `outcome-label-check.sh`, `fleetd/phase_dispatch.py`,
`lib/run-identity.sh`) in full, in their current on-disk state, plus a fresh `grep` for
`.labels.nodes`/`label_names` across the same five plugins to catch any reader outside that list.
Documented-consumer search repeated `grep -rn` for each label's exact string across every plugin
`CLAUDE.md`, `README.md`, `docs/*.md`, `skills/*/SKILL.md`, and `next.md`/`CHANGELOG.md`, reading
every hit in context (same method as the original audit and the `rejected`/`reviewed`/
`repro-failed` follow-up).

**Finding, all six labels: B3a is not the read-removal B3b's proposal anticipated it might be —
it is a read-migration with a deliberate, still-live fallback, and that fallback is itself a
`control`-qualifying read.** Every migrated call site follows the identical shape: check whether a
local manifest exists for this ticket/epic; if so, read the manifest field; **if not, fall back to
the exact pre-B3a live label read, unchanged.** This is B3a's own explicitly stated design (design.md:
"keeping every label write unchanged as an explicit rollback net... any reverted call site falls
back to exactly its pre-B3a behavior") — the fallback branch was never dead code to begin with, it
is the mechanism that makes B3a revertible. A live label read that only fires when a manifest is
absent (predates the migration, write failed, `REPOS_ROOT` unset, `TICKET_LOCAL_MANIFEST_DISABLE`)
is still a real decision read: the pipeline's routing/gating behavior for that ticket depends on
the label's presence in exactly those cases. Confirmed per label:

- **`planned`** — live fallback read confirmed unchanged (label-gated on `ticket_manifest_exists`)
  at `gate-check.sh:622` (Check 2.7 gate entry), `appraise-fast-path.sh:95-99` (fast-path
  eligibility), `planner-artifacts.sh:52-63` (`resolve_planner_dir`), `planned-ticket-check.sh:93-97`,
  `planned-ticket-body-check.sh:80-84`, and `epic-branch.sh:511-515` (`epic_branch_children_done`'s
  live-query branch, which additionally filters children by the label unconditionally within that
  branch — not manifest-gated at all, since it only runs when no epic manifest exists),
  `fleet-dispatch.sh:701-705,796-802` (per-child live fallback when no child manifest exists).
  Documented-consumer search found only architectural/mechanism prose (`CLAUDE.md`,
  `ticket-planner/CLAUDE.md`, `ticket-planner/docs/ticket-planner.md`,
  `fleet-controller/CLAUDE.md`/`README.md`, `ticket-appraise/SKILL.md`) — no instruction to a human
  to look for this label in the Linear UI, same as the original pass. Moot regardless: the live
  fallback reader alone is sufficient `control` evidence. **Reconfirmed `control`** — classification
  basis narrows from "primary decision read" to "fallback decision read used whenever no local
  manifest exists," not a change in kind.
- **`blocked-by:*`** — live fallback confirmed at `fleet-dispatch.sh:693-705` (per-child dispatch
  eligibility, no child manifest) and `fleet-detect.sh:1187-1210` (`detect_blocked_by`'s live-query
  branch, no ticket manifest). Same doc-mention shape as `planned` (dependency-mechanism
  documentation in `ticket-planner/CLAUDE.md`, `ticket-planner/docs/ticket-planner.md`,
  `fleet-controller/CLAUDE.md`/`README.md`), no imperative human instruction found. Design's own
  Risk ("removing this label removes the last Linear-UI-visible trace of a dispatch block") is
  accepted as a live trade-off, not evidence of a documented consumer relying on it today.
  **Reconfirmed `control`**, same basis narrowing as `planned`.
- **`state:execution`** — live fallback confirmed at `fleet-dispatch.sh:530-557` (epic validation,
  no epic manifest) and `fleet-detect.sh:1364-1416,1555,1732-1772` (three separate detector call
  sites' live-query branches, no epic manifests found under `REPOS_ROOT`). Doc mentions
  (`ticket-planner/docs/ticket-planner.md`, `ticket-planner/plugin-overview.md`,
  `fleet-controller/README.md`/`CLAUDE.md`) are all pipeline-mechanism descriptions of when the
  label is set and what it gates, not operator-facing instructions. **Reconfirmed `control`**, same
  basis narrowing.
- **Type labels (`bug`/`feature`/`improvement`/`security`/`chore`)** — live fallback confirmed at
  `gate-check.sh:642-645` (`ticket_type` resolution for Check 2.7b's `NO_TEMPLATE_FOR_TYPE` gate,
  falls back to `_resolve_type_label` at `gate-check.sh:730-756`) and
  `fleetd/phase_dispatch.py:1685-1738` (`resolve_ticket_type`, manifest-first via
  `_resolve_ticket_type_from_manifest`, falls back to a live `get_issue` + label-set read).
  `run-identity.sh:229-260`'s type field is manifest-first too, but that write
  (`META|ticket-meta`) is informational/telemetry, not a decision — consistent with the original
  audit's classification boundary, this site was never counted as `control` evidence and its
  fallback shape doesn't change that. No new documented-consumer evidence beyond the original
  pass's saved-view-triage framing (still unconfirmed, no saved-view data available).
  **Reconfirmed `control`** for all five, same basis narrowing.
- **`Smooth`/`Rough`/`Hard`** — **not actually invalidated at all.** `outcome-label-check.sh`'s own
  in-file comment (`lib/outcome-label-check.sh:153-158`, added by the same B3a migration) states
  explicitly: "Deliberately does NOT touch `_has_outcome_label`'s live Linear read above... migrating
  it to the manifest would make it verify against the *write this function itself just performed*
  instead of independently confirming the mutation landed" — `_has_outcome_label`
  (`outcome-label-check.sh:73-83`) is unchanged, unconditional, and still the sole implementation.
  B3a only added a write-side mirror to the manifest (`_mirror_outcome_to_manifest`,
  `outcome-label-check.sh:158-161`) — a genuinely separate concern from this label's read path. The
  premise that motivated re-auditing this label (a control-evidencing read relocated to local
  state) did not occur. **Reconfirmed `control`, evidence unchanged from the 2026-09-19 pass** —
  this is the one of the six where "re-audit" found literally nothing to reconsider.

**Saved-view impact:** no new data available for any of the six, same constraint as the original
audit and its follow-up pass.

**Net effect on the operator confirmation gate: no proposed-vestigial list.** All six labels are
reconfirmed `control` on the strength of a still-live fallback decision read (five of six) or an
entirely untouched decision read (`Smooth`/`Rough`/`Hard`) — not on documented-consumer evidence,
which was searched but is redundant once a code reader exists. Per this file's own governing rule
("A label SHALL NOT stop being written unless it is classified `vestigial`"), none of the six
qualifies, so **no operator confirmation is required and no write removal proceeds** — this is the
"re-audit finds genuine consumers for all six, making this phase a no-op on the write side" outcome
the change's own design.md named as an accepted, correct possibility (§ Risks / Trade-offs), not a
partial or deferred result. `planner_linear_create_issue`, `planner_linear_ensure_label`,
`planner_dispatch_gate`, and `outcome-label-check.sh`'s write paths are unchanged. `workflow.json`'s
label declarations, `planner_verify_tickets`'s assertion, and `manifest-read.sh`'s live-fetch
fallbacks are unchanged — the last of these specifically because a fallback exists precisely
*because* the live read (and therefore the write) is confirmed still load-bearing for all six
fields, the opposite of the condition that would have required removing it.
