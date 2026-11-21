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

# env-check asks before writing the log-dir anchor when stdin is a terminal;
# a test run must never block on that prompt.
exec </dev/null

# Speed + hermeticity. Validate mode walks the whole filesystem for a stale
# Docker jgit lock (seconds per call) and probes api.github.com with the PAT.
# Point the walk at an empty scratch dir and shim curl to fail fast, the way
# the probe behaves offline and in CI. No assertion reads either result except
# the jgit-lock tests below, which plant their own lock under the scratch root.
_TEST_SCRATCH=$(mktemp -d)
trap 'rm -rf "$_TEST_SCRATCH"' EXIT
export ENV_CHECK_JGIT_LOCK_ROOT="$_TEST_SCRATCH/lockroot"
mkdir -p "$ENV_CHECK_JGIT_LOCK_ROOT" "$_TEST_SCRATCH/bin"
printf '#!/bin/sh\nexit 7\n' >"$_TEST_SCRATCH/bin/curl"
chmod +x "$_TEST_SCRATCH/bin/curl"
export PATH="$_TEST_SCRATCH/bin:$PATH"
# The Linear label check calls the API whenever LINEAR_API_KEY is set; only the
# label tests below turn it on, each against its own fake curl.
export ENV_CHECK_SKIP_LINEAR=1
# The skill-shadow check reads ~/.claude/skills; point it at an empty dir so
# the developer's own skills never change a result.
export ENV_CHECK_USER_SKILLS_DIR="$_TEST_SCRATCH/userskills"
mkdir -p "$ENV_CHECK_USER_SKILLS_DIR"

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
  grep -q -e '---BEGIN_VARS---' <<<"$output" && grep -q -e '---END_VARS---' <<<"$output"
}

# GitHub #578 follow-up: full mode's VAR table is shown to the operator and
# lands in transcripts — a secret must appear masked, never in full.
test_full_mode_masks_secrets() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  output=$(LINEAR_API_KEY=lin_api_SECRETVALUE578abcd \
    GITHUB_PERSONAL_ACCESS_TOKEN=ghp_SECRETVALUE578wxyz \
    ANTHROPIC_AUTH_TOKEN=sk-SECRETVALUE578mnop \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  rm -rf "$tmpdir"
  ! grep -q 'SECRETVALUE578' <<<"$output" || return 1
  grep -q '^LINEAR_API_KEY|ok|\*\*\*\*abcd|' <<<"$output"
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
  grep -q 'REPOS_ROOT (/tmp/test-repos-backticked)' <<<"$output" &&
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
  grep -q 'LOCAL_URL (http://localhost:4000)' <<<"$output"
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
  grep -q '^REPOS_ROOT|ok|/tmp/test-repos-backticked|' <<<"$output" &&
    grep -q '^LOCAL_URL|ok|http://localhost:4000|' <<<"$output" &&
    grep -q '^UAT_URL|ok|http://uat.example.com|' <<<"$output"
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

_validate_output() {
  LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$1" 2>&1 || true
}

test_validate_warns_unwired_env_start() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  printf '#!/usr/bin/env bash\nAPP_DIR="$REPOS_ROOT/app"\n' >"$tmpdir/env-start.sh"
  output=$(_validate_output "$tmpdir")
  rm -rf "$tmpdir"
  echo "$output" | grep 'env-start.sh' | grep -q 'warn.*VERIFY_SERVED_WRONG_WORKTREE'
}

test_validate_passes_wired_env_start() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  printf '#!/usr/bin/env bash\nAPP_DIR="${VERIFY_REPO_PATH_APP:-$REPOS_ROOT/app}"\n' >"$tmpdir/env-start.sh"
  output=$(_validate_output "$tmpdir")
  rm -rf "$tmpdir"
  grep -q 'ok.*env-start.sh reads VERIFY_REPO_PATH_' <<<"$output"
}

# GitHub #772: a missing env-start.sh used to be silent here and surfaced only
# as verify-env-up.sh's exit 127 mid-run. A warning, never a failure.
test_validate_warns_missing_env_start() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  output=$(_validate_output "$tmpdir")
  rm -rf "$tmpdir"
  grep -q 'warn.*VERIFY_ENV_START.*env-start.sh not found' <<<"$output" &&
    ! grep -q 'MISS.*env-start' <<<"$output"
}

test_validate_verify_served_ports() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  echo 'VERIFY_SERVED_PORTS = 8080, http://localhost:9000' >>"$tmpdir/CLAUDE.md"
  output=$(_validate_output "$tmpdir")
  grep -q 'ok.*VERIFY_SERVED_PORTS (8080, http://localhost:9000)' <<<"$output" || {
    rm -rf "$tmpdir"
    return 1
  }
  _mk_project_dir "$tmpdir"
  echo 'VERIFY_SERVED_PORTS = 8080 nope' >>"$tmpdir/CLAUDE.md"
  output=$(_validate_output "$tmpdir")
  rm -rf "$tmpdir"
  echo "$output" | grep 'VERIFY_SERVED_PORTS' | grep -q 'warn.*nope'
}

test_validate_jgit_lock_none() {
  local tmpdir output
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  output=$(_validate_output "$tmpdir")
  rm -rf "$tmpdir"
  grep -q 'Docker jgit lock (none found)' <<<"$output"
}

test_validate_jgit_lock_stale_auto_cleaned() {
  local tmpdir output lock
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  lock="$tmpdir/cnb-local-registry/repo/jgit/config.lock"
  mkdir -p "$(dirname "$lock")"
  : >"$lock"
  touch -d '2 hours ago' "$lock"
  output=$(ENV_CHECK_JGIT_LOCK_ROOT="$tmpdir" _validate_output "$tmpdir")
  local gone=1
  [ -e "$lock" ] || gone=0
  rm -rf "$tmpdir"
  [ "$gone" -eq 0 ] && grep -q 'Docker jgit lock (stale, auto-cleaned)' <<<"$output"
}

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
  [ -f "$summary_file" ] && grep -q "Summary written to" <<<"$stdout_output" || ok=1
  rm -rf "$tmpdir"
  [ "$ok" -eq 0 ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

# ── Linear board labels ──────────────────────────────────────────────────────

# Fake curl answering the three Linear calls the label check makes. The team
# has needs-info (as "Needs-Info", to prove the case-insensitive match) and
# reviewed. Each created label name is appended to <dir>/mutations.
_mk_fake_linear() {
  local dir="$1"
  mkdir -p "$dir/bin"
  : >"$dir/mutations"
  {
    echo '#!/usr/bin/env bash'
    echo "MUT='$dir/mutations'"
    cat <<'CURL'
cat >/dev/null
payload=""
while [ $# -gt 0 ]; do
  [ "$1" = "-d" ] && payload="$2"
  shift
done
case "$payload" in
*issueLabelCreate*)
  name=$(printf '%s' "$payload" | jq -r '.variables.input.name')
  echo "$name" >>"$MUT"
  printf '{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"new-%s","name":"%s"}}}}\n200' "$name" "$name"
  ;;
*"teams("*)
  printf '{"data":{"teams":{"nodes":[{"id":"11111111-1111-1111-1111-111111111111","key":"SUN","name":"Sun"}]}}}\n200'
  ;;
*"team("*)
  printf '{"data":{"team":{"id":"t","name":"Sun","states":{"nodes":[]},"labels":{"nodes":[{"id":"L1","name":"Needs-Info","parent":null},{"id":"L4","name":"reviewed","parent":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}\n200'
  ;;
*) printf '{}\n500' ;;
esac
CURL
  } >"$dir/bin/curl"
  chmod +x "$dir/bin/curl"
}

_label_env_check() {
  local tmpdir="$1"
  shift
  PATH="$tmpdir/fake/bin:$PATH" ENV_CHECK_SKIP_LINEAR= LINEAR_RETRY_DELAYS="0 0 0" \
    LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" "$@" 2>/dev/null || true
}

test_full_mode_reports_missing_labels() {
  local tmpdir output rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _mk_fake_linear "$tmpdir/fake"
  output=$(_label_env_check "$tmpdir")
  {
    grep -q '^LINEAR_TEAM|ok|11111111-1111-1111-1111-111111111111|' <<<"$output" &&
      grep -q '^label:needs-info|ok|L1|' <<<"$output" &&
      grep -q '^label:reviewed|ok|L4|' <<<"$output" &&
      grep -q '^label:needs-adr|missing||' <<<"$output" &&
      grep -q '^label:rejected|missing||' <<<"$output" &&
      [ ! -s "$tmpdir/fake/mutations" ]
  } || rc=1
  rm -rf "$tmpdir"
  return $rc
}

test_full_mode_create_labels_creates_only_missing() {
  local tmpdir output rc=0 cache
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _mk_fake_linear "$tmpdir/fake"
  mkdir -p "$tmpdir/logs"
  cache="$tmpdir/logs/.linear-team-11111111-1111-1111-1111-111111111111.json"
  echo '{}' >"$cache"
  output=$(FLEET_PIPELINE_LOG_DIR="$tmpdir/logs" _label_env_check "$tmpdir" --create-labels)
  {
    grep -q '^label:needs-adr|ok|new-needs-adr|Linear|created by --create-labels' <<<"$output" &&
      grep -q '^label:rejected|ok|new-rejected|' <<<"$output" &&
      grep -q '^label:needs-info|ok|L1|' <<<"$output" &&
      [ "$(sort "$tmpdir/fake/mutations" | tr '\n' ' ')" = "needs-adr rejected " ] &&
      [ ! -e "$cache" ]
  } || rc=1
  rm -rf "$tmpdir"
  return $rc
}

test_full_mode_labels_skipped_without_key() {
  local tmpdir output rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _mk_fake_linear "$tmpdir/fake"
  output=$(
    unset LINEAR_API_KEY
    PATH="$tmpdir/fake/bin:$PATH" ENV_CHECK_SKIP_LINEAR= HOME="$tmpdir" GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" --create-labels 2>/dev/null || true
  )
  { ! grep -q '^label:\|^LINEAR_TEAM|' <<<"$output" && [ ! -s "$tmpdir/fake/mutations" ]; } || rc=1
  rm -rf "$tmpdir"
  return $rc
}

test_full_mode_labels_unknown_team_warns() {
  local tmpdir output rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _mk_fake_linear "$tmpdir/fake"
  output=$(LINEAR_TEAM_ID=NOPE _label_env_check "$tmpdir" --create-labels)
  {
    grep -q '^LINEAR_TEAM|warn|NOPE|' <<<"$output" &&
      ! grep -q '^label:' <<<"$output" &&
      [ ! -s "$tmpdir/fake/mutations" ]
  } || rc=1
  rm -rf "$tmpdir"
  return $rc
}

test_full_mode_labels_team_by_key() {
  local tmpdir output rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  _mk_fake_linear "$tmpdir/fake"
  output=$(LINEAR_TEAM_ID=sun _label_env_check "$tmpdir")
  grep -q '^LINEAR_TEAM|ok|11111111-1111-1111-1111-111111111111|settings.local.json|' <<<"$output" || rc=1
  rm -rf "$tmpdir"
  return $rc
}

# ── Skill shadowing and plugin-registered hooks ─────────────────────────────

test_full_mode_reports_shadowing_skill() {
  local tmpdir output rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  mkdir -p "$tmpdir/userskills/ticket-auto"
  printf -- '---\nname: ticket-auto\n---\nold\n' >"$tmpdir/userskills/ticket-auto/SKILL.md"
  output=$(ENV_CHECK_USER_SKILLS_DIR="$tmpdir/userskills" LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  grep -q "^SKILL_SHADOW:ticket-auto|missing|$tmpdir/userskills/ticket-auto/SKILL.md|" <<<"$output" || rc=1
  rm -rf "$tmpdir"
  return $rc
}

test_full_mode_shadow_ok_when_clean() {
  local tmpdir output rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  grep -q '^SKILL_SHADOW|ok|none|' <<<"$output" || rc=1
  rm -rf "$tmpdir"
  return $rc
}

test_validate_fails_on_shadowing_skill() {
  local tmpdir output rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  mkdir -p "$tmpdir/.claude/skills/ticket-verify"
  printf -- '---\nname: ticket-verify\n---\nold\n' >"$tmpdir/.claude/skills/ticket-verify/SKILL.md"
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir" 2>&1) && rc=1
  grep -q "SKILL.md shadows plugin skill 'ticket-verify'" <<<"$output" || rc=1
  rm -rf "$tmpdir"
  return $rc
}

test_hooks_ok_when_plugin_registers_them() {
  local tmpdir output rc=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  # No token-tracker hooks in any settings.json: the plugin's own plugin.json
  # registers them, so this is not a missing hook.
  echo '{"permissions":{"allow":[]}}' >"$tmpdir/.claude/settings.json"
  output=$(HOME="$tmpdir" LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  grep -q '^HOOKS_CONFIGURED|ok|SubagentStart + SubagentStop|plugin.json|registered by the plugin' <<<"$output" || rc=1
  rm -rf "$tmpdir"
  return $rc
}

# Issue #763: env-check names the tickets-root layout and says when it is
# the unsupported one (a tickets root inside another repo's work tree).
_layout_row() { # project-dir -> the TICKETS_LAYOUT row
  (LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" "$1" </dev/null 2>/dev/null || true) | grep '^TICKETS_LAYOUT|' || true
}

test_full_mode_reports_tickets_layout() {
  local d ok=1
  d=$(mktemp -d)
  mkdir -p "$d/plain" "$d/own" "$d/outer/tickets"
  _mk_project_dir "$d/plain"
  _mk_project_dir "$d/own"
  _mk_project_dir "$d/outer/tickets"
  git init -q "$d/own"
  git init -q "$d/outer"
  [[ "$(_layout_row "$d/plain")" == "TICKETS_LAYOUT|ok|plain directory|"*"|supported"* ]] || ok=0
  [[ "$(_layout_row "$d/own")" == "TICKETS_LAYOUT|ok|git repo|"*"|supported"* ]] || ok=0
  [[ "$(_layout_row "$d/outer/tickets")" == "TICKETS_LAYOUT|warn|inside another git repo|"*"|UNSUPPORTED"* ]] || ok=0
  rm -rf "$d"
  [ "$ok" -eq 1 ]
}

test_validate_reports_tickets_layout() {
  local d out rc=0 ok=1
  d=$(mktemp -d)
  mkdir -p "$d/outer/tickets"
  _mk_project_dir "$d/outer/tickets"
  git init -q "$d/outer"
  out=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$d/outer/tickets" 2>&1) || rc=$?
  # Reported, never a failure.
  [ "$rc" -eq 0 ] && grep -q 'tickets root: inside another git repo.*UNSUPPORTED' <<<"$out" || ok=0
  rm -rf "$d/outer/.git"
  out=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$d/outer/tickets" 2>&1) || true
  grep -q 'tickets root: plain directory' <<<"$out" || ok=0
  rm -rf "$d"
  [ "$ok" -eq 1 ]
}

for fn in \
  test_validate_passes_all_required \
  test_validate_fails_missing_linear_key \
  test_validate_fails_missing_github_token \
  test_validate_warns_missing_optional \
  test_full_mode_emits_begin_end_sentinels \
  test_full_mode_rowcount_matches_var_lines \
  test_full_mode_masks_secrets \
  test_full_mode_gh_token_derived \
  test_full_mode_local_url_env_priority \
  test_full_mode_linear_key_in_dotenv \
  test_full_mode_ticket_autonomy_warn \
  test_validate_reads_backticked_repos_root \
  test_validate_reads_backticked_local_url \
  test_validate_passes_backticked_project \
  test_full_mode_reads_backticked_fields \
  test_claude_md_field_grammar \
  test_validate_warns_unwired_env_start \
  test_validate_passes_wired_env_start \
  test_validate_warns_missing_env_start \
  test_validate_verify_served_ports \
  test_validate_jgit_lock_none \
  test_validate_jgit_lock_stale_auto_cleaned \
  test_unknown_mode_exits_1 \
  test_summary_file_flag_writes_to_path \
  test_full_mode_reports_missing_labels \
  test_full_mode_create_labels_creates_only_missing \
  test_full_mode_labels_skipped_without_key \
  test_full_mode_labels_unknown_team_warns \
  test_full_mode_labels_team_by_key \
  test_full_mode_reports_shadowing_skill \
  test_full_mode_shadow_ok_when_clean \
  test_validate_fails_on_shadowing_skill \
  test_hooks_ok_when_plugin_registers_them \
  test_full_mode_reports_tickets_layout \
  test_validate_reports_tickets_layout; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
