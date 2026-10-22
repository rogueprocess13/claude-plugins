#!/usr/bin/env bash
# test-pr-evidence.sh — unit tests for lib/pr-evidence.sh (GitHub #525).
#
# A PR opened by the VERIFY phase never left a `META|pr-created` line: the
# capture was prose in ticket-verify/SKILL.md that the agent paraphrased into
# an improvised `VERIFY|pr-open|done|<url>` line. The run event then carried
# `repo: null`, merge-poll wrote `unknown-repo` once and never polled again,
# and every blocked-by dependent stayed held after a human merged the PR.
#
# Usage: bash test-pr-evidence.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if ("$@") 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_ws=""
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/logs" "$_ws/home/.claude/plugins/cache" "$_ws/bin"
  export FLEET_PIPELINE_LOG_DIR="$_ws/logs"
  unset FLEET_GENERATION FLEET_STATE_DIR REPOS_ROOT LINEAR_API_KEY
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

_created_lines() { grep -c '|META|pr-created|info|' "$1" 2>/dev/null || true; }

# ── record_pr_created ───────────────────────────────────────────────────────

test_record_writes_marker_with_repo() {
  _setup
  # shellcheck source=/dev/null
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-1-pipeline.log"
  echo "2026-01-01T00:00:00Z|META|schema|info|1" >"$log"
  record_pr_created "$log" CRE-1 "https://github.com/acme/repo/pull/73" >/dev/null
  local json
  json=$(grep '|META|pr-created|info|' "$log" | tail -1 | cut -d'|' -f5-)
  _teardown
  [ "$(jq -r .pr <<<"$json")" = "73" ] &&
    [ "$(jq -r .repo <<<"$json")" = "acme/repo" ] &&
    [ "$(jq -r .url <<<"$json")" = "https://github.com/acme/repo/pull/73" ]
}

test_record_new_emits_pr_opened_once() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-2-pipeline.log"
  echo "2026-01-01T00:00:00Z|META|schema|info|1" >"$log"
  record_pr_created --new "$log" CRE-2 "https://github.com/acme/repo/pull/5" >/dev/null
  record_pr_created --new "$log" CRE-2 "https://github.com/acme/repo/pull/5" >/dev/null
  local n_ev n_lines
  n_ev=$(grep -c '"event":"pr-opened"' "$_ws/logs/CRE-2-outbox.jsonl" 2>/dev/null || true)
  n_lines=$(_created_lines "$log")
  _teardown
  [ "$n_ev" = "1" ] && [ "$n_lines" = "1" ]
}

test_record_existing_pr_does_not_emit() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-3-pipeline.log"
  echo "2026-01-01T00:00:00Z|META|schema|info|1" >"$log"
  record_pr_created "$log" CRE-3 "https://github.com/acme/repo/pull/6" >/dev/null
  local has_outbox=0
  [ -s "$_ws/logs/CRE-3-outbox.jsonl" ] && has_outbox=1
  _teardown
  [ "$has_outbox" = "0" ]
}

test_record_rejects_non_pr_url() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-4-pipeline.log"
  echo "2026-01-01T00:00:00Z|META|schema|info|1" >"$log"
  local rc=0
  record_pr_created "$log" CRE-4 "not a url" >/dev/null 2>&1 || rc=$?
  local n
  n=$(_created_lines "$log")
  _teardown
  [ "$rc" -ne 0 ] && [ "$n" = "0" ]
}

# ── pr_evidence_backfill ────────────────────────────────────────────────────

# The exact shape from the issue: an improvised VERIFY line carries the URL,
# PR-REVIEW carries the bare number, no pr-created line anywhere.
_issue_log() {
  cat >"$1" <<'EOF'
2026-01-01T00:00:00Z|META|schema|info|1
2026-01-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-5-a","gen":null,"trigger":"manual","pid":1}
2026-01-01T00:00:02Z|META|branch-context|info|base=epic/x;integration=epic/x;source=epic-directive;ticket=feat/CRE-5-thing
2026-01-01T00:00:03Z|VERIFY|pr-open|done|https://github.com/acme/repo/pull/73 (base epic/x); implement-complete not re-fired (--from-auto)
2026-01-01T00:00:04Z|VERIFY|verify|done|PASS 3/3; PR #73
2026-01-01T00:00:05Z|PR-REVIEW|checkout-pr|done|73
2026-01-01T00:00:06Z|PR-REVIEW|merge-decision|done|skipped: epic Branch Directive Merge Policy: manual requires human merge
EOF
}

test_backfill_from_improvised_verify_url() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-5-pipeline.log"
  _issue_log "$log"
  pr_evidence_backfill "$log" CRE-5 >/dev/null
  local json
  json=$(grep '|META|pr-created|info|' "$log" | tail -1 | cut -d'|' -f5-)
  _teardown
  [ "$(jq -r .pr <<<"$json")" = "73" ] && [ "$(jq -r .repo <<<"$json")" = "acme/repo" ]
}

test_backfill_is_idempotent() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-5-pipeline.log"
  _issue_log "$log"
  pr_evidence_backfill "$log" CRE-5 >/dev/null
  pr_evidence_backfill "$log" CRE-5 >/dev/null
  local n
  n=$(_created_lines "$log")
  _teardown
  [ "$n" = "1" ]
}

test_backfill_noop_when_marker_present() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-6-pipeline.log"
  _issue_log "$log"
  echo '2026-01-01T00:00:07Z|META|pr-created|info|{"pr":73,"url":"https://github.com/acme/repo/pull/73","repo":"acme/repo"}' >>"$log"
  local before after
  before=$(wc -l <"$log")
  pr_evidence_backfill "$log" CRE-6 >/dev/null
  after=$(wc -l <"$log")
  _teardown
  [ "$before" = "$after" ]
}

# No URL anywhere (e.g. "gateway PR #103 opened"): resolve the bare
# checkout-pr number against the ticket's own worktree remotes, accepting the
# PR only when gh confirms its head is this ticket's branch.
test_backfill_resolves_bare_number_via_worktree_remote() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-7-pipeline.log"
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|META|schema|info|1
2026-01-01T00:00:02Z|META|branch-context|info|base=epic/x;integration=epic/x;source=epic-directive;ticket=feat/CRE-7-thing
2026-01-01T00:00:03Z|VERIFY|verify|done|PASS 2/2, gateway PR #103 opened
2026-01-01T00:00:05Z|PR-REVIEW|checkout-pr|done|103
EOF
  local repos="$_ws/repos" wt
  for wt in gateway other; do
    mkdir -p "$repos/.ticket-auto/worktrees/CRE-7/$wt"
    git -C "$repos/.ticket-auto/worktrees/CRE-7/$wt" init -q
    git -C "$repos/.ticket-auto/worktrees/CRE-7/$wt" remote add origin "git@github.com:acme/$wt.git"
  done
  cat >"$_ws/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh pr view <n> --repo <slug> --json url,headRefName
repo=""
while [ $# -gt 0 ]; do
  [ "$1" = "--repo" ] && repo="$2"
  shift
done
case "$repo" in
acme/gateway) echo '{"url":"https://github.com/acme/gateway/pull/103","headRefName":"feat/CRE-7-thing"}' ;;
acme/other) echo '{"url":"https://github.com/acme/other/pull/103","headRefName":"feat/unrelated"}' ;;
*) exit 1 ;;
esac
EOF
  chmod +x "$_ws/bin/gh"
  REPOS_ROOT="$repos" PATH="$_ws/bin:$PATH" pr_evidence_backfill "$log" CRE-7 >/dev/null
  local json
  json=$(grep '|META|pr-created|info|' "$log" | tail -1 | cut -d'|' -f5-)
  _teardown
  [ "$(jq -r .repo <<<"$json")" = "acme/gateway" ] && [ "$(jq -r .pr <<<"$json")" = "103" ]
}

# ── merge-state end to end (the dependent-release path) ─────────────────────

# A backfilled marker lands near the end of the log. The pipeline's own merge
# record (here PR-REVIEW's direct merge) sits BEFORE it, and must still count:
# the PR reference is the earliest line naming the same PR.
test_backfilled_marker_does_not_hide_earlier_merge_record() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  source "$LIB_DIR/manifest-read.sh"
  local log="$_ws/logs/CRE-8-pipeline.log"
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|META|schema|info|1
2026-01-01T00:00:03Z|VERIFY|pr-open|done|https://github.com/acme/repo/pull/9
2026-01-01T00:00:05Z|PR-REVIEW|checkout-pr|done|9
2026-01-01T00:00:06Z|PR-REVIEW|merge-decision|done|merged
EOF
  pr_evidence_backfill "$log" CRE-8 >/dev/null
  echo "2026-01-01T00:00:09Z|META|outcome|info|completed: STEP_6" >>"$log"
  local state
  state=$(ticket_pipeline_merge_state CRE-8 "$_ws/logs") || true
  _teardown
  [ "$state" = "merged" ]
}

# The issue's full path: finalize must leave a run event whose pr carries the
# repo, so merge-poll polls it instead of writing unknown-repo.
test_finalize_run_event_carries_repo_for_verify_opened_pr() {
  _setup
  cat >"$_ws/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null,"baseRefName":"epic/x"}'
EOF
  chmod +x "$_ws/bin/gh"
  local log="$_ws/logs/CRE-5-pipeline.log"
  _issue_log "$log"
  PATH="$_ws/bin:$PATH" HOME="$_ws/home" bash "$LIB_DIR/pipeline-finalize.sh" CRE-5 0 "$log" >/dev/null 2>&1 || true
  local run_repo merge_state last
  run_repo=$(grep '"kind":"run"' "$_ws/logs/runs.jsonl" | tail -1 | jq -r '.pr.repo // empty')
  merge_state=$(grep '"kind":"merge"' "$_ws/logs/runs.jsonl" | tail -1 | jq -r '.state // empty')
  last=$(tail -1 "$log")
  _teardown
  [ "$run_repo" = "acme/repo" ] && [ "$merge_state" = "open" ] &&
    echo "$last" | grep -q '|META|outcome|info|'
}

# ── ticket-verify must call the deterministic recorder ──────────────────────

test_ticket_verify_calls_record_pr_created() {
  local skill_md="$LIB_DIR/../skills/ticket-verify/SKILL.md"
  grep -q 'record_pr_created --new' "$skill_md" && grep -q 'record_pr_created "{LOG_FILE}"' "$skill_md"
}

test_epic_branch_calls_record_pr_created() {
  grep -q 'record_pr_created' "$LIB_DIR/epic-branch.sh"
}

# ═══════════════════════════════════════════════════════════════════════════════
FILTER="${1:-}"

for fn in \
  test_record_writes_marker_with_repo \
  test_record_new_emits_pr_opened_once \
  test_record_existing_pr_does_not_emit \
  test_record_rejects_non_pr_url \
  test_backfill_from_improvised_verify_url \
  test_backfill_is_idempotent \
  test_backfill_noop_when_marker_present \
  test_backfill_resolves_bare_number_via_worktree_remote \
  test_backfilled_marker_does_not_hide_earlier_merge_record \
  test_finalize_run_event_carries_repo_for_verify_opened_pr \
  test_ticket_verify_calls_record_pr_created \
  test_epic_branch_calls_record_pr_created; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
