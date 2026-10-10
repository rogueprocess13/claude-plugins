# plugin-overview.md — ticket-planner

Maintainer-facing overview of the ticket-planner plugin. Read this before adding features, modifying the state machine, or debugging planning failures.

## Design philosophy

**Determinism at the boundary.** Bash handles state (log parsing, position derivation, phase transition validation, entity idempotency, dependency acyclicity, confidence computation, spec validation). Agents handle reasoning (appraisal, discovery, architecture, proposal/spec synthesis, review, consensus, ticket body generation). The boundary is absolute — agents never mutate state directly; they write log entries the router reads.

**Stateless routing, copied from ticket-auto.** State lives in an append-only log. The router reads it to derive position. Each phase runs as an isolated agent with no inline reasoning between phases. Resume re-derives position by re-reading the log — zero in-memory state between invocations.

**Generate against the validator.** Every ticket is validated by `planned-ticket-check.sh` before creation. A ticket that fails validation is not created. Confidence is derived deterministically from concrete signals (services identified, symbols resolved, prior art, exploration depth, complexity) — never a uniform constant.

**Idempotency by design.** Every entity-creating phase records intent before the API call, checks existence before creating, and marks completion after success. A crash between intent and creation produces exactly one entity on resume.

## Component inventory

### State management

| Component | File | Role |
|-----------|------|------|
| State log helpers | `lib/planner-state.sh` | Log format, read/write/init, position derivation, phase sequence, transition validation, phase locking, state log repair |
| Phase router | `lib/planner-router.sh` | Reads state log, derives position, dispatches phase agents |
| Phase prompts | `lib/planner-phase-prompts.sh` | Per-phase agent prompt templates with input sanitization |

### Validation and gating

| Component | File | Role |
|-----------|------|------|
| Dependency validation | `lib/planner-deps-check.sh` | Acyclicity (`tsort`), topological sort, missing-target detection, cross-initiative (existing Linear ID) ref exemption |
| Ticket validation | `lib/planner-ticket-validate.sh` | Pre-creation validation, idempotency helpers, post-creation verification, dispatch gate |
| Spec validation | `lib/planner-spec-validate.sh` | Deterministic spec file validation — required sections + parseable Signals JSON |
| Context generation | `lib/planner-context-gen.sh` | Deterministic Planner Context block generation, confidence derivation from 5 concrete signals |

### Linear integration

| Component | File | Role |
|-----------|------|------|
| Linear API client | `lib/planner-linear-api.sh` | GraphQL API with retry (3 attempts, exponential backoff), issue creation and retrieval |

### Re-planning

| Component | File | Role |
|-----------|------|------|
| Re-plan support | `lib/planner-replan.sh` | Regenerate flag detection, feedback ingestion, drift computation, scope restriction, post-replan validation |

### Testing

| File | Coverage |
|------|----------|
| `lib/tests/test-planner-state.sh` | State log read/write/init, position derivation, repair, duplicate detection (12 tests) |
| `lib/tests/test-planner-transitions.sh` | Phase transition validation, lifecycle scenarios (23 tests) |
| `lib/tests/test-planner-integration.sh` | End-to-end: state init → phase transitions → position derivation (28 tests) |
| `lib/tests/test-planner-generation.sh` | Idempotency: intent recording, entity existence, entity creation (23 tests) |
| `lib/tests/test-planner-replan.sh` | Re-plan: flag detection, feedback listing, drift computation, record (29 tests) |
| `lib/tests/test-planner-sanitize.sh` | Input sanitization: bidi chars, injection patterns, length limits (27 tests) |

## Architecture: Stateless Router

```
User invokes /ticket-planner plan "idea"
  → SKILL.md sources planner-state.sh + planner-router.sh
    → planner_state_init "$ID" "$IDEA"
    → planner_run "$ID" "$IDEA"
    → persist invocation config (planner_config_set) — flags become log entries
      → dispatch loop (one process per iteration):
        1. planner_position_derive → current phase
        2. planner_create_gate_check → refuse EpicGen/TicketGen unless authorized
        2a. Crosscheck is bash, not an agent: planner_crosscheck_run runs directly,
            a blocking finding stops the loop immediately (steps 3-5 skipped)
        2b. Refinement is also bash, not an agent (planner-refinement-phase):
            per-ticket deterministic DoR check + dor-semantic-agent scan/audit
            spawns, then planner_refinement_gate stamps the epic and decides
            halt vs. proceed (steps 3-5 skipped)
        3. planner_prompt_for_phase → agent prompt, config read back off disk
        4. Spawn isolated agent with prompt
        5. Agent writes state log entries via planner_state_write
        6. planner_should_stop_after → stop at the create gate or an --until
        7. Re-read position → next phase or done
      → plan stops after Crosscheck; resume --create continues
      → Completed → planner_position_derive returns "" → stop
```

### Phase dispatch

| # | Phase | Agent prompt | Key artifacts |
|---|-------|-------------|---------------|
| 1 | Appraisal | `planner_prompt_appraisal` | `appraisal.md` |
| 2 | Discovery | `planner_prompt_discovery` | `discovery.md` |
| 3 | Architecture | `planner_prompt_architecture` | `architecture.md` |
| 4 | Specify | `planner_prompt_specify` | `proposal.md`, `specs/*.md` |
| 5 | Review | `planner_prompt_review` | `review.md` |
| 6 | Consensus | `planner_prompt_consensus` | `proposal.md` (overwritten), `consensus.md` |
| 7 | Crosscheck | *(none — `planner_crosscheck_run`)* | `META|crosscheck` findings in state.log — **last artifact-only phase, gates EpicGen** |
| 8 | EpicGen | `planner_prompt_epicgen` | Linear epic — **first Linear write, gated on `--create`** |
| 9 | TicketGen | `planner_prompt_ticketgen` | Linear tickets, per-ticket `planner/body.md` |
| 10 | Refinement | *(none — bash + two `dor-semantic-agent` spawns per ticket)* | Per-ticket readiness verdicts; epic manifest `dispatch=true` once every child has one |
| 11 | Completed | `planner_prompt_completed` | `COMPLETED.md` |

## Phase merge history

The original design specified 12 phases. Four were merged in implementation:

| Original | Merged Into | Rationale |
|----------|------------|-----------|
| Proposal + OpenSpec | Specify (phase 4) | Proposal and spec writing share the same upstream artifacts; doing them in one pass avoids context loss between phases |
| StoryGen | TicketGen (phase 9) | Stories are always 1:1 with tickets — no separate decomposition step needed |
| Execution | Refinement (phase 10) | Stamping the epic manifest `dispatch=true` is a deterministic operation after every child ticket has a readiness verdict, not a reasoning phase. It lived in TicketGen until planner-refinement-phase moved it to the new Refinement phase, once readiness verdicts — not just ticket existence — became the gate |

The merge reduced phase count from 12 to 10 (11 after planner-refinement-phase added Refinement back as a genuinely new phase) without removing any capability. Phase agents produce all the same artifacts.

## Key design decisions

- **Phase sequence is single source of truth.** `planner_phase_sequence` in `planner-state.sh` is the canonical phase list. Position derivation, transition validation, and the dispatch table all derive from it. There is no second copy to drift.
- **Confidence from signals, not self-assessment.** The LLM writes raw signal values (services count, symbols count, prior art boolean, complexity enum, exploration depth enum). A deterministic bash function computes confidence from these. The LLM never sees its own confidence score — it can't game it.
- **Regenerate is an explicit flag.** Feedback is not read by default. The `Regenerate` flag must be set on the Planner Context block before `replan` will ingest feedback. This keeps planner runs reproducible and feedback ingestion a deliberate act.
- **Creation is authorized separately from planning.** `plan` ends at Crosscheck, the last artifact-only phase; EpicGen is the first Linear write and runs only for an initiative carrying `META|create-authorized|done`, written by `resume <ID> --create`. The default is a constant in the phase sequence rather than a flag, so nothing has to propagate correctly for the safe outcome to hold — and the authorization, being a log entry, survives a crashed router.
- **Crosscheck (#178) is the one phase that isn't an agent.** It runs the citation (#172) and cross-ticket propagation (#173) linters as plain bash, writes `META|crosscheck` findings, and stops the loop immediately on a blocking one rather than folding it into the phase-retry budget — a deterministic check re-run against unedited artifacts can't produce a different answer.
- **The epic is made dispatch-eligible by Refinement, not EpicGen or TicketGen.** Every issue the planner creates carries no labels. Dispatch eligibility is the epic manifest's `dispatch` field, a one-way `false`→`true` flag. Refinement's gate (`planner_refinement_gate` in `lib/planner-refinement.sh`) sets it through `stamp_epic_dispatch` only after every child ticket has a deterministic-and-semantic readiness verdict. This prevents fleet-controller from dispatching a partially-created or not-yet-evaluated initiative. (Historical: this flag replaced the retired `state:execution` Linear label, which TicketGen used to apply.)
- **Cross-plugin dependency on `planned-ticket-check.sh`.** The planner does not bundle its own ticket validator. It resolves `planned-ticket-check.sh` from ticket-auto-pipeline via a three-level fallback. This is deliberate — schema drift between planner output and pipeline consumption is a hard stop, not a silent degradation.

## Known sharp edges

See [CLAUDE.md § Known sharp edges](CLAUDE.md#known-sharp-edges) for the current list. Key items:

- Cross-plugin validator dependency (three-level fallback, hard stop on unavailable)
- `planner-artifacts.sh` lives in ticket-auto-pipeline, not planner
- Pipe character in state log message field can truncate naive `cut -f5` consumers
- Stale phase lock blocks resume until PID dies or lock is manually removed
- Prompt phase indices are hardcoded — changing phase sequence requires updating 9 prompt functions
- Phase prompts embed bash inside unquoted heredocs, so every `$`, backtick and trailing `\` intended for the agent's shell must be escaped. An unescaped one executes at prompt-generation time and lands in the prompt blank — this is not covered by type checking or linting, only by `test-planner-lib-root.sh`

## Related plugins

- [ticket-auto-pipeline](../ticket-auto-pipeline/) — Downstream consumer. Reads Planner Context blocks. Its appraise fast-path (`lib/appraise-fast-path.sh`) treats a ticket as planned when the ticket's local manifest exists, then fast-paths it when the block's `Pre-approved` field is `true` or its `Confidence` meets `FAST_PATH_CONFIDENCE_THRESHOLD` (default 0.85). No Linear label is read.
- [fleet-controller](../fleet-controller/) — Dispatch orchestrator. Finds dispatch-eligible initiatives by scanning local epic manifests for `dispatch=true` (`detect_initiative_dispatch` / `fleet_dispatch_initiative`), then dispatches child tickets to ticket-auto workers. No Linear query or label is involved in finding them.
