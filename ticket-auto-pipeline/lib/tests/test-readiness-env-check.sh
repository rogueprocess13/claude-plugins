#!/usr/bin/env bash
# test-readiness-env-check.sh — lib/readiness-env-check.sh, the run-readiness
# rows of env-check.sh (GitHub #772): env-start.sh, the Playwright MCP server
# and browser, the GitNexus index, the prescan docs. Each probe is tested
# present, absent and not applicable, against stubs only: no browser, index,
# network or real HOME.
# Usage: bash test-readiness-env-check.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

PASS=0
FAIL=0
exec </dev/null

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
REAL_PATH="$PATH"

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

# A fresh world: $W/home (HOME), $W/root (REPOS_ROOT), $W/root/tickets (the
# project dir, with a CLAUDE.md).
_world() {
  W=$(mktemp -d -p "$SCRATCH")
  mkdir -p "$W/home" "$W/root/tickets"
  printf 'REPOS_ROOT = %s\nLOCAL_URL = http://localhost:3000\nUAT_URL = http://uat.example.com\n' \
    "$W/root" >"$W/root/tickets/CLAUDE.md"
  P="$W/root/tickets"
}

_rows() { # [VAR=value ...] — rows for $P in the stub world
  env -u REPOS_ROOT -u PLAYWRIGHT_BROWSERS_PATH -u npm_config_cache \
    HOME="$W/home" GITNEXUS_REGISTRY="$W/home/.gitnexus/registry.json" \
    READINESS_NPX_CACHE="$W/home/.npm/_npx" "$@" \
    bash "$LIB_DIR/readiness-env-check.sh" "$P"
}

_row() { # NAME [VAR=value ...]
  local name="$1"
  shift
  _rows "$@" | grep "^${name}|" || true
}

_repo() { # name [origin url]
  git init -q "$W/root/$1"
  [ -z "${2:-}" ] || git -C "$W/root/$1" remote add origin "$2"
}

_mcp() { # json for the playwright server
  printf '{"mcpServers":{"playwright":%s}}\n' "$1" >"$P/.mcp.json"
}

_npx_pkg() { # version browser revision
  local d="$W/home/.npm/_npx/abc123/node_modules"
  mkdir -p "$d/@playwright/mcp" "$d/playwright-core"
  printf '{"name":"@playwright/mcp","version":"%s"}\n' "$1" >"$d/@playwright/mcp/package.json"
  printf '{"browsers":[{"name":"%s","revision":"%s"}]}\n' "$2" "$3" >"$d/playwright-core/browsers.json"
}

_build() { mkdir -p "$W/home/.cache/ms-playwright/$1"; }

# ── env-start.sh ────────────────────────────────────────────────────────────
test_env_start_absent_warns() {
  _world
  [[ "$(_row VERIFY_ENV_START)" == "VERIFY_ENV_START|warn||$P|env-start.sh not found at the tickets root: verify-env-up.sh exits 127"* ]]
}

test_env_start_present_ok() {
  _world
  printf '#!/usr/bin/env bash\nAPP="${VERIFY_REPO_PATH_APP:-x}"\n' >"$P/env-start.sh"
  [[ "$(_row VERIFY_ENV_START)" == "VERIFY_ENV_START|ok|present|$P/env-start.sh|env-start.sh reads VERIFY_REPO_PATH_* (not run here"* ]]
}

test_env_start_unwired_warns() {
  _world
  printf '#!/usr/bin/env bash\necho up\n' >"$P/env-start.sh"
  [[ "$(_row VERIFY_ENV_START)" == "VERIFY_ENV_START|warn|present|"*"VERIFY_SERVED_WRONG_WORKTREE" ]]
}

test_env_start_syntax_error_warns() {
  _world
  printf '#!/usr/bin/env bash\nif then VERIFY_REPO_PATH (\n' >"$P/env-start.sh"
  [[ "$(_row VERIFY_ENV_START)" == "VERIFY_ENV_START|warn|syntax error|"* ]]
}

test_env_start_is_never_run() {
  _world
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\n: "$VERIFY_REPO_PATH_APP"\n' "$W" >"$P/env-start.sh"
  chmod +x "$P/env-start.sh"
  _rows >/dev/null
  [ ! -e "$W/ran" ]
}

test_no_claude_md_prints_nothing() {
  _world
  rm "$P/CLAUDE.md"
  [ -z "$(_rows)" ]
}

# ── Playwright MCP server ───────────────────────────────────────────────────
test_mcp_absent_warns_and_browser_not_checked() {
  _world
  [[ "$(_row PLAYWRIGHT_MCP)" == "PLAYWRIGHT_MCP|warn||.mcp.json|no MCP server named 'playwright'"* ]] &&
    [[ "$(_row PLAYWRIGHT_BROWSER)" == "PLAYWRIGHT_BROWSER|info||.mcp.json|not checked: no playwright MCP server configured" ]]
}

test_mcp_present_says_config_only() {
  _world
  _mcp '{"command":"npx","args":["-y","@playwright/mcp@1.2.3","--browser","firefox"]}'
  [[ "$(_row PLAYWRIGHT_MCP)" == "PLAYWRIGHT_MCP|ok|configured|$P/.mcp.json|config only: whether the server is connected"* ]]
}

test_mcp_user_scope_config_counts() {
  _world
  printf '{"mcpServers":{"playwright":{"command":"npx","args":["@playwright/mcp@latest"]}}}\n' >"$W/home/.claude.json"
  [[ "$(_row PLAYWRIGHT_MCP)" == "PLAYWRIGHT_MCP|ok|configured|$W/home/.claude.json (user)|"* ]]
}

# ── Playwright browser ──────────────────────────────────────────────────────
test_browser_pinned_revision_present_ok() {
  _world
  _mcp '{"command":"npx","args":["-y","@playwright/mcp@1.2.3","--browser","firefox","--headless"]}'
  _npx_pkg 1.2.3 firefox 1578
  _build firefox-1578
  [[ "$(_row PLAYWRIGHT_BROWSER)" == "PLAYWRIGHT_BROWSER|ok|firefox 1578|$W/home/.cache/ms-playwright|"* ]]
}

# The rehearsal's failure: a firefox build was installed, but not the revision
# the pinned server launches.
test_browser_pinned_revision_missing_warns() {
  _world
  _mcp '{"command":"npx","args":["-y","@playwright/mcp@1.2.3","--browser","firefox","--headless"]}'
  _npx_pkg 1.2.3 firefox 1578
  _build firefox-1549
  local row
  row=$(_row PLAYWRIGHT_BROWSER)
  [[ "$row" == "PLAYWRIGHT_BROWSER|warn|firefox|"*"needs firefox build 1578, which is not installed (found: 1549)"* ]] &&
    [[ "$row" == *"Run: npx -y @playwright/mcp@1.2.3 install-browser firefox" ]]
}

test_browser_none_installed_warns() {
  _world
  _mcp '{"command":"npx","args":["@playwright/mcp@latest","--browser=webkit"]}'
  [[ "$(_row PLAYWRIGHT_BROWSER)" == "PLAYWRIGHT_BROWSER|warn|webkit|"*"no webkit build installed"*"install-browser webkit" ]]
}

test_browser_unpinned_is_info_not_ok() {
  _world
  _mcp '{"command":"npx","args":["@playwright/mcp@latest","--browser","chromium"]}'
  _build chromium_headless_shell-1200
  [[ "$(_row PLAYWRIGHT_BROWSER)" == "PLAYWRIGHT_BROWSER|info|chromium (revision not verified)|"* ]]
}

test_browser_env_names_browser_and_cache() {
  _world
  _mcp "{\"command\":\"npx\",\"args\":[\"@playwright/mcp@1.2.3\"],\"env\":{\"PLAYWRIGHT_MCP_BROWSER\":\"firefox\",\"PLAYWRIGHT_BROWSERS_PATH\":\"$W/pw\"}}"
  _npx_pkg 1.2.3 firefox 77
  mkdir -p "$W/pw/firefox-77"
  [[ "$(_row PLAYWRIGHT_BROWSER)" == "PLAYWRIGHT_BROWSER|ok|firefox 77|$W/pw|"* ]]
}

test_browser_default_channel_present_ok() {
  _world
  _mcp '{"command":"npx","args":["@playwright/mcp@latest"]}'
  printf '#!/bin/sh\n' >"$W/fake-chrome"
  chmod +x "$W/fake-chrome"
  [[ "$(_row PLAYWRIGHT_BROWSER "READINESS_BROWSER_BINS=$W/fake-chrome")" == "PLAYWRIGHT_BROWSER|ok|chrome (default)|$W/fake-chrome|"* ]]
}

test_browser_default_channel_absent_warns() {
  _world
  _mcp '{"command":"npx","args":["@playwright/mcp@latest"]}'
  [[ "$(_row PLAYWRIGHT_BROWSER "READINESS_BROWSER_BINS=no-such-browser-772 $W/nope")" == "PLAYWRIGHT_BROWSER|warn|chrome (default)|PATH|"* ]]
}

test_browser_remote_server_not_applicable() {
  _world
  _mcp '{"type":"http","url":"http://localhost:8931/mcp"}'
  [[ "$(_row PLAYWRIGHT_BROWSER)" == "PLAYWRIGHT_BROWSER|info||"*"not applicable: the server is remote"* ]]
}

test_browser_is_never_installed_or_started() {
  _world
  _mcp '{"command":"npx","args":["@playwright/mcp@1.2.3","--browser","firefox"]}'
  mkdir -p "$W/bin"
  local t
  for t in npx node playwright gitnexus claude; do
    printf '#!/bin/sh\ntouch "%s/called-%s"\n' "$W" "$t" >"$W/bin/$t"
    chmod +x "$W/bin/$t"
  done
  _rows "PATH=$W/bin:$REAL_PATH" >/dev/null
  ! ls "$W"/called-* >/dev/null 2>&1
}

# ── GitNexus index ──────────────────────────────────────────────────────────
_registry() { # json array
  mkdir -p "$W/home/.gitnexus"
  printf '%s\n' "$1" >"$W/home/.gitnexus/registry.json"
}

test_gitnexus_indexed_by_path_ok() {
  _world
  _repo app
  _registry "[{\"name\":\"app\",\"path\":\"$W/root/app\"}]"
  [[ "$(_row GITNEXUS_INDEX)" == "GITNEXUS_INDEX|ok|1 of 1 indexed|"*"cannot be seen from a shell" ]]
}

test_gitnexus_indexed_by_remote_ok() {
  _world
  _repo app "git@example.com:Acme/App.git"
  _registry '[{"name":"app","path":"/elsewhere/app","remoteUrl":"https://example.com/acme/app"}]'
  [[ "$(_row GITNEXUS_INDEX)" == "GITNEXUS_INDEX|ok|1 of 1 indexed|"* ]]
}

test_gitnexus_repo_not_indexed_warns() {
  _world
  _repo app
  _repo web
  _registry "[{\"name\":\"app\",\"path\":\"$W/root/app\"}]"
  local row
  row=$(_row GITNEXUS_INDEX)
  [[ "$row" == "GITNEXUS_INDEX|warn|1 of 2 indexed|"*"not indexed: web — "* ]] &&
    [[ "$row" == *"Run: gitnexus analyze $W/root/web "* ]]
}

test_gitnexus_no_registry_warns() {
  _world
  _repo app
  [[ "$(_row GITNEXUS_INDEX)" == "GITNEXUS_INDEX|warn|0 of 1 indexed|"*"no readable GitNexus registry"* ]]
}

test_gitnexus_no_code_repo_not_applicable() {
  _world
  [[ "$(_row GITNEXUS_INDEX)" == "GITNEXUS_INDEX|info||$W/root|not applicable: no code repository under REPOS_ROOT" ]]
}

# A git tickets root holds plans, not code; hidden dirs hold worktrees.
test_tickets_root_and_hidden_dirs_are_not_code_repos() {
  _world
  git init -q "$P"
  git init -q "$W/root/.ticket-auto/worktrees/app"
  [[ "$(_row GITNEXUS_INDEX)" == *"|not applicable: no code repository under REPOS_ROOT" ]] &&
    [[ "$(_row PRESCAN_DOCS)" == *"|not applicable: no code repository under REPOS_ROOT" ]]
}

test_repos_root_unset_not_checked() {
  _world
  printf 'LOCAL_URL = http://localhost:3000\n' >"$P/CLAUDE.md"
  [[ "$(_row GITNEXUS_INDEX)" == "GITNEXUS_INDEX|info||CLAUDE.md|not checked: REPOS_ROOT"* ]] &&
    [[ "$(_row PRESCAN_DOCS)" == "PRESCAN_DOCS|info||CLAUDE.md|not checked: REPOS_ROOT"* ]]
}

# ── prescan docs ────────────────────────────────────────────────────────────
test_prescan_present_ok() {
  _world
  _repo My.App
  mkdir -p "$W/root/.ticket-auto/my-app/docs"
  echo "# index" >"$W/root/.ticket-auto/my-app/docs/INDEX.md"
  [[ "$(_row PRESCAN_DOCS)" == "PRESCAN_DOCS|ok|1 of 1 scanned|$W/root/.ticket-auto|INDEX.md present; freshness not judged"* ]]
}

test_prescan_absent_warns() {
  _world
  _repo app
  _repo web
  mkdir -p "$W/root/.ticket-auto/app/docs"
  echo "# index" >"$W/root/.ticket-auto/app/docs/INDEX.md"
  : >"$W/root/.ticket-auto/web-index-placeholder"
  local row
  row=$(_row PRESCAN_DOCS)
  [[ "$row" == "PRESCAN_DOCS|warn|1 of 2 scanned|"*"no docs/INDEX.md for: web — "* ]] &&
    [[ "$row" == *"/ticket-prescan $W/root/web (once per repo)" ]]
}

test_prescan_no_code_repo_not_applicable() {
  _world
  [[ "$(_row PRESCAN_DOCS)" == "PRESCAN_DOCS|info||$W/root|not applicable: no code repository under REPOS_ROOT" ]]
}

test_long_repo_list_is_capped() {
  _world
  local i
  for i in 1 2 3 4 5 6 7 8; do _repo "svc$i"; done
  [[ "$(_row PRESCAN_DOCS)" == *"svc6 (+2 more) — "* ]]
}

# ── rows as a whole, and env-check.sh ───────────────────────────────────────
test_statuses_are_ok_warn_or_info_and_five_cells() {
  _world
  _repo app
  local bad
  bad=$(_rows | awk -F'|' 'NF != 5 || $2 !~ /^(ok|warn|info)$/' || true)
  [ "$(_rows | wc -l)" -eq 5 ] && [ -z "$bad" ]
}

_env_check() { # prints the summary block; rc in $EC_RC
  EC_RC=0
  EC_OUT=$(cd "$P" && env -u REPOS_ROOT -u PLAYWRIGHT_BROWSERS_PATH -u LINEAR_API_KEY \
    HOME="$W/home" GITNEXUS_REGISTRY="$W/home/.gitnexus/registry.json" \
    READINESS_NPX_CACHE="$W/home/.npm/_npx" ENV_CHECK_SKIP_LINEAR=1 \
    ENV_CHECK_USER_SKILLS_DIR="$W/home/noskills" \
    bash "$LIB_DIR/env-check.sh" "$P" 2>/dev/null) || EC_RC=$?
}

test_env_check_reports_the_five_rows() {
  _world
  _repo app
  _env_check
  local n rows
  rows=$(sed -n '/^---BEGIN_VARS---$/,/^---END_VARS---$/p' <<<"$EC_OUT" | grep -vE '^(---|NAME\||ROWCOUNT=)')
  n=$(grep '^ROWCOUNT=' <<<"$EC_OUT" | cut -d= -f2)
  [ "$(wc -l <<<"$rows")" -eq "$n" ] &&
    grep -q '^VERIFY_ENV_START|warn|' <<<"$rows" &&
    grep -q '^PLAYWRIGHT_MCP|warn|' <<<"$rows" &&
    grep -q '^PLAYWRIGHT_BROWSER|info|' <<<"$rows" &&
    grep -q '^GITNEXUS_INDEX|warn|' <<<"$rows" &&
    grep -q '^PRESCAN_DOCS|warn|' <<<"$rows"
}

# A warn row is never an env-check issue: the exit code (the issue count) is
# the same with every gap open as with every gap closed.
test_env_check_exit_code_ignores_readiness_rows() {
  _world
  _repo app
  _env_check
  local gaps_rc="$EC_RC"
  printf '#!/usr/bin/env bash\n: "$VERIFY_REPO_PATH_APP"\n' >"$P/env-start.sh"
  _mcp '{"command":"npx","args":["@playwright/mcp@1.2.3","--browser","firefox"]}'
  _npx_pkg 1.2.3 firefox 9
  _build firefox-9
  _registry "[{\"path\":\"$W/root/app\"}]"
  mkdir -p "$W/root/.ticket-auto/app/docs"
  echo "# index" >"$W/root/.ticket-auto/app/docs/INDEX.md"
  _env_check
  ! grep -E '^(VERIFY_ENV_START|PLAYWRIGHT_MCP|PLAYWRIGHT_BROWSER|GITNEXUS_INDEX|PRESCAN_DOCS)\|(warn|info|missing)\|' <<<"$EC_OUT" &&
    [ "$gaps_rc" -eq "$EC_RC" ]
}

test_validate_mode_warns_without_failing() {
  _world
  local out
  out=$(cd "$P" && env -u REPOS_ROOT HOME="$W/home" GITNEXUS_REGISTRY="$W/none.json" \
    ENV_CHECK_JGIT_LOCK_ROOT="$W/home" ENV_CHECK_USER_SKILLS_DIR="$W/home/noskills" \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$P" 2>&1) || true
  grep -q 'warn.*VERIFY_ENV_START.*env-start.sh not found' <<<"$out" &&
    grep -q 'warn.*PLAYWRIGHT_MCP' <<<"$out" &&
    ! grep -q 'MISS.*\(VERIFY_ENV_START\|PLAYWRIGHT\|GITNEXUS\|PRESCAN\)' <<<"$out"
}

# fleetd refuses to boot on a fleet-env-check.sh failure. That gate must stay
# independent of these rows: it neither runs env-check.sh nor this file.
test_fleetd_boot_gate_does_not_read_these_rows() {
  local f="$REPO_ROOT/fleet-controller/lib/fleet-env-check.sh" m="$REPO_ROOT/fleet-controller/fleetd/__main__.py"
  [ -f "$f" ] && [ -f "$m" ] || return 0
  ! grep -q 'readiness-env-check' "$f" "$m" &&
    ! grep -v '^[[:space:]]*#' "$f" | grep 'env-check\.sh' | grep -vq 'fleet-env-check\.sh' &&
    ! grep 'env-check\.sh' "$m" | grep -vq 'fleet-env-check\.sh'
}

FILTER="${1:-}"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  [ -z "$FILTER" ] || [[ "$t" == *"$FILTER"* ]] || continue
  _run "$t" "$t"
done

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
