#!/usr/bin/env bash
# readiness-env-check.sh — the run-readiness rows of ticket-env-check (GitHub
# #772): four things a run needs that are not env vars or CLAUDE.md fields,
# and that used to be discovered only when a phase failed.
#
# readiness_env_check_rows <project dir>
#   Prints one `NAME|STATUS|VALUE|LOCATION|NOTE` row per check. STATUS is only
#   `ok`, `warn` or `info` (not applicable / not checkable): none of these
#   stops every ticket, so none is ever an env-check issue. Prints nothing
#   when <project dir> has no CLAUDE.md. Rows:
#     VERIFY_ENV_START    <project dir>/env-start.sh, which ticket-verify
#                         Step 1.6 runs for browser and live-backend tickets
#     PLAYWRIGHT_MCP      an MCP server keyed `playwright` is configured
#     PLAYWRIGHT_BROWSER  the browser that server is configured to launch
#     GITNEXUS_INDEX      code repos under REPOS_ROOT in the GitNexus registry
#     PRESCAN_DOCS        code repos with .ticket-auto/<slug>/docs/INDEX.md
#
# Read-only and bounded: nothing is started, indexed, scanned or installed;
# each outside command runs under `timeout`. What bash cannot see is said in
# the row instead of being reported `ok`:
#   - whether env-start.sh brings the stack up (it is never run)
#   - whether an MCP server is connected in the agent's session
#   - the browser revision, unless the server is an exactly pinned
#     `@playwright/mcp@X.Y.Z` whose package is in the npx cache
#   - whether an index or the prescan docs are fresh (prescan-sweep.sh does
#     the docs; `gitnexus status` the index)
#
# Test and host overrides: GITNEXUS_REGISTRY, PLAYWRIGHT_BROWSERS_PATH,
# READINESS_NPX_CACHE, READINESS_BROWSER_BINS (space-separated command names
# and absolute paths that replace the built-in channel list).
#
# Sourceable: sets no shell options. Always returns 0.

_RDY_EC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f claude_md_field >/dev/null 2>&1 ||
  source "$_RDY_EC_DIR/claude-md-field.sh"
declare -f verify_preflight_playwright_server >/dev/null 2>&1 ||
  source "$_RDY_EC_DIR/verify-preflight.sh"

_rdy_row() {
  # No pipe or newline may reach a cell: the table is pipe-delimited.
  local IFS='|'
  local cells=("${@//|/ }")
  cells=("${cells[@]//$'\n'/ }")
  printf '%s\n' "${cells[*]}"
}

# _rdy_names <max> <name>... — "a, b, c (+2 more)"
_rdy_names() {
  local max="$1" out="" n=0
  shift
  local total=$# name
  for name in "$@"; do
    n=$((n + 1))
    [ "$n" -le "$max" ] || break
    out="${out:+$out, }$name"
  done
  [ "$total" -le "$max" ] || out="$out (+$((total - max)) more)"
  printf '%s\n' "$out"
}

# ── env-start.sh ────────────────────────────────────────────────────────────
_rdy_env_start() {
  local dir="$1" f="$1/env-start.sh"
  local needs="ticket-verify Step 1.6 runs it for browser and live-backend tickets (build-only tickets, --env=uat and --no-env-start do not)"
  if [ ! -e "$f" ]; then
    _rdy_row VERIFY_ENV_START warn "" "$dir" \
      "env-start.sh not found at the tickets root: verify-env-up.sh exits 127 and verify cannot start the app. $needs. Add an env-start.sh that starts the local stack and reads VERIFY_REPO_PATH_<REPO>"
  elif [ ! -f "$f" ] || [ ! -r "$f" ]; then
    _rdy_row VERIFY_ENV_START warn "unreadable" "$f" "env-start.sh is not a readable file. $needs"
  elif ! timeout -k 2 5 bash -n "$f" >/dev/null 2>&1; then
    _rdy_row VERIFY_ENV_START warn "syntax error" "$f" "env-start.sh fails bash -n: verify cannot start the app. Fix it: bash -n $f"
  elif ! grep -q 'VERIFY_REPO_PATH' "$f" 2>/dev/null; then
    _rdy_row VERIFY_ENV_START warn "present" "$f" \
      "env-start.sh does not read VERIFY_REPO_PATH_* — it will serve the primary checkout and ticket-verify will gate-stop VERIFY_SERVED_WRONG_WORKTREE"
  else
    _rdy_row VERIFY_ENV_START ok "present" "$f" \
      "env-start.sh reads VERIFY_REPO_PATH_* (not run here: whether the stack comes up is known only at verify)"
  fi
}

# ── Playwright ──────────────────────────────────────────────────────────────
# _rdy_pw_revision <server json> <browser> — the browser revision an exactly
# pinned npx `@playwright/mcp@X.Y.Z` needs, from the copy in the npx cache.
# Prints "<version> <revision>"; rc 1 when it cannot be known without running.
_rdy_pw_revision() {
  local server="$1" browser="$2" ver cache pkg bj rev
  ver=$(jq -r '[(.command // ""), (.args // [])[]] | map(strings
      | capture("@playwright/mcp@(?<v>[0-9]+\\.[0-9]+\\.[0-9]+[0-9A-Za-z.+-]*)$").v) | first // empty' \
    <<<"$server" 2>/dev/null)
  [ -n "$ver" ] || return 1
  cache="${READINESS_NPX_CACHE:-${npm_config_cache:-$HOME/.npm}/_npx}"
  for pkg in "$cache"/*/node_modules/@playwright/mcp/package.json; do
    [ -f "$pkg" ] || continue
    [ "$(jq -r '.version // empty' "$pkg" 2>/dev/null)" = "$ver" ] || continue
    bj="${pkg%/@playwright/mcp/package.json}/playwright-core/browsers.json"
    rev=$(jq -r --arg b "$browser" '.browsers[]? | select(.name == $b) | .revision' "$bj" 2>/dev/null | head -1)
    [ -n "$rev" ] || continue
    printf '%s %s\n' "$ver" "$rev"
    return 0
  done
  return 1
}

_rdy_playwright() {
  local dir="$1" src server
  if ! command -v jq >/dev/null 2>&1; then
    _rdy_row PLAYWRIGHT_MCP info "" "PATH" "jq not installed — not checked"
    _rdy_row PLAYWRIGHT_BROWSER info "" "PATH" "jq not installed — not checked"
    return 0
  fi
  if ! src=$(verify_preflight_playwright_source "$dir" 2>/dev/null); then
    _rdy_row PLAYWRIGHT_MCP warn "" ".mcp.json" \
      "no MCP server named 'playwright' in .mcp.json, ~/.claude.json or ~/.claude/settings.json: browser-mode verify has no mcp__playwright__* tools (build-only and live-backend tickets do not need it). Add one, e.g. claude mcp add playwright -- npx -y @playwright/mcp@latest"
    _rdy_row PLAYWRIGHT_BROWSER info "" ".mcp.json" "not checked: no playwright MCP server configured"
    return 0
  fi
  _rdy_row PLAYWRIGHT_MCP ok "configured" "$src" \
    "config only: whether the server is connected in the agent session cannot be seen from a shell"

  server=$(verify_preflight_playwright_server "$dir" 2>/dev/null) || server=""
  if ! jq -e 'objects' <<<"$server" >/dev/null 2>&1; then
    _rdy_row PLAYWRIGHT_BROWSER info "" "$src" "not checked: the playwright server entry is not an object"
    return 0
  fi
  local remote
  remote=$(jq -r 'if (.url // "") != "" or ((.type // "stdio") | test("^(http|sse)$"))
      or ((.args // []) | map(strings) | any(test("^--(cdp-endpoint|extension)(=|$)")))
    then "yes" else "no" end' <<<"$server" 2>/dev/null)
  if [ "$remote" = yes ]; then
    _rdy_row PLAYWRIGHT_BROWSER info "" "$src" \
      "not applicable: the server is remote or attaches to a running browser, so no browser is launched from this host's install"
    return 0
  fi

  local browser from="default"
  browser=$(jq -r '(.args // []) | map(strings) as $a
    | ([range(0; $a | length) | select($a[.] == "--browser") | $a[. + 1] // empty] | first)
      // ([$a[] | select(startswith("--browser=")) | ltrimstr("--browser=")] | first)
      // empty' <<<"$server" 2>/dev/null)
  [ -n "$browser" ] && from="--browser"
  if [ -z "$browser" ]; then
    browser=$(jq -r '.env.PLAYWRIGHT_MCP_BROWSER // empty' <<<"$server" 2>/dev/null)
    [ -n "$browser" ] && from="PLAYWRIGHT_MCP_BROWSER"
  fi
  local cfg_note=""
  if [ -z "$browser" ]; then
    browser="chrome"
    jq -e '(.args // []) | map(strings) | any(test("^--config(=|$)"))' <<<"$server" >/dev/null 2>&1 &&
      cfg_note=" (the server has a --config file, which is not read here and may name another browser)"
  fi
  browser=$(printf '%s' "$browser" | tr '[:upper:]' '[:lower:]')

  local install
  install=$(jq -r '[(.command // ""), ((.args // [])[] | strings)]
    | (map(select(test("@playwright/mcp(@|$)"))) | first) as $p
    | if .[0] == "npx" and $p then "npx -y \($p) install-browser" else "npx -y @playwright/mcp@latest install-browser" end' \
    <<<"$server" 2>/dev/null)
  [ -n "$install" ] || install="npx -y @playwright/mcp@latest install-browser"

  case "$browser" in
  chromium | firefox | webkit)
    local cache
    cache=$(jq -r '.env.PLAYWRIGHT_BROWSERS_PATH // empty' <<<"$server" 2>/dev/null)
    [ -n "$cache" ] || cache="${PLAYWRIGHT_BROWSERS_PATH:-}"
    if [ -z "$cache" ]; then
      cache="$HOME/.cache/ms-playwright"
      [ -d "$cache" ] || [ ! -d "$HOME/Library/Caches/ms-playwright" ] || cache="$HOME/Library/Caches/ms-playwright"
    fi
    local have=() d rev="" ver=""
    for d in "$cache/$browser"-[0-9]* "$cache/${browser}_headless_shell"-[0-9]*; do
      [ -d "$d" ] && have+=("${d##*-}")
    done
    if read -r ver rev < <(_rdy_pw_revision "$server" "$browser"); then :; else rev=""; fi
    if [ -n "$rev" ]; then
      if [ -d "$cache/$browser-$rev" ] || [ -d "$cache/${browser}_headless_shell-$rev" ]; then
        _rdy_row PLAYWRIGHT_BROWSER ok "$browser $rev" "$cache" "the build @playwright/mcp@$ver launches is installed"
      else
        _rdy_row PLAYWRIGHT_BROWSER warn "$browser" "$cache" \
          "@playwright/mcp@$ver needs $browser build $rev, which is not installed (found: ${have[*]:-none}): browser-mode verify fails 'Browser \"$browser\" is not installed'. Run: $install $browser"
      fi
    elif [ ${#have[@]} -eq 0 ]; then
      _rdy_row PLAYWRIGHT_BROWSER warn "$browser" "$cache" \
        "no $browser build installed: browser-mode verify fails 'Browser \"$browser\" is not installed'. Run: $install $browser"
    else
      _rdy_row PLAYWRIGHT_BROWSER info "$browser (revision not verified)" "$cache" \
        "a $browser build is installed (${have[*]}), but the revision the server needs is known only for an exactly pinned npx @playwright/mcp@X.Y.Z already in the npx cache. If verify reports 'not installed', run: $install $browser"
    fi
    ;;
  chrome* | msedge*)
    local bins found="" b
    if [ -n "${READINESS_BROWSER_BINS+x}" ]; then
      bins="$READINESS_BROWSER_BINS"
    elif [[ "$browser" == chrome* ]]; then
      bins="google-chrome google-chrome-stable google-chrome-beta chrome /opt/google/chrome/chrome"
    else
      bins="microsoft-edge microsoft-edge-stable msedge /opt/microsoft/msedge/msedge"
    fi
    for b in $bins; do
      if [[ "$b" == /* ]]; then
        [ -x "$b" ] && found="$b"
      else
        found=$(command -v "$b" 2>/dev/null || true)
      fi
      [ -z "$found" ] || break
    done
    if [ -z "$found" ] && [[ "$browser" == chrome* ]] && [ -z "${READINESS_BROWSER_BINS+x}" ] &&
      [ -d "/Applications/Google Chrome.app" ]; then
      found="/Applications/Google Chrome.app"
    fi
    if [ -n "$found" ]; then
      _rdy_row PLAYWRIGHT_BROWSER ok "$browser ($from)" "$found" "system browser found${cfg_note}"
    else
      _rdy_row PLAYWRIGHT_BROWSER warn "$browser ($from)" "PATH" \
        "the server launches the system '$browser' channel and none was found${cfg_note}: browser-mode verify fails at its first page. Install it ($install $browser), or pass --browser chromium|firefox and install that build"
    fi
    ;;
  *)
    _rdy_row PLAYWRIGHT_BROWSER info "$browser ($from)" "$src" "not checked: unknown browser name"
    ;;
  esac
}

# ── code repos under REPOS_ROOT ─────────────────────────────────────────────
# Every git repo within three levels (the walk prescan uses), except hidden
# directories (.ticket-auto, .verify-worktrees) and the tickets root itself.
_rdy_repos() {
  local root="$1" tickets="$2" g repo rel real
  tickets=$(cd "$tickets" 2>/dev/null && pwd -P) || tickets=""
  while IFS= read -r -d '' g; do
    repo="${g%/.git}"
    rel="${repo#"$root"/}"
    case "/$rel" in */.*) continue ;; esac
    real=$(cd "$repo" 2>/dev/null && pwd -P) || continue
    [ "$real" != "$tickets" ] || continue
    printf '%s\n' "$real"
  done < <(timeout -k 2 20 find "$root" -maxdepth 3 -name .git -type d -print0 2>/dev/null | LC_ALL=C sort -z)
}

_rdy_norm_url() {
  local u="$1"
  u="${u%.git}"
  u="${u%/}"
  u="${u#*://}"
  u="${u#*@}"
  u="${u/://}"
  printf '%s\n' "$u" | tr '[:upper:]' '[:lower:]'
}

_rdy_gitnexus() {
  local root="$1"
  shift
  local repos=("$@")
  local registry="${GITNEXUS_REGISTRY:-$HOME/.gitnexus/registry.json}"
  local session="whether the gitnexus MCP server is connected in the agent session cannot be seen from a shell"
  local fallback="appraise, implement and PR review fall back to tracing callers by hand"
  if ! command -v jq >/dev/null 2>&1; then
    _rdy_row GITNEXUS_INDEX info "" "$registry" "jq not installed — not checked"
    return 0
  fi
  if ! jq -e 'arrays' "$registry" >/dev/null 2>&1; then
    _rdy_row GITNEXUS_INDEX warn "0 of ${#repos[@]} indexed" "$registry" \
      "no readable GitNexus registry: $fallback. Run: gitnexus analyze <repo path> for each repo (/ticket-prescan does it too)"
    return 0
  fi
  local paths urls repo url missing=() first=""
  paths=$(jq -r '.[] | .path // empty' "$registry" 2>/dev/null |
    while IFS= read -r repo; do (cd "$repo" 2>/dev/null && pwd -P) || true; done)
  urls=$(jq -r '.[] | .remoteUrl // empty' "$registry" 2>/dev/null |
    while IFS= read -r url; do _rdy_norm_url "$url"; done)
  for repo in "${repos[@]}"; do
    grep -qxF -- "$repo" <<<"$paths" && continue
    url=$(timeout -k 2 5 git -C "$repo" config --get remote.origin.url 2>/dev/null || true)
    if [ -n "$url" ] && grep -qxF -- "$(_rdy_norm_url "$url")" <<<"$urls"; then
      continue
    fi
    missing+=("${repo##*/}")
    [ -n "$first" ] || first="$repo"
  done
  local n=${#repos[@]} m=${#missing[@]}
  if [ "$m" -eq 0 ]; then
    _rdy_row GITNEXUS_INDEX ok "$n of $n indexed" "$registry" "freshness not judged; $session"
  else
    _rdy_row GITNEXUS_INDEX warn "$((n - m)) of $n indexed" "$registry" \
      "not indexed: $(_rdy_names 6 "${missing[@]}") — $fallback. Run: gitnexus analyze $first (once per repo; /ticket-prescan does it too)"
  fi
}

_rdy_prescan() {
  local root="$1"
  shift
  local repos=("$@") repo slug missing=() first=""
  for repo in "${repos[@]}"; do
    slug=$(basename "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
    [ -s "$root/.ticket-auto/$slug/docs/INDEX.md" ] && continue
    missing+=("${repo##*/}")
    [ -n "$first" ] || first="$repo"
  done
  local n=${#repos[@]} m=${#missing[@]}
  if [ "$m" -eq 0 ]; then
    _rdy_row PRESCAN_DOCS ok "$n of $n scanned" "$root/.ticket-auto" \
      "INDEX.md present; freshness not judged here (prescan-sweep.sh --repos-root $root)"
  else
    _rdy_row PRESCAN_DOCS warn "$((n - m)) of $n scanned" "$root/.ticket-auto" \
      "no docs/INDEX.md for: $(_rdy_names 6 "${missing[@]}") — appraise Step 3a has no agent-knowledge docs, and a headless run cannot build them. Run interactively: /ticket-prescan $first (once per repo)"
  fi
}

readiness_env_check_rows() {
  local dir="${1:-$PWD}"
  [ -f "$dir/CLAUDE.md" ] || return 0
  dir=$(cd "$dir" && pwd)

  _rdy_env_start "$dir"
  _rdy_playwright "$dir"

  local root="${REPOS_ROOT:-}"
  [ -n "$root" ] || root=$(claude_md_field "$dir/CLAUDE.md" REPOS_ROOT 2>/dev/null) || root=""
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    _rdy_row GITNEXUS_INDEX info "" "CLAUDE.md" "not checked: REPOS_ROOT is not set or not a directory"
    _rdy_row PRESCAN_DOCS info "" "CLAUDE.md" "not checked: REPOS_ROOT is not set or not a directory"
    return 0
  fi
  root=$(cd "$root" && pwd)
  local repos=() r
  while IFS= read -r r; do
    [ -n "$r" ] && repos+=("$r")
  done < <(_rdy_repos "$root" "$dir")
  if [ ${#repos[@]} -eq 0 ]; then
    _rdy_row GITNEXUS_INDEX info "" "$root" "not applicable: no code repository under REPOS_ROOT"
    _rdy_row PRESCAN_DOCS info "" "$root" "not applicable: no code repository under REPOS_ROOT"
    return 0
  fi
  _rdy_gitnexus "$root" "${repos[@]}"
  _rdy_prescan "$root" "${repos[@]}"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  readiness_env_check_rows "${1:-$PWD}"
fi
