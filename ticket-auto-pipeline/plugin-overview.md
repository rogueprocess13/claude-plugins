# plugin-overview.md — ticket-auto-pipeline

Maintainer-facing overview of the ticket-auto-pipeline plugin. Read this before adding features, modifying the state machine, or debugging pipeline failures.

## Design philosophy

**Determinism at the boundary.** AI handles reasoning (appraisal, implementation, review). Bash handles mutation (state transitions, API calls, log writes). The boundary is absolute — skills never call Linear mutation endpoints or write log entries directly. This gives reproducible failure modes: if a state transition is wrong, it's in `flow.sh`, not in an untraceable agent decision.

**Logs as checkpoints.** The pipeline log is the single source of truth for pipeline progress. Crash recovery reads it. Retro analysis reads it. Dashboard reads it. Every meaningful action writes to it. No in-memory state survives agent spawn boundaries.

**Safety over speed.** 11 structural gate-stop codes halt the pipeline when invariants are violated. This is deliberate — a halted pipeline that requires human attention is better than a silent merge of broken code.

## Component inventory

### State management
| Component | File | Role |
|-----------|------|------|
| State machine definition | `skills/ticket-flow/workflow.json` | Declares triggers, states, labels, transitions |
| State machine executor | `skills/ticket-flow/flow.sh` | Reads JSON, executes transitions with idempotency |
| State diagram generator | `skills/ticket-flow/gen-mermaid.sh` | Generates mermaid from state machine JSON |
| Interactive diagram | `docs/ticket-auto-pipeline-diagram.html` | Visual state diagram with drill-down (GitHub Pages) |
| Linear config validator | `validate-linear-config.sh` | Asserts team states/labels match state machine |

### Core pipeline (thin router dispatch)

The orchestrator (`ticket-auto`) is a **thin stateless dispatch router** — it reads pipeline log state via `detect-resume.sh`, dispatches to the correct phase agent or bash gate, and re-reads state. Zero inline LLM reasoning between phases.

| Step | Phase | Dispatches | Type |
|------|-------|------------|------|
| 0 | Prescan | `ticket-prescan-agent` | Named agent — auto-invoke before Step 1. Runs `prescan-check.sh` per repo; if stale/missing, spawns prescan to refresh `.ticket-auto/` docs. Non-blocking — failure/skip falls through to appraise Path B. |
| 1 | Appraise | `ticket-appraise-agent` | Named agent — investigates ticket, scores complexity. Step 3a loads prescan docs (Tier 1: INDEX.md routing via `prescan-route.sh`, Tier 2: claude-mem corpus, Tier 3: wiki fallback). |
| 1.5 | Reproduce | `ticket-appraise-agent` | Named agent — bug reproduction (bug tickets only) |
| 2 | Exec | `ticket-appraise-agent` | Named agent — creates artifact, regression guard, adversarial review (complex), verification plan derivation (complex, Step 3.7), advisory verification-readiness score (Step 3.8, `verify-readiness.sh`) |
| 2.5 | Gate | `bash gate-check.sh --mode entry` | **Bash only** — artifact existence, complexity coherence, verification readiness (reads derived plan + artifact fallback), autonomy routing |
| 3.5 | Reconcile | `ticket-gate-reconcile-agent` | Named agent — post-gate-hold comment reconciliation (only when held ticket re-approved) |
| 4 | Implement | `ticket-implement-agent` | Named agent — code changes, then `bash outcome-label-check.sh` |
| 4.5 | Verify | `ticket-verify-agent` | Named agent — Playwright UAT, router-managed retry loop (max 3 attempts). With `VERIFY_QA_PERSONA=true`, Step 1g loads the `qa-engineer` persona (`persona-select.sh --phase verify --verify-mode <mode>`); its supporting checks widen the plan, never the verdict — findings no criterion covers go to an `Observations` section (`skills/ticket-verify/references/qa-persona.md`) |
| 4.6 | PR Review | `ticket-pr-review-agent` | Named agent — code review pass, router-managed iteration loop (max 3 cycles) |
| 5 | Maintenance | `ticket-maintenance-agent` | Named agent — document (ai-context.md) + wiki-maintenance (errata) |
| 5.5 | PR Reconcile | `ticket-pr-review-agent` | Named agent — PR comment cross-reference |
| 6 | Report | `bash` + optional `ticket-retro` skill | Bash check (gate-stop / fallback detection) + optional retro agent |

### Support systems
| System | Components | Purpose |
|--------|-----------|---------|
| Logging | `pipeline-log-format.md`, `pipeline-heartbeat-format.md`, `lib/heartbeat.sh` | Dual-stream progress + operational logging |
| Bash gates | `lib/gate-check.sh`, `lib/outcome-label-check.sh` | Deterministic gate decisions (no Claude agent) — artifact, complexity, autonomy, outcome labels |
| Human approval | `skills/ticket-approve/approve.sh`, `skills/ticket-reject/reject.sh`, `lib/human-terminal.sh` | Operator scripts a person runs in an interactive terminal (`/ticket-approve` and `/ticket-reject` only print the command). They refuse an agent or fleetd-worker session and a missing terminal, and ask for the ticket id to be typed back; `flow.sh` refuses a `human` approval or a `human-reject` the same way (exit 15). The entry gate accepts only `approval_provenance: human` for a complex, manual-mode or held ticket; the pipeline's own approvals are `policy`. Not a sandbox: a process with its own pseudo-terminal, or one that writes the manifest file, is not stopped |
| Crash recovery | `lib/detect-resume.sh`, pipeline log | Direct bash invocation by router — reads last completed step, outputs routing variables |
| Comment reconciliation | `ticket-gate-reconcile` | Isolated agent for post-gate-hold comment reconciliation |
| Failure analysis | `ticket-retro`, retro templates | Post-mortem classification + fix proposals |
| Monitoring | `ticket-overseer`, `dashboard.py`, `report.py` | Queue status, stall detection (human-facing) |
| Fleet control | `fleet-controller` plugin (`fleet-controller/lib/fleet-detect.sh`, `fleet-intervene.sh`, `fleet-dashboard.sh`) | Automated intervention — detect, kill, restart pipelines |
| Validation | `ticket-env-check`, `validate-linear-config.sh` | Pre-flight checks |
| Batch ops | `ticket-batch-appraise`, `ticket-batch-verify` | Bulk ticket processing |
| Audit | `ticket-audit`, `ticket-audit-exec`, `lib/audit-size-check.sh`, `lib/audit-drift-check.sh`, `lib/audit-title-similarity.sh`, `lib/audit-scope-check.sh`, `lib/audit-repro-check.sh`, `lib/audit-ac-testability.sh`, `lib/audit-test-data-check.sh`, `lib/audit-overlap-check.sh`, `lib/audit-comment-guard.sh`, `lib/ticket-audit-exec.sh` | Cross-ticket audit within milestone/parent — detects duplicates, overlaps, empty tickets, goal misalignment, stale tickets, split candidates, wiki misalignment. Two-phase apply agent delegates needs-info to ticket-critique, posts structural comments. |
| Prescan | `ticket-prescan`, `lib/prescan-check.sh`, `lib/prescan-docs.sh`, `lib/prescan-route.sh`, `lib/prescan-verify.sh`, `lib/prescan-wire-claude-md.sh` | Repo knowledge building — deterministic freshness gate, graph-to-markdown distiller, INDEX.md keyword router, post-scan quality assertions, managed block injection (also wires a `Cross-repo` row into each repo's INDEX.md pointing at `WIKI_ROOT/index.md` when `WIKI_ROOT` is configured). Produces `.ticket-auto/` docs consumed by appraise Step 3a to skip per-ticket codebase rediscovery. |
| Wiki knowledge | `wiki-maintenance`, `lib/wiki-check.sh`, `lib/corrections-parse.sh` | Cross-repo knowledge layer — `WIKI_ROOT` is loaded alongside prescan in appraise Step 3a (not gated behind it), routed to as a primary source on multi-repo scope or an index topic match. `lib/wiki-check.sh` is the freshness/completeness lint (frontmatter, broken `related:` links, unresolved backticked class names, fresh/stale/decayed classification) run in MAINTENANCE before commit and in appraise Step 3a before trusting a loaded wiki file. `wiki-maintenance` incorporates errata (deleting entries on incorporation — git is the audit trail) and is the only skill permitted to `git commit` (scoped to `WIKI_ROOT`). |
| Recording | `lib/record.sh`, `skills/ticket-verify/references/record.md`, `lib/board-drivers/recorder.sh`, `lib/board-drivers/record/board-shot.mjs`, `lib/record-stitch.sh`, `ticket-record-stitch`, `lib/record-env-check.sh` | Opt-in (`--record`): app screenshots from browser-mode VERIFY and board screenshots per card move, listed in a per-ticket manifest and stitched into a video on request. See [Recording](#recording---record). |

## Architecture: Thin Router Dispatch

```
ticket-auto (thin stateless dispatch router)
  │
  ├─ Pre-pipeline bash gate (no Claude agent):
  │   └─ lib/prescan-check.sh       ── freshness gate per repo (before Step 1)
  │       └─ if stale/missing: flock → spawn ticket-prescan-agent (non-blocking)
  │
  ├─ Bash gates (no Claude agent):
  │   ├─ lib/gate-check.sh          ── entry mode (artifact, complexity, verification readiness, autonomy)
  │   │   └─ ticket-flow (state mutations)
  │   ├─ lib/outcome-label-check.sh  ── post-implement outcome label guard
  │   │   └─ ticket-flow
  │   └─ lib/detect-resume.sh       ── direct bash invocation (not skill spawn)
  │
  ├─ Named agent spawns (3-step pattern: pre → spawn → capture → post):
  │   ├─ ticket-prescan-agent        ── Step 0 (pre-pipeline: repo knowledge refresh)
  │   ├─ ticket-appraise-agent       ── Step 1 (appraise) + Step 1.5 (reproduce) + Step 2 (exec: artifact + regression + adversarial + verification plan derivation + readiness gate)
  │   ├─ ticket-gate-reconcile-agent ── Step 3.5 (post-hold comment reconciliation)
  │   ├─ ticket-implement-agent      ── Step 4 (code changes)
  │   ├─ ticket-verify-agent         ── Step 4.5 (Playwright UAT, consumes derived verification plan, router-managed retry)
  │   ├─ ticket-pr-review-agent      ── Step 4.6 (code review, router-managed iteration)
  │   └─ ticket-maintenance-agent    ── Step 5 (document + wiki)
  │
  └─ Router-managed loops (counters from pipeline log):
      ├─ Verify retry: FAIL → re-implement → outcome-check → re-verify (max 3)
      └─ PR iteration: ⚠️ → pr-iterate → reapprove-check → re-implement → verify → pr-review (max 3)

Support (invoked independently):
  ticket-prescan ── manual prescan slash command (also auto-invoked by router)
  ticket-detect-resume ── reads pipeline log (also called as bash by router)
  ticket-retro ── reads pipeline + heartbeat logs
  ticket-overseer ── reads pipeline logs
  fleet-controller (separate plugin, lib/fleet-*.sh) ── reads pipeline + heartbeat logs, writes interventions
  ticket-env-check ── validates environment
  ticket-flow ── all Linear state/label mutations (deterministic bash)
```

All pipeline agents use `lib/skill-preamble-auto.md` (thin router variant). All bash operations source from `lib/*.sh` (synced to `~/.claude/skills/lib/` by the SessionStart hook).

## Data flow

```
                     ┌──────────────┐
                     │ Linear API   │
                     └──────┬───────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
         get_issue     get_comments   update_issue
              │             │             │
              ▼             ▼             ▲
    ┌─────────────┐  ┌───────────┐  ┌────┴──────┐
    │ Phase Agents│  │ Gate      │  │ flow.sh   │
    │ (appraise,  │  │ Reconcile │  │ (idempotent
    │  implement, │  │ PR Review │  │  mutations)│
    │  verify,    │  │ Retro     │  └───────────┘
    │  maintenance│  └───────────┘
    └──────┬──────┘
           │
           ▼
    ┌──────────────┐     ┌─────────────────┐
    │ Pipeline Log │◄────│ Bash Gates      │
    │ Heartbeat Log│     │ gate-check.sh   │
    └──────┬───────┘     │ outcome-label-  │
           │             │ check.sh        │
    ┌──────┴───────┐     └─────────────────┘
    │              │
    ▼              ▼
├────────┐  ┌──────────┐
│detect- │  │ Retro    │
│resume  │  │ (post-   │
│(bash — │  │ mortem)  │
│no agent│  │          │
│spawn)  │  │          │
├────────┘  └──────────┘
│              │
▼              ▼
┌──────────────┐  ┌──────────────┐
│ Fleet        │  │ Overseer     │
│ Controller   │  │ (human       │
│ (automated   │  │  dashboard)  │
│  intervention│  │              │
└──────┬───────┘  └──────────────┘
       │
       ▼
┌──────────────┐
│ Stop files,  │
│ pipeline log │
│ intervention │
│ entries      │
└──────────────┘
```

## Recording (`--record`)

Opt-in. With recording off, none of the code below runs and nothing changes. The operator how-to is in the [README](README.md#recording-a-run---record); this section is the design.

### Parts

```
/ticket-auto <ID> --record
   │
   ├─ ticket-preamble.sh      checks RECORD_ALLOWED, writes META|record|info|on once
   │
   ├─ VERIFY (browser mode)   agent takes a screenshot per settled step
   │     └─ record.sh append  checks the page's environment, names the file,
   │                          appends an "app" entry            ──┐
   │                                                              ├─► <ticket dir>/artifacts/recordings/
   └─ flow.sh exit / fleetd pusher: outbox drain                  │      manifest.jsonl
         linear.sh            moves the card                      │      verify-a{attempt}-{NNN}.png
         recorder.sh          waits for the card in its column, ──┘      board-{SEQ}-{EVENT}.png
            └─ board-shot.mjs screenshots that column, "board" entry

/ticket-record-stitch <ID>...
   └─ record-stitch.sh        plan (bash/jq, re-checks every entry) → render (ffmpeg) → MP4
```

| Part | Role |
|---|---|
| `lib/ticket-preamble.sh` | Parses `--record` / `RECORD=` / `TICKET_RECORD`. The one writer of `META\|record\|info\|on`, the only recording line the pipeline log ever gets |
| `lib/record.sh` | `record_enabled <log>` is the only reader of that line (`RECORD_DISABLE=true` overrides it). `record.sh append` is the only path an app frame takes into the workspace. `record_append_entry` is the only manifest writer (one line per call, under `flock`) |
| `skills/ticket-verify/references/record.md` | The agent's instructions, loaded by `ticket-verify` Step 1h only when recording is on **and** `VERIFY_MODE=browser` |
| `lib/board-drivers/recorder.sh` | Second board driver, listed after `linear`. One board frame per card move |
| `lib/board-drivers/record/board-shot.mjs` | Its browser half (Playwright from `$REPOS_ROOT/.ticket-auto/record/node_modules`, never bundled). Also `--login`, `--import`, `--check` behind `recorder.sh login\|import\|check` |
| `lib/record-stitch.sh` + `ticket-record-stitch` | A pure planner and a thin `ffmpeg` runner. Not a pipeline phase: no preamble, no log line, no tracker write |
| `lib/record-env-check.sh` | The eight `RECORD_*` rows of `/ticket-env-check`, printed only when `RECORD_ALLOWED` is set, `ok` or `warn` only |

### The flag is a log line

`--record` is not carried from phase to phase. The preamble writes `META|record|info|on` once, and every later reader (VERIFY, the driver, a resume, a fleetd phase) asks `record_enabled`. So recording survives a resume without the flag, and `RECORD_DISABLE=true` is the off switch.

An explicit `--record` that `RECORD_ALLOWED` does not permit is a usage error (exit 1) decided before anything is written. `TICKET_RECORD=true` in the same situation only warns: fleetd reads the preamble's usage exit as "retry later", so a refusal there would repeat forever.

### Manifest

`artifacts/recordings/manifest.jsonl` is append-only JSON Lines. Every line has the same 13 keys: `ts`, `tid`, `source` (`app` or `board`), `phase`, `attempt`, `step`, `file`, `env`, `event`, `seq`, `column`, `status` (`ok`, `skipped` or `fail`) and `reason`. Failures are recorded here and nowhere else. Readers skip a line that does not parse, so a line torn by a crash costs one frame.

App entries carry `phase: "verify"`, the attempt number and the environment. The attempt number only grows, so a retry's frames never mix with the failed attempt's, and the stitch shows the latest attempt only. Board entries carry `event`, `seq` and `column`, with `phase`, `attempt`, `step` and `env` null.

### The recorder driver

`recorder.sh apply <TID> <EVENT> <SEQ> <DATA>` runs these checks in order and stops at the first that applies:

1. The ticket workspace resolves from `REPOS_ROOT` in the environment. If not: nothing.
2. `record_enabled` is true and `workflow.json`'s `board_drivers.linear.events` maps the event to a column. If not: nothing.
3. `board-{SEQ}-{EVENT}.png` already exists (a replayed dispatch): nothing.
4. The outbox holds a later event that also moves the card: `skipped` / `superseded`. A backlog costs one screenshot, and each frame matches the board at the time it is taken.
5. The `linear` cursor is below `SEQ`: `skipped` / `board-not-applied`.
6. `RECORD_BOARD_URL` unset: `fail` / `no-board-url`. Not `https://linear.app/…` with `/project/` or `/view/` in the path: `fail` / `bad-board-url`. No browser is started.
7. `board-shot.mjs shoot` under `timeout` (`RECORD_SHOT_TIMEOUT`, 1–55 s, default 25; the script has its own 20 s deadline). It opens the board with the saved session at 1600×900, waits until the card is seen under the expected column's header twice in a row, and saves a screenshot cropped to that column.

`linear`'s cursor alone is not proof of a move: a dead-lettered event also advances it, and Linear's page can lag its API. The column check is the proof, which is why a frame is saved only after it.

A `skipped` or `fail` outcome is final for that event. The driver exits 0, its cursor moves on, and nothing retries.

### Safety properties

| Property | How it is held |
|---|---|
| Recording never changes a verdict, a gate or a route | `record.sh` returns 0 on every runtime problem; the agent is told to ignore `append`'s output; the manifest is read by nothing but the stitch |
| A drain never fails because of recording | `recorder.sh apply` exits 0 for every input, including bad arguments and an unknown subcommand. It projects nothing and changes no other driver's cursor |
| `META\|outcome` stays the last log line | No recording code writes the pipeline log after the preamble. Drains run after the outcome line, so the driver writes only under `artifacts/recordings/` |
| A hung browser cannot hold the pipeline | `timeout -k 2` around the screenshot, capped at 55 s, under the pusher's 60 s per driver call |
| Real data is not recorded | `record.sh append` maps the page URL's origin to `local` (`LOCAL_URL`) or `uat` (`UAT_URL`) and deletes the screenshot when the origin is neither or the environment is not in `RECORD_ALLOWED`. `uat` needs `RECORD_UAT_SYNTHETIC=true`. The agent never decides this and never names a file |
| Real data is not stitched | The planner re-checks each entry's `env` against the `RECORD_ALLOWED` in force at stitch time, and plans nothing when the field allows nothing |
| Passwords are not recorded | No frame while a form holds a typed password (`references/record.md`, the rule VERIFY already applies to its own screenshots). Screenshots are viewport-only |
| The stitch reads only recording frames | Ticket ids must match the id pattern; a `file` must be a basename matching `verify-a<N>-<NNN>.png` or `board-<SEQ>-<event>.png`, a regular file, not a symlink, whose real path is exactly `<ticket dir>/artifacts/recordings/<file>`. Nothing is globbed. `render` checks every plan line again |
| The saved Linear session stays private | Written with `umask 077`, file 0600, directory 0700, beside a `.gitignore` of `*`. Never printed; browser error text is printed only with `RECORD_SHOT_DEBUG=1`. The browser that loads it is opened only on an `https://linear.app/` URL. The stitch whitelist cannot reach `.ticket-auto/record/` |
| A failed render leaves no half file | Encoding goes to a temp dir, then `mv`. On exit 3, 4 or 5 an existing output is kept |

One thing is deliberately a hard stop: under `--record`, a missing `references/record.md` stops VERIFY with `META|reference-missing|fail`, as every missing reference does. Both files ship in the same plugin version, so this is an install defect, not a recording failure.

The remaining risk is the operator's: the saved session is a full login for its Linear user (use a dedicated read-only or guest user), and `RECORD_UAT_SYNTHETIC=true` is a statement the code cannot verify.

### Known limitation

`board-shot.mjs` reads the Linear board without using Linear's class names: it finds text equal to the known column names, takes the row with the most of them as the header row, finds text equal to the ticket id below it, and assigns the card to the column whose header starts left of the card's centre. It treats any host other than `linear.app`, or a path starting `/login`, `/signup`, `/auth` or `/sso`, as the login page. Neither rule has been run against a real Linear page; the tests drive the script with a stand-in browser. Where the page differs (a header split over several text nodes, a card far down a virtualised column), the result is `column-mismatch` on every move: no board frames, nothing else affected.

### Costs

- A `flow.sh` exit on a recording ticket waits for the screenshot: usually a few seconds, close to 20 s when the card is not found, never more than `RECORD_SHOT_TIMEOUT` plus the 2 s kill grace.
- One extra reference in the VERIFY agent's context, and one screenshot plus one bash call per step.
- Dependencies, only when used: `ffmpeg` with `libx264` for the stitch (also needed by `lib/tests/test-record-stitch.sh`, so by `make test`); Node, Playwright and Chromium for board frames.

### Retention

Frames, manifest and clip live in the ticket workspace and go with it. `hooks/tmp-sweep.sh` does not touch them. Nothing uploads a recording; attaching the clip to the tracker ticket and recording REPRODUCE are not built.

## How to add a new pipeline phase

1. Create skill directory: `skills/ticket-<name>/SKILL.md`
2. Add slash command definition in SKILL.md frontmatter
3. Reference `lib/skill-preamble-auto.md` for shared parameter patterns (thin router variant)
4. If the phase needs a restricted tool allowlist or its own system prompt, add a plugin-defined subagent: create `agents/<name>-agent.md` (YAML frontmatter: `name`, `description`, `tools`; body is the system prompt), then set `spawn.agent` (or `sequence[].agent`) to `ticket-auto-pipeline:<name>-agent` on the step's entry in `skills/ticket-flow/dispatch-table.json`. Otherwise leave `agent` unset/`null` — the step falls back to `general-purpose`. Regenerate the dispatch table (below) so SKILL.md's "Agent types" table picks up the mapping; fleetd's phase-dispatch path reads the same JSON field automatically.
5. Add dispatch case to `ticket-auto/SKILL.md` dispatch table (new RESUME_STEP)
6. Add any new state transitions to `skills/ticket-flow/workflow.json`
7. Add corresponding trigger to `flow.sh` if needed
8. Add phase to `pipeline-log-format.md` if it writes log entries
9. Regenerate state diagram: `bash skills/ticket-flow/gen-mermaid.sh`
10. Regenerate skill docs: run `/skill-docs`
11. Update this document (plugin-overview.md) with the new phase

## How to modify the state machine

1. Edit `skills/ticket-flow/workflow.json` — add/modify triggers, states, labels
2. Run `skills/ticket-flow/validate-linear-config.sh` to verify the Linear team has the required states/labels
3. Run `bash skills/ticket-flow/gen-mermaid.sh` to update the diagram
4. If adding new triggers: update `flow.sh` trigger dispatch
5. Test with a real ticket in `--manual` mode first

The state machine JSON structure:
```json
{
  "triggers": {
    "<trigger-name>": {
      "from": ["<state>"],
      "to": "<state>",
      "addLabels": ["<label>"],
      "removeLabels": ["<label>"],
      "setAssignee": "<role>"
    }
  },
  "states": { "<name>": { "type": "<category>" } },
  "labels": { "<name>": { "color": "<hex>" } }
}
```

## Testing approach

- **Unit-level**: `lib/*.sh` scripts are bash — test with direct invocation
- **Integration**: Run individual skills (`/ticket-appraise <id>`, `/ticket-implement <id>`) independently before full pipeline
- **End-to-end**: Run `/ticket-auto <id> --manual` for full pipeline with human gates
- **State machine**: `validate-linear-config.sh` checks config alignment; test each trigger with `/ticket-flow <id> <trigger>`
- **Log integrity**: After any log-format change, verify `ticket-detect-resume` and `ticket-retro` can parse the new format
- **Drift gates**: `make test` starts with three. `check-generated` checks that the dispatch-table block and the state diagram match their JSON sources. `check-test-registration` checks that every test file is run by the Makefile. `check-skill-size` (`scripts/check-skill-size.sh`) checks that skills, agents, the skill preambles and personas only shrink against `scripts/skill-size-baseline.tsv`, that a new skill fits 500 lines / 20 KB, and that the frontmatter, fence and `references/` rules hold. End any PR that touches a skill with `make skill-baseline` — see the root CLAUDE.md § Skill size budget

## Debugging tips

- **Pipeline stuck in a state**: Check the pipeline log at `tickets/{ID}--*/pipeline.log`. Look for `|waiting|` entries (agent never completed) or `|fail|` entries (agent reported failure).
- **State assertion failures (exit 7)**: flow.sh mutated state but post-trigger re-fetch didn't match expectations. Check Linear for conflicting automations or manual changes.
- **Silent agent failures**: If an agent spawn shows `|waiting|` with no matching `|done|` or `|fail|`, check the heartbeat log for the agent's last decision or fallback entry.
- **MCP auth issues**: Run `/ticket-env-check` in validate mode to isolate which server is failing. Check `~/.claude.json` MCP server env blocks.
- **Log corruption**: Schema version mismatches or manual edits can break parsing. Schema version is line 1 of every log. Delete and restart if corrupted.

## Related OpenSpec changes

Active and recently archived changes that affect this plugin:

- `ticket-auto-thin-router` — Thin stateless dispatch router with bash gates (active, tasks 0–12 complete)
- `pr-comment-reconciliation` — PR comment cross-referencing (active)
- `reproduce-pipeline-integration` — Bug reproduction phase (active)
- `ticket-pipeline-cleanup` — Code quality and safety (active)
- `token-optimization` — Prompt and template externalization (active)
- `skill-preamble-dedup` — Shared preamble extraction (archived)
- `transcript-capture-for-retro` — Agent output persistence (archived)
- `gate-comment-reconciliation` — Approval comment handling (archived)
- `pipeline-heartbeat-log` — Heartbeat log system (archived)
- `env-check-unification` — Dual-mode env validation (archived)
