# Next — pipeline work queue

Ordered backlog for the ticket-auto / fleet-controller pipeline. Ordering rationale is at the
bottom. Update the checkboxes as work lands; move completed steps to the archive section.

> Public repo — no ticket IDs, no customer data in this file.

Last reviewed: 2026-09-23 (Step 7 Track A merged and archived — all 3 changes landed, PRs #385/#386;
CI green on #386. Step 7b Track B Phase B1 merged and archived — PR #388, plus a CI-caught
shell-flags fix. Phase B2 (pusher/drivers) merged and archived — PR #392, CI green
(`lint-and-test: pass`), specs synced to main tree, version-bumped to ticket-auto-pipeline 0.51.0 /
fleet-controller 0.32.0. Deferred flow-driven-cutover follow-up filed as issue #391. Phase B3a
(local facts replace tracker reads) implemented 2026-09-21 via `/opsx:apply` — all 52 tasks done,
full test suite green, version-bumped to ticket-auto-pipeline 0.52.0 / ticket-planner 0.10.0 /
fleet-controller 0.33.0, committed and merged via **PR #397** (2026-09-23), pre-PR
lint/fmt-check/test all green. **Live-verification tests reordered by explicit instruction**: the
4 tests originally gating B3b (9.3-9.6) are no longer run per-phase — they're deferred to a single
consolidated pass against a real epic on one of the user's own projects, run once the whole Track B
plan (through at least B3b, possibly further) is implemented. B3b is unblocked to start now without
waiting on 9.3-9.6. Step 6 itself still held for real-run
validation)

---

## Step 0 — Extract standalone bug fixes

Buried inside the queued plans but dependent on none of them. Two are causing silent harm today.
Estimated: one sitting for all three.

- [x] **Narrow the `META|outcome` detector skip** — `fleet-controller/lib/fleet-detect.sh:1360`
      and `detect_abandoned:571`. Done 2026-09-05: added `_pipeline_genuinely_terminal`/
      `_pipeline_is_held` helpers; the sweep now runs a held-aware `detect_abandoned` (WARN-only,
      never escalates to kill/restart — no process exists to kill, and restarting would just
      duplicate the wait) for held tickets, while the other 10 process-liveness detectors
      (stalls/zombies/loops/...) stay skipped for them since they'd false-positive on a cleanly
      exited router within minutes. Also fixed the same skip shape in `detect_blocked_by`'s own
      sweep (line ~1199, not in the original two sites but identical bug). 61/61 fleet-detect
      tests pass.
      Source plan: human-hold.

- [x] **`held: ` prefix match in `fleet_ticket_terminal_state`** —
      `fleet-controller/lib/fleet-reconcile.sh:87-145`, plus the documented pairwise-sync partner
      `_log_reached_terminal:1971`. Done 2026-09-05: both now match the `held: ` prefix instead of
      the exact string `held: gate`, so a future hold kind (e.g. human-hold's external-wait) won't
      fall through to `done`. `phase_dispatch.py:281`'s `in ('done','gate-held','gate-stopped')`
      needed no change — it consumes the same fixed vocabulary, not its own classification.
      34/34 fleet-reconcile tests, 5/5 supervisor terminal-state tests pass.
      Source plan: human-hold.

- [x] **Agent-type enforcement decision + fix.** Decided: wire it up (not delete).
      Root cause was deeper than "not wired" — `agentTypes` in `plugin.json` was never a real
      Claude Code plugin schema field (confirmed against docs.claude.com); the real mechanism is
      `agents/*.md` files with YAML frontmatter, referenced as `subagent_type:
      "ticket-auto-pipeline:<name>-agent"`. Done 2026-09-05: converted the 8 JSON entries to
      `ticket-auto-pipeline/agents/*.md`, deleted the dead `agentTypes` block, added `spawn.agent`
      to the 7 dispatch-table.json steps that have a dedicated type (2 loop steps —
      `/ticket-pr-iterate`, `/ticket-retro` — stay `general-purpose`, no type ever existed for
      them), extended `gen-dispatch-table.py` to render an "Agent types" table into SKILL.md,
      threaded `AGENT_TYPE` through `spawn_agent_pre` (manual router path) and `agent`/`--agent`
      through `phase_dispatch.build_phase_spawn` → `supervisor.spawn_worker`/`_build_worker_cmd`
      (fleetd path). `CLAUDE.md`/`plugin-overview.md` updated to describe the real mechanism.
      101/101 spawn-helper, 116/116 phase-dispatch, 26/26 relevant supervisor tests pass.
      Source plans: agent-observer (`--agent`), plus the Phase-1 investigation (router path).

- [x] **Latent: `META|worker-exit` is appended after `META|outcome` at reap**
      (`fleetd/supervisor.py:2916`). Done 2026-09-05: added `_last_effective_line`
      (fleet-detect.sh) and the matching Python skip-trailing-worker-exit loop in
      `_log_reached_terminal`; both classifiers (and the new helpers above) now find the real
      last outcome/dead-letter line instead of misreading a completed pipeline as `incomplete`
      once fleetd has reaped it — which would have silently defeated the stale-queue-entry skip
      at `supervisor.py:3024` and let fleetd re-spawn an already-finished ticket.

- [x] **fleetd startup env-check gate + two false-positive issue-counters found live.** Not
      from a queued plan — built and merged reactively 2026-09-06 (PR #311, fleet-controller
      0.26.0) after being asked to verify the tickets host would come up clean. `__main__.py`'s
      `_run_startup_env_check()` now shells out to `lib/fleet-env-check.sh` before constructing
      the `Supervisor` and refuses to boot on any reported issue — fleetd previously had no
      equivalent of ticket-auto-pipeline's Step-0 `validate-env` guard at all. Live-reproduced
      against `../tickets` (real `LINEAR_API_KEY` + `gh` token exported, no `CLAUDE_CMD`) and
      found the gate refused to start on a fully valid config: `FLEET_WORKER_PERMISSION_MODE`
      unset — fleetd's own documented zero-config default — was being counted as an issue.
      Fixed by reclassifying that branch `auto` (non-issue), matching the existing convention
      for other intentional defaults. Confirmed live afterward: fleetd boots clean from
      `../tickets`. Full fleetd suite green post-fix (745 passed / 2 skipped).

- [x] **Epic-branch push runs the pre-push hook against the wrong tree** (issue #381) —
      `ticket-auto-pipeline/lib/epic-branch.sh:224` (`ensure_epic_branch`),
      `fleet-controller/lib/fleet-dispatch.sh:557` (`_fleet_dispatch_initiative_locked`),
      `fleet-controller/fleetd/supervisor.py:3680` (`dispatch_epic`). Not from a queued plan —
      reactive, found live 2026-09-15 dispatching a real initiative. Two independent defects:
      (a) the epic-branch ref push fires the repo's local pre-push hook, which runs the full
      test preflight against whatever branch the shared `REPOS_ROOT` clone happens to have
      checked out — a stale feature branch from a prior session fails a push whose ref is by
      construction identical to `origin/<base>`; (b) the resulting gate-stop is echoed to
      stderr while `dispatch_epic` derives `message` from the last *stdout* line, so `/dispatch`
      returns `{"queued": [], "spawned": []}` with no error — a failure that renders as a clean
      no-op. Fix: assert `rev-parse <epic> == rev-parse origin/<base>` and push `--no-verify`
      only on that proven-zero-commit path (escape hatch `EPIC_BRANCH_PUSH_VERIFY=true`), move
      the gate-stop line to stdout, and have `dispatch_epic` scan stdout+stderr for gate-stop
      markers at all rc values plus return an additive `gate_stop` key. Rejected the
      dedicated always-on-base worktree option — whole worktree lifecycle/GC cost to let a hook
      test a tree with zero new commits in it.
      Done 2026-09-16, PR #382 (`fix/issue-381-epic-branch-push-hook`, 998d9b0), same day as
      filing — checkbox missed at the time. Both fixes landed as designed above; 30/30
      epic-branch, 55/55 fleet-dispatch, 9/9 dispatch_epic tests. Confirmed against current
      `main` 2026-09-19 while closing out Step 7b.

---

## Step 1 — Commercial evidence MVP (runs.jsonl)

**Plan:** `~/.claude/plans/based-on-all-we-eager-valley.md`
**Audit:** "Provable Fleet" artifact, 2026-09-05 (private) — 20-section audit of what the
platform can prove from its own data.
**Size:** three PR-sized branches, no schema change, no new services.
**Openspec changes** (proposed 2026-09-05, all 4/4 artifacts complete, `openspec validate --strict`
clean). Sequence — apply strictly in this order, one `/opsx:apply` + PR per change:
1. `commercial-evidence-run-identity` (Branch A)
2. `commercial-evidence-runs-jsonl` (Branch B) — depends on A's `run-identity.sh`/`META|run-id`
3. `commercial-evidence-fleet-cost-events` (Branch C) — depends on B's `runs.jsonl`/`merge-poll.sh`

Makes the three facts a buyer needs recordable per run: whether the PR actually **merged** and
when (today `gh pr merge --auto` fires and nothing learns the result), **which run / version**
produced an outcome (no run-id, no plugin version, re-runs append to one log), and **USD cost**
(fleetd writes the harness `total_cost_usd` to `{tid}-gen{N}.json` and never reads it). Plus
human approval actor/time from Linear `IssueHistory`.

Design invariant: `META|outcome` stays the pipeline log's last line (both terminal classifiers
read only the last line), so **every post-outcome fact goes to `logs/runs.jsonl`** — an
append-only event log with four kinds: `run`, `merge`, `cost`, `human`.

- [x] **A — `feat(ticket-auto-pipeline)`: run identity, version stamp, ticket-meta, per-run
      postmortem.** Openspec: `commercial-evidence-run-identity`. New `lib/run-identity.sh` (single writer for `META|run-id` + `META|version`,
      called by both `ticket-preamble.sh` and the router's Step 0.6 with `--new`; log-based
      "open run" guard, not env); `META|ticket-meta` from `get_issue` (+`estimate startedAt
      completedAt`); `pipeline-postmortem.sh` run_id from the last `META|run-id` (today it is
      constant per ticket, so post-mortem fires once ever); `preamble.py` passes
      `TICKET_RUN_TRIGGER=fleetd`. Merged 2026-09-05 (PR #299, ticket-auto-pipeline 0.40.0).
- [x] **B — `feat(ticket-auto-pipeline)`: runs.jsonl record, merge poll, Linear history.**
      Openspec: `commercial-evidence-runs-jsonl`. `META|pr-created` in ticket-verify (capture the `gh pr create` URL — it is not captured
      today), `META|cache-tokens` as a *separate* line (four consumers sum every slash field of
      `META|tokens`), guarded `META|complexity` in gate-check; new `lib/run-summary.sh` (window =
      last `META|run-id` → EOF, counters via detect-resume's exact grep patterns, never sources
      detect-resume.sh); new `lib/merge-poll.sh` (the one merge-truth implementation:
      `gh pr view --json state,mergedAt,mergeCommit`, 10-min re-poll floor, 14-day stale);
      `get_issue_history` in linear-api.sh; `pipeline-finalize.sh` appends `run` + one-shot
      merge sweep + `human` event after the outcome line, all fail-soft. Merged 2026-09-05
      (PR #300, ticket-auto-pipeline 0.41.0).
- [x] **C — `feat(fleet-controller)`: worker cost events, merge-poll cadence, generation/version
      env.** Openspec: `commercial-evidence-fleet-cost-events`. `worker_cost_usd()` beside `worker_return_text`; read in reap and fleet-kill paths
      before the generation-file sweep; `cost_usd` on the exit record + `cost` event;
      `FLEET_GENERATION`/`FLEET_VERSION` in worker env (neither exists today); merge-poll sweep
      every `FLEET_MERGE_POLL_CYCLES` (10) as a bash subprocess. Merged 2026-09-05
      (PR #301, fleet-controller 0.22.1).

**Step 1 complete** (2026-09-05): all three branches implemented, tested, and merged to main.
Dexter follow-up (below) can start now.

Follow-up in the **dexter repo** (separate plan, not tracked here): The Bench executive view
reading `runs.jsonl` — five tiles (autonomous merge rate, cycle time P50/P90, cost per merged
ticket, first-pass rate, post-merge defects 30 d) with n / window / Wilson CI / maturity badge;
fix the `success_rate` denominator (excludes held tickets today); cohort → ticket drill-down.
Also a recovery-success tile — a query over `run` + `cost` events, no new instrumentation.

Evidence Phase 2 (after Step 4, see below): `exit_class` incl. timeout + persisted detection
events; post-merge defect/revert scan on the merge SHA with 7/30/90-day delayed windows; queue
wait (rides on the human-hold migration); merge-conflict rate under parallel dispatch.

---

## Step 2 — Skill-version attribution (measurement Phase 1, **reduced**)

**Plan:** `~/.claude/plans/no-edits-write-up-composed-fountain.md`
**Memory:** `project_skill-version-attribution-phase1`
**Openspec change:** `skill-prompt-fingerprint` (proposed 2026-09-05, 4/4 artifacts,
`openspec validate --strict` clean). One PR. Note the plan is stale on two points the change
corrects: Step 0 made `agents/*.md` **live** prompt material (they must be fingerprinted, the
plan says the opposite), and the emission is one field on `META|version`, so
`spawn-helper.sh` is untouched — the Step 2 / Step 4 conflict listed below no longer applies.

Step 1A already ships `META|run-id` and `META|version` (plan items 3–4) and Step 1B ships
`runs.jsonl` — so this plan shrinks to the prompt-material fingerprint and stops needing a
bash grouper:

**Status: implemented 2026-09-05 on `feat/skill-prompt-fingerprint` (ticket-auto-pipeline 0.42.0).**

- [x] 1. `prompt_manifests` block in `skills/ticket-flow/dispatch-table.json` — 12 skills.
      Membership verified per skill, not grepped: `ticket-appraise-exec`'s "Run
      `/ticket-implement`" and `ticket-appraise`'s "`/ticket-appraise-exec`" are both prose
      inside user-facing handoff blocks and are excluded.
- [x] 2. `hooks/skill-fingerprint.sh` (SessionStart, third, after lib-sync) +
      `lib/skill-version.sh` + 24 tests. ~0.2s per run.
- [x] 3. `skills` `{sha256, manifest_n}` + `skills_unresolved` **on the existing
      `META|version` object** — not a second line, `spawn-helper.sh` untouched.
      `run-summary.sh` needed no change; that passthrough is now asserted by test.
- [x] 4. ~~`META|run-id` at Step 0.6 + postmortem suppression fix~~ — delivered by Step 1A
      (`commercial-evidence-run-identity`), nothing to do here.
- [x] 5. Grouping is a `jq` group-by over `runs.jsonl` — a documented query in
      `pipeline-log-format.md`, not code. No bash grouper written; a cohort test in
      `test-run-summary.sh` pins the property.
- [x] 6. Docs (`pipeline-log-format.md`, `CLAUDE.md`), version bump 0.41.0 → 0.42.0, CHANGELOG

**Two corrections to the change's own design, found during implementation:**

1. The spec said the work set is `steps[].spawn.skill`, which yields **9** skills. The design's
   own count ("12 distinct skills") only holds if `post_dispatch`, `sub_steps` and `sequence`
   entries count too — all four shapes carry `instructions` that `spawn_agent_pre` concatenates
   into `AGENT_PROMPT`. Implemented as the broader union: 12 distinct across 15 blocks.
2. **Host-side skill copies shadow the plugin's** on this machine:
   `~/.claude/skills/ticket-implement/SKILL.md` is 30083 bytes vs the plugin's 30794 (same for
   `ticket-verify`, `app-knowledge`). `spawn-helper.sh:487` emits `Run /ticket-implement`
   unqualified, so resolution may pick the stale host copy — the exact failure D2 guards against,
   at a root the design did not anticipate. Manifests follow the design (`plugin:` for
   `SKILL.md`), which is correct on a clean install. **The fix is to run
   `ticket-auto-pipeline/install.sh`**, which archives these leftovers; it has never been run
   here. Worth doing before trusting a fingerprint on this box.

- [ ] 8.6 End-to-end on one real ticket — not run: needs the tickets host. Verify with
      `grep '|META|version|' logs/<TID>-pipeline.log | jq -r '.skills | keys | length'` and
      confirm the same object appears in that run's `runs.jsonl` `run` event.

Still observational: no randomisation, task mix drifts, models change underneath. Report deltas
per version with n and CI; say "associated with", never "caused". Without Step 1B's merge truth
there is no verified outcome to group by — which is why this now sits second.

Later measurement phases (local `verifier_results`/`phase_attribution` tables, traces + Langfuse
canary, score shipping) remain **optional** and unscheduled.

---

## Step 3 — Human-hold / external-wait (remainder)

**Plan:** `~/.claude/plans/go-over-the-current-soft-dahl.md`
**Memory:** `project_human-hold-external-wait`
**Openspec changes** (proposed 2026-09-06, both 4/4 artifacts, `openspec validate --strict`
clean). Sequence — apply strictly in this order, one `/opsx:apply` + PR per change:
1. **`human-hold-store-foundation` — implemented 2026-09-06 on
   `feat/human-hold-store-foundation` (fleet-controller 0.23.0), 41/41 tasks, `make
   lint`/`fmt-check`/`check-generated`/`test` all green.** Schema v2 (`gate_held` → `held` +
   `hold_kind`/`hold_id`/`hold_generation`/`hold_attempts`/`notify_state`/`notified_at`/
   `escalated_at`/`released_at`), additive forward migration in `store.py` (`_MIGRATIONS` table,
   v1→v2 declared non-additive — verified no production store exists), the `set_hold`/
   `release_hold` CAS pair (`mint_hold_id`), the `held=1` spawn guard in
   `_consume_queue_locked`, and `Supervisor._hold_reconcile_pass` wired into the **live**
   `run_observe` loop on `gate_hold.is_due(...)`/`FLEET_GATE_RECONCILE_INTERVAL` for the existing
   `gate` kind. `gate_hold.py` gained a fourth outcome, `UNAVAILABLE` (probe timeout,
   undocumented exit code, or an unregistered kind), distinct from `hold` — `human` is reserved by
   the CHECK constraint and resolves to `UNAVAILABLE`, never released, never gate-stopped, so this
   change and the dependent one below are safe in either review order. Ships standalone value:
   gate holds get a live reconciler for the first time. The store/CAS/wiring half of Step 3 is
   done — `human-hold-protocol` below is now unblocked.
2. **`human-hold-protocol` — implemented 2026-09-06 on `feat/human-hold-store-foundation`
   (ticket-auto-pipeline 0.43.0, fleet-controller 0.24.0), 43/43 tasks (two are inherently
   live/operational and are follow-ups below, not unchecked work), `make lint`/`fmt-check`/
   `check-generated`/`test` all green.** `=== HUMAN_HOLD ===` marker + `human-hold-parse.sh`
   (redaction, four refused fields, `absent` writes nothing while `invalid` still logs), the
   preamble section, `held: human` in `pipeline-finalize.sh`, `detect_human_hold` and
   `fleet_notify_hold` (both pipeline-log-driven — live today, no store dependency), the `human`
   release predicate registered into `gate_hold.py`'s dispatch, `post_human_hold_comment` +
   `human_hold_attempt_exceeds_max` (`HUMAN_HOLD_EXHAUSTED`), `human_hold_requested`/
   `human_hold_parse_status` on `runs.jsonl`'s `run` event. `needs-info` reused unchanged.

Makes "blocked on a human" a first-class recoverable fleet state — a hold is a row, not a stalled
process. Reviewed to 10/10 on 2026-09-03. Step 0 already removed its two urgent bug fixes.

**Four corrections to the plan, found while writing the changes (three while proposing, one while
implementing):**

1. **Detector severity caps at 1, not 2.** The plan specifies severity 1 at 2h → **2** at 24h,
   reasoning "severity 3 triggers intervention, and a ticket must never be killed for waiting on
   a person." That is off by one here: severity **2** already *is* an intervention — *KILL: touch
   stop files, finalize pipeline log*. On a held ticket that kills nothing (the router exited
   cleanly) and finalizes the log **over** the `held:` outcome, which is the hold's own audit
   record and the line both terminal classifiers key on — the escalation meant to raise the alarm
   would make the waiting ticket look finished. Step 0 reached the same conclusion independently
   for `detect_abandoned`. So the cap is 1, and the 24h escalation moves to the **notifier**
   (gated on `escalated_at`), which is the mechanism that actually reaches a person anyway.
2. **`run-summary.sh` needs no fix.** `lib/run-summary.sh:110` already greps `held:` as a
   substring, so a `held: <kind>` outcome is bridged correctly today. Downgraded from a fix to a
   pinning test, which ships with change 2.
3. **The v1→v2 rename is declared non-additive**, so it refuses rather than silently migrating —
   safe only because no production store exists. The migration machinery added in change 1
   governs v2 onward, and v2 is the last version permitted to take that shortcut. Once it exists,
   the evidence queue-wait column (carry the enqueue timestamp into `workers`) is a one-liner.
4. **`fleet_notify_hold`'s idempotency keys off a per-ticket sidecar file, not the store's
   `notify_state` column** design.md D7 names as authoritative. A bash library cannot write the
   fleet state store — fleetd is its sole writer — and the row carries no question/blocks text
   regardless, so the notifier needs the pipeline log either way. It keeps `{tid}-hold-notify.json`
   instead, exactly the pattern `fleet_slack_post` already used for its own thread bookkeeping.
   Every observable guarantee in the spec (one send per hold, restart-safe, failure retried,
   escalate once) holds under this mechanism; only the storage location moved.

Regression fixture: `fleet-controller/lib/tests/fixtures/human-hold-160h-pipeline.log` — synthetic
and scrubbed (no real ticket data exists to replay; the actual 160h incident used a different,
pre-this-mechanism ask-form), shaped like the incident this change targets.

**Follow-ups, deliberately deferred rather than guessed at:**

- **No live caller creates a `hold_kind='human'` row yet.** Nothing calls `store.set_hold` for a
  fresh human-hold request — the same pre-existing, explicitly accepted gap
  `human-hold-store-foundation` left for the `gate` kind ("`gate_hold.py` has no live caller").
  `post_human_hold_comment`/`human_hold_attempt_exceeds_max`/the `human` predicate all ship
  tested and ready; wiring `META|human-hold` → `store.set_hold` → Linear comment → first notify
  is real, scoped follow-up work, not done here speculatively.
- **Task 8.2 (measure real emission rate) needs a week of real runs** — cannot be done from this
  session. `human_hold_requested`/`human_hold_parse_status` now exist on `runs.jsonl`'s `run`
  event specifically so this is a `jq` query once runs exist, per design.md's Risk: if the rate
  stays near zero, the honest conclusion is the preamble channel doesn't work and the request must
  come from somewhere deterministic — do not build further consumers before that measurement.
- **Task 9.5 (end-to-end against real Linear)** needs a live fleetd + a scratch ticket on the
  tickets host — same "live verification pending" status prior changes in this queue have shipped
  under (e.g. `fleet-reconcile-gate-retry`).
- **Migrating the four legacy ask-forms** (`needs-info` label alone, `[needs-human]` in
  `notes.md`, `META|human-decision`, prose in an agent return) onto this mechanism — explicitly
  out of scope per design.md's Open Questions; revisit once the emission-rate measurement above
  lands, since migrating onto an unused mechanism is wasted work.

---

## Step 4 — RLVR phase-result contract

**Openspec changes:** `rlvr-phase-result-contract`, then `rlvr-verdict-recompute`
(note: `openspec/` is gitignored — these exist only on local disk)
**Memory:** `project_rlvr-return-contract`

Agent returns a machine-readable claim; bash recomputes; the delta is the reward signal. On the
critical path to workflow-driven execution and to finishing fleetd phase supervision.

1. **`rlvr-phase-result-contract` — merged earlier (PR #279), archived.** The
   `=== PHASE_RESULT ===` transport, `lib/phase-result-parse.sh`, and the
   `META|phase-result` channel for the three loop-bearing phases (IMPLEMENT,
   VERIFY, PR-REVIEW). Observe-only; nothing routes on it. **Gap carried
   forward, not fixed here:** `runs.jsonl`'s `run` record still has no
   `phase_result_emitted` field, so emission rate has not actually been
   measured yet — the consumer-gating condition this change specified is
   still open.
2. **`rlvr-verdict-recompute` — implemented 2026-09-06 (ticket-auto-pipeline
   0.44.0), 15/17 tasks (2 telemetry-review tasks are gated on real-run data,
   not done here), `make lint`/`fmt-check`/`test` all green.** New
   `lib/verdict-recompute.sh` (VERIFY only): reuses `phase-result-parse.sh`'s
   parser (sourced, log-free) for the claim and `return-completeness-check.sh`'s
   section-scoped checkbox counter (sourced) for the verified side — counts
   `- [x]`/`- [ ]` in `verify-session.md`'s `## Step trace`, gated on the file
   postdating the phase's own bracket-open line. Emits `META|claim-delta` with
   `direction` (`aligned`/`optimistic`/`pessimistic`/`unknown`). Wired into
   `skills/ticket-auto/SKILL.md` immediately after `phase-result-parse.sh`,
   same observe-only guarantees. 17/17 new tests.

If the follow-up's `direction` comes back `aligned` on essentially every ticket, the routing
increments get **dropped** — that is an intended outcome, not a failure.

---

## Step 5 — Agent Observer

**Plan:** `~/.claude/plans/delightful-spinning-snowglobe.md`
**Memory:** `project_agent-observer-plan`
**Openspec change:** `agent-observer` (implemented 2026-09-06, 43/43 tasks; `openspec/` is
gitignored, exists only on local disk).

**Merged 2026-09-06 on `feat/agent-observer` (PR #309, fleet-controller 0.25.0).**
`fleetd/observer.py`, a fleet-wide sidecar modelled on `otel.py`'s own
spawn/backoff/reap/stop supervision, tails phase workers' `--output-format stream-json
--verbose` transcripts (opt-in via `FLEET_OBSERVER_ENABLE`) and computes 8 deterministic
findings — `CLAIM_CONTRADICTION`, `REPEATED_FAILURE`, `SCOPE_VIOLATION`, `UNEXPECTED_TOOL`,
`RUNAWAY_COST`, `LONG_TOOL_CALL`, `DEGRADED_SESSION`, `PERMISSION_DENIED` — against a
per-phase contract (`build_phase_contract`) sourced from the dispatch table and each agent's
own `agents/*.md` frontmatter. Findings surface via a new `findings` table (schema v3,
PROJECTION class), `/health` counts, a `fleet-dashboard.sh` FINDINGS column, and
`detect_observer_findings` (16th detection engine, hard-capped at WARN). Fully inert by
default — confirmed via two full `make test` runs with `FLEET_OBSERVER_ENABLE` unset.

Both urgent side-findings from the plan were resolved as part of this change rather than
filed separately: `--agent` threading turned out to already exist (the plan's premise was
stale against an installed-plugin-cache lag, corrected in the change's own design doc), and
the phase-slug sweep leak (`fleetd/supervisor.py`'s stale-generation-file sweep matching only
`{tid}-gen{N}`, never `{tid}-{phase}-gen{N}.*`) was fixed directly in Inc 1
(`_sweep_stale_generation_files` now takes a `phase` param).

Probe fixtures used: `fleet-controller/fleetd/tests/fixtures/stream-json-*.ndjson`.

---

## Step 6 — Agent Mesh MVP (PC agent ↔ server agent)

**Held (2026-09-06): do not start until a few real ticket runs have exercised the recent
batch of changes** (Steps 3/4/5 — human-hold, RLVR verdict recompute, agent-observer — plus
the commercial-evidence branches). All of it is implemented and unit-tested but largely
unverified against live fleetd/Linear traffic on the tickets host. Agent Mesh's task-delegation
phase (Phase 3) adds another consumer of the same reap path several of those changes just
touched (`fleetd/supervisor.py`) — better to know the current batch is solid first than debug
two layers of new behavior at once.

**Partial de-risking done 2026-09-06:** verified against `../tickets` directly — Linear API
key live (`viewer` query succeeds), `gh` CLI authenticated, and fleetd now actually boots
clean from that workspace with a real config (see Step 0's env-check-gate entry above — this
is what surfaced that bug). Still missing before the hold lifts: an actual ticket run through
live fleetd on that host, which is what would exercise Steps 3/4/5's reap-path changes for
real.

**Plan:** `~/.claude/plans/i-want-you-to-zesty-quilt.md`

Investigated 2026-09-06: how much of an Agent Mesh foundation (identity, capabilities,
endpoint, status, permissions, trust) already exists, and the smallest step to get two
Claude agents on different machines discovering, delegating, and returning structured
results. Verdict: ~60% of the foundation exists; no new major infrastructure component
needed — fleetd's existing loopback HTTP server, reached over an SSH tunnel with a bearer
token, is the endpoint.

**Not started.** Four-phase plan in the file above:
- Phase 0 — prove communication (zero code: systemd fleetd + SSH tunnel + curl).
- Phase 1 — agent identity + registration (`agent_id`, bearer token, `GET /agent` card,
  threading HTTP server, `FLEET_AGENT_ID` stamped alongside `FLEET_GENERATION`).
- Phase 2 — capabilities + discovery (derive from `fleet-env-check.sh` + installed
  `agents/*.md`, cached; client-side `FLEET_MESH_PEERS`, no server-side registry).
- Phase 3 — task delegation (`POST /tasks` with `run_prompt`/`run_ticket`; the reaper needs
  a `reason`-keyed branch — modelled on the existing otel-exporter branch — so a mesh task
  is never misclassified as an orphaned ticket and re-enqueued).
- Phase 4 — evidence (assemble existing `PHASE_RESULT`/exit-record/`runs.jsonl` objects;
  no new trust primitive).

Cut from MVP: `run_phase` (phase-level dispatch isn't rolled out yet), a server-side
`/peers` registry, mTLS/signing/RBAC, dexter Workflows integration.

---

## Step 7 — Tracker decoupling, Track A (near-term) — COMPLETE, archived

**Plan:** `~/.claude/plans/something-that-has-been-soft-gosling.md`
**Openspec changes** — all 3 merged to main and archived (2026-09-19), specs synced into
`openspec/specs/`:

1. **`tracker-client-consolidation`** (merged via PR #385, archived
   `openspec/changes/archive/2026-09-19-tracker-client-consolidation`) — five raw-`curl` transports
   collapse onto `lib/linear-api.sh` behind a new `get_epics_by_label`, one declared unwrapped
   response shape, uniform retry. Fixed a real production defect: `_get_initiative_labels`
   (`fleet-feedback.sh:31`) read `.data.issue.labels.nodes[]` from already-unwrapped `get_issue`
   output and returned **empty on every call**, so per-initiative feedback grouping never worked.
2. **`tracker-label-audit`** (merged via PR #385, archived
   `openspec/changes/archive/2026-09-19-tracker-label-audit`) — classified every declared label as
   `control` / `human-signal` / `vestigial` with file:line evidence in `docs/label-audit.md`, then
   stopped writing only the vestigial ones (`claimed` confirmed vestigial, zero readers repo-wide).
3. **`tracker-read-failure-policy`** (merged via PR #386, CI green, archived
   `openspec/changes/archive/2026-09-19-tracker-read-failure-policy`) — two declared read classes
   through one helper; decision reads resolve fail-closed, informational reads degrade soft. Fixed
   the unsafe degrade-open at `fleet-dispatch.sh:658-670` (**BREAKING**: an unreadable blocker now
   withholds the child instead of dispatching it). Converted `LINEAR_FETCH_FAILED` from a terminal
   gate-stop into a retryable hold.

Addressed both halves of the operator complaint — a quieter board, and a tracker outage that no longer
halts the pipeline — without an event system, a schema change, or moving state authority.

**Outstanding on Track A:** tasks 6.3/6.4 (client-consolidation), 7.1–7.4 (label-audit), and 7.4/7.5
(read-failure-policy) are all "run a real ticket end to end on the tickets host" live-verification
items, still unchecked in the archived task files. Code is merged; only real-traffic confirmation is
open. Roll these into whatever live-verification pass lifts Step 6's hold.

## Step 7b — Tracker decoupling, Track B Phases B1-B2 — COMPLETE, archived; B3a — COMPLETE, PR #397 merged; B3b — COMPLETE, merged PR #399; B4 — COMPLETE, merged PR #400

**Openspec change:** `tracker-event-vocabulary-and-emitter` — proposed 2026-09-19, applied same day
via explicit `/opsx:apply` instruction, ahead of Step 6's hold (the plan file's own ordering would
have held this for Step 6 first — overridden here by direct request, not by re-litigating the
ordering). Merged via **PR #388** (2026-09-19), archived
`openspec/changes/archive/2026-09-19-tracker-event-vocabulary-and-emitter`, specs synced (new
capabilities: `tracker-event-outbox`, `pipeline-event-vocabulary`). Version-bumped to
ticket-auto-pipeline 0.50.15 / fleet-controller 0.31.13.

**CI caught a real bug before merge**: `events.sh`/`fence-check.sh` both did `set -eo pipefail`
unconditionally at file scope. `epic-branch.sh` and `fleet-intervene.sh` (this phase's dual-write
wiring) source `events.sh` unconditionally too, and both are themselves sourced by
`fleet-monitor.sh` — so the flags leaked into the whole monitor chain, exactly the class of bug
`fleet-dispatch.sh` already documents and works around for `linear-api.sh`. Fixed by scoping the
`set` to direct execution only (matching the CLI-entrypoint guard `fence-check.sh` already had),
with a regression test in each library's test file. Confirmed separately with a scratch-dir smoke
test against a real, terminal ticket before pushing the fix.

**Remaining, by explicit instruction to skip and move to B2:**
- Tasks 10.1/10.2 — a live ticket run confirming gate-held/human-hold/PR-open/merge/fleet-kill each
  produce a matching outbox entry, and that the Linear board + pipeline log stay byte-identical.
  Deferred, same as Track A's own outstanding live-verification items — roll into whatever
  live-verification pass eventually lifts Step 6's hold.
- Task 7.7 — `blocked`/`unblocked` are declared in the vocabulary but have no wired call site: the
  `blocked-by:*` auto-removal feature they'd describe was found to never have been implemented (see
  the pre-existing finding below) — wiring dual-write into a mutation that doesn't exist isn't safely
  doable in this phase. Follow-up ticket needed to either implement the feature or drop it from the
  vocabulary.
- Task 7.5's manual-router path (`ticket-auto/SKILL.md`) has no `verify-failed-retrying` wiring —
  only fleetd's phase-dispatch path does. Acceptable for now since phase-dispatch is not yet the
  default, but worth closing before B2 if it touches the same sites.

Phase B1 of 5 (B1 event vocabulary + emitter → B2 pusher/drivers → B3 local facts replace ticket
reads → B4 inbound approval → B5 second board), per the plan's own convention of one
`/opsx:propose` + `/opsx:apply` + PR per phase — not proposed as one combined change.

**Scope:** a new append-only per-ticket event outbox (`lib/events.sh` `emit_event`) and the closed
event vocabulary it writes, dual-write only — nothing consumes the outbox yet, nothing the pipeline
reads changes, the Linear board is unaffected. Collapses `pr-review-pass-done`/`-uat` into one
`pr-review-passed{uat_required}` fact (the destination-encoding root cause no earlier draft touched),
adds 9 previously-unemitted facts (`gate-held`, `human-hold-requested`, `pr-opened`, `pr-merged`,
`blocked`/`unblocked`, etc.), and splits `state-machine.json` into `workflow.json` + a driver-table
placeholder for B2. New capabilities: `tracker-event-outbox`, `pipeline-event-vocabulary`.

**B2 (pusher/drivers) implemented 2026-09-20, also by explicit instruction ahead of Step 6's hold** —
same override as B1. Openspec change `tracker-event-board-pusher`: all 47 tasks done via
`/opsx:apply` — `lib/board-cursor.sh` (flock-guarded cursor), `lib/board-drivers/linear.sh` (the one
shipped driver, no-op for every event this phase covers), the `jsonl-audit` test fixture,
`skills/ticket-flow/outbox-drain.sh` (wired into `pipeline-finalize.sh` at every router exit),
`fleet-controller/fleetd/pusher.py` (the same drain as a periodic fleetd pass, gated
`FLEET_BOARD_PUSHER_ENABLE=false`), and `detect_outbox_staleness` as fleet-controller detector #19.
`workflow.json`'s `board_drivers.linear` is now `{}` (registered, no mappings). Version-bumped to
ticket-auto-pipeline 0.51.0 / fleet-controller 0.32.0. Merged via **PR #392** (2026-09-20), CI green
(`lint-and-test: pass`), archived `openspec/changes/archive/2026-09-20-tracker-event-board-pusher`,
specs synced (new capabilities: `tracker-board-driver-contract`, `tracker-board-pusher`; plus an
ADDED-requirements delta merged into the existing `fleet-detection` spec for the new detector —
note the sync appended it as its own requirement rather than folding it into the existing
"aggregator includes N detectors" requirement text, which still reads 12; cosmetic drift, not
functional). Pre-existing, unrelated `ticket-planner` test failure (`test-planner-body-template-
humanizer.sh`, EpicGen humanizer citation) confirmed present on `main` before this branch — not
fixed here, out of scope.

Per design.md Decision 1, the router's ~dozen existing direct `flow.sh` call sites are deliberately
**not** rerouted through the pusher in this phase — the literal "flow.sh becomes the pusher's
executor" reading is a large behavioral inversion sized as its own phase, not a B2-sized addition.
Filed as a standalone, agent-handoff-shaped follow-up rather than left as only a queue entry — this
repo has a real precedent for that stalling (`pipeline-integrity-consolidated-plan`, archived with
39/48 boxes unchecked): **[issue #391](https://github.com/willard-pro/claude-plugins/issues/391)**,
"Migrate flow.sh-driven call sites through the tracker event-board pusher."

B2 is now merged. **B3a implemented 2026-09-21, same explicit-override basis as B1/B2** — openspec
change `tracker-local-facts-read-migration`, proposed and applied same day per the plan's per-phase
convention (this phase split into read-side-only B3a vs. write-side B3b, an implementation-time
refinement of the plan's original single "B3" phase). All 52 tasks done:

- New `ticket-auto-pipeline/lib/manifest-read.sh` / `manifest-write.sh` — the local manifest
  (`manifest.json` per ticket and per epic, plus an initiative index) every migrated call site reads
  instead of a live Linear label/description fetch. `TICKET_LOCAL_MANIFEST_DISABLE` kill switch
  centralized in one function, so every site inherits it for free.
- Migrated: `resolve_planner_dir`, `branch-resolve.sh`'s three resolvers, `epic_branch_children_done`
  + `ensure_epic_branch`'s drift-refresh, `fleet-detect.sh`'s D-10/D-11 (D-12 partially — the
  readiness check is local, epic *enumeration* is not, see task 3.2's scope note), the whole of
  `fleet-dispatch.sh`'s eligibility/blocked-by resolution, `gate-check.sh`, `appraise-fast-path.sh`,
  `planned-ticket-check.sh`/`planned-ticket-body-check.sh`, `ticket-setup/setup.sh`,
  `planner-ticket-validate.sh`/`planner-phase-prompts.sh` (ticket-planner's write side, unchanged —
  EpicGen/TicketGen now also *write* the manifest), `outcome-label-check.sh`, three type-label sites
  including fleetd's `phase_dispatch.py`, and `epic-precondition.sh`'s epic discriminator. Both
  dashboards (`dashboard.py`, `fleet-dashboard.sh`) gained hold-reason/blocked-by/dispatch columns.
- **Design-invalidating finding corrected during implementation**: the design's premise that
  ticket-planner "already writes body.md/exploration.md/proposal.md" per-ticket was false — that
  directory was never populated (every reader already had a live fallback, which is why it was
  invisible). Fixed by having the manifest writer create the directory itself.
- **Real regression caught in verification, not by the implementing agent**: `manifest-read.sh`
  declared a bare global `SCRIPT_DIR` (copied from this codebase's own prevailing convention), which
  — once `epic-precondition.sh`'s migration made it transitively sourced by `flow.sh` — clobbered
  `flow.sh`'s own `SCRIPT_DIR` and broke every `flow.sh` invocation. Caught by independently
  re-running `ticket-flow/tests/phase1.sh` rather than trusting the fork's summary; fixed by
  namespacing the variable. A reminder that "tests pass" claims from delegated work need independent
  re-verification on the specific suites most likely to catch cross-file effects, not just the files
  that were directly touched.
- Pre-existing, unrelated `ticket-planner` flakiness (`test-planner-body-template-humanizer.sh` /
  `test-planner-lib-root.sh`, different test failing each run under `make test-planner`) reproduced
  on unmodified `main` too — confirmed not a regression, not fixed here.
- **Not done**: the 4 live-verification tests (9.3-9.6) — need a real Linear workspace + tickets
  host.

**Committed and merged 2026-09-23**, sha `2f4a90a` on `feat/tracker-local-facts-read-migration`,
**PR #397** (merge commit `ee09697`). Pre-PR `make lint && make fmt-check && make test` all green.
No Co-Authored-By trailer per repo convention.

**Ordering reconsidered by explicit instruction, 2026-09-23**: originally B3b was gated on 9.3-9.6
running clean first, on the reasoning that B3b removes B3a's own rollback safety net (label writes,
kill switch, per-site live fallback) and shouldn't do that before B3a itself had ever been live-
verified. The user chose to reorder instead: **all live-verification testing (9.3-9.6, and whatever
B3b/B4/B5 add) is deferred to one consolidated pass, run against a real epic on one of the user's own
projects once the whole plan is implemented** — rather than gating each phase on its own live run.
**Tradeoff flagged and accepted**: this means B3b (and potentially B4/B5) will be built on read/write
paths that have never been exercised against a live Linear workspace, compounding whatever B3a
verification would have caught. Accepted in favor of not fragmenting live-testing into N separate
passes, each requiring the same real-workspace setup. **B3b is unblocked to start now.**

**B3b implemented 2026-09-23, same explicit-override basis as B1/B2/B3a** — openspec change
`tracker-local-facts-write-migration`, proposed and applied same day. All 20 tasks done via
`/opsx:apply`, but the change is a **no-op on the write side by design**: the re-audit (Section 1 of
the change's tasks.md) re-ran the code-reader and documented-consumer searches for the six labels
whose `control` evidence B3a relocated (`planned`, `blocked-by:*`, `state:execution`, the five type
labels, `Smooth`/`Rough`/`Hard`) and found that every B3a-migrated call site is manifest-first with
an **unchanged live-label fallback** — the exact rollback net B3a's own design describes — and that
`Smooth`/`Rough`/`Hard`'s read was never touched by B3a at all (explicit in-file comment). All six
are reconfirmed `control` on that still-live fallback reader alone; none reached the vestigial
question, so no operator confirmation was needed and no write, `workflow.json` declaration,
`planner_verify_tickets` assertion, or `manifest-read.sh` fallback changed. Findings recorded as a
dated addendum in `ticket-auto-pipeline/docs/label-audit.md` (additive, original 2026-09-19 audit
untouched). Only file changes: `docs/label-audit.md` (addendum) and this file — no code, no version
bump needed. Pre-existing `test-planner` flakiness (a different test fails each run under
`make test-planner`, passes standalone every time) reproduced again here — same pattern as B3a,
confirmed unrelated to this doc-only change. **Not yet committed/PR'd as of this writing.**

**B4 proposed 2026-09-23 as `tracker-inbound-approval`, same explicit-override basis as B1-B3b, then
revised same day after 3-reviewer pass (safety, code-grounding, scope/consistency — per standing
feedback).** 4/4 artifacts, `openspec validate --strict` clean. The reviewers together surfaced a
proposal-invalidating finding for the originally-scoped item (3): every one of `gate-check.sh`'s
approval-read sites already does an unconditional live Linear fetch before reading `approved` (so a
manifest-first read would skip zero fetches), and `approved` — unlike every field B3 migrated — is
not monotonic (it can be revoked, including by a direct Linear-UI label edit outside `flow.sh`), so
caching it for a gate *decision* would be a real false-approval risk for no offsetting benefit.
Revised scope: **`gate-check.sh`'s approval-decision reads are untouched by this phase, full stop**
— no manifest involvement of any kind, not even as a fallback-preserving optimization. What remains:
(1) `_gate_hold_intake_pass` on `Supervisor`, symmetric to `_human_hold_intake_pass`, closing the
gap that `hold_kind='gate'` store rows are today only created behind `FLEET_PHASE_DISPATCH_ENABLE`
(still `false` by default) — scoped to the 3 approval-type hold reasons (`complex-ticket`,
`manual-mode`, `default-fallback`) after code-grounding review found `_gate_emit_held` actually has
8 call sites, not 3 — the other 5 are content/fetch holds that resolve by a gate re-run, not an
approval decision, and get no store row from this pass; (2) `approved`/`approval_provenance`
(`human`|`policy`) added to the ticket manifest, **informational-only** — feeds `runs.jsonl`'s
human-approval attribution (retiring a second independent re-derivation from live `IssueHistory`)
and future dashboards, never read by a decision path. Also fixed: an ordering mismatch between
design.md's Migration Plan and tasks.md's task groups, a punted-not-resolved Open Question (now
resolved: no exhaustion cap needed — existing per-hold-kind severity/escalation already covers it
once the row exists), and a silently-dropped scope item from the source plan
(`detect-resume.sh:470-492`'s approval read — now an explicit Non-Goal, not migrated, for the same
staleness reason as gate-check.sh). Explicitly **not** in scope: a new Slack/comment notifier for
gate holds (they release by label/state only, same as today). Ready for `/opsx:apply`.

**B4 implemented 2026-09-23 via `/opsx:apply`.** All 22 tasks complete. Shipped: (1) outbox
completeness — `_gate_emit_released` calls added at Check 5 (`"policy"`) and Check 2.8c/Check 4's
manual-mode overrides (`"human"`), pairing every approval-type `_gate_emit_held` call with a release;
(2) `manifest-write.sh` gained `set_ticket_approval` (writes `approved`/`approval_provenance`,
clears both on `false` — overwrite-not-append, same shape as `outcome_label`); `flow.sh` gained
`--provenance <human|policy>` (default `human`) threaded through `human-approve`/`pr-iterate`, the
manifest write sequenced strictly after the post-trigger assertion succeeds (both the idempotent-skip
and real-mutation exit paths), and `re-claim` clears the fields via the same call; `gate-check.sh`
Check 5 passes `--provenance policy` explicitly; a grep sweep found one more policy-driven call site
needing it — `ticket-pr-iterate/SKILL.md`'s own `pr-iterate` invocation (machine-driven re-approval
after a PR cycle, per design.md) — now passes `--provenance policy` too; (3)
`pipeline-finalize.sh`'s `runs.jsonl` human-approval attribution reads the manifest's
`approval_provenance` first, live `IssueHistory` scan only as fallback; (4) a guard-only regression
test pins that Checks 2.8b/2.8c/4/reapprove never read the manifest for their approval decision
(stale manifest `approved:true` still holds/gate-stops when live Linear disagrees); (5)
`Supervisor._gate_hold_intake_pass` (fleet-controller/fleetd/supervisor.py) — symmetric to
`_human_hold_intake_pass`, reads each ticket's outbox for the latest unreleased `gate-held` event
whose reason is one of the 3 approval-type reasons, mints a `hold_kind='gate'` store row via the same
primitives, posts no comment/notification (per design.md Non-Goals), wired into `run_observe`
unconditionally (not gated behind `FLEET_PHASE_DISPATCH_ENABLE`). Regression tests: 6
`test-gate-check.sh` cases (3 release-pairing, 4 stale-manifest-ignored — one shared helper covers
2 of the 7), 2 `test-manifest-write.sh` cases, 1 `test-pipeline-finalize.sh` case (manifest-present
vs. live-fallback), 3 `flow.sh` cases (`phase1.sh`: policy provenance, default-human provenance,
re-claim clears both fields), 6 `GateHoldIntakePassTest` cases in `test_supervisor.py` (fresh
approval-type hold, idempotent re-run, content-type hold ignored, released hold ignored,
phase-dispatch hold not duplicated, no comment/notify called). Full suite green: `make
check-generated && make lint && make fmt-check && make test` (the one `test-planner` failure —
`EpicGen prompt cites issue #285: not found` — reproduces identically on unmodified `main`, confirmed
via `git stash`; pre-existing, unrelated). `fleet-controller/fleetd/tests/test_supervisor.py`'s 13
pre-existing subprocess-spawn/health-endpoint failures (`SingleInstanceTest`,
`StartupEnvCheckGateTest`, `HealthEndpointTest`, etc.) also reproduce on unmodified `main` —
sandbox/loopback environment flakiness, unrelated. Version-bumped to ticket-auto-pipeline 0.53.0 /
fleet-controller 0.34.0, committed and opened as **PR #400** (2026-09-23) on
`feat/tracker-inbound-approval`, then archived as `2026-09-23-tracker-inbound-approval` via
`openspec archive -y` (2 specs updated: `gate-hold-intake` created, `ticket-local-manifest` gained
2 requirements — `openspec validate --specs --strict` clean, 51/51). PR #400 merged 2026-09-23.
Live-verification (hold a ticket at the gate, confirm the store row via the default path;
approve via label, confirm `runs.jsonl` provenance) intentionally deferred to the single
consolidated live-verification pass covering B3a/B3b/B4, per the same reordering decision recorded
above.

B5, as originally scoped ("second board" — GitHub Issues alongside Linear, proving the driver owns
the mapping), remains unproposed and is **superseded by Step 7c below**, not merely deferred: B1-B4
built the outbox, the no-op driver and informational-only manifest fields, but none of it stopped a
single label from being written, which was always the operator's actual complaint
(`tracker-label-audit`, 2026-09-19, removed exactly one — `claimed`). Step 7c is the change that
finishes what B5 was pointed at the wrong target to fix.

**Track B in full is behind next.md Step 6.** The plan file carries the complete 5-phase design
(event emitter and outbox, board drivers with per-board `event → column` tables, local facts,
approval intake, second board) — a rewrite of the coupling layer across five plugins. Its real value
is tracker *portability*, not needed until a second board is actually wanted.

Three findings from the Track B design work that stand on their own, whether or not it ever runs:
- **Gate holds create no store row on the default path.** `store.set_hold(..., 'gate', ...)`'s only
  caller is `_create_phase_dispatch_hold`, gated behind `FLEET_PHASE_DISPATCH_ENABLE` (default false).
  Any future work assuming "held tickets are rows" is wrong for the primary hold type.
- **`auto_remove_when: blocker_reaches_done`** (`state-machine.json:40`) is declared and **never
  implemented** — referenced only by a test asserting the key exists.
- **`_plog` silently drops any line whose MSG contains `|`** (`heartbeat.sh:42-46`, returns 1, and its
  three existing JSON callers ignore the return code). Fine for metadata, disqualifying for any
  channel of record.

---

## Step 7c — Tracker decoupling, Track B: the authority flip (labels off Linear, approval by script) — Change 1 (`tracker-approval-by-script`) implemented 2026-09-23, PR #401 open; Changes 2/3 still PROPOSED

**Why this exists:** 2026-09-23, after B4 shipped, the operator restated the original complaint
directly — Linear tickets are noisy with labels, and none of B1-B4 addressed that. Investigation
confirmed it: `update_issue` has exactly one non-test caller (`flow.sh:462`) and every trigger still
adds/removes real Linear labels on every run; B3a's manifest-first reads all kept a live-label
fallback, which made B3b's re-audit reconfirm all six migrated labels `control` rather than let any
of them stop being written — the rule (`tracker-label-inventory`: "only vestigial labels may be
removed") and the fallback held each other in place. B4's own design explicitly declined to make
`approved` a decision read, reasoning that the label is revocable out-of-band via the Linear UI —
true only because the label *was* the approval act.

**The operator's target, stated directly:** a human approves via a script call that writes
`approved` to local metadata; the ticket becomes information-tracking and comments only; Linear
labels stop carrying machine state. Two decisions taken before proposing: approval path is
**script-only** (no label read as input, closing B4's revocation objection by removing its
premise); the four **human-signal** labels (`needs-info`, `needs-adr`, `rejected`, `reviewed`)
remain as board-driver *projections* — pure output, nothing reads them back.

**Plan:** `~/.claude/plans/radiant-juggling-candle.md` — built from a 3-agent codebase inventory
(every Linear write site, every approval/state decision read, the full outbox→driver push path)
and reviewed by 3 independent agents (approval-safety, removal-completeness, projection-design)
before being finalized. Three openspec changes, one PR each, in this order — later changes depend
on manifest fields and classifications the earlier ones add, so the order is load-bearing, not
just a size-limiting convention:

1. **`tracker-approval-by-script`** — **IMPLEMENTED 2026-09-23, 40/40 tasks, PR #401 open.**
   New `/ticket-approve` / `/ticket-reject` commands are the only approval actuator; manifest
   gains `stage`; all six approval-decision reads (`gate-check.sh` Checks 2.8b/2.8c/4/reapprove via
   a new shared `_gate_manifest_approved` helper, `detect-resume.sh`'s `GATE_HELD` resume, fleet-
   detect D-18) move to the manifest with no tracker fallback; `approved` stops being written
   (`human-approve`/`pr-iterate.adds`, `implement-complete`/`re-claim.removes` in `workflow.json`).
   Adds a fourth label classification, **`projected`**, to `tracker-label-inventory` — a control
   label whose every read has been relocated with no fallback remaining, which is the rule that
   actually permits a write to stop (the missing piece B1-B4 never added); `approved` is the first
   label this audit has ever reclassified off `control` (`docs/label-audit.md`). Ad-hoc
   (non-planned) tickets get a reserved `_adhoc` initiative via new `ensure_ticket_manifest` so
   they're manifest-addressable at all. One-shot `manifest-backfill.sh` seeds in-flight tickets
   (`--dry-run` supported). Clean `git revert` rollback — the label is never removed from existing
   issues, only stops being written to new transitions.
   Two real bugs found and fixed during implementation, neither anticipated by the plan: (1) a
   latent `set -e` landmine in `manifest-read.sh`/`manifest-write.sh` — a bare `var=$(failing_cmd)`
   aborts the caller's whole script under `set -e` (which `flow.sh`/`gate-check.sh` both set) before
   the return code can even be checked, now guarded with `|| rc=$?` everywhere a failed manifest
   read is a normal outcome; (2) `_write_approval_manifest` never cleared the manifest's `approved`
   fact on `implement-complete` (only `re-claim`) — silently safe under B4 since nothing read the
   field, but load-bearing now for the `uat-fail`-returns-to-`Ready`-without-reapproval invariant
   design.md calls out, so a dedicated regression test (`test_uat_fail_never_observes_approved_true`,
   `phase1.sh`) pins it. Also found `gate-check.sh`/`detect-resume.sh` never sourced
   `manifest-read.sh` themselves — both run as their own `bash` subprocess, so the pre-existing
   Check 2.7b manifest-first read was unreachable in production before this change added the
   source lines. Full suite green (`make check-generated && make lint && make fmt-check && make
   test`, incl. one real regression this change's own doc-rewrite caused in
   `test-pipeline-phases.sh`, fixed). Versions bumped: `ticket-auto-pipeline` 0.53.0→0.54.0,
   `fleet-controller` 0.34.0→0.35.0. Task 9.4 (live verification on the tickets host) deferred to
   the programme's consolidated live-verification pass, per the same reordering decision B3a/B3b/B4
   already used.
2. **`tracker-flow-projection-cutover`** (proposed, 70 tasks) — `flow.sh` stops calling Linear
   entirely; manifest gains `flags`/`rev`/`pending_event`; `emit_event` gains an idempotency key so
   a crash between manifest-write and emit can't double-fire; `board_drivers.linear` becomes the
   real projection table (columns + the four human-signal labels only, non-projected labels like a
   hand-applied `bug` always preserved); pusher flips default-on. **One-way door** — no kill switch,
   rollback is a `git revert`. Migration hazard caught in review: every existing host's outbox
   cursors sit at 0 (the pusher's been opt-in since B2), so flipping the default without a cursor
   fast-forward would replay each ticket's full transition history and flap its column through
   every past state — now a spec requirement (`tracker-board-pusher`) with the code landing
   pusher-still-off and the default flip as a separate, later commit per host.
3. **`tracker-planner-and-fallback-cutover`** (proposed, 51 tasks) — the planner stops stamping
   `planned`/`INIT-*`/`blocked-by:*`/`state:execution`/type/`pre-approved` at ticket and epic
   creation; every remaining B3a live-fallback branch is deleted. Gated on a parity step: two
   fleet-detect engines (D-12 `_fleet_scan_epic_branch_ready`, D-18
   `_fleet_scan_stalled_approved_children`) currently enumerate epics via a live
   `state:execution` query with **no manifest path at all** — reviewed and confirmed worse than
   first scoped: D-12 also needs the live epic state for its never-regress short-circuit and the
   live description for the Branch Directive, D-18 also needs the live children list. Task group 1
   builds and verifies local enumeration for every input (not just population) against a real
   fleet *while labels are still written*, records the comparison as a durable artefact, and only
   then lets group 4 (planner stops writing) proceed — that group is marked the point of no return.

All three validated `openspec validate --strict` clean as of 2026-09-23. Change 1
(`tracker-approval-by-script`) is implemented (40/40 tasks, PR #401 open) — see its entry above.
Changes 2/3 are not started. Track B remains the next queued work ahead of Step 6 by the same
direct-override precedent B1 used; Change 2 (`tracker-flow-projection-cutover`) is next up once
Change 1's PR merges, since it depends on manifest fields (`flags`/`rev`/`pending_event`) and the
`projected` classification Change 1 just added.

---

## Ordering rationale

1. **Active harm first.** Step 0's first two items mean held tickets are invisible to every
   detector and can be marked done while still waiting. Cheapest fixes in the backlog, largest
   real-world cost today.
2. **Sales evidence accrues in calendar time.** Step 1 is the proof the platform can be sold on:
   every week without `runs.jsonl` is a week of merges, costs and approvals that can never be
   reconstructed (merge truth is not in any log; `--auto` merges leave no local trace). It also
   subsumes the run-id/version half of the old attribution plan, so doing it first removes work
   from Step 2 rather than adding to it. The 30-day defect tile and any percentage with n ≥ 30
   need elapsed time nobody can engineer around — start recording now.
3. **Attribution needs a verified outcome to group by.** Step 2's "did this skill edit help?"
   is unanswerable against self-reported `completed`; with Step 1B's confirmed merges it becomes
   an observational cohort query. Hence 2 after 1, and much smaller than before.
4. **Schema work in one place.** Step 3 owns the store migration; Step 1 avoided touching the
   schema so it never blocks on it, and the evidence queue-wait column rides on Step 3's
   migration for free.
5. **Dependencies last.** Step 5 genuinely needs Step 4. Step 4 unblocks programmatic
   orchestration generally, and `runs.jsonl` gives it an emission-rate measurement for free.
6. **Largest and most diagnostic last.** Once Step 0 extracts its urgent findings, the observer's
   remaining value is investigative rather than corrective.

### Parallel track

The Dexter executive view (Step 1 follow-up) lives in another repo and only needs `runs.jsonl`
lines to exist — it can start as soon as Step 1B merges and run alongside Steps 2–3 without a
file conflict.

### Known scheduling conflicts

- ~~Step 2 and Step 4 both edit `ticket-auto-pipeline/lib/spawn-helper.sh`~~ — resolved by the
  `skill-prompt-fingerprint` design: emission is a field on the existing `META|version` line
  written by `run-identity.sh`, not a per-phase line at `phase_bracket_open`, so Step 2 does not
  touch `spawn-helper.sh` at all.
- Step 1A/B and Step 2 both edit `lib/ticket-preamble.sh` and `lib/run-identity.sh` (Step 2
  extends the `META|version` object). Sequential, in that order.
- Step 1C and Step 3 both edit `fleetd/supervisor.py`'s reap path and worker env. Sequential.

### Repo conventions that apply to every step

- Bump the plugin version on each branch (marketplace update detection).
- `make lint && make fmt-check && make test` before opening any PR.
- `shfmt -i 2` — run `make fmt`, not bare `shfmt`.
- Never pipe `make test` into another command; redirect to a file (the spawn-helper test leaks
  orphans that hang the pipe).
- `make check-generated` must stay green — none of the steps above touches
  `dispatch-table.json` except Step 2 item 1, which must regenerate `ticket-auto/SKILL.md`.

---

## Archive

_Move completed steps here with the date and PR number._
