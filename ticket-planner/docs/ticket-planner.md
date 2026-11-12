# Ticket Planner — Architecture and Reference

The ticket-planner is the autonomous planning layer that sits upstream of `ticket-auto` and `fleet-controller`. It turns business ideas into dependency-ordered planned tickets the existing pipeline consumes without special-casing.

## Architecture

```
User idea → [ticket-planner] → Linear initiative + epic + planned tickets
                                    ↓
                              [fleet-controller dispatch] → spawn queue
                                    ↓
                              [ticket-auto] → implement → verify → merge
                                    ↓
                              [fleet-feedback] → aggregated feedback JSON
                                    ↓
                        (Regenerate flag) → [ticket-planner re-plan]
```

The planner is a separate plugin from `ticket-auto-pipeline` and `fleet-controller` — same precedent as fleet-controller's extraction. It has its own version, release cadence, and marketplace entry. Planner churn cannot destabilize ticket execution.

## Operator-Facing Flow

### Starting a planning run

```
/ticket-planner plan "Add real-time collaboration to the document editor"
```

The planner initializes a state directory under `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/`, writes the idea to the state log, and begins the 11-phase state machine. Each phase runs as an isolated Claude agent, except Crosscheck and Refinement, both deterministic bash. The router advances sequentially through phases with no inline reasoning between them.

### What auto-dispatch does

When the Refinement phase's gate passes — every child ticket has a deterministic-and-semantic readiness verdict — the initiative epic manifest's `dispatch` field is stamped `true` (planner-refinement-phase; before that change, TicketGen stamped it on successful creation alone, with no readiness verdict yet involved — tracker-planner-and-fallback-cutover made it a local, one-way manifest flag in the first place, not the now-retired `state:execution` label; nothing in this flow writes a Linear label any more). The fleet-controller detector `_fleet_scan_initiative_dispatch` finds it during its next poll cycle by scanning epic manifests directly and — when `FLEET_AUTO_DISPATCH=true` — calls `fleet_dispatch_initiative`, which:

1. Enumerates epics whose manifest `dispatch` field is `true`
2. Enumerates each epic's child tickets from its manifest `children` array, filtering to those not yet dispatched
3. Resolves `blocked_by` dependencies from each ticket's own manifest field, checked against each blocker's local pipeline-log terminal state
4. Writes spawn queue entries under `flock` serialization
5. Respects `FLEET_MAX_CONCURRENT` and `FLEET_DRY_RUN`

The spawn queue is consumed by `fleetd` (the Python supervisor daemon), which forks workers running `ticket-auto {TID} --auto --from-planned`.

### What the approval gate still holds

**Auto-dispatch automates dispatch — it does not automate approval.** Every auto-dispatched ticket still stops at the human approval gate. This is a deliberate design decision, not an oversight:

- Dispatch decides *which* tickets enter the pipeline. Automating this removes a mechanical step a human adds no judgement to.
- Approval decides *whether* a ticket's plan is acted on. Automating this would remove the only place a human sees the plan before code is written, on a system that spends money per ticket.

The `planned-entry-gate` capability (confidence ≥ 0.85 + the Planner Context block's `Pre-approved` field → bypass human gate) is specified but deliberately unimplemented. See [Planned-Entry Gate Dormancy](#planned-entry-gate-dormancy) below.

### Resuming after interruption

```
/ticket-planner resume INIT-42
```

The router reads the state log, finds the last incomplete phase, and resumes from there. Completed phases are skipped. Entity-creating phases are idempotent — a crash between intent and creation produces exactly one entity on resume.

### Checking status

```
/ticket-planner status INIT-42
```

Shows the current phase, initiative metadata, and the last few state log entries.

## State Machine

11 phases, strictly linear. Every phase but two runs as an isolated Claude agent; Crosscheck and Refinement are deterministic bash (Refinement additionally spawns a `dor-semantic-agent` scan+audit per ticket that needs one, but the phase's own decisions stay in bash). The router is bash — it reads the state log, derives position, and dispatches phases. It performs no reasoning of its own.

```
Appraisal → Discovery → Architecture → Specify → Review → Consensus →
Crosscheck → EpicGen → TicketGen → Refinement → Completed
```

### Phase Details

| # | Phase | Agent role | Output | Deterministic gates |
|---|-------|-----------|--------|---------------------|
| 1 | **Appraisal** | Interprets the business idea, establishes initiative scope, identifies affected repositories | Scope summary, repo list | — |
| 2 | **Discovery** | Explores affected repos, traces code paths, gathers context on symbols and APIs; writes the epic-wide `## Test Data Inventory` (entity, states, roles, volume, Source, Load via, privacy — [test-data-source.md §3.1](test-data-source.md)) | Code paths, symbol references, API contracts, test-data inventory | — |
| 3 | **Architecture** | Determines technical approach, evaluates alternatives | Architecture decision record | — |
| 4 | **Specify** | Synthesizes proposal + writes per-ticket spec files with signals and a `## Verification Notes` table keyed by each AC's verbatim text (role, test data, test-data `Source` — [#503](https://github.com/willard-pro/claude-plugins/issues/503), expected value, verifiable — planner-ready-by-construction, [#499](https://github.com/willard-pro/claude-plugins/issues/499)) in a single pass; each row's test data is derived from the criterion's Given/When, naming inventory entities, and unowned data is written `Source: generate` (never a hand-written test-data pack); the Description is humanized here, since TicketGen copies it verbatim | `proposal.md`, spec files in `artifacts/specs/` | — |
| 5 | **Review** | Critiques the proposal for gaps, risks, and feasibility | Review findings | Before dispatch, the Specify decision gate halts on an open `NEEDS_HUMAN_DECISION` (deterministic bash — see [Open business decisions](#open-business-decisions-stop-the-run-before-review)) |
| 6 | **Consensus** | Resolves review findings into a settled, actionable plan | Finalized proposal | — |
| 7 | **Crosscheck** | *(not an agent — bash)* Runs the citation ([#172](https://github.com/willard-pro/claude-plugins/issues/172)) and cross-ticket propagation ([#173](https://github.com/willard-pro/claude-plugins/issues/173)) linters against the settled artifacts and the live repo, plus the test-data checks. Its first sub-step, `testdata-synth`, synthesizes test-data (TD) specs and `artifacts/testdata-synth.json` for unowned needs before any check family runs ([test-data-source.md §3](test-data-source.md)) | `META|crosscheck` findings in state.log; TD specs + sidecar | Blocking finding halts the dispatch loop before the create gate is even checked ([#178](https://github.com/willard-pro/claude-plugins/issues/178)) |
| 8 | **EpicGen** | Creates the initiative epic in Linear with no labels; writes the epic manifest. A shared-branch epic with synthesized TD specs, or with any spec blocked by a sibling, gets `**UAT Policy:** epic` unless the `uat-policy` config key (`PLANNER_UAT_POLICY`) is set | Linear epic, epic manifest (`branch`/`uat_policy`/`merge_policy`/`children`) | Idempotency: records intent before creation, checks existence by initiative ID |
| 9 | **TicketGen** | Creates planned child tickets in Backlog with no labels. Every body is composed in bash by `planner-ticket-body.sh` ([#499](https://github.com/willard-pro/claude-plugins/issues/499)) — the same spec set always produces byte-identical bodies: the spec's Description verbatim (ticket-auto-pipeline's required body sections, [#285](https://github.com/willard-pro/claude-plugins/issues/285)), `## Test Data Prerequisites` (`- <what>. Source: <source>` per need) and a `## Verification Plan` table (Test data needed cell `<what> (Source: <source>)`), both generated from Specify's `## Verification Notes` matched to Acceptance Criteria by text (never position), `## Related Tickets` from the resolved dependencies, and the Planner Context block (`Generated` = the epic's creation time, not the clock); the parent epic identifier is resolved to its UUID in the lib. Requires `## Test Data Prerequisites` on every type (planner-ready-by-construction — closes the gap Refinement's deterministic check otherwise reports advisory on every ticket). Validates dependency DAG, writes each ticket manifest, persists each body to `planner/body.md`. Sidecar edges join each consumer's dependencies and sidecar overrides render as `seeded-by:<td-slug>`; synth-marked TD tickets are created at Linear priority High. No longer stamps the epic `dispatch` flag (planner-refinement-phase) — its only phase-named success line is `TicketGen\|verify\|done`, so a post-creation verify failure no longer hides behind an earlier `generate\|done` line | Linear tickets, ticket manifests, per-ticket `body.md` | `planner-ticket-body.sh` (order, deps, body, Verification Plan), `planner-deps-check.sh` (acyclicity), `planner-context-gen.sh` (block format), `planned-ticket-check.sh` (Planner Context block validation), `planned-ticket-body-check.sh` (required `##` section validation before creation — [#285](https://github.com/willard-pro/claude-plugins/issues/285)) |
| 10 | **Refinement** | *(not an agent — bash + two `dor-semantic-agent` spawns per ticket)* For every child: a deterministic Definition-of-Ready check against its local `body.md`, then (unless `PLANNER_REFINEMENT_SEMANTIC=false`) a blind semantic scan and an audit of the deterministic result. Stamps the epic manifest `dispatch=true` once every child has a verdict, whether ready or not; the planner itself halts while any child is not ready  Convergence (planner-refinement-convergence): findings carry an id and a `new`/`carried`/`drift` label per round (`ready.lineage`); from round `PLANNER_REFINEMENT_MAX_ROUNDS`+1, and for evaluator drift on unchanged text, non-structural findings stop blocking and travel to ticket-auto appraisal as a `## Refinement Carry-over` section. An edit only to `Related Tickets` rebases the verdict; other edits get a rescan scoped to the changed sections. `resume --converge --only <TIDs>` demotes the rest without a rescan. Each child's Linear description is compared against a baseline recorded at TicketGen: a Linear-only edit is adopted, a conflicting edit is the non-waivable `BODY_DRIFT`, released by `--refresh-bodies` | Per-ticket readiness verdicts (`ready.missing`/`ready.semantic`/`ready.lineage`/`ready.demoted` on the manifest), `planner/linear-baseline.sha`, epic manifest `dispatch=true` | `dor-check.sh` (deterministic hard codes), `dor-semantic-parse.sh` + `dor_semantic_apply` (semantic result validation — quote verification against the body, `SEMANTIC_UNAVAILABLE`/`SEMANTIC_UNVERIFIED` on a bad result) |
| 11 | **Completed** | Terminal phase — writes completion summary, no further transitions permitted. Dispatched automatically in the same invocation as Refinement's gate passing clean (or legacy-skipping), never left for a separate `resume` ([#226](https://github.com/willard-pro/claude-plugins/issues/226)) | Completed state log entry, `COMPLETED.md` | Phase transition validator rejects any transition from Completed; `planner_completion_verify` refuses to report the run finished without both outputs |

**Phase merge notes:** The original 12-phase design separated Proposal, OpenSpec, StoryGen, and Execution as standalone phases. These were merged into Specify (Proposal + OpenSpec) and TicketGen (StoryGen + Execution labelling) to reduce phase count from 12 to 9. The merged phases handle all the same work — no capability was removed. Crosscheck (#178) was added later as phase 7, bringing the count to 10. Refinement (planner-refinement-phase) was added later still, as phase 10 — it un-merges the Execution-era epic stamp out of TicketGen and conditions it on a readiness verdict rather than ticket existence alone, bringing the count to 11.

### Failure handling

If a phase fails (`fail` status in state log), the router halts. The operator can:
- Re-run the phase by triggering resume (phases are idempotent)
- Manually intervene and skip the phase by writing `skip` to the state log
- Abandon the initiative

Max retries per phase: retry on `fail` or crash (phases are idempotent, so re-running is safe). `PLANNER_MAX_PHASE_RETRIES` (default 2) bounds this. The count is derived by `planner_phase_retries_exhausted` from `fail` entries in the state log rather than held in memory, so the budget survives a crashed router the same way position does.

## State Representation

State lives in an append-only pipe-delimited log at `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/state.log`. Format:

```
ISO|PHASE|STEP|STATUS|MSG
```

Schema version `1` declared as the first line. The router re-derives position by reading the log — no state held in memory between invocations.

### State Directory Layout

```
${REPOS_ROOT}/.ticket-auto/initiatives/{INITIATIVE_ID}/
  state.log           # Append-only phase transition log
  .intents/           # Idempotency intent files — created lazily on first intent write
    epic-main.json
    ticket-1.json
  artifacts/          # Per-phase artifacts (proposal.md, specs/, etc.)
    testdata-synth.json  # Crosscheck synthesis sidecar: TD specs, Source overrides, blocked_by edges
    ownership-edges.json # Crosscheck ownership edges (spec-ownership-v1 initiatives only)
  feedback/           # Feedback aggregation (written by fleet-feedback.sh)
    2026-07-21.json
```

## Resume Semantics

1. Read the state log in reverse (`tac`).
2. Find the last phase with a terminal entry (`done` or `skip`). `fail` is explicitly excluded — a failed phase is not complete and will be re-executed on resume.
3. Check if a `start` entry exists after the last completed phase (crash mid-phase).
4. If crashed mid-phase, resume at that phase (every phase is idempotent).
5. If no crash detected, advance to the next phase after the last completed.
6. If the last completed phase is `Completed`, the run is done (empty string returned).

Partial trailing writes (crash mid-write) are ignored — `cut -d'|'` cannot parse incomplete lines, so position derivation correctly falls through to the last valid `done` entry.

## Idempotency

Every entity-creating phase (EpicGen, StoryGen, TicketGen) follows a three-step pattern:

1. **Record intent** — `planner_record_intent` writes a JSON file to `.intents/{entity_key}.json` with status `"intent"`. Call BEFORE the Linear API call. Idempotent: if intent already exists, this is a no-op.
2. **Check existence** — `planner_entity_exists` checks if the intent file has status `"created"`. If so, the entity was already created — skip the API call.
3. **Mark created** — `planner_entity_mark_created` writes the Linear ID and sets status `"created"`. Call AFTER a successful Linear API call.

A crash between step 1 and step 3 produces exactly one entity on resume: the intent file exists with status `"intent"`, `planner_entity_exists` returns false, and the phase re-executes the API call. The deterministic entity key prevents duplicates.

## Contracts

The planner produces against five frozen consumption-side contracts. These are specified in earlier OpenSpec changes and are not re-specified here.

### 1. Planner Context Block

`## Planner Context` markdown block in ticket descriptions. Schema-Version 1 with 11 fields:

| Field | Type | Description |
|-------|------|-------------|
| Schema-Version | integer | Schema version (currently 1) |
| Initiative | string | Initiative identifier (e.g., `INIT-42`) |
| Epic | string | Parent epic identifier |
| Confidence | float (0.0-1.0) | Planner's confidence in correctness |
| Strategy | enum | Conservative / Balanced / Innovative |
| Decision | string | One-sentence architectural decision |
| Affected Services | CSV | Comma-separated service names |
| Target Symbols | semicolon-list | `symbol:file:line` references |
| Pre-approved | boolean | Ready for accelerated appraisal |
| Generated | ISO 8601 | When the context was created |
| Regenerate | boolean | Whether re-planning is recommended |

**Optional business-framing fields** (planner-business-framing): `Kind` (`business` | `enabler`), `Serves` and `Enables` (comma-separated Business Outcome ids). Emitted only when non-empty, after `Regenerate`; informational, ignored by every downstream parser, no Schema-Version bump. TicketGen fills them from the spec's Signals.

**Validator:** `planned-ticket-check.sh` (exit 0 = valid, 1 = malformed, 2 = low confidence + not pre-approved). The ticket *body* — the required `##` sections below the Planner Context block — is validated separately by `planned-ticket-body-check.sh`'s `check_planned_body`, called from `planner_validate_ticket`'s third (`ticket_type`) argument ([#285](https://github.com/willard-pro/claude-plugins/issues/285)); see "2. Body section contract" below.

**Generator:** `planner-context-gen.sh` — takes structured JSON, validates all fields, emits formatted markdown. Generate against the validator, not the schema document.

### 2. Body section contract

Every planned ticket's body must carry the `##` sections ticket-auto-pipeline's
gate-check (`lib/gate-check.sh` Check 2.7c) requires before a planned ticket can
leave the approve gate — the canonical set lives in ticket-auto-pipeline's
`templates/{bug,feature,improvement,security,chore}.md` files and is enforced
by `planned-ticket-body-check.sh`'s `check_planned_body`:

- **Universal:** `## Acceptance Criteria`, `## Test User`, `## Scope` (a `| Layer | Service | Area |` table)
- **feature / improvement:** + `## Navigation Path`
- **bug:** + `## Steps to Reproduce`, `## Test Data Prerequisites`

TicketGen's phase prompt (`planner-phase-prompts.sh`) instructs the agent to
compose every ticket body against this set from the start, and
`planner_validate_ticket` (`planner-ticket-validate.sh`) mechanically checks it
before creation when called with a `ticket_type` argument — a ticket missing a
required section is not created; the failure surfaces as a planner error at
generation time, not as a `PLANNED_BODY_INCOMPLETE` gate-stop several phases
later in ticket-auto ([#285](https://github.com/willard-pro/claude-plugins/issues/285)).

#### Business-first layout (planner-business-framing)

The section contract above is unchanged; the business framing is additive. Every
ticket body is rendered in this order:

1. `## Summary` — what the ticket does, in plain language.
2. `## Outcome` (Kind = business: `**Serves:**`, `**Who:**`, `**Need:**`, `**Outcome:**`)
   or `## Enables` (Kind = enabler: the outcome id it enables, or the technical reason).
3. The type template's own why/outcome headings — `## Background / Motivation`,
   `## Motivation`, `## Impact`, `## Proposed Behaviour` / `## Proposed Changes` /
   `## Desired Behaviour`, `## Expected Behaviour` / `## Actual Behaviour`.
4. `## Technical Context` — files, routes, tables, symbols, line references, repository evidence.
5. `## Acceptance Criteria` and the rest of the contract above.

Step 3 is not optional. ticket-auto-pipeline's readiness check (`dor-check.sh`,
hard code `INTENT_MISSING`) matches the why/outcome headings by exact name, and
neither `## Outcome` nor `## Technical Context` is one of its aliases — a body with
only Summary / Outcome / Technical Context fails Refinement.
`test-planner-business-framing.sh` holds the golden bodies and a negative control
for exactly this.

Where it comes from: Specify writes `## Business Outcomes` (`### O<n>` with
Who / Need / Outcome / Measure) into `proposal.md`. Sources, in order: the sealed
`intent.md`, then `appraisal.md`, otherwise an explicit `NEEDS_HUMAN_DECISION`
marker — the planner never invents actors, value or metrics. Each spec's Signals
JSON carries `Kind`, `Serves` and `Enables`. Consensus carries the outcomes over;
EpicGen renders them into the epic (`## Summary` / `## Outcomes` / `## Who benefits` /
`## Child tickets` / `## Technical approach`, with a capability-style title and no
phase codes); TicketGen renders the per-ticket `## Outcome` or `## Enables`.
Business titles are actor/capability or outcome statements with no code
identifiers; enabler titles may be technical. The proposal's `# ` H1 stays a short
initiative name because the epic branch slug is derived from it.

#### Open business decisions stop the run before Review

A `NEEDS_HUMAN_DECISION` marker is a question for a person, and the run now waits
for it (planner-specify-waiting-on-human). The marker line is
`**Outcome:** NEEDS_HUMAN_DECISION — <question>` under a `### O<n>` heading of
`## Business Outcomes`. When the dispatch loop is about to dispatch Review, the
decision gate (`planner_specify_gate`, `lib/planner-specify-decisions.sh`) scans
proposal.md. With an open decision it prints the questions and stops with `exit 0`,
like the create gate. No agent runs, and the state log gets no phase line.

A person releases a decision in one of three ways:

- **Answer.** Headless: `bash lib/planner-stop-describe.sh <INIT_ID>` reports
  `REASON: SPECIFY_DECISION`, one question per open decision, binding
  `specify-answer:O<n>`, `AUDIENCE: either` (the client's question; the operator
  may answer for them). Answer in one line of at most 500 characters, then
  `/ticket-planner resume <INIT_ID> --answers <file>`. The marker line becomes
  `**Outcome:** Human decision (verbatim, round N, <role>): "<answer>"`.
- **Defer.** Answer `__defer__`. The line becomes
  `**Outcome:** Deferred decision: <question>`, and Epic Gen carries the question
  into the epic unresolved — exactly the outcome a run had before this gate existed.
- **Edit.** Change the Outcome line in proposal.md by hand, then
  `/ticket-planner resume <INIT_ID>`. An answers file sent for the old question then
  gets `UNKNOWN_QUESTION_ID`; describe again.

The first answer wins: a decision that is no longer open refuses a later answer with
`UNKNOWN_QUESTION_ID`. The answer text is written to proposal.md and
`artifacts/answers/round-N.json`, never to state.log, and from proposal.md it reaches
the Review, Consensus and Epic Gen agents and the Linear epic.

**Trade-off.** Only the Outcome line changes. Who and Need stay as Specify wrote them,
often "Not specified". Review and Consensus see the decision and may refine them. This
avoids re-running Specify.

#### Parameters: one registry, asked with the outcomes

Every value the plan depends on that someone could choose differently — a timeout,
a retry rule, a rounding mode, a fee — is declared once per initiative
(planner-specify-parameters). It applies to **contract initiatives** only: those whose
state.log holds `META|contract|start|specify-parameters-v1`, which
`planner_params_contract_mark` writes once when Specify is about to be dispatched for the
first time (no Specify `done` line, no spec file yet).
An initiative that ran Specify before the change has no marker and behaves exactly as
before: no registry, no second stop, no parameter Crosscheck family.

Specify writes `## Parameters` in proposal.md, directly after `## Business Outcomes`:
either `None.` or one table.

```
| Name | Key | Kind | Default | Value | Source |
|------|-----|------|---------|-------|--------|
| Idle session timeout | `auth.session_idle_minutes` | duration | 30 minutes | 30 minutes | default |
| Invoice rounding | `billing.total_rounding` | rounding | half-up, 2 decimal places | NEEDS_HUMAN_DECISION — round each line, or only the invoice total? | — |
| Provider API timeout | `payments.provider_timeout` | fixed | — | 10 seconds | discovery:"the provider closes the connection after 10 seconds" |
```

- **Kind** is one of `policy`, `rounding`, `transaction`, `failure`, `fixed` (the
  *must-ask* kinds — they change what an acceptance criterion means) or `duration`,
  `limit`, `size` (tuning kinds — cheap to change, may be `default`).
- **Key** is backticked, a letter then letters, digits, `_`, `.` or `-`, at most 64
  characters, unique. Specs write the Value verbatim and name the key in backticks in
  `## Technical Context`.
- **Source** is `default`; `—` (only while Value is open); `<artifact>:"<quote>"` with
  artifact `idea`, `intent`, `appraisal`, `discovery` or `architecture`;
  `code:<path>:"<quote>"` (relative, no `..`); or `human:r<N>:<client|operator>`, which
  only answer intake writes.
- **Anchors.** Bash checks each source (`planner_params_anchor_ok`): a quote of 8 to 300
  characters must appear in the file (whitespace normalised, case-sensitive), and must
  hold a literal equal to the Value's; a `human:` source must match a `specify-param`
  record in `artifacts/answers/round-N.json`. A source that does not verify counts as
  `default`. Nothing fails at this step.
- **Open rows.** A row is open when its Value starts with `NEEDS_HUMAN_DECISION`, or when
  its effective source is `default` and its kind is must-ask. A keyword in the Name or
  Key (`round`/`decimal`/`precision`, `retry`/`attempt`/`backoff`/`fallback`/`fail`…,
  `rollback`/`transaction`/`atomic`/`commit`/`idempot`, `refund`/`fee`/`price`/`trial`/
  `retention`/`grace`/`quota`/`tax`…; the full list is `PLANNER_PARAMS_KIND_KEYWORDS`)
  makes a tuning row must-ask, so "Payment retry delay" (`duration`) is asked. An
  invalid row is never asked; the tripwire lists it as `param`, and Crosscheck reports
  it.

**One round, two stops.** `planner_specify_gate` counts open rows with the open
outcomes, so the stop before Review asks both in one `SPECIFY_DECISION` round. For a
contract initiative the same gate runs again when Crosscheck is about to be dispatched,
to catch rows and markers Consensus added or reopened. That halt's first line is
`Consensus left <n> decision(s) open — this is a second stop, after Consensus and before
Crosscheck.`

**Answering a parameter.** Each open row is one question, id `param-<key>`, binding
`specify-param:<key>`. The text puts the plain question first, then
`Suggested: "<suggestion>" — reply with exactly that text to accept it`, then the
format hint and `(<Name>; key <key>, <kind>; used by <slugs>)`. There is no sentinel:
accept a suggestion by sending its text back. `__defer__` is refused. A `duration`
answer must be one number with a unit (`30 minutes`); a `limit` or `size` answer may
also be a bare number. A must-ask kind takes free text. A refused answer is
`INVALID_VALUE` with an example, and nothing is written. An accepted answer rewrites
the row line, with Source `human:r<N>:<role>`, and writes
`META|specify-param|step|<key> answered (round N, by <who>, <role>)` — never the value.

**Hand edits.** A tuning row may be edited at any time; it stays `default`, so it
stays closed. A must-ask row cannot be edited to closed: set its Value back to
`NEEDS_HUMAN_DECISION — <question>` and answer it through `--answers`, so every human
source stays verifiable.

**Changing a value later.** Specs hold real values, not placeholders, so a changed
value is a change to text:

| Situation | What happens |
|---|---|
| Answer before Review | Intake rewrites the row. Consensus uses the registry Value in specs. Crosscheck then blocks any spec literal that no closed row declares, so a spec still holding the old suggestion fails with `PARAM_LITERAL`. |
| Answer at the second stop | Same path: Crosscheck runs on the decided registry. |
| Changing a decided value before Epic Gen | Tuning row: edit the row and the specs. Must-ask row: reopen it and answer it, then edit the specs. Crosscheck catches a spec left behind. |
| Changing a value after tickets exist | Manual: edit the row, the specs and the Linear tickets, or use re-plan (`Regenerate`), which regenerates undispatched Backlog tickets. Crosscheck does not run after Epic Gen, so nothing checks a post-creation edit. |
| Specify re-run after answers | The prompt keeps `human:` rows verbatim. A dropped or altered row fails its anchor, reopens, and is asked again with the earlier answer as a hint. |

**Prompt edits.** The Specify and Consensus prompt wording for parameters lives in lib
functions (`planner_params_prompt_rules`, `planner_params_consensus_rule` in
`lib/planner-specify-params.sh`), each pulled into its prompt by one `$(…)` line. Keep
that rule — one function per prompt block — for any later Specify prompt edit, so the
prompt diff stays one line and the `SPECIFY_PROMPT_SHA` re-pin is the only other change.

### 3. Local manifest facts (tracker-planner-and-fallback-cutover)

Every issue the planner creates carries **no labels at all** — Epic Gen and Ticket Gen both pass
an empty label array to `planner_linear_create_issue`. The facts these labels used to carry live
in the local ticket/epic manifest instead
(`${REPOS_ROOT}/.ticket-auto/initiatives/{INIT}/tickets/{TID}/planner/manifest.json` and the
sibling `epic/manifest.json`), written once at creation time:

| Former label | Manifest field | Set by | Lifecycle |
|-------|---------|--------|-----------|
| `planned` | ticket manifest existence | Ticket Gen | A manifest exists, or it doesn't. |
| `INIT-*` | ticket manifest `initiative` | Ticket Gen | Never changes. |
| `pre-approved` | Planner Context block `Pre-approved` field (not a manifest field) | Ticket Gen (when confidence ≥ 0.85) | Accelerates fast-path. Never a label to remove. |
| `blocked-by:*` | ticket manifest `blocked_by` (array) | Ticket Gen | Target is a sibling ticket in this initiative, or an existing Linear ID for a cross-initiative prerequisite. Resolved against each blocker's own local pipeline-log terminal state. |
| `state:execution` | epic manifest `dispatch` (bool) | Refinement's gate, via `planner_refinement_gate` (planner-refinement-phase — formerly Ticket Gen's own post-creation gate) | One-way stamp once every child has a deterministic-and-semantic readiness verdict, whether ready or not. |
| `Type` | ticket manifest `type` | Ticket Gen | `bug`/`feature`/`improvement`/`security`/`chore`. Drives template selection locally. |

The only labels still projected onto a Linear ticket are the 4 human-signal ones the board driver
writes (`needs-info`/`needs-adr`/`rejected`/`reviewed`) — never written by the planner.

### 4. Artifact Plane

`planner-artifacts.sh` (in `ticket-auto-pipeline/lib/`) resolves per-ticket artifact directories from the Planner Context block's Initiative field. Path: `${REPOS_ROOT}/.ticket-auto/initiatives/{INIT}/tickets/{TID}/planner/`.

Per-initiative artifacts (proposal, specs) live under `${REPOS_ROOT}/.ticket-auto/initiatives/{INIT}/artifacts/`.

### 5. Feedback

`fleet-feedback.sh` aggregates `META|planner-feedback` entries from pipeline logs, grouped by initiative ID. `planned-feedback-write.sh` (post-implement hook in ticket-auto) emits these entries.

Feedback payload:
```json
{
  "confidence_predicted": 0.85,
  "confidence_actual": 0.70,
  "outcome": "Rough",
  "corrections_count": 2,
  "files_changed": ["src/auth.ts"],
  "services_touched": ["auth"],
  "decision_drift": "minor"
}
```

Aggregated to `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json` with summary statistics (total tickets, avg confidence, drift count, services touched).

### 6. Cross-plugin validators (not bundled here)

The planner ships no copy of the scripts that define these contracts — it resolves
them from the plugins that own them, via a three-level fallback (plugin cache →
skills lib → sibling path in the same repo). A drifting duplicate would silently
produce output the downstream pipeline rejects, so the dependency is deliberate.
Run `/ticket-planner doctor` to see whether each one resolves on this install.

| Script | Owning plugin | What it owns | Planner call site |
|---|---|---|---|
| `planned-ticket-check.sh` | ticket-auto-pipeline | Planner Context block **structure** — required fields, `Schema-Version`, confidence range, and the `Target Symbols` grammar (`_validate_target_symbols`: each `;`-separated entry must be `symbol:file` or `symbol:file:line` — a zero-colon bare path is rejected). Also the canonical `_extract_md_section` / `_extract_field` markdown helpers. | `planner_validate_ticket` (`planner-ticket-validate.sh`), before every Ticket Gen create; `branch_directive_source_md_helpers` (`branch-directive-gen.sh`), in the Epic Gen idempotency check |
| `planned-ticket-body-check.sh` | ticket-auto-pipeline | Ticket **body** section completeness — the `##` headings gate-check's Check 2.7c requires per type (`check_planned_body`), sourced from `templates/{bug,feature,improvement,security,chore}.md` ([#285](https://github.com/willard-pro/claude-plugins/issues/285)) | `planner_validate_ticket` (`planner-ticket-validate.sh`), before every Ticket Gen create, when called with a `ticket_type` argument |
| `branch-directive-check.sh` | ticket-auto-pipeline | Branch Directive block schema and enums | `_resolve_branch_directive_checker` (`branch-directive-gen.sh`) — generated blocks are round-trip tested against it |
| `grill-seal.sh` | grill-me | Validated Business Intent seal verification | `planner_intent_gate` (`planner-intent-gate.sh`) |

**Validation is split across two plugins, and neither side sees the other's rules.**
Crosscheck's citation linter (`planner-crosscheck-citations.sh`) checks that a
`symbol:path:line` TargetSymbols entry *resolves* against the repo; it does not
check the entry's *shape*. The shape rule lives only in `_validate_target_symbols`
above, which does not run until Ticket Gen's pre-creation validation — so a
malformed entry surfaces as a late creation failure rather than at the
artifact-only gate. **Any change to the TargetSymbols grammar must be made in both
validators**, or one of them will start rejecting what the other emits.

## Confidence Derivation

Confidence is derived from five concrete signals — never a uniform constant. A planner that emits uniformly high confidence would silently disable the investigation that catches its own mistakes.

| Signal | Effect | Rationale |
|--------|--------|-----------|
| Services identified | +5 per service (max +20) | More services traced → higher confidence in scope understanding |
| Symbols resolved | +3 per symbol (max +15) | More symbols with confirmed file:line → higher confidence in code understanding |
| Prior art found | +10 if true | Similar patterns in codebase → higher confidence in approach |
| Exploration depth | +5 standard, +10 deep | Deeper exploration → more evidence |
| Complexity | -15 complex, +5 simple | Complex tickets have more unknown unknowns |

Score clamped to 0.05–0.95. `planner_confidence_derive` in `planner-context-gen.sh` implements this.

## Dependency Validation

Dependencies are expressed as `blocked-by:{ID}` labels. `planner-deps-check.sh` validates that:

1. The dependency set forms a DAG (no cycles). Uses `tsort` for cycle detection.
2. All `blocked-by` targets exist in the ticket set (no dangling references).
3. Topological sort determines dispatch order.

Crosscheck adds the blocking `DEPENDENCY_CYCLE` code: it runs the TicketGen dependency reader
(`planner_ticketgen_deps_json`) after test-data synthesis and the ownership edges step, so a
cycle through a sidecar edge (consumer → TD spec, or reader → writer from
`artifacts/ownership-edges.json`) is caught before the first Linear write. The message counts
`## Labels` blocked-by, the test-data synthesis edges in `artifacts/testdata-synth.json` and
the ownership edges in `artifacts/ownership-edges.json`.

`planner_replan_validate_deps` (re-planning) still sees `## Labels` refs only, not either
sidecar. That gap predates the ownership edges.

### Cross-initiative prerequisites

A `blocked-by` target may instead name a ticket **outside** this initiative by its
existing Linear identifier (`blocked-by:WIL-83`). Such a ref is already resolved, so
it is exempt from check 2 and from the Crosscheck `DANGLING_BLOCKED_BY` check — it
names a real ticket by design, not a sibling spec. Ticket Gen applies it verbatim.

Sibling resolution is always attempted first; a token counts as external only when it
resolves to no sibling spec *and* has the shape of a Linear identifier (uppercase team
key, hyphen, number). Spec slugs are lowercase filenames, so the namespaces do not
collide. External refs are also excluded from the shared-branch chain-depth heuristic —
a ticket in another initiative is not part of this epic branch's merge topology.

Before this, a cross-initiative prerequisite could only be described in prose in the
ticket Description, where nothing enforces it and nothing surfaces it to `ticket-auto`
or `fleet-controller`.

A cyclic dependency set produces no tickets — the error is reported before any Linear API call.

## Auto-Dispatch

When TicketGen completes successfully, the initiative epic manifest's `dispatch` field is stamped `true` (no Linear label write). The fleet-controller detector `_fleet_scan_initiative_dispatch` finds it during its next poll cycle by scanning epic manifests directly.

**Gating:** `FLEET_AUTO_DISPATCH=true` must be set. When false (default), the detector reports undispatched initiatives at severity 1 (WARN) but does not actuate. This allows observe-only operation during rollout.

**Idempotency:** `fleet_dispatch_initiative` checks the spawn queue for already-queued entries before enqueuing. Re-running dispatch does not duplicate entries.

**Concurrency:** `FLEET_MAX_CONCURRENT` caps active pipelines. `FLEET_DRY_RUN` makes dispatch no-op for preview.

## Shared-Branch Directive

When Epic Gen creates an initiative epic, a deterministic bash heuristic decides whether the epic should carry a `## Branch Directive` block. The directive declares a shared integration branch that child tickets target — downstream, `ticket-auto-pipeline` resolves it via `branch-resolve.sh` and `fleet-controller` manages its lifecycle via `epic-branch.sh`.

### Decision Rule

The recommender (`planner_branch_directive_recommend`) applies a two-condition rule, both required:

- **≥ 3 planned tickets** — fewer tickets don't warrant shared-branch overhead
- **Dependency chain depth ≥ 2** — chained tickets genuinely build on each other

Ticket count alone is insufficient — independent tickets serialised behind a single integration PR gain nothing. Chain depth (computed via DP on the topological ordering) is the signal that tickets form an integrated unit.

### Thresholds

The thresholds are **provisional and unvalidated** against real usage data. The asymmetry is deliberate:

- **Under-recommending** costs the operator one flag (`--shared-branch`)
- **Over-recommending** silently changes the merge topology of ordinary work

When uncertain, don't recommend. Both override flags exist so the heuristic is never the final word.

### Operator Overrides

| Flag | Behavior |
|------|----------|
| `--shared-branch` | Force directive emission regardless of heuristic |
| `--no-shared-branch` | Suppress directive regardless of heuristic |

Supplying both is an error. Neither flag defers to the heuristic.

`PLANNER_UAT_POLICY=per-ticket|epic` is read once at argument parsing and persisted as
the `uat-policy` config key; any other value is rejected. Unset, EpicGen stamps
`**UAT Policy:** epic` on a shared-branch directive when `testdata-synth.json` lists at least
one TD spec, or when any spec is blocked by a sibling spec (`planner_uat_policy_resolve`,
planner-ac-coverage-and-epic-uat). Under per-ticket UAT a child parked in `UAT` never reaches
`Done`, and every ticket it blocks would deadlock. External prerequisites do not count. The
decision is recorded as `META|uat-policy-decision|done|policy=<p> reason=<explicit|td-spec|chain|none|error>`.

**Base branch, merge and sync policy** (planner-base-branch-config) are config keys too:
`--base-branch <name>` (fallback `PLANNER_BASE_BRANCH`), `PLANNER_MERGE_POLICY`
(`manual`\|`on-all-children-done`) and `PLANNER_SYNC_POLICY` (`rebase-on-base-change`\|`none`)
are read once at argument parsing and persisted as `base-branch`/`merge-policy`/`sync-policy`.
Invalid values are refused there. Epic Gen interpolates them as literals and reads no
environment variable. When the directive will be emitted and no base is set,
`planner_base_branch_resolve` detects it for each repo Discovery pinned: `develop` (local or
`origin/develop`), then the `origin/HEAD` target, then `main`, then `master`. One shared answer is
persisted and recorded as `META|base-branch-source|done|detected:<repo>=<branch>,...`. With no
pinned repos the base is `develop` (`...|done|default`). Repos that disagree
(`BASE_BRANCH_AMBIGUOUS`), a repo with no candidate or no checkout, or an explicit base a repo
lacks (`BASE_BRANCH_UNRESOLVED`) make prompt rendering fail, so Epic Gen stops before any
Linear write. The message names each repo's result; the fix is `resume <ID> --base-branch <name>`.

### Design Decisions

- **The decision is bash, not agent judgement.** "Do these tickets belong on one branch?" is a question about dependency graph shape, not content. Reproducibility matters — merge topology must not depend on sampling variance.
- **The branch name is derived, not authored.** `epic/{INITIATIVE_ID}-{title-slug}`, deterministic, satisfying the downstream validator's charset rules by construction. No agent-supplied content.
- **Generate against the validator.** `branch-directive-gen.sh` round-trips through `branch-directive-check.sh` (downstream plugin). No bundled copy — a drifting duplicate would silently produce blocks that fail validation.
- **Nothing is added to the Planner Context block.** Children inherit the branch by parent lookup. Adding a branch field to each child would mean an epic edit silently desynchronises every child, with no arbiter.

### Ticket Gen Unchanged

The Ticket Generation phase is deliberately unaffected. Child tickets inherit the shared branch by parent lookup at execution time. No branch information is written into child ticket bodies or Planner Context blocks. The Planner Context block schema version is unchanged.

## Re-Planning

When an initiative carries the `Regenerate` flag (set to `true` in the Planner Context block), the planner:

1. Reads aggregated feedback JSONs from `{initiative_dir}/feedback/`.
2. Computes confidence drift from predicted vs actual outcomes.
3. Regenerates tickets still in `Backlog` and not present in the spawn queue.
4. Dispatched, in-progress, and completed tickets are left unchanged and reported as such.
5. Validates the regenerated dependency set remains acyclic.
6. Aggregates each feedback file's `summary.readiness_gaps` (`planner_readiness_gaps_compute`) into a `META|replan-readiness-gaps` entry. Report-only: it surfaces gate-stop and no-test-user patterns from fleet-controller's readiness-gap scan, and never feeds confidence adjustment, ticket selection or dependency validation.

**Regenerate is an explicit flag, not a default.** Reading feedback on every re-plan would make planner output depend on execution history in ways that are hard to reason about. Requiring the flag makes feedback ingestion a deliberate act with a visible trigger.

## Crosscheck

Unlike every other phase, Crosscheck is not an agent — `planner_crosscheck_run` (in
`lib/planner-crosscheck.sh`) is deterministic bash, so the dispatch loop calls it
directly instead of spawning one (SKILL.md step 1a). Its check families include:

- **Citation + precedent linter** ([#172](https://github.com/willard-pro/claude-plugins/issues/172)) — every `path:line` citation and Signals `TargetSymbols` entry must resolve against `REPOS_ROOT`; every "mirrors the existing `X`"-style precedent claim must name a symbol that actually exists in the repo.
- **Cross-ticket propagation linter** ([#173](https://github.com/willard-pro/claude-plugins/issues/173)) — a Consensus resolution or in-spec forward reference naming 2+ tickets must actually reach all of them; a post-Specify ticket-count change is flagged for manual scope audit.
- **Test-data provenance + cited artifacts** ([#503](https://github.com/willard-pro/claude-plugins/issues/503)/[#504](https://github.com/willard-pro/claude-plugins/issues/504)) — every Verification Notes test-data need (a row of the Criterion table, `Source` column) must name an owned Source (`TEST_DATA_UNOWNED`), and every external artifact Discovery could not retrieve must be raised and answered in consensus.md `## Open Questions` (`CITED_ARTIFACT_UNRAISED`/`CITED_ARTIFACT_UNRESOLVED`). Contract: [docs/test-data-source.md](test-data-source.md).
- **Test-data derivation** (planner-test-data-derivation, contract §3) — first, the `testdata-synth` sub-step (`Crosscheck|testdata-synth|start`/`done|<N> TD spec(s), <M> need(s)`, before every family) turns `generate` needs and `generate:` answers into synth-marked test-data specs (`<prefix>-test-data-pack` / `<slug>-test-data`, type chore, Seed/Verify `make` targets, Seed channel) plus `artifacts/testdata-synth.json` (Source overrides + `blocked_by` edges; consumer specs untouched). Then: `VERIFICATION_NOTES_MISSING` (blocking — a spec with ACs and no notes rows), `TEST_DATA_IMPLIED` (blocking — rows all `none` but a criterion clearly implies data; answerable via `TESTDATA_CONFIRM`) / `TEST_DATA_IMPLIED_WEAK` (warn), `TEST_DATA_INVENTORY_MISSING` (warn — discovery.md lacks `## Test Data Inventory`), `TEST_DATA_SYNTH_FAILED` (blocking — an unmarked file holds a TD slug) and `DEPENDENCY_CYCLE` (blocking — cycle in the blocked-by graph including sidecar edges).

- **Parameters** (planner-specify-parameters, `lib/planner-crosscheck-params.sh`; contract initiatives only) — `PARAM_TABLE_INVALID` (no `## Parameters` section, a bad header or an invalid row), `PARAM_UNDECIDED` (an open row; normally the second Specify stop halts first) and `PARAM_LITERAL` (a unit literal — `15 minutes`, `10s`, `30-day`, `2 GB`, `3 retries`, `2.5%` — in an acceptance criterion or a Verification Notes `Expected` cell that no closed row declares), all blocking. Literals are compared canonically (`86400 seconds` = `24 hours` = `1 day`); a `fixed` row covers only the specs that name its key. Not checked: `0`, `100%`, decades, code spans, URLs, criterion labels like `10h.`, numbered notes lines, Test data cells, and other sections. Synth-marked TD specs and `INDEX.md` are skipped.

- **Data ownership** (planner-crosscheck-ownership, `lib/planner-crosscheck-ownership.sh`; `spec-ownership-v1` initiatives only) — see [Data ownership](#data-ownership-writes-and-reads-tables) below.

- **AC preconditions** (planner-ac-code-precondition, `lib/planner-crosscheck-ac-precondition.sh`; `ac-precondition-v1` initiatives only) — see [AC preconditions](#ac-preconditions-the-preconditions-table) below.

(Bypass, contract, Signals and dangling-dependency checks also run — see `lib/planner-crosscheck.sh`.)

The citation + precedent linter also runs once earlier, as a self-lint at the end of
the Specify phase ([#218](https://github.com/willard-pro/claude-plugins/issues/218)) —
the Specify agent runs `planner_crosscheck_citations` against its own fresh output and
fixes findings before handing off to Review, catching the defect class in the same
context window that introduced it. This front-loads the check; it does not replace
Crosscheck, which still re-runs it as the final gate against the fully-reviewed
artifacts.

Every finding is written to state.log as `META|crosscheck|fail|<CODE> <message>` — the
shape `ticket-retro`'s failure-histogram parser already reads (see
[#176](https://github.com/willard-pro/claude-plugins/issues/176),
[#177](https://github.com/willard-pro/claude-plugins/issues/177)). A blocking finding
halts the dispatch loop immediately, before the create gate is even checked — retrying
a deterministic check against unchanged artifacts cannot produce a different answer, so
this is not folded into the phase-retry budget. Fix the cited artifact and
`/ticket-planner resume <INIT_ID>` re-runs Crosscheck; it proceeds once clean. If the
finding is genuine but expected rather than a defect (a documented rescope, say),
`/ticket-planner resume <INIT_ID> --accept CODE:"reason"` is the supported alternative
to fixing the artifact — see [Accepting a genuine Crosscheck finding](#accepting-a-genuine-crosscheck-finding---accept).

`#174` (bypass sweep for guarded fields) and `#175` (cross-initiative contract check)
now run as their own check families (see the parenthetical above).

### Data ownership: Writes and Reads tables

planner-crosscheck-ownership. It applies to initiatives whose state.log holds
`META|contract|start|spec-ownership-v1`. `_planner_dispatch_contract_mark` writes it, together
with `specify-parameters-v1`, on the **first** Specify dispatch only: when the log has no
`|Specify|<step>|done|` line and `artifacts/specs/` holds no `*.md` file
(`_planner_specify_first_dispatch`). A re-dispatch of an initiative whose Specify already wrote
specs therefore stays legacy, so its specs are never failed for tables the older prompt did not
ask for. The Specify prompt asks for both tables (`planner_ownership_prompt_rules`), and
Consensus keeps them in step with its edits (`planner_ownership_consensus_rule`). A legacy
initiative (no marker) gets no finding, no edges line and no file.

**Format.** Every spec except synth-marked test-data specs and `INDEX.md` has two sections.
Each holds `None.` or exactly one pipe table directly under the heading:

```
## Writes

| Key | Op |
|-----|----|
| `invoice.status` | transition:sent,overdue->paid |
| `invoice_history` | append |
| `email.payment_receipt` | fire |
| `email.invoice_overdue` | trigger |

## Reads

| Key | Source |
|-----|--------|
| `invoice.amount_due` | spec |
| `invoice.due_date` | code:billing-service/src/main/resources/db/changelog |
| `user.id` | framework:auth_user |
| `bank_holiday.date` | external:public holiday feed |
```

A key is backticked `<segment>` or `<segment>.<segment>`, each segment a lower-case letter then
lower-case letters, digits or `_`, at most 64 characters, once per table. Data keys are entity
and field; effect keys (`fire`, `trigger`) are channel and event, a separate namespace, and are
never read. A read of `invoice.status` matches a write of `invoice` or `invoice.status`; a read
of `invoice` matches a write of `invoice` or any `invoice.<field>` (entity rule, reads only).

**Ops and the conflict rule.** `create`, `update`, `delete`, `append`,
`transition:<from>-><to>` (`<from>` a comma list or `*`), `fire`, `trigger`. Two specs with a
data row for the same exact key conflict unless either row is `append`, or both are
transitions with disjoint from-sets. `create`/`update`/`delete` count as `transition:*->…`, and
`*` overlaps everything.

**Sources.** `spec` (a sibling writes it); `code:<path>` (relative, no `..`, letters, digits and
`._/@+-` only — the anchor holds when one file under the path, in the Discovery-pinned tree,
names every key segment as a word, at most 200 files); `framework:<name>` (`auth_user`,
`session`, `clock`, `timestamps`, `row_id`, `tenant`); `external:<name>` (3–80 characters,
anchored when the name appears in idea.txt, intent.md, discovery.md or architecture.md). A
failed `code:` anchor counts as `spec`. A read of a key the spec writes itself is ignored. The resolver (`_planner_own_code_tree`) also reports a pin state, `pinned`, `live` or
`pin-failed` (a pinned sha whose worktree could not be created: the live tree is used); the
ownership anchor treats all three alike, the AC precondition family does not.

**Codes.**

| Code | Tier | Accept |
|---|---|---|
| `OWN_TABLE_INVALID` | blocking, one per spec | code-wide `--accept OWN_TABLE_INVALID:"…"` |
| `OWN_MULTI_WRITER` | blocking, cross-file, one per key | `--accept OWN_MULTI_WRITER@<key>:"<reason>"` |
| `OWN_NO_WRITER` | blocking, one per spec and key | `--accept OWN_NO_WRITER@<slug>/<key>:"<reason>"` |
| `OWN_MULTI_FIRE` | blocking, cross-file, one per key | `--accept OWN_MULTI_FIRE@<key>:"<reason>"` |
| `OWN_TRIGGER_UNOWNED` | blocking, one per spec and key | `--accept OWN_TRIGGER_UNOWNED@<slug>/<key>:"<reason>"` |
| `OWN_EDGES_FAILED` | blocking (the sidecar could not be written) | code-wide |
| `OWN_NEAR_MATCH`, `OWN_UNDECLARED_REF`, `OWN_EXTERNAL_UNANCHORED`, `OWN_EDGES_DIVERGED` | warn | — |

The four instance codes take only the per-instance form or the wildcard
`<CODE>@*:"<reason>"` (see [Accepting a genuine Crosscheck finding](#accepting-a-genuine-crosscheck-finding---accept)).
Each finding message ends with its own accept command. Spec-derived text in a message has `"`
replaced by `'` and `--accept` defused, and the instance is read only from that trailing
command, so a spec cannot name another instance.

**Edges and freeze.** Right after test-data synthesis, Crosscheck writes
`artifacts/ownership-edges.json` (`{"version":1,"edges":[{"consumer","blocked_by","keys","frozen"}]}`,
written only when its bytes change, removed when empty) and one
`META|ownership-edges|done|<n> edge(s)` line. A read whose effective source is `spec` gives
`reader blocked_by writer` for every other spec with a matching data write; a `trigger` gives
`trigger-spec blocked_by fire-owner`. Verified `code:`, `framework:` and `external:` reads
give none. A consumer whose ticket exists keeps its recorded edges (`"frozen": true`); a
differing recompute is the `OWN_EDGES_DIVERGED` warning. `planner_ticketgen_spec_deps` adds
these edges after Labels and test-data edges, so TicketGen, draft readiness drafts,
`## Related Tickets`, the cycle check and the epic UAT policy (resolved to epic-level, reason `chain`) all see
them. Ticket bodies never carry the two tables: `writes` and `reads` are in the composer's
drop list. Draft revise cannot change them: they are outside the editable sections.

**Not checked.** A write or read the spec does not declare (only `OWN_UNDECLARED_REF` warns,
for backticked `entity.field` tokens in Technical Context); two names for one thing beyond
the one-trailing-`s` near-match warning; writes or effects by existing code outside the
initiative; whether a `code:` file defines the field rather than mentioning its words;
whether transition states exist or form a valid state machine; whether the `fire` owner's
ACs state idempotency; ordering between writers of different fields of one entity; AC
numbers against seed or test data.

### AC preconditions: the Preconditions table

planner-ac-code-precondition. It applies to initiatives whose state.log holds
`META|contract|start|ac-precondition-v1`. `_planner_dispatch_contract_mark` writes it with
`planner_acpre_contract_mark` on the first Specify dispatch, right after `spec-ownership-v1`
(a missing mark function is skipped; a failing one fails the dispatch). An initiative that ran
Specify before that gets no family, describer note or revise check, and its specs, bodies and
halts are unchanged. The one exception is the body composer: `## Preconditions` is always in its
drop list. The Specify prompt asks for the table (`planner_acpre_prompt_rules`, after the
Writes/Reads rules), Consensus keeps it in step with its edits (`planner_acpre_consensus_rule`),
and the draft revise prompt tells the agent to extend a row's Criterion cell when it extends that
criterion (`planner_acpre_revise_rule`).

**Format.** Every spec except synth-marked test-data specs and `INDEX.md` has a
`## Preconditions` section. It holds `None.` or exactly one pipe table directly under the
heading. Each row names the stored starting state that one acceptance criterion needs:

```
## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| An invoice with no due date is listed on the Needs date page. | `invoice.due_date` | state | null | code:billing/src/main/resources/db/changelog |
| Saving the invoice form without a customer shows "Customer is required". | `invoice.customer_id` | input | null | — |
```

- **Criterion** repeats one `## Acceptance Criteria` line (after `- [ ]`), matched as Verification
  Notes rows are: trimmed, whitespace runs collapsed. Several rows may share one criterion.
- **Key** uses the `## Writes`/`## Reads` key grammar with exactly two segments, `<entity>.<field>`.
- **Mode** is `state` (a stored record must hold the value before the criterion is checked; this
  is checked) or `input` (a value the test submits and expects to be rejected; recorded, never
  flagged). Anything else is invalid.
- **Requires** is `null`, `value:<v>` (`<v>` a lower-case letter, then lower-case letters, digits
  or `_`) or `number:<n>` (optional `-`, digits, optional `.` and digits; at most 30 characters).
- **Basis** is `code:<path>` or `spec:<slug>` for a `state` row, and `—` for an `input` row.
  `code:` uses the ownership path grammar (relative, no `..`).
- A `(Criterion, Key, Mode, Requires)` tuple appears at most once.

**`spec:` Basis.** It says a spec of this initiative changes the schema so the state becomes
reachable. The slug must name an existing, non-synthesized spec; that spec's `## Writes` must
have a row for the key or its entity (`basis-spec-no-write`); and if it is another spec, it must
be in this spec's dependencies (`planner_ticketgen_spec_deps`; `basis-not-a-dependency`, add
`blocked-by:<slug>`). `spec:<own slug>` follows the same Writes rule against the spec itself. A
valid `spec:` row is never checked against code and counts as planned on the info line.

**Planned change without the Basis.** When a `code:` row is unreachable but another
non-synthesized spec writes the key (any op), the finding is downgraded to the warning
`AC_PRECONDITION_PLANNED`, naming that spec, with the hint to set `spec:<slug>`.

**Code and pin.** `code:` resolves through `planner_ownership_code_target`, against the
Discovery-pinned tree. A `pinned` tree prints `(pinned)` in messages, a `live` tree (nothing was
pinned) prints `(unpinned)`, and `pin-failed` makes the row unchecked. Candidate files are found
with `.git`, `target`, `build`, `node_modules`, `out`, `.gradle` and `.idea` pruned, filtered to
`.java` and `.xml`, sorted, and capped at `PLANNER_OWNERSHIP_CODE_MAX_FILES` (200); over the cap,
the row is unchecked. When the path holds no matching `@Entity` (often it is a changelog
directory), entity lookup repeats over the whole repository, capped at
`PLANNER_ACPRE_ENTITY_MAX_FILES` (2000); changelogs are found the same way. Java enums are
always looked up in the whole repository.

**Supported stacks and facts.** Only JPA (`.java`) and Liquibase XML changelogs are read, and
only strong facts. Names compare lower-cased with `_` removed (no plural folding): an `@Entity`
class or its `@Table(name)`, a field or its `@Column`/`@JoinColumn(name)`, a Liquibase
`tableName` or column `name`.

| Fact | Source |
|---|---|
| `nullable no` | Liquibase `nullable="false"`, `primaryKey="true"`, `<addNotNullConstraint>`; JPA `@Id` |
| `nullable yes` | Liquibase `<dropNotNullConstraint>`, `nullable="true"` |
| `primitive` | a Java primitive field type (agrees only, never decides) |
| `enum` | an `@Enumerated(EnumType.STRING)` field whose type is exactly one `enum` in the repository with no constructor arguments |
| `enum-unchecked` | an ordinal enum (also no `@Enumerated`), `@Convert`, or an enum with constructor arguments or constant bodies |
| `min` / `max` | Liquibase `smallint`, `int`/`integer`, `bigint` (their SQL ranges); `modifyDataType` gives a type too |
| `transient` | `@Transient`, `@Formula` or the `transient` keyword: the field's other facts are dropped |
| `unparsed` | a changelog touches the table with a change the parser does not model (`<sql>`, `<sqlFile>`, `<renameColumn>`, `<update>`, `<loadData>`, …) |

XML comments and `<rollback>` blocks are blanked first; multi-line `<column>` and
`<constraints>` elements and multi-column `<addColumn>` are read. Changelog order and includes
are not followed: facts are pooled, and a contradiction (`nullable no` with `nullable yes`, two
integer types) makes the row unchecked. A Java annotation argument that is not a literal gives no
fact.

**Decision** (`planner_acpre_decide`). `null` is unreachable on a `nullable no` fact with no
`nullable yes` fact. `value:<v>` is unreachable on an `enum` fact with no constant equal to `<v>`
(lower-cased, `_` removed). `number:<n>` is unreachable below `min` or above `max`, compared as
decimal strings, never as floating point. Anything uncertain is unchecked: field or table not
found, contradictory facts, only a `primitive` fact, `enum-unchecked`, an ambiguous enum, an
`unparsed` change (for `null` and `number:` rows), a `transient` field, a pin failure, a cap hit.

**Codes.**

| Code | Tier | Accept |
|---|---|---|
| `AC_PRECONDITION_TABLE_INVALID` | blocking, one per spec, every problem listed | code-wide `--accept AC_PRECONDITION_TABLE_INVALID:"…"` |
| `AC_PRECONDITION_UNREACHABLE` | blocking, one per row | `--accept AC_PRECONDITION_UNREACHABLE@<slug>/<key>/<requires>:"<reason>"`, `<requires>` with its `:` written `=` (`null`, `value=disputed`, `number=-5`), or the wildcard `@*` |
| `AC_PRECONDITION_PLANNED` | warn, one per row | — |
| `AC_PRECONDITION_NO_SOURCE` | warn, once per initiative: no scanned row found an `@Entity` class or a Liquibase changelog | — |

An `AC_PRECONDITION_UNREACHABLE` message reads `specs/<slug>.md:<line> '<criterion excerpt>' needs
<key> <requires>, but <file>:<line> declares it NOT NULL | allows only <constants> | is an integer
column with min/max <n> (pinned|unpinned). Fix: … Accept: --accept …`. Spec text in a message has
`"` replaced by `'`, every `--` shortened, and `|`, CR and LF removed; the instance token is read
only from the trailing accept command, and it holds no criterion text, so an accept survives an
AC extension but not a change of key or value. The code-wide form is refused.

**Info line.** Unchecked rows are not findings. Each run writes one
`META|ac-precondition|done|<c> checked, <u> unchecked, <p> planned, <i> input[: <details>]` line,
before its findings, where `<details>` lists up to 300 characters of `<slug>/<key> (<reason>)`.
For a missing entity or field the reason names up to three nearest names, for example
`invoice-list/invoices.status (entity not found; nearest: invoice)`.

**Revise and body.** Draft revise may update a row's Criterion cell when it extends that AC (the
AC guard still allows only keep and extend). Any change to the sorted `(Key, Mode, Requires,
Basis)` rows, or `None.` turned into a table, is refused as `FROZEN_CHANGED preconditions
changed`. A Criterion cell left stale after an extension passes the revise guard and comes back
from the readiness Crosscheck re-run as `AC_PRECONDITION_TABLE_INVALID` (`criterion not
found`). A legacy initiative keeps the section frozen. Ticket bodies never carry the table.

**Not checked.** Preconditions the spec does not declare; `input` rows; names that differ from
the code beyond case and `_`; fields on a `@MappedSuperclass`, `@Embeddable`, Lombok-generated
or record component, or mapped in `orm.xml`/`hbm.xml`; changelog include and changeset order;
tables touched by unmodelled changes; ordinal, converted or constructor-valued enums;
nullability only a Java primitive implies; database check constraints, enum types, triggers,
defaults and computed columns; config-driven limits (`application.yml`,
`@ConfigurationProperties`); whether a `spec:` Basis spec really changes the schema; visibility
across threads, transactions or async boundaries.

**Follow-ups, decided after the live check.** Weak facts (`@NotNull`, `@Column(nullable/length)`,
Bean Validation) as warnings; `length:<n>` with `varchar(n)`; decimal scale and precision;
Liquibase YAML, JSON and SQL changelogs; an under-declaration keyword tripwire; a second stack
(Flyway SQL, Kotlin JPA, a non-JVM ORM); a headless per-instance accept.

### Goldfish review: a context-withheld lens before Review

planner-goldfish-review. **Opt-in:** `PLANNER_GOLDFISH_REVIEW=true` (default `false`). The
Review agent re-reads appraisal, discovery and architecture before it critiques
`proposal.md`, so a gap the proposal inherited from them is a gap the reviewer shares. The
goldfish lens is a second reviewer that never saw how the plan was produced.

**Wiring.** `planner_dispatch_gate pre <INIT> Review` calls `planner_goldfish_due` after
every other `pre` check passed. When a run is due it prints one line,
`SPAWN NEXT=planner_goldfish_next APPLY=planner_goldfish_apply TIMEOUT=<ms>`, and SKILL.md
step 1 runs the step 1e spawn-list loop with those, passing `timeout_ms` = `<ms>` to the
spawn (description `lens: <INIT>`). Otherwise it prints nothing, so a flag-off run's
stdout and the halt goldens are unchanged; only the one `skip … DISABLED` line is new. A
halt of an earlier `pre` check (an open Specify decision) prints no `SPAWN` line and
writes no goldfish line. The Consensus prompt carries `planner_goldfish_consensus_rule`
directly after step 4's Readiness bullet. Run telemetry assigns a `lens: <INIT>`
transcript to the first Review attempt that started at or after its end (5s grace).

**When it runs.** Just before the Review agent, once per proposal version: `sha12` is the
first 12 hex digits of the sha256 of `artifacts/proposal.md`. `planner_goldfish_due`
decides, in order: a terminal goldfish line for this `sha12` already exists (not due); a
valid result for it is already on disk, after a crash (recorded `done`, no spawn); the
flag is off (`META|goldfish|skip|<sha12> DISABLED`); `proposal.md` is missing or empty
(`fail … NOT_RUN no-proposal`); both attempts were handed out and none was recorded
(`fail … NOT_RUN no-result`); otherwise due. The decision is recorded, so a resume or a
Review retry never re-decides or re-spawns it. A new proposal version is due again, and
every version's lines are kept (`goldfish` is in `PLANNER_REPEATABLE_META_STEPS`).

**Inputs.** `planner_goldfish_next` copies proposal.md to `goldfish/input/proposal.md`,
writes `goldfish/prompt.txt`, records `start|<sha12> attempt=<n>` and prints one spawn-list
line (`<INIT>\tlens\tticket-planner:goldfish-review-agent\t<prompt>\t<result>`). The prompt
names only the input copy, the absolute path of every git repository directly under
`REPOS_ROOT` (dot-directories such as `.ticket-auto/` left out) and the result path. It never
names the idea, the intent, appraisal, discovery, architecture, the specs, `review.md` or
`REPOS_ROOT` itself. The agent has `tools: Read, Grep, Glob, Write` (no Bash), and every
Grep and Glob call must pass `path` = one of the listed repositories.

**Withholding is best-effort.** The prompt, the tool scope and the `## Files Read` tripwire
enforce it, not a sandbox: Read can still open any path. A `## Files Read` entry under
`.ticket-auto/` other than the input copy (or the result itself) makes the result
`contaminated`. The list is self-reported; bash does not read transcripts.

**Result.** `<state_dir>/goldfish/review-goldfish.md`, outside `artifacts/`:
`**Proposal:** <sha12>`, `## Findings` with `None.` or at most 8 headings
`### G<n> — <blocker|major|minor|nit> — <title>` ranked by severity, then `## Files Read`.
`planner_goldfish_parse` is fence-aware and CRLF-tolerant; it prints `ok <N> <ids|->[ capped]`
or `malformed <reason>`. More than 8 findings keeps the first 8 and adds `capped`; gaps in
numbering are allowed; a duplicate id is malformed.

**Not run is recorded, never zero findings.** `planner_goldfish_apply` writes
`done|<sha12> findings=<N> bm=<blocker and major ids>` for a valid result. A missing, empty,
malformed or contaminated result is a failed attempt: the file is deleted and
`warn|<sha12> attempt=1 <reason>` keeps the run due; the second failure writes
`fail|<sha12> NOT_RUN <reason>`. A proposal edited between NEXT and APPLY gives
`NOT_RUN proposal-changed` for the old version. Reasons: `no-result`, `malformed:<why>`,
`contaminated:<path>`, `no-proposal`, `proposal-changed`. A `fail` on a META step is not a
phase failure: position derivation and Review's retry budget ignore it, and Review runs either
way.

**Timeout.** Each spawn gets `timeout_ms` = `PLANNER_GOLDFISH_TIMEOUT` (seconds, default 600)
× 1000 (`planner_goldfish_timeout_ms`). A timed-out agent leaves no result, so the worst case
is two timeouts before Review starts.

**Status line.** `planner_goldfish_status <INIT>` prints one line from the latest terminal
line: `Goldfish review: ran — <N> finding(s), proposal <sha12>, see goldfish/review-goldfish.md`,
`Goldfish review: NOT RUN — <reason>. Its findings are unknown, not zero.` (reason `no record`
with no line at all), or `Goldfish review: disabled`.

**Dispositions.** Consensus copies the status line as the first line under
`## Goldfish Findings Addressed`, then writes one `### G<n> — <severity> — <title> — <disposition>`
per blocker or major finding. Minor and nit findings may share one `Minor/nit G<a>, …: deferred`
line. The dispositions are `accepted`, `rejected (<why>, covered in <proposal § | spec <slug> |
upstream artifact § | code path>)`, `deferred` and `clarified` (add the fact to proposal.md; only
for a fact that exists in an upstream artifact and in no spec or proposal section). After
`NOT RUN` or `disabled`, nothing else goes under the heading.

**`GOLDFISH_UNADDRESSED` (Crosscheck, warn only).** `planner_crosscheck_goldfish`
(`lib/planner-crosscheck-goldfish.sh`, after the AC precondition family) emits at most one
warning naming each `bm=` id of the latest `done` line that has no disposition heading in that
section, and `status line missing` when the section has no `Goldfish review:` line. A
disposition is the first word of a ` — ` segment after the id: `accepted`, `rejected`,
`deferred` or `clarified`. Headings outside the section and fenced lines do not count; minor
and nit findings are never checked. Without any terminal goldfish line the family is silent,
so legacy initiatives and the halt goldens are unchanged. It never blocks.

### Resolving against the ref Discovery explored, not whatever REPOS_ROOT is now ([#217](https://github.com/willard-pro/claude-plugins/issues/217))

REPOS_ROOT is a shared checkout — it can move to a different branch between
Discovery and Crosscheck (another terminal, another initiative's pipeline, an
operator). Left unaddressed, the citation linter resolves against whatever the
live checkout happens to be on *right now*, which produces
`CITATION_UNRESOLVED`/`CITATION_LINE_OUT_OF_RANGE` findings indistinguishable
from a genuinely bad citation — confirmed live on two initiatives (VS-2, VS-3),
worked around both times by hand with a throwaway worktree.

The fix: Discovery records the ref it actually explored per repo —
`META|discovery|repo-ref|<repo>@<branch>@<sha>` (`<repo>` is the path relative to
REPOS_ROOT, e.g. `microservices/foo`; a bare name from an older initiative is
resolved by searching REPOS_ROOT for exactly one git checkout of that name, #500)
— and `planner_crosscheck_citations`
(`lib/planner-crosscheck-citations.sh`) reads it back via
`planner_crosscheck_repo_ref_setup` (`lib/planner-crosscheck-repo-ref.sh`) before
resolving any citation. For any repo whose live checkout no longer matches the
pinned sha, it creates (or reuses) an isolated `git worktree` alongside the live
repo — `<live-repo-dir>-crosscheck-<ref>-<short-sha>` — and excludes the live
copy from resolution for the duration of that Crosscheck run, so citations
resolve against the worktree instead. The live checkout is never touched. This is
best-effort: a repo Discovery recorded no ref for, or one whose worktree creation
fails, silently falls back to resolving against whatever the live checkout has.

**Hard rule: the planner never runs `git checkout`, `git switch`, or `git reset`
against a REPOS_ROOT repo — anywhere, in any phase.** It may only read from a
REPOS_ROOT repo, or create a worktree alongside it. This is enforced by
convention in every phase prompt that touches REPOS_ROOT (see Discovery's
prompt in `planner-phase-prompts.sh`) since the planner's own agents are the
only thing that could violate it — there is no live checkout mutation path in
the deterministic bash libraries to guard against.

## Refinement

Like Crosscheck, Refinement is not an agent phase — SKILL.md's dispatch-loop step 1b
runs it directly (`lib/planner-refinement.sh`), and it has no entry in
`planner_prompt_for_phase`. It sits between Ticket Gen and Completed
(planner-refinement-phase) and is the phase that answers a question the
deterministic DoR check alone cannot: whether the criteria are the *right*
ones, whether requirements contradict each other, or whether an autonomous
agent could build the ticket without asking a human.

For each child of the epic:

1. **Deterministic** — `check_ticket_ready` (ticket-auto-pipeline's
   `dor-check.sh`) against the ticket's local `planner/body.md` (written by
   Ticket Gen; fetched once from Linear, read-only, if somehow missing), run
   strict: `DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true` as a call prefix,
   so missing/unseeded test data and Verification Plan gaps are hard here even
   where the host keeps them advisory (planner-test-data-derivation).
2. **Semantic** — unless `PLANNER_REFINEMENT_SEMANTIC=false`, two
   `ticket-auto-pipeline:dor-semantic-agent` spawns: a **scan** of the body
   that never sees the deterministic result, then an **audit** of that
   result. Bash parses and applies both via `dor-semantic-parse.sh` /
   `dor_semantic_apply`. A blocking semantic finding joins `ready.missing`
   as a `SEMANTIC_*` code, exactly like a deterministic hard code.

Blocking is **per ticket** — the epic manifest is stamped `dispatch=true`
once every child has a verdict (deterministic, and semantic when enabled),
whatever that verdict is. Fleet dispatch already refuses a not-ready child
individually, so a held ticket does not stop its ready siblings from
dispatching. The planner itself is stricter: while any child is not ready,
Refinement halts (no `Refinement|gate|done`, no retry-budget consumption —
same "content decision, not a transient failure" treatment as a Crosscheck
halt) and the run does not advance to Completed.

A halt prints a report per not-ready ticket: its deterministic codes, its
round, each semantic finding with its quote and label (`Blocking (new)`,
`Blocking (carried since round <k>)`, `Structural drift (blocks)`,
`Unverified finding`, `Advisory finding`), a `Demoted (does not block):` list,
codes the evaluator believes the deterministic check missed, and every
deterministic code the evaluator disputes with its reason plus the exact
`dor-check.sh --waive` command that releases it. A ticket with a blocking,
non-structural, verified finding also gets a `Converge (no rescan):` hint.
After the report, `## Demoted findings on ready tickets` lists what was
demoted on tickets that did pass. `/ticket-planner resume <INIT_ID>`
re-enters Refinement and reuses every cached verdict whose body and evaluator
version are unchanged — only a ticket whose `body.md` changed, or whose
evaluator version is stale, is re-evaluated.

**Rounds and convergence** (planner-refinement-convergence). Each new body a
ticket is scanned on is one round, counted per ticket in `ready.lineage`.
Every finding has an id (code + anchor section or acceptance-criteria item +
normalised quote) and is labelled `new`, `carried` or `drift`:

- **Round limit.** From round `PLANNER_REFINEMENT_MAX_ROUNDS + 1` (default 2,
  so from round 3) a non-structural semantic finding is stored as advisory
  with `demoted: round-limit`. The limit bounds blocking, not scanning.
- **Drift.** From round 2, a new id on an unchanged unit that holds no open
  carried finding is evaluator drift, and is demoted (`demoted: drift`).
- **Structural codes** — `NEEDS_HUMAN_DECISION`,
  `CONTRADICTORY_REQUIREMENTS`, `UNSTATED_DEPENDENCY`, `INTENT_AC_MISMATCH`
  (`DOR_SEMANTIC_STRUCTURAL_CODES` overrides the list) — are never demoted by
  the round limit, drift or converge. A structural code on an unchanged
  section prints as `Structural drift (blocks)`. The deterministic codes
  (test data included) and the bash-owned `SEMANTIC_*` codes are not touched
  either.
- **Reset.** A rewrite that changes 50% or more of the non-inert sections
  (`DOR_SEMANTIC_ROUND_RESET_SHARE`) restarts the ticket at round 1.
- **Scoped rescan.** An edit confined to the inert sections (default only
  `Related Tickets`, `DOR_SEMANTIC_INERT_SECTIONS`) with no finding anchored
  there rebases the verdict instead of staling it, and does not count as a
  round. Any other stale verdict is rescanned with the changed sections named
  in the prompt.
- Each round writes one `META|refinement-round|done` trend line per ticket and
  body hash (`round=`, `new=`, `carried=`, `drift=`, `resolved=`,
  `unverified=`, `reset=`).
- The evaluator is now `dor-semantic-v4` (dor-semantic-paraphrase). An
  unchanged v2 verdict is migrated in place at the start of the scan, and an
  unchanged v3 verdict is kept as current
  (`dor_semantic_evaluator_compatible`), so only tickets edited since are
  rescanned.
- Each scan writes a `PARAPHRASE` — the one change the ticket makes, in the
  evaluator's words — stored as `ready.semantic.paraphrase`. The halt report
  prints it as `Paraphrase:` above a ticket's findings. A part of the ticket
  that describes a different change is `INCOHERENT_CHANGE`, advisory-only:
  it never blocks, and the advisory summary (and the halt report's
  `## Advisory incoherent-change findings` section) lists it with the
  ticket's paraphrase.

Demoted and other advisory findings are not lost: ticket-auto appraisal
writes them into the ticket's notes as a `## Refinement Carry-over` section
(`SCOPE_AMBIGUOUS` as a `[needs-human]` Open Question, `MISSING_CORE_AC` as a
`### Test candidates` entry ticket-implement tests and ticket-verify checks,
the rest `[agent-resolvable]`).

**Converge.** `/ticket-planner resume <INIT_ID> --converge --only <TID[,…]>
[--by <name>]` demotes the named tickets' remaining blocking, verified,
non-structural findings on the stored verdict (`demoted: converge`, stamped
with the operator) without a rescan, and logs
`META|refinement-converge|done|<TID> demoted=<n> by=<op>`. A ticket whose
verdict is missing, stale, unavailable, for an edited body or from another
evaluator is refused (`META|refinement-converge|skip`) and scanned as usual;
re-run converge after it. Converge runs after the deterministic scan and
before the semantic passes.

**Audit demotion (off by default).** Under `PLANNER_REFINEMENT_AUDIT_DEMOTE=true`,
an audit that disputes an allow-listed heuristic code (`VPLAN_ROW_GAP`,
`VPLAN_UNVERIFIABLE`, `AC_VAGUE`, `AC_IMPLEMENTATION_ONLY`,
`NAV_PATH_MISSING`) and quotes the code's own section verbatim moves that code
from `missing` to `advisory`, recorded in `ready.demoted` and bound to the body
hash. Only the first audit for a body hash counts, and more than
`DOR_AUDIT_DEMOTE_MAX` (default 2) qualifying codes on one ticket is refused as
a blanket dispute. Each demotion logs `META|refinement-dispute|done`; a refusal
or failure logs `META|refinement-dispute|warn`. A demoted code gets no waive
command in the report, and fleet-controller drops it from its `disputed` hints.

**Body drift.** Ticket Gen records a baseline hash of Linear's own rendering of
each description (`planner/linear-baseline.sha`; when Linear stores a
different rendering, `body.md` takes Linear's text and a
`META|ticketgen|warn` line says so). Unless `PLANNER_REFINEMENT_DRIFT_CHECK=false`,
every Refinement scan reads each child from Linear once and compares:

- Linear changed, `body.md` did not → **adopted**: `body.md` takes the Linear
  text, the baseline moves, `META|refinement|step|<TID> body adopted from Linear
  [<old8>→<new8>]` is logged, and it counts as a new body.
- `body.md` and Linear were both edited differently, or there is no baseline and
  they differ (`conflict`), or only `body.md` was edited (`local-ahead`) →
  blocking `BODY_DRIFT`. Both edited the same way → the baseline is re-recorded.
- The read failed → `META|refinement|warn|<TID>: Linear read failed (n/max) …`;
  after `PLANNER_REFINEMENT_DRIFT_MAX_FAILS` (default 3) in a row, blocking
  `BODY_UNVERIFIED`. A recorded `BODY_DRIFT` survives a failed read.

`BODY_DRIFT` and `BODY_UNVERIFIED` cannot be waived. The release is
`/ticket-planner resume <INIT_ID> --refresh-bodies` (copy a local edit into
Linear first if you want to keep it), which the halt also offers as a headless
`flag:refresh-bodies` question. The same check runs in ticket-auto appraisal:
a ready ticket whose Linear text drifted gets a `[needs-human]` Open Question
and a `META|body-drift|info` line. `--refresh-bodies` and `--converge` also
work on a Completed initiative: the resume re-runs Refinement on the refreshed
and named children only, writes `META|refinement-after-completed|done`, and
writes no phase line.

An initiative planned before this change shipped (its log already carries
the retired `TicketGen|dispatch-gate|done` line) skips Refinement entirely
— it has no local body and its epic may already be dispatching.

## Draft readiness

Draft readiness is not a phase. It runs after Crosscheck passes and on every Epic Gen
entry, before the first Linear write (SKILL.md step 1d, `planner-draft-readiness-gate.sh`).
For each spec it composes the ticket body TicketGen would write, with `DRAFT` as the epic
and `DRAFT-<slug>` as sibling ids, and runs the same deterministic DoR check and the same
`dor-semantic-agent` scan and audit that Refinement runs on real tickets. A blocking
finding halts the run with `DRAFT_NOT_READY` while nothing exists in Linear. Per-spec
files live under `artifacts/draft-readiness/<slug>/` (`body.md`, `dor-result.json`,
`semantic.json`, `verdict` written last; revision history `spec.r<N-1>.md`,
`findings.r<N>.json`, `revise.r<N>.*` once the revision loop runs).

### Revision loop: reasons, assumptions, security

- **Reason class per finding.** At the end of the loop every demoted finding records why
  it was not fixed, judged per finding: `assumed`, `rebutted`, `revised`, `reverted` or
  `failed` from the rounds the finding was given to (highest of that order wins), else
  `revised` for a finding on a unit the last applied revision changed, else `untouched`
  (the evaluator raised it on text no revision changed). Logged as
  `META|draft-readiness|info|<slug> DEMOTED <CODE> round-limit|drift <class> <id>`.
- **Scoped rescan.** After a revision (or any edit) a draft's scan gets
  `--changed-sections` with the headings whose section hash changed since its last
  evaluation (`lineage.json`), as Refinement scopes its rescans. Not at
  `PLANNER_DRAFT_REVISE_MAX_ROUNDS=0`, and never with a heading only one of the two
  bodies has or one that does not look like a section name (that scan is a full scan),
  so spec text cannot reach the evaluator prompt as a heading.
- **No-source decisions become assumptions.** When a finding needs a product decision
  that no source states, the revise agent picks a conservative default instead of
  rebutting: one `- Assumption: <text>` row in the spec's `## Scope` (so it reaches the
  ticket body), a new or extended criterion that tests it, and an
  `ASSUMED <id> — <what> — assumption: "<text>"` disposition. The guard
  `ASSUMPTION_INVALID` reverts the round unless rows and dispositions match one to one
  (an ASSUMED line with no text fails), no assumption line appears outside `## Scope`,
  there are at most 3 per round of at most 40 words without `|`, `<`, `>`, backticks,
  `##`, links (`](`, `![`, `://`) or `@`, each has a testing criterion, and the finding is
  one of the round's and not a security finding. A finished round's revise file is bound
  to a hash recorded at finish (`revise.r<N>.sha`), so a later round cannot rewrite its
  dispositions to change a reason class. Old rows are kept by
  `SCOPE_DROPPED`. Bash logs `META|draft-revise|info|<slug> ASSUMED <CODE> <id> "<text>"`
  and gives the class `assumed` only for an applied round. The run stays hands-free; every
  assumption is listed in the pass output and the epic summary for a human to review.
- **Security findings are never drift-demoted.** A finding is security-relevant when
  its code, detail, quote or quote_b matches XSS, `innerHTML`/`outerHTML`/
  `dangerouslySetInnerHTML`, injection (not dependency injection), CSRF/XSRF, SSRF, path
  traversal or `../`, open redirect or redirect target, privilege escalation, auth or
  permission bypass, a missing authorization/role/ownership check, IDOR, cross-tenant
  access, hard-coded or plain-text secrets, unsanitised/unescaped/unencoded/unvalidated
  input, raw user input, user-controlled values, SQL queries, CORS, brute force or
  session tokens; or its detail (the evaluator's reason, never body text alone) names
  secrets, API or private keys, access tokens, passwords, credentials, PII or personal
  data, encryption, rate limiting or unvalidated tokens (`planner_draft_security_def`,
  case-insensitive, not env-overridable). It errs wide on purpose: a false hit costs one
  revise round, a miss lets a gap be assumed away or drift-demoted. Such a
  finding stays blocking when the lineage would call it drift, so the next revise round
  takes it while budget is left. Past the budget it is demoted `round-limit` like any
  non-structural finding (the loop stays bounded and hands-free), but never silently: a
  `META|draft-readiness|warn|<slug> SECURITY <CODE> <id> "<quote>"` line, a
  "Security findings demoted at draft stage" block in the pass output and halt report,
  and a `Security finding (review)` line in the epic summary. It reaches Refinement
  through the carried verdict like any demotion. The revise prompt marks such findings
  `security: yes`, and `ASSUMED` is refused for them.
- **Audit MISSED entries.** The audit can name a gap the scan missed (`MISSED_n_CODE`/
  `REASON`, stored as `missed`). An entry whose code is a known, blocking,
  non-structural semantic code and whose code or reason matches the security rule joins
  the findings as a blocking one (`origin: "audit-missed"`, id `m-<hash>`, no quote), so
  it takes the security path above: the next revise round, else a round-limit demotion
  shown as a security finding (its reason stands in for the quote). Every other entry
  (non-security, structural or unknown code) blocks nothing and is listed under "Audit
  advisories (gaps the scan missed; they do not block)" in the pass output and the halt
  report; Refinement's advisory summary lists the real tickets' `missed` entries as
  `Advisory (does not block) <TID> [Security ]MISSED <CODE>: <reason>`.
- **A revision that creates a contradiction is reverted.** The revise prompt lists every
  section the agent may not edit (Technical Context included) as one it must not
  contradict. As a deterministic backstop, the first evaluation after an applied
  revision is compared with the evaluation the round started from: a verified blocking
  structural code (`CONTRADICTORY_REQUIREMENTS`, …) on a unit the revision changed that
  the pre-round evaluation did not have reverts that spec's revision
  (`reverted:REVISION_REGRESSION`, reason class `reverted`, a
  `META|draft-revise|fail|<slug> round=<N> REVISION_REGRESSION "<codes>"` line), restores
  the pre-round verdict and re-runs Crosscheck, instead of halting on a finding no round
  can fix. The pre-round copy (spec, draft body, lineage, result files) lives outside the
  workspace under `PLANNER_DRAFT_SNAPSHOT_ROOT/<INIT>/eval/`, like the round plan, so no
  agent can forge the baseline or the spec the revert restores; the gate drops it when
  it closes.

### Refinement carry-over

A spec that passed draft readiness has already been scanned, audited and possibly
revised. A fresh Refinement sample would re-block on findings the gate resolved or
demoted, so `planner_refinement_scan` carries the draft verdict over to each ticket that
has no semantic verdict yet (`planner-draft-carryover.sh`):

1. **Import.** The ticket's `body.md` (Linear's rendering, stored by
   `planner_ticketgen_record_baseline`) is compared with the draft after normalisation:
   the epic id, sibling ids and their Linear links are rewritten to draft tokens, the
   Planner Context `Generated` value to a fixed token, Linear's markdown re-rendering is
   undone (`planner_draft_render_normalise`: `*` list markers → `-`, `[X]` → `[x]`,
   table separator rows → `|---|` per column, backslash-escaped punctuation unescaped and
   `**` dropped outside inline code, blank lines dropped outside fences — never words,
   values, inline code or fenced blocks), then CRLF, trailing whitespace and trailing
   blank lines are normalised. The carry-over's unit and section hashing uses the same
   text, so a rendered-but-unchanged unit never reads as changed. When the draft verdict is `ready`, the two
   are equal and the evaluator matches, ticket-auto's `dor_semantic_import` stores the draft verdict on the ticket.
   Quotes are rewritten to real ids, and a finding whose quote no longer locates in the
   real body is dropped (never stored unverified). No agent is spawned and no round is
   added. Logged as `META|refinement-draft-import|done|<TID> from=DRAFT-<slug> round=<n> demoted=<k> dropped=<d>`.
2. **Draft-passed scan.** When the bodies differ or the import is refused (draft
   verdict `ready`), or the draft is `blocked` with an accept bound to the current drafts
   (importing it would re-halt Refinement on the accepted findings), the ticket's prior
   lineage is seeded from the draft (the gate's `lineage.json`). For an accepted draft,
   the findings the operator accepted leave the seeded prior, so a re-raise on an
   unchanged unit is demoted rather than carried as blocking. Each unit whose text is equal
   modulo ids gets the real body's hash, so it reads as unchanged. The normal scan then
   runs, and its apply uses `DOR_SEMANTIC_PRIOR_PASSED=true`: no round reset, every
   verified non-structural finding becomes advisory (`demoted: draft-passed`), and a new
   structural finding on an unchanged unit becomes advisory
   (`demoted: draft-passed-structural`, `demote_reason: unchanged-unit`). A structural
   finding on changed text still blocks. Deterministic codes, unverified findings and
   `SEMANTIC_*` codes are untouched. Logged as
   `META|refinement-draft-import|skip|<TID> <reason> draft-passed round=<n>` (`<reason>`: `not-equivalent`, `accepted`, `no-semantic`, `equivalence-unknown` or `import-refused:<rc>`).

A ticket that already has a semantic verdict is never touched, so a `resume` after
Refinement keeps its own lineage. A spec whose draft never passed (gate skipped by
`--until Crosscheck`, a stale verdict, or no draft directory) takes the old path.

### Epic summary

When any spec was revised or had findings demoted, Epic Gen appends a
`## Revised by draft readiness` section to the epic description (after humanizing, in
bash): per spec, the revision rounds used with their statuses, criteria added and
extended, every assumption the revisions added (`Assumption (review)`), and each demoted
finding with its code and reason class (security findings prefixed
`Security finding (review)`). It goes on the epic
only, never into a ticket body, so ticket body hashes and the import equivalence are
unaffected.

### Draft readiness variables

Read each time the gate or Refinement runs, not persisted at argument parsing.

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_DRAFT_REVISE_MAX_ROUNDS` | 2 | Spec revisions per spec before the remaining non-structural findings are demoted (`round-limit`). `0` = halt-only gate |
| `PLANNER_DRAFT_SPAWN_BUDGET` | 8 × spec count | Draft-stage agent spawns (scan, audit, revise, retries) before the gate halts with `DRAFT_NOT_READY` / `SPAWN_BUDGET` |
| `PLANNER_DRAFT_DEMOTE_CEILING` | 0.5 | Share of specs ending with a `reverted`/`failed` demotion above which the gate halts with `DEMOTE_CEILING` |
| `PLANNER_DRAFT_EXTEND_MAX_WORDS` | 25 | Words a revision may append to an existing criterion |
| `PLANNER_DRAFT_VERDICT_IMPORT` | true | `false` turns the Refinement carry-over off, so Refinement takes an independent semantic sample (two spawns per ticket) |

## Determinism Boundary

| Bash (deterministic) | Agent (LLM) |
|---------------------|-------------|
| State log parsing and position derivation | Per-phase content reasoning |
| Phase transition validation | Appraisal scope decisions |
| Entity idempotency (intent→check→create) | Discovery code path selection |
| Dependency acyclicity (`tsort`) | Architecture approach evaluation |
| Shared-branch recommendation (heuristic) | — |
| Planner Context block generation | Proposal and spec authoring |
| Directive block generation (branch naming) | — |
| Confidence signal derivation | Review critique generation |
| Pre-creation validation (`planned-ticket-check.sh`, `planned-ticket-body-check.sh` — [#285](https://github.com/willard-pro/claude-plugins/issues/285)) | Ticket body content, humanized (issue #285) |
| Auto-dispatch detection and enqueuing | Re-planning decisions |
| The Crosscheck phase (`planner-crosscheck.sh`) | — |
| Refinement's own decisions: which tickets need a semantic pass, the deterministic DoR verdict, the epic dispatch stamp, halt vs. proceed (`planner-refinement.sh`) | Refinement's per-ticket semantic judgement (the two `dor-semantic-agent` spawns) |

The router never reasons about content. Phases never mutate state directly (they write log entries the router reads).

## Configuration

### Planner variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_CONFIDENCE_THRESHOLD` | 0.85 | Confidence at or above which TicketGen writes `Pre-approved: true` in the Planner Context block (a block field, not a label). Pre-approval only: ticket-auto-pipeline's `planned-ticket-check.sh` low-confidence floor is the separate `PLANNED_TICKET_MIN_CONFIDENCE` (default 0.5) |
| `PLANNER_IDEA_MAX_LENGTH` | 2000 | Maximum idea length in chars (truncated with warning) |
| `PLANNER_TSORT_TIMEOUT` | 30 | Seconds before timing out dependency graph sort |
| `PLANNER_PHASE_TIMEOUT` | 600 | Seconds before timing out a hung phase agent |
| `PLANNER_REQUIRE_INTENT` | false | When `true`, raw idea strings are refused — `plan` must be given a grill-me intent file |

The `PLANNER_REFINEMENT_*` and `PLANNER_DRAFT_*` families are read each time Refinement or the draft gate runs, so set them in the environment of that run. Every other planner variable is read **once, in the shell that parses arguments**, and its effect is persisted to the state log there and then; setting one after a run has started has no effect — re-invoke with the corresponding flag instead (see [Why the controls live on disk](#why-the-controls-live-on-disk)).

### Cross-plugin variables (fleet-controller)

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_AUTO_DISPATCH` | false | Must be `true` to enable automatic dispatch from detection |
| `FLEET_MAX_CONCURRENT` | 3 | Max concurrent pipelines for dispatch |
| `FLEET_DRY_RUN` | false | When `true`, dispatch is preview-only |

### Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `REPOS_ROOT` | (required) | Root for initiative directories and repo discovery. No fallback: state, intent and Crosscheck helpers fail with a clear error when it is unset rather than guessing `~/repos` ([#459](https://github.com/willard-pro/claude-plugins/issues/459)). Phase prompts interpolate the dispatcher's value as a literal `export REPOS_ROOT=...` in every preamble |
| `LINEAR_API_KEY` | (required) | Linear API authentication token |
| `LINEAR_TEAM_ID` | *(unset)* | Team key, name or id to create on, the fallback for `--team`. Unset resolves to the workspace's only team; several visible teams is an error naming them, never a guess |
| `LINEAR_API_URL` | `https://api.linear.app/graphql` | Linear GraphQL API endpoint |
| `LINEAR_MAX_RETRIES` | 3 | Max Linear API call retries |
| `LINEAR_RETRY_DELAYS` | `1 2 4` | Retry backoff delays in seconds |
| `CLAUDE_PLUGIN_ROOT` | (resolved at runtime) | Plugin cache location for library sourcing |

### The create gate and stop conditions

Phases 1–7 write only to disk. Epic Gen (phase 8) is the first Linear write, and the
dispatch loop **stops on that boundary unless the initiative has been explicitly
authorized to cross it**. That default is a constant, not runtime state: there is no
flag whose absence permits creation, and nothing that has to propagate correctly for
the safe outcome to hold.

Crosscheck (phase 7) runs unconditionally regardless of authorization — it's
artifact-only, so there's nothing for the gate to protect there — and a blocking
finding halts the loop before the gate is even reached (see [Phase Details](#phase-details)).

Crossing the boundary takes a separate invocation:

```
/ticket-planner plan "…"                  # → Appraisal … Crosscheck, nothing in Linear
/ticket-planner resume INIT-42 --create   # → Epic Gen, Ticket Gen, Refinement, Completed
```

`--create` is read once, at the top of that invocation, and written to the state log
as `META|create-authorized|done` **before the loop starts**. Every later check reads
it back from disk, so the authorization survives a crashed router and the process
boundary between phases — the same durability the retry budget gets from `fail`
entries. A `resume` after a crash mid-Epic-Gen proceeds without re-passing the flag.

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_UNTIL` | *(unset)* | Phase to stop after. Read **once, during argument parsing**, and persisted as `META|stop-after` |
| `PLANNER_REVIEW_HOLD` | false | When `true`, stop after Review — folded into `--until Review` at parsing time |
| `PLANNER_MAX_PHASE_RETRIES` | 2 | Max retries per phase before failing the run |
| `PLANNER_REFINEMENT_SEMANTIC` | true | When `false`, Refinement skips the `dor-semantic-agent` spawns entirely and gates on the deterministic verdict alone (planner-refinement-phase) |
| `PLANNER_REFINEMENT_PARALLEL` | 4 | Max concurrent per-ticket semantic-pass batches in Refinement |
| `PLANNER_REFINEMENT_MAX_ROUNDS` | 2 | Rounds in which a non-structural semantic finding may block; later rounds store it as advisory (`demoted: round-limit`) (planner-refinement-convergence) |
| `PLANNER_REFINEMENT_AUDIT_DEMOTE` | false | When `true`, an audit dispute with a verified quote demotes an allow-listed heuristic deterministic code to advisory (`ready.demoted`) |
| `PLANNER_REFINEMENT_DRIFT_CHECK` | true | When `false`, Refinement does not compare each child's Linear description against its TicketGen baseline |
| `PLANNER_REFINEMENT_DRIFT_MAX_FAILS` | 3 | Consecutive failed Linear reads before the blocking `BODY_UNVERIFIED` |

`PLANNER_CONSENSUS_HOLD` was removed: stopping before the first Linear write is now
the default and needs no variable.

Both controls resolve through a single function, `planner_stop_phase <initiative_id>`,
which returns the **earliest** applicable stop point — `--until TicketGen` on an
unauthorized initiative still stops at Crosscheck. There is one stop condition in the
dispatch loop, not several, so the forms cannot diverge.

Two further guards sit under the stop check, because the failure being prevented is
silent entity creation: `planner_create_gate_check` refuses to dispatch a write phase
without authorization, and the Epic Gen and Ticket Gen prompts re-verify it from the
state log inside the agent.

Stopping is not a distinct mode. The router holds no in-memory state, so a stop is
just "quit dispatching", and `resume` is the continuation — the same path crash
recovery already uses.

A plain `resume` on an initiative sitting at the gate does not create anything. It
reports the position and the `--create` command, and stops. `--until` accepts any phase
name from `planner_phase_sequence`; an unknown phase, or one the initiative has already
passed, is rejected with the valid names (or the current position) in the message.

### Plan and resume flags

Flags are accepted by both `plan` and `resume`. Every one of them is **written to the
state log the moment it is parsed** and re-read from there wherever it is used — none
of them is carried in an environment variable, because the dispatch loop spans a fresh
process per phase and an `export` does not survive that (#144).

| Flag | Effect |
|------|--------|
| `--create` | **`resume` only.** Authorize Linear creation, then run Epic Gen → Ticket Gen → Completed |
| `--accept CODE:"reason"` | **`resume` only.** Mark a Crosscheck finding genuine-and-expected; non-blocking on the next Crosscheck run. Repeatable. `PARAM_LITERAL` takes only the per-literal form `PARAM_LITERAL@<slug>:"<literal>"` |
| `--shared-branch` | Force a shared-branch directive on the epic regardless of the heuristic |
| `--no-shared-branch` | Suppress the shared-branch directive regardless of the heuristic |
| `--until <Phase>` | Stop the dispatch loop once `<Phase>` completes; `resume` continues |
| `--dry-run` | Accepted and redundant — stopping before Linear is already the default |
| `--team <key\|name\|id>` | Linear team to create on (overrides `LINEAR_TEAM_ID`) |
| `--project <name\|id>` | Linear project for the epic and its tickets |
| `--no-project` | File the epic and its tickets with no Linear project, deliberately — silences the project gate |
| `--milestone <name\|id>` | Linear project milestone (needs `--project` when given by name) |
| `--no-tests-rule[=true\|false]` | Record that the project forbids implementation from writing tests (#503): Crosscheck then does not count a spec that seeds its own test data as an owner, so a synthesized test-data spec (or an `exists:`/`external:` Source) becomes mandatory. `=false` records the opposite. Without the flag, the first `plan`/`resume` detects it once from `REPOS_ROOT` CLAUDE.md files and records where it found it. Sticky — persisted as the `no-tests-rule` config key. `PLANNER_NO_TESTS_RULE` is the default, read once here |
| `--refresh-bodies` | **`resume` only.** Re-read every child's description from Linear — ready and waived tickets included — before Refinement re-evaluates. Only a ticket whose Linear text no longer matches its baseline is rewritten: `body.md` takes Linear's text, the baseline is re-recorded, and the ticket is re-scanned. A clean ticket is left alone, and waivers are kept. This is the release for `BODY_DRIFT` (a local edit and a Linear edit conflict) and `BODY_UNVERIFIED` (repeated failed reads), neither of which can be waived. A plain Linear edit over an unchanged `body.md` does not need it — every resume adopts that on its own. Also accepted on a Completed initiative. One-shot — consumed and cleared by this invocation, never sticky |
| `--converge --only <TID[,TID...]> [--by <name>]` | **`resume` only.** Release the named tickets from their stored semantic verdict without a rescan: every blocking, verified, non-structural semantic finding becomes advisory with `demoted: converge` and the operator's name. Structural codes, unverified findings, deterministic codes and the bash-owned `SEMANTIC_*` codes keep blocking. A ticket with no verdict, or a stale, unavailable, edited-since or older-evaluator one, is refused and logged as `META\|refinement-converge\|skip`. `--only` is mandatory (there is no epic-wide converge); `--only`/`--by` without `--converge` are rejected; `--by` defaults to `$USER` (`operator` when unset). Spawns no agent. Also accepted on a Completed initiative. One-shot — persisted as the `converge` config key and cleared once Refinement consumes it |
| `--answers <file>` | **`resume` only.** Apply an answers file to the open question round from `planner-stop-describe.sh`, then resume. Each answer becomes the flag it is bound to (`--create`, `--accept`, `--project`/`--no-project`, `--refresh-bodies`, a DoR waiver). See [Headless use](#headless-use---answers) |

The branch flags are optional. Supplying both together is an error. When neither is supplied,
the binary heuristic decides (≥ 3 tickets **and** dependency chain depth ≥ 2).

`--create` is rejected in `plan` mode. Authorizing creation is a separate, deliberate
invocation made *after* the artifacts exist and have been read — a single command that
both plans and creates would be the footgun this design exists to remove.

### Accepting a genuine Crosscheck finding (`--accept`)

Some blocking findings are correct about the artifacts but not defects — most often
`CARVE_SCOPE_LOST` when a ticket count was deliberately rescoped after Specify and the
rescope is already documented in `consensus.md` or a post-Consensus coverage-audit doc.
Before this flag existed the only way to unblock the create gate was hand-writing a
`META|crosscheck|accepted|...`-shaped line directly into `state.log` — undocumented,
easy to get wrong, and indistinguishable from an automated pass unless you already knew
to look for it (#222).

```
/ticket-planner resume INIT-42 --accept CARVE_SCOPE_LOST:"documented rescope, see consensus.md#tickets-6"
```

`--accept CODE:"reason"` is **`resume` only**, same restriction as `--create` — a
finding can only be accepted after Crosscheck has reported it. It is parsed and
persisted the same way `--create`/`--until` are: written to the state log as
`META|crosscheck|accepted|<CODE> <reason>` the moment it is parsed, before the dispatch
loop reaches Crosscheck again, so the decision survives the process boundary between
phases (the governing principle from #144 — see [Plan and resume flags](#plan-and-resume-flags) above). The
flag is repeatable — pass it once per code to accept more than one finding in the same
`resume`.

Once accepted, the code stays accepted for the life of the initiative; there is no
un-accept. On the next Crosscheck run, `planner_crosscheck_run` treats a finding whose
code was accepted as non-blocking — the create gate does not see it — but still writes
it to the state log as `META|crosscheck|accepted|<CODE> <message>` every time it
recurs, so it stays visible in `status` mode's Crosscheck findings section and in
`COMPLETED.md`'s Warnings section exactly like an automated pass or fail, with the
operator's reason attached. Only the code named survives — a new finding under a
different code still blocks normally.

`PARAM_LITERAL` is accepted one literal at a time, never by code:

```
/ticket-planner resume INIT-42 --accept PARAM_LITERAL@export-link:"15 minutes"
```

The quoted text must be exactly one unit literal. It is recorded as
`META|crosscheck|accepted|PARAM_LITERAL@export-link=time:900000 15 minutes`, and only a
finding in that spec with that canonical value becomes `accepted` (written with the
instance token first, `PARAM_LITERAL@<slug>=<canonical> <message>`). A new literal, or
the same literal in another spec, still blocks. `--accept PARAM_LITERAL:"…"` is refused
at parsing (rc 1, nothing written). Each finding message ends with its own accept
command. Headless callers get no accept for this code: the `CROSSCHECK_BLOCKED` block
asks one `param-literals` note instead.

The four ownership instance codes work the same way: `OWN_MULTI_WRITER@<key>`,
`OWN_MULTI_FIRE@<key>`, `OWN_NO_WRITER@<slug>/<key>` and `OWN_TRIGGER_UNOWNED@<slug>/<key>`,
each with a non-empty `:"<reason>"`; the code-wide form is refused.
So does `AC_PRECONDITION_UNREACHABLE@<slug>/<key>/<requires>` (planner-ac-code-precondition),
where `<requires>` is `null`, `value=<v>` or `number=<n>`.

**Wildcard.** `--accept <CODE>@*:"<reason>"` is valid for `PARAM_LITERAL`, the four
ownership instance codes and `AC_PRECONDITION_UNREACHABLE`. At `resume`, before the loop, it reads the `fail|<CODE>` lines of
the latest Crosscheck attempt and records one `accepted|<instance-token> <reason>` line per
distinct instance (for `PARAM_LITERAL`, `PARAM_LITERAL@<slug>=<canonical> <literal> — <reason>`).
It never writes `<CODE>@*`, so an instance first found by a later run still blocks. With no
current instance it is refused (rc 1, "no <CODE> finding in the latest Crosscheck attempt").

`--accept DRAFT_NOT_READY:"reason"` is not a Crosscheck accept: it passes a draft
readiness halt (SKILL.md step 1d) by writing `META|draft-readiness|accepted|<hash> <reason>`,
where `<hash>` covers the current drafts, so any spec edit re-arms the gate.

#### Why the controls live on disk

Every value that survives the dispatch loop correctly — the initiative ID, the idea,
the current phase, retry counts — survives by being re-derived from disk or re-supplied
as a literal argument, never by shell persistence. The loop is not one process: an
Agent tool call sits between every pair of phases, so each iteration runs in a fresh
shell and an `export` from argument parsing is gone by the next one.

The stop conditions and project/milestone flags were, briefly, the only pieces of state
that tried to cross that boundary via `export`, and they were the only pieces that were
broken — `--dry-run` silently did nothing (#144), the same root cause as the plugin-root
defect before it (#138). `test-planner-config-durability.sh` now runs each step in a
separate process so a regression fails a test rather than shipping.

### Projects and milestones

| Variable | Default | Description |
|----------|---------|-------------|
| `LINEAR_PROJECT` | *(unset)* | Default project name or id, the fallback for `--project`. Read once during argument parsing |
| `LINEAR_PROJECT_MILESTONE` | *(unset)* | Default project milestone, the fallback for `--milestone`. Read once during argument parsing |

The ref given is persisted as `META|linear-project`; Epic Gen resolves it to a UUID
against the team, records the result as `META|linear-project-id`, and Ticket Gen reads
that id straight back. The team itself follows the same path — `META|linear-team` →
`planner_linear_resolve_team_id` in Epic Gen → `META|linear-team-id`, reused verbatim by
Ticket Gen, because children on a different team from their parent epic cannot be fixed
without deleting and recreating them. The epic and every child therefore land in the same project off
a single name lookup, and no phase reads the variable from its environment.

Which project an initiative belongs to is an operator decision, so it comes from
configuration rather than agent judgement — it stays on the deterministic side of the
boundary. With both unset, no `projectId` is sent and the payload is byte-identical to
what workspaces that do not use projects saw before. A named milestone that does not
exist is an error; the planner does not create milestones.

The resolved ids are recorded at EpicGen as `EpicGen|project|done|project=… milestone=…`
so a later reader can tell where the initiative was filed without re-querying Linear.

## Headless use (`--answers`)

A caller with no terminal — an orchestrator running `claude -p`, a Slack bridge, a
script — cannot read the halt prose. It runs this loop instead:

1. **Describe.** `bash lib/planner-stop-describe.sh <INIT_ID>` prints why the run
   stopped, as a human-hold Schema-Version 2 block (`REASON`, `ROUND`, and one
   question per decision, each with an id, a binding and, for a closed choice,
   options). A run with
   nothing to ask prints one line: `REASON=COMPLETED`, `REASON=RUNNING` (just
   resume) or `REASON=FAILED_RETRY_EXHAUSTED`.
2. **Answer.** The caller collects answers and writes them to a JSON file: the
   block's `ROUND`, plus `id`, `value`, `answered_by`, `role` and `ts` per answer.
   The block format and the answers-file format are defined in
   `ticket-auto-pipeline/docs/human-hold-schema.md` § Schema-Version 2.
3. **Resume.** `/ticket-planner resume <INIT_ID> --answers <file>`.

| Stop (`REASON`) | Question binding | What the answer does |
|---|---|---|
| `CREATE_GATE` | `flag:create` | `yes` = `--create`. `no` records the round; the run stops at the gate again |
| `CROSSCHECK_BLOCKED` | `flag:accept:<CODE>` | the reason = `--accept CODE:"reason"`. `__skip__` declines |
| `CROSSCHECK_BLOCKED` (`PARAM_LITERAL`) | `note`, id `param-literals`, option `resolved` — replaces the code's `flag:accept` question | recorded only. The text names each undeclared literal and the terminal command `resume <INIT> --accept PARAM_LITERAL@<slug>:"<literal>"`; declare the value in `## Parameters` or change the spec, then resume |
| `CROSSCHECK_BLOCKED` (`OWN_MULTI_WRITER`, `OWN_NO_WRITER`, `OWN_MULTI_FIRE`, `OWN_TRIGGER_UNOWNED`) | one `note`, id `ownership-findings`, option `resolved` — replaces those codes' `flag:accept` questions | recorded only. The text counts each code, lists the instance tokens (up to 300 characters), says how to fix each kind and gives the terminal per-instance and wildcard accept forms; there is no headless accept. `OWN_TABLE_INVALID` and `OWN_EDGES_FAILED` keep the standard `flag:accept` question |
| `CROSSCHECK_BLOCKED` (`AC_PRECONDITION_UNREACHABLE`) | one `note`, id `ac-precondition-findings`, option `resolved` — replaces the code's `flag:accept` question | recorded only. The text gives the count, the instance tokens (up to 300 characters), the three fixes (change the criterion, Mode `input`, Basis `spec:<slug>`) and the terminal per-instance and wildcard accept forms; there is no headless accept. `AC_PRECONDITION_TABLE_INVALID` keeps the standard `flag:accept` question. With ownership findings in the same attempt, both notes are asked, each once |
| `CROSSCHECK_BLOCKED` (`CITED_ARTIFACT_UNRESOLVED`) | `consensus-answer:cited:<n>`, one per unanswered artifact | `exists:<where>`, `external:<who>` or `generate`, written into the `Answer:` field of consensus.md's `n`th `CITED_ARTIFACT:` question. Any other value, or one with `\|`, CR or LF, is `INVALID_VALUE`. Specs are not edited: a spec need whose `Source` disagrees is `CITED_ARTIFACT_SOURCE_MISMATCH` on the re-run. The code's `flag:accept` question is still offered |
| `CROSSCHECK_BLOCKED` (`TEST_DATA_IMPLIED`) | `consensus-answer:testdata:<slug>`, one per blocking spec, id `testdata-<slug>-<hash8>` | `none`, `generate: <desc>` (default `generate: <match phrase>`), `exists:<where>` or `external:<who>`, written as consensus.md's ``TESTDATA_CONFIRM: `<slug>` [<hash8>] — Answer: <value>`` line. `hash8` is re-derived from the spec's current trigger criterion at intake; a mismatch is `STALE_QUESTION` (exit 2, nothing written). The code's `flag:accept` question is still offered |
| `CONSENSUS_BLOCKED` | `note` | recorded only — fix the plan and change consensus.md's Readiness from `blocked` (or re-run Consensus); the gate re-reads consensus.md on resume |
| `PROJECT_GATE` | `flag:project` | a name or id = `--project`. `__none__` = `--no-project` |
| `REFINEMENT_HALT` (`BODY_DRIFT` / `BODY_UNVERIFIED`) | `flag:refresh-bodies`, id `refresh-bodies`, asked first; options `yes\|no`, default `no` | `yes` = `--refresh-bodies` on the resume. `no` records the round; the held tickets stay held. Its text lists each held `<TID> (<codes>)`. These codes get no `waive:` question — they cannot be waived |
| `REFINEMENT_HALT` | `waive:<TICKET>:<CODE>` | the reason = `dor-check.sh --waive <TICKET> <CODE> "reason"`. `__skip__` declines. Not offered for `BODY_*` codes or for a code in `ready.demoted` (an audit dispute already took it off the blocking list) |
| `ADR_GATE` | `note` | recorded only — accept the ADR out of band (`adr-store.sh accept` refuses inside an agent session) |
| `UNTIL_STOP` | `note` | recorded only — resuming is what continues past the `--until` phase |
| `SPECIFY_DECISION` | `specify-answer:O<n>`, one per open decision, id `decision-O<n>-<hash8>`; `KIND input`, `AUDIENCE either`, no options or default | one line of at most 500 characters, written into proposal.md as `**Outcome:** Human decision (verbatim, round N, <role>): "<answer>"`. `__defer__` writes `**Outcome:** Deferred decision: <question>` and keeps the old outcome: the epic carries the question unresolved. Either a client or an operator may answer |
| `SPECIFY_DECISION` (parameters) | `specify-param:<key>`, one per open `## Parameters` row, id `param-<key>`; same block as the outcome questions, and also at the second stop before Crosscheck | one line of at most 500 characters. Send the `Suggested:` text back to accept it. `__defer__` and a blank value are `INVALID_VALUE`; a `duration` answer must be a number with a unit, a `limit`/`size` answer a number with a unit or a bare number. The row line is rewritten with Source `human:r<N>:<role>`; `round-N.json` stores `question`, `suggestion` and `value` |

`lib/planner-answers.sh` checks the file before it writes anything: the round must be
the open one (exit 4, `STALE_ROUND`), every id must belong to it and an operator
question needs `role: operator` (exit 2), and the file's `schema_version` major must
be `1`. It writes `artifacts/answers/round-N.json`, applies the bindings through the
same functions SKILL.md step 2b uses for the flags, and appends
`META|human-hold|done|round=N sha=<sha256>` last. The same file again is a no-op; a
different file for an answered round exits 3 (`ROUND_ALREADY_ANSWERED`). Answer text
is untrusted: capped at 4 KB, stripped of control characters and code fences, stored
with its attribution, and never evaluated.

A `SPECIFY_DECISION` answer has stricter rules. It must be one line of at most 500
characters after trimming; a longer value is `INVALID_VALUE` (exit 2), never cut. The
first answer wins: an answer to a decision that was already answered, or whose
question was edited in proposal.md, is `UNKNOWN_QUESTION_ID` (exit 2) — describe again
and ask the new question. A round may answer only some decisions; the next describe
opens round N+1 with the rest. Every intake runs under a per-initiative lock
(`<state.log>.answers-lock`), so two concurrent files for one round give one exit 0
and one exit 3. The answer text is written into proposal.md and `round-N.json`, never
into state.log.

The halts themselves do not change — same prose, same exit codes. The describer reads
the state log the halts already write. The one halt added with the describer in mind
is SKILL.md step 1c's open-decision halt: its describer check reads proposal.md, read-only,
at position `Review`, so after `--until Specify` the decision is described before
`UNTIL_STOP`.

### When the client asks back

A reply can be a question instead of an answer ("why do you need this?"). The caller
decides which it is with an explicit affordance (a button, a command, a `?` prefix),
never by asking a model. A question goes to the read-only Q&A script:

```bash
REPOS_ROOT=… bash lib/planner-artifact-qa.sh <INIT_ID> --question-file <file|-> \
  [--qa-id <id>] [--about <QUESTION_ID>]
```

It answers from a read-only snapshot of the initiative's artifacts in its own sandboxed
`claude -p` session and prints one JSON object: `status` (`answered` or
`not_in_plan`), `answer`, `sources`, `about_open`, `phase_running`, `round`. An answer
with no source in the plan comes back as `That is not in the plan yet.` Its exit codes
are its own — do not reuse the `planner-answers.sh` table: 0 post the answer, 1 could
not run, 2 input rejected, 3 `NO_ARTIFACTS`, 4 `QA_MODEL_FAILED` (retry once with the
same `--qa-id`, unless stderr says `QA_MODEL_FAILED: budget`), 5 sandbox unsafe or
violated (never retry).

A question back is never an answer. The script does not touch `state.log`,
`artifacts/` or the answers round: the open round stays open and its question stays
pending. When `phase_running` is true a phase is running and the plan may still change;
say so next to the answer.

## Planned-Entry Gate Dormancy

The `planned-entry-gate` capability is specified in `ticket-planner-enrichment` but deliberately unimplemented. It would allow confidence ≥ 0.85 plus the Planner Context block's `Pre-approved` field to bypass the human approval gate.

**Why it stays dormant:**

1. **Dispatch and approval are independent controls.** Automating dispatch removes a mechanical step; automating approval removes the only point where a human sees the plan before code is written.
2. **The system spends real money per ticket.** A bad auto-approved plan fans out into many expensive workers.
3. **Confidence calibration is unproven.** The feedback loop has never received real input (the feedback writer just shipped). Until confidence drift is measured across multiple completed initiatives, self-assessed confidence is not trustworthy enough to gate on.

**What would have to be true to revisit this decision:**

1. Confidence drift is measured across ≥ 10 completed initiatives with real feedback data.
2. Drift is consistently ≤ 0.10 (minor or none) for tickets with confidence ≥ 0.85.
3. No auto-approved ticket has produced a production incident or required emergency rollback.
4. The operator explicitly opts in — auto-approval is never the default.

Even then, auto-approval should be a per-initiative flag (`--auto-approve`), not a global setting. The cost of a false positive (bad code merged) vastly exceeds the cost of a false negative (human reviews a good plan).

The capability is left specified rather than removed so the design rationale is preserved. Removing it would invite someone to re-specify it without understanding why it was deferred.

## Future Enhancements

Candidate enhancements identified during the 7-part integration programme:

- **Constitution / immutable-rules primitive** — per-initiative `constitution.md` validated at the entry gate
- **EARS notation for acceptance criteria** — deterministically-checkable AC shape
- **Critique-refine loop in planning phases** — iterate the proposal in Review→Consensus, not just pass/fail
- **Per-initiative dependency graph visualization** — surfaced in the dexter dashboard Initiatives tab
