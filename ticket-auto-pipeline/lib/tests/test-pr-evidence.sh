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
#
# Backfill never trusts a URL or number in free text on its own: gh must
# confirm the PR's head is this ticket's branch, in a repo that is one of the
# ticket's own worktree remotes. Anything it cannot verify is a warn line.

# _mk_worktrees <tid> <slug>... — git worktree dirs with GitHub origins.
_mk_worktrees() {
  local tid="$1" slug
  shift
  for slug in "$@"; do
    local d="$_ws/repos/.ticket-auto/worktrees/$tid/${slug#*/}"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" remote add origin "git@github.com:${slug}.git"
  done
}

# _gh_stub — answers `gh pr view <url>|<n> --repo <slug> ...` from
# $_ws/prs.tsv ("<slug> <num> <head>" per line); unknown PR → exit 1.
_gh_stub() {
  : >"$_ws/prs.tsv"
  cat >"$_ws/bin/gh" <<EOF
#!/usr/bin/env bash
db="$_ws/prs.tsv"
EOF
  cat >>"$_ws/bin/gh" <<'EOF'
[ "$1" = pr ] && [ "$2" = view ] || exit 1
target="$3"
shift 3
repo=""
while [ $# -gt 0 ]; do
  [ "$1" = "--repo" ] && repo="$2"
  shift
done
case "$target" in
https://github.com/*)
  repo=$(echo "$target" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/[0-9]+#\1#')
  num="${target##*/}"
  ;;
*) num="$target" ;;
esac
line=$(awk -v r="$repo" -v n="$num" '$1 == r && $2 == n' "$db" | head -1)
[ -n "$line" ] || exit 1
head=$(echo "$line" | awk '{print $3}')
printf '{"url":"https://github.com/%s/pull/%s","headRefName":"%s","state":"OPEN","mergedAt":null,"mergeCommit":null,"baseRefName":"epic/x"}\n' "$repo" "$num" "$head"
EOF
  chmod +x "$_ws/bin/gh"
}

_backfill() {
  REPOS_ROOT="$_ws/repos" PATH="$_ws/bin:$PATH" pr_evidence_backfill "$@" >/dev/null
}

# The exact shape from the issue: an improvised VERIFY line carries the URL,
# PR-REVIEW carries the bare number, no pr-created line anywhere.
_issue_log() {
  local tid="${2:-CRE-5}"
  cat >"$1" <<EOF
2026-01-01T00:00:00Z|META|schema|info|1
2026-01-01T00:00:01Z|META|run-id|info|{"run_id":"${tid}-a","gen":null,"trigger":"manual","pid":1}
2026-01-01T00:00:02Z|META|branch-context|info|base=epic/x;integration=epic/x;source=epic-directive;ticket=feat/${tid}-thing
2026-01-01T00:00:03Z|VERIFY|pr-open|done|https://github.com/acme/repo/pull/73 (base epic/x); implement-complete not re-fired (--from-auto)
2026-01-01T00:00:04Z|VERIFY|verify|done|PASS 3/3; PR #73
2026-01-01T00:00:05Z|PR-REVIEW|checkout-pr|done|73
2026-01-01T00:00:06Z|PR-REVIEW|merge-decision|done|skipped: epic Branch Directive Merge Policy: manual requires human merge
EOF
}

test_backfill_from_verified_verify_url() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-5-pipeline.log"
  _issue_log "$log"
  _mk_worktrees CRE-5 acme/repo
  _gh_stub
  echo "acme/repo 73 feat/CRE-5-thing" >>"$_ws/prs.tsv"
  _backfill "$log" CRE-5
  local json
  json=$(grep '|META|pr-created|info|' "$log" | tail -1 | cut -d'|' -f5-)
  _teardown
  [ "$(jq -r .pr <<<"$json")" = "73" ] && [ "$(jq -r .repo <<<"$json")" = "acme/repo" ] &&
    [ "$(jq -r .backfill <<<"$json")" = "true" ]
}

test_backfill_is_idempotent() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-5-pipeline.log"
  _issue_log "$log"
  _mk_worktrees CRE-5 acme/repo
  _gh_stub
  echo "acme/repo 73 feat/CRE-5-thing" >>"$_ws/prs.tsv"
  _backfill "$log" CRE-5
  _backfill "$log" CRE-5
  local n
  n=$(_created_lines "$log")
  _teardown
  [ "$n" = "1" ]
}

# Security review: an agent links a related/upstream PR on a VERIFY line.
# That PR is not this ticket's — it must never become the ticket's PR.
test_backfill_ignores_unrelated_pr_url() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-11-pipeline.log"
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|META|schema|info|1
2026-01-01T00:00:02Z|META|branch-context|info|base=epic/x;integration=epic/x;source=epic-directive;ticket=feat/CRE-11-thing
2026-01-01T00:00:03Z|VERIFY|verify|done|PASS; see upstream fix https://github.com/other/upstream/pull/500
EOF
  _mk_worktrees CRE-11 acme/repo
  _gh_stub
  echo "other/upstream 500 main-fix" >>"$_ws/prs.tsv"
  _backfill "$log" CRE-11
  local n warn
  n=$(_created_lines "$log")
  warn=$(grep -c '|META|pr-evidence|warn|' "$log" || true)
  _teardown
  [ "$n" = "0" ] && [ "$warn" -ge 1 ]
}

# Same repo, but the PR's head is another branch: still not this ticket's PR.
test_backfill_rejects_url_with_other_head_branch() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-12-pipeline.log"
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|META|schema|info|1
2026-01-01T00:00:02Z|META|branch-context|info|base=epic/x;integration=epic/x;source=epic-directive;ticket=feat/CRE-12-thing
2026-01-01T00:00:03Z|VERIFY|verify|done|PASS; sibling PR https://github.com/acme/repo/pull/41
EOF
  _mk_worktrees CRE-12 acme/repo
  _gh_stub
  echo "acme/repo 41 feat/CRE-99-sibling" >>"$_ws/prs.tsv"
  _backfill "$log" CRE-12
  local n warn
  n=$(_created_lines "$log")
  warn=$(grep -c '|META|pr-evidence|warn|' "$log" || true)
  _teardown
  [ "$n" = "0" ] && [ "$warn" -ge 1 ]
}

# Unverifiable (no REPOS_ROOT / gh) → warn, never a marker.
test_backfill_unverifiable_writes_warn_only() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-13-pipeline.log"
  _issue_log "$log" CRE-13
  PATH="$_ws/bin:$PATH" pr_evidence_backfill "$log" CRE-13 >/dev/null
  local n warn
  n=$(_created_lines "$log")
  warn=$(grep -c '|META|pr-evidence|warn|' "$log" || true)
  _teardown
  [ "$n" = "0" ] && [ "$warn" = "1" ]
}

test_backfill_noop_when_marker_present() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-6-pipeline.log"
  _issue_log "$log" CRE-6
  echo '2026-01-01T00:00:07Z|META|pr-created|info|{"pr":73,"url":"https://github.com/acme/repo/pull/73","repo":"acme/repo"}' >>"$log"
  _mk_worktrees CRE-6 acme/repo
  _gh_stub
  echo "acme/repo 73 feat/CRE-6-thing" >>"$_ws/prs.tsv"
  local before after
  before=$(wc -l <"$log")
  _backfill "$log" CRE-6
  after=$(wc -l <"$log")
  _teardown
  [ "$before" = "$after" ]
}

# Any real marker in this run's window blocks backfill — even for a
# different PR the log mentions.
test_backfill_never_adds_beside_real_marker() {
  _setup
  source "$LIB_DIR/pr-evidence.sh"
  local log="$_ws/logs/CRE-14-pipeline.log"
  _issue_log "$log" CRE-14
  echo '2026-01-01T00:00:07Z|META|pr-created|info|{"pr":80,"url":"https://github.com/acme/repo/pull/80","repo":"acme/repo"}' >>"$log"
  _mk_worktrees CRE-14 acme/repo
  _gh_stub
  echo "acme/repo 73 feat/CRE-14-thing" >>"$_ws/prs.tsv"
  _backfill "$log" CRE-14
  local n
  n=$(_created_lines "$log")
  _teardown
  [ "$n" = "1" ]
}

# A real marker wins in ticket_pipeline_pr_ref even when a backfill record is
# later in the log (e.g. an earlier run's real record, a later run's backfill).
test_pr_ref_prefers_real_marker_over_backfill() {
  _setup
  source "$LIB_DIR/manifest-read.sh"
  local log="$_ws/logs/CRE-15-pipeline.log"
  cat >"$log" <<'EOF'
2026-01-01T00:00:00Z|META|schema|info|1
2026-01-01T00:00:01Z|META|pr-created|info|{"pr":7,"url":"https://github.com/acme/repo/pull/7","repo":"acme/repo"}
2026-01-01T00:00:02Z|META|pr-created|info|{"pr":9,"url":"https://github.com/acme/other/pull/9","repo":"acme/other","backfill":true}
EOF
  local ref
  ref=$(ticket_pipeline_pr_ref "$log")
  _teardown
  [ "$(cut -f2 <<<"$ref")" = "7" ] && [ "$(cut -f3 <<<"$ref")" = "acme/repo" ]
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
  _mk_worktrees CRE-7 acme/gateway acme/other
  _gh_stub
  echo "acme/gateway 103 feat/CRE-7-thing" >>"$_ws/prs.tsv"
  echo "acme/other 103 feat/unrelated" >>"$_ws/prs.tsv"
  _backfill "$log" CRE-7
  local json n
  json=$(grep '|META|pr-created|info|' "$log" | tail -1 | cut -d'|' -f5-)
  n=$(_created_lines "$log")
  _teardown
  [ "$n" = "1" ] && [ "$(jq -r .repo <<<"$json")" = "acme/gateway" ] && [ "$(jq -r .pr <<<"$json")" = "103" ]
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
2026-01-01T00:00:02Z|META|branch-context|info|base=epic/x;integration=epic/x;source=epic-directive;ticket=feat/CRE-8-thing
2026-01-01T00:00:03Z|VERIFY|pr-open|done|https://github.com/acme/repo/pull/9
2026-01-01T00:00:05Z|PR-REVIEW|checkout-pr|done|9
2026-01-01T00:00:06Z|PR-REVIEW|merge-decision|done|merged
EOF
  _mk_worktrees CRE-8 acme/repo
  _gh_stub
  echo "acme/repo 9 feat/CRE-8-thing" >>"$_ws/prs.tsv"
  _backfill "$log" CRE-8
  echo "2026-01-01T00:00:09Z|META|outcome|info|completed: STEP_6" >>"$log"
  local state n
  n=$(_created_lines "$log")
  state=$(ticket_pipeline_merge_state CRE-8 "$_ws/logs") || true
  _teardown
  [ "$n" = "1" ] && [ "$state" = "merged" ]
}

# The issue's full path: finalize must leave a run event whose pr carries the
# repo, so merge-poll polls it instead of writing unknown-repo.
test_finalize_run_event_carries_repo_for_verify_opened_pr() {
  _setup
  _mk_worktrees CRE-5 acme/repo
  _gh_stub
  echo "acme/repo 73 feat/CRE-5-thing" >>"$_ws/prs.tsv"
  local log="$_ws/logs/CRE-5-pipeline.log"
  _issue_log "$log"
  REPOS_ROOT="$_ws/repos" PATH="$_ws/bin:$PATH" HOME="$_ws/home" \
    bash "$LIB_DIR/pipeline-finalize.sh" CRE-5 0 "$log" >/dev/null 2>&1 || true
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
  test_backfill_from_verified_verify_url \
  test_backfill_is_idempotent \
  test_backfill_ignores_unrelated_pr_url \
  test_backfill_rejects_url_with_other_head_branch \
  test_backfill_unverifiable_writes_warn_only \
  test_backfill_noop_when_marker_present \
  test_backfill_never_adds_beside_real_marker \
  test_pr_ref_prefers_real_marker_over_backfill \
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
