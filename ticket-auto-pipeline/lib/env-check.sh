#!/usr/bin/env bash
# ticket-env-check — validates env vars and config required by ticket-auto-pipeline.
#
# Output: pipe-delimited rows between ---BEGIN_VARS--- / ---END_VARS---
# Format: NAME|STATUS|VALUE|LOCATION|NOTE
#   STATUS  ok=present  missing=required+absent  auto=derivable  warn=optional+absent
#   LOCATION  settings.local.json | CLAUDE.md | either
#
# Usage: env-check.sh [PROJECT_DIR] [--mode full|validate] [--summary-file PATH] [--show]
#   --mode full|validate  Output mode: full=pipe-delimited (default), validate=colored pass/fail
#   --summary-file PATH   Write delimited block to PATH; print only "Written to PATH"
#   --show                Also print a human-readable table to stdout
#   --anchor-log-dir PATH Write the log-dir anchor ($REPOS_ROOT/.ticket-auto/log-dir,
#                         state-root-anchor) with PATH's absolute form, print
#                         "LOG_DIR_ANCHOR: <value now anchored>" and exit: 0 when
#                         the anchor holds PATH, 1 when it already names another
#                         dir (never replaced), 2 when REPOS_ROOT is unknown.
#   --create-labels       Create any board-projected Linear label (needs-info,
#                         needs-adr, rejected, reviewed) the team lacks.
# Full mode checks those labels whenever LINEAR_API_KEY is loaded (rows
# LINEAR_TEAM and label:<name>; ENV_CHECK_SKIP_LINEAR=1 skips the check).
# Full mode reports the anchor as the LOG_DIR_ANCHOR row; when it is absent and
# stdin is a terminal (or ENV_CHECK_INTERACTIVE=1) it asks before anchoring
# PROJECT_DIR/logs.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/error-handler.sh" ] && source "$SCRIPT_DIR/error-handler.sh"
# resolve_uat_url lives in linear-api.sh (function definitions only — safe to
# source here). Both UAT_URL sites below delegate to it so there is one
# resolution order, not three.
[ -f "$SCRIPT_DIR/linear-api.sh" ] && source "$SCRIPT_DIR/linear-api.sh"
# claude_md_field — the single CLAUDE.md field grammar shared with
# resolve_uat_url and ticket-preamble.sh. Every CLAUDE.md read below goes
# through it, so validate mode and report mode cannot drift apart (#417).
source "$SCRIPT_DIR/claude-md-field.sh"

SUMMARY_FILE=""
SHOW=""
PROJECT_DIR=""
_MODE="full"
_EXPECTING_SUMMARY_PATH=false
ANCHOR_PATH=""
CREATE_LABELS=false
_ANCHOR_FLAG=false
_EXPECTING_ANCHOR_PATH=false
for arg in "${@}"; do
  if $_EXPECTING_ANCHOR_PATH; then
    ANCHOR_PATH="$arg"
    _EXPECTING_ANCHOR_PATH=false
    continue
  fi
  if $_EXPECTING_SUMMARY_PATH; then
    if [[ "$arg" == --* ]]; then
      echo "env-check: --summary-file requires a path argument (got flag: $arg)" >&2
      error_exit 12 "env-check: required configuration missing"
    fi
    SUMMARY_FILE="$arg"
    _EXPECTING_SUMMARY_PATH=false
    continue
  fi
  case "$arg" in
  --mode) _MODE="" ;;
  --mode=*) _MODE="${arg#*=}" ;;
  --summary-file) _EXPECTING_SUMMARY_PATH=true ;;
  --summary-file=*) SUMMARY_FILE="${arg#*=}" ;;
  --show) SHOW="1" ;;
  --create-labels) CREATE_LABELS=true ;;
  --anchor-log-dir)
    _ANCHOR_FLAG=true
    _EXPECTING_ANCHOR_PATH=true
    ;;
  --anchor-log-dir=*)
    _ANCHOR_FLAG=true
    ANCHOR_PATH="${arg#*=}"
    ;;
  *)
    if [ "$_MODE" = "" ]; then
      _MODE="$arg"
    elif [ -z "$PROJECT_DIR" ]; then
      PROJECT_DIR="$arg"
    else
      echo "env-check: unexpected argument: $arg" >&2
      error_exit 12 "env-check: required configuration missing"
    fi
    ;;
  esac
done

if $_EXPECTING_SUMMARY_PATH; then
  echo "env-check: --summary-file requires a path argument" >&2
  error_exit 12 "env-check: required configuration missing"
fi
if $_ANCHOR_FLAG && [ -z "$ANCHOR_PATH" ]; then
  echo "env-check: --anchor-log-dir requires a path argument" >&2
  exit 2
fi
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"

source "$SCRIPT_DIR/log-dir.sh"
# skill_shadow_list / _skill_shadow_default_root: user-level SKILL.md files that
# shadow this plugin's skills (SKILL_SHADOW row).
source "$SCRIPT_DIR/skill-shadow.sh"
_EC_PLUGIN_ROOT=$(_skill_shadow_default_root 2>/dev/null || true)

# The plugin registers the token-tracker hooks itself (plugin.json SubagentStart
# and SubagentStop), so an installed plugin needs no settings.json entry. Only
# a host without the plugin manifest falls back to the settings.json check.
_EC_PLUGIN_HOOKS=false
if [ -n "$_EC_PLUGIN_ROOT" ] && [ -f "$_EC_PLUGIN_ROOT/.claude-plugin/plugin.json" ] &&
  jq -e '(.hooks.SubagentStart // [] | [.[].hooks[]?.command | select(test("token-tracker-start"))] | length > 0)
     and (.hooks.SubagentStop // [] | [.[].hooks[]?.command | select(test("token-tracker\\.sh"))] | length > 0)' \
    "$_EC_PLUGIN_ROOT/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  _EC_PLUGIN_HOOKS=true
fi

# Prints "name|path" per shadowing SKILL.md, user level then project level.
_ec_skill_shadows() {
  [ -n "$_EC_PLUGIN_ROOT" ] || return 0
  local d
  for d in "${ENV_CHECK_USER_SKILLS_DIR:-$HOME/.claude/skills}" "$PROJECT_DIR/.claude/skills"; do
    skill_shadow_list "$_EC_PLUGIN_ROOT" "$d" 2>/dev/null | tr '\t' '|'
  done
}

# REPOS_ROOT for the anchor: env first, then the project's CLAUDE.md (the same
# order ticket-preamble.sh uses).
_env_check_repos_root() {
  if [ -n "${REPOS_ROOT:-}" ]; then
    printf '%s\n' "$REPOS_ROOT"
    return 0
  fi
  claude_md_field "$PROJECT_DIR/CLAUDE.md" REPOS_ROOT 2>/dev/null || true
}

if [ -n "$ANCHOR_PATH" ]; then
  _rr=$(_env_check_repos_root)
  if [ -z "$_rr" ]; then
    echo "env-check: --anchor-log-dir needs REPOS_ROOT (env or CLAUDE.md in ${PROJECT_DIR})" >&2
    exit 2
  fi
  _want=$(realpath -m -- "$ANCHOR_PATH")
  _rc=0
  _have=$(REPOS_ROOT="$_rr" ticket_log_dir_anchor_write "$_want") || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "env-check: could not write the anchor under ${_rr}/.ticket-auto" >&2
    exit 1
  fi
  echo "LOG_DIR_ANCHOR: ${_have}"
  if [ "$(realpath -m -- "$_have")" != "$_want" ]; then
    echo "env-check: already anchored at ${_have}; the anchor is never replaced. To move: stop the fleet, mv the dir, rewrite ${_rr}/.ticket-auto/log-dir, start the fleet" >&2
    exit 1
  fi
  exit 0
fi

# Reject unknown --mode values
case "${_MODE:-full}" in
full | validate) ;;
*)
  echo "ERROR: unknown --mode '${_MODE:-}'. Valid modes: full, validate" >&2
  error_exit 12 "env-check: required configuration missing"
  ;;
esac
# ── Color helpers (used by validate mode) ─────────────────────────────────────
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
BLUE=$(tput setaf 4 2>/dev/null || echo "")
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

say() { echo "${BOLD}${1}${RESET}: ${2}"; }
pass() { echo "  ${GREEN}ok${RESET}  ${1}"; }
fail() { echo "  ${RED}MISS${RESET} ${1} — ${2}"; }
warn() { echo "  ${YELLOW}warn${RESET} ${1} — ${2}"; }
info() { echo "  ${BLUE}info${RESET} ${1} — ${2}"; }

# Walk ancestors from start_dir; emit the first dir with ≥2 child repos on stdout.
# Returns empty string (exit 0) when no qualifying ancestor is found.
_derive_repos_root() {
  local walk_dir="$1"
  while [ "$walk_dir" != "/" ] && [ "$walk_dir" != "." ]; do
    local count=0
    for child in "$walk_dir"/*/; do
      [ -d "$child" ] || continue
      if [ -d "$child/.git" ] || [ -f "$child/CLAUDE.md" ]; then
        count=$((count + 1))
      fi
    done
    if [ "$count" -ge 2 ]; then
      echo "$walk_dir"
      return 0
    fi
    walk_dir="$(dirname "$walk_dir")"
  done
}

# ── Validate mode ─────────────────────────────────────────────────────────────
if [ "${_MODE:-full}" = "validate" ]; then
  # Resolve CLAUDE.md path: if PROJECT_DIR points to a file, it IS the CLAUDE.md
  if [ -f "$PROJECT_DIR" ]; then
    CLAUDE_MD="$PROJECT_DIR"
    PROJECT_DIR="$(dirname "$PROJECT_DIR")"
  else
    CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"
  fi
  cd "$PROJECT_DIR"

  failures=0

  echo ""
  say "check" "pre-flight infrastructure"

  # Docker registry lock check
  # cnb-local-registry uses jgit for config storage — stale lock files from
  # crashed processes block env-start.sh. Check and auto-clean if stale (>1h).
  # ENV_CHECK_JGIT_LOCK_ROOT narrows the search (default "/", a whole-filesystem
  # walk that takes seconds) — tests point it at a scratch dir.
  _docker_jgit_lock=$(find "${ENV_CHECK_JGIT_LOCK_ROOT:-/}" -path "*/cnb-local-registry/*/jgit/config.lock" -type f 2>/dev/null | head -1 || true)
  if [ -n "$_docker_jgit_lock" ]; then
    _lock_age=$(($(date +%s) - $(stat -c %Y "$_docker_jgit_lock" 2>/dev/null || echo 0)))
    if [ "$_lock_age" -gt 3600 ]; then
      rm -f "$_docker_jgit_lock" 2>/dev/null && pass "Docker jgit lock (stale, auto-cleaned)" || warn "Docker jgit lock (stale, could not auto-clean: $_docker_jgit_lock)"
    else
      warn "Docker jgit lock (active: ${_lock_age}s old — env-start may fail if this is stale)"
    fi
  else
    pass "Docker jgit lock (none found)"
  fi

  # GitHub PAT scope validation (non-fatal: falls back to listing if API unreachable)
  # Pipe the Authorization header via stdin to avoid exposing the token in
  # /proc/*/cmdline (curl -H would leak it in process listings).
  if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    _pat_scopes=$(printf 'Authorization: token %s\r\n' "$GITHUB_PERSONAL_ACCESS_TOKEN" | curl -s -f -H @- https://api.github.com/user 2>/dev/null | grep -c '"login"' || true)
    _pat_scopes=${_pat_scopes:-0}
    if [ "${_pat_scopes:-0}" -gt 0 ]; then
      # Check if PAT has repo scope — needed for PR creation
      _repo_scope=$(printf 'Authorization: token %s\r\n' "$GITHUB_PERSONAL_ACCESS_TOKEN" | curl -s -I -H @- https://api.github.com/orgs/willard-pro/repos 2>/dev/null | head -1 | grep -c '200' || true)
      _repo_scope=${_repo_scope:-0}
      if [ "${_repo_scope:-0}" -gt 0 ]; then
        pass "GitHub PAT (authenticated, repo scope confirmed)"
      else
        warn "GitHub PAT (authenticated but repo scope unconfirmed — PR creation may fail)"
      fi
    else
      # PAT validation API call failed — token might still work, just can't verify
      warn "GitHub PAT (scope validation unavailable — GitHub API unreachable or token is scoped)"
    fi
  else
    fail "GITHUB_PERSONAL_ACCESS_TOKEN not set" "add to .claude/settings.local.json"
    failures=$((failures + 1))
  fi

  echo ""
  say "check" "shell environment variables"

  # LINEAR_API_KEY
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    pass "LINEAR_API_KEY"
  elif [ -f "$PROJECT_DIR/.env" ] && grep -q '^LINEAR_API_KEY=' "$PROJECT_DIR/.env" 2>/dev/null; then
    pass "LINEAR_API_KEY (in .env)"
  else
    fail "LINEAR_API_KEY" "add to .claude/settings.local.json env block — required by lib/linear-api.sh"
    failures=$((failures + 1))
  fi

  # LINEAR_API_URL (optional, has default)
  if [ -n "${LINEAR_API_URL:-}" ]; then
    pass "LINEAR_API_URL (override)"
  else
    pass "LINEAR_API_URL (default: https://api.linear.app/graphql)"
  fi

  # GITHUB_PERSONAL_ACCESS_TOKEN
  if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    pass "GITHUB_PERSONAL_ACCESS_TOKEN"
  else
    fail "GITHUB_PERSONAL_ACCESS_TOKEN" "add to ~/.claude/settings.json env block — required by GitHub MCP"
    failures=$((failures + 1))
  fi

  echo ""
  say "check" "CLAUDE.md values ($CLAUDE_MD)"

  if [ ! -f "$CLAUDE_MD" ]; then
    fail "CLAUDE.md not found at $CLAUDE_MD" "ticket-auto guard should have already verified working directory"
    echo ""
    echo "${RED}${BOLD}Validation failed: ${failures} missing${RESET}"
    error_exit 12 "env-check: required configuration missing"
  fi

  # REPOS_ROOT
  if val=$(claude_md_field "$CLAUDE_MD" REPOS_ROOT); then
    pass "REPOS_ROOT ($val)"
  else
    DERIVED="$(_derive_repos_root "$(dirname "$CLAUDE_MD")")"
    if [ -n "$DERIVED" ]; then
      fail "REPOS_ROOT" "not in CLAUDE.md — propose: REPOS_ROOT = $DERIVED"
    else
      fail "REPOS_ROOT" "CLAUDE.md missing REPOS_ROOT = /path/to/repos — skills can't resolve repo paths"
    fi
    failures=$((failures + 1))
  fi

  # LOCAL_URL
  if [ -n "${LOCAL_URL:-}" ]; then
    pass "LOCAL_URL ($LOCAL_URL via env)"
  elif val=$(claude_md_field "$CLAUDE_MD" LOCAL_URL) && [[ "$val" =~ ^https?:// ]]; then
    pass "LOCAL_URL ($val)"
  else
    fail "LOCAL_URL" "required by ticket-verify — add to env or CLAUDE.md"
    failures=$((failures + 1))
  fi

  # UAT_URL — resolution delegated to resolve_uat_url (lib/linear-api.sh)
  if val=$(resolve_uat_url "$(dirname "$CLAUDE_MD")" 2>/dev/null); then
    if [ -n "${UAT_URL:-}" ]; then
      pass "UAT_URL ($val via env)"
    else
      pass "UAT_URL ($val)"
    fi
  else
    fail "UAT_URL" "required by ticket-verify — add to env or CLAUDE.md"
    failures=$((failures + 1))
  fi

  # BE_TEST_CMD (optional)
  if grep -q 'BE_TEST_CMD' "$CLAUDE_MD" 2>/dev/null; then
    pass "BE_TEST_CMD (present)"
  else
    warn "BE_TEST_CMD" "missing — ticket-implement will skip BE tests"
  fi

  # BE_TEST_RUNNER (optional) — exact test invocation for pyenv/pipenv environments
  if grep -q 'BE_TEST_RUNNER' "$CLAUDE_MD" 2>/dev/null; then
    pass "BE_TEST_RUNNER (present)"
  else
    info "BE_TEST_RUNNER" "not set — will use BE_TEST_CMD directly"
  fi

  # SLACK_CHANNEL (optional)
  if grep -q 'SLACK_CHANNEL' "$CLAUDE_MD" 2>/dev/null; then
    pass "SLACK_CHANNEL (present)"
  else
    warn "SLACK_CHANNEL" "missing — ticket-overseer will print to stdout only"
  fi

  # WIKI_ROOT (optional)
  if grep -q 'WIKI_ROOT\|wiki/' "$CLAUDE_MD" 2>/dev/null; then
    pass "WIKI_ROOT (wiki path present)"
  else
    warn "WIKI_ROOT" "missing — appraise will skip wiki bootstrapping"
  fi

  # RECORD_ALLOWED (optional, ticket-auto-record) — environments `--record`
  # may capture: `local` and/or `uat`, comma-separated. They must hold
  # synthetic data only; `uat` also needs RECORD_UAT_SYNTHETIC=true.
  # RECORD_BOARD_URL (optional) is the Linear project/view the board
  # recorder opens. Silent when RECORD_ALLOWED is not set.
  val=$(claude_md_field "$CLAUDE_MD" RECORD_ALLOWED) || val="${RECORD_ALLOWED:-}"
  if [ -n "$val" ]; then
    _syn=$(claude_md_field "$CLAUDE_MD" RECORD_UAT_SYNTHETIC || echo "${RECORD_UAT_SYNTHETIC:-}")
    _rec=$(source "$SCRIPT_DIR/record.sh" && record_allowed_parse "$val" "$_syn" 2>/dev/null | tr '\n' ' ')
    if [ -n "$_rec" ]; then
      pass "RECORD_ALLOWED (${_rec% }) — synthetic data only"
    else
      warn "RECORD_ALLOWED" "'$val' allows nothing — use local and/or uat (uat needs RECORD_UAT_SYNTHETIC=true); --record will be refused"
    fi
  fi

  # Verify worktree serving (#419): ticket-verify hands env-start.sh the
  # ticket's verify worktree as VERIFY_REPO_PATH_<REPO>, then gate-stops
  # VERIFY_SERVED_WRONG_WORKTREE when the dev server still runs from another
  # checkout. Surface an unwired env-start.sh here, before a verify run trips.
  if [ -f "$PROJECT_DIR/env-start.sh" ]; then
    if grep -q 'VERIFY_REPO_PATH' "$PROJECT_DIR/env-start.sh" 2>/dev/null; then
      pass "env-start.sh reads VERIFY_REPO_PATH_* (serves the ticket's verify worktree)"
    else
      warn "env-start.sh" "does not read VERIFY_REPO_PATH_* — it will serve the primary checkout and ticket-verify will gate-stop VERIFY_SERVED_WRONG_WORKTREE"
    fi
  fi

  # VERIFY_SERVED_PORTS (optional) — extra ports whose listener must also serve
  # the ticket's code, besides LOCAL_URL's port.
  if val=$(claude_md_field "$CLAUDE_MD" VERIFY_SERVED_PORTS); then
    _bad_ports=""
    for _item in $(printf '%s' "$val" | tr ',' ' '); do
      [[ "$_item" =~ ^[0-9]+$ || "$_item" =~ ^https?://[^/:]+(:[0-9]+)?(/.*)?$ ]] || _bad_ports="$_bad_ports $_item"
    done
    if [ -z "$_bad_ports" ]; then
      pass "VERIFY_SERVED_PORTS ($val)"
    else
      warn "VERIFY_SERVED_PORTS" "unparseable item(s):$_bad_ports — use ports or http(s) URLs, comma or space separated"
    fi
  fi

  echo ""
  say "check" "plugin skills not shadowed"
  _shadows=$(_ec_skill_shadows)
  if [ -z "$_EC_PLUGIN_ROOT" ]; then
    warn "skill shadowing" "plugin root not found — not checked"
  elif [ -z "$_shadows" ]; then
    pass "no user- or project-level SKILL.md shadows a plugin skill"
  else
    while IFS='|' read -r _sn _sp; do
      fail "SKILL.md shadows plugin skill '$_sn'" "$_sp runs instead of the plugin's — run: bash $SCRIPT_DIR/skill-shadow.sh fix (user level; the SessionStart hook does this too)"
      failures=$((failures + 1))
    done <<<"$_shadows"
  fi

  echo ""
  say "check" "token tracker hooks"

  # Check project-level settings first (preferred — scoped to this repo), then user-level
  HOOKS_FOUND=false
  HOOKS_LEVEL=""
  $_EC_PLUGIN_HOOKS && HOOKS_FOUND=true && HOOKS_LEVEL="plugin"
  for SETTINGS_FILE in "$PROJECT_DIR/.claude/settings.json" "$HOME/.claude/settings.json"; do
    $HOOKS_FOUND && break
    [ -f "$SETTINGS_FILE" ] || continue
    START_OK=false
    STOP_OK=false
    jq -e '.hooks.SubagentStart // [] | [.[].hooks[]? | select(.command | test("token-tracker-start"))] | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && START_OK=true
    jq -e '.hooks.SubagentStop // [] | [.[].hooks[]? | select(.command | test("token-tracker\\.sh"))] | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && STOP_OK=true
    if $START_OK && $STOP_OK; then
      HOOKS_FOUND=true
      HOOKS_LEVEL="$SETTINGS_FILE"
      break
    fi
  done

  if $HOOKS_FOUND; then
    if [ "$HOOKS_LEVEL" = "plugin" ]; then
      pass "SubagentStart → token-tracker-start.sh + SubagentStop → token-tracker.sh (registered by the plugin)"
    elif [[ "$HOOKS_LEVEL" == "$PROJECT_DIR/.claude/settings.json" ]]; then
      pass "SubagentStart → token-tracker-start.sh + SubagentStop → token-tracker.sh (project-level — scoped to this repo)"
    else
      warn "SubagentStart → token-tracker-start.sh + SubagentStop → token-tracker.sh (user-level — fires globally, consider moving to project .claude/settings.json)"
    fi
  else
    fail "token tracker hooks not wired" "add SubagentStart→token-tracker-start.sh + SubagentStop→token-tracker.sh to project .claude/settings.json"
    failures=$((failures + 1))
  fi

  echo ""
  say "check" "spawn permissions"

  # Check project-level settings first (preferred — scoped to this repo), then user-level
  PERMS_FOUND=false
  PERMS_LEVEL=""
  for SETTINGS_FILE in "$PROJECT_DIR/.claude/settings.json" "$HOME/.claude/settings.json"; do
    [ -f "$SETTINGS_FILE" ] || continue
    SPAWN_OK=false
    HB_OK=false
    LOGS_OK=false
    jq -e '.permissions.allow // [] | map(select(. | test("spawn-helper\\.sh"))) | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && SPAWN_OK=true
    jq -e '.permissions.allow // [] | map(select(. | test("heartbeat\\.sh"))) | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && HB_OK=true
    jq -e '.permissions.allow // [] | map(select(. | test("Write.*logs/\\*\\*"))) | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && LOGS_OK=true
    if $SPAWN_OK && $HB_OK && $LOGS_OK; then
      PERMS_FOUND=true
      PERMS_LEVEL="$SETTINGS_FILE"
      break
    fi
  done

  if $PERMS_FOUND; then
    if [[ "$PERMS_LEVEL" == "$PROJECT_DIR/.claude/settings.json" ]]; then
      pass "Bash(spawn-helper.sh) + Bash(heartbeat.sh) + Write(logs/**) (project-level)"
    else
      warn "Bash(spawn-helper.sh) + Bash(heartbeat.sh) + Write(logs/**) (user-level — consider moving to project .claude/settings.json)"
    fi
  else
    fail "spawn permissions not configured" "add Bash(spawn-helper.sh), Bash(heartbeat.sh), Write(logs/**) to project .claude/settings.json"
    failures=$((failures + 1))
  fi

  echo ""
  if [ "$failures" -eq 0 ]; then
    echo "${GREEN}${BOLD}All required values present.${RESET}"
    exit 0
  else
    echo "${RED}${BOLD}${failures} required value(s) missing. Fix above and re-run.${RESET}"
    error_exit 12 "env-check: required configuration missing"
  fi
fi

cd "$PROJECT_DIR"

issues=0
declare -a VAR_LINES
_var() { VAR_LINES+=("$1|$2|$3|$4|$5"); }

# Masks a secret to presence + last 4 chars (e.g. "****yw3D") so the report
# never carries a full credential into a transcript (same rule as
# fleet-controller's fleet-env-check.sh).
_mask() {
  local val="$1"
  if [ "${#val}" -le 4 ]; then
    printf '****'
  else
    printf '****%s' "${val: -4}"
  fi
}

# Returns "filepath:value" if varname found in env block of either settings.local.json.
# Checks project-local first, then global ~/.claude.
find_in_settings() {
  local varname="$1"
  local files=(
    "$PROJECT_DIR/.claude/settings.local.json"
    "$HOME/.claude/settings.local.json"
  )
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    local val=""
    if command -v jq &>/dev/null; then
      val=$(jq -r --arg k "$varname" '.env[$k] // empty' "$f" 2>/dev/null || true)
    else
      val=$(grep -oP "\"$varname\"\s*:\s*\"\K[^\"]+" "$f" 2>/dev/null | head -1 || true)
    fi
    [ -n "$val" ] && echo "${f}:${val}" && return 0
  done
  return 1
}

GIT_NAME="$(git config user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config user.email 2>/dev/null || true)"

# ── API keys ────────────────────────────────────────────────────────────────

if [ -n "${LINEAR_API_KEY:-}" ]; then
  _var "LINEAR_API_KEY" "ok" "$(_mask "${LINEAR_API_KEY}")" "settings.local.json" ""
elif DOTENV_LINEAR_KEY=$(grep -oP '^LINEAR_API_KEY=\K.*' "$PROJECT_DIR/.env" 2>/dev/null || true) && [ -n "$DOTENV_LINEAR_KEY" ]; then
  _var "LINEAR_API_KEY" "auto" "(in .env)" ".env" "key found in project .env"
elif result=$(find_in_settings "LINEAR_API_KEY"); then
  _var "LINEAR_API_KEY" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
else
  _var "LINEAR_API_KEY" "missing" "" "settings.local.json" "Linear API key (Linear → Settings → API)"
  issues=$((issues + 1))
fi

# ── Linear board labels ─────────────────────────────────────────────────────
# The board driver projects needs-info/needs-adr/rejected/reviewed but never
# creates them; a missing one fails that event's projection permanently.
# Checked once the key is loaded; created only with --create-labels.
if [ -n "${LINEAR_API_KEY:-}" ] && [ "${ENV_CHECK_SKIP_LINEAR:-}" != "1" ] &&
  [ -f "$SCRIPT_DIR/linear-labels.sh" ]; then
  source "$SCRIPT_DIR/linear-labels.sh"
  _ll_rc=0
  _ll_team=$(linear_labels_resolve_team 2>/dev/null) || _ll_rc=$?
  if [ "$_ll_rc" -eq 4 ]; then
    _var "LINEAR_TEAM" "warn" "" "Linear" "teams query failed — check LINEAR_API_KEY; labels not checked"
  elif [ "$_ll_rc" -ne 0 ]; then
    _var "LINEAR_TEAM" "warn" "${LINEAR_TEAM_ID:-}" "settings.local.json" "team not resolved — set LINEAR_TEAM_ID (key, name or id); labels not checked"
  else
    _var "LINEAR_TEAM" "ok" "$_ll_team" "$([ -n "${LINEAR_TEAM_ID:-}" ] && echo settings.local.json || echo "Linear (only team)")" ""
    _ll_rc=0
    _ll_rows=$(linear_labels_status "$_ll_team") || _ll_rc=$?
    if [ "$_ll_rc" -ne 0 ]; then
      _var "LINEAR_LABELS" "warn" "" "Linear" "team label fetch failed; labels not checked"
    else
      _ll_made=false
      while IFS=$'\t' read -r _ll_name _ll_id; do
        [ -z "$_ll_name" ] && continue
        if [ -n "$_ll_id" ]; then
          _var "label:${_ll_name}" "ok" "$_ll_id" "Linear" ""
        elif $CREATE_LABELS && _ll_id=$(linear_labels_create "$_ll_team" "$_ll_name" 2>/dev/null); then
          _var "label:${_ll_name}" "ok" "$_ll_id" "Linear" "created by --create-labels"
          _ll_made=true
        elif $CREATE_LABELS; then
          _var "label:${_ll_name}" "missing" "" "Linear" "absent — --create-labels could not create it"
          issues=$((issues + 1))
        else
          _var "label:${_ll_name}" "missing" "" "Linear" "absent — board projection fails; re-run with --create-labels"
          issues=$((issues + 1))
        fi
      done <<<"$_ll_rows"
      $_ll_made && linear_labels_drop_driver_cache "$_ll_team"
    fi
  fi
fi

if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  _var "ANTHROPIC_AUTH_TOKEN" "ok" "$(_mask "${ANTHROPIC_AUTH_TOKEN}")" "settings.local.json" ""
elif result=$(find_in_settings "ANTHROPIC_AUTH_TOKEN"); then
  _var "ANTHROPIC_AUTH_TOKEN" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
else
  _var "ANTHROPIC_AUTH_TOKEN" "missing" "" "settings.local.json" "Anthropic API key"
  issues=$((issues + 1))
fi

if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "ok" "$(_mask "${GITHUB_PERSONAL_ACCESS_TOKEN}")" "settings.local.json" ""
  if [ -z "${GH_TOKEN:-}" ]; then
    _var "GH_TOKEN" "auto" "(copy of GITHUB_PERSONAL_ACCESS_TOKEN)" "settings.local.json" "set same as GITHUB_PERSONAL_ACCESS_TOKEN"
  else
    _var "GH_TOKEN" "ok" "$(_mask "${GH_TOKEN}")" "settings.local.json" ""
  fi
elif result=$(find_in_settings "GITHUB_PERSONAL_ACCESS_TOKEN"); then
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
  issues=$((issues + 1))
else
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "missing" "" "settings.local.json" "GitHub personal access token"
  issues=$((issues + 1))
  if [ -z "${GH_TOKEN:-}" ]; then
    _var "GH_TOKEN" "missing" "" "settings.local.json" "set same as GITHUB_PERSONAL_ACCESS_TOKEN"
    issues=$((issues + 1))
  fi
fi

# ── Optional env ────────────────────────────────────────────────────────────

if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
  _var "ANTHROPIC_BASE_URL" "ok" "${ANTHROPIC_BASE_URL}" "settings.local.json" ""
elif result=$(find_in_settings "ANTHROPIC_BASE_URL"); then
  _var "ANTHROPIC_BASE_URL" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
else
  _var "ANTHROPIC_BASE_URL" "warn" "" "settings.local.json" "override Anthropic API base URL"
fi

if [ -n "${ANTHROPIC_MODEL:-}" ]; then
  _var "ANTHROPIC_MODEL" "ok" "${ANTHROPIC_MODEL}" "settings.local.json" ""
elif result=$(find_in_settings "ANTHROPIC_MODEL"); then
  _var "ANTHROPIC_MODEL" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
else
  _var "ANTHROPIC_MODEL" "warn" "" "settings.local.json" "override default model"
fi

if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
  _var "GIT_AUTHOR_NAME" "ok" "${GIT_AUTHOR_NAME}" "settings.local.json" ""
elif [ -n "$GIT_NAME" ]; then
  _var "GIT_AUTHOR_NAME" "auto" "$GIT_NAME" "settings.local.json" "from git config user.name"
else
  _var "GIT_AUTHOR_NAME" "warn" "" "settings.local.json" "run: git config user.name"
fi

if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
  _var "GIT_AUTHOR_EMAIL" "ok" "${GIT_AUTHOR_EMAIL}" "settings.local.json" ""
elif [ -n "$GIT_EMAIL" ]; then
  _var "GIT_AUTHOR_EMAIL" "auto" "$GIT_EMAIL" "settings.local.json" "from git config user.email"
else
  _var "GIT_AUTHOR_EMAIL" "warn" "" "settings.local.json" "run: git config user.email"
fi

if [ -n "${TICKET_AUTONOMY:-}" ]; then
  _var "TICKET_AUTONOMY" "ok" "${TICKET_AUTONOMY}" "settings.local.json" ""
else
  DOTENV_VAL=$(grep -oP '^TICKET_AUTONOMY=\K.*' "$PROJECT_DIR/.env" 2>/dev/null || true)
  if [ -n "$DOTENV_VAL" ]; then
    _var "TICKET_AUTONOMY" "auto" "$DOTENV_VAL" "settings.local.json" "found in .env — copy to settings.local.json"
  elif result=$(find_in_settings "TICKET_AUTONOMY"); then
    _var "TICKET_AUTONOMY" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
  else
    _var "TICKET_AUTONOMY" "warn" "manual" "settings.local.json" "auto | semi-auto | manual (default)"
  fi
fi

if UAT_CLAUDE=$(resolve_uat_url "$PROJECT_DIR" 2>/dev/null); then
  _var "UAT_URL" "ok" "$UAT_CLAUDE" "CLAUDE.md" ""
else
  _var "UAT_URL" "missing" "" "CLAUDE.md" "UAT environment URL (e.g. https://uat.example.com)"
  issues=$((issues + 1))
fi

# ── CLAUDE.md fields ────────────────────────────────────────────────────────

if [ ! -f "$PROJECT_DIR/CLAUDE.md" ]; then
  _var "CLAUDE.md" "missing" "" "CLAUDE.md" "file not found at $PROJECT_DIR/CLAUDE.md"
  issues=$((issues + 1))
else
  if VAL=$(claude_md_field "$PROJECT_DIR/CLAUDE.md" REPOS_ROOT); then
    _var "REPOS_ROOT" "ok" "$VAL" "CLAUDE.md" ""
  else
    DERIVED="$(_derive_repos_root "$PROJECT_DIR")"
    if [ -n "$DERIVED" ]; then
      _var "REPOS_ROOT" "auto" "$DERIVED" "CLAUDE.md" "add REPOS_ROOT = $DERIVED to CLAUDE.md"
    else
      _var "REPOS_ROOT" "missing" "" "CLAUDE.md" "parent directory of all project repos"
    fi
    issues=$((issues + 1))
  fi

  # LOG_DIR_ANCHOR (state-root-anchor): informational, never an issue.
  _rr=$(_env_check_repos_root)
  if [ -n "$_rr" ]; then
    _af="${_rr%/}/.ticket-auto/log-dir"
    if _av=$(_tld_anchor_read "$_af"); then
      _var "LOG_DIR_ANCHOR" "ok" "$_av" "$_af" ""
    elif [ -e "$_af" ]; then
      _var "LOG_DIR_ANCHOR" "warn" "" "$_af" "first line is not an absolute path — fix it by hand"
    else
      _want=$(realpath -m -- "$PROJECT_DIR/logs")
      _reply=""
      if [ "${ENV_CHECK_INTERACTIVE:-}" = "1" ] || [ -t 0 ]; then
        printf 'Anchor the pipeline log dir at %s? [y/N] ' "$_want" >&2
        IFS= read -r _reply || true
      fi
      case "$_reply" in
      y | Y | yes | YES)
        if _av=$(REPOS_ROOT="$_rr" ticket_log_dir_anchor_write "$_want"); then
          _var "LOG_DIR_ANCHOR" "ok" "$_av" "$_af" ""
        else
          _var "LOG_DIR_ANCHOR" "warn" "" "$_af" "could not write the anchor"
        fi
        ;;
      *)
        _var "LOG_DIR_ANCHOR" "warn" "" "$_af" "not anchored — run env-check.sh --anchor-log-dir $_want, or one /ticket-auto from the project dir"
        ;;
      esac
    fi
  fi

  if [ -n "${LOCAL_URL:-}" ]; then
    _var "LOCAL_URL" "ok" "$LOCAL_URL" "settings.local.json" ""
  elif VAL=$(claude_md_field "$PROJECT_DIR/CLAUDE.md" LOCAL_URL) && [[ "$VAL" =~ ^https?:// ]]; then
    _var "LOCAL_URL" "ok" "$VAL" "CLAUDE.md" ""
  elif result=$(find_in_settings "LOCAL_URL"); then
    _var "LOCAL_URL" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
  else
    _var "LOCAL_URL" "missing" "" "settings.local.json or CLAUDE.md" "local dev server URL (e.g. http://localhost:3000)"
    issues=$((issues + 1))
  fi

  if grep -q 'BE_TEST_CMD' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    _var "BE_TEST_CMD" "ok" "present" "CLAUDE.md" ""
  else
    _var "BE_TEST_CMD" "warn" "" "CLAUDE.md" "backend test command — ticket-implement skips BE tests if absent"
  fi

  if grep -q 'BE_TEST_RUNNER' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    _var "BE_TEST_RUNNER" "ok" "present" "CLAUDE.md" "exact test runner path (e.g., ~/.pyenv/versions/3.13.12/bin/pytest)"
  else
    _var "BE_TEST_RUNNER" "info" "" "CLAUDE.md" "optional — falls back to BE_TEST_CMD when not set"
  fi

  if grep -q 'SLACK_CHANNEL' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    _var "SLACK_CHANNEL" "ok" "present" "CLAUDE.md" ""
  else
    _var "SLACK_CHANNEL" "warn" "" "CLAUDE.md" "Slack channel — ticket-overseer prints to stdout only if absent"
  fi

  if grep -qi 'WIKI_ROOT\|wiki/' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    _var "WIKI_ROOT" "ok" "present" "CLAUDE.md" ""
  else
    _var "WIKI_ROOT" "warn" "" "CLAUDE.md" "wiki directory path — appraise skips wiki bootstrapping if absent"
  fi
fi

# ── Skill shadowing ─────────────────────────────────────────────────────────
# A user- or project-level SKILL.md named like a plugin skill runs instead of
# the plugin's, silently (lib/skill-shadow.sh).

if [ -z "$_EC_PLUGIN_ROOT" ]; then
  _var "SKILL_SHADOW" "warn" "" "~/.claude/skills" "plugin root not found — not checked"
else
  _shadows=$(_ec_skill_shadows)
  if [ -z "$_shadows" ]; then
    _var "SKILL_SHADOW" "ok" "none" "~/.claude/skills" ""
  else
    while IFS='|' read -r _sn _sp; do
      _var "SKILL_SHADOW:${_sn}" "missing" "$_sp" "$(dirname "$(dirname "$_sp")")" "shadows the plugin skill — run: bash $SCRIPT_DIR/skill-shadow.sh fix (user level; the SessionStart hook does this too)"
      issues=$((issues + 1))
    done <<<"$_shadows"
  fi
fi

# ── Hooks ───────────────────────────────────────────────────────────────────

START_OK=false
STOP_OK=false
HOOKS_LEVEL=""
if $_EC_PLUGIN_HOOKS; then
  START_OK=true
  STOP_OK=true
  HOOKS_LEVEL="plugin"
fi
for SETTINGS_FILE in "$PROJECT_DIR/.claude/settings.json" "$HOME/.claude/settings.json"; do
  [ "$HOOKS_LEVEL" = "plugin" ] && break
  [ -f "$SETTINGS_FILE" ] || continue
  jq -e '.hooks.SubagentStart // [] | [.[].hooks[]? | select(.command | test("token-tracker-start"))] | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && START_OK=true
  jq -e '.hooks.SubagentStop // [] | [.[].hooks[]? | select(.command | test("token-tracker\\.sh"))] | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && STOP_OK=true
  if $START_OK && $STOP_OK; then
    HOOKS_LEVEL="$SETTINGS_FILE"
    break
  fi
done

if $START_OK && $STOP_OK; then
  if [ "$HOOKS_LEVEL" = "plugin" ]; then
    _var "HOOKS_CONFIGURED" "ok" "SubagentStart + SubagentStop" "plugin.json" "registered by the plugin"
  elif [[ "$HOOKS_LEVEL" == "$PROJECT_DIR/.claude/settings.json" ]]; then
    _var "HOOKS_CONFIGURED" "ok" "SubagentStart + SubagentStop" "project .claude/settings.json" "token tracker hooks scoped to this repo"
  else
    _var "HOOKS_CONFIGURED" "warn" "SubagentStart + SubagentStop" "~/.claude/settings.json" "hooks fire globally — consider moving to project .claude/settings.json"
  fi
elif $START_OK && ! $STOP_OK; then
  _var "HOOKS_CONFIGURED" "warn" "SubagentStart only" "settings.json" "missing SubagentStop → token-tracker.sh"
  issues=$((issues + 1))
elif ! $START_OK && $STOP_OK; then
  _var "HOOKS_CONFIGURED" "warn" "SubagentStop only" "settings.json" "missing SubagentStart → token-tracker-start.sh"
  issues=$((issues + 1))
else
  _var "HOOKS_CONFIGURED" "missing" "" "project .claude/settings.json" "add SubagentStart→token-tracker-start.sh + SubagentStop→token-tracker.sh"
  issues=$((issues + 1))
fi

# ── Spawn permissions ────────────────────────────────────────────────────────

SPAWN_OK=false
HB_OK=false
LOGS_OK=false
PERMS_LEVEL=""
for SETTINGS_FILE in "$PROJECT_DIR/.claude/settings.json" "$HOME/.claude/settings.json"; do
  [ -f "$SETTINGS_FILE" ] || continue
  jq -e '.permissions.allow // [] | map(select(. | test("spawn-helper\\.sh"))) | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && SPAWN_OK=true
  jq -e '.permissions.allow // [] | map(select(. | test("heartbeat\\.sh"))) | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && HB_OK=true
  jq -e '.permissions.allow // [] | map(select(. | test("Write.*logs/\\*\\*"))) | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && LOGS_OK=true
  if $SPAWN_OK && $HB_OK && $LOGS_OK; then
    PERMS_LEVEL="$SETTINGS_FILE"
    break
  fi
done

if $SPAWN_OK && $HB_OK && $LOGS_OK; then
  if [[ "$PERMS_LEVEL" == "$PROJECT_DIR/.claude/settings.json" ]]; then
    _var "SPAWN_PERMISSIONS" "ok" "spawn-helper + heartbeat + logs/**" "project .claude/settings.json" ""
  else
    _var "SPAWN_PERMISSIONS" "warn" "spawn-helper + heartbeat + logs/**" "~/.claude/settings.json" "permissions fire globally — consider moving to project .claude/settings.json"
  fi
else
  _var "SPAWN_PERMISSIONS" "missing" "" "project .claude/settings.json" "add Bash(spawn-helper.sh), Bash(heartbeat.sh), Write(logs/**)"
  issues=$((issues + 1))
fi

# ── Emit ────────────────────────────────────────────────────────────────────

emit_vars() {
  echo "---BEGIN_VARS---"
  printf 'NAME|STATUS|VALUE|LOCATION|NOTE\n'
  for line in "${VAR_LINES[@]}"; do echo "$line"; done
  echo "ROWCOUNT=${#VAR_LINES[@]}"
  echo "---END_VARS---"
}

show_table() {
  printf '%-35s %-8s %-45s %-22s %s\n' "NAME" "STATUS" "VALUE" "LOCATION" "NOTE"
  printf '%-35s %-8s %-45s %-22s %s\n' "----" "------" "-----" "--------" "----"
  for line in "${VAR_LINES[@]}"; do
    IFS='|' read -r name status value location note <<<"$line"
    [ -z "$value" ] && value="-"
    printf '%-35s %-8s %-45s %-22s %s\n' "$name" "$status" "$value" "$location" "$note"
  done
}

if [ -n "${SUMMARY_FILE:-}" ]; then
  emit_vars >"$SUMMARY_FILE"
  echo "Summary written to ${SUMMARY_FILE}"
  [ -n "${SHOW:-}" ] && show_table
else
  emit_vars
  [ -n "${SHOW:-}" ] && echo "" && show_table
fi

exit $issues
