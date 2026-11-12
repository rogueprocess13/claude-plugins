#!/usr/bin/env bash
# test-fleet-env-check.sh — unit tests for lib/fleet-env-check.sh
# Usage: bash test-fleet-env-check.sh [test_name_filter]
# -u (nounset) intentionally omitted — see ticket-auto-pipeline's
# test-env-check.sh for the harness shell-snapshot rationale.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

_mk_project_dir() {
  local dir="$1"
  mkdir -p "$dir/child-a/.git" "$dir/child-b/.git"
  cat >"$dir/CLAUDE.md" <<EOF
REPOS_ROOT=$dir
EOF
}

_env_vars() {
  bash "$LIB_DIR/fleet-env-check.sh" "$@" 2>/dev/null
}

_row() {
  # _row OUTPUT NAME — prints the pipe-delimited row for NAME
  echo "$1" | grep "^$2|"
}

# ── LINEAR_API_KEY ────────────────────────────────────────────────────────────

test_linear_key_present_masks_value() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=abcd1234EFGH _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  local row
  row=$(_row "$out" "LINEAR_API_KEY")
  [[ "$row" == "LINEAR_API_KEY|ok|"*"|"* ]] && [[ "$row" == *"****EFGH"* ]] && [[ "$row" != *"abcd1234EFGH"* ]]
}

test_linear_key_missing_is_issue() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset LINEAR_API_KEY
    bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null
  ) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "LINEAR_API_KEY")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

# ── GITHUB_PERSONAL_ACCESS_TOKEN (conditional on FLEET_EPIC_AUTO_PR) ─────────

test_github_token_optional_when_auto_pr_off() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset GITHUB_PERSONAL_ACCESS_TOKEN
    LINEAR_API_KEY=x FLEET_EPIC_AUTO_PR=false bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null
  ) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "GITHUB_PERSONAL_ACCESS_TOKEN")" == *"|warn|"* ]]
}

test_github_token_required_when_auto_pr_on() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset GITHUB_PERSONAL_ACCESS_TOKEN
    LINEAR_API_KEY=x FLEET_EPIC_AUTO_PR=true bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null
  ) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "GITHUB_PERSONAL_ACCESS_TOKEN")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

test_github_token_masks_value() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x GITHUB_PERSONAL_ACCESS_TOKEN=ghp_wxyz9999 _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "GITHUB_PERSONAL_ACCESS_TOKEN")" == *"****9999"* ]] && [[ "$out" != *"ghp_wxyz9999"* ]]
}

test_slack_bot_token_warn_when_absent() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "SLACK_BOT_TOKEN")" == *"|warn|"* ]]
}

test_slack_bot_token_masks_value() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x SLACK_BOT_TOKEN=xoxb-1234-abcd9999 _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "SLACK_BOT_TOKEN")" == *"****9999"* ]] && [[ "$out" != *"xoxb-1234-abcd9999"* ]]
}

# ── REPOS_ROOT ────────────────────────────────────────────────────────────────

test_repos_root_ok_when_declared() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "REPOS_ROOT")" == "REPOS_ROOT|ok|$tmpdir|"* ]]
}

test_repos_root_missing_when_no_claude_md() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  out=$(LINEAR_API_KEY=x bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE.md")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

test_repos_root_auto_derived_does_not_count_as_issue() {
  # CLAUDE.md present but without a REPOS_ROOT field, and >=2 child repos to
  # derive from — REPOS_ROOT should come back "auto" (successfully derived,
  # nothing broken) and must NOT contribute to the exit-code issue count.
  # Regression for a bug where the issues++ sat outside the auto/missing
  # if/else and fired on both branches.
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/child-a/.git" "$tmpdir/child-b/.git"
  echo "# no REPOS_ROOT declared here" >"$tmpdir/CLAUDE.md"
  out=$(LINEAR_API_KEY=x CLAUDE_CMD="bash --dangerously-skip-permissions" bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "REPOS_ROOT")" == *"|auto|"* ]] && [ "$exit_code" -eq 0 ]
}

# ── CLAUDE_BIN / CLAUDE_CMD ───────────────────────────────────────────────────

test_claude_bin_default_ok_when_resolvable() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset CLAUDE_CMD CLAUDE_BIN
    LINEAR_API_KEY=x bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null | sed -n '/CLAUDE_BIN|/p'
  ) || true
  rm -rf "$tmpdir"
  # 'claude' won't be on PATH in CI — accept either ok or missing, just confirm the row exists.
  [[ -n "$out" ]]
}

test_claude_cmd_overrides_and_resolves() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CMD="bash 2 --bypass" _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CMD")" == "CLAUDE_CMD|ok|bash 2 --bypass|"* ]]
}

test_claude_cmd_missing_binary_is_issue() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CMD="totally-not-a-real-binary --flag" bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CMD")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

# ── CLI tools ─────────────────────────────────────────────────────────────────

test_jq_ok_when_present() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "jq")" == *"|ok|"* ]]
}

test_gh_required_only_when_auto_pr_on() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x FLEET_EPIC_AUTO_PR=true _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "gh")" == *"required — FLEET_EPIC_AUTO_PR=true"* ]]
}

# ── Output contract ───────────────────────────────────────────────────────────

test_rowcount_matches_emitted_rows() {
  local tmpdir out declared actual
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  declared=$(echo "$out" | grep -oP 'ROWCOUNT=\K[0-9]+')
  actual=$(echo "$out" | sed -n '/^---BEGIN_VARS---$/,/^---END_VARS---$/p' | grep -c '|')
  # actual includes the header row (ROWCOUNT= has no '|' so it isn't counted); subtract 1.
  actual=$((actual - 1))
  [ "$declared" -eq "$actual" ]
}

test_summary_file_written() {
  local tmpdir summary
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  summary="$tmpdir/summary.txt"
  LINEAR_API_KEY=x bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" --summary-file "$summary" >/dev/null 2>&1 || true
  local ok=1
  [ -f "$summary" ] && grep -q '^---BEGIN_VARS---$' "$summary" && ok=0
  rm -rf "$tmpdir"
  [ "$ok" -eq 0 ]
}

# ── Worker permission mode (worker-reap-recovery, task 2.7) ─────────────────

test_permission_mode_auto_when_not_configured_and_not_an_issue() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset CLAUDE_CMD
    # CLAUDE_BIN pinned to a binary guaranteed resolvable in CI (unlike the
    # real 'claude' binary) so this test's exit-code assertion isolates the
    # permission-mode default and isn't entangled with that unrelated row.
    LINEAR_API_KEY=x CLAUDE_BIN=bash bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null
  ) || exit_code=$?
  rm -rf "$tmpdir"
  # fleetd's own documented zero-config default (bypassPermissions) must
  # never be the reason fleetd's startup env-check gate refuses to boot.
  [[ "$(_row "$out" "FLEET_WORKER_PERMISSION_MODE")" == *"|auto|"* ]] && [ "$exit_code" -eq 0 ]
}

test_permission_mode_ok_when_claude_cmd_specifies_one() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CMD="bash --dangerously-skip-permissions" _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEET_WORKER_PERMISSION_MODE")" == *"|ok|"* ]]
}

test_not_root_ok_for_normal_user() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEETD_NOT_ROOT")" == *"|ok|"* ]]
}

test_claude_code_simple_ok_when_unset() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset CLAUDE_CODE_SIMPLE
    LINEAR_API_KEY=x _env_vars "$tmpdir"
  )
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CODE_SIMPLE")" == *"|ok|"* ]]
}

test_claude_code_simple_missing_when_bare_active() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CODE_SIMPLE=1 bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CODE_SIMPLE")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

test_restricted_missing_when_active() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CODE_RESTRICTED=true bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CODE_RESTRICTED")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

test_permission_probe_skipped_by_default() {
  # The live probe must never run unless explicitly opted in — it would
  # otherwise execute CLAUDE_CMD's real argv on every env-check invocation,
  # including inside make test where CLAUDE_CMD is often a test stub.
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset FLEET_ENV_CHECK_LIVE_PROBE
    LINEAR_API_KEY=x CLAUDE_CMD="bash 2 --bypass" _env_vars "$tmpdir"
  )
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEET_WORKER_PERMISSION_PROBE")" == *"|info|"* ]]
}

# ── Worker autonomy (FLEET_WORKER_AUTONOMY, review finding PO-9) ────────────

_autonomy_env_check() {
  # _autonomy_env_check TMPDIR [VALUE] — runs env-check with every other row
  # pinned to a passing value, so the exit code isolates the autonomy row.
  local dir="$1"
  if [ "$#" -ge 2 ]; then
    LINEAR_API_KEY=x CLAUDE_BIN=bash FLEET_WORKER_AUTONOMY="$2" bash "$LIB_DIR/fleet-env-check.sh" "$dir" 2>/dev/null
  else
    (
      unset FLEET_WORKER_AUTONOMY
      LINEAR_API_KEY=x CLAUDE_BIN=bash bash "$LIB_DIR/fleet-env-check.sh" "$dir" 2>/dev/null
    )
  fi
}

test_worker_autonomy_default_is_auto_and_not_an_issue() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(unset CLAUDE_CMD && _autonomy_env_check "$tmpdir") || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEET_WORKER_AUTONOMY")" == "FLEET_WORKER_AUTONOMY|info|auto|"* ]] && [ "$exit_code" -eq 0 ]
}

test_worker_autonomy_valid_values_ok() {
  local tmpdir out v rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  for v in auto semi-auto manual; do
    out=$(unset CLAUDE_CMD && _autonomy_env_check "$tmpdir" "$v") || rc=1
    [[ "$(_row "$out" "FLEET_WORKER_AUTONOMY")" == "FLEET_WORKER_AUTONOMY|ok|$v|"* ]] || rc=1
  done
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ]
}

test_worker_autonomy_invalid_value_refuses() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(unset CLAUDE_CMD && _autonomy_env_check "$tmpdir" "--auto") || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEET_WORKER_AUTONOMY")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

# ── Log-dir anchor (state-root-anchor, PR B) ─────────────────────────────────
# fleetd passes its own log dir as FLEET_ENV_CHECK_LOG_DIR; the check compares
# it with $REPOS_ROOT/.ticket-auto/log-dir (realpath both sides). A mismatch is
# the two-roots bug and must fail fleetd's boot gate (any nonzero exit).

_anchor() {
  # _anchor REPOS_ROOT VALUE
  mkdir -p "$1/.ticket-auto"
  printf '%s\n' "$2" >"$1/.ticket-auto/log-dir"
}

# _anchor_rc PROJECT ENV... — run the check with a clean log-dir env, print rc.
_anchor_rc() {
  local dir="$1" rc=0
  shift
  env -u REPOS_ROOT -u FLEET_PIPELINE_LOG_DIR -u FLEET_STATE_DIR -u FLEET_ENV_CHECK_LOG_DIR \
    "$@" bash "$LIB_DIR/fleet-env-check.sh" "$dir" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

_anchor_out() {
  local dir="$1"
  shift
  env -u REPOS_ROOT -u FLEET_PIPELINE_LOG_DIR -u FLEET_STATE_DIR -u FLEET_ENV_CHECK_LOG_DIR \
    "$@" bash "$LIB_DIR/fleet-env-check.sh" "$dir" 2>/dev/null || true
}

test_log_dir_anchor_absent_passes() {
  local tmpdir out row rc_base rc
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(_anchor_out "$tmpdir" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/logs")
  rc=$(_anchor_rc "$tmpdir" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/logs")
  rc_base=$(_anchor_rc "$tmpdir")
  row=$(_row "$out" "LOG_DIR_ANCHOR")
  rm -rf "$tmpdir"
  [[ "$row" == "LOG_DIR_ANCHOR|info|"* ]] && [ "$rc" = "$rc_base" ]
}

test_log_dir_anchor_equal_passes() {
  local tmpdir out row rc_mis rc_eq
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  mkdir -p "$tmpdir/logs"
  ln -s "$tmpdir/logs" "$tmpdir/logs-link"
  _anchor "$tmpdir" "$tmpdir/logs-link"
  out=$(_anchor_out "$tmpdir" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/logs")
  rc_eq=$(_anchor_rc "$tmpdir" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/logs")
  rc_mis=$(_anchor_rc "$tmpdir" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/other")
  row=$(_row "$out" "LOG_DIR_ANCHOR")
  rm -rf "$tmpdir"
  [[ "$row" == "LOG_DIR_ANCHOR|ok|"* ]] && [ "$rc_mis" -eq $((rc_eq + 1)) ]
}

test_log_dir_anchor_mismatch_fails() {
  local tmpdir out row rc
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _anchor "$tmpdir" "$tmpdir/router/logs"
  out=$(_anchor_out "$tmpdir" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/fleetd/logs")
  rc=$(_anchor_rc "$tmpdir" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/fleetd/logs")
  row=$(_row "$out" "LOG_DIR_ANCHOR")
  rm -rf "$tmpdir"
  [[ "$row" == "LOG_DIR_ANCHOR|fail|$tmpdir/router/logs|"* ]] &&
    [[ "$row" == *"log-dir-anchor-mismatch"* ]] &&
    [[ "$row" == *"$tmpdir/fleetd/logs"* ]] && [ "$rc" -ne 0 ]
}

test_log_dir_anchor_flag_and_state_dir_sources() {
  local tmpdir row1 row2 row3
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _anchor "$tmpdir" "$tmpdir/a/logs"
  row1=$(_row "$(_anchor_out "$tmpdir" FLEET_STATE_DIR="$tmpdir/b")" "LOG_DIR_ANCHOR")
  row2=$(_row "$(env -u REPOS_ROOT -u FLEET_PIPELINE_LOG_DIR -u FLEET_STATE_DIR -u FLEET_ENV_CHECK_LOG_DIR \
    bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" --log-dir "$tmpdir/a/logs" 2>/dev/null || true)" "LOG_DIR_ANCHOR")
  row3=$(_row "$(_anchor_out "$tmpdir" FLEET_PIPELINE_LOG_DIR="$tmpdir/a/logs" FLEET_STATE_DIR="$tmpdir/b")" "LOG_DIR_ANCHOR")
  rm -rf "$tmpdir"
  [[ "$row1" == "LOG_DIR_ANCHOR|fail|"* ]] && [[ "$row2" == "LOG_DIR_ANCHOR|ok|"* ]] &&
    [[ "$row3" == "LOG_DIR_ANCHOR|ok|"* ]]
}

test_log_dir_anchor_unknown_fleetd_dir_is_info() {
  local tmpdir row rc rc_base
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _anchor "$tmpdir" "$tmpdir/a/logs"
  row=$(_row "$(_anchor_out "$tmpdir")" "LOG_DIR_ANCHOR")
  rc=$(_anchor_rc "$tmpdir")
  rc_base=$(_anchor_rc "$tmpdir" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/a/logs")
  rm -rf "$tmpdir"
  [[ "$row" == "LOG_DIR_ANCHOR|info|$tmpdir/a/logs|"* ]] && [ "$rc" = "$rc_base" ]
}

test_log_dir_anchor_env_repos_root_wins() {
  local tmpdir other row
  tmpdir=$(mktemp -d)
  other=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _anchor "$tmpdir" "$tmpdir/x/logs"
  _anchor "$other" "$tmpdir/y/logs"
  row=$(_row "$(_anchor_out "$tmpdir" REPOS_ROOT="$other" FLEET_ENV_CHECK_LOG_DIR="$tmpdir/y/logs")" "LOG_DIR_ANCHOR")
  rm -rf "$tmpdir" "$other"
  [[ "$row" == "LOG_DIR_ANCHOR|ok|"* ]]
}

# The tickets host: fleetd's cwd and FLEETD_WORKSPACE = the workspace,
# --state-dir <workspace>/logs, REPOS_ROOT exported, FLEET_PIPELINE_LOG_DIR
# unset; the router preamble anchored <workspace>/logs.
test_log_dir_anchor_tickets_host_layout_passes() {
  local root ws row
  root=$(mktemp -d)
  ws="$root/tickets"
  mkdir -p "$ws/logs"
  _mk_project_dir "$ws"
  _anchor "$root" "$ws/logs"
  row=$(_row "$(cd "$ws" && _anchor_out "$ws" REPOS_ROOT="$root" FLEETD_WORKSPACE="$ws" \
    FLEET_ENV_CHECK_LOG_DIR="$ws/logs")" "LOG_DIR_ANCHOR")
  rm -rf "$root"
  [[ "$row" == "LOG_DIR_ANCHOR|ok|$ws/logs|"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Runner
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"
for fn in \
  test_linear_key_present_masks_value \
  test_linear_key_missing_is_issue \
  test_github_token_optional_when_auto_pr_off \
  test_github_token_required_when_auto_pr_on \
  test_github_token_masks_value \
  test_slack_bot_token_warn_when_absent \
  test_slack_bot_token_masks_value \
  test_repos_root_ok_when_declared \
  test_repos_root_missing_when_no_claude_md \
  test_repos_root_auto_derived_does_not_count_as_issue \
  test_claude_bin_default_ok_when_resolvable \
  test_claude_cmd_overrides_and_resolves \
  test_claude_cmd_missing_binary_is_issue \
  test_jq_ok_when_present \
  test_gh_required_only_when_auto_pr_on \
  test_rowcount_matches_emitted_rows \
  test_summary_file_written \
  test_permission_mode_auto_when_not_configured_and_not_an_issue \
  test_permission_mode_ok_when_claude_cmd_specifies_one \
  test_not_root_ok_for_normal_user \
  test_claude_code_simple_ok_when_unset \
  test_claude_code_simple_missing_when_bare_active \
  test_restricted_missing_when_active \
  test_permission_probe_skipped_by_default \
  test_worker_autonomy_default_is_auto_and_not_an_issue \
  test_worker_autonomy_valid_values_ok \
  test_worker_autonomy_invalid_value_refuses \
  test_log_dir_anchor_absent_passes \
  test_log_dir_anchor_equal_passes \
  test_log_dir_anchor_mismatch_fails \
  test_log_dir_anchor_flag_and_state_dir_sources \
  test_log_dir_anchor_unknown_fleetd_dir_is_info \
  test_log_dir_anchor_env_repos_root_wins \
  test_log_dir_anchor_tickets_host_layout_passes; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
