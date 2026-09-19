# Tracker read classification

**Audit date:** 2026-09-19
**Taken against commit:** `89f7c4c4fef9f2aaa4c2a1b9d11e04df221c296d`
**Source:** `openspec/changes/tracker-read-failure-policy/` (proposal, design, specs, tasks)
**Scope:** every call to a `ticket-auto-pipeline/lib/linear-api.sh` client function
(`get_issue`, `get_comments`, `get_issue_history`, `get_team`, `update_issue`, `get_me`,
`get_project_milestones`, `save_comment`, `resolve_uat_url`, `get_epics_by_label`) from bash across
all five plugins. Function definitions, test files, and the client's own internals are excluded.

This file is the durable record required by the `tracker-read-failure-policy` capability. It
classifies every call site as **decision** (a branch depends on the value) or **informational**
(metadata/telemetry/feedback/display only), states the safe direction for decision reads, records
current behaviour, and flags where the two disagree. **No call site's behaviour has been changed by
this document** — this is the classification the later sections (3–6) of the change act on.

If this file is more than a few months old relative to `lib/linear-api.sh`'s current git history,
treat it as possibly stale — re-run the searches below before trusting a classification, per the
sibling convention in `docs/label-audit.md`.

## Scoping note: SKILL.md prose reads are a separate category, out of scope here

Beyond the ~40 bash call sites below, many `skills/*/SKILL.md` files instruct an LLM agent to fetch
`get_issue`/`get_comments`/`save_comment` via prose ("Linear access strategy") rather than through a
bash script calling a shared helper. These are agent-mediated: the agent reads the ticket for its own
judgment (appraisal, implementation, PR review), not a deterministic bash branch. They already carry
explicit fail-closed instructions in prose — `skills/ticket-auto/SKILL.md:29`: *"A failed or malformed
fetch must be a hard stop for the step, never substituted with a placeholder and evaluated further"* —
and `skills/ticket-critique/SKILL.md:36-41` does the same inline. There is no shared-helper mechanism
for prose to call, so section 3's helper does not apply to them, and they are not enumerated
individually here — the design's own "~40 call sites" figure matches the bash-only count below,
confirming this was the intended scope.

## Summary table

| # | Site | Class | Safe direction (decision only) | Current behaviour | Agrees? |
|---|------|-------|-------------------------------|--------------------|---------|
| 1 | `lib/gate-check.sh:144-153` (`_gate_fetch_issue`) | decision | do not approve (gate-stop) | explicit `META\|gate-stop\|fail\|LINEAR_FETCH_FAILED`, terminal | **Partially** — never approves on failure (safe), but terminal is too aggressive (this change's whole point — see §6) |
| 2 | `fleet-controller/lib/fleet-dispatch.sh:665-674` (blocker resolution) | decision | treat as blocked, do not dispatch | `if blocker_json=$(get_issue ...); then ... fi` — no `else`; a failed fetch never sets `is_blocked=true` | **No — the headline bug** |
| 3 | `lib/outcome-label-check.sh:101-111` | decision | do not auto-merge | explicit `return 1`, no `META\|outcome-label` line written; auto-merge's `OUTCOME` grep then finds nothing ≠ `"Smooth"` | **Yes** — already safe, by omission rather than by design |
| 4 | `skills/ticket-detect-resume/detect-resume.sh:481` (`GATE_HELD`) | decision | do not resume past the gate | `RESUME_STEP="GATE_STILL_HELD"` on failure — identical to the "not approved yet" branch | **Yes** — resolves design's open question; no change needed |
| 5 | `lib/branch-resolve.sh:200` (`resolve_uat_policy`) | decision | do not silently assume a policy | echoes `"per-ticket"` **and** returns 1; both callers (`ticket-pr-review`, `ticket-verify` SKILL.md) capture only stdout | **Borderline** — see detail; matches the pre-existing documented default for "no directive", not a new substitution |
| 6 | `lib/branch-resolve.sh:227` (`resolve_merge_policy`) | decision | require human merge when unreadable (fail toward the stricter outcome) | returns 1, **echoes nothing** — caller's `merge_policy` becomes empty, which the guard treats as "no restriction" | **No — new finding**, see detail. Narrow blast radius (standalone-invocation fallback only) |
| 7 | `lib/branch-resolve.sh:72` (`resolve_branch_context` epic fetch) | decision | do not resolve a branch on unknown epic state | `return 1` → caller (`ticket-preamble.sh`) returns a distinct `TP_*` exit code (design doc's "3 transient branch-resolution failure") | **Yes** |
| 8 | `lib/ticket-preamble.sh:190` (`get_me` preflight) | decision | do not start the ticket | `return $TP_LINEAR_AUTH_FAILED`, distinct code | **Yes** |
| 9 | `lib/appraise-fast-path.sh:77` | decision | do not take the fast path | `FAST_PATH_REASON="api_error"`, `FAST_PATH_EXIT_CODE=1`, `return 1` | **Yes** |
| 10 | `lib/planned-ticket-check.sh:70` | decision | treat as invalid/unverifiable, not valid | `CHECK_RESULT="api_error"`, `return 1` | **Yes** |
| 11 | `lib/planner-artifacts.sh:39` | decision | do not resolve the planner dir as present | `return 1` (no result substituted) | **Yes** |
| 12 | `lib/planned-ticket-body-check.sh:71` | decision | treat body as incomplete/unverifiable | `BODY_CHECK_EXIT_CODE=2`, `BODY_CHECK_MISSING="body_source_unavailable"` | **Yes** |
| 13 | `lib/epic-branch.sh:69` (Branch Directive description fetch) | decision | do not treat a directive as present/valid | `return 1` | **Yes** |
| 14 | `lib/branch-directive-check.sh:88` | decision | treat directive as absent/invalid | `CHECK_RESULT="api_error"`, `return 1` | **Yes** |
| 15 | `lib/audit-comment-guard.sh:32` (`get_comments`) | decision | do not post a possible duplicate | `\|\| echo "[]"` — failure is indistinguishable from "no comments yet", so the caller **posts** (risks a duplicate, not a lost comment) | **No (minor)** — see detail |
| 16 | `fleet-controller/lib/fleet-dispatch.sh:512` (initiative epic fetch) | decision | do not validate/dispatch the initiative | `\|\| { echo ERROR; return 1; }` | **Yes** |
| 17 | `fleet-controller/lib/fleet-dispatch.sh:531` (`get_epics_by_label`) | decision | do not dispatch any child of this epic | `\|\| { echo ERROR; return 1; }` | **Yes** |
| 18 | `skills/ticket-flow/flow.sh:174` (`ISSUE_JSON`, desired-state computation) | decision | do not mutate the tracker on unknown current state | no guard; `set -eo pipefail` (flow.sh:6) aborts the whole script on a non-zero `get_issue` | **Yes, but uncontrolled** — see detail |
| 19 | `skills/ticket-flow/flow.sh:480` (`LIVE_JSON`, post-trigger assertion) | decision | treat as assertion failure, not success | same `set -e` abort, or (if not aborted) empty `LIVE_STATE` never matches `NEW_STATE_NAME` → `assert_failed=true` | **Yes**, safe either way |
| 20 | `skills/ticket-flow/flow.sh:442` (`get_me`, `ASSIGNEE_ARG`) | informational | — | `// empty` → assignee left unset on failure; does not block the state mutation | **Yes** (benign) |
| 21 | `skills/ticket-flow/flow.sh:449-458` (`update_issue`) | decision (write, not a read — listed for completeness) | do not silently accept a malformed mutation result | explicit non-JSON check, `hb_retry` logged | **Yes** |
| 22 | `skills/ticket-setup/setup.sh:32-33,61` | informational | — | no guard; `set -eo pipefail` (setup.sh:6) aborts scaffold creation entirely on failure — no workspace written with placeholder data | **Yes** |
| 23 | `skills/ticket-flow/validate-linear-config.sh:112` (`get_team`) | informational | — | operator-run diagnostic tool; unguarded, script aborts (`set -eo pipefail`) | **Yes** |
| 24 | `lib/env-check.sh:224,460` (`resolve_uat_url`) | informational | — | `\|\| ` fallback chain already designed for absence (env → CLAUDE.md → git root) | **Yes** |
| 25 | `lib/run-identity.sh:220` (`META\|ticket-meta`) | informational | — | `\|\| return 0`, fails soft by design (already documented) | **Yes** |
| 26 | `lib/pipeline-finalize.sh:141-143` (history/comments/me, dead-letter enrichment) | informational | — | `\|\| history_json=""` etc., fails soft | **Yes** |
| 27 | `lib/planned-feedback-write.sh:24,78` | informational | — | `\|\| true`, fails soft (feedback file content only) | **Yes** |
| 28 | `fleet-controller/lib/fleet-feedback.sh:29,320` | informational | — | `if issue_json=$(...); then ... fi` — failure just skips that feedback field | **Yes** |
| 29 | `fleet-controller/lib/fleet-detect.sh:1115-1137` (`detect_blocked_by`, detector #10) | informational | report no finding, not a false one | explicit early `echo "0"` on fetch failure; a failed per-blocker read is simply not counted toward `unblocked_count` | **Yes** — resolves design's open question for this site |
| 30 | `fleet-controller/lib/fleet-detect.sh:1191` (`detect_initiative_dispatch`, #11) | informational | report no finding | explicit `[ -z "$epics_json" ] && echo severity:0` | **Yes** |
| 31 | `fleet-controller/lib/fleet-detect.sh:1388` (`detect_epic_branch_ready`, #12) | informational | report no finding | same explicit empty-check | **Yes** |
| 32 | `fleet-controller/lib/fleet-detect.sh:1563` (`detect_stalled_approved_children`, #18) | informational | report no finding | same explicit empty-check | **Yes** |
| 33–36 | `fleet-controller/lib/fleet-detect.sh:1100-1103,1178-1181,1352-1355,1553-1556` (`declare -f get_issue` guards for #10/#11/#12/#18) | informational | report no finding | `echo "0"` when the client can't even be sourced | **Yes** |

That is 33 distinct decision points across 36 line references (several detectors share the same
"client unavailable" guard pattern). Combined with the ~40-callsite estimate in the design doc
(which also counted the now-fixed `_fleet_linear_query` duplicates removed by
`tracker-client-consolidation`), this is the complete post-consolidation set.

## Detail: the two real disagreements

### `fleet-controller/lib/fleet-dispatch.sh:665-674` — the headline bug (confirmed, re-read in full)

```bash
local is_blocked=false
for blocker_id in $blocked_labels; do
  [ -z "$blocker_id" ] && continue
  local blocker_json blocker_state
  if blocker_json=$(get_issue "$blocker_id" 2>/dev/null); then
    blocker_state=$(echo "$blocker_json" | jq -r '.state.name // empty' 2>/dev/null)
    if [ "$blocker_state" != "Done" ]; then
      is_blocked=true
      break
    fi
  fi
done
```

`is_blocked` starts `false`. The loop only ever sets it `true` inside the success branch of the
`if` (blocker read succeeded **and** its state isn't `Done`). A failed `get_issue` for a blocker
falls through the `if` entirely — no `else`, nothing sets `is_blocked` — so an unreadable blocker
is treated identically to a blocker that doesn't exist: the child dispatches. This is exactly the
design doc's characterization, confirmed against the live file: the unsafe direction is reached by
absence of an `else`, not by an explicit wrong assignment. The fix is a one-line `else
is_blocked=true` (with a log line naming which blocker was unreadable, per spec R1/task 5.3), not a
restructuring — the loop shape, priority ordering, and every other branch are otherwise correct and
should not change.

### `lib/branch-resolve.sh:227` (`resolve_merge_policy`) — new finding

```bash
resolve_merge_policy() {
  ...
  issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
    echo "branch-resolve: failed to fetch ticket $ticket_id for Merge Policy" >&2
    return 1
  }
  ...
}
```

On failure this echoes **nothing** and returns 1. Its only two callers capture stdout only:

```bash
# ticket-pr-review/SKILL.md:411, ticket-verify path is analogous for UAT policy
merge_policy=$(resolve_merge_policy "{TICKET-ID}" 2>/dev/null)
...
elif [ -n "$merge_policy" ]; then
  _merge_blocked_reason="epic Branch Directive Merge Policy: ${merge_policy} requires human merge"
fi
```

An empty `$merge_policy` is indistinguishable from "no epic directive" (the documented default per
`ticket-auto-pipeline/CLAUDE.md`'s `branch-resolve.sh` row: *"unlike `UAT_POLICY`, absence has no
normalised default: empty means the ticket has no epic directive at all"*). So an **unreadable**
epic and a **genuinely absent** epic produce the same empty value, and the merge-block guard treats
both as "no restriction" — a PR under an epic whose directive actually declares
`Merge Policy: manual` could auto-merge if the tracker read fails at exactly this check. **Narrow
blast radius**: this fallback only executes when `ticket-pr-review` is invoked standalone with
neither `$AUTONOMY` nor `$MERGE_POLICY` pre-set in the environment (the comment at
`SKILL.md:403-406` says so explicitly) — in the normal autonomous pipeline, `MERGE_POLICY` is
already resolved once during `ticket-preamble.sh` and exported into the agent's env file, so this
particular read is never reached. Still a genuine decision-read disagreement per the letter of the
spec ("SHALL NOT proceed on a substituted, empty ... value"), and in scope for section 6 if the
implementer chooses to harden it — flagged here since the design doc's seed list did not anticipate
it.

### `lib/branch-resolve.sh:200` (`resolve_uat_policy`) — borderline, likely not a defect

Same shape, but on failure it explicitly echoes `"per-ticket"` before returning 1 — not a silent
absorption into empty, but an explicit substitution of the *same* value the field already
normalises to when a directive has no `UAT Policy` field at all (`branch-resolve.sh`'s own
documented behaviour: *"UAT_POLICY... resolved from the parent directive... normalised to
per-ticket when absent"*). So an unreadable epic and a genuinely-absent-field epic already produce
the same downstream value by design; this substitution doesn't introduce a new failure mode, it
just reaches the pre-existing default through a different path. Recorded as a disagreement against
the letter of the spec, but not treated as needing a fix — flagged for the operator's judgment in
section 6, not assumed.

### `lib/audit-comment-guard.sh:32` — minor, informational-adjacent decision

```bash
comments=$(get_comments "$ticket_id" 2>/dev/null || echo "[]")
```

Used to skip re-posting an appraisal comment if one already exists (idempotency guard). On failure,
substitutes `"[]"` (no existing comments) rather than distinguishing "couldn't check" from "checked,
found none" — so a transient read failure risks a duplicate comment post rather than a lost one.
Classified `decision` by the letter (a branch — post vs. skip — depends on the value), but the
failure mode is cosmetic (board noise) rather than incorrect work, unlike the two findings above.
Recorded for completeness; not treated as urgent.

## Detail: `lib/gate-check.sh:144-153` — already safe, but the wrong consequence

`_gate_fetch_issue` never approves a ticket it can't read — that direction is already correct and
is exactly why issue #362 exists. The disagreement this whole change addresses is **not** that this
site substitutes a wrong value; it's that its consequence (immediate terminal `gate-stop`) is worse
than the failure warrants. Section 6 changes the *consequence* (retryable hold) without touching
this read's fail-closed guarantee — see design D3/D4.

## Detail: `skills/ticket-flow/flow.sh:174,480` — safe via `set -e`, not via design

Neither read has an explicit guard (`|| { ... }` or `2>/dev/null` fallback); both rely on
`set -eo pipefail` (flow.sh:6) to abort the entire script the instant `get_issue` returns non-zero.
This is fail-safe in outcome (no mutation happens on unreadable state) but fail-*silent* in
diagnosis: an aborted `flow.sh` invocation leaves no structured `META|gate-stop` or `META|gate-warn`
line, just a nonzero exit the caller must already be checking. Worth knowing before section 6 wires
a retry/hold mechanism elsewhere in the pipeline — `flow.sh` itself is not part of that mechanism
and this document takes no position on whether it should be; recorded as a design nit for the
implementer's awareness only.

## Method

- Enumerated every call to a client function (`grep -rnE` across `*.sh` in all five plugins,
  excluding `linear-api.sh` itself, `/tests/` directories, and comment-only lines), then read each
  call site's surrounding code directly rather than trusting the design/proposal docs' line numbers
  verbatim (several had drifted by a few lines; `outcome-label-check.sh`'s and `needs-info`'s exact
  citations in the sibling `label-audit.md` were similarly found stale during that audit).
- For every site with no explicit guard, checked whether the enclosing script runs under
  `set -e`/`set -eo pipefail` before concluding the failure mode was "silent absorption."
- For every function returning a value some other file consumes (`resolve_uat_policy`,
  `resolve_merge_policy`, `resolve_branch_context`), traced to the actual caller(s) rather than
  assuming the function's own `return` code is checked — two of the three follow patterns
  (`$(...) 2>/dev/null`) that capture stdout only and never inspect the exit code, which is where
  the two new findings above came from.
- Did not exhaustively trace every downstream consumer of every "explicit `return 1`, propagates a
  distinct error code" site (rows 7–21 in the summary table) beyond confirming the immediate
  function's own failure signal is unambiguous — those are lower-risk than a value substitution and
  section 6 does not need per-caller detail to migrate them onto the shared helper.
