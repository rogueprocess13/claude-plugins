#!/usr/bin/env bash
# test-merge-poll.sh — unit tests for lib/merge-poll.sh
# (Commercial Evidence MVP, Branch B — the single merge-truth implementation)
# All tests stub `gh` via PATH — no network required.
# Usage: bash test-merge-poll.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/merge-poll.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_ws=""
_orig_path=""
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/bin"
  _orig_path="$PATH"
  PATH="$_ws/bin:$PATH"
}
_teardown() {
  PATH="$_orig_path"
  rm -rf "$_ws" 2>/dev/null || true
}

_stub_gh_merged() {
  cat >"$_ws/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"state":"MERGED","mergedAt":"2026-09-02T00:00:00Z","mergeCommit":{"oid":"abc123"}}'
EOF
  chmod +x "$_ws/bin/gh"
}

_stub_gh_failure() {
  cat >"$_ws/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$_ws/bin/gh"
}

# ── merge_poll_one ────────────────────────────────────────────────────────────

test_merge_poll_one_success_emits_merged_with_sha() {
  _setup
  _stub_gh_merged
  local event
  event=$(merge_poll_one "CRE-1" "42" "acme/repo")
  _teardown
  echo "$event" | jq -e '.kind == "merge" and .state == "merged" and .merge_sha == "abc123" and .merged_at == "2026-09-02T00:00:00Z"' >/dev/null
}

test_merge_poll_one_gh_failure_emits_nothing() {
  _setup
  _stub_gh_failure
  local event rc=0
  event=$(merge_poll_one "CRE-2" "9" "acme/repo") || rc=$?
  _teardown
  [ "$rc" -ne 0 ] && [ -z "$event" ]
}

# ── merge_poll_candidates ────────────────────────────────────────────────────

test_candidates_selects_run_with_pr_repo() {
  _setup
  local runs="$_ws/runs.jsonl"
  cat >"$runs" <<'EOF'
{"kind":"run","tid":"CRE-3","run_id":"r1","ended_at":"2026-09-01T00:00:00Z","pr":{"pr":1,"url":"https://x","repo":"acme/repo"},"observed_at":"2026-09-01T00:00:00Z"}
EOF
  local candidates
  candidates=$(merge_poll_candidates "$runs")
  _teardown
  echo "$candidates" | jq -e 'length == 1 and .[0].tid == "CRE-3" and .[0].pr.repo == "acme/repo"' >/dev/null
}

test_candidates_excludes_tid_with_terminal_merged_state() {
  _setup
  local runs="$_ws/runs.jsonl"
  cat >"$runs" <<'EOF'
{"kind":"run","tid":"CRE-4","run_id":"r1","ended_at":"2026-09-01T00:00:00Z","pr":{"pr":1,"url":"https://x","repo":"acme/repo"},"observed_at":"2026-09-01T00:00:00Z"}
{"kind":"merge","tid":"CRE-4","pr":1,"repo":"acme/repo","state":"merged","merged_at":"2026-09-02T00:00:00Z","merge_sha":"x","observed_at":"2026-09-02T00:00:00Z"}
EOF
  local candidates
  candidates=$(merge_poll_candidates "$runs")
  _teardown
  [ "$candidates" = "[]" ]
}

test_candidates_surfaces_repo_less_pr_for_unknown_repo_reporting() {
  _setup
  local runs="$_ws/runs.jsonl"
  cat >"$runs" <<'EOF'
{"kind":"run","tid":"CRE-5","run_id":"r1","ended_at":"2026-09-01T00:00:00Z","pr":{"pr":1,"url":"https://x","repo":null},"observed_at":"2026-09-01T00:00:00Z"}
EOF
  local candidates
  candidates=$(merge_poll_candidates "$runs")
  _teardown
  echo "$candidates" | jq -e 'length == 1 and .[0].tid == "CRE-5"' >/dev/null
}

# ── merge_poll_sweep ──────────────────────────────────────────────────────────

test_sweep_recently_polled_candidate_is_skipped() {
  _setup
  _stub_gh_merged
  local runs="$_ws/runs.jsonl" recent_ts
  recent_ts=$(date -u -d "5 minutes ago" +%Y-%m-%dT%H:%M:%SZ)
  cat >"$runs" <<EOF
{"kind":"run","tid":"CRE-6","run_id":"r1","ended_at":"2026-09-01T00:00:00Z","pr":{"pr":1,"url":"https://x","repo":"acme/repo"},"observed_at":"2026-09-01T00:00:00Z"}
{"kind":"merge","tid":"CRE-6","pr":1,"repo":"acme/repo","state":"open","merged_at":null,"merge_sha":null,"observed_at":"$recent_ts"}
EOF
  merge_poll_sweep "$runs"
  local lines
  lines=$(wc -l <"$runs")
  _teardown
  [ "$lines" -eq 2 ] || {
    echo "expected no re-poll within the 10-minute floor, got $lines lines"
    return 1
  }
}

test_sweep_old_open_pr_marked_stale_not_polled() {
  _setup
  _stub_gh_merged
  local runs="$_ws/runs.jsonl" old_ts
  old_ts=$(date -u -d "20 days ago" +%Y-%m-%dT%H:%M:%SZ)
  cat >"$runs" <<EOF
{"kind":"run","tid":"CRE-7","run_id":"r1","ended_at":"$old_ts","pr":{"pr":1,"url":"https://x","repo":"acme/repo"},"observed_at":"$old_ts"}
EOF
  merge_poll_sweep "$runs"
  local last_state
  last_state=$(tail -1 "$runs" | jq -r '.state')
  _teardown
  [ "$last_state" = "stale" ]
}

test_sweep_unknown_repo_reported_once() {
  _setup
  _stub_gh_merged
  local runs="$_ws/runs.jsonl"
  cat >"$runs" <<'EOF'
{"kind":"run","tid":"CRE-8","run_id":"r1","ended_at":"2026-09-01T00:00:00Z","pr":{"pr":1,"url":"https://x","repo":null},"observed_at":"2026-09-01T00:00:00Z"}
EOF
  merge_poll_sweep "$runs"
  merge_poll_sweep "$runs"
  local count
  count=$(grep -c 'unknown-repo' "$runs")
  _teardown
  [ "$count" -eq 1 ] || {
    echo "expected exactly 1 unknown-repo event across two sweeps, got $count"
    return 1
  }
}

test_sweep_gh_failure_emits_nothing_this_pass() {
  _setup
  _stub_gh_failure
  local runs="$_ws/runs.jsonl" recent_ts
  recent_ts=$(date -u -d "1 day ago" +%Y-%m-%dT%H:%M:%SZ)
  cat >"$runs" <<EOF
{"kind":"run","tid":"CRE-9","run_id":"r1","ended_at":"$recent_ts","pr":{"pr":1,"url":"https://x","repo":"acme/repo"},"observed_at":"$recent_ts"}
EOF
  merge_poll_sweep "$runs"
  local lines
  lines=$(wc -l <"$runs")
  _teardown
  [ "$lines" -eq 1 ] || {
    echo "expected no merge event appended on gh failure, got $lines lines"
    return 1
  }
}

test_sweep_successful_poll_appends_merge_event_shape() {
  _setup
  _stub_gh_merged
  local runs="$_ws/runs.jsonl" recent_ts
  recent_ts=$(date -u -d "1 day ago" +%Y-%m-%dT%H:%M:%SZ)
  cat >"$runs" <<EOF
{"kind":"run","tid":"CRE-10","run_id":"r1","ended_at":"$recent_ts","pr":{"pr":1,"url":"https://x","repo":"acme/repo"},"observed_at":"$recent_ts"}
EOF
  merge_poll_sweep "$runs"
  local last
  last=$(tail -1 "$runs")
  _teardown
  echo "$last" | jq -e '.kind == "merge" and .tid == "CRE-10" and .state == "merged" and .merge_sha == "abc123"' >/dev/null
}

test_merge_poll_one_records_pr_base() {
  _setup
  cat >"$_ws/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"state":"MERGED","mergedAt":"2026-09-02T00:00:00Z","mergeCommit":{"oid":"abc123"},"baseRefName":"epic/x"}'
EOF
  chmod +x "$_ws/bin/gh"
  local with_base without_base
  with_base=$(merge_poll_one "CRE-1" "42" "acme/repo")
  _stub_gh_merged
  without_base=$(merge_poll_one "CRE-1" "42" "acme/repo")
  _teardown
  echo "$with_base" | jq -e '.base == "epic/x"' >/dev/null &&
    echo "$without_base" | jq -e '.base == null' >/dev/null
}

# GitHub #412 end to end: a run completed and left its PR for a human. The
# periodic sweep (what fleetd's _merge_poll_sweep runs) keeps re-polling the
# open PR; once the human merges, the sweep's merge event alone flips
# ticket_pipeline_terminal_done for a dependent — no new pipeline run.
test_sweep_records_human_merge_releasing_dependents() {
  _setup
  source "$LIB_DIR/manifest-read.sh"
  local runs="$_ws/runs.jsonl" recent_ts
  recent_ts=$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ)
  {
    echo '2026-01-01T00:00:00Z|META|branch-context|info|base=develop;integration=;source=default;ticket=feat/x;uat-policy=per-ticket;merge-policy='
    echo '2026-01-01T00:00:01Z|META|pr-created|info|{"pr":7,"url":"https://github.com/acme/repo/pull/7","repo":"acme/repo"}'
    echo '2026-01-01T00:00:05Z|PR-REVIEW|merge-decision|done|skipped: pipeline autonomy=manual requires human merge'
    echo '2026-01-01T00:00:09Z|META|outcome|info|completed: STEP_6'
  } >"$_ws/CRE-20-pipeline.log"
  echo "{\"kind\":\"run\",\"tid\":\"CRE-20\",\"run_id\":\"r1\",\"ended_at\":\"$recent_ts\",\"pr\":{\"pr\":7,\"url\":\"https://x\",\"repo\":\"acme/repo\"},\"observed_at\":\"$recent_ts\"}" >"$runs"

  cat >"$_ws/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null,"baseRefName":"develop"}'
EOF
  chmod +x "$_ws/bin/gh"
  MERGE_POLL_MIN_INTERVAL_SECS=0 merge_poll_sweep "$runs"
  local rc_open=0
  ticket_pipeline_terminal_done CRE-20 "$_ws" || rc_open=$?

  cat >"$_ws/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"state":"MERGED","mergedAt":"2026-09-02T00:00:00Z","mergeCommit":{"oid":"abc123"},"baseRefName":"develop"}'
EOF
  MERGE_POLL_MIN_INTERVAL_SECS=0 merge_poll_sweep "$runs"
  local rc_merged=0
  ticket_pipeline_terminal_done CRE-20 "$_ws" || rc_merged=$?
  local n_merge
  n_merge=$(grep -c '"kind":"merge"' "$runs" || true)
  _teardown
  [ "$rc_open" -ne 0 ] && [ "$rc_merged" -eq 0 ] && [ "$n_merge" = "2" ]
}

# ── merge_poll_close_merged (GitHub #765) ────────────────────────────────────
# These run the real flow-run.sh → flow.sh against a temp REPOS_ROOT, so the
# manifest stage and the outbox are the real ones. The board driver is a stub.

_FLOW_SH="$LIB_DIR/../skills/ticket-flow/flow.sh"

# _close_setup: after _setup. Exports the env flow.sh needs.
_close_setup() {
  mkdir -p "$_ws/repos" "$_ws/drivers" "$_ws/logs"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$_ws/drivers/linear.sh"
  chmod +x "$_ws/drivers/linear.sh"
  export REPOS_ROOT="$_ws/repos" CLAUDE_SKILLS_LIB="$LIB_DIR"
  export TICKET_FLOW_LOCK_DIR="$_ws/locks" OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE="$_ws/drivers"
  # flow-run.sh would otherwise pick an installed ~/.claude/skills flow.sh.
  export FLEET_PIPELINE_LOG_DIR="$_ws/logs" FLOW_RUN_FLOW_SH="$_FLOW_SH"
  unset FLEET_GENERATION FLEET_STATE_DIR FLEET_WORKER_PID LOG_FILE TAP_LOG HB_LOG_FILE
}
_close_teardown() {
  unset REPOS_ROOT CLAUDE_SKILLS_LIB TICKET_FLOW_LOCK_DIR OUTBOX_DRAIN_DRIVER_DIR_OVERRIDE FLEET_PIPELINE_LOG_DIR FLOW_RUN_FLOW_SH
  _teardown
}
_flow() { bash "$_FLOW_SH" "$@" >/dev/null 2>&1; }
_stage() { get_ticket_manifest_field "$1" stage 2>/dev/null; }
_rev() { get_ticket_manifest_field "$1" rev 2>/dev/null; }
_n_event() { grep -c "\"event\":\"$2\"" "$_ws/logs/$1-outbox.jsonl" 2>/dev/null || true; }

# _close_ticket TID REVIEW_TRIGGER...: a finished run that left PR 7 open.
_close_ticket() {
  local tid="$1" recent_ts trig
  shift
  recent_ts=$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ)
  _flow "$tid" implement-complete
  for trig in "$@"; do _flow "$tid" "$trig"; done
  {
    echo '2026-01-01T00:00:00Z|META|branch-context|info|base=epic/x;integration=epic/x;source=epic-directive;ticket=feat/x;uat-policy=epic;merge-policy=manual'
    echo '2026-01-01T00:00:01Z|META|pr-created|info|{"pr":7,"url":"https://github.com/acme/repo/pull/7","repo":"acme/repo"}'
    echo '2026-01-01T00:00:05Z|PR-REVIEW|merge-decision|done|skipped: epic Branch Directive Merge Policy: manual requires human merge'
    echo '2026-01-01T00:00:09Z|META|outcome|info|completed: STEP_6'
  } >"$_ws/logs/$tid-pipeline.log"
  echo "{\"kind\":\"run\",\"tid\":\"$tid\",\"run_id\":\"r-$tid\",\"ended_at\":\"$recent_ts\",\"pr\":{\"pr\":7,\"url\":\"https://x\",\"repo\":\"acme/repo\"},\"observed_at\":\"$recent_ts\"}" >>"$_ws/logs/runs.jsonl"
}
# _gh_state STATE [BASE]
_gh_state() {
  local merged_at=null commit=null
  [ "$1" = MERGED ] && merged_at='"2026-09-02T00:00:00Z"' && commit='{"oid":"abc123"}'
  cat >"$_ws/bin/gh" <<EOF
#!/usr/bin/env bash
echo '{"state":"$1","mergedAt":$merged_at,"mergeCommit":$commit,"baseRefName":"${2:-epic/x}"}'
EOF
  chmod +x "$_ws/bin/gh"
}
_sweep() { MERGE_POLL_MIN_INTERVAL_SECS=0 merge_poll_sweep "$_ws/logs/runs.jsonl" "$@"; }

# Review pass with a human merge pending leaves the ticket in Review; the
# observed merge closes it, once, however often the sweep repeats.
test_close_merge_observed_moves_review_to_done_once() {
  _setup
  _close_setup
  _close_ticket EPC-1 pr-review-pass-merge-pending
  local ok=1 log_before
  [ "$(_stage EPC-1)" = "Review" ] || ok=0
  get_ticket_manifest_field EPC-1 flags | jq -e 'index("reviewed") != null' >/dev/null || ok=0
  log_before=$(cat "$_ws/logs/EPC-1-pipeline.log")

  _gh_state OPEN
  _sweep
  [ "$(_stage EPC-1)" = "Review" ] && [ "$(_n_event EPC-1 merge-observed)" = 0 ] || ok=0

  _gh_state MERGED
  _sweep
  [ "$(_stage EPC-1)" = "Done" ] && [ "$(_n_event EPC-1 merge-observed)" = 1 ] || ok=0
  local rev_done
  rev_done=$(_rev EPC-1)

  _sweep
  _sweep EPC-1
  merge_poll_close_merged "$_ws/logs/runs.jsonl"
  [ "$(_stage EPC-1)" = "Done" ] && [ "$(_n_event EPC-1 merge-observed)" = 1 ] &&
    [ "$(_rev EPC-1)" = "$rev_done" ] || ok=0
  # The run has ended: nothing is appended to the pipeline log.
  [ "$(cat "$_ws/logs/EPC-1-pipeline.log")" = "$log_before" ] || ok=0
  ticket_pipeline_terminal_done EPC-1 "$_ws/logs" || ok=0
  _close_teardown
  [ "$ok" = 1 ]
}

# A ticket that review already closed (auto-merge, or merged before the
# transition) is in Done: observing its merge fires nothing.
test_close_already_done_fires_nothing() {
  _setup
  _close_setup
  _close_ticket EPC-2 pr-review-pass-done
  local ok=1 rev_before
  [ "$(_stage EPC-2)" = "Done" ] || ok=0
  rev_before=$(_rev EPC-2)
  _gh_state MERGED
  _sweep
  _sweep
  grep -q '"state":"merged"' "$_ws/logs/runs.jsonl" || ok=0
  [ "$(_stage EPC-2)" = "Done" ] && [ "$(_n_event EPC-2 merge-observed)" = 0 ] &&
    [ "$(_rev EPC-2)" = "$rev_before" ] || ok=0
  _close_teardown
  [ "$ok" = 1 ]
}

# Review without `reviewed` (the review failed, or never ran) is not closed by
# a merge; neither is a per-ticket ticket parked in UAT for its human merge.
test_close_needs_review_stage_and_reviewed_flag() {
  _setup
  _close_setup
  _close_ticket EPC-3 pr-review-fail
  _close_ticket EPC-4 pr-review-pass-uat
  _gh_state MERGED
  _sweep
  _sweep
  local ok=1
  [ "$(_stage EPC-3)" = "Review" ] && [ "$(_n_event EPC-3 merge-observed)" = 0 ] || ok=0
  [ "$(_stage EPC-4)" = "UAT" ] && [ "$(_n_event EPC-4 merge-observed)" = 0 ] || ok=0
  _close_teardown
  [ "$ok" = 1 ]
}

# The board must not show Done for a merge dispatch does not accept.
test_close_skips_merge_into_another_base() {
  _setup
  _close_setup
  _close_ticket EPC-5 pr-review-pass-merge-pending
  _gh_state MERGED develop
  _sweep
  local ok=1
  [ "$(ticket_pipeline_merge_state EPC-5 "$_ws/logs")" = "merged-other-base" ] || ok=0
  [ "$(_stage EPC-5)" = "Review" ] && [ "$(_n_event EPC-5 merge-observed)" = 0 ] || ok=0
  _close_teardown
  [ "$ok" = 1 ]
}

# A flow.sh failure on the pass that observes the merge (lock busy) is
# retried by the next sweep, although the PR is no longer a poll candidate.
test_close_retries_after_flow_failure() {
  _setup
  _close_setup
  _close_ticket EPC-6 pr-review-pass-merge-pending
  printf '#!/usr/bin/env bash\nexit 42\n' >"$_ws/flow-run-busy.sh"
  _gh_state MERGED
  MERGE_POLL_FLOW_RUN="$_ws/flow-run-busy.sh" _sweep
  local ok=1
  [ "$(_stage EPC-6)" = "Review" ] || ok=0
  [ "$(merge_poll_candidates "$_ws/logs/runs.jsonl")" = "[]" ] || ok=0
  _sweep
  [ "$(_stage EPC-6)" = "Done" ] && [ "$(_n_event EPC-6 merge-observed)" = 1 ] || ok=0
  _close_teardown
  [ "$ok" = 1 ]
}

# No REPOS_ROOT (no manifest root): the sweep still records the merge and
# fires nothing.
test_close_without_repos_root_is_a_noop() {
  _setup
  _close_setup
  _close_ticket EPC-7 pr-review-pass-merge-pending
  _gh_state MERGED
  local root="$REPOS_ROOT" ok=1
  unset REPOS_ROOT
  _sweep
  export REPOS_ROOT="$root"
  grep -q '"state":"merged"' "$_ws/logs/runs.jsonl" || ok=0
  [ "$(_stage EPC-7)" = "Review" ] || ok=0
  _close_teardown
  [ "$ok" = 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatcher
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"

for fn in \
  test_merge_poll_one_success_emits_merged_with_sha \
  test_merge_poll_one_gh_failure_emits_nothing \
  test_candidates_selects_run_with_pr_repo \
  test_candidates_excludes_tid_with_terminal_merged_state \
  test_candidates_surfaces_repo_less_pr_for_unknown_repo_reporting \
  test_sweep_recently_polled_candidate_is_skipped \
  test_sweep_old_open_pr_marked_stale_not_polled \
  test_sweep_unknown_repo_reported_once \
  test_sweep_gh_failure_emits_nothing_this_pass \
  test_sweep_successful_poll_appends_merge_event_shape \
  test_merge_poll_one_records_pr_base \
  test_sweep_records_human_merge_releasing_dependents \
  test_close_merge_observed_moves_review_to_done_once \
  test_close_already_done_fires_nothing \
  test_close_needs_review_stage_and_reviewed_flag \
  test_close_skips_merge_into_another_base \
  test_close_retries_after_flow_failure \
  test_close_without_repos_root_is_a_noop; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
