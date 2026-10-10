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
  test_sweep_records_human_merge_releasing_dependents; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
