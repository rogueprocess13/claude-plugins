---
name: ticket-auto
description: Fully autonomous ticket pipeline — appraise, exec, implement, PR review, merge. Thin stateless router that dispatches to per-phase agents. No inline LLM reasoning between phases. Requires zero user input beyond the ticket ID. Stops only for complex tickets at the approve gate. Supports `--branch {name}` for explicit branch targeting (precedence: flag → parent epic directive → default). Use when the user says "/ticket-auto {ID}", "auto {ID}", "process ticket {ID}", or "run ticket {ID} end to end".
---

# Ticket Auto — Thin Dispatch Router

Thin stateless router. Reads pipeline log state via `detect-resume.sh`, dispatches to the correct phase agent or bash gate, waits for completion, re-reads state, and routes again. **Zero inline LLM reasoning between phases** — every conditional is a deterministic bash comparison.

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=none, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,get_comments,save_comment, HAS_GUARD=true, EXTRA_GUARD=validate-env, HAS_PROJECT_CONTEXT=false, HAS_LOGGING=false, HAS_HEARTBEAT=false, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=false

---

## Linear access strategy

Same strategy as the full preamble — see [skill-preamble.md § 2](../../lib/skill-preamble.md#2-linear-access-strategy)
for the Function mapping table, the standard operation rows, and the
comment-formatting rule. Single source (tracker-client-consolidation design
D5) — do not restate it here.

The `get_issue` function returns the issue object already unwrapped from `.data.issue` — use `jq` to extract fields directly (e.g., `.id`, `.title`, `.labels`). The `get_comments` function returns a JSON array of comment nodes. API error capture (incl. the #362 `require_issue_payload` hard stop) is [skill-preamble.md § 9](../../lib/skill-preamble.md#9-api-error-capture).

---

## Step 0 — Clear context: Run `/clear`.

---

## Step 0.1 — Ticket preamble (autonomy, preflight, branch context, env file, pipeline log, run identity)

One call to `lib/ticket-preamble.sh` does everything the router needs before the first
dispatch, in this order: heartbeat log, Linear preflight (sentinel-cached team-config check,
then `get_me`), pipeline log with its `META|schema` line, run identity (`NEW_RUN=true` opens
a new run, since one router process is one run), branch context (`--branch` flag → parent
epic directive → config default; a decision already in the log as `META|branch-context` is
rehydrated, never re-resolved), project context from `CLAUDE.md` plus the env file
every sub-agent sources (`lib/ticket-env.sh`), then the `META|autonomy` /
`META|mode-change` and `META|from-planned` markers. fleetd's phase dispatch calls the same
script, so the two paths cannot drift. `TICKET_ARG` is the raw argument string:
`--semi-auto` > `--auto` > `--manual`, else `$TICKET_AUTONOMY`, else `manual`;
`--from-planned`; `--branch <name>`; the one remaining token is the ticket id.

```bash
export PATH="$HOME/.claude/skills/lib:$PATH"  # makes bare hb-wrap.sh calls resolve (script is executable)
source ~/.claude/skills/lib/capture-transcript.sh
source ~/.claude/skills/lib/phase-inspector.sh
_pre_rc=0
_pre_out=$(bash ~/.claude/skills/lib/ticket-preamble.sh TICKET_ARG="{TICKET_ARG}" NEW_RUN=true ANNOUNCE_START=true) || _pre_rc=$?
echo "$_pre_out"
_pre() { echo "$_pre_out" | sed -n "s/^  ${1}: //p"; }
if [ "$_pre_rc" -eq 0 ]; then
  HB_LOG_FILE="$(_pre HB_LOG_FILE)"; export HB_LOG_FILE
  # capture-transcript.sh turns on `set -eo pipefail`: every line here must survive it.
  _who=$(grep '|source|linear-auth|ok|' "$HB_LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5) || true
  [ -z "$_who" ] || echo "Linear: API key (direct GraphQL) — $_who"
  YELLOW=$(tput setaf 3 2>/dev/null) || true; BOLD=$(tput bold 2>/dev/null) || true; RESET=$(tput sgr0 2>/dev/null) || true
  echo "${BOLD}${YELLOW}Dashboard ready. In a second terminal run either:${RESET}"
  echo "${BOLD}${YELLOW}  $(_pre DASHBOARD_CMD_LOG)${RESET}"
  echo "${BOLD}${YELLOW}  $(_pre DASHBOARD_CMD_FLEET)${RESET}"
fi
# Exit codes: table below. Same Bash call: _pre_rc does not survive into another.
case "$_pre_rc" in
0) ;;
2 | 3 | 6)
  _tid=$(bash -c 'source ~/.claude/skills/lib/ticket-preamble.sh && ticket_preamble_parse_arg "${1}"' _ "{TICKET_ARG}" | sed -n 's/^TICKET_ID=//p')
  bash ~/.claude/skills/lib/pipeline-finalize.sh "$_tid" "$_pre_rc" "$PWD/logs/${_tid}-pipeline.log" || true
  exit "$_pre_rc"
  ;;
*) exit "$_pre_rc" ;;
esac
```

From the `TICKET_PREAMBLE_RESULT` block set `{TICKET_ID}` (`{TICKET-ID}` is the same value),
`{ENV_FILE}`, `{LOG_FILE}`, `{HB_LOG_FILE}`, `{CLAUDE_LOG_FILE}`, `{AUTONOMY}`,
`{FROM_PLANNED}`, `{BASE_BRANCH}`, `{INTEGRATION_BRANCH}`, `{TICKET_BRANCH}`,
`{BRANCH_SOURCE}`, `{UAT_POLICY}`, `{MERGE_POLICY}` and `{REPOS_ROOT}` — used throughout the
pipeline. Every other project-context field (`ISSUE_PREFIX`, `BE_SERVICES`, `WIKI_ROOT`,
`BE_TEST_CMD`, `BE_TEST_RUNNER`, `FE_TEST_CMD`, `LOCAL_URL`, `UAT_URL`, `SLACK_CHANNEL`) is
in `{ENV_FILE}`: a later bash block that needs one runs `source {ENV_FILE}` first. `AUTONOMY`
and `MERGE_POLICY` in that file are what `ticket-pr-review` Step 6b reads to decide whether it
may merge a passing PR directly — see [Auto-merge logic](#auto-merge-logic) below.

**The router does not spawn a dashboard pane.** It prints the two `dashboard.py` commands
(`DASHBOARD_CMD_LOG`, and `DASHBOARD_CMD_FLEET`, the `--fleet` view of the whole workspace)
for the operator to open once; nothing is spawned per run.

**Exit codes.** On any non-zero `_pre_rc`, report the preamble's stderr and stop — no fallback,
no dispatch. 2, 3 and 6 happen after the pipeline log exists, so the block finalizes it first
(Step 0.65); 1, 4 and 5 happen before it exists:

| `_pre_rc` | Meaning | Router action |
|---|---|---|
| 0 | ok | continue to Step 0.65 / Step 0.7 |
| 1 | usage — bad or unknown token in the argument string, `--branch` without a name, no ticket id; nothing written | report, stop |
| 2 | `BRANCH_DIRECTIVE_INVALID` — the parent epic's Branch Directive is malformed; `META\|gate-stop\|fail\|BRANCH_DIRECTIVE_INVALID` is already in the log | finalize, stop |
| 3 | branch resolution failed (API error, malformed result) — not a gate-stop | finalize, stop |
| 4 | Linear config invalid (team states/labels do not match `workflow.json`, validator missing, or several teams visible without `LINEAR_TEAM_ID`) | report, stop |
| 5 | Linear auth failed (teams query failed, or `LINEAR_API_KEY` unset/rejected by `get_me`) | report, stop |
| 6 | env file write failed — never spawn without it | finalize, stop |


### Step 0.65 — Exit finalizer (RLVR Phase 3)

Every exit path in the router MUST call `pipeline-finalize.sh` to run post-mortem analysis and write `META|outcome`. This replaces the bash trap approach (which cannot persist across separate Bash tool calls in the harness execution model).

**Usage pattern at every exit point:**
```bash
bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" <exit-code> "{LOG_FILE}" || true
exit <exit-code>
```

`pipeline-finalize.sh` handles: postmortem analysis (fail-soft, timeout 60s), outcome derivation from log evidence (not exit code alone), and tail-check idempotency (F10: only skips if outcome IS the last log line — prevents stale outcomes from crash-resume blocking fresh writes).

**Covered exit paths:** gate-stop, gate-held, VERIFY_EXHAUSTED, PR_FEEDBACK_EXHAUSTED, router-error, STEP_6 completion. Fleet-killed pipelines use the fleet-side trigger (`fleet-controller/lib/fleet-intervene.sh`).

### :rotating_light: CRITICAL — Agent isolation requirement

**Every phase agent MUST run in an isolated `Agent` invocation; the `Skill` tool is never used for phase dispatch.** `Skill` runs the phase inline in the router's context window, so every code read, test output and internal step lands there: a 4-phase pipeline burns 150k–300k tokens instead of ~15k for the router plus per-agent summaries. `Agent` returns only the subagent's final result.

### Agent spawn template

Every agent spawn follows this 3-step pattern:

1. **Pre-spawn** — `spawn_agent_pre` prints the `AGENT_PROMPT` and `AGENT_TYPE` lines. Look up `AGENT_TYPE` for the skill you are dispatching in the "Agent types" table above, and pass it explicitly — `spawn_agent_pre` cannot infer it from `SKILL` alone (the same skill can be dispatched at more than one step). Capture the output:
   ```bash
   source ~/.claude/skills/lib/spawn-helper.sh
   _prompt=$(spawn_agent_pre \
     PHASE=<phase> STEP=<step> TICKET_ID={TICKET-ID} \
     LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
     SKILL=/ticket-auto-pipeline:ticket-<skill> FLAGS="--from-auto" \
     AGENT_TYPE="<subagent_type from the Agent types table>" \
     FROM_STEP={<FROM>} \
     DESCRIPTION="<what the agent does>" \
     INSTRUCTIONS="<additional skill-specific instructions>")
   ```
   `spawn_agent_pre` outputs two lines: `AGENT_PROMPT=` (everything after it is the exact prompt the agent needs) and `AGENT_TYPE=` (the exact `subagent_type` value to use in the next step — `general-purpose` if you omitted `AGENT_TYPE=`, never guess a different fallback).

2. **Spawn** — invoke the `Agent` tool with the prompt from `$_prompt`. Extract the text after `AGENT_PROMPT=` and pass it as the `prompt` parameter; extract the text after `AGENT_TYPE=` and pass it as `subagent_type`:
   ```
   Agent tool call:
     description: "<phase> agent for {TICKET-ID}"
     prompt: <content after AGENT_PROMPT= from step 1>
     subagent_type: <content after AGENT_TYPE= from step 1>
   ```
   Always `Agent` (never `Skill` — see above), and always the `subagent_type` `spawn_agent_pre` printed — never hardcode `general-purpose`: a phase's tool allowlist and system prompt (`ticket-auto-pipeline/agents/*.md`) only apply when the matching named agent type is used.

3. **Post-spawn** — `spawn_capture` persists agent output to `-{phase}-agent.log`, then `spawn_agent_post` writes done/fail log entries, stops pinger, and writes heartbeat transitions.

   **Hand the return over as a file, never as a quoted argument.** Write the
   agent's return verbatim into `./logs/{TICKET-ID}-agent-return.txt`
   using a **quoted** heredoc (`<<'AGENT_RETURN_EOF'` — the quotes are what stop
   the shell expanding `$`, backticks and `$(...)` inside the return), then pass
   the path. A return containing `"` or `$` interpolated into `RESULT="..."` is
   truncated at best and evaluated at worst:
   ```bash
   cat > ./logs/{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
   <the agent's return text, verbatim and unmodified>
   AGENT_RETURN_EOF

   spawn_capture TICKET_ID={TICKET-ID} PHASE=<phase> RESULT_FILE=./logs/{TICKET-ID}-agent-return.txt [ATTEMPT=<n>]
   # On success:
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="<result>" NEXT_PHASE=<next>
   # On failure (blocking):
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
   # On failure (non-blocking, e.g. document/wiki):
   FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
   ```

   **Verdict phases (VERIFY, PR-REVIEW only)** — pass `VERDICT=<token>` so `spawn_agent_post`
   prepends a canonical token to `MSG` (`done|PASS — <result>`). This decouples
   `detect-resume.sh`'s resume grep from router free-text prose or emoji bytes. See
   [Verdict tokens](../../pipeline-log-format.md#verdict-tokens) for the full token table.
   ```bash
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done VERDICT=PASS MSG="<result>" NEXT_PHASE=<next>
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done VERDICT=WARN MSG="Verdict: ⚠️ <summary>" NEXT_PHASE=<next>
   ```

### Phase inspector (after IMPLEMENT, VERIFY, PR-REVIEW)

RLVR Phase 1 advisory inspection. It never changes a verdict and never blocks the next transition. `{P}` is the phase and `{p}` its lowercase form (`implement`, `verify`, `pr-review`). Each of those steps runs:

```bash
bash ~/.claude/skills/lib/router-step.sh inspector {P} {TICKET_ID} --log-file "{LOG_FILE}" || true
```

The script adds the cross-phase context (VERIFY reads IMPLEMENT's verifier results too, PR-REVIEW reads both). With no verifier results it logs the skip itself and prints `PHASE_INSPECTOR_READY=skip`; then skip the rest of this section. Otherwise it prints `INSPECTOR_INSTRUCTIONS_FILE=<path>`. Spawn the guidance-extractor-agent with the standard pattern:

```
STEP=phase-inspector-{p} PHASE={P} SKILL=/ticket-auto-pipeline:guidance-extractor
AGENT_TYPE=ticket-auto-pipeline:guidance-extractor-agent
EXTRA_FLAGS="--from-auto --mode extract"
DESCRIPTION="Phase inspector for {P}"
INSTRUCTIONS="$(cat <INSPECTOR_INSTRUCTIONS_FILE>)"
FAIL_ACTION=warn-continue
```

After it returns, write its return to `./logs/{TICKET-ID}-agent-return.txt` (quoted heredoc), then run:

```bash
bash ~/.claude/skills/lib/router-step.sh inspector-done {P} {TICKET_ID} || true
```

`inspector-done` captures the return with `ATTEMPT=inspector`, which appends to the phase agent's own capture instead of overwriting the phase-result parser's input, then calls `spawn_agent_post STEP=phase-inspector-{p}`.

---

## Step 0.7 — State detection (direct bash invocation)

Resolve the `detect-resume.sh` path dynamically and invoke directly as bash — no Claude agent spawn. This replaces the old pattern of calling the `ticket-detect-resume` skill:

```bash
# Resolve detect-resume.sh: synced copy, else the installed (else newest cached) version (#468)
source ~/.claude/skills/lib/plugin-cache.sh
DETECT_SH="$HOME/.claude/skills/ticket-detect-resume/detect-resume.sh"
[ -f "$DETECT_SH" ] || DETECT_SH=$(tap_cache_find ticket-auto-pipeline skills/ticket-detect-resume/detect-resume.sh)
if [ -z "$DETECT_SH" ]; then echo "detect-resume.sh not found"; exit 1; fi
```

For every dispatch decision, re-run `detect-resume.sh` to get fresh state:

```bash
DETECT_OUTPUT=$(bash "$DETECT_SH" "{TICKET_ID}")
```

Parse the `DETECT_RESUME_RESULT` block and set all routing variables:
`{RESUME_STEP}`, `{APPRAISE_FROM}`, `{REPRODUCE_FROM}`, `{EXEC_FROM}`, `{IMPLEMENT_FROM}`, `{MAINTENANCE_FROM}`, `{DOCUMENT_FROM}`, `{VERIFY_FROM}`, `{VERIFY_CHECKPOINT}`, `{PR_REVIEW_FROM}`, `{PR_ITERATE_FROM}`, `{TICKET_DIR}`, `{COMPLEXITY}`, `{AUTONOMY}`, `{ARTIFACT_TYPE}`, `{BRANCH}`, `{BASE_BRANCH}`, `{INTEGRATION_BRANCH}`, `{BRANCH_SOURCE}`, `{MERGE_POLICY}`, `{TICKET_TITLE}`, `{VERIFY_ATTEMPTS}`, `{VERIFY_LAST}`, `{ITERATION}`, `{RECONCILE_CYCLE}`, `{PR_FEEDBACK_CYCLE}`.

**If `RESUME_STEP = SCHEMA_MISMATCH`:**
Report the schema mismatch with log vs expected version numbers. Stop here.

**If `RESUME_STEP = GATE_STILL_HELD`:**
Report that the ticket is still held and requires `/ticket-approve {TICKET_ID}`. Stop here.

**If recovering (`RESUME_STEP ≠ STEP_1`):**
```bash
bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" META recovery info "Resuming from {RESUME_STEP}"
```

**Before the recovery log entry, rehydrate the branch env vars from `detect-resume.sh` output** — on a crash-recovery the router does not re-run `resolve_branch_context`. The branch decisions were written to `META|branch-context` by the Step 0.1 preamble and are now in the `DETECT_RESUME_RESULT` block as `BASE_BRANCH`, `INTEGRATION_BRANCH`, `BRANCH_SOURCE`,
`UAT_POLICY`, `MERGE_POLICY`. Write them back to the env file so sub-agents see branch vars even on resume — `AUTONOMY` is rehydrated too, from the same `DETECT_RESUME_RESULT` block (it comes from `META|autonomy|info|`, not branch-context, but needs the same resume-time re-export or a resumed pipeline's `ticket-pr-review` spawn would merge unconditionally):

```bash
if [ -n "{BASE_BRANCH}" ] || [ -n "{TICKET_BRANCH}" ]; then
  source "{ENV_FILE}"  # project context the Step 0.1 preamble wrote
  source ~/.claude/skills/lib/spawn-helper.sh
  spawn_write_env \
    TICKET_ID="{TICKET_ID}" \
    REPOS_ROOT="$REPOS_ROOT" \
    ISSUE_PREFIX="$ISSUE_PREFIX" \
    BE_SERVICES="$BE_SERVICES" \
    WIKI_ROOT="$WIKI_ROOT" \
    BE_TEST_CMD="$BE_TEST_CMD" \
    BE_TEST_RUNNER="$BE_TEST_RUNNER" \
    FE_TEST_CMD="$FE_TEST_CMD" \
    LOCAL_URL="$LOCAL_URL" \
    UAT_URL="$UAT_URL" \
    SLACK_CHANNEL="$SLACK_CHANNEL" \
    FROM_PLANNED="{FROM_PLANNED}" \
    BASE_BRANCH="{BASE_BRANCH}" \
    INTEGRATION_BRANCH="{INTEGRATION_BRANCH}" \
    TICKET_BRANCH="{TICKET_BRANCH}" \
    UAT_POLICY="{UAT_POLICY}" \
    AUTONOMY="{AUTONOMY}" \
    MERGE_POLICY="{MERGE_POLICY}"
fi
```

The guard `[ -n "{BASE_BRANCH}" ] || [ -n "{TICKET_BRANCH}" ]` skips this on
legacy logs that predate branch-context. `spawn_write_env` is idempotent — the
env file is regenerated with the same values.

---

## Prescan gate (Phase 2 — auto-invoke before appraise)

Prescan keeps the `.ticket-auto/` docs fresh before appraise. It is an optimization: failure, timeout or lock contention never blocks the pipeline, and appraise Step 3a falls back INDEX.md → claude-mem corpus → WIKI_ROOT → Path B.

`lib/prescan-run.sh gate` does the deterministic part (its header lists the log lines). It skips the whole gate when resuming at STEP_4 or later, walks every repo under `REPOS_ROOT`, and runs `prescan-check.sh` against `{BASE_BRANCH}` (the ticket's target, not whatever `HEAD` the shared checkout has). It logs a skip for `decayed`/`missing` repos: they need `/ticket-prescan`'s Path A fan-out, and `ticket-prescan-agent` has no `Agent` tool, so an operator runs `/ticket-prescan <repo>` interactively. It also logs a skip for an unknown status or a held lock. It stops at the first `stale` repo, which `ticket-prescan-agent` can refresh with Path B. Run it, and prepare the spawn when it names a repo:

```bash
source ~/.claude/skills/lib/spawn-helper.sh
eval "$(bash ~/.claude/skills/lib/prescan-run.sh gate --log-file "{LOG_FILE}" --repos-root "{REPOS_ROOT}" --branch "{BASE_BRANCH}" --resume-step "{RESUME_STEP}" {PRESCAN_AFTER} || true)"
echo "PRESCAN_REPO=$PRESCAN_REPO PRESCAN_SLUG=$PRESCAN_SLUG PRESCAN_STATUS=$PRESCAN_STATUS"
if [ -n "$PRESCAN_REPO" ]; then
  # spawn_agent_pre accepts only its documented params; repo, slug and cadence travel in INSTRUCTIONS.
  _prompt=$(spawn_agent_pre \
    PHASE=MAINTENANCE STEP=prescan TICKET_ID={TICKET-ID} \
    LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
    SKILL=/ticket-auto-pipeline:ticket-prescan FLAGS="--from-auto" \
    AGENT_TYPE="ticket-auto-pipeline:ticket-prescan-agent" \
    DESCRIPTION="Refresh prescan docs for $PRESCAN_SLUG ($PRESCAN_STATUS)" \
    INSTRUCTIONS="Run /ticket-auto-pipeline:ticket-prescan --from-auto on $PRESCAN_REPO. Repo slug: $PRESCAN_SLUG. Cadence: $PRESCAN_STATUS.")
  echo "$_prompt"
fi
```

`{PRESCAN_AFTER}` is empty on the first call. If `PRESCAN_REPO` is empty, go to the Dispatch Loop. Otherwise spawn the agent (Agent spawn template step 2). Write its return to `./logs/{TICKET-ID}-agent-return.txt` with the quoted heredoc, then run:

```bash
bash ~/.claude/skills/lib/prescan-run.sh done {TICKET-ID} --slug "{PRESCAN_SLUG}" --status "{PRESCAN_STATUS}" --log-file "{LOG_FILE}" || true
```

`done` captures the return and judges success by the `{PRESCAN_SLUG}: scanned` marker in it. It writes the done or fail terminal (fail is `warn-continue`). Then run the gate block again with `{PRESCAN_AFTER}` set to `--after "{PRESCAN_REPO}"`, and repeat until it names no repo. The token-tracker hook labels these spawns `PRESCAN` (informational only, not a resumable phase).

---

## Dispatch Loop

After state detection, enter the stateless dispatch loop. Re-run `detect-resume.sh` before each dispatch decision to get current state from the pipeline log.

**At every agent dispatch site:** `spawn_agent_pre` → `Agent` tool (see "Agent isolation requirement") → `spawn_capture` → `spawn_agent_post` → re-run `detect-resume.sh`. Exact pattern: "Agent spawn template" above.

### Dispatch table

<!-- GENERATED:dispatch-table START -->
<!-- Generated from skills/ticket-flow/dispatch-table.json by skills/ticket-flow/gen-dispatch-table.py. Do not hand-edit: edit the JSON and regenerate. CI fails the build when this block drifts. -->

| RESUME_STEP | Action |
|-------------|--------|
| `STEP_1` | Spawn `ticket-appraise` agent |
| `STEP_1_5` | Spawn `ticket-reproduce` agent |
| `STEP_2` | Spawn `ticket-appraise-exec` agent |
| `STEP_2_5` / `STEP_3` | Run `bash gate-check.sh --mode entry` |
| `STEP_3_5` | Spawn `ticket-gate-reconcile` agent |
| `STEP_4` | Spawn `ticket-implement` agent, run `return-completeness-check.sh` (openspec tickets only), then `outcome-label-check.sh` |
| `STEP_4_5` | Verify retry sub-loop (see below) |
| `STEP_4_6` | PR review + iteration sub-loop (see below) |
| `STEP_5` | Spawn `ticket-document`, then `wiki-maintenance` (sequential) |
| `STEP_5_5` | PR comment reconciliation |
| `STEP_6` | Retro check + optional `ticket-retro` + outcome write |
| `done` | Exit 0 |
| `*` (unknown) | Log error, exit 1 |

**Agent types** — the `subagent_type` each phase's `Agent` tool spawn MUST use (see "Agent spawn template" below). A skill with no dedicated agent type falls back to `general-purpose`.

| Skill | subagent_type |
|-------|---------------|
| `/ticket-auto-pipeline:ticket-appraise` | `ticket-auto-pipeline:ticket-appraise-agent` |
| `/ticket-auto-pipeline:ticket-reproduce` | `ticket-auto-pipeline:ticket-appraise-agent` |
| `/ticket-auto-pipeline:ticket-appraise-exec` | `ticket-auto-pipeline:ticket-appraise-agent` |
| `/ticket-auto-pipeline:ticket-gate-reconcile` | `ticket-auto-pipeline:ticket-gate-reconcile-agent` |
| `/ticket-auto-pipeline:ticket-implement` | `ticket-auto-pipeline:ticket-implement-agent` |
| `/ticket-auto-pipeline:guidance-extractor` | `ticket-auto-pipeline:guidance-extractor-agent` |
| `/ticket-auto-pipeline:ticket-verify` | `ticket-auto-pipeline:ticket-verify-agent` |
| `/ticket-auto-pipeline:ticket-pr-review` | `ticket-auto-pipeline:ticket-pr-review-agent` |
| `/ticket-auto-pipeline:ticket-document` | `ticket-auto-pipeline:ticket-maintenance-agent` |
| `/ticket-auto-pipeline:wiki-maintenance` | `ticket-auto-pipeline:ticket-maintenance-agent` |
| `/ticket-auto-pipeline:ticket-pr-iterate` | `general-purpose` |
| `/ticket-auto-pipeline:ticket-retro` | `general-purpose` |
<!-- GENERATED:dispatch-table END -->

### STEP_1 — Appraise

**First, fail fast on a structurally incomplete planned ticket** (issue #410). `gate-check.sh --mode planned` runs the entry gate's own Check 2.7 (template, required body sections, DoR readiness) before any agent is spawned. Ad-hoc tickets pass straight through without a Linear call, and a failed issue fetch defers to the entry gate rather than stopping here:

```bash
_gate_sh="${HOME}/.claude/skills/lib/gate-check.sh"
bash "$_gate_sh" "{TICKET_ID}" "{LOG_FILE}" "{HB_LOG_FILE}" --mode planned
_pre_rc=$?
if [ $_pre_rc -eq 2 ]; then
  # Gate-stop (PLANNED_BODY_INCOMPLETE / NO_TEMPLATE_FOR_TYPE / TICKET_NOT_READY) — already logged
  echo "Planned-ticket pre-check gate-stopped {TICKET_ID} before APPRAISE. Fix the ticket body (see the META|gate-stop line in the pipeline log), then re-run."
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
```

**Then, before the agent spawn, claim the ticket immediately** so Linear reflects that work has started. Complexity defaults to `simple` — the appraise agent corrects it in Step 4 when the real score is known. `flow.sh` is idempotent: re-calling with the same params is a no-op.

```bash
bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" "{TICKET-ID}" appraise-start --data complexity=simple 2>&1
_rc=$?
if [ $_rc -ne 0 ]; then
  # flow-run.sh already wrote META|flow-error (or the exit-11 gate-stop) and the retry heartbeat.
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" META ticket-claimed info "{TICKET-ID} claimed → Todo"
hb-wrap.sh gate "ticket-claimed" "ok" "ticket claimed — Todo + claimed label + assigned"
```

```
STEP=appraise PHASE=APPRAISE SKILL=/ticket-auto-pipeline:ticket-appraise FROM_STEP={APPRAISE_FROM}
DESCRIPTION="Investigate the ticket and produce complexity score"
INSTRUCTIONS="Follow the skill exactly."
NEXT_PHASE=APPRAISE
```

### STEP_1_5 — Reproduce (bug tickets only)

```
STEP=reproduce PHASE=REPRODUCE SKILL=/ticket-auto-pipeline:ticket-reproduce FROM_STEP={REPRODUCE_FROM}
DESCRIPTION="Reproduce the bug and capture evidence"
INSTRUCTIONS="Follow the skill exactly."
NEXT_PHASE=REPRODUCE
```

### STEP_2 — Appraise Exec

```
STEP=exec PHASE=EXEC SKILL=/ticket-auto-pipeline:ticket-appraise-exec FROM_STEP={EXEC_FROM}
DESCRIPTION="Create implementation artifacts (simple-fix.md or OpenSpec change)"
INSTRUCTIONS="Follow the skill exactly."
NEXT_PHASE=EXEC
```

### STEP_2_5 — Gate Check (bash only, no agent)

Run `gate-check.sh` in entry mode — deterministic bash, no Claude agent involved:

```bash
_gate_sh="${HOME}/.claude/skills/lib/gate-check.sh"
bash "$_gate_sh" "{TICKET_ID}" "{LOG_FILE}" "{HB_LOG_FILE}" --mode entry
_gate_rc=$?

if [ $_gate_rc -eq 0 ]; then
  # Auto-approved — loop back to state detection
  hb-wrap.sh gate "phase-transition" "ok" "GATE → IMPLEMENT"
elif [ $_gate_rc -eq 1 ]; then
  # Held — fleet controller will detect, stop here
  echo "Gate held for {TICKET_ID}. Check the appraisal comment in Linear for any Open Questions and answer them in a comment first — then run /ticket-approve {TICKET_ID}. Approving before answering will just trigger another gate-reconcile hold on next resume."
  bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" META gate-held info "held"
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 0 "{LOG_FILE}" || true
  exit 0
else
  # Gate-stop (exit 2) — structural failure
  echo "Gate-stop fired for {TICKET_ID}. Check pipeline log for code."
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
```

### STEP_3_5 — Gate Reconcile

Spawned only when a held ticket is re-approved. **Before dispatching**, check
`RECONCILE_CYCLE` from `detect-resume.sh`. Caps at 3, matching the
`VERIFY_ATTEMPTS`/`ITERATION`/`PR_FEEDBACK_CYCLE` cap pattern — otherwise a
hold → re-approve → re-hold cycle could repeat without bound:

```bash
if [ "{RECONCILE_CYCLE}" -ge 3 ]; then
  bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" META gate-stop fail "RECONCILE_EXHAUSTED"
  echo "Gate reconciliation exhausted after 3 cycles for {TICKET_ID}. Needs human review."
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
```

```
STEP=reconcile PHASE=GATE SKILL=/ticket-auto-pipeline:ticket-gate-reconcile
DESCRIPTION="Reconcile comments after gate hold and re-approval"
INSTRUCTIONS="Follow the skill exactly. Load context from env.sh, pipeline log, and artifact files."
NEXT_PHASE=GATE
```

### STEP_4 — Implement

Spawn implement agent. Its post-spawn step (`router-step.sh post-spawn IMPLEMENT`)
runs the return-completeness gate **before** `spawn_agent_post`: the gate must see
the agent's returned work before the router commits the phase as `done`.

**Pre-warming (openspec tickets):** For complex/openspec tickets, the implement
agent may time out during context loading before any work is done. When
`{ARTIFACT_TYPE}` is `openspec`, the pre-spawn step MUST load the artifact
into context before spawning the implement agent:

```bash
# Pre-warm: load artifact content into the agent's initial context
if [ "{ARTIFACT_TYPE}" = "openspec" ]; then
  # Read tasks.md and relevant files into the agent session to avoid
  # timeout during initial context loading
  _artifact_dir="$(dirname "{ARTIFACT_PATH}")"
  echo "Pre-warming implement agent: loading openspec artifact from $_artifact_dir"
fi
```

**Timeout guidance:** For openspec tickets, the implement agent requires at
least 10 minutes of context processing time. The router does not set the
agent timeout directly (harness-controlled), but pre-warming reduces the
risk of timeout during initial context load.

```
STEP=implement PHASE=IMPLEMENT SKILL=/ticket-auto-pipeline:ticket-implement FROM_STEP={IMPLEMENT_FROM}
EXTRA_FLAGS="--from-auto --mode extract"
DESCRIPTION="Implement the changes described in the artifact"
INSTRUCTIONS="Use Serena for all code navigation. For openspec tickets: first read tasks.md in full, then proceed task by task. Pre-warm by reading all task descriptions before starting implementation."
NEXT_PHASE=IMPLEMENT
```

After the agent returns, write its return to the file, then run the post-spawn step **before** `spawn_agent_post`:

```bash
cat > ./logs/{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the implement agent's return text, verbatim>
AGENT_RETURN_EOF

bash ~/.claude/skills/lib/router-step.sh post-spawn IMPLEMENT {TICKET_ID} --log-file "{LOG_FILE}" --repos-root "{REPOS_ROOT}"

# On success:
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="<result>" NEXT_PHASE=IMPLEMENT
# On failure (blocking):
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
```

`post-spawn IMPLEMENT` captures the return, runs the advisory `phase-result-parse.sh` (observe-only, nothing routes on it), then the return-completeness gate (tasks.md, else simple-fix.md). In Phase 1 that gate is warn-only. When it is not `complete` it logs `META|gate-warn|info|RETURN_INCOMPLETE — …` and never changes `RESULT`. It prints `RETURN_COMPLETENESS_STATUS`.

**Hard contract (D3):** whenever `return-completeness-check.sh` exits non-zero
in enforce mode (Phase 2+), the router MUST call `spawn_agent_post RESULT=fail`
— no code path may call `RESULT=done` on a non-zero exit once enforce mode is
active. This mirrors `gate-check.sh`'s existing exit-code contract. In Phase 1
(warn-only, current), the gate never changes `RESULT` — this note documents
the contract ahead of the Phase 2 flip, it does not yet apply.

After implement completes, always run outcome-label-check:
```bash
_outcome_sh="${HOME}/.claude/skills/lib/outcome-label-check.sh"
bash "$_outcome_sh" "{TICKET_ID}" "{LOG_FILE}"
```

Then emit planner feedback for planned tickets (no-op for unplanned):
```bash
_feedback_sh="${HOME}/.claude/skills/lib/planned-feedback-write.sh"
if [ ! -f "$_feedback_sh" ]; then
  source ~/.claude/skills/lib/plugin-cache.sh
  _feedback_sh=$(tap_cache_find ticket-auto-pipeline lib/planned-feedback-write.sh)
fi
if [ -f "$_feedback_sh" ]; then
  source "$_feedback_sh"
  planned_feedback_write "{TICKET_ID}" "{LOG_FILE}" || true
fi
```

Then run the [Phase inspector](#phase-inspector-after-implement-verify-pr-review) for `IMPLEMENT`: `bash ~/.claude/skills/lib/router-step.sh inspector IMPLEMENT {TICKET_ID} --log-file "{LOG_FILE}" || true`.

Then transition from Ready → Review via implement-complete:
```bash
# Non-zero (incl. 127 = flow.sh not found): flow-run.sh writes META|flow-error and the
# retry heartbeat itself; the router continues and detect-resume decides the next step.
bash ~/.claude/skills/lib/flow-run.sh --log-file "{LOG_FILE}" "{TICKET_ID}" implement-complete 2>&1
```
### STEP_4_5 — Verify (with retry sub-loop)

The router manages the verify→implement→verify retry loop. The verify agent has a
**hard cap of 2 total attempts** (1 initial + 1 retry). After 2 failures, the pipeline
stops with VERIFY_EXHAUSTED.

**Before dispatching**, run a pre-spawn health check and export CLAUDE_LOG_FILE:

```bash
# Pre-spawn Playwright MCP config check. MCP tools are not shell commands, so
# bash cannot probe their reachability; this checks the one thing bash can
# answer — that an MCP server named `playwright` (the source of the verify
# agent's mcp__playwright__* tools) is configured. Logs exactly one
# META|preflight line (done / fail VERIFY_PREFLIGHT_FAILED / skip) and always
# exits 0. Advisory: proceed either way — a real outage still surfaces as a
# counted verify attempt. Linear is not checked: verify reaches it through
# linear-api.sh, which the preamble already validated.
bash ~/.claude/skills/lib/verify-preflight.sh "{LOG_FILE}" "$(pwd)" || true

# Export CLAUDE_LOG_FILE for crash diagnostics — survives agent crashes
export CLAUDE_LOG_FILE="./logs/{TICKET-ID}-verify-$(date +%s).log"
```

**Before dispatching**, check `VERIFY_LAST` from `detect-resume.sh`. `VERIFY_LAST=fail` means
the pipeline crashed after a terminal verify FAIL but before the re-implement step ran —
resuming straight into verify would re-run against the same unfixed code. Dispatch
re-implement first in that case, not verify:

```bash
if [ "{VERIFY_LAST}" = "fail" ]; then
  # Dispatch re-implement (FROM_STEP={IMPLEMENT_FROM}) first, then fall through to verify below
else
  # Dispatch verify directly
fi
```

```
STEP=verify PHASE=VERIFY SKILL=/ticket-auto-pipeline:ticket-verify FROM_STEP={VERIFY_FROM}
EXTRA_FLAGS="--from-auto --mode extract"
DESCRIPTION="Run Playwright UAT verification"
INSTRUCTIONS="Follow the skill exactly. Use per-criterion checkpointing: after each criterion passes, write VERIFY|checkpoint|done|criterion-{N}-pass to LOG_FILE. On a resume, take the criteria already passed in THIS attempt from lib/verify-checkpoint.sh (see the skill's Checkpoint resume rule) — never from an earlier attempt. PHASE_RESULT_ATTEMPT=$(({VERIFY_ATTEMPTS} + 1)) — emit this verbatim as the ATTEMPT field of your phase result block."
NEXT_PHASE=VERIFY
```

**After verify completes**, write the terminal entry with a canonical `VERDICT` token
(see [Verdict tokens](../../pipeline-log-format.md#verdict-tokens)) so PASS/FAIL never
depends on router prose, then re-run `detect-resume.sh` and check VERIFY_ATTEMPTS:

```bash
cat > ./logs/{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the verify agent's return text, verbatim>
AGENT_RETURN_EOF

# VERIFY retries, so --attempt is mandatory: without it the second attempt
# overwrites the first capture and the retry history is gone.
bash ~/.claude/skills/lib/router-step.sh post-spawn VERIFY {TICKET_ID} --log-file "{LOG_FILE}" --attempt $(({VERIFY_ATTEMPTS} + 1)) --ticket-dir "{TICKET_DIR}"

spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done VERDICT=PASS MSG="<summary>" NEXT_PHASE=PR-REVIEW LOOP_BEARING=true  # on PASS
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail VERDICT=FAIL MSG="<summary>" LOOP_BEARING=true                         # on FAIL

# Verify may tick deferred tasks: re-count if return_completeness is FAIL (#598).
bash "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/return-completeness-check.sh" "{TICKET_ID}" \
  --repos-root "{REPOS_ROOT}" --log-file "{LOG_FILE}" --refresh >/dev/null || true
```

`post-spawn VERIFY` captures this attempt, runs the advisory `phase-result-parse.sh` (it reads the last block, which is this attempt's), then `verdict-recompute.sh`. That script derives the verdict from `verify-session.md` on its own and logs `META|claim-delta`. It never gates or halts on a mismatch.

Then run the [Phase inspector](#phase-inspector-after-implement-verify-pr-review) for `VERIFY`, before the retry/advance decision (it does not affect that decision): `bash ~/.claude/skills/lib/router-step.sh inspector VERIFY {TICKET_ID} --log-file "{LOG_FILE}" || true`.

Then evaluate the verify verdict for retry/advance:

`lib/verify-retry-decide.sh` makes this decision from the log as it is now — never from
`{VERIFY_ATTEMPTS}`, which was read before this attempt ran. It judges only the latest
`VERIFY|verify` terminal line (an earlier attempt's FAIL never re-triggers re-implement
after a later PASS), recounts the attempts, and reads the cap (2) from STEP_4_5 in
`dispatch-table.json`:

```bash
eval "$(bash "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/verify-retry-decide.sh" "{LOG_FILE}")"
case "$VERIFY_DECISION" in
advance) echo "VERIFY PASS → STEP_4_6" ;;
retry) echo "VERIFY FAIL (attempt $VERIFY_ATTEMPTS of $VERIFY_CAP) → re-implement" ;;
exhausted)
  bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" META gate-stop fail "VERIFY_EXHAUSTED"
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
  ;;
esac
```

- `advance` → proceed to STEP_4_6.
- `retry` → re-implement with `--from-auto`, then outcome-check, then loop back to verify.
- `exhausted` → stopped above.

### STEP_4_6 — PR Review (with iteration sub-loop)

The router manages the pr-review→pr-iterate→re-implement→verify→pr-review cycle.

```
STEP=pr-review PHASE=PR-REVIEW SKILL=/ticket-auto-pipeline:ticket-pr-review
DESCRIPTION="Review the PR for code quality and correctness"
INSTRUCTIONS="Follow the skill exactly. Return verdict: ✅ ✅, ⚠️, or ❌. PHASE_RESULT_ATTEMPT=$(({ITERATION} + 1)) — emit this verbatim as the ATTEMPT field of your phase result block."
NEXT_PHASE=PR-REVIEW
```

**After PR review completes**, write the terminal entry with a canonical `VERDICT` token
mapped from the review's emoji verdict (see
[Verdict tokens](../../pipeline-log-format.md#verdict-tokens)) — this is what `ITERATION`
counts on, so it must never be skipped or left as free-text prose:

```bash
cat > ./logs/{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the pr-review agent's return text, verbatim>
AGENT_RETURN_EOF

# PR-REVIEW iterates, so --attempt is mandatory (a second cycle must not overwrite the first capture).
bash ~/.claude/skills/lib/router-step.sh post-spawn PR-REVIEW {TICKET_ID} --log-file "{LOG_FILE}" --attempt $(({ITERATION} + 1))

# ✅ → VERDICT=OK
# ⚠️ → VERDICT=WARN
# ❌ → VERDICT=BLOCK
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done VERDICT=<OK|WARN|BLOCK> MSG="Verdict: <emoji> <summary>" NEXT_PHASE=<next> LOOP_BEARING=true
```

`post-spawn PR-REVIEW` captures this cycle and runs the advisory `phase-result-parse.sh`. This is the last gate before merge, so its record matters most, but it stays observe-only. The `VERDICT` token is what routes.

**After spawn_agent_post**, run the [Phase inspector](#phase-inspector-after-implement-verify-pr-review) for `PR-REVIEW`: `bash ~/.claude/skills/lib/router-step.sh inspector PR-REVIEW {TICKET_ID} --log-file "{LOG_FILE}" || true`.

Then evaluate verdict:

```bash
# ✅ (VERDICT=OK) → proceed to STEP_5 (Document + Wiki)
# ⚠️ (VERDICT=WARN) AND ITERATION < 3 → spawn pr-iterate (moves Review→Ready, re-adds approved) → THEN run gate-check.sh --mode reapprove (it asserts state=Ready AND approved, which only pr-iterate establishes) → implement → outcome-check → implement-complete → verify → loop back to pr-review
# ❌ (VERDICT=BLOCK) → gate-stop
# ITERATION >= 3 → gate-stop with code PR_REVIEW_EXHAUSTED (matching the VERIFY_EXHAUSTED / PR_FEEDBACK_EXHAUSTED cap convention)
```

**PR iteration loop:**

```
STEP=pr-iterate PHASE=PR-REVIEW SKILL=/ticket-auto-pipeline:ticket-pr-iterate
DESCRIPTION="Iterate on PR feedback"
INSTRUCTIONS="Apply the requested changes from the PR review."
NEXT_PHASE=PR-REVIEW
```

### Auto-merge logic

After PR review ✅, run `lib/auto-merge.sh`. The whole decision (merge authorization, complexity,
outcome label, PR number, integration-branch guard) and its exit codes are in that script's
header — do not re-derive any part of it here. Exit 0 merged, 3 skipped, 4 `gh pr merge` failed:
all three continue to STEP_5. An unmerged PR is a human's to look at, never a reason to fail a
finished ticket. `{COMPLEXITY}` comes from `DETECT_RESUME_RESULT`.

```bash
bash "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/auto-merge.sh" \
  --complexity "{COMPLEXITY}" "{TICKET_ID}" "{LOG_FILE}" || true
```

### STEP_5 — Document + Wiki Maintenance

Sequential spawns (non-blocking — `FAIL_ACTION=warn-continue`):

```
STEP=document PHASE=MAINTENANCE SKILL=/ticket-auto-pipeline:ticket-document
DESCRIPTION="Generate ai-context.md documentation"
INSTRUCTIONS="Follow the skill exactly."
FAIL_ACTION=warn-continue
NEXT_PHASE=MAINTENANCE
```

```
STEP=wiki-maintenance PHASE=MAINTENANCE SKILL=/ticket-auto-pipeline:wiki-maintenance
DESCRIPTION="Process wiki errata and update documentation"
INSTRUCTIONS="Follow the skill exactly."
FAIL_ACTION=warn-continue
NEXT_PHASE=MAINTENANCE
```

**After both spawns complete**, start the GitNexus refresh (detached, never fails) as
one Bash call: `bash ~/.claude/skills/lib/gitnexus-refresh.sh "{TICKET_ID}" "{LOG_FILE}" || true`.
Then, in a separate Bash call, write the STEP_5 rollup line. `detect-resume.sh`'s
STEP_5→STEP_6 transition needs this marker; without it a resumed run loops STEP_5:

```bash
bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" MAINTENANCE maintenance done "clean"
```

### STEP_5_5 — PR Comment Reconciliation

**Before dispatching**, check `PR_FEEDBACK_CYCLE` from `detect-resume.sh`. Caps at 3,
matching the `VERIFY_ATTEMPTS`/`ITERATION` cap pattern — otherwise a single reviewer
leaving repeated new comments could cycle the pipeline indefinitely:

```bash
if [ "{PR_FEEDBACK_CYCLE}" -ge 3 ]; then
  bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" META gate-stop fail "PR_FEEDBACK_EXHAUSTED"
  echo "PR feedback reconciliation exhausted after 3 cycles for {TICKET_ID}. Needs human review."
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
```

```
STEP=pr-reconcile PHASE=PR-REVIEW SKILL=/ticket-auto-pipeline:ticket-pr-iterate
DESCRIPTION="Reconcile PR comments from human reviewers"
INSTRUCTIONS="Check for new human comments on the open PR. Apply amend/push-back/clean logic."
NEXT_PHASE=PR-REVIEW
```

**After pr-reconcile completes**, write the terminal entry with a `cycle#N` counter so
`PR_FEEDBACK_CYCLE` (see `detect-resume.sh`) can track reconciliation rounds — without
this, the cap above never advances past 0:

```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="cycle#$(({PR_FEEDBACK_CYCLE} + 1)) reconciled" NEXT_PHASE=PR-REVIEW LOOP_BEARING=true
```

### STEP_6 — Report

Retro auto-trigger check (bash only):
```bash
bash ~/.claude/skills/lib/router-step.sh retro-check --log-file "{LOG_FILE}" --hb-log-file "{HB_LOG_FILE}"
```

It prints `NEEDS_RETRO=true|false`, `DRIFT` and `RETRO_REASONS`. Any one of five conditions sets `NEEDS_RETRO=true`: a gate-stop; no VERIFY `PASS` plus PR-REVIEW `OK`/`N/A` success markers; a heartbeat fallback event (this one also logs `META|drift|warn`); `VERIFY_EXHAUSTED`; or a VERIFY fail line. The script header lists them in full. If `NEEDS_RETRO=true`, spawn the `ticket-retro` agent. Then release the worktree (non-fatal):

```bash
# Release worktree — non-fatal: a failed removal warns but never halts the pipeline.
# Ordered after STEP_5 (ticket-document + wiki-maintenance) so document agents still
# have access to the worktree for git diff/log operations.
if [ -n "${WORKTREE_ROOT:-}" ] && [ -f "$HOME/.claude/skills/lib/worktree.sh" ]; then
  source "$HOME/.claude/skills/lib/worktree.sh"
  release_worktree "{TICKET_ID}" || \
    bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" META worktree-release warn "release_worktree failed for {TICKET_ID}"
fi

# META|outcome is written by pipeline-finalize.sh (Step 0.65) — called at
# every exit point (gate-stop, gate-held, exhaustion, router-error, STEP_6).
# Tail-check idempotency guard prevents double-writing on crash-resume.
```

### Default case — Unknown RESUME_STEP

```bash
echo "Unknown RESUME_STEP: {RESUME_STEP}" >&2
bash ~/.claude/skills/lib/plog.sh --log-file "{LOG_FILE}" META router-error fail "Unknown RESUME_STEP: {RESUME_STEP}"
bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
exit 1
```

---

## Router invariants

Statelessness, no inline reasoning and bash-only gates: see the introduction. The spawn pattern: "Agent spawn template".

1. **Sequential dispatch**: one agent in flight at a time.
2. **Router-managed loops**: the verify retry, PR iteration, reconcile and PR-feedback loops are counted by the router from the pipeline log, never inside a phase agent.
3. **Advisory parsers never route**: `phase-result-parse.sh` (IMPLEMENT, VERIFY, PR-REVIEW) and `verdict-recompute.sh` (VERIFY) only append `META|phase-result|info|` / `META|claim-delta|info|` lines, are `|| true`-guarded and emit no gate-stop code. Routing stays on `RESULT=` and `VERDICT=`. See [phase-result schema](../../docs/phase-result-schema.md) and [pipeline-log-format.md](../../pipeline-log-format.md#claim-delta-entries-rlvr-verdict-recompute).

---

## Step trace

At session end, write a trace file:

```bash
cat > {ticket-dir}/auto-session.md << 'TRACE'
# auto session — {ISSUE-ID}
**Date:** {today}
**Outcome:** {completed | stopped: <reason>}

## Step trace
- [x] Step 1: Appraise — {simple|complex}, {N} files traced
- [x] Step 1.5: Reproduce — {REPRODUCED|NOT_REPRODUCED|BLOCKED|skipped: not bug}
- [x] Step 2: Exec — {simple-fix|openspec: <name>}
- [x] Step 2.5: Gate — {auto-approved|held: <reason>|gate-stop: <code>}
- [x] Step 4: Implement — {Smooth|Rough|Hard}
- [x] Step 4.5: Verify — {✅ PASS (N attempts)|❌ FAIL after N|skipped: no UI}
- [x] Step 4.6: PR review — {✅|⚠️|❌}, {N} iterations
- [x] Step 5: Document + Wiki — ai-context.md ({trivial|non-trivial}), {N} errata
- [x] Step 6: Report — retro check + worktree release + outcome
TRACE
```
