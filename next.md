# Next — pipeline work queue

Ordered backlog for the ticket-auto / fleet-controller pipeline. Ordering rationale is at the
bottom. Update the checkboxes as work lands; move completed steps to the archive section.

> Public repo — no ticket IDs, no customer data in this file.

**Overnight 2026-11-12 (autonomous, 01:10–05:00):** merged #699 (drift report, Step 18 item 3),
#700 (ARCH-8), #701 (triage), #702 (PO-9), #703/#710 (DET-SU-1/2), #704 (ARCH-3), #705
(paraphrase, Step 18 item 2), #706/#709 (Step 12 item 7), #707 (DET-AP-5), #708 (ARCH-4), #711
(CRITIQUE_NOT_RUN), #712/#714 (goldfish review lens, wired, flag off), #715 (DET-PL-4). Step 9 item 5 was already fixed by #528.
Every merged change's live check is on the tickets host. ARCH-5 and ARCH-9 have since been designed and merged (see below).

**Evening 2026-11-12:** ARCH-9 **merged #717** (board cursors start at the outbox origin sidecar;
ticket-auto-pipeline 0.116.0 / fleet-controller 0.50.0). Its live check (tasks 5.2–5.4) passed on a
demo Linear project, so the board pusher now defaults **on**: **merged #718** (fleet-controller
0.51.0). ARCH-5 design decided by the operator (fleetd fails its boot gate on an anchor mismatch;
no relocation tool, manual move documented; `FLEET_STATE_DIR` out of scope; strays re-projected by
hand). ARCH-5 **merged #720** (resolver, writers, router preamble, `state-root-doctor.sh`;
ticket-auto-pipeline 0.117.0 / fleet-controller 0.52.0) and **#721** (fleetd exports the anchored
log dir and fails its boot gate on an anchor mismatch; fleet-controller 0.53.0). Before upgrading a
host, run `state-root-doctor.sh` and `fleet-env-check.sh --log-dir`, and confirm fleetd starts with
`--state-dir` (unchecked in the dexter container). `STATE_ROOT_STRICT` stays off until hosts are
anchored; flipping it is a later PR.

**2026-11-13:** tickets host upgraded to ticket-auto-pipeline 0.117.1 / fleet-controller 0.53.0.
**#723** (0.117.1): `state-root-doctor.sh` skips test fixtures, plugin copies and pipeline worktrees
(it reported 16 state dirs on a clean host). ARCH-5 live check: anchor = `tickets/logs` (written by
fleetd at boot, nothing moved), boot gate passes, a trigger fired from a repo subfolder landed in the
anchored outbox and moved a throwaway TetrisOne ticket in Linear, a router from the wrong cwd is
refused. Open: 6.4's worker-environ check rides on the next real dispatch. ARCH-9 task 0.2: the
tickets host has no outboxes at all, so the pusher has nothing to replay.

Last reviewed: 2026-11-09 (see the 2026-11-09 housekeeping note below). Earlier: 2026-09-23 (Step 7 Track A merged and archived — all 3 changes landed, PRs #385/#386;
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

Updated 2026-09-27: Step 7c Change 1 (`tracker-approval-by-script`, PR #401) and Change 2
(`tracker-flow-projection-cutover`, PR #402) both merged to `main`. Change 3
(`tracker-planner-and-fallback-cutover`) **fully implemented, all 7 groups, all 51 tasks** — groups
1-3 landed earlier as PR #424 (`ticket-auto-pipeline` 0.56.0, `fleet-controller` 0.37.0); this
session finished groups 4-7 on the same branch: the planner (`ticket-planner`) now creates every
epic and ticket with **zero Linear labels** — the 10 retired labels' facts all live in the local
ticket/epic manifest instead; the remaining live-fallback deletes (`phase_dispatch.py`'s
`resolve_ticket_type`, `fleet-detect.sh`'s D-11/D-12/D-18 live paths, the
`TICKET_LOCAL_MANIFEST_DISABLE` kill switch) are gone; `workflow.json`'s `planner_labels` section is
deleted; docs (`label-audit.md`'s final disposition, `ticket-planner`/`ticket-auto-pipeline`/root
`CLAUDE.md`, `fleet-controller/README.md`, `kc-import/SKILL.md`, `CHANGELOG.md`) are updated; and
versions are bumped (`ticket-auto-pipeline` 0.57.0, `fleet-controller` 0.38.0, `ticket-planner`
0.11.0, `knowledge-curator` 0.2.1). Full test sweep (148 bash files + the whole `fleetd` pytest
suite) shows zero regressions from this work — every failure found is confirmed pre-existing on
unmodified `main` via `git stash`. **Task 1.7/1.7a's live parity run was explicitly WAIVED by
explicit user decision (2026-09-27)**, not merely deferred: no real fleet with live `state:
execution` epics was available in this dev checkout, and the user chose to proceed through the full
cutover (including the label-write removal that makes 1.7a's diff-based evidence permanently
unproducible for any future epic) rather than pause to arrange one. Task 7.4's live end-to-end
functional verification on the tickets host is the sole live-fleet evidence this change will ever
have. See `ticket-auto-pipeline/docs/label-audit.md`'s final disposition entry for the full record
of the waiver and the disposition of every formerly-`control` label.

**Correction, 2026-09-30:** PR #424 merged the same day this note was written (2026-09-27) — the
"hard blocker before merge" framing above was stale by the time it was read back in a later
session. Task 7.4's live verification remains genuinely outstanding, but as a post-merge item now
rolled into Step 8's consolidated live-verification pass, not a pre-merge gate. See Step 7c below
for the corrected per-change status.

**Housekeeping, 2026-09-30:** 27 fully-merged and never-started openspec changes archived to
`openspec/changes/archive/2026-09-30-<name>/` (`--skip-specs` — specs for the merged ones were
already synced by hand at merge time, so the CLI's own spec-delta step was skipped to avoid
double-applying). `complexity-classifier-calibration` was deliberately left active (real,
unscheduled backlog item); `langfuse-evidence-layer` was left alone (still in progress, 96/112
tasks). None of these were referenced from a `next.md` Step by name except where noted inline
below. 14 plan files under `~/.claude/plans/` covering the same shipped/abandoned work were
deleted at the same time — where a Step below cited one of them, the citation is marked deleted
rather than removed, to keep the historical record intact.

**Updated 2026-10-04:** new Step 9. `planner-business-framing` (PR #440) and `ticket-create-skill`
(PR #441, ticket-auto-pipeline 0.62.0) both merged on 2026-10-03. The live checks for both are
still open, and so is a follow-up on the gap between the templates and the DoR checks — see Step 9.

**Updated 2026-10-11:** new Step 10, Slack-interactive planning. Two OpenSpec changes were proposed
and validated: `planner-headless-questions` here, and `slack-interactive-planning` in the dexter
repo. The claude-plugins change ships first. Later the same day `planner-headless-questions` was
implemented on `feat/planner-headless-questions` (ticket-auto-pipeline 0.63.0, ticket-planner
0.16.0, grill-me 0.2.0); the dexter change has not started and needs those pins.

**Updated 2026-10-23:** `complexity-classifier-calibration` (the backlog item left active in the
2026-09-30 housekeeping) implemented on `feat/complexity-classifier-calibration`
(ticket-auto-pipeline 0.71.0). The specs were amended first for seven weeks of drift (#367, #413,
tracker decoupling). Retro now emits `complexity_calibration` (false-simple rate from the simple
row only); appraise scores weighted axes with a new Reversibility axis; fast path escalates on it.
PR #548. Baseline: 6/9 simple tickets on one workspace went Rough/Hard (0.667), all from the
now-finished Java 25 upgrade project, so there is no tuning follow-up. The new model will be
validated on new feature tickets in a later retro window.

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

**Plan:** `~/.claude/plans/based-on-all-we-eager-valley.md` (deleted 2026-09-30 — work shipped, see below)
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
Openspec changes `commercial-evidence-run-identity`/`-runs-jsonl`/`-fleet-cost-events` archived
2026-09-30 (`openspec/changes/archive/2026-09-30-commercial-evidence-*`).
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

**Plan:** `~/.claude/plans/no-edits-write-up-composed-fountain.md` (deleted 2026-09-30 — work shipped, see below)
**Memory:** `project_skill-version-attribution-phase1`
**Openspec change:** `skill-prompt-fingerprint` (proposed 2026-09-05, 4/4 artifacts,
`openspec validate --strict` clean). One PR. Note the plan is stale on two points the change
corrects: Step 0 made `agents/*.md` **live** prompt material (they must be fingerprinted, the
plan says the opposite), and the emission is one field on `META|version`, so
`spawn-helper.sh` is untouched — the Step 2 / Step 4 conflict listed below no longer applies.

Step 1A already ships `META|run-id` and `META|version` (plan items 3–4) and Step 1B ships
`runs.jsonl` — so this plan shrinks to the prompt-material fingerprint and stops needing a
bash grouper:

**Status: implemented 2026-09-05 on `feat/skill-prompt-fingerprint` (ticket-auto-pipeline 0.42.0).
Archived 2026-09-30 (`openspec/changes/archive/2026-09-30-skill-prompt-fingerprint`).**

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

**Plan:** `~/.claude/plans/go-over-the-current-soft-dahl.md` (deleted 2026-09-30 — work shipped, see below)
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

Both changes archived 2026-09-30 (`openspec/changes/archive/2026-09-30-human-hold-store-foundation`,
`openspec/changes/archive/2026-09-30-human-hold-protocol`).

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
   same observe-only guarantees. 17/17 new tests. Archived 2026-09-30
   (`openspec/changes/archive/2026-09-30-rlvr-verdict-recompute`).

If the follow-up's `direction` comes back `aligned` on essentially every ticket, the routing
increments get **dropped** — that is an intended outcome, not a failure.

---

## Step 5 — Agent Observer

**Plan:** `~/.claude/plans/delightful-spinning-snowglobe.md` (deleted 2026-09-30 — work shipped, see below)
**Memory:** `project_agent-observer-plan`
**Openspec change:** `agent-observer` (implemented 2026-09-06, 43/43 tasks; `openspec/` is
gitignored, exists only on local disk). Archived 2026-09-30
(`openspec/changes/archive/2026-09-30-agent-observer`).

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

**Plan:** `~/.claude/plans/something-that-has-been-soft-gosling.md` (deleted 2026-09-30 — work shipped, see below)
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

## Step 7c — Tracker decoupling, Track B: the authority flip (labels off Linear, approval by script) — COMPLETE, all 3 changes merged. Changes 1/2/3 MERGED (PR #401, PR #402, PR #424 — #424 merged 2026-09-27, correcting this section's earlier "not yet mergeable" status). Task 7.4's live end-to-end verification on the tickets host is the only item from this programme still outstanding — rolled into Step 8's consolidated live-verification pass below. Task 1.7/1.7a's pre-cutover parity run was explicitly waived by the user rather than performed; see `label-audit.md`'s final disposition entry.

**What remains after this closes:** a second board driver (only `lib/board-drivers/linear.sh` is shipped; the projection architecture — `board_drivers` in `workflow.json`, `board-cursor.sh`, `pusher.py` — was built driver-agnostic on purpose, but nothing has proposed a second one) is still unproposed. That is the next natural step for this program, whenever a second tracker becomes a real requirement — nothing in this repo currently needs it.

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

**Plan:** `~/.claude/plans/radiant-juggling-candle.md` (deleted 2026-09-30 — work shipped, see below) — built from a 3-agent codebase inventory
(every Linear write site, every approval/state decision read, the full outbox→driver push path)
and reviewed by 3 independent agents (approval-safety, removal-completeness, projection-design)
before being finalized. Three openspec changes, one PR each, in this order — later changes depend
on manifest fields and classifications the earlier ones add, so the order is load-bearing, not
just a size-limiting convention:

1. **`tracker-approval-by-script`** — **IMPLEMENTED 2026-09-23, 40/40 tasks, merged via PR #401
   (2026-09-23).**
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
2. **`tracker-flow-projection-cutover`** — **IMPLEMENTED 2026-09-23, 70/70 tasks, merged via
   PR #402 (2026-09-23)** (9.3 and 10.10
   deferred to the programme's consolidated live-verification pass — both need real Linear
   credentials this sandbox doesn't have). `flow.sh` stops calling Linear entirely: no
   `get_issue`/`get_team`/`update_issue`, no post-trigger assertion (exit 7 retired, every consumer
   updated — `skill-preamble.md`/`-auto.md`, `fleetd/orchestration.py`, `fleetd/phase_dispatch.py`).
   It is now a local state machine: reads `workflow.json` + the manifest, writes the manifest
   (`stage`/`flags`/`rev`/`pending_event`, always in one atomic call via the new
   `set_ticket_transition`/`set_epic_transition` — called on every invocation, not skipped when
   unchanged, which is what keeps a structurally-nil trigger like `implement-outcome`/`re-claim`
   from ever losing its event) and emits exactly one outbox event, idempotency-keyed `{tid}:{rev}`
   (`emit_event` gained `--idem`, dedup'd under the existing per-ticket lock). `board_drivers.linear`
   went from `{}` to the real projection table — every vocabulary event has an `events` entry
   (object or explicit null), `projected_labels` is exactly `needs-info`/`needs-adr`/`rejected`/
   `reviewed`, enforced by a coverage test; `lib/board-drivers/linear.sh` now writes real desired
   state, caches team metadata, preserves labels it doesn't own, and classifies failures
   (permanent → `META|board-projection|fail` + skip; repeated → dead-letter after
   `FLEET_BOARD_MAX_ATTEMPTS` + `BOARD_PROJECTION_STALLED` Slack notify). `Simple`/`Complex` removed
   against `docs/label-audit.md`'s own deferred `vestigial` finding — `COMPLEXITY_OPPOSITE` and the
   three #170-pinning `phase1.sh` tests deleted with them. `pr-review-passed` emission moved from
   `branch-resolve.sh`'s `uat_decide_trigger` (a decision helper) onto `flow.sh` itself, after the
   verdict gate. **One-way door** — no kill switch, rollback is `git revert` with a caveat (see
   design.md Migration Plan / `fleet-controller/README.md`'s new "Migrating to board projection"
   section). `FLEET_BOARD_PUSHER_ENABLE` deliberately still defaulted `false` here (flipped to
   `true` in #718 once board-cursor-first-drain #717 removed the replay hazard) —
   the migration hazard caught in review (every existing host's outbox cursors sit at 0, so
   enabling projection against them replays full history) is real and the fast-forward step
   (`skills/ticket-flow/board-cursor-fastforward.sh`, new, tested against a counting stub driver
   proving replay-vs-no-replay by invocation count) is a per-host operator action documented in
   `CHANGELOG.md` and `fleet-controller/README.md`, not part of this code landing. Full suite green
   (`make check-generated && make lint && make fmt-check && make test`); versions bumped
   `ticket-auto-pipeline` 0.54.0→0.55.0, `fleet-controller` 0.35.0→0.36.0.
3. **`tracker-planner-and-fallback-cutover`** — **IMPLEMENTED, all 51 tasks, all 7 groups, merged
   via PR #424 (2026-09-27).** The planner stops stamping
   `planned`/`INIT-*`/`blocked-by:*`/`state:execution`/type/`pre-approved` at ticket and epic
   creation; every remaining B3a live-fallback branch is deleted (confirmed on `main`:
   `workflow.json`'s `planner_labels` section is gone, `TICKET_LOCAL_MANIFEST_DISABLE` kill switch
   is retired). Task group 1's parity step (local enumeration verified against a real fleet while
   labels were still written, for the two fleet-detect engines — D-12
   `_fleet_scan_epic_branch_ready`, D-18 `_fleet_scan_stalled_approved_children` — that had no
   manifest path at all) is the durable artefact that let group 4 (planner stops writing) proceed
   past the point of no return. `ticket-auto-pipeline` 0.57.0, `fleet-controller` 0.38.0,
   `ticket-planner` 0.11.0.

All three validated `openspec validate --strict` clean as of 2026-09-23 and are now merged to
`main`. This closes the Track B authority-flip programme; task 7.4's live end-to-end verification
is the only outstanding item, rolled into Step 8's consolidated live-verification pass.

All three changes (`tracker-approval-by-script`, `tracker-flow-projection-cutover`,
`tracker-planner-and-fallback-cutover`) archived 2026-09-30
(`openspec/changes/archive/2026-09-30-tracker-*`).

---

## Step 8 — Definition of Ready (DoR) readiness gate — all phases implemented; live verification pending

**Plan:** `~/.claude/plans/when-working-on-the-delightful-ocean.md` (deleted 2026-09-30 — work
shipped, see below; re-scoped 2026-09-27 after a live-evidence report over both tickets hosts and
a 3-reviewer + second-agent pass).
**Openspec changes**, strictly in this order, one `/opsx:propose` + `/opsx:apply` + PR each:
1. `dor-readiness-gate-foundation` (ticket-auto-pipeline + fleet-controller) — merged
2. `dor-quality-score` (ticket-auto-pipeline, diagnostic score + 2 hard codes) — merged
3. `planner-phase-count-derivation` (ticket-planner, mechanical prep) — merged
4. `dor-semantic-evaluator` (ticket-auto-pipeline, LLM scan/audit contract) — merged
5. `planner-refinement-phase` (ticket-planner, halt-only) — merged, **supersedes
   `planner-readiness-phase`**
6. `planner-ready-by-construction` (ticket-planner + ticket-auto-pipeline) — merged
7. `readiness-feedback-loop` (fleet-controller + ticket-planner) — merged

All 7 changes are implemented and merged, and all 7 archived 2026-09-30
(`openspec/changes/archive/2026-09-30-{dor-readiness-gate-foundation,dor-quality-score,
planner-phase-count-derivation,dor-semantic-evaluator,planner-refinement-phase,
planner-ready-by-construction,readiness-feedback-loop}`). Only item 4 below (the consolidated
live-verification pass) remains.

**Why this exists:** planner-cut tickets reached a worker with no Scope / Navigation Path / Test
User section and no test data, and were stopped only at the entry gate after a worker was already
spent — `PLANNED_BODY_INCOMPLETE` on 27/52 WIL tickets, `held: gate` "plan missing N/M verification
prerequisites" ×12, `CRITIQUE_BLOCKED` ×6. **52 % of WIL and 22 % of CRE tickets** hit a readiness
stop post-dispatch: 2–4 wasted worker generations, 2–8 h wall clock and one human Linear edit each;
one CRE ticket sat 40 days. Verify-time "no test user" failures are zero — the cost lands at
dispatch → gate, so the fix is a **pre-dispatch** gate. `exit-path.sh` has no readiness class, so
`runs.jsonl` currently reports every one of these as `none`.

**Shape:** manifest `ready` object (hard codes + advisory codes + per-code waivers); slim
`lib/dor-check.sh` (hard: Scope / Nav / Test User section presence, AC present + not vague, repro
for bugs, `needs-info` flag; advisory in v1: catalog role resolution, test-data, Verification Plan
— promotable per host via `DOR_STRICT_*` env once a host seeds its `test-users.json`, which neither
host has today); hard refusal in `fleet-dispatch.sh`, fleet-detect D-11/D-18 and a new gate-check
Check 2.7e `TICKET_NOT_READY`; backfill that enumerates from the initiative index (the log glob
misses undispatched Backlog tickets — and zero ticket manifests exist on either host today);
`exit-path.sh` `readiness` class. Then a new planner phase `Readiness` between TicketGen and
Completed — scan → derive → halt with questions → `resume --answer/--waive/--confirm-enablers` →
apply, enablers created as `chore` children in `blocked_by` and stamped ready at creation; epic
`dispatch=true` moves there. Inline `AskUserQuestion`, planner-written Verification Plans and the
feedback loop are later increments.

**Two live defects folded into change 1** (found by review, confirmed on `main`): gate-check 2.7
and `planned-feedback-write.sh` treat "manifest exists" as "planned", but `flow.sh` now creates an
`_adhoc` manifest for every ad-hoc ticket on its first trigger; and `needs-info-resolved` is
declared in `workflow.json` with zero callers, so a `needs-info` flag can never clear.

**Success criteria for the first shippable increment (changes 1 + 3):** no new planned ticket can
be fleet-dispatched or run via `/ticket-auto` while not-ready; missing Scope / Nav / Test User is
caught before any worker is spent; legacy tickets are waived and keep running; ad-hoc tickets are
untouched.

- [x] 1. `dor-readiness-gate-foundation` — propose, apply, PR. Merged 2026-09-30 via **PR #425**
      (`ticket-auto-pipeline`/`fleet-controller` version-bumped). Mandatory `manifest-backfill.sh`
      run per host afterwards (CHANGELOG note, same class as 0.57.0's) still outstanding per-host.
- [x] 1b. `dor-quality-score` — merged 2026-09-30 via **PR #426**. Adds `INTENT_MISSING`/`REPRO_NO_EXPECTED_ACTUAL`
      hard codes, `AC_IMPLEMENTATION_ONLY`/`VERIFICATION_REQUIRED_NOT_SELF_VERIFYING` advisory codes
      (strict-promotable), a widened `AC_VAGUE` pass, the diagnostic `dor_quality_score` (0-100,
      never gates), `semantic_coverage_gaps`, body-hash cache invalidation, and the shared dimension
      vocabulary a future semantic evaluator (JEV) writes against. Implemented on
      `feat/dor-quality-score` 2026-09-30 per `openspec/changes/dor-quality-score/tasks.md` (all 10
      sections) — 18 adversarial fixtures + 1 padding fixture, `lib/dor-check.sh` rewritten,
      `manifest-write.sh`'s `set_ticket_readiness` extras arg, `run-summary.sh`/`fleet-dispatch.sh`/
      `fleet-notify.sh` report-only consumers, full test suite green.
- [x] 2. `planner-phase-count-derivation` — merged 2026-09-30 via **PR #427**. Mechanical prep:
      `planner_phase_count`/`planner_phase_position` derived from `planner_phase_sequence`; every
      prompt's "phase N of 10" literal and the test suite's hard-coded counts/indices replaced with
      the derived helpers. Byte-identical prompt output confirmed; full suite green; ticket-planner
      0.11.0 → 0.11.1.
- [x] 2b. `dor-semantic-evaluator` — implemented 2026-09-30, merged 2026-09-30 via **PR #428**.
      LLM semantic DoR pass contract in ticket-auto-pipeline: scan +
      audit agents (`dor-semantic-agent`), block parser (`dor-semantic-parse.sh`, 28 tests),
      `dor_semantic_apply`/`_dor_semantic_normalise` (`dor-semantic.sh`, 25 tests), `set_ticket_semantic`
      (third writer of `ready`, `manifest-write.sh`), `SEMANTIC_*` blocking codes (block from day one,
      per-host relax via `DOR_SEMANTIC_ADVISORY_CODES`), `set_ticket_readiness` preserve/stale rule,
      fleet-dispatch/fleet-notify report-only wiring. Full suite green (2 clean `make test` runs after
      registering the new test files in the Makefile). ticket-auto-pipeline 0.59.0 → 0.60.0,
      fleet-controller 0.40.0 → 0.41.0. **Golden-set live verification only partial**: 2/19 fixtures
      spot-checked with real agents (14-typo-fix matched "no blocking finding"; 01-excellent produced
      3 specific, quote-verified findings against the same expectation — flagged, not yet tuned). Full
      19-fixture sweep + prompt tuning deferred to a live-verification pass before
      `planner-refinement-phase` can safely assume the evaluator's output quality. Plan:
      `~/.claude/plans/gentle-doodling-truffle.md` (deleted 2026-09-30 — work shipped).
- [x] 3. `planner-refinement-phase` — implemented 2026-09-30, merged 2026-09-30 via **PR #430**.
      **Supersedes `planner-readiness-phase`.** New planner phase
      Refinement between TicketGen and Completed (11 phases, up from 10): per-ticket deterministic
      DoR → `dor-semantic-agent` scan → audit → per-ticket blocking; epic stamped `dispatch=true`
      once every child has a verdict, ready or not. TicketGen now persists each body to
      `planner/body.md` and no longer stamps the epic or writes `dispatch-gate` (BREAKING for
      anything grepping that line — a legacy log skips Refinement). New
      `resume --refresh-bodies` (one-shot). `planner_dispatch_gate` removed. No ticket-auto-pipeline
      or fleet-controller code change. New `test-planner-refinement.sh` (41 assertions) + 5 existing
      planner suites updated; full `make test` green. Answers/enablers/body rewrite from the old
      Readiness design stay deferred. **Live verification (task 10) not yet run** — needs a real
      tickets host; roll into item 4 below.
- [ ] 4. Live: one planned epic on a user project through Refinement → dispatch → gate, plus an
      ad-hoc ticket confirming 2.7 is untouched. Roll into the consolidated live-verification pass.
      **Reordered 2026-09-30 by explicit operator instruction**: land every remaining phase
      (items 5a/5b below) before running this — one consolidated live pass at the end, not one
      per change.
- [x] 5a. `planner-ready-by-construction` — implemented 2026-09-30, merged 2026-09-30 via
      **PR #434**. TicketGen writes a `## Verification Plan` table
      (`### Per-Criterion Verification`, one row per AC line, exact `vplan-parse.sh`-compatible
      shape, embedded as a literal fenced example not prose-only) and `## Test Data Prerequisites`
      on every type, not bug-only. Specify feeds it via a new `## Verification Notes` per-AC
      role/test-data signal. New `DOR_STRICT_VPLAN` (ticket-auto-pipeline, default `false`) promotes
      `VPLAN_MISSING`/`VPLAN_ROW_GAP`/`VPLAN_UNVERIFIABLE` to hard together — not enabled on any
      host by this change. No interactive component, no retroactive rewrite, no `vplan-parse.sh`
      contract change. Drafted fresh this session (the only prior design — "Change 2c" in the
      pre-refinement-phase plan file — assumed the since-superseded interactive Readiness design)
      and passed 3 independent reviewer passes (grounding, scope/completeness, architecture/risk)
      before implementation. New `test-planner-vplan-generation.sh` (5 assertions, against the real
      parser) + `test-dor-check.sh` additions (8 assertions) + 2 existing suites updated; full
      `make test` green. ticket-planner 0.12.0→0.13.0, ticket-auto-pipeline 0.60.0→0.61.0.
- [x] 5b. `readiness-feedback-loop` — implemented 2026-09-30, merged 2026-09-30 via **PR #437**.
      Re-scoped fresh against current code (the only prior sketch, "Change 3" in the stale plan
      file, assumed an agent-backed Readiness phase that no longer exists — `replan` was never
      agent-backed either). `fleet-feedback.sh` gains an independent readiness-gap scan (gate-stop
      `TICKET_NOT_READY` codes + verify no-test-user SKIPs), closing a blind spot where a ticket
      that never reached implement never wrote a `planner-feedback` entry and so never surfaced —
      new `summary.readiness_gaps` key on every feedback file, plus a write-loop fix so an
      initiative with only readiness-gap data still gets one written. `planner-replan.sh`'s
      `planner_replan_record` gains an 8th parameter; new `planner_readiness_gaps_compute` sums
      per-key across files (never a shallow merge); `replan` writes one new
      `META|replan-readiness-gaps` line, report-only, never feeding regeneration logic. Deferred a
      `grill-me` `test_readiness` dimension (pinned scoring-boundary arithmetic across 10 existing
      dimensions; structurally disconnected from this loop anyway). Passed 3 independent reviewer
      passes before implementation. New tests: 7 assertions in `test-fleet-feedback.sh` (20/20
      total) + 6 in `test-planner-replan.sh` (35/35 total); full `make test` green. fleet-controller
      0.41.0→0.42.0, ticket-planner 0.13.0→0.14.0. **Live verification not yet run** — roll into
      item 4 above, now the last remaining item before that consolidated pass.


---

## Step 9 — Agent-facing ticket quality: business framing + standard single-ticket creation — both merged; live verification pending

Two changes that make tickets readable by stakeholders and stop agents from creating tickets that
skip the checks. Both were implemented and merged on 2026-10-03.

- [x] 1. `planner-business-framing`: merged via **PR #440**. The planner now writes epics and
      tickets business-first. Each ticket is classified `business` or `enabler`. A business ticket
      gets an `## Outcome` section (Who / Need / Outcome) and traces to outcome ids; an enabler gets
      an `## Enables` section and no fake user story. Business titles carry no paths, routes or
      code symbols. Implementation detail moves to `## Technical Context`. The business-wording
      lint on titles and bodies is a deferred follow-up.
- [x] 2. `ticket-create-skill`: merged via **PR #441** (ticket-auto-pipeline 0.62.0).
      `/ticket-create` and `skills/ticket-create/create.sh` are now the one standard path for
      logging a single ticket: routing (Linear ticket / GitHub issue for marketplace defects /
      `kc-capture` for knowledge), the body section check, the readiness check
      (`check_ticket_ready --no-fetch`), a duplicate check (`search_issues` plus Jaccard over
      `_title_terms`), `create_issue` with no labels, and an `_adhoc` manifest. A `PreToolUse`
      guard (`hooks/ticket-create-guard.sh`) denies direct Linear creates and redirects to the
      skill. `TICKET_CREATE_GUARD=off` opts out. Tasks 1–6 are done (21/23); the openspec change
      is not archived yet.
- [ ] 3. Live verification of `ticket-create-skill` (tasks 7.1 and 7.2). Needs a new session on
      plugin 0.62.0. (a) Ask an agent to "log a bug" without naming the skill, and confirm it uses
      `/ticket-create`, runs the dry run, and creates one ticket with the template layout and an
      `_adhoc` manifest. (b) Confirm a direct MCP `save_issue` create is denied with the redirect
      message, and an MCP update to an existing ticket still works. Can be run on its own (it does
      not need a planned epic), or rolled into Step 8's consolidated live pass. After it passes,
      run `/opsx:archive ticket-create-skill`.
- [ ] 4. Live: one planner run on a real idea, confirming the business-framed titles and sections
      survive TicketGen into Linear. Roll into Step 8's consolidated live pass (item 4).
- [x] 5. **Already fixed by #528 (9f84431, 2026-10-22)** — checked 2026-11-12: `dor-check.sh`'s outcome aliases include `Desired Behaviour`, the security template carries `## Impact` + `## Proposed Changes`, and `_has_section_nav_path` no longer accepts the column header. Original note: two existing mismatches found while building `create.sh`.
      (a) The `improvement` template's `## Desired Behaviour` is not in `dor-check.sh`'s outcome
      aliases, and the `security` template has neither a why heading nor an outcome heading, so a
      body written straight from either template fails with `INTENT_MISSING`. The skill currently
      tells agents to add `## Proposed Changes` as a workaround. Fix the templates or the alias
      list. (b) `_has_section_nav_path` accepts the Verification Plan's "Navigation path" column
      header as a navigation path, so `NAV_PATH_MISSING` is weaker than it looks.

---

## Step 10 — Slack-interactive planning (grill-me + ticket-planner driven by dexter) — proposed, not started

Goal: dexter starts a planning run, and the client and the operator take part only through Slack
(no terminal), over hours or days. Pattern: the plugin writes its questions, the process exits,
and a later invocation resumes with the answers. No process ever blocks waiting on Slack. There
are two OpenSpec changes, one per repo, and the claude-plugins one ships first. Source plan:
`~/.claude/plans/what-i-need-next-peaceful-tarjan.md`, reviewed by architect, QA and analyzer
agents on 2026-10-11.

- [x] 1. **claude-plugins: `planner-headless-questions`** (proposed and validated 2026-10-11;
      implemented 2026-10-11 on `feat/planner-headless-questions`, PR pending — ticket-auto-pipeline
      0.63.0, ticket-planner 0.16.0, grill-me 0.2.0).
      - **Question format:** human-hold Schema-Version 2. The new fields are optional (`ROUND`,
        `KIND`, `AUDIENCE`, plus per-question `ID`, `OPTIONS`, `DEFAULT` and `BINDING`), and v1
        parses byte-identically.
      - **`ticket-planner/lib/planner-stop-describe.sh`:** derives the stop from `state.log`
        deterministically. Halt prose and exit codes are unchanged, and golden tests captured
        first prove it.
      - **`resume --answers <file>`** (`lib/planner-answers.sh`): maps answers onto the existing
        flags (`--create`, `--accept`, `--project`, waivers). It is idempotent per round, and a
        stale round exits 4.
      - **grill-me:** new `--emit-questions` and `--answers` modes, plus a round-cap escalation
        to the operator.
      - **Minor breaking change:** grill-me now needs `GRILL_WORK_DIR` or `REPOS_ROOT` in every
        mode. Accepted 2026-10-11.

      CLI use of ticket-planner is otherwise unchanged. Version bumps: ticket-auto-pipeline,
      ticket-planner, grill-me.

      Implementation notes for the dexter side:
      - ADR questions bind `note`, not `adr:<id>`: `adr-store.sh accept` refuses inside an agent
        session, so the human accepts the ADR out of band and the answer only records it.
      - The answers file carries its own `schema_version: 1`, separate from the hold's
        `SCHEMA_VERSION: 2`.
      - An operator may answer a client question (standing in for the client); a client may
        never answer an operator question.
      - grill-me headless rounds need the same `--id` on every call (or the same brief), since the
        work directory is derived from it.
- [ ] 2. **dexter: `slack-interactive-planning`** (in the dexter repo, proposed and validated
      2026-10-11, 0/34 tasks). It depends on item 1 being released and the plugin pins bumped to
      ticket-planner ≥ 0.16.0, grill-me ≥ 0.2.0 and ticket-auto-pipeline ≥ 0.63.0.
      Dexter pins ticket-planner at 0.15.1 and does not list grill-me at all.
      - **New `plugin_segment` step type:** deterministic. It runs one allowed plugin step under
        `claude -p` with its own timeout and env allow-list, then routes on the describer's
        output rather than on the model's prose.
      - **Spec change:** `workflow-step-contract` is modified to allow `plugin_segment` alongside
        `claude_prompt`.
      - **`interactive-planning` workflow:** the grill-me loop, then the planner loop, then
        operator retry/abort.
      - **Slack bridge:** Socket Mode, two channels (client and operator), roles enforced on the
        server, and exactly one resume per round. It sends reminders but never resumes on its
        own, re-posts open questions after a restart, and runs a scrubber on client-channel
        posts that fails closed.
- [x] 3. Specify stops on `NEEDS_HUMAN_DECISION` — openspec change
      `planner-specify-waiting-on-human`, implemented on feat/planner-specify-decision-gate
      (ticket-planner 0.20.0, ticket-auto-pipeline 0.68.0, following PR #528). No `waiting`
      marker after all: a bash gate halts before Review on an open decision, and an answer or
      `__defer__` replaces the marker line in proposal.md (new reason `SPECIFY_DECISION`, binding
      `specify-answer:O<n>`). dexter must change before using it — see that change's design.md
      § What dexter must change (pins, `AUDIENCE either`, serialised answers, partial rounds, no
      auto-answer, single line of at most 500 characters).
- [x] 4. Two-way chat. When the client asks a question back, a read-only Q&A session answers
      it, running without bypass and using only the initiative's `artifacts/`. Done 2026-10-22
      as `planner-artifact-qa` (ticket-planner 0.21.0, branch `feat/planner-artifact-qa`):
      `lib/planner-artifact-qa.sh` spawns its own sandboxed `claude -p` over a read-only
      snapshot. The dexter side (call it, route its exit codes) is part of item 2.

---

## Step 11 — Test-data derivation + test-data-engineer persona — DONE 2026-10-22 (#526, #527 merged; archived). Live checks (group 9) deferred to next feature

Goal: planner-cut tickets never reach a worker without test data. The planner inventories test
data for the whole epic (Discovery), derives what each acceptance criterion needs (Specify), and
turns every need nobody owns into a test-data ticket that blocks its consumer and whose seed VERIFY
actually loads. A new persona implements those tickets. Gaps it closes: a spec with no
Verification Notes, all-`none` rows when the AC implies data, and Refinement and dor-check treating
both as advisory. Source plan: `~/.claude/plans/lets-add-some-intelligence-merry-flurry.md`, plus
a web scan (no published autonomous pipeline plans test data). Three Sonnet reviewers checked it
on 2026-10-21: one on the heuristic and questions, one on synthesis determinism, one on downstream
effects. Decided with the user: hybrid grouping (a need shared by 2 or more specs goes into one
epic pack, a need one spec has goes into its own sibling ticket), and implied data is asked,
defaulting to generate when headless.

- [x] 1. (merged PR #526) `test-data-engineer-persona` (ticket-auto-pipeline) — ships first. It adds:
      - a base persona plus `testdata/{sql,api,ui-forms,files,factories}` specializers;
      - in `persona-select.sh`, a strong signal (the ticket is a TD ticket) that swaps the base
        persona, a weak keyword signal that adds the persona, and multi-channel selection;
      - additive `PERSONA_TESTDATA*` keys.
- [x] 2. (merged PR #527) `planner-test-data-derivation` (ticket-planner + ticket-auto-pipeline). It adds:
      - a Test Data Inventory in Discovery, and per-criterion derivation in Specify;
      - `VERIFICATION_NOTES_MISSING` and a two-tier `TEST_DATA_IMPLIED`;
      - a `TESTDATA_CONFIRM` answer line in consensus.md, keyed by slug and hash;
      - a `testdata-synth` sub-step, with edges in a sidecar so consumer specs are never edited;
      - an epic UAT stamp from EpicGen;
      - `VERIFY|seed-apply`;
      - strict test-data and Verification Plan checks on contract bodies only.

      **Breaking (gates):** contract-shaped feature and improvement bodies without test data
      now fail readiness.
- [ ] 3. Live verification, folded into Step 8's consolidated pass (tasks 9.1–9.4 of change 2).
- [x] 4. Follow-ups: a semantic DoR backstop for heuristic misses, and a grill-me test-data
      dimension.
      - **dor-semantic half — implemented (advisory)** as `dor-semantic-test-data-gap` on
        `feat/dor-semantic-test-data-gap` (ticket-auto-pipeline 0.69.0, ticket-planner 0.22.0):
        `TEST_DATA_GAP` semantic code, advisory only (fixed in code), evaluator `dor-semantic-v2`,
        Refinement warn lines and an advisory summary. **Promotion to blocking is pending** the live
        golden sweep (task 4.3: fixtures 01, 22, 25–28 against the fixtures README's Semantic
        expectation list); `TESTDATA_CONFIRM: none` suppression ships with that promotion.
      - [x] a grill-me test-data dimension (`grill-test-data-dimension`, branch
        `feat/grill-test-data-dimension`, grill-me 0.3.0 / ticket-planner 0.23.0): profile
        `product-idea` 1.1.0 gains `test_data`, and Discovery points at the sealed intent's
        `## Test Data`. Optional live check (task 7.1) not run.

---

## Step 12 — Planner output that dispatches first time — proposed 2026-10-22, not started

Source: a planner feedback report from a 13-ticket epic on a client project (2026-10-22). The
planner finished cleanly, but 0 of 13 tickets could enqueue. Two weeks of manual work followed:
6 Refinement rounds, 59+ description rewrites and a late test-data ticket. Root cause: the planner
checked that tickets were well-formed. It did not check that they matched the code, the test data
or each other. That initiative ran before #510/#511/#527, so most of the test-data part is already
fixed (item 0). Items 1–3 are bugs, specced as issues. Items 4–7 need an openspec change each.

- [ ] 0. Live check: run one new initiative end to end. Crosscheck must write the test-data
      ticket and its `blocked-by` edges itself (#510, #511, #527). Fold into Step 11 item 3.

**Bugs: one branch and one PR per issue, no openspec.** The issue body is the plan.

- [x] 1. #535 — VPLAN_ROW_GAP counts Environment checkboxes as ACs (ticket-auto-pipeline,
      `dor-check.sh`). **Fixed by PR #537 (2026-10-22).**
- [x] 2. File and fix: `FLAG_NEEDS_INFO` stays set after the questions are answered
      (`dor-check.sh:1302`, `gate-check.sh:425`). **Already fixed by #540 (0faed14, 0.69.4,
      2026-10-22); re-verified on main f914dfa 2026-11-11.** Gap left open (decision): a passing
      re-run of `ticket-critique` does not clear `needs-info`, yet the critique comment tells the
      user to re-run `/ticket-appraise`; `dor-readiness.md` said `/ticket-approve` clears it, which
      would also approve an unreviewed ticket. Fixed in 0.113.2: the critique message and the doc
      now name `/ticket-flow {ID} needs-info-resolved`.
- [x] 3. Dispatch path: ~~#524 (epic manifest lookup), #525 (no `META|pr-created` from VERIFY),
      #529 (hold-reconcile on an empty scratch log)~~ fixed by PRs #538, #541, #539 (2026-10-22).
      ~~File and fix `/ticket-flow needs-info` failing on claimed tickets~~ — already fixed by
      #396/#423, and `flow.sh` no longer writes to Linear at all. **Left:** check the four
      unverified items in the report (reconcile double-count, openspec path, heartbeat `start`,
      dropped `|` lines) against `main`, then file only those that reproduce. **All four already
      fixed by #542 (e0338cd, 0.69.1, 2026-10-22); re-verified on main f914dfa 2026-11-11. Item
      closed.**

**Openspec changes: one branch each. Review each plan with 3 Sonnet reviewers before implementing.**

- [x] 4. `planner-refinement-convergence` (ticket-planner + ticket-auto-pipeline). **Implemented
      2026-10-22, PR #544** (all 9 groups; ticket-auto-pipeline 0.70.0, ticket-planner 0.24.0,
      fleet-controller 0.42.7). Audit demotion ships dark (`PLANNER_REFINEMENT_AUDIT_DEMOTE`).
      Live check pending: one real initiative through Refinement on the tickets host. Biggest cost
      in the report. Open design questions (all resolved in design.md):
      - a round limit (`PLANNER_REFINEMENT_MAX_ROUNDS`), and what happens to the findings left over
        (advisory appraisal input rather than a DoR hold);
      - which categories stay blocking: test data, contradictions, missing decisions;
      - keep findings across rounds and label each one new or carried over. A new finding on
        unchanged text means the evaluator drifted;
      - section-scoped staleness instead of a whole-body hash for `SEMANTIC_STALE`;
      - an audit `disputed` verdict lowers the deterministic code's severity instead of only
        printing a waive command;
      - fold in body drift: `BODY_DRIFT` when the Linear description differs from `body.md`, and
        `--refresh-bodies` covers every ticket, not only not-ready ones. Same file
        (`planner-refinement.sh`), so not a separate branch.
- [ ] 5. `planner-specify-parameters` — **MERGED 2026-11-11: PR 1 #692 (afbde02,
      ticket-auto-pipeline 0.114.0, `specify-param:<key>` binding) and PR 2 #694 (30a9ced,
      ticket-planner 0.36.0, all planner work). Groups 1–8 done; only group 9 is open (live check
      on the tickets host, which also measures the per-initiative bounds of 12 rows / 6
      questions), then archive.** Specify prompt rules came out at ~560 tokens (target ≈500).
      Change at `openspec/changes/planner-specify-parameters/` (local; validates
      `--strict`; design.md § Review round 1 records all 30 findings). User decisions: no `{{key}}`
      placeholders or ticket-body rendering (specs keep real values; follow-up
      `planner-param-rendering` only if the live check shows values change after TicketGen);
      non-human sources must quote a phrase bash finds in the named artifact, else a must-ask row
      is asked; `fixed` rows cover only the specs that name them; per-literal Crosscheck accept
      (`PARAM_LITERAL@<slug>:"<literal>"`), base-unit comparison. Shape: one `## Parameters` table
      in `proposal.md`; questions batched through the existing Specify stop, plus a second stop at
      Crosscheck only for initiatives with the new contract marker; Crosscheck codes
      `PARAM_TABLE_INVALID`/`PARAM_UNDECIDED`/`PARAM_LITERAL` on AC lines and Expected cells only.
      38 tasks: PR 1 ticket-auto-pipeline only (the `specify-param:<key>` answer binding, 4 tasks),
      PR 2 all planner work (25 tasks; prompt, SHA re-pin and marker last), then 7 live-check tasks
      on the tickets host. Open: headless per-literal accept (wait until dexter needs it).
      Original note: (ticket-planner). Extends `planner-specify-waiting-on-human`;
      start after that branch merges. Open design questions:
      - a `## Parameters` table in Specify (name, config key, default, value or
        `NEEDS_HUMAN_DECISION`), asked as one batch through the existing Specify gate;
      - which parameter kinds must be asked: durations, limits, pool sizes, rounding rules,
        transaction boundaries, failure behaviour;
      - a Crosscheck check against literal values in ACs and seeds that are not declared keys.
- [ ] 6. `planner-crosscheck-ownership` (ticket-planner) — **specced 2026-11-11, reviewed (3
      reviewers), revised. PR A MERGED 2026-11-12 as #696 (3e6016e, ticket-planner 0.37.0; dormant
      family, edges, wildcard accept, and a fix that reads the accept instance only from the
      trailing command, for ownership and `PARAM_LITERAL`). PR B MERGED 2026-11-12 as #697
      (4c8e161, ticket-planner 0.38.0): Specify asks for the tables, so the family is live for new
      initiatives; both contract markers are now written only on the first Specify dispatch. Left:
      group 7 (seed-numbers decision) and group 8 (live check on the tickets host), then archive.** Change at `openspec/changes/planner-crosscheck-ownership/`
      (local; validates `--strict`; design.md § Review round 1 records every finding). Each spec
      declares `## Writes` (Key, Op) and `## Reads` (Key, Source) tables; bash checks them, no prose
      parsing. Ops: `create`/`update`/`delete`, `append` (never conflicts),
      `transition:<from>-><to>` (conflicts only on a shared from-state; `*` overlaps all), `fire`
      (exactly one owner per side effect) and `trigger` (causes another spec's effect, gets a
      `blocked-by` edge to it). Read sources: `spec`, `code:<file-or-dir>` (word-boundary match in
      the pinned repo-ref worktree), `framework:<name>` (fixed allowlist), `external:<name>`
      (warning only). Blocking codes `OWN_TABLE_INVALID`, `OWN_MULTI_WRITER`, `OWN_NO_WRITER`,
      `OWN_MULTI_FIRE`, `OWN_TRIGGER_UNOWNED`, `OWN_EDGES_FAILED`; warnings `OWN_NEAR_MATCH`,
      `OWN_UNDECLARED_REF`, `OWN_EXTERNAL_UNANCHORED`, `OWN_EDGES_DIVERGED`. Edges only from
      `spec` reads and trigger→fire, in a second sidecar (`artifacts/ownership-edges.json`; the
      test-data sidecar reader drops non-test-data edges), frozen once a consumer's ticket exists;
      they can flip shared-branch epics to epic UAT (rule `chain`). Tables are dropped from ticket
      bodies. New marker `spec-ownership-v1`, written only on the first Specify dispatch (the same
      fix is applied to `specify-parameters-v1`, whose re-dispatch would flip legacy initiatives).
      User decisions: declared lists, not prose parsing; 2 PRs (A: accept-table refactor + wildcard
      accept + family + edges + body drop, dormant, 21 tasks; B: prompts, both SHA re-pins, marker,
      4 tasks), then 7 live-check tasks; AC-vs-seed number checks cut (follow-up
      `planner-seed-numbers` only if the live check shows the need); wildcard accept
      `--accept CODE@*:"reason"` records one accept per current instance. Open: `framework:` names
      configurable per host (recommend a code constant for now); headless accept deferred.
- [ ] 7. `planner-ac-code-precondition` (ticket-planner) — **MERGED 2026-11-12: PR 1 #706
      (dormant, 0.40.0), PR 2 #709 (prompts + `ac-precondition-v1` marker, 0.41.0) — new
      initiatives now get the checks.** Open: task 0.2 (grep the tickets host for prose
      `## Preconditions`) and group 7 live check (sandbox idea text in tasks.md 7.1, one real
      project, stop-ship at >2 accepted false positives), then 6.1 follow-ups, then archive.
      Earlier status: specced 2026-11-11, reviewed (3 reviewers), revised. Change at `openspec/changes/planner-ac-code-precondition/`
      (local; validates `--strict`; design.md § Review round 1 records every finding). Checks that
      each acceptance criterion's starting state is reachable in the real code. Each spec declares a
      `## Preconditions` table (Criterion, Key, Mode, Requires, Basis): `Mode` `state` rows are
      checked, `input` rows (a value the test submits expecting rejection) are never flagged;
      `Requires` is `null`, `value:<v>` or `number:<n>`; `Basis` is `code:<path>` (item 6's pinned
      repo-ref worktree; a failed pin or the live checkout is marked) or `spec:<slug>` (`spec:<self>`
      only when the spec's own `## Writes` declares the key). Strong facts only, JPA entities and
      Liquibase XML first: Liquibase constraints/types, `@Id`, enum types; a primitive Java type
      blocks only when Liquibase or `@Id` agrees; ordinal/converted enums, unparsed changes to the
      table, and a hit file cap are unchecked (one info line per run, listing the nearest names).
      Blocking `AC_PRECONDITION_TABLE_INVALID`, `AC_PRECONDITION_UNREACHABLE` (per-instance and
      wildcard accept); warnings `AC_PRECONDITION_PLANNED` (another spec's `## Writes` declares the
      key, so a planned schema change is downgraded) and `AC_PRECONDITION_NO_SOURCE` (once per
      initiative). User decisions: cut to the incident's cases (weak facts, the undeclared tripwire,
      `length:` and Liquibase YAML are follow-ups only if the live check shows the need); `Mode`
      column; planned changes downgrade; 2 PRs (PR 1 dormant, 20 tasks; PR 2 prompts ~150 words, a
      third marker `ac-precondition-v1` as a plain call, SHA re-pins, 5 tasks, after item 6 PR B),
      then 8 live-check tasks including one real-project run, with a stop rule: more than 2
      accepted false positives means narrowing the family. Thread/transaction visibility handed to
      Step 18 item 1. Open: whether any `## Writes` op counts as a planned change (recommend any op).

**Order and conflicts.** Items 1–3 first: small, and they block the next epic today. Then 4.
Items 5, 6 and 7 all edit the Specify prompt in `planner-phase-prompts.sh` and re-pin its sha
test, so run them one after another in that order. Item 4 touches `planner-refinement.sh` and
`dor-semantic.sh` only, so it can run in parallel with 5–7. Each branch bumps its plugin version;
expect version-bump rebases on the second PR of any pair.

---

## Step 13 — Ten-agent codebase review fixes — tranche 1 DONE 2026-10-24 (PRs #549–#558 merged); tranche 2 open

Source: `review-2026-10-23/README.md`. Five persona reviews (architect, QA, PO, backend, frontend)
and five determinism scans found 98 issues (4 P0, 22 P1) and 114 determinism candidates.
Detail and file:line evidence are in `review-2026-10-23/01..10-*.md`. Each work package (WP) below
runs on its own branch in a worktree. Each fix gets a test that fails before the fix and passes
after, where a test is possible. Per-WP handoff notes go in `review-2026-10-23/fixes/WP-N.md`.

**Tranche 1: bugs (parallel, one branch per WP).**

- [x] WP-1 `fix/review-flow-core` (PR #550 merged): fence generation from `FLEET_GENERATION` (ARCH-1/QA-1/BE-1),
      `emit_event` failure keeps `pending_event` (ARCH-2/QA-2/BE-2), `--dry-run` side effects and
      unknown-flag handling, malformed generation, fleetd `--data`, torn outbox line resets `seq`
      (ARCH-10/BE-5).
- [x] WP-2 `fix/review-flow-run-wrapper` (PR #551 merged): `lib/flow-run.sh` replaces `/ticket-flow …; _rc=$?`
      in bash blocks (DET-IP-1, DET-RV-20).
- [x] WP-3 `fix/review-plan-resolver` (PR #552 merged): one whole-ID plan-artifact resolver (DET-IP-2, DET-AP-4),
      gate-reconcile `$NOTES_PATH` fallback (DET-IP-13).
- [x] WP-4 `fix/review-test-registration` (PR #549 merged): register the 6 orphan test files and add a Makefile
      drift gate (QA-3); fix tests that always pass.
- [x] WP-5 `fix/review-docs-diagram` (PR #557 merged): approval wording and `/ticket-approve` in the README tables
      (PO-1, PO-16), Path B `resume --create` (PO-3), `REPOS_ROOT` env (PO-4), diagram synced to
      `workflow.json` plus a CI check (FE-1/2/3/5), landing page phase count.
- [x] WP-6 `fix/review-linear-client` (PR #553 merged): outage reported as `[]` (BE-3), curl timeouts (BE-8), API key
      in `ps` (BE-9), blind create retries (BE-10), rate-limit regex (BE-11), `spawn_write_env`
      escaping (BE-4).
- [x] WP-7 `fix/review-router-merge` (PR #554 merged): auto-merge respects `MERGE_POLICY` and fails closed (DET-RV-4),
      retry check scoped to the latest attempt (DET-RV-3), `VERIFY_FROM=checkpoint` (DET-RV-16),
      `IMPLEMENT|commit-push|skip` (DET-IP-9), conflict-marker false positive (DET-IP-5),
      pr-iterate `--repo` (DET-IP-4).
- [x] WP-8 `fix/review-fleet-controller` (PR #558 merged): `monitor` takes work off the queue and spawns nothing
      (PO-2), gate-stopped and dead-lettered tickets missing from status (PO-5), fleetd POST auth
      (BE-13).
- [x] WP-9 `fix/review-misc-live-bugs` (PR #556 merged): wiki routing `${#REPOS[@]}` (DET-AP-8), critique BLOCKED
      without needs-info (DET-AP-1), audit drift ID/date mismatch (DET-SU-3), prescan contract-map
      wipe (DET-SU-15), persona-refresh `find` (DET-SU-20), Consensus `Readiness: blocked` unread,
      kc-sweep first run, kc-import title.
- [x] WP-10 `fix/review-verify-agent` (PR #555 merged): verify pre-flight runs MCP tools as bash (PO-8), missing
      Playwright and Skill tools (FE-14), hard-coded credentials posted to Linear (FE-15–17).

**Status 2026-10-24:** all 10 PRs merged in order #549→#558 via an automated merge-rebase chain (per-row markdown-table conflict resolver; version-bump/CHANGELOG resolver). Worktrees and branches cleaned. **Deploy actions still open:** set `UAT_TEST_PASSWORD` on each host (#555); update any external fleetd POST caller (dexter dashboard) to send `X-Fleetd-Token` (#558); run `ticket-dir.sh change-dir` once over the live tickets repo to confirm no ticket has two plan folders (#552); `get_comments` now exits non-zero on a Linear outage (#553). Follow-ups from handoffs in `review-2026-10-23/fixes/`: fixed-`/tmp` test path collisions (preamble, spawn-helper, seed-apply, dor-semantic-parse), stale label wording inside skill prompts, ticket templates still saying password `admin`, `ticket-prescan` MCP-in-bash, `qa/*` specializers have no caller. Earlier status: all 10 WPs committed on local branches with fail-before/pass-after tests; handoffs in `review-2026-10-23/fixes/`. PRs #549–#558 opened 2026-10-23 after a clean serial `make test` per branch. Merge order: #549, #550, #551, then the rest; each later PR needs a CHANGELOG/version rebase. Earlier note: fix the fixed-`/tmp`-path collisions in `test-ticket-preamble.sh`, `test-spawn-helper.sh` and seed-apply (they fail only under parallel `make test`), then run one clean full `make test` per branch after rebasing.

**Tranche 2: needs design (openspec first).** Lock and state-root split (ARCH-3/4/5), `flow.sh`
network calls while holding the lock (ARCH-8), migration replay (ARCH-9), fleetd autonomy setting
(PO-9), and the determinism backlog (review README "top high-value, small-effort items").

**Tranche 2 triage, 2026-11-12** (checked against `main` @ 7d31fe0):
- ARCH-8 — was still live: `outbox-drain.sh` inherited flow.sh's FD 9, so the ticket lock was held
  through the board call. **Fixed, PR #700** (0.114.1).
- ARCH-3 (lock dir next to whichever flow.sh ran, `flow.sh:83` vs `fleet-intervene.sh:83`) and
  ARCH-4 (`set_ticket_transition`/`clear_pending_event`/`set_ticket_approval` write the manifest
  with no lock; flow.sh reads `rev` outside any lock) — live, paired; ARCH-3 must land first. One
  PR each is plausible, ARCH-4 needs a concurrency test.
- ARCH-5 (cwd-relative `./logs` state root) — **designed** (`openspec/changes/state-root-anchor`,
  anchor file `$REPOS_ROOT/.ticket-auto/log-dir`, nothing moves), operator questions decided
  2026-11-12, **merged**: PR A **#720** (resolver, writers, preamble, doctor), PR B **#721**
  (fleetd export and boot gate), doctor fix **#723**. Tickets-host live check passed 2026-11-13
  except 6.4's worker-environ read (next real dispatch). Open: the `STATE_ROOT_STRICT=true` flip
  (later PR, once other hosts are anchored).
- ARCH-9 — **fixed, PR #717** (`board-cursor-first-drain`): `emit_event` writes a per-outbox
  origin sidecar; a board with no cursor starts there (or at the outbox tail), so no drain replays
  pre-0.55.0 history and a new ticket still projects from seq 1. Live check passed (demo Linear
  project). Pusher default flipped on in **#718**. Tickets-host inventory (task 0.2) done 2026-11-13: no outboxes, nothing at risk.
- PO-9 — **fixed, PR #702** (fleet-controller 0.49.0): `FLEET_WORKER_AUTONOMY`; phase dispatch
  unchanged unless it is set. Follow-up: reuse a ticket's recorded `META|autonomy` on restart;
  `semi-auto` currently behaves exactly like `auto`.
- ARCH-3 **fixed, PR #704** (lock at `$REPOS_ROOT/.ticket-auto/locks`; fleet-intervene also checks
  the legacy `~/.claude/skills/ticket-flow/locks` file — remove that one release later). ARCH-4
  **fixed, PR #708** (every manifest writer under one lock; idem key from the written rev).
- Determinism backlog: DET-RV-1, DET-IP-1/RV-20, DET-IP-2, DET-AP-6, DET-PL-26 fixed; DET-AP-1
  partial (score still LLM); DET-PL-20 moot (knowledge-curator removed). DET-SU-1 and DET-SU-2
  **fixed, PR #703**, hardened in #710 (inspector-done recomputes the verdict); DET-AP-5 **fixed,
  PR #707** (`complexity-score.sh`). Also fixed: a crashed critique passed the entry gate
  (`CRITIQUE_NOT_RUN`, PR #711). Still live: DET-PL-4 **fixed, PR #715** (`planner-completed.sh`), DET-PL-2 (TicketGen script, own PR, needs
  care). DET-AP-2 unclear (critique may still check by eye).

**Merging.** WPs do not bump versions; bump each plugin once per PR at PR time. WP-2 and WP-7
both edit skill markdown, and WP-1 and WP-2 touch the flow call path, so merge WP-1 first, then
WP-2, then rebase the rest. Expect routine Makefile `test-lib` conflicts.

---

## Step 14 — Debugger persona overlay — PR #560 merged 2026-10-24 (21abba2, 0.72.0); live check open

Openspec change `debugger-persona-overlay` (proposal, design, 2 specs, 36 tasks; validated).
Adds `personas/base/debugger.md` + `specializers/debug/{jvm,python,node,browser}.md` as an
additive overlay (new selector keys `PERSONA_DEBUG`/`PERSONA_DEBUG_SPECIALIZER`), fired by
manifest `type=bug` or a verify-fail rework cycle (`--remediation`). Injected in implement
(Step 2 + Part B rework: hypothesis-to-confirm, failing test first, attempt-3 stop rule),
pr-review (root-cause + regression-test checks) and appraise (`### Root cause hypothesis`).
Also fixes a verified pre-existing bug: no skill ever sets `TICKET_TEXT_FILE` for
`persona-select.sh`, so every keyword trigger (security, test-data weak signal,
migration/refactor specializers) has been dead in production. Ships a `used-by` ↔ call-site
guard test. Research sources: obra/superpowers `systematic-debugging`, wshobson/agents
debugging-strategies, brunoborges/jdb-agentic-debugger.

- [x] 1. Three-reviewer pass done 2026-10-24 (persona-redundancy, selector/errexit, wiring+value). Two blockers fixed in the specs: the verify cap is 2 so an "attempt 3" rule could never fire (now: the one rework is the last chance → confirm or `HUMAN_HOLD`); the injection log line must be `META|persona-select|info|`, not an `IMPLEMENT|…|done|` step (would perturb `IMPLEMENT_FROM`). Also: `detect_stack <layer>` (layer decides for JHipster-style repos), `--type` derived from manifest else `bug` label (hand-filed bugs have no manifest type), appraise writes the hypothesis template without loading the persona, 6-gram shingle + bundle-size tests, metric = `VERIFY_EXHAUSTED` rate among bug tickets.
- [x] 2. Implemented on `feat/debugger-persona-overlay` → PR #560 merged (21abba2, 0.72.0). 33/35 tasks; full `make test` green. Deviations: bundle budget 12 KB (existing 4 files already 9.4 KB); prescan passes `TICKET_TEXT_FILE=""` (shared docs); audit:247 is a real second call, prefixed; stale `used-by` on analyzer/qa-engineer/technical-writer corrected. Follow-up issue #559 (`qa/*` specializers never selected).
- [ ] 3. Live check: one real bug ticket on the tickets host; confirm hypothesis block + log line.
- [ ] 4. After ~20 bug runs per arm: compare `VERIFY_EXHAUSTED` share in `runs.jsonl` grouped
      by implement skill fingerprint; promote to a `retro.sh` metric only if a signal shows.
      **Baseline 2026-10-24:** 76 tickets on both hosts, 0 `VERIFY_EXHAUSTED`, and every row has
      `type=null` — `run-identity.sh` reads only the manifest type (no `bug`-label fallback), so the
      bug-only metric has no data yet. Fix that first or this comparison never populates.

**Order:** Step 13 tranche 1 merged first; PR #560 is on top of main `4a23836`.

---

## Step 15 — Skill size reduction programme — changes 1–3 and 5 merged (#561, #562, #659–#665, #678–#688), change 4 merged except group 14 (#668–#675), change 6 code merged (#689), live run + port removal open

42 `SKILL.md` files total 825 KB; the four largest (ticket-planner 96 KB, ticket-verify 93 KB,
ticket-auto 75 KB, ticket-appraise 72 KB) are 41%. Anthropic's authoring guidance is a body under
500 lines / ~5k tokens (~20 KB), and Claude Code keeps only the first 5,000 tokens of a skill after
auto-compaction, so the big skills lose most of their body on long fleetd phases. Nothing in CI
measures skill size. Reviewed plan (13 inspection agents, 1 web-research agent, 3 reviewers):
`~/.claude/plans/skills-shouldn-t-ggrow-too-rustling-charm.md`. Realistic end state ~825 KB →
~330-370 KB of SKILL.md, ~90 KB moved to on-demand `references/`, ~60 KB of bash into ~25 tested
lib scripts. ticket-auto (~22-26 KB floor) and ticket-verify (~45-60 KB) cannot reach 20 KB and stay
as annotated exceptions; the effective-context ratchet over `prompt_manifests` is the real end-state
metric.

Chained openspec changes (each its own PR(s), version bump, `make skill-baseline` last; chain
`ticket-auto-pipeline` PRs, do not parallelise — they all bump the same version):

- [x] 1. `skill-size-gate` (6 specs, 38 tasks) — MERGED PR #561 (ecc12f5, 0.72.1) 2026-10-24; archived 2026-10-24 — `scripts/check-skill-size.sh` + committed TSV
      ratchet baseline (may only shrink; raises checked against `origin/main`, need
      `# allow-growth:`), 500-line/20 KB ceiling for new skills, frontmatter allowlist, fence >60
      lines fails unless `<!-- size-gate: template -->`, generated blocks excluded + 6 KB cap,
      `references/` link rules, per-manifest context ratchet. Day-one fixes: overseer frontmatter,
      5 fence markers. **Ship first.**
- [x] 2. `skill-glue-collapse` (5 specs, 40 tasks) — **MERGED PR #562 (0.75.0) 2026-10-29; archived 2026-11-09; live check 6.6 on the tickets host still open** — `lib/plog.sh` CLI over existing `_plog`
      (~140 inline log echoes, bare-`&&` guards in 8 skills), `lib/skill-ref.sh`, plugin-cache
      resolver dedupe (6 pastes in ticket-auto), ticket-auto Steps 0.1-0.6 → `ticket-preamble.sh`
      with new `TICKET_ARG=`/`ANNOUNCE_START`/`NEW_RUN` manual modes, `persona-select.sh
      --ticket-dir` (3 pastes, not 5). Confirm-first tasks: #362 rule (already enforced by
      `gate-check.sh require_issue_payload`), fleetd tolerance of new preamble fields. Live check.
- [x] 3. `skill-prose-dedupe` (3 specs, 133 tasks, 7 sub-PRs 3a-3g) — **MERGED #659–#665
      (2026-11-09, b8fe01a … f0da6f8); archived 2026-11-10.** ~113 KB of skill text removed
      (planner 95 → 61 KB, ticket-verify 91 → 81 KB); ticket-auto-pipeline 0.97.0 (BREAKING minor:
      `ticket-fleet-controller` forwarder removed), planner 0.35.2, fleet-controller 0.46.8,
      grill-me 0.5.2, kc 0.2.18. Deviations: dispatch-table aliases folded into the target row
      (`detect-resume.sh` still emits `STEP_3`); planner text not in docs moved to
      `ticket-planner/docs/ticket-planner.md`. Out-of-scope findings, left for change 4/5 or small
      fixes (full list: `openspec/changes/archive/2026-11-10-skill-prose-dedupe/handoff.md`
      § Follow-ups, local only):
      - ticket-implement-agent lacks the Agent/Skill tools its SKILL.md Steps 4/4b/5 use (#667)
      - appraise-exec `--from-step regression-guard` resumes at Step 4, skipping Steps 3.6–3.8
      - gate-reconcile calls `hb_init` without sourcing `heartbeat.sh`
      - stale `approved`/`claimed` label prose (pr-iterate, appraise, appraise-exec, batch-appraise,
        verify) and retired dispatch labels in fleet-controller's Dispatch mode
      - fleet-controller engine count (16/12/19) and `FLEET_STALL_WARN_SECS` (README 300, code 600)
      - CRE-* IDs left in ticket-critique and ticket-verify; planner `--base-branch` missing from
        the flags tables; docs/skills/ticket-flow.md still describes Linear calls and exit 7
      Original scope:
      Preconditions inside: move detection-logic/evidence strings into `phase-inspector.sh`
      injection before cutting guidance-extractor; app-knowledge → skeleton (CRE ticket IDs also in
      nav-hints, reproduce, batch-verify; `install.sh` SUPPORT_SKILLS entry); delete
      `ticket-fleet-controller`; fleet-controller drops the six duplicated sections.
- [ ] 4. `skill-progressive-disclosure` (5 specs, 120 tasks) — **groups 1–13 MERGED #668–#675
      (2026-11-10, 7a7805a … 1aaacef), ticket-auto-pipeline 0.105.0; change kept open (not
      archived) for group 14 and the tickets-host live checks** (checklist:
      `openspec/changes/skill-progressive-disclosure/handoff.md` § Summary, local only).
      Always-loaded context −69.5 KB across 7 manifests; 91 KB now loads only behind its
      condition (new `<manifest>:conditional` rows in the context baseline). Moved: appraise
      (−31.8 KB fast path), verify (−10.7), appraise-exec (−10.9), implement (−6.1), setup
      (−2.0 per appraise/reproduce run), retro `--post-to-github` only (−4.2), wiki errata/ADR
      (−3.7). Measured first, no move: critique (6), document (10), reproduce (12) — the text is
      read on almost every run. Dropped: grill-me (11), kc (13) — `skill-ref.sh` resolves
      ticket-auto-pipeline files only. Full-read paths grew a little (appraise +4.4 KB, others
      < 1.4 KB). Open findings:
      - ticket-critique picks Check 5/6 from the `bug` label; planned bugs carry no label, so they
        never get the bug checks (issue body ready, not yet filed)
      - `META|reference-missing` is not in `pipeline-log-format.md`
      - `test-fleet-features.sh` scans SKILL.md only, not `references/`
      - retro `REMEDIATION_BRIEF_TRUNCATED` template points at a stale location
      - `skill-ref.sh` cannot resolve other plugins' references (blocks grill-me/kc/planner)
      Original scope: `references/` convention, appraise
      split (condition is `FAST_PATH_ELIGIBLE=false`, not the planned label; 2.1/2.7/2.8/3.5 stay
      inline), verify mode refs (`build_only`/`live_backend` ids stay in SKILL.md), then
      appraise-exec, implement, critique, setup, retro, wiki, document, grill-me, reproduce, kc.
      Target Symbols → Specify prompt **waits for Step 12 items 5-7**. critique/setup register under
      the appraise/reproduce manifests; grill-me/kc/planner have no manifest.
- [x] 5. `skill-deterministic-extraction` (24 specs, 151 tasks, 6 PR groups) — **MERGED
      #678–#686 (2026-11-10, groups 1–6c) + follow-up #688 (b490338, 0.113.0: handoff decisions
      1(b) and 3 — shared `verify-readiness.sh`, appraise-exec 3.8 advisory only, one mode
      classifier with `verify_mode_gate_profile`, infra-only gone; 21/65 gate verdicts changed,
      mostly stricter browser holds when context.md has UI repro steps); archived 2026-11-11, delta
      specs synced (+63/~3).** Open, tickets host: tasks 1.22 (`/ticket-planner status` output
      unchanged), 3.19 (one real `/ticket-auto` run, log lines unchanged, `META|outcome` last),
      4.29 (browser verify end to end with forced mid-run failure, lock released), the per-group
      live checklist in the archived `handoff.md` § Summary (local only), and one ticket with UI
      repro steps to confirm #688's stricter hold. Open decisions (handoff § Decisions): 2 rework
      trigger is dead, 4 ticket-document PASS strictness, 5 prescan Step 0 env checks, 6 retro
      "(complex, confounded)" tag, 7 planner status mode as a deterministic report. Decision 8 is
      void (kc removed, #687). Original scope: planner
      (`planner-invocation.sh`, `planner_dispatch_gate` composes across 4 planner libs),
      pr-review (`pr-merge-gate.sh` mock-`gh`), router (`router-step.sh`, `prescan-run.sh`),
      verify (`verify-mode.sh` carved from inline gate-check 2.6; staged `verify-env-up.sh`),
      appraise/exec/implement, long tail. Live checks after router and verify groups.
- [ ] 6. `fleetd-shared-router-steps` (3 specs, 20 tasks) — **code MERGED PR #689 (4d91767,
      2026-11-11; fleet-controller 0.48.0, ticket-auto-pipeline 0.113.1), flag default off; change
      kept open.** Built without the 3.19 live check (user's choice); it folds into 5.1. Parity
      fixes on the Python side: `needs_retro` now accepts PR-REVIEW `N/A`; drift text matches the
      router. Design amendments A1–A7 in design.md: `classify_phase` stays in Python (post-spawn
      only captures and records), so turning the flag on starts writing `META|phase-result` and
      PR-REVIEW can classify `OK` for the first time. Open, tickets host: old 3.19 (manual router),
      then 5.1 (fleetd with `FLEET_ROUTER_STEP_SHELL=true`, one real ticket, diff against a flag-off
      run) and 5.2 (inspector `cost_usd`). Then 6.1: delete the port (`needs_retro`, retro helpers,
      `capture_phase_return`, parity test) and flip the default; decide whether inspector/prescan
      stay switchable. Handoff: `openspec/changes/fleetd-shared-router-steps/handoff.md` (local).
      Original scope: fleetd calls `router-step.sh` behind
      `FLEET_ROUTER_STEP_SHELL` (catalog entry required). Only `needs_retro` and the post-spawn
      judgement (`classify_phase`, `apply_verifier_overrides`, `missing_phase_result`) are true
      ports; inspector is `_unsupported_runner` today and prescan has no fleetd code, so those are
      net-new wiring. Parity test first; new tests in `test_router_step*.py`, not
      `test_supervisor.py`.

**Order:** 1 → 2 → 3 → 4 → 5 → 6. Change 1 alone stops the bleeding and is independent of
everything else in this queue; 2-6 each depend on the previous. Orthogonal to Steps 3 and 10;
Step 12 items 5-7 gate one task in change 4.

---

## Step 16 — Dispatch rehearsal loop (Conduit-lite) — started 2026-10-24 — **streak loop RETIRED 2026-11-18, replaced by Step 21; history kept as regression evidence**

Goal: one real idea goes grill-me → ticket-planner → `--create` → fleet dry-run with **zero
blockers**, by running the chain, saving results, fixing each blocker at its source and re-running.
This is the live check of Step 12 item 0, and it will likely re-hit Step 12 items 1-3. Plan
(reviewed by 3 Sonnet reviewers: feasibility, loop integrity, cost):
`~/.claude/plans/so-what-i-want-parallel-dream.md`.

- [x] 1. `dispatch-rehearsal-preflight` — **PR #563 merged** (b5a9987, 2026-10-24, 0.74.0; live
      check 4.4 PASSED on WIL-119: `--no-post` left Linear and the outbox untouched). Was: openspec change (ticket-auto-pipeline): ticket-critique
      `--no-post` (verdict to a local file, no comment, label or flow.sh) + `scripts/e2e-preflight.sh`
      (body-check + `gate-check --mode planned` with a vacuous-pass guard + strict DoR + epic
      `dispatch=true` assert + dry-run + mechanical blocked-by-sibling check).
- [x] 2. Runbook `docs/runbooks/dispatch-rehearsal.md` (shipped in PR #563): setup, freeze rules (hash-frozen brief,
      gate changes keep DoR fixtures 20-28 failing, negative control, clean counter resets on any
      fix), blocker classes A-D, exit criteria. Reusable per idea; not openspec.
- [ ] 3. Loop on Conduit-lite (RealWorld subset: auth + articles; tags at first clean) in
      dexter-sandbox, WIL / "Dexter Sandbox", `rehearsal` label. Exit: two clean fresh full runs
      after the last code change, ending at fleet dry-run (user, 2026-11-07: no real `ticket-auto` dispatch for now). Cap ~~4~~ ~~6~~ ~~10~~ 15 full runs (raised 2026-11-07; to 15 on 2026-11-15). Holdout: comments + favorites slice, run once.
      Fixes: class C/D as commit + test; class B or grill-me profile changes get their own openspec.
      - **Iter 01 (2026-10-24): FAIL**, full run 1 of 4. Work root
        `/home/mortal/workspace/workbench/e2e-conduit`. Grill-me sealed `ready` (54 → 100, 2 rounds).
        Planner `INIT-1792863226-5186` → epic WIL-118, children WIL-119..124 (strict chain).
        Crosscheck halted once (F12, answered headless). Strict deterministic DoR 6/6 pass.
        **Refinement halted 6/6** on semantic findings (F16). Preflight `FAIL rows=33 failed=12`:
        gate-planned `TICKET_NOT_READY` ×6 (real, not vacuous), dry-run `not_ready 6`.
        17 findings in `e2e-conduit/rehearsal/findings.md`. Fix order proposed:
        - [x] F16 + F8 → openspec `planner-ac-coverage-and-epic-uat` — **PR #564 merged**
              (11d3237, ticket-planner 0.25.0). Was: proposed + validated, 3-reviewer pass folded in. F16: Specify/Consensus prompt rule "one AC +
              Verification Notes row per stated outcome, never delete a sentence to comply",
              Crosscheck `AC_STATUS_UNCOVERED`. F8: `planner_uat_policy_resolve` — any sibling
              `blocked_by` edge on a shared branch → `epic` UAT.
        - [x] F13 → openspec `planner-base-branch-config` — **PR #565 merged** (32d9ddb, 0.26.0). Was (proposed 2026-10-24):
              `--base-branch` / `base-branch` config key, detection develop → origin/HEAD → main →
              master over Discovery's pinned repos; merge/sync policy also off the agent env.
              Implement after the change above (both edit `planner_prompt_epicgen`).
        - [x] F1 + F6 (A, grill-me): 2000-char silent input truncation; sealed intent loses brief
              detail (seed titles). **PR #571 merged** (grill-me 0.4.0, with F19): brief sealed
              verbatim, input limits loud, planner passes the brief to Discovery.
        - [ ] F10, F12, F14, F4 (B, minor): untyped Consensus questions invisible to headless;
              Discovery lists public reference specs as Cited Artifacts; duplicate VN rows; IDEA
              extraction includes clarified answers.
        - [ ] Runbook (D): F7 (don't edit tracked CLAUDE.md in the clone), F11 (update marketplace
              plugins to checkout version + restart before iter), export the Linear key.
        - Iter-01 Linear issues WIL-118..124 **cancelled 2026-10-25**.
        - [ ] Draft readiness → openspec `planner-draft-readiness` (proposed + validated 2026-10-25,
              user approved building it): before the first Linear write, compose each spec's ticket
              body and run strict deterministic DoR + the semantic scan/audit on it; halt
              `DRAFT_NOT_READY` (override `--accept DRAFT_NOT_READY:"…"`, bound to the draft hashes).
              Removes the create → Refinement halt → cancel loop. 3-reviewer pass folded in
              2026-10-25: two entry points (after Crosscheck, before the EpicGen create gate), shared
              evaluator split out of `dor_semantic_apply`/`set_ticket_semantic`, own accept line (not
              Crosscheck's), re-Crosscheck after spec edits, no opt-out. **Build after iter 02** (so iter
              02 measures the F16 prompt rules alone). **Amended 2026-10-30** (after iter 03): bounded
              auto-revise loop inside the gate (D8–D16); user decision: build it in 6 slices — S1
              (ticket-auto evaluator extractions), S2a (draft helpers), S2b (halt-only gate), S3a
              (revise guards + agent), S3b (revision loop), S4 (Refinement carry-over, docs). Iter 04
              is its live check.
      - **Iter 02 (2026-10-29): FAIL**, full run 2 of 4. Grill-me sealed `ready` (100). Planner
        `INIT-1793284709-5497` reached Consensus (14/15 findings accepted, ready-for-spec), then
        **Crosscheck BLOCKED, 43 findings**:
        - [x] F22 (B): `CONTRACT_MISMATCH` ×5 against iter 01's cancelled initiative. **PR #567
              merged** (ticket-planner 0.26.1):
              `planner_initiative_abandon` + sibling skip in the contract check; both rehearsal
              initiatives marked abandoned; contract check now rc 0.
        - [x] F23 (D+B): `CITATION_UNRESOLVED` ×31, sandbox left with code on diverged remote
              branches. Runbook reset step added. **PR #574 merged**: Discovery pins the ref it
              reads; citations resolve at that ref.
        - [x] F24 (B, = F12): `CITED_ARTIFACT_UNRESOLVED`/`UNREFERENCED` ×4 (public `openapi.yml`,
              "the brief"). **PR #570 merged**: reference contracts are not cited artifacts.
        - [x] F25 (B): `RESOLUTION_NOT_PROPAGATED` ×3. **PR #570 merged**: per-ticket shares of the
              Consensus block.
      - **Iter 03 (2026-10-29/30): FAIL**, full run 3 of 6. Grill-me sealed `ready` (100). Crosscheck
        43 → 2 findings; F28 (`TEST_DATA_IMPLIED` on quoted content) fixed by **PR #581**; resumed
        with one `TESTDATA_CONFIRM` answer. `--create`: epic WIL-125 + children WIL-126..132,
        `dispatch=true`. **Refinement halted 6/7** on round-1 non-structural semantic AC gaps (F31),
        the create → halt loop draft readiness removes. **PR #583** fixed F26/F27/F30 (minor).
        - [x] Cancel WIL-125..132 before iter 04 (all Canceled in Linear, checked 2026-11-07).
        - [x] Iter 04 = live check of `planner-draft-readiness` (all 6 slices merged first).
      - **Iter 04 (2026-10-30/31): FAIL**, full run 4 of 10. Grill-me sealed `ready` (93, 2 rounds).
        `INIT-1793396786-8715` passed first Crosscheck, then the gate revised 5/7 specs and reverted all 5 as
        `CROSSCHECK_REGRESSION` on 57 false `CITATION_UNRESOLVED`; halted `DRAFT_NOT_READY`, no Linear writes.
        - [x] F33 (C): unquoted `find` prune patterns glob against the caller's cwd. Reproduced: old lib 57 from the
              work root, 0 from `/`; fixed lib 0. **PR #612 merged 2026-11-08** (planner 0.34.1).
        - [x] F35 (D): sandbox `CLAUDE.md` set `skip-worktree`, value kept; runbook updated.
        - [ ] Before iter 05: ~~land #594 → #596 → #595~~ (merged); ~~three queued gate bugs (security regex
              wording, earlier `MISSED` advisories dropped, `advisory_summary` empty in a fresh shell)~~
              (**PR #613 merged 2026-11-08**, planner 0.34.2); land the post-iter-04 issue batch below; grill-me
              `## Assumptions & Defaults` + failure-behaviour probe (F36); F37 runbook note; abandon the iter 04
              initiative; update plugins to the checkout and restart.
        - [x] Post-iter-04 GitHub issue batch (2026-11-08/09): **all merged**, one version per PR, in this order:
          - #614 (#605/#606/#608/#611 failure diagnostics, ticket-auto-pipeline 0.85.0)
          - #612 (F33 citation cwd glob, ticket-planner 0.34.1); #613 (queued draft-gate bugs, ticket-planner 0.34.2)
          - #615 (#602 stale skill copies, #609 GitNexus refresh, 0.86.0)
          - #616 (#607 zombie VERIFY keeps checkpoints, #600 retro lib layout, 0.87.0, fleet-controller 0.46.1)
          - #617 (#599 answer-only reconcile passes, #604 AC drift reaches VERIFY, #601 seeder precheck before
            VERIFY, 0.88.0). Precheck takes scenario names from seed-repo git history and runs argv-only; a
            precheck fail burns one VERIFY attempt on purpose (the attempt cap is the only loop bound).
          - #618 (#598 verdict gate honours the latest result, #610 adversarial override operator-only; plog.sh
            rejects `|`/CR/LF in fields, 0.89.0). Accepted residual risk: a same-uid agent can still forge the
            marker with a raw append to the log.
          - #625 (#621 shared seeder runner `lib/seed-run.sh`: process group plus marker sweep catches `setsid`
            strays; seed-apply gets a timeout, 0.90.0); #629 (sweep race with processes mid-exec, 0.95.0)
          - #623 (#620 resume only past setup from `build-plan`; unknown VERIFY steps restart at Step 1, 0.91.0)
          - #622 (#619 private per-user scratch dir `lib/ticket-tmp.sh`; plog.sh trusts only owned, private
            spawn-meta, 0.92.0)
          - #627 (#626 same-ticket lock takeover only when the owner is dead; `build-plan` resume re-locks;
            Step 7 releases the lock, 0.93.0). Manual router: a crashed sub-agent's owner is the live router
            session, so it waits (visible as `META|verify-lock-self-wait`); fleetd path takes over.
          - #628 (#624 remaining `/tmp` paths: per-user verify lock, fence fallback removed, verify/retro/audit
            scratch, fleetd pidfile in the scratch dir with O_NOFOLLOW + nlink check, 0.94.0, fleet-controller 0.46.2)
          - #632 (#630 skill-size gate: duplicate baseline rows take the min, keep comments, fail as `DUPLICATE`)
          - #633 (#631 planner + grill-me run telemetry: per-phase time/tokens from transcripts,
            `planner-run-report.sh`; ticket-planner 0.35.0, grill-me 0.5.0)
          - #636 (#635 token usage counted once per assistant message, by `message.id`, last line wins, in
            ticket-auto `hooks/token-tracker.sh` and fleetd `observer.py` cost; 0.96.0, fleet-controller 0.46.3).
            `META|tokens`/`META|cache-tokens` written before 0.96.0 overstate usage, so don't compare them
            with later runs.
        - [ ] Live checks for the batch, on the tickets host: restart fleetd (pidfile moved to the scratch dir;
              it refuses to start while an old fleetd holds `/tmp/fleetd.pid`); one ticket run end to end to
              confirm agents load the env file via `ticket-env.sh`; one planner run to confirm
              `planner-run-report.sh` shows tokens; the ticket's `META|tokens` should now be lower than in pre-0.96.0 runs.
        - [ ] Before iter 05: the grill-me + planner self-assessment prompt is at
              `~/.claude/plans/grill-planner-self-assessment-prompt.md` (runs 05/06 rows are `<FILL IN>`). Every
              rehearsal run now writes `iter-NN/run-record.md` (runbook §3).
        - [x] Watch in iter 05 (F34): closed. Iter 05 applied 7 revisions over 2 rounds and the 4 re-evaluated
              specs all came back `ready`.
      - **Iter 05 (2026-11-13): FAIL**, full run 5 of 10. Grill-me 0.6.0 sealed `ready` (80, 1 round, no
        questions). `INIT-1794584184-3869` (9 specs: 7 + 2 synthesized test-data) halted first at Crosscheck
        (F38 citation marker, F39 `TEST_DATA_IMPLIED` false positive; both hand-patched), then at the draft
        gate: `DRAFT_NOT_READY` 3/9 after 2 revise rounds, 34/72 spawns. No Linear writes. F36 held (empty repo
        recorded correctly); F33 fix held (in-loop Crosscheck clean on every apply). Record:
        `e2e-conduit/rehearsal/iter-05/run-record.md`, findings F38–F45 in `rehearsal/findings.md`.
        - [ ] F42 (C, main): `planner-testdata-synth.sh:763,799` puts a foreign-key criterion in every
              synthesized test-data spec; for file or worktree data the audit raises structural
              `INTENT_AC_MISMATCH`, which no revise can clear. Blocked 2/9.
        - [ ] F43 (C): frontend-editor `UNSTATED_DEPENDENCY` on a blocker that exists transitively
              (via frontend-auth-pages). Structural, so never revised. Blocked 1/9.
        - [ ] F38 (B): prompts lack a marker rule for "file created by an earlier ticket in this initiative".
        - [ ] F39 (C): `TEST_DATA_IMPLIED` matches a backtick-quoted literal.
        - [ ] F40 (B, warn): params rule vs ownership rule (`OWN_UNDECLARED_REF` ×7). F44 (B, minor): revise of
              a synthesized spec adds Verification rows with test-data needs and is reverted. F45 (advisory).
        - [x] F42, F39, F43 + F38 fixed on branch `fix/planner-iter05-findings` (worktree
              `claude-plugins-worktrees/iter05-fixes`, planner 0.43.2, `make test` green, **not pushed**).
              `INIT-1794584184-3869` abandoned.
      - **Same-intent rerun (2026-11-13, "iter 05b", not a full run):** `replan` needs created tickets and
        the Regenerate flag, so this was a fresh `plan` on the iter 05 intent with the worktree libs.
        `INIT-1794594411-9961`, 7 specs: Crosscheck clean on the first attempt (0 warn); draft gate 6/7 ready
        after 1 revise round; halted `DRAFT_NOT_READY` 1/7. F43 and F38 fixes held; F39 and F42 were not
        exercised (unit tests only). Record: `rehearsal/iter-05b/run-record.md`.
        - [x] F47 (C): fixed in PR #726 (tap 0.117.2). The scan prompt lists the codes that back each
              `GAP_*` line; the evidence check is unchanged. Not yet exercised by a live run.
        - [x] F46 (D): fixed in PR #726 (runbook uses `$REHEARSAL`, outside `REPOS_ROOT`). The folder
              moved to `workbench/e2e-conduit-rehearsal/`; earlier `e2e-conduit/rehearsal/…` paths in
              this step now mean that folder.
        - [x] Before iter 06: PR #726 merged (098b2de), `INIT-1794594411-9961` abandoned, plugins
              updated (planner 0.43.2, tap 0.117.2).
      - [x] **Iter 06 (2026-11-14, full run 6 of 10): FAIL at the draft gate, 1/6.**
        `INIT-1794651384-4164`, 6 specs. Grill ready 84 (2 rounds). First Crosscheck 1 blocking
        (F48), 7 warn. Gate: 1 revise round, 5/6 ready, halt on project-scaffold. No Linear writes.
        Record: `workbench/e2e-conduit-rehearsal/iter-06/run-record.md`. F43, F38, F46 held; F47 not
        triggered; F42 not exercised.
        - [ ] F49 (C, main): scan PARAPHRASE over 400 characters (403) makes the scan invalid; two
              in a row give `SEMANTIC_UNAVAILABLE`, not revisable. Truncate in the parser or loosen
              the cap.
        - [ ] F51 (B): a no-page chore spec has no `## Navigation Path`, so `NAV_PATH_MISSING`
              blocks and the revise agent cannot add the section.
        - [ ] F48 (B/C): `TEST_DATA_IMPLIED` on "search of README.md for `calculator` returns 0
              matches" (F39 variant the fix missed). Unblocked by hand.
        - [ ] F50 (C/D): the gate hides the parse error (`2>/dev/null`) and deletes the rejected
              result files; log the reason and keep the file.
        - [ ] Before iter 07: fix F49, F51, F48, F50 (done on `fix/planner-iter06-findings`,
              uncommitted); abandon `INIT-1794651384-4164`; update plugins and restart. 4 full runs
              left; exit needs two clean runs in a row.
        - [ ] **Change of approach (decided 2026-11-14, user).** Iterations were improving but circling
              on gate false positives (F28 → F39 → F48 same family; F47, F49 format strictness). Order:
              1. [x] **Block audit** (2026-11-14, `$REHEARSAL/block-audit.md`): 13 halts, 3 from real
                 plan defects, none since iter 04. Changes on `fix/planner-iter06-findings`:
                 TEST_DATA_IMPLIED strong → warn (`PLANNER_TESTDATA_IMPLIED_BLOCKS=true` restores);
                 draft gate SEMANTIC_UNAVAILABLE/UNVERIFIED → warn (`PLANNER_DRAFT_WARN_CODES`);
                 state-log repair keeps accepted/info/step/warn lines; run record labels every block.
              2. [~] **Gate rewording tests**: `test-planner-testdata-rewording.sh` (30 wordings, 0/21
                 false positives, 0/8 misses, 1 known: `caps \`limit\``). DoR nav/test-user rewordings
                 still to write (only the chore/security type matrix so far).
              3. **Iterations 07–09** with those changes; track blocks per run and false-positive rate,
                 not only pass/fail.
                 - [x] **Iter 07 (2026-11-14, full run 7 of 10): FAIL at Crosscheck** on F52 (checker
                       bug, `DEPENDENCY_CYCLE` from an `append` writer's derived edge). Fixed, PR #728
                       merged (planner 0.43.4). Diagnostic resume on the fix: Crosscheck clean, draft gate
                       **8/8** (first ever), `--create` → epic + 8 tickets, Refinement 8/8, critique 8/8
                       CLEAR, `PREFLIGHT PASS rows=43 failed=0`, negative control failed as expected. Not a
                       clean run (code changed mid-run). Issues cancelled. Record:
                       `workbench/e2e-conduit-rehearsal/iter-07/run-record.md`.
                       - [x] F54 (D): `scripts/e2e-preflight.sh` not executable. PR #729 merged.
                       - [x] F53 (B): Linear's description re-render is normalised; the one real change was
                         CommonMark dropping code-span edge spaces from a test value. Warn-level Crosscheck
                         `CODE_SPAN_EDGE_SPACE` + Specify self-lint, PR #730 merged (planner 0.43.5).
                       - F55, F56: observations, no fix.
                 - [x] **Iter 08 (2026-11-15, full run 8 of 10): PASS, ruled CLEAN** (1st of 2). Grill
                       85, Crosscheck clean, draft gate 7/7, epic WIL-145 + 7 tickets, Refinement 7/7,
                       critique 7/7 CLEAR, `PREFLIGHT PASS rows=38 failed=0`, negative control failed as
                       expected. Harness deviation F57 (`next` called extra times, restored by hand).
                       WIL-145..152 cancelled, INIT abandoned. Findings F57–F61 (F57 orchestration guard,
                       F58 revise-guard reused assumption, F59 Requires grammar, F60 round-limit demotion,
                       F61 Linear autolinks) — unfixed, classes in findings.md.
                 - [x] **Iter 09 (2026-11-15, full run 9 of 15): FAIL at draft gate** 1/7, nothing in
                       Linear, INIT abandoned. Same code as iter 08. 5 specs revised and cleared (6
                       revisions, 0 reverted). Blocker F62 (C): frontend-editor round-0
                       `INTENT_AC_MISMATCH` on a "0 `img` elements" criterion, speculative (no spec
                       renders images) → false positive; the code is in the gate's structural list, so
                       it halts with no revise round. F63–F66 observations. Record:
                       `workbench/e2e-conduit-rehearsal/iter-09/run-record.md`.
                       - [ ] F62 fix: let the draft gate revise an `INTENT_AC_MISMATCH` that names one
                         criterion (user approved continuing, cap raised to 15).
                 - [ ] **Iter 10+**: two consecutive clean runs on the F62 fix.
                 - [x] **Iter 10** (2026-11-15, INIT-1794744986-6851, planner 0.43.6): FAIL at Crosscheck,
                   `CARVE_SCOPE_LOST` (F67, checker bug: count read from the Specify `start` log line, a guess).
                   Nothing in Linear; draft gate never reached. New F67–F70. Run 10 of 15.
                 - **PAUSED 2026-11-15** for Step 19 (LLM ↔ script seam): halts keep coming from a
                   recurring class, not one-off bugs. Iter 11 waits for Step 19's G1–G7.
                 - [x] **Iter 11** (2026-11-16, INIT-1794825677-5521, planner 0.50.0 / tap 0.121.0): PASS end
                   to end (grill 82, Crosscheck clean, draft gate 9/9 after 2 revise rounds, epic WIL-153 +
                   WIL-154..162, Refinement 9/9, critique 9/9 CLEAR, `PREFLIGHT PASS rows=48 failed=0`,
                   negative control failed as expected). **G7: NOT CLEAN** — independent review left 3
                   debatable audit advisories (F77–F79) and one false revise-guard block (F80). Run 11 of 15,
                   clean counter 0. New: F71 (Refinement format retry never fires — G6 fn not sourced), F72
                   (contracts ugrep regex), F73/F74 (agents write operator answers / rewrite state.log), F75
                   (Linear key source), F80 (TESTDATA_REGRESSION on `—` Source), F81 (composer case-insensitive
                   VN dedupe). Record: `workbench/e2e-conduit-rehearsal/iter-11/run-record.md`. WIL-153..162
                   cancel pending user OK.
                 - [x] **Iter 12** (2026-11-16, INIT-1794853599-2599, planner 0.52.1 / tap 0.122.1): PASS end
                   to end (grill 84 in 2 rounds, Crosscheck clean, draft gate 8/8 after 2 revise rounds with 8/8
                   revisions applied and 0 reverted, epic WIL-163 + WIL-164..171, Refinement 8/8 all imported,
                   critique 8/8 CLEAR, `PREFLIGHT PASS rows=43 failed=0`, negative control failed as expected).
                   **G7: NOT CLEAN** — B5 and W5 debatable, plus F84: a revise ASSUMED answer in frontend-shell
                   contradicts editor-page's `/editor` guard and no gate re-checks dependents. F71/F72/F75 fixes
                   held. New: F82 (advisory "earlier revision" means not re-raised, not fixed), F83 (negative
                   control wording), F84. Run 12 of 15, clean counter 0; 3 runs left, exit needs 2 clean in a
                   row. Record: `workbench/e2e-conduit-rehearsal/iter-12/run-record.md`. WIL-163..171 cancelled and
                   INIT abandoned 2026-11-16.
                   - [x] **Before iter 13 (user approved 2026-11-16): fix F84 (+ F82 wording, F83 runbook).** MERGED #751 (4d0bded, planner 0.53.0), installed; restart before iter 13.
                     **Chosen (after 3 Sonnet reviews): fix at the source, in the revise agent.** (1) Prompt rule:
                     an ASSUMED default must not set behaviour a neighbour spec relies on (session, token, auth,
                     error handling, data ownership); where it must, it matches what the neighbour states, else
                     fails closed (deny / clear / signed out); if neither works, rebut. (2) The revise brief lists
                     the spec's direct upstream (`blocked-by`) and direct downstream neighbour spec paths as
                     read-only inputs. No keyword reject (false-reject risk costs clean runs).
                     **Rejected: composer propagation** of upstream assumptions into dependent bodies: Related
                     Tickets is a semantically inert section (edits rebase, no rescan); a cross-ticket conflict
                     is raised as a structural code (CONTRADICTORY_REQUIREMENTS) that the revise loop never
                     revises → halt; a dependent already at lineage round 2 gets the finding round-limit demoted;
                     nested bullets risk Linear round-trip non-equivalence (F76). Kept as fallback if iter 13's
                     review still finds cross-spec assumption conflicts.
                     Same PR: F82 report wording, F83 runbook negative-control wording. Planner 0.53.0.
                 - [x] **Iter 13** (2026-11-17, INIT-1794883205-8074 → WIL-172, planner 0.53.0 / tap 0.122.1): PASS end
                   to end (grill 89, draft gate 9/9 in 1 revise round, 28/72 spawns, Refinement 9/9 imported,
                   `PREFLIGHT WIL-172 PASS rows=48 failed=0`, critique 9/9 CLEAR). **G7: NOT CLEAN.** Run 13/15,
                   counter 0. F84 fix held (neighbour lines present; boot-failure gap rebutted, no ASSUMED).
                   New: **F85** structural CONTRADICTORY_REQUIREMENTS marked `resolved` by a scoped rescan that
                   could not see its untouched sections (dor-semantic.sh lineage ~L642); **F86** `_scope_layers`
                   only knows `FE`, Specify wrote `Frontend` → 4 frontend tickets skip TEST_USER/NAV_PATH (negative
                   control exposed it); **F87** frontend session contract (guard vs boot order, setToken username,
                   getToken caching) unpinned across tickets (reviewer U1–U3). Debatable: boot non-401 deferral,
                   W2. Record: `$REHEARSAL/iter-13/run-record.md`. WIL-172..181 cancelled, INIT abandoned (2026-11-17).
                   - [ ] **Before iter 14:** fix F85 + F86 (gate code, class C; user approved 2026-11-17); F87 open.
                     Runs left: 14, 15 — both must be clean, so iter 14 is the last chance.
                 - [x] **Iter 14** (2026-11-17, INIT-1794904930-5594, planner 0.53.1 / tap 0.122.2): HALTED at draft
                   readiness, `DRAFT_NOT_READY` 1/9, nothing in Linear. **G7: NOT CLEAN** — 2 consecutive clean runs
                   within the cap of 15 no longer possible. New: **F88** grill assessor variance (attempt 1 capped at
                   75, discarded; fresh grill 82); **F89** Specify wrote `Source: generate` for an in-test fixture app
                   (`GET /boom`) → testdata-synth made a DB-seed TD ticket; **F90** revise loop edits synth-marked TD
                   specs, the post-round testdata-synth re-run reverts them, report says "applied". F85/F86 not
                   exercised. Record: `$REHEARSAL/iter-14/run-record.md`.
                   INIT-1794904930-5594 abandoned (2026-11-17).
                   - [x] **F89 + F90 fixed:** PR #753 (planner 0.54.0) merged 2026-11-17 as 48b2480, 0.54.0 installed. User decisions 2026-11-17:
                     cap raised 15 → 17 (runbook in #753), F87 + F88 left open (known, not fixed).
                     Next: restart session, iter 15 (run 15/17; 15 AND 16 must both be clean).
                 - [x] **Iter 15** (2026-11-17, INIT-1794929444-3879 → WIL-182, planner 0.54.0 / tap 0.122.2): PASS end
                   to end (grill 87 in 1 answered round, 8 specs, Crosscheck clean 0 warn, draft gate 8/8 after 1
                   revision, 19/64 spawns, Refinement 8/8 with 1 fresh scan, `PREFLIGHT WIL-182 PASS rows=43 failed=0`,
                   critique 8/8 CLEAR, negative control failed as expected ×2). **G7: NOT CLEAN.** Run 15/17,
                   counter 0. Debatable: W3 (**F91** Linear autolink corrupted one Verification Plan cell in WIL-185),
                   W4 (4 open operator questions tested as defaults). Unflagged: **F87 recurs** (`/editor` guard vs
                   boot token check; WIL-190:66 passes vacuously), **F92** (`toArticleResponse` two owners),
                   **F93** (WIL-188 needs jake's token, says no password needed). No gate leak of the F85/F86/F90
                   kind; F85, F86, F89, F90 not exercised. Record: `$REHEARSAL/iter-15/run-record.md`.
                   WIL-182..190 cancelled, INIT abandoned (2026-11-17).
                   - [ ] **Before iter 16 (user approved 2026-11-17): fix F87** (shared client-state lifecycle +
                     vacuous-criterion rule at Specify/Consensus, revise-prompt clause; planner 0.55.0). F91 not in scope.
                     3 Sonnet reviews done; warn code + cross-ticket draft pass rejected for now (fallback if F87 recurs).
                     MERGED #754 (9327c53, planner 0.55.0) 2026-11-17; install, restart, iter 16.
                     Runs left: 16, 17 — both must be clean.
              4. **If 07–09 show no improvement → reverse engineering**: hand-corrected ideal tickets
                 for the hardest specs (no-page scaffold, editor page), used as gate fixtures and to
                 compare planner output by property, not text.
              Later, user's call: dispatch 1–2 tickets in the sandbox to test that "ready" means
              ticket-auto can build it.
- [ ] 4. Follow-up, start once item 3 converges (it supplies the baseline): **chain consistency
      check**. Bash steps (dor/gate/body checks, dispatch) are already repeatable and unit-tested;
      grill-me, the planner and critique are LLM steps, so "similar results" means invariants, not
      equality.
      - Frozen golden ideas: Conduit-lite plus the holdout, brief hashed, answers from the brief only.
        A saved `--answers` file can't be replayed, because grill question ids are generated per run.
      - Structural fingerprint per run, never prose: ticket count, blocked-by graph shape, AC count per
        ticket, sections present, test-data Source kinds, the test-data/seed ticket and its edges, grill
        verdict and score, preflight verdict, critique status per ticket.
      - Tolerance bands, for example: ticket count within ±2 of the baseline, graph acyclic, the seed
        blocker edge kept, preflight PASS every time, grill score ≥ 80. Run each idea N=3 times and
        judge the spread, not a single run.
      - Attribute drift with the skill prompt fingerprints (`skill-prompt-fingerprint`, Step 2).
      - Cost: never per-PR CI. Run it manually or nightly, plus automatically on PRs that touch the
        grill profile, planner phase prompts or gate libs. Mocked Linear for the fingerprint; real
        Linear only for the final dispatch check.

## Step 17 — Faster CI — DONE 2026-11-09 (items 1–4; CI ~55 → ~18 → 5 min); `ci-ok` is the required check on `main`; optional next floor `test-planner-draft-revise.sh`

PR CI takes a median of 46 min (`make test` is 53 of a ~55 min job), and a PR takes a median of
2.8 h from opened to merged, because merging main in restarts CI. All 257 test commands run one
after another on a 4-vCPU runner. Local profile with 4 at a time: 9.8 min wall against 27.7 min
serial, 0 failures; the CI runner is ~1.9x slower than local. Seven files are 55% of the time:
`test-planner-draft-readiness-loop.sh` 312s, `test-env-check.sh` 176s, `test_supervisor.py` 147s,
`test-planner-draft-revise.sh` 81s, `test-ticket-create-guard.sh` 75s,
`test-planner-draft-readiness-gate.sh` 67s, `test-verify-lock.sh` 57s. By plugin: planner 750s,
ticket-auto 635s, fleet-controller 240s, the rest < 40s.

- [x] 1. Run test files in parallel inside the one job (`scripts/run-tests.sh`, slow files first,
      per-test logs, failing logs printed in full; `make test-serial` keeps the old path).
      **PR #638 merged 2026-11-09**: CI job ~55 → 17m56s (unit tests 53 → 16m14s).
- [x] 2. Speed up or split the top 3 files. **Merged 2026-11-09**: #643 (draft-readiness loop
      ~300s → four files of 30–38s), #639 (`test-env-check.sh` 97s → 1s; a whole-filesystem
      `find` per call), #641 (`test_supervisor.py` 146s → 36s; kill-grace sleeps). No file is
      over ~40s locally. Measured CI after it: job 14–21 min (median ~18), unit tests 12–18 min.
      Run-to-run noise on the shared runner (±4 min) is as large as this step's gain; its real
      value is that sharding (item 3) is no longer floored by a 10-minute file.
- [x] 2a. Parallel runs exposed real races, all fixed and merged 2026-11-09:
      - #642 `vplan_parse` read a ticket with a Verification Plan as having none
        (`echo | grep -q` SIGPIPE under `pipefail`; production bug, 0.96.2).
      - #644 (closes #640): the same pattern in 117 non-test sites, 15 multi-stage producers and
        977 test lines → here-strings; `scripts/check-grep-q-pipe.sh` in `make lint` blocks new
        ones. Before it, about one PR CI run in three failed on a Broken-pipe flake.
      - #646 (closes #645): grill-me tests registered `/tmp` dirs in the developer's telemetry
        session marker and the session's Stop hook wrote into them; `run-tests.sh` now strips
        `CLAUDE_CODE_SESSION_ID`.
      - #649 (closes #647): the post-mortem test wrote into the real `~/.claude/state` and could
        reach a real `gh issue create` (none was filed); `POSTMORTEM_STATE_DIR` + `gh` stub.
      - #650 (closes #648): fleetd tests ran the installed `~/.claude/skills` `flow.sh` and libs;
        one resolver with `FLEET_TICKET_FLOW_SH`, `_hermetic.py` isolation.
- [x] 3. Matrix shards (4 jobs, balanced by measured time) plus one gates job (lint, fmt,
      generated, registration, skill size) so shards skip the 112s shellcheck. Expect ~7-9 min.
      **PR #651** (2026-11-09): `gates` + `tests (shard K/4)` + `otel` + `ci-ok` aggregator;
      `run-tests.sh --shard K/N`, LPT-balanced by `scripts/test-durations.tsv` (replaces
      `test-slow-first.txt`; refresh with `make test-durations`). Measured on the PR's green run:
      **CI 5m00s** (was ~18 min median, 14–21), gates 2m25s, otel 20s, shards 4m41s / 3m43s /
      4m51s / 3m25s (slowest = shard 3). Predicted shard loads (local seconds) 294.4 / 294.4 /
      294.4 / 294.3; actual CI serial sums 934 / 806 / 1047 / 763s, runner wall 268 / 207 / 274 /
      192s. The skew is the planner draft-readiness files, which run ~4x their local time on CI
      against ~1.9x for the rest. `test-planner-draft-readiness-gate.sh` alone (67s local, 274s
      CI) sets shard 3's wall time, so it is now the floor. Also fixed: four ticket-auto tests
      shared `/tmp/test-repos-root` and `rm -rf`'d each other's fixtures (or a real inherited
      `REPOS_ROOT`'s `.ticket-auto`).
- [x] 3a. Both follow-ups of item 3, **PR #653 merged 2026-11-09** (eb65bda):
      - `test-planner-draft-readiness-gate.sh` (81s local today, 263–274s CI): the loop suites'
        compose memo is now a shared sourced file (`draft-readiness-compose-memo.sh`), which
        alone takes the file to 29s; then split into `-gate-flow` / `-gate-block` /
        `-gate-recover` (scenarios 1–3 / 4–5 / 6–8: 9.7 / 11.6 / 12.8s local). Bodies moved
        unchanged; the later files start with one clean `_gate_prelude` run. 27 checks → 34.
      - `scripts/test-durations.tsv` re-seeded from the 070e91a `main` push run's four
        `test-results-shard-K` artifacts (CI seconds now, not local). New files get local ×
        the old file's CI/local ratio (263.3 / 81.0): 31.5 / 37.7 / 41.6s. Fixed on the way:
        `update-test-durations.sh` left a CI runner's root in the 7 `CLAUDE_SKILLS_LIB=` commands,
        so they never matched and got the median.
      - Predicted shard loads (serial CI seconds): 981.0 x4 re-seeded with the unsplit file,
        942.9 x4 after the split. Measured on the PR's green run: CI 5m19s; unit-test steps
        4m55s / 3m07s / 4m22s / 4m05s (serial 929 / 744 / 1045 / 973s); gate files 26.2 / 49.1 /
        35.9s on CI (estimated 31.5 / 37.7 / 41.6, same 111s total). The slowest file is now
        `test-planner-draft-revise.sh` (81s local, 268–355s CI; 295s here, shard 1): it is the
        floor and the next file to speed up or split. Shard serial sums still spread 744–1045s
        against a predicted 943 each, so runner noise is now as large as the imbalance.
- [x] 4. PR runs only the shards for the plugins a PR touches; ticket-auto changes also run
      fleet-controller (it sources ticket-auto libs). Decide inside one always-running job, never
      with a workflow `paths:` filter (a skipped required check stays Pending and blocks merging).
      Nightly full run at `7 0 * * *` UTC (02:07 local, off the busy :00 slot), plus the OTel SDK
      step, opening an issue on failure. `concurrency` with `cancel-in-progress` for PR runs only.
      Expect ~5 min on most PRs.
      **PR #652 merged 2026-11-09** (7136904): a `changes` job runs
      `scripts/select-tests.sh --base HEAD^1` and passes `TEST_ONLY` to the shards
      (`run-tests.sh --only`, filtered before the shard split); `otel` runs only when
      fleet-controller is selected; every job skips by step, so all checks report.
      Map: ticket-auto → fleet-controller, planner, grill-me, scripts/tests;
      fleet-controller → ticket-auto, planner, scripts/tests; planner →
      `test-ticket-create.sh`; grill-me → planner; knowledge-curator → none; plus
      `test-fleet-features.sh` and `test-diagram-drift.sh` on any plugin change;
      outside a plugin → all; root notes (CHANGELOG.md, next.md) → none. Real
      Makefile: kc 9, planner 65, grill-me 71 of 265 commands; ticket-auto or
      fleet-controller ≈ all, so the gain is on planner/grill/kc/notes PRs. Nightly
      `7 0 * * *` + `workflow_dispatch`; a failed nightly files/comments on one
      `ci-nightly` issue (`scripts/ci-nightly-issue.sh`). PR-only
      `cancel-in-progress`; non-PR runs get their own group (`run_id`), so a burst of merges
      never drops a queued `main` run. Not yet seen live: the subset path on a single-plugin
      PR, and `ci-nightly-issue.sh` against real GitHub (stub-tested only). Left: make `ci-ok`
      a required check on `main` (blocks the merge-right-after-push shortcut; user's call).
- Not doing: merge queue. It runs a separate full CI per queued PR (no speed-up) and is offered
  only for organisation-owned repos; this repo is user-owned.
- [x] Required check: `ci-ok` (GitHub Actions only, `strict: false`) required on `main` since
  2026-11-09, admins included. #657 was the first PR it held: a GitHub Actions outage left jobs
  `abandoned`, `ci-ok` failed closed, and the PR merged on a re-run after recovery. Follow-ups
  #655 (kc-render) and #657 (exit-path, closes #656) fixed the two `while … break` SIGPIPE
  readers left after #644.

---

## Step 18 — Context-withheld ("goldfish") review, borrowed from EGM — proposed 2026-11-11, not started

Source: [google/elephant-goldfish-model](https://github.com/google/elephant-goldfish-model)
(Apache-2.0), evaluated 2026-11-11. Its core idea: a reviewer that never saw how a document was
produced cannot inherit the producer's blind spots, so reviewers get only the document, the files
it links, and the code. EGM itself is an interactive, human-gated plugin (one question per turn,
approval at each stage), so it is not installed into the pipeline. Three ideas are borrowed. No
openspec change exists yet for any item. Ordered cheapest first.

Which plugins each item touches (bump the version of every plugin an item edits):

| Item | Plugin(s) | Where |
| --- | --- | --- |
| 1 | ticket-planner | Review prompt in `lib/planner-phase-prompts.sh`; Consensus reads the extra findings |
| 2 | ticket-planner + ticket-auto-pipeline | spawned from planner `lib/planner-refinement.sh`; `dor-semantic-agent` and `ticket-critique` live in ticket-auto-pipeline |
| 3 | none (repo tooling) | a script under `scripts/`, run on demand or nightly; packaging it as a skill for other projects is a separate decision |

- [ ] 1. **Goldfish lens for the planner's Review phase.** Specced 2026-11-12 as openspec
      `planner-goldfish-review` (local; reviewed once, revised): an extra agent before Review via
      the spawn-list loop, `goldfish/review-goldfish.md`, max 8 findings, not-run never zero,
      warn-only `GOLDFISH_UNADDRESSED`, flag `PLANNER_GOLDFISH_REVIEW` default **false**. **MERGED** PR A #712
      (0.42.0) and PR B #714 (0.43.0); off until the operator sets the flag. **Operator questions Q1–Q5 in design.md**
      (default on/off, warn vs block, read specs too, serial vs parallel, the `clarified` rule).
      Original note: `planner_prompt_review`
      (`ticket-planner/lib/planner-phase-prompts.sh`) tells the reviewer to re-read
      appraisal, discovery and architecture, so it reviews with the generator's framing. Add a
      second, context-withheld lens that reads only `artifacts/proposal.md` and the code, and
      writes its own section (or file) that Consensus consumes alongside `review.md`. Open
      questions: one extra agent spawn per run (cost), and whether Consensus treats goldfish-only
      findings differently. Copy EGM's rule: a lens that fails or times out is recorded as
      "not run", never as zero findings.
- [ ] 2. **Paraphrase test on planned tickets.** **MERGED 2026-11-12, PR #705**
      (ticket-auto-pipeline 0.115.0, ticket-planner 0.39.0): required `PARAPHRASE` scan line,
      advisory-only `INCOHERENT_CHANGE`, evaluator v4 (v3 verdicts stay valid). The critique audit
      found a fail-open, fixed in #711. Open: live check (read stored paraphrases, judge
      `INCOHERENT_CHANGE` hits before promoting to blocking); epic/intent comparison deferred. Original note: From EGM's comprehension reviewer: before
      listing findings, the reviewer writes what the ticket proposes in its own words; a
      paraphrase that disagrees with the sealed intent / epic is a finding. A document whose
      terms are all defined but whose parts don't connect passes a definitions check and fails
      this one. Extend the existing body-only `dor-semantic-agent` scan
      (`ticket-planner/lib/planner-refinement.sh`) rather than adding an agent. While there,
      check that DoR semantic and `ticket-critique` treat a failed/timed-out evaluator as
      "not run", not "no findings". EGM's "Zero-Decision Rule" (a plan fails if the implementer
      must make any design choice) is a candidate one-line wording for TicketGen/strict DoR.
- [x] 3. **Spec/doc drift report.** DONE 2026-11-12: `scripts/drift-report.sh` + prompt + stub-claude test
      (openspec change `spec-doc-drift-report`, local). Smoke run on one doc: 16 s, $0.42, one real
      finding. Live task 4.1 (one `--only 'ticket-auto-pipeline/docs/*'` sweep, spot-check three
      findings) is the operator's call — a full sweep is ~140 docs ≈ $60. Original note: An LLM pass that compares each `openspec/specs/*` capability
      and each `*/docs/*.md` against the current code and reports only divergences (missing
      behaviour, missing fields, hardcoded values where logic was specified, different
      pattern/library). CI only checks the state diagram against `workflow.json`; nothing checks
      the ~120 specs or the docs, and stale ones have bitten before (the RLVR plan cited 4 docs
      that did not exist). Run on demand or nightly with a dated report, never as a CI gate
      (non-deterministic). Process one document per subagent to bound context.

Not borrowed: brainstorm/draft (grill-me and the planner cover them), bootstrap (overlaps
prescan), the TRIZ "inventive catalyst" lens, and transcript-regex scenario tests. EGM can still be
installed as-is for reviewing our own openspec `design.md` files (`/egm:egm-review`,
"Consolidated report" preset); that needs no work here.

**Housekeeping, 2026-11-09:** checkboxes brought in line with `main`. Step 12 item 1 (#535 → PR
#537) and the three issues in item 3 (#524 → #538, #529 → #539, #525 → #541) were fixed on
2026-10-22; Step 15 item 2 (`skill-glue-collapse`) merged as #562; Step 17 closed with `ci-ok` the
required check on `main`. Six merged openspec changes archived locally (`openspec/` is gitignored):
`debugger-persona-overlay`, `dispatch-rehearsal-preflight`, `grill-me-verbatim-brief`,
`skill-glue-collapse`, `planner-ac-coverage-and-epic-uat`, `planner-base-branch-config`. Their only
open tasks were live or rehearsal checks, still tracked here: Step 14 (debugger, 6.4), Step 15 item
2 (glue collapse, 6.6), Step 16 (preflight 4.4, verbatim brief 3.4, AC coverage and base branch
5.1). `planner-draft-readiness` stays active: its open tasks are the iteration 05/06 exit
criteria. `langfuse-evidence-layer` (16 live tasks) and the four unstarted Step 15 changes are
unchanged.

**Housekeeping, 2026-11-10:** Step 15 item 3 (`skill-prose-dedupe`) merged as seven chained PRs
#659–#665 and archived locally; its delta specs were synced (`skill-single-source-of-truth` and
`skill-public-repo-hygiene` added, `phase-inspector-detection-patterns` modified). Step 15 item 4
(`skill-progressive-disclosure`) groups 1–13 merged as #668–#675 the same day; the change stays
active for group 14 (waits on Step 12 items 5–7) and its live checks. Next in the programme is
`skill-deterministic-extraction`.

**Housekeeping, 2026-11-11:** Step 15 item 5 (`skill-deterministic-extraction`) merged as #678–#686
plus the #688 follow-up, and archived locally with its delta specs synced. `knowledge-curator` was
removed from the marketplace (#687); every kc item in this file is void. Next in the programme is
item 6, `fleetd-shared-router-steps`, started 2026-11-11; its code merged the same day as #689, and its live run and port removal are open.

---

## Step 19 — LLM ↔ script seam: "the model judges; bash knows" — planned 2026-11-15, IN PROGRESS — **streak loop RETIRED 2026-11-18, replaced by Step 21; history kept as regression evidence**

Decided 2026-11-15 (user): Track 0 runs now, in parallel with G1–G2; G7 runbook amendment approved
(cap 15, warning labels in the exit criterion; applied to docs/runbooks/dispatch-rehearsal.md);
three openspec changes (seam-bash-derives, seam-gate-safety, seam-fail-closed); Track 0 and
G1–G7 go before the other open steps, because the rehearsal (Step 16) is blocked on them.
Done 2026-11-15: Track 0 merged — #733 (planner replan parser, 0.43.7), #734 (fleet, 0.54.0),
#736 (ticket-auto, 0.118.0); seam-bash-derives slice 1 merged — #735 (planner 0.44.0, F67/F70).
Done 2026-11-15/16: seam-bash-derives slices 2–5b merged (#738–#742); seam-gate-safety G3–G6 merged
(#743 ledger seed, #744 demotion registry + F58, #745 validator-only DoR retry, #746 harness errors
never plan defects + Refinement 25% unevaluated halt). main d980708, ticket-auto-pipeline 0.121.0 /
ticket-planner 0.50.0 (install together; planner refuses older tap). G1–G7 gate for iter 11 is met.
Next: rehearsal iter 11 (run 11 of 15, clean counter 0); its gate fires go into the ledger before
seam-gate-safety group 5. Watch the 25% unevaluated halt over iters 11–15. Then H1–H6. Follow-ups: fleetd phase dispatch should call
auto-merge.sh before going live; reconcile scripts read only `- [needs-human]`.

Why: every rehearsal run halted on a new instance of the same few mechanisms — scripts reading
facts out of model prose, format slips treated as plan defects, checks meeting untested plan
shapes, prompt/check drift, no repair route, fail-open parsing, late validation. 5 code audits,
2 web reports, 5 design deep dives and 3 plan reviews are in the untracked folder
`seam-audit-2026-11-15/` at the repo root; the plan is `seam-audit-2026-11-15/PLAN.md` (v2).

- [x] **Track 0 — live fail-opens** (bug-fix PRs, one per plugin, parallel): merge safety
      (PR branch check, outcome label can only withhold merge), router routes on parsed
      PHASE_RESULT, entry-gate critique/complexity/readiness/`[needs-human]`, fleet feedback grep +
      replan parser. fleetd `classify_phase` fail-closed goes on the phase-dispatch flag checklist.
- [x] **G1–G7 — gate for rehearsal iter 11:** bash derives facts (F67/F70), minimal corpus of real
      rehearsal output, ledger seed, narrow demotions with sunsets, Refinement parity + unevaluated
      cap, validator-only DoR retry, runbook amendment (cap 15, stricter exit criterion — user sign-off).
- [ ] **H1–H6 — hardening after iter 11:** fail-closed planner parsers (shadow run first), full
      Specify self-lint, bash-owned phase done markers, decision-parser lint, block-after-revise
      with guards, closed-token glossary constants + drift test.
- Deferred unless two more halts need them: JSON result channel, AC ids, contract/policy
  generators, k=2 judge, SubagentStop hook.
- Delivery: openspec changes (a) seam-bash-derives, (b) seam-gate-safety, (c) seam-fail-closed;
  planner PRs one at a time, one version bump each.
- Open: user to confirm Track 0 now, G7 runbook amendment, 3 changes vs 1 umbrella; order vs Steps 1–18.

## Step 20 — Persona work from Dexter: planner review panel + QA persona for verify — both MERGED 2026-11-16; live checks open

Two openspec changes Dexter proposed for this repo. Both ship off by default, so merging changed
no behaviour.

**A. `planner-persona-panel`** — PR #747 merged (b867e78, ticket-planner 0.51.0). Each authoring
phase reads as a job function (`PLANNER_PHASE_PERSONAS`), and a panel of up to five persona
reviewers reads each proposal before Review (`PLANNER_PERSONA_PANEL`). Consensus settles every
finding; only a security or product-owner blocker that Consensus does not accept in full stops the
plan, as an ordinary open decision (`panel.<ID>` row). New Crosscheck codes `PANEL_UNADDRESSED`
(warn) and `PANEL_STOP_SKIPPED` (blocking). The branch was built on an older main (its 0.44/0.45
were taken meanwhile), so it shipped as 0.51.0 with the panel-stop hardening commit on top.

- [x] 1. Built (PR A dormant + PR B wiring), merged with main, hardening committed, `make test` 329/329, merged.
- [ ] 2. Live check (task 4.3): one real plan with `PLANNER_PHASE_PERSONAS=true`, then one with
      `PLANNER_PERSONA_PANEL=true`; compare artifacts, run time and cost with a plan from before.
      Watch how often the security seat sits (its trigger words include `token` and `auth`).
- [ ] 3. Dexter side (5.1–5.3): pin bump via `scripts/sync-plugin-pins.sh` (far behind — its own
      change with a smoke run); confirm a panel stop shows on the Slack round card and the answer
      reaches `--answers` with the `panel:<id>` key; set both flags for Dexter planning runs.
- Known window: a crash between the proposal write and the reopen line in answer intake leaves an
  upheld objection without a second Consensus run; Crosscheck then blocks with
  `PANEL_STOP_SKIPPED … (upheld by the owner, not accepted)`.

**B. `verify-qa-persona`** — PR #748 merged (782e7ed, ticket-auto-pipeline 0.122.0).
`persona-select.sh --phase verify [--verify-mode …]` returns `qa-engineer` plus `qa/playwright-web`
(browser), `qa/api-testing` (live-backend) or none (build-only). `ticket-verify` Step 1g loads it
behind `VERIFY_QA_PERSONA` from `references/qa-persona.md`. The persona adds supporting checks (≤ 3
per criterion, ≤ 12 total); PASS/FAIL stays on the acceptance criteria, extra findings go to an
`Observations` section that Steps 6/7f and the remediation brief ignore. A guard forbids mocking
(`page.route()`), URL navigation, new tickets/states and new pass criteria.

- [x] 1. Implemented (selector, Step 1g reference, guard, docs, 405-combination selector golden), `make test` 326/326, merged. SKILL.md shrank 7 bytes.
- [ ] 2. Live check (task 3.2): one real ticket per verify mode with the flag on; compare report,
      verdict and run time with a like ticket from before.
- [ ] 3. Dexter side (4.1–4.2): same pin bump as A; dexboard `personas.py` handles for
      `qa/playwright-web` and `qa/api-testing`; run view shows the verify persona from `META persona-select`.
- [ ] 4. Small follow-up: `architect.md` and `product-owner.md` `used-by` lists disagree with the selector.

After the live checks: archive both changes (`openspec/changes/<name>/handoff.md` has the details).

## Step 21 — Delivery-first programme: prove grill → planner → ticket-auto delivers working software — v2 AGREED 2026-11-18; M0 + X0 approved, M0 in progress

Supersedes the Steps 16/19 rehearsal streak loop once agreed (iter 16 halted on F94; the
iteration-17 investigation replaced run 17). Architecture, contracts, models, strategies:
`delivery-plan-2026-11-18/PLAN.md` (v2, untracked). Reviews: `delivery-plan-2026-11-18/reviews/R1–R3`;
objections, disagreements and rejections settled in `delivery-plan-2026-11-18/RESOLUTION.md`.
Evidence: `seam-audit-2026-11-15/architecture-2026-11-17/SYNTHESIS.md` + A–E.

Rule: optimise for delivering the software the rehearsal describes, not for passing the rehearsal.
Order: environment → consumer ground truth → consumer fixes → measured subtraction → planner ground
truth → **decide** → ownership / benchmark / initiative review / plan model.
Per code milestone: one PR, one version bump per touched plugin, a compatibility note (planned vs
unplanned tickets, old/new sibling versions, flag-off byte-identity golden), and a byte ceiling.
New prompt text goes into sibling libs or `references/`, never into SKILL.md bodies that carry a
size exception.
Blocks: none after M2 (the X0b re-run is enough); 2 runs after a milestone that changes plan content;
3 runs when variance is the question.

**User decisions 2026-11-18** (answers to PLAN §11):
1. Bar: oracle pass rate ≥ 80 % and delivered without human edit ≥ 70 %, **reported separately**. A
   ticket whose oracle pass depends on an unresolved decision is not a success. Also report tickets
   blocked + reasons, and defects found after implementation. Initial bar, not production readiness.
2. Oracle Layer A: an agent drafts it from the brief; the user approves it before execution. Layer B
   and the hidden decision truth set are written independently, by someone who has not read the tickets.
3. X0 uses the existing WIL-182..190 in the copied work root. Record the original Linear state first;
   the copy must not be able to affect the live initiative.
4. One batch decision checkpoint after Consensus, before ticket generation. Only decisions that need
   human input; confirmed ones never come back; unresolved ones never silently become requirements.
5. Brownfield = **Ledgerly** at a pinned commit, as a disposable copy with no live customer data (not the
   revenue-critical app). Fallback: a snapshot of another existing app. Prerequisite found: Crosscheck
   hard-codes `ledgerly` as an excluded dir (`planner-crosscheck-contracts.sh`, `planner-crosscheck-bypass.sh`),
   so those scans would skip the benchmark repo — remove before M6.
6. Steps 16/19 streak loop retired; Step 21 replaces it. All iterations, reports, fixtures and failure
   cases are kept as regression evidence.
7. Enable Playwright and refresh the GitHub token before X0; checklist + smoke ticket are M0 acceptance.
   Anything that cannot be enabled is recorded as E, never attributed to the planner or ticket-auto.

**Separation rule:** X0 answers "can ticket-auto deliver an existing plan?"; X1 answers "can current
grill-me → planner produce a plan ticket-auto can deliver?". Their results are reported separately and
never pooled. Sequence: M0 → X0 → X1 → evidence review → choose the M5–M8 order. No architecture change
lands during X0 or X1 (controlled experiment; only the M2/M3 changes needed to run X1, decided at the
X0 review).

- [ ] **M0 — Baseline freeze + environment readiness** (no pipeline code)
  - Problem: results cannot be compared without a fixed reference (R7). Environment failures would be
    confused with consumer failures (GitHub MCP token expired; Playwright plugin disabled in
    `~/.claude/settings.json`; skip-worktree `CLAUDE.md` vs WIL-183, which edits it; ports 3000/5173).
  - Root cause: no frozen baseline; the consumer path has never run on this host for planned tickets.
  - Affected: tag `baseline/2026-11-18` (9327c53); `$REHEARSAL/BASELINE-SHA256SUMS` +
    `chmod -R a-w $REHEARSAL/iter-*`; tar of `e2e-conduit/.ticket-auto/initiatives/`;
    `$REHEARSAL/baseline-2026-11-18/` (versions, known-defects table, PLAN §3.3 predictions,
    environment checklist); one `[X0-smoke]` throwaway ticket run end to end.
  - Dependencies: none. Regression risk: none.
  - Tests / evidence: `sha256sum -c` passes; checklist all green or recorded; smoke ticket merged.
  - Rollback: delete the tag and folder, restore permissions, close the smoke ticket.

- [ ] **M1 — X0: execute the iter-15 epic (consumer experiment)** (no pipeline code)
  - Problem: no planned ticket has ever been implemented (R1); consumer seams are unexercised.
  - Root cause: the runbook stops at fleet dry-run.
  - Scope note: iter 15 is an old (planner 0.54.0), best-of-16 plan. X0 measures **ticket-auto only**
    and is not used to rank planner work.
  - Affected: copied work root (initiative + epic dirs + fresh sandbox clone at 200f5a4, abandon and
    dispatch state cleared by a documented script in the copy only); Linear WIL-182..190 re-opened
    (or fresh `[X0]` issues, Q3); `$REHEARSAL/oracle/` (Layer A per ticket from `idea.md`, user-approved,
    hashed; Layer B sanity walk, observations only); `$REHEARSAL/x0/outcomes.md`, `operator-log.md`;
    runbook gains §7 "Execution".
  - Change: `/ticket-auto` per ticket in dependency order. The operator merges each passing PR before
    the next ticket starts (epic + manual releases dependants before merge). A merge conflict counts
    as a human edit and stops that branch. Checkpoint after WIL-185. Attribution per PLAN §3.4:
    E/C/P/I/V, primary + secondary, tie-break, cascades separate, second reader only on ambiguous cells.
  - Dependencies: M0. Regression risk: none to code; the sandbox is disposable.
  - Tests: each Layer-A assertion fails on the pre-ticket code; oracle hash unchanged after each run.
  - Evidence for acceptance: outcome table for WIL-183..185 (checkpoint), then the rest or a recorded
    stop; ticket-verify × oracle 2×2; predictions scored; reader agreement.
  - Rollback: delete the copy, reset the sandbox, re-cancel the issues.

- [x] **M2 — One PR: consumer fixes observed in X0 + F91 at the source** (ticket-auto-pipeline, ticket-planner)
  — DONE 2026-11-21: #804 (F91/F61, 0.138.0, planner 0.56.3) + #805 (#773 verify mode, 0.139.0, planner 0.57.0)
  merged. Other X0 C-findings were already fixed by #756/#758/#764/#768. X0b live re-run judged optional.
  - Problem: C-coded failures from X0. Likely candidates: verify mode `browser` on API/store tickets;
    test-user SKIP. Plus F91 (Linear autolink corrupts a test value in body.md).
  - Root cause: consumer seams never exercised; `planner_ticketgen_record_baseline` adopts Linear's
    re-render into body.md.
  - Change: fix only what X0 observed. For planned tickets only, read a **declared verify mode**
    (Planner Context/manifest) before `verify_mode_classify`; the classifier is untouched for other
    tickets. TicketGen refuses to adopt a re-render that changes a code-span literal or a credential
    row; human Linear edits are still adopted through `body_baseline_classify`. Nothing documented
    is deleted (Exploration Depth, `adopt_planner_proposal` go on an inert-paths list). The fast-path
    threshold is not touched.
  - Dependencies: M1. Regression risk: verify routing for planned tickets; body adoption. Golden tests
    over the existing verify-mode fixtures; body-baseline tests; a seeded F91 autolink case.
  - Evidence: X0b (re-run of only the C-failed tickets) no longer fails for that reason.
  - Rollback: revert the PR.

- [ ] **M3 — Measured subtraction of planner halts** (ticket-planner, small; mostly offline)
  - Problem: blocking prose checks halt fresh plans (Crosscheck 111 blocks, 0 true; iter 16 F94), so
    X1 cannot reach `--create`.
  - Root cause: regex and word-overlap checks judging meaning (R2).
  - Change: (a) `units=N` / `UNTESTED` on every blocking check (field appended at the end of the
    line; grep the consumers first). (b) Ledger rows for iters 12–16. (c) Recall for the 8 blocking
    prose codes (`RESOLUTION_NOT_PROPAGATED`, `PRECEDENT_NOT_FOUND`, `FORWARD_REF_UNFULFILLED`,
    `CONTRACT_MISMATCH`, `CONTRACT_CONSUMERS_UNNOTIFIED`, `BYPASS_PATH_UNADDRESSED`, `SIGNALS_UNIFORM`,
    `AC_STATUS_UNCOVERED`): seeded operators derived from iters 01–10 findings, tested on iters 11–15
    finals, plus X0 P cases. (d) Codes with recall 0 move to `PLANNER_CROSSCHECK_WARN_CODES`
    (`planner-crosscheck.sh`), with a ledger row and a sunset. No deletion. `gate-demotions.tsv`
    stays reader-less.
  - Dependencies: M1 (real cases). Regression risk: a defect only a demoted code caught; warn rows stay
    visible, and the recall result is recorded.
  - Tests: counter units; recall fixture set in the corpus layout (`scripts/corpus-scrub.sh`, privacy
    test); corpus replay halts fewer with recall unchanged.
  - Evidence: a recall table for the 8 codes; replay of the 16 recorded runs.
  - Rollback: restore the warn-code list.

- [ ] **M4 — X1: two fresh greenfield runs on current main, each executed end to end** (experiment)
  - Problem: today's planner has never been measured by delivery; X0 cannot do it.
  - Change: grill → planner → `--create` → X0 protocol, using the scripted-owner `--answers` file
    for the grill and any planner stop. Record planner halts as data.
  - Dependencies: M2, M3. Evidence: an outcome table comparable to X0; attribution counts.
  - **Then decide** the order of M5–M8 from X0 + X1 (user decision; record it here).
  - **X1 plan (added 2026-11-20, from the X0 review; X0 evidence in
    `e2e-conduit-rehearsal/x0/REPORT.md`).** X1 is the before/after comparison with X0: same brief
    (Conduit-lite), started again from the brief, on a pipeline with the M2 and M3 fixes.
    - **Why not re-run the X0 tickets with a fixed consumer.** X0 already passed Layer A 92 of 92
      with 8 of 8 merged, so the outcome cannot improve. A consumer-only re-run of all 8 tickets
      shows process gains only, and the first tickets of X1 show those anyway. X0b in M2 stays what
      it says: only the tickets that failed for a C reason, not the whole epic.
    - **Reuse without change:** the Layer A oracle (92 assertions), the decision truth set (39) and
      the Layer B walk, run from `$R/oracle` with the hashes checked before and after.
    - **Baseline from X0, consumer side** (expected after M2): rescues 1 → 0; pipeline changes during
      the run 2 → 0; runs for 8 tickets 14 → fewer; fast-path `api_error` on 5 tickets → 0; wrong
      verify mode on 2 tickets → 0.
    - **Baseline from X0, planner side** (the numbers X1 is compared with): 0 of 39 open decisions
      confirmed by a product owner; 20 written as plain criteria with no flag; 5 settled by nobody;
      7 Layer B gaps worth a ticket (`x0/oracle-run-2026-11-20/LAYER-B.md`); 1 P-xticket failure
      (WIL-190 criteria 18–19, counted as a failure by user decision 2026-11-20).
    - **Add one seeded-defect ticket.** X0 had no failed verify attempt, so it gives no evidence
      that ticket-verify catches bad work. One ticket with a known defect fills the "verify fail"
      row of the 2×2.
    - **Protocol, fixing what X0 got wrong:** freeze the pipeline version for the whole run (X0 had
      2 changes mid-run and is marked `assisted`); write the predictions before the run; run Layer A
      after each ticket, not afterwards; the session does not approve its own gate holds (X0: 2
      holds approved within seconds); keep the operator log during the run; stop and report at the
      agreed checkpoint.
    - **Blind spot:** fixes designed from the gaps this brief exposed are tested here on the same
      brief. X1 on Conduit-lite is a regression check. Whether the fixes generalise is M6
      (brownfield), which is the real test.
    - **Size: 2 runs** (user decision 2026-11-20; the delivery plan is updated to match: item 5,
      the M4 row and §8.3). One run against one run cannot separate a fix from run-to-run noise.

- [ ] **M5 — Decision checkpoint, reusing the existing records** (ticket-planner, grill-me; flag `PLANNER_DECISION_CHECKPOINT`, default off)
  - Problem: guesses become tested facts, different on each run (R4).
  - Root cause: an architecture anchor can settle a grill Open Gap; Consensus Open Questions never
    stop (F10); nothing renders unconfirmed status into tickets.
  - Change: read-only `planner_decisions_report` (union of Parameters rows, `### O<n>` outcomes,
    Assumption rows, Open Questions, TESTDATA_CONFIRM/CITED questions). Open-Gap overlap rule in
    `planner_params_*` (an `architecture:`/`appraisal:` anchor on a must-ask kind that overlaps a
    sealed Open Gap counts as `default`; the source family stays). Open Questions raise the existing
    `planner-stop-describe.sh` stop. An `accept-proposed` answer value on the existing
    `specify-param:`/`specify-answer:` keys. A `## Decisions` section from the composer, with parser
    tolerance in dor-check, critique, render-equivalence and body-baseline. grill-me: Open Gaps status
    column inside the seal (profile-gated); no implementation questions to the client.
  - Failure handling: PLAN §6.4 (owner never answers; contradictory answers; answers changing mid-run).
  - Dependencies: M4. Regression risk: a new planner stop in fleetd/Slack planning runs (the headless
    `--answers` path must carry it); a new body section for existing parsers. Flag off = byte-identical.
  - Tests: report units; overlap-rule units; composer golden with and without Decisions; seal
    byte-identity for intents without the new column; two runs with one owner file.
  - Evidence: silent-point behaviour identical across the two runs; 0 decision-derived ACs without a
    status; P-decision failures in the next block ≤ X1.
  - Rollback: flag off.

- [ ] **M6 — Brownfield benchmark** (experiment; Q5 decided before M2)
  - Problem: every finding comes from one greenfield brief.
  - Change: a frozen copy of one of the user's apps (or a mutated public app); brief that extends it;
    Layer A + Layer B oracle + the app's suite stays green + test count monotonic. One run.
  - Dependencies: M2, M3. Evidence: an outcome table comparable to X0/X1.

- [ ] **M7 — Initiative review (brief coverage A + cross-ticket B): offline → shadow → promote** (one new agent)
  - Problem: requirements lost at Specify (C L1, L3, L4) and cross-ticket contracts unjudged (R5).
  - Change: offline on the final bodies of iters 11/12/13/15 against a pre-labelled loss list and
    the 8 historical cross-ticket cases (bar for B: ≥ 6/8; for A: precision/recall vs the list).
    Then shadow inside revise round 1 (`planner-draft-readiness-gate.sh`; counts in
    `PLANNER_DRAFT_SPAWN_BUDGET`; findings in `findings.r1.json`) for one block. Then promote each
    checklist on its own numbers into the revise loop; never halt without revise. Kill B if X0 + X1
    show no P-xticket failures and the offline bar fails.
  - Dependencies: M3; M4 data. Regression risk: a new LLM false-finding source (hence offline + shadow).
  - Rollback: flag off.

- [ ] **M8 — Plan model step 2: sealed REQ ids + bash-derived plan.json** (only if M7-A needs ids or is unstable)
  - Change: a profile-gated `## Requirements` section inside the seal (quote spans verified at seal);
    planner grill-me version floor + absent-section fallback; `plan.json` derived by bash from the
    Markdown (single writer; AC id ledger); optional `Covers: REQ-n` tokens; validators read plan.json.
  - Evidence: graph checks re-find the M7-A losses without prose joins.
  - Rollback: flag off; plan.json unread.

- [ ] **Post-X0 proposal — ticket-gap loop: preflight finds the gaps, patch or re-plan closes them** (proposed 2026-11-20; input to the X0 review, not built during X0/X1)
  - Premise: the planner will never write gap-free tickets (real-world tickets don't either). Stop
    chasing a perfect planner; make gaps cheap to find and fix after planning.
  - Problem: WIL-182's tickets passed critique (CLEAR 85–100), strict DoR and `e2e-preflight.sh`, yet
    agents still guessed behaviour: 401/403/404/422 ordering, network/empty-body errors, trailing-space
    username duplicate, unconfirmed security decisions later reversed by WIL-192; 56/71 ACs on
    WIL-185/186; Scope vs Technical Context mismatches; six non-UI tickets verified in a browser
    (claude-plugins #773, #761; comment on #667).
  - Root cause: the existing loop already exists (`scripts/e2e-preflight.sh`, `planner-draft-readiness`
    + `draft-revise-agent`, `/ticket-planner replan`, `readiness-feedback-loop`) but (1) every check
    judges the ticket's **text** (sections present, ACs well-formed), not whether behaviour is
    **decided**; (2) it runs once, at plan time, before sibling tickets change the code (WIL-190's
    `navigate('/login')` vs the replace-based guard); fleet dispatch only re-runs
    `ensure_ticket_readiness`; (3) implementation guesses never flow back — `readiness-feedback-loop`
    is report-only by design; (4) the rehearsal's exit was "zero blockers at dry-run", not delivery.
  - Change (extend what exists; no new loop):
    - **A. "Two implementations" ambiguity check** — for each AC/outcome, would two reasonable
      implementers differ in user- or operator-visible behaviour? Focus: errors and edge cases,
      security/identity decisions, verify mode. Added to the draft-readiness evaluator and as a
      `e2e-preflight.sh` row. Typed findings `{ticket, field, gap, options[], blast: local|cross|human}`
      (location + admissible options; untyped feedback repairs poorly). Local → `draft-revise-agent`;
      human → the M5 decision checkpoint. Overlaps M7-A; decide at the X0 review whether A is a
      checklist inside M7 or its own change.
    - **B. Deterministic preflight rows** (no LLM): AC count soft cap (~20); declared verify mode
      present (ties to M2); Scope files ⊆ Technical Context files and vice versa; referenced files and
      branches exist at the pinned ref; ACs that cannot hold live (frozen clock, unmerged base).
    - **C. Just-in-time re-check at dispatch** — fleet runs A + B per ticket against the current epic
      branch right before spawning it, not only at plan time. Local gap → patch the ticket
      (`draft-revise-agent`, bounded rounds); cross-cutting gap → `replan` scoped to affected
      undispatched tickets; human → hold with one specific question. Cap 2 rounds; stop when the
      finding count does not drop (noisy-verifier rule).
    - **D. Close the feedback loop** — implement agents log every guess (decision register in
      notes.md); guesses flow into `readiness-feedback-loop`, which may now trigger patch/replan and
      proposes template additions when the same gap class recurs (the #773 template gaps are the
      first batch).
  - **User decision 2026-11-20 — freeze rule vs patching:** the rehearsal freeze rule stays
    (runbook §2: never hand-edit or patch a generated ticket, `body.md` or manifest; fix at the
    source). Patching (C) is allowed in **production** runs only. Every patch must be recorded
    (ticket, finding, before/after hash) and counted, so production patch volume is itself planner
    feedback. Rehearsal and benchmark runs (X0/X1/M6) run with C disabled, or record C's findings
    without applying them.
  - Dependencies: X0 review (M1); M2 (declared verify mode) for B; M5 for the human route; M7 shares
    A's offline → shadow → promote path. Regression risk: new LLM false-finding source (A, C) → offline
    on WIL-182..193 first, then shadow; patch churn in production → round cap + recorded patches.
  - Tests: B rows as fixture units; A offline against the WIL-182 gap list (recall on the known
    gaps, false-finding rate on clean tickets); C round-cap and stop-rule units; D register → feedback
    file golden.
  - Evidence: next epic vs WIL-182 baseline — rework/follow-up tickets per epic, reversed decisions per
    epic, agent guesses per ticket, oracle pass rate.
  - Rollback: each of A–D behind its own flag; flag off = today's behaviour.
  - Sources: SAGE (arXiv 2609.34268), REPOT (2605.30052), structured feedback (2607.14167), VRR-Stop
    (2607.17641); two-implementations technique (levelup.gitconnected.com); Microsoft DoR playbook.

Open (user): success bar (PLAN §8.3); oracle and truth-set authorship; X0 tracker (re-open vs fresh);
checkpoint owner; brownfield target (before M2); retire the Steps 16/19 loop; Playwright + GitHub token
for X0.

## Step 22 — `--record`: capture the automation as it runs — code + docs MERGED 2026-11-21; live check (5.2) open

Openspec change **`ticket-auto-record`** — all 5 PRs merged 2026-11-20/21: #776 flag+guard (`lib/record.sh`),
#777 VERIFY capture, #780 stitch (`/ticket-record-stitch`, `lib/record-stitch.sh`), #786 recorder board driver +
env-check rows, #792 README / plugin-overview how-to. ticket-auto-pipeline 0.130.0 at #786. Tasks 22 of 23 done;
the change is not archived. The checklist below is superseded by the change's tasks.md.

**Open — task 5.2, needs the user:** one ticket end to end with `--record` on a local synthetic-data project,
then `/ticket-record-stitch`, and watch the video. The step-by-step checklist is the "PR 5" section of the
change's `handoff.md`. `openspec/` is gitignored, so the newest `tasks.md` / `handoff.md` are in the worktree
`.claude/worktrees/agent-a0163f75688377ac4/openspec/changes/ticket-auto-record/`, not the main checkout.
Never run against a live system before 5.2:
- the Linear board page reading (`locateCard` in `lib/board-drivers/record/board-shot.mjs`): if Linear's markup
  differs, every board frame is skipped as `column-mismatch` (safe, but no board frames);
- login-page detection (`isLoginUrl`), which decides `session-expired`;
- fleetd's pusher passing `REPOS_ROOT` and `FLEET_BOARD_DRIVERS=linear,recorder` to drivers;
- a real `npx playwright install chromium`, `recorder.sh login`, and a stitch over real frames.
After 5.2 passes: remove the "Known limitation" paragraphs from README and plugin-overview, then archive.

**Decided:** a missing `skills/ticket-verify/references/record.md` stays a hard stop (user, 2026-11-20).
`make test` now needs real `ffmpeg` (`test-record-stitch.sh`); CI installs it.

**Follow-ups (not started, not sequenced — the user places them):**
- `ticket-auto-record-attach`: Linear upload + `recording-attached` outbox event. Waits on the client-access
  decision (guest seat vs shared link).
- REPRODUCE recording (it uses playwright-cli, so it needs its own capture path).

**Goal.** Opt-in recording of a ticket's life for an internal or client demo: a board screenshot
each time the ticket moves, a step-by-step capture of VERIFY / REPRODUCE in the app, attached to
the ticket, and a separate stitch command that turns all captures into one video (board move →
feature working → move to Done → next ticket to Ready). Recording never changes a pass or fail.

**Design anchors (checked against the code 2026-11-20):**
- **Flag.** `/ticket-auto {ID} --record` is parsed in `lib/ticket-preamble.sh` (beside `--auto`,
  `--branch`) and written once as `META|record|on`; later phases and resumes read it from the log.
  `TICKET_RECORD=true` for fleetd and a project default.
- **Board capture is a board driver, not a hook.** `flow.sh` does no tracker I/O; moves reach
  Linear through the outbox drain, which already runs several drivers (`FLEET_BOARD_DRIVERS`,
  default `linear`), each with its own cursor and retry. A new `lib/board-drivers/recorder.sh`
  (`FLEET_BOARD_DRIVERS=linear,recorder`) sees every move in order, can never fail the pipeline,
  and survives a crash. It must capture only after the `linear` driver has applied the same event
  (read that driver's cursor, or run after it in the same drain pass), or it shoots the card
  before it moves.
- **App capture.** The verify agent already saves a screenshot per criterion into `artifacts/`
  (`agents/ticket-verify-agent.md`). Under `--record`: one per step, fixed viewport
  (`browser_resize`), plus `artifacts/recordings/manifest.json` (ts, ticket, phase, event, file).
  Real video needs a second Playwright MCP server started with video on — later slice.
- **Attach to the ticket.** `linear-api.sh` has no upload today: add one (`fileUpload` → PUT to
  the signed URL → comment). The comment is a tracker write from a phase, so it goes through the
  outbox as a new vocabulary event (e.g. `recording-attached`) — skills never write to Linear.
- **Synthetic data only.** `--record` is refused unless the target environment is declared
  recordable (new CLAUDE.md field, e.g. `RECORD_ALLOWED = local`); a run against real data can
  never end up in a recording.
- **Linear session for board screenshots** is the weak link (expires silently): env-check reports
  it, the way it now reports the board labels.

| Item | Plugin(s) | Where |
| --- | --- | --- |
| 1–2, 4 | ticket-auto-pipeline | `lib/ticket-preamble.sh`, `skills/ticket-verify` + `ticket-reproduce`, `agents/ticket-verify-agent.md`, `lib/linear-api.sh`, `workflow.json` vocabulary |
| 3 | ticket-auto-pipeline (+ fleet-controller if fleetd's pusher needs the driver listed) | `lib/board-drivers/recorder.sh`, `skills/ticket-flow/outbox-drain.sh` |
| 5 | ticket-auto-pipeline | new `skills/ticket-record-stitch` (ffmpeg first; Remotion optional later) |

- [x] 1. Flag, `META|record|on`, `TICKET_RECORD`, recordable-environment guard (refuse otherwise). (#776)
- [x] 2. Per-step verify screenshots under `--record` + `recordings/manifest.jsonl` (#777; reproduce deferred).
- [x] 3. Recorder board driver (#786; live board read unverified until 5.2) (screenshot or 2–3 s clip per move, after the `linear` driver
      applied it; failures only `META|record|fail|<reason>`); env-check row for the saved session.
- [ ] 4. Linear upload + `recording-attached` outbox event (comment with the clip after VERIFY
      PASS). Blocked on a user decision: how the client sees it (guest seat vs shared link).
- [x] 5. Stitch command: reads every manifest in time order, title card per ticket, re-runnable
      without re-recording. (#780)

Items 1–2 already yield clips to look at; 3 is the board half (~½ day); 4 waits on the access
decision. Phase inspector and retro must ignore recording failures.

## Step 23 — GitHub issue batch 2026-11-20/21 — code MERGED 2026-11-21; live checks + decisions open

16 issues, one agent per issue, PRs #775–#802 merged (pipeline 0.123.x → 0.137.0). All closed except
**#773** and **#667**, which stay open on purpose. Per-issue notes: memory `project_issue-batch-2026-11-20.md`.

Last round (2026-11-21): #800 ADR gate runs inline in phase agents through `skill-ref.sh` (no Skill tool);
#802 approval provenance follow-ups (`gate-check.sh --mode implement` is ticket-implement's Step 1 check,
backfill seeds tracker-label approvals as `policy`, operator text names `approve.sh`); #801 `VERIFY_AC_TAGS`
(default off; an unprovable `[unit]` criterion fails, never falls back to live).

**Open — needs the user:**
- [ ] Live checks on the tickets host. None of these changes has run on a real ticket: terminal approval
      (`approve.sh` / `reject.sh` from a real terminal), `TICKET_ROUTER_PLAN_REVIEW`, ADR gate inline,
      `VERIFY_AC_TAGS`, `/ticket-cancel` (re-run the Linear preflight: `workflow.json` changed), #765
      merge-observed sweep.
- [x] Move the adr-gate body to `skills/adr-gate/references/` and list it in `prompt_manifests` — DONE
      2026-11-21, #803 (0.137.1).
- [x] Bind an approval to a plan hash — DONE 2026-11-21, #806 (0.140.0): location bound, append-only amendments,
      symlink/unresolvable log record fails closed. Live check on the tickets host pending.
- [ ] #773 remainder: promote the advisory DoR codes after a rehearsal (record dor-advisory rows in X1).
      Done in #805: all-`[unit]` verify build-only; Verify Mode on synthesised test-data specs.
- [ ] #667 remainder: KNOWN_GAPS in `test-agent-tool-coverage.sh` (appraise / appraise-exec subagents and
      Task tools, reproduce, verify, pr-review, gate-reconcile MCP fallbacks); fleetd phase-dispatch support
      for STEP_2_2.
- [ ] #770: dependents of a cancelled ticket keep waiting (agent recommends keep); Linear reason comment.
- [ ] Old issue body revisions (#761–#774, one #667 comment) still show internal ticket ids in the public
      edit history. GitHub has no API for it: delete in the web UI ("edited" dropdown).

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
7. **Step 8 (DoR gate) proposed ahead of Step 6 (Agent Mesh) by rule 1.** It is active harm
   measured on both hosts today — half of WIL's planned tickets burn worker generations before a
   gate stops them — and change 1 is self-contained (ticket-auto-pipeline + fleet-controller libs,
   no fleetd reap-path contact), so it does not compound the Step 6 hold's risk. Operator decides
   the final slot.
8. **Step 10 (Slack-interactive planning) is new capability, not harm reduction**, so by rule 1
   it sits after the outstanding live-verification passes (Steps 8 and 9). Its claude-plugins
   half is additive and touches no file that Steps 1–5 edit, apart from the human-hold parser it
   shares with Step 3. If Step 3 resumes first, land its parser changes before Step 10 item 1.
   The operator decides the final slot.
9. **Step 12 items 1–3 are active harm by rule 1.** They block dispatch of a real epic today.
   Items 4–7 reduce planner rework and come after them. The operator decides the final slot.
10b. **Step 14 is new capability by rule 8**, queued behind Step 13's merges because it edits the same three skill files. Its dead-haystack fix is active harm, but it rides along rather than splitting out.
10. **Step 13 tranche 1 is active harm by rule 1.** Several items are confirmed silent failures
   (frozen manifests after a fleet kill, events lost for good, wrong plan picked by substring). It
   was started by explicit instruction on 2026-10-23, ahead of Step 12 items 1–3.
11. **Step 18 (goldfish review) is quality improvement, not harm reduction**, so it queues
   behind the active Step 15 programme and the Step 16 rehearsal. Item 1 edits
   `planner-phase-prompts.sh`, which Step 12 items 5–7 also edit (and re-pin its sha) — land
   those first. The operator decides the final slot.
12. **Step 20 is new capability, already merged with flags off**, so only its live checks queue.
   Run them after Step 19's iteration 11 so a planner flag does not change the rehearsal's
   baseline mid-measurement. The Dexter pin bump (A3/B3) is one shared change. The operator
   decides the final slot.

13. **Step 21 replaces the Step 16/19 rehearsal loop once agreed.** It runs before Steps 1–15
   and 20's live checks that touch the planner, so the measurement baseline is not moved mid-programme.
   Its M0–M1 change no pipeline code and can start at once; Step 20's live checks wait until after M4.

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
