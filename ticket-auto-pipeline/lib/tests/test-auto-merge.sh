#!/usr/bin/env bash
# test-auto-merge.sh — unit tests for lib/auto-merge.sh (review finding
# DET-RV-4: the router's inline auto-merge ignored MERGE_POLICY and merged
# when `gh pr view` failed). `gh` is stubbed via PATH; every invocation is
# recorded to $_ws/gh.calls.
# Usage: bash test-auto-merge.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
AM="$LIB_DIR/auto-merge.sh"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
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
  mkdir -p "$_ws/bin"
  : >"$_ws/gh.calls"
  # Default gh: `pr view` prints a ticket head ref, `pr merge` succeeds.
  _stub_gh 'feat/cre-2' 0 0
  cat >"$_ws/log" <<'EOF'
2026-10-01T00:00:00Z|META|outcome-label|info|Smooth
2026-10-01T00:00:01Z|PR-REVIEW|checkout-pr|done|12
EOF
  : >"$_ws/env.sh"
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

# _stub_gh <head> <view_rc> <merge_rc>
_stub_gh() {
  cat >"$_ws/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$_ws/gh.calls"
case "\$1 \$2" in
"pr view") [ "$2" = 0 ] || exit "$2"; echo "$1" ;;
"pr merge") exit "$3" ;;
esac
exit 0
EOF
  chmod +x "$_ws/bin/gh"
}

# _am [flags...] — run auto-merge.sh with the default eligible inputs; extra
# flags override. Prints stdout; rc in $_rc.
_rc=0
_out=""
_am() {
  _rc=0
  _out=$(PATH="$_ws/bin:$PATH" AUTONOMY="" MERGE_POLICY="" INTEGRATION_BRANCH="" COMPLEXITY="" \
    bash "$AM" --env-file "$_ws/env.sh" --autonomy auto --complexity simple "$@" CRE-2 "$_ws/log" 2>/dev/null) || _rc=$?
}

_merged() { grep -q '^pr merge 12' "$_ws/gh.calls"; }

test_happy_path_merges() {
  _setup
  _am
  local ok=1
  [ "$_rc" = 0 ] && _merged && echo "$_out" | grep -q '^AUTO_MERGE=merged' &&
    grep -q '|META|pr-auto-merge|done|12' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_semi_auto_merges() {
  _setup
  _am --autonomy semi-auto
  local ok=1
  [ "$_rc" = 0 ] && _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_merge_policy_manual_skips() {
  _setup
  _am --merge-policy manual
  local ok=1
  [ "$_rc" = 3 ] && ! _merged && echo "$_out" | grep -q 'Merge Policy: manual' &&
    grep -q '|META|pr-auto-merge|skip|MERGE_AUTHORIZATION' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_merge_policy_on_all_children_done_skips() {
  _setup
  _am --merge-policy on-all-children-done
  local ok=1
  [ "$_rc" = 3 ] && ! _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_merge_policy_from_env_file_skips() {
  # The router passes no --merge-policy flag; the agent env file is the
  # source of truth on a pipeline run.
  _setup
  echo 'MERGE_POLICY="manual"' >"$_ws/env.sh"
  _rc=0
  _out=$(PATH="$_ws/bin:$PATH" AUTONOMY="" MERGE_POLICY="" bash "$AM" --env-file "$_ws/env.sh" \
    --autonomy auto --complexity simple CRE-2 "$_ws/log" 2>/dev/null) || _rc=$?
  local ok=1
  [ "$_rc" = 3 ] && ! _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_manual_autonomy_never_merges() {
  _setup
  _am --autonomy manual
  local ok=1
  [ "$_rc" = 3 ] && ! _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_unset_autonomy_never_merges() {
  _setup
  _am --autonomy ""
  local ok=1
  [ "$_rc" = 3 ] && ! _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_complex_skips() {
  _setup
  _am --complexity complex
  local ok=1
  [ "$_rc" = 3 ] && ! _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_rough_outcome_skips() {
  _setup
  echo '2026-10-01T00:00:02Z|META|outcome-label|info|Rough' >>"$_ws/log"
  _am
  local ok=1
  [ "$_rc" = 3 ] && ! _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_no_pr_number_skips() {
  _setup
  echo '2026-10-01T00:00:00Z|META|outcome-label|info|Smooth' >"$_ws/log"
  _am
  local ok=1
  [ "$_rc" = 3 ] && ! grep -q '^pr ' "$_ws/gh.calls" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_integration_pr_guarded() {
  _setup
  _stub_gh 'epic/thing' 0 0
  _am --integration-branch epic/thing
  local ok=1
  [ "$_rc" = 3 ] && ! _merged && grep -q 'INTEGRATION_PR_GUARD' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_ticket_pr_targeting_epic_still_merges() {
  _setup
  _stub_gh 'feat/cre-2' 0 0
  _am --integration-branch epic/thing
  local ok=1
  [ "$_rc" = 0 ] && _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_gh_view_failure_fails_closed() {
  _setup
  _stub_gh '' 1 0
  _am --integration-branch epic/thing
  local ok=1
  [ "$_rc" = 3 ] && ! _merged && grep -q 'PR_HEAD_UNREADABLE' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_gh_merge_failure_is_soft_rc4() {
  _setup
  _stub_gh 'feat/cre-2' 0 1
  _am
  local ok=1
  [ "$_rc" = 4 ] && echo "$_out" | grep -q '^AUTO_MERGE=failed' &&
    ! grep -q '|pr-auto-merge|done|' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_repo_scoped_from_pr_created() {
  _setup
  echo '2026-10-01T00:00:00Z|META|pr-created|info|{"pr":12,"url":"https://github.com/acme/app/pull/12","repo":"acme/app"}' >>"$_ws/log"
  _am --integration-branch epic/thing
  local ok=1
  [ "$_rc" = 0 ] && grep -q '^pr view 12 --repo acme/app' "$_ws/gh.calls" &&
    grep -q '^pr merge 12 --repo acme/app' "$_ws/gh.calls" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_dry_run_never_merges() {
  _setup
  _am --dry-run
  local ok=1
  [ "$_rc" = 0 ] && ! _merged || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_usage_rc2() {
  local rc=0
  bash "$AM" CRE-2 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

# The router must delegate to the script — no inline `gh pr merge` left in the
# Auto-merge logic section of ticket-auto/SKILL.md.
test_router_delegates_to_script() {
  local section
  section=$(awk '/^### Auto-merge logic/{f=1;next} f&&/^### /{exit} f' "$PLUGIN_DIR/skills/ticket-auto/SKILL.md")
  echo "$section" | grep -q 'auto-merge.sh' && ! echo "$section" | grep -q 'gh pr merge "\$_pr_num"'
}

_run "happy path merges" test_happy_path_merges
_run "semi-auto merges" test_semi_auto_merges
_run "MERGE_POLICY=manual skips" test_merge_policy_manual_skips
_run "MERGE_POLICY=on-all-children-done skips" test_merge_policy_on_all_children_done_skips
_run "MERGE_POLICY from env file skips" test_merge_policy_from_env_file_skips
_run "manual autonomy never merges" test_manual_autonomy_never_merges
_run "unset autonomy never merges" test_unset_autonomy_never_merges
_run "complex skips" test_complex_skips
_run "Rough outcome skips" test_rough_outcome_skips
_run "no PR number skips" test_no_pr_number_skips
_run "integration PR guarded" test_integration_pr_guarded
_run "ticket PR targeting epic merges" test_ticket_pr_targeting_epic_still_merges
_run "gh pr view failure fails closed" test_gh_view_failure_fails_closed
_run "gh pr merge failure is soft rc 4" test_gh_merge_failure_is_soft_rc4
_run "repo scoped from META|pr-created" test_repo_scoped_from_pr_created
_run "dry-run never merges" test_dry_run_never_merges
_run "usage error rc 2" test_usage_rc2
_run "router delegates to auto-merge.sh" test_router_delegates_to_script

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
