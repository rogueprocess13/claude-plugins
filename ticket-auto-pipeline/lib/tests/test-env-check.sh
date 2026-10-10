#!/usr/bin/env bash
# test-env-check.sh — unit tests for lib/env-check.sh
# Targets env-check.sh directly (validate-env.sh is just a thin wrapper).
# Usage: bash test-env-check.sh [test_name_filter]
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
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# Create a minimal valid project dir with CLAUDE.md and settings.json
_mk_project_dir() {
  local dir="$1"
  mkdir -p "$dir/.claude"
  cat >"$dir/CLAUDE.md" <<'EOF'
REPOS_ROOT=/tmp/test-repos
LOCAL_URL=http://localhost:3000
UAT_URL=http://uat.example.com
EOF
  cat >"$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SubagentStart": [{"hooks": [{"command": "token-tracker-start.sh"}]}],
    "SubagentStop":  [{"hooks": [{"command": "token-tracker.sh"}]}]
  },
  "permissions": {
    "allow": [
      "Bash(source /home/user/.claude/skills/lib/spawn-helper.sh *)",
      "Bash(source /home/user/.claude/skills/lib/heartbeat.sh *)",
      "Write(/tmp/test-repos/logs/**)"
    ]
  }
}
EOF
}

# ── validate mode tests ───────────────────────────────────────────────────────

test_validate_passes_all_required() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local exit_code=0
  (LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir") >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 0 ]
}

test_validate_fails_missing_linear_key() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local exit_code=0
  (
    unset LINEAR_API_KEY
    GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir"
  ) >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -ne 0 ]
}

test_validate_fails_missing_github_token() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local exit_code=0
  (
    unset GITHUB_PERSONAL_ACCESS_TOKEN
    LINEAR_API_KEY=test \
      bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir"
  ) >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -ne 0 ]
}

test_validate_warns_missing_optional() {
  # SLACK_CHANNEL absent — should warn but still exit 0
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  # No SLACK_CHANNEL in CLAUDE.md (default _mk_project_dir doesn't add it)
  local exit_code=0
  (LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir") >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 0 ]
}

# ── full mode tests ───────────────────────────────────────────────────────────

test_full_mode_emits_begin_end_sentinels() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  rm -rf "$tmpdir"
  echo "$output" | grep -q -e '---BEGIN_VARS---' && echo "$output" | grep -q -e '---END_VARS---'
}

test_full_mode_rowcount_matches_var_lines() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  rm -rf "$tmpdir"

  local rowcount
  rowcount=$(echo "$output" | grep '^ROWCOUNT=' | sed 's/ROWCOUNT=//')
  local var_count
  var_count=$(echo "$output" |
    awk '/---BEGIN_VARS---/{p=1;next}/---END_VARS---/{p=0}p' |
    grep -v '^NAME|' |
    grep -v '^ROWCOUNT=' |
    grep -c '|' || true)

  [ -n "$rowcount" ] && [ "$rowcount" -eq "$var_count" ]
}

test_full_mode_gh_token_derived() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(
    unset GH_TOKEN 2>/dev/null || true
    LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true
  )
  rm -rf "$tmpdir"
  echo "$output" | grep 'GH_TOKEN' | grep -q 'auto'
}

test_full_mode_local_url_env_priority() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test LOCAL_URL=http://env-priority.test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  rm -rf "$tmpdir"
  echo "$output" | grep 'LOCAL_URL' | grep -q 'http://env-priority.test'
}

test_full_mode_linear_key_in_dotenv() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  echo 'LINEAR_API_KEY=my-dotenv-key' >"$tmpdir/.env"
  local output
  output=$(
    unset LINEAR_API_KEY
    GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true
  )
  rm -rf "$tmpdir"
  echo "$output" | grep 'LINEAR_API_KEY' | grep -q 'auto|(in .env)|.env|key found in project .env'
}

test_full_mode_ticket_autonomy_warn() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(
    unset TICKET_AUTONOMY 2>/dev/null || true
    LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true
  )
  rm -rf "$tmpdir"
  echo "$output" | grep 'TICKET_AUTONOMY' | grep -q 'warn'
}

# ── backticked CLAUDE.md fields (#417) ───────────────────────────────────────
# A project CLAUDE.md documents its fields as `KEY` = value. Validate mode used
# to anchor on a bare ^REPOS_ROOT and report a false MISS for that form, while
# report mode (and the runtime preamble) read it fine. Every mode must agree.

_mk_backticked_project_dir() {
  local dir="$1"
  _mk_project_dir "$dir"
  cat >"$dir/CLAUDE.md" <<'EOF'
`REPOS_ROOT` = /tmp/test-repos-backticked
`LOCAL_URL` = `http://localhost:4000`
`UAT_URL`: http://uat.example.com
`BE_TEST_CMD` = mvn -q test
EOF
}

test_validate_reads_backticked_repos_root() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_backticked_project_dir "$tmpdir"
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir" 2>&1 || true)
  rm -rf "$tmpdir"
  echo "$output" | grep -q 'REPOS_ROOT (/tmp/test-repos-backticked)' &&
    ! echo "$output" | grep 'REPOS_ROOT' | grep -q 'MISS'
}

test_validate_reads_backticked_local_url() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_backticked_project_dir "$tmpdir"
  output=$(
    unset LOCAL_URL
    LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir" 2>&1 || true
  )
  rm -rf "$tmpdir"
  echo "$output" | grep -q 'LOCAL_URL (http://localhost:4000)'
}

test_validate_passes_backticked_project() {
  local tmpdir exit_code=0
  tmpdir=$(mktemp -d)
  _mk_backticked_project_dir "$tmpdir"
  (
    unset LOCAL_URL UAT_URL
    LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir"
  ) >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 0 ]
}

test_full_mode_reads_backticked_fields() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_backticked_project_dir "$tmpdir"
  output=$(
    unset LOCAL_URL UAT_URL
    LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true
  )
  rm -rf "$tmpdir"
  echo "$output" | grep -q '^REPOS_ROOT|ok|/tmp/test-repos-backticked|' &&
    echo "$output" | grep -q '^LOCAL_URL|ok|http://localhost:4000|' &&
    echo "$output" | grep -q '^UAT_URL|ok|http://uat.example.com|'
}

# The shared reader the preamble (runtime) and env-check (diagnostic) both
# call: backticks on either side, values with spaces, absent key -> rc 1.
test_claude_md_field_grammar() {
  local tmpdir rc=0 got
  tmpdir=$(mktemp -d)
  _mk_backticked_project_dir "$tmpdir"
  got=$(
    source "$LIB_DIR/claude-md-field.sh"
    printf '%s|' "$(claude_md_field "$tmpdir/CLAUDE.md" REPOS_ROOT)" \
      "$(claude_md_field "$tmpdir/CLAUDE.md" LOCAL_URL)" \
      "$(claude_md_field "$tmpdir/CLAUDE.md" UAT_URL)" \
      "$(claude_md_field "$tmpdir/CLAUDE.md" BE_TEST_CMD)"
    claude_md_field "$tmpdir/CLAUDE.md" NOT_DECLARED >/dev/null && exit 9
    exit 0
  ) || rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] &&
    [ "$got" = "/tmp/test-repos-backticked|http://localhost:4000|http://uat.example.com|mvn -q test|" ]
}

# ── argument parsing edge cases ───────────────────────────────────────────────

test_unknown_mode_exits_1() {
  local exit_code=0
  bash "$LIB_DIR/env-check.sh" --mode=garbage >/dev/null 2>&1 || exit_code=$?
  # Migration to error-handler.sh: E_ENV=12
  [ "$exit_code" -eq 12 ]
}

test_summary_file_flag_writes_to_path() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local summary_file="$tmpdir/summary.txt"
  local stdout_output
  stdout_output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full --summary-file="$summary_file" "$tmpdir" 2>/dev/null || true)
  local ok=0
  [ -f "$summary_file" ] && echo "$stdout_output" | grep -q "Summary written to" || ok=1
  rm -rf "$tmpdir"
  [ "$ok" -eq 0 ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_validate_passes_all_required \
  test_validate_fails_missing_linear_key \
  test_validate_fails_missing_github_token \
  test_validate_warns_missing_optional \
  test_full_mode_emits_begin_end_sentinels \
  test_full_mode_rowcount_matches_var_lines \
  test_full_mode_gh_token_derived \
  test_full_mode_local_url_env_priority \
  test_full_mode_linear_key_in_dotenv \
  test_full_mode_ticket_autonomy_warn \
  test_validate_reads_backticked_repos_root \
  test_validate_reads_backticked_local_url \
  test_validate_passes_backticked_project \
  test_full_mode_reads_backticked_fields \
  test_claude_md_field_grammar \
  test_unknown_mode_exits_1 \
  test_summary_file_flag_writes_to_path; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
