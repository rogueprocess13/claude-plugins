#!/usr/bin/env bash
# verify-worktree.sh — git worktree isolation for ticket-verify.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling — mirrors lib/worktree.sh's convention).
#
# ticket-verify previously ran services and browser checks directly against
# the shared repo clones under REPOS_ROOT — whatever branch happened to be
# checked out there at verify time is what actually got exercised, with
# nothing tying a verify run to the ticket branch it was meant to test. This
# library gives ticket-verify its own per-ticket, per-repo worktree, deliberately
# separate from lib/worktree.sh's implement-phase worktrees
# (REPOS_ROOT/.ticket-auto/worktrees/{TICKET_ID}/{repo-slug}): verify must
# never read a directory implement might still be actively writing to, and
# a verify worktree always re-syncs to the branch's current remote tip on
# every reuse (see ensure_verify_worktree), where an implement worktree
# deliberately preserves local working-tree state between reuses.
#
# Path formula: $REPOS_ROOT/.verify-worktrees/{repo-slug}/{TICKET_ID}
#
# Dependencies: config.sh (for $REPOS_ROOT, $VERIFY_WORKTREE_TTL_HOURS).
# Best-effort dependency on lib/verify-lock.sh for verify_worktree_gc's
# lock-aware guard (see below) — sourced lazily if verify_lock_status isn't
# already defined, and the guard simply no-ops if it still can't be found.
#
# Usage:
#   source lib/verify-worktree.sh
#   verify_worktree_gc                                          # opportunistic TTL sweep
#   path=$(ensure_verify_worktree "CRE-123" "/path/to/repo" "feat/CRE-123-fix")
#   verify_env_init "TICKET-1" ./CLAUDE.md                      # REPOS_ROOT in a fresh shell
#   eval "$(verify_worktree_exports "CRE-123")"                 # env-start.sh contract
#   verify_served_worktree_check "CRE-123" "$(verify_url_port "$LOCAL_URL")"
#   verify_served_check_ports "TICKET-1" $(verify_served_ports "$LOCAL_URL" "$VERIFY_SERVED_PORTS")
#   bash verify-worktree.sh served 3000                         # CLI for env-status.sh
#   release_verify_worktree "CRE-123"
#   verify_worktree_gc

if ! declare -f verify_lock_status >/dev/null 2>&1; then
  _verify_worktree_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -n "$_verify_worktree_lib_dir" ] && [ -f "$_verify_worktree_lib_dir/verify-lock.sh" ]; then
    # shellcheck disable=SC1091
    source "$_verify_worktree_lib_dir/verify-lock.sh" 2>/dev/null || true
  fi
  unset _verify_worktree_lib_dir
fi

# Gitignored env-file mirroring (worker/.env, .env.local, ...) is shared with
# implement's lib/worktree.sh, including #408's relative-path pinning, so a
# verify worktree carries the same runtime config an implement worktree
# would. Without it a dev server started from the verify worktree silently
# runs with missing config — and the reuse path's `clean -fdx` wipes any
# earlier copy on every resync.
if ! declare -f _mirror_gitignored_env_files >/dev/null 2>&1; then
  _verify_worktree_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -n "$_verify_worktree_lib_dir" ] && [ -f "$_verify_worktree_lib_dir/worktree.sh" ]; then
    # shellcheck disable=SC1091
    source "$_verify_worktree_lib_dir/worktree.sh" 2>/dev/null || true
  fi
  unset _verify_worktree_lib_dir
fi

# ── Internal helpers ─────────────────────────────────────────────────────────

# Portable mtime (seconds since epoch) — GNU stat then BSD/macOS stat.
_verify_worktree_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Marks a worktree as "just used" independent of whatever git itself did or
# didn't touch on disk. `git reset --hard`/`clean -fdx` (ensure_verify_worktree's
# reuse path) mutate files inside the worktree, but git's own bookkeeping for
# a linked worktree lives under the main repo's .git/worktrees/<name>/, not
# under the worktree root itself — so unless a reset happens to rewrite a
# file directly at the worktree's top level (uncommon), the worktree root
# directory's own mtime can sit frozen at its original `git worktree add`
# creation time no matter how many times it's legitimately reused. A ticket
# iterated across more than VERIFY_WORKTREE_TTL_HOURS (ordinary for one
# gated on human review/PR feedback) would then look idle to
# verify_worktree_gc while being actively reused. Called at the top of
# every ensure_verify_worktree success path, so "last used" always reflects
# reality regardless of git's incidental side effects.
_verify_worktree_touch() {
  touch "$1" 2>/dev/null || true
}

# Mirrors the primary checkout's gitignored env files into the worktree
# (no-op when lib/worktree.sh could not be loaded).
_verify_worktree_mirror_env() {
  if declare -f _mirror_gitignored_env_files >/dev/null 2>&1; then
    _mirror_gitignored_env_files "$1" "$2"
  fi
  return 0
}

# Removes a single worktree directory: detaches it from its origin repo via
# `git worktree remove` when possible, then deletes the directory outright.
# Non-fatal — failures warn but never exit non-zero (cleanup, not a
# correctness requirement).
_verify_worktree_remove_one() {
  local wt_dir="$1"
  [ -d "$wt_dir" ] || return 0

  if [ -f "$wt_dir/.git" ] || [ -d "$wt_dir/.git" ]; then
    local repo_path
    repo_path=$(git -C "$wt_dir" rev-parse --git-common-dir 2>/dev/null | sed 's|/.git/worktrees/.*||' || true)
    if [ -n "$repo_path" ] && [ -d "$repo_path" ]; then
      git -C "$repo_path" worktree remove "$wt_dir" --force 2>/dev/null || {
        echo "verify-worktree: failed to remove $wt_dir — continuing" >&2
      }
    fi
  fi

  rm -rf "$wt_dir" 2>/dev/null || true
  return 0
}

# ── Public API ──────────────────────────────────────────────────────────────

# verify_worktree_path <repo_slug> <TICKET_ID>
# Pure path computation — no side effects, no git calls.
# Returns $REPOS_ROOT/.verify-worktrees/{repo-slug}/{TICKET_ID}
verify_worktree_path() {
  local repo_slug="$1"
  local ticket_id="$2"
  echo "${REPOS_ROOT:-.}/.verify-worktrees/${repo_slug}/${ticket_id}"
}

# ensure_verify_worktree <TICKET_ID> <repo_path> <branch>
# Ensures a git worktree exists at the computed path, checked out on <branch>.
# Creates it when absent. Unlike implement's ensure_worktree, a verify
# worktree never brings a branch into existence — verify only ever checks
# out a branch ticket-implement has already pushed, so there is no <base>
# parameter. On reuse (same branch), always fetches and hard-resets to
# origin/<branch> — a verify run must see the latest pushed commits, not
# whatever an earlier attempt happened to leave checked out, since
# ticket-implement can push new commits to the same branch between retries.
# Exits non-zero when present on a different branch (identity guard,
# mirrors implement's worktree — release_verify_worktree first to retarget).
# Prints the resolved worktree path on stdout.
ensure_verify_worktree() {
  local ticket_id="$1"
  local repo_path="$2"
  local branch="$3"

  if [ -z "$ticket_id" ] || [ -z "$repo_path" ] || [ -z "$branch" ]; then
    echo "ensure_verify_worktree: usage: ensure_verify_worktree <TICKET_ID> <repo_path> <branch>" >&2
    return 1
  fi
  if [ ! -d "$repo_path/.git" ] && [ ! -f "$repo_path/.git" ]; then
    echo "ensure_verify_worktree: $repo_path is not a git repo" >&2
    return 1
  fi

  local repo_slug
  repo_slug=$(basename "$repo_path")
  local wt_path
  wt_path=$(verify_worktree_path "$repo_slug" "$ticket_id")

  # Fetch first so both the "reuse" and "create" branches below see the
  # branch's current remote tip.
  git -C "$repo_path" fetch origin "$branch" 2>/dev/null || true

  if [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; then
    local current_branch
    current_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    if [ "$current_branch" != "$branch" ]; then
      echo "verify-worktree: $wt_path exists on branch '$current_branch', expected '$branch' — refusing to reuse; release it first" >&2
      return 2
    fi

    # Reuse: always re-sync to the remote tip. A stale local checkout would
    # silently re-verify an earlier, already-superseded attempt.
    if git -C "$wt_path" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
      git -C "$wt_path" reset --hard "origin/$branch" >/dev/null 2>&1 || {
        echo "verify-worktree: failed to sync $wt_path to origin/$branch" >&2
        return 3
      }
      git -C "$wt_path" clean -fdx >/dev/null 2>&1 || true
    fi

    _verify_worktree_mirror_env "$repo_path" "$wt_path"
    _verify_worktree_touch "$wt_path"
    echo "$wt_path"
    return 0
  fi

  # Doesn't exist — create it. Never brands a new branch: the branch must
  # already exist (locally or on origin) for there to be anything to verify.
  if git -C "$repo_path" rev-parse --verify "$branch" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$wt_path")"
    git -C "$repo_path" worktree add "$wt_path" "$branch" >/dev/null 2>&1 || {
      echo "verify-worktree: failed to create worktree for $branch in $repo_path" >&2
      return 1
    }
  elif git -C "$repo_path" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$wt_path")"
    git -C "$repo_path" worktree add -b "$branch" "$wt_path" "origin/$branch" >/dev/null 2>&1 || {
      echo "verify-worktree: failed to create worktree for origin/$branch in $repo_path" >&2
      return 1
    }
  else
    echo "verify-worktree: branch '$branch' not found locally or on origin for $repo_path — nothing to verify" >&2
    return 1
  fi

  _verify_worktree_mirror_env "$repo_path" "$wt_path"
  _verify_worktree_touch "$wt_path"
  echo "$wt_path"
  return 0
}

# verify_worktree_env_var <repo_slug>
# The env var a repo's verify worktree is exported under: VERIFY_REPO_PATH_<SLUG>,
# slug upper-cased with every char outside [A-Z0-9_] mapped to "_"
# (credit-report -> VERIFY_REPO_PATH_CREDIT_REPORT, ledgerly -> VERIFY_REPO_PATH_LEDGERLY).
verify_worktree_env_var() {
  local slug
  slug=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')
  printf 'VERIFY_REPO_PATH_%s' "$slug"
}

# verify_worktree_exports <TICKET_ID>
# Prints eval-able `export` lines — the contract a consuming workspace's
# env-start.sh reads to serve this ticket's code instead of its primary checkout:
#   VERIFY_TICKET_ID=<TICKET_ID>
#   VERIFY_REPO_PATH_<SLUG>=$REPOS_ROOT/.verify-worktrees/<slug>/<TICKET_ID>
# (one line per verify worktree on disk for this ticket). Derived from the
# deterministic path formula, not from variables exported by an earlier step:
# each SKILL.md bash block runs in a fresh shell, so an `export` in Step 1.6a4
# never reaches the env-start.sh call in Step 1.6b — the values must be
# re-derived in the same shell that runs env-start.sh.
verify_worktree_exports() {
  local ticket_id="$1"
  [ -n "$ticket_id" ] || return 0
  printf 'export VERIFY_TICKET_ID=%q\n' "$ticket_id"

  local root="${REPOS_ROOT:-.}/.verify-worktrees"
  [ -d "$root" ] || return 0
  local wt slug
  for wt in "$root"/*/"$ticket_id"; do
    [ -d "$wt" ] || continue
    [ -e "$wt/.git" ] || continue
    slug=$(basename "$(dirname "$wt")")
    printf 'export %s=%q\n' "$(verify_worktree_env_var "$slug")" "$wt"
  done
  return 0
}

# verify_url_port <url>
# Port of an http(s) URL: the explicit port if present, else 80/443.
# Prints nothing and returns 1 when it cannot be determined.
verify_url_port() {
  local url="$1" port
  # `|` as the s-command delimiter: the pattern itself uses `#` (in [^/:?#]).
  port=$(printf '%s' "$url" | sed -nE 's|^[A-Za-z][A-Za-z0-9+.-]*://([^/@]*@)?[^/:?#]+:([0-9]+).*|\2|p')
  if [ -z "$port" ]; then
    case "$url" in
    https://*) port=443 ;;
    http://*) port=80 ;;
    *) return 1 ;;
    esac
  fi
  printf '%s' "$port"
}

# Every pid listening on a TCP port (a --reload dev server has both parent and
# child on the socket). ss first, lsof as fallback.
_verify_listening_pids() {
  local port="$1" pids=""
  if command -v ss >/dev/null 2>&1; then
    pids=$(ss -ltnpH 2>/dev/null |
      awk -v p="$port" '{ n = split($4, a, ":"); if (a[n] == p) print }' |
      grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)
  fi
  if [ -z "$pids" ] && command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -t -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true)
  fi
  printf '%s' "$pids"
}

# Working directory of a pid (/proc first, lsof as fallback).
_verify_pid_cwd() {
  local pid="$1" cwd=""
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  if [ -z "$cwd" ] && command -v lsof >/dev/null 2>&1; then
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  fi
  printf '%s' "$cwd"
}

# Absolute, symlink-resolved git common dir of a checkout ("" when not a repo).
# Two checkouts of the same repository (primary clone, its linked worktrees)
# share one common dir — that is how "same repo, different checkout" is told
# apart from "an unrelated repo".
_verify_git_common_dir() {
  local d
  d=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$d" in
  /*) ;;
  *) d="$1/$d" ;;
  esac
  (cd "$d" 2>/dev/null && pwd -P) || true
}

# verify_served_worktree_check <TICKET_ID> <port>
# Answers, after env-start.sh, "is the server on <port> serving THIS ticket's
# code?" — which an up/down health check (env-status.sh) cannot. For each pid
# listening on <port>, resolves its cwd to a git checkout and compares it with
# this ticket's verify worktrees (REPOS_ROOT/.verify-worktrees/*/<TICKET_ID>):
#   rc 0 — served from a verify worktree, or from another checkout of the same
#          repo that is clean and on the same commit (prints the served cwd)
#   rc 1 — served from another checkout of a repo under test that is on a
#          different commit or has tracked changes: the run would verify the
#          wrong code (diagnostic on stderr)
#   rc 3 — undeterminable or not applicable: no visible listener, unreadable
#          cwd, cwd outside any git checkout (e.g. a container port), or the
#          served repo is not one this ticket touches
#   rc 4 — nothing to compare against: no verify worktree exists for this
#          ticket under $REPOS_ROOT/.verify-worktrees. After Step 1.6a4 this
#          almost always means REPOS_ROOT is unset or wrong in the calling
#          shell, which also means env-start.sh got no VERIFY_REPO_PATH_*
#          exports. Kept apart from rc 3 so the caller can say so loudly
#          instead of logging a quiet skip.
verify_served_worktree_check() {
  local ticket_id="$1" port="$2"
  if [ -z "$ticket_id" ] || [ -z "$port" ]; then
    echo "verify_served_worktree_check: usage: verify_served_worktree_check <TICKET_ID> <port>" >&2
    return 3
  fi

  local root="${REPOS_ROOT:-.}/.verify-worktrees"
  local -a exp_top=() exp_common=() exp_sha=()
  local wt
  for wt in "$root"/*/"$ticket_id"; do
    [ -e "$wt/.git" ] || continue
    exp_top+=("$(cd "$wt" && pwd -P)")
    exp_common+=("$(_verify_git_common_dir "$wt")")
    exp_sha+=("$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)")
  done
  if [ "${#exp_top[@]}" -eq 0 ]; then
    echo "verify-worktree: no verify worktrees for $ticket_id under $root — nothing to compare :$port against (is REPOS_ROOT set in this shell?)" >&2
    return 4
  fi

  local pids
  pids=$(_verify_listening_pids "$port")
  if [ -z "$pids" ]; then
    echo "verify-worktree: no listening process visible on :$port" >&2
    return 3
  fi

  local pid cwd top common sha i mismatch=""
  for pid in $pids; do
    cwd=$(_verify_pid_cwd "$pid")
    [ -n "$cwd" ] || continue
    top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || continue
    [ -n "$top" ] || continue
    top=$(cd "$top" 2>/dev/null && pwd -P) || continue
    common=$(_verify_git_common_dir "$top")
    sha=$(git -C "$top" rev-parse HEAD 2>/dev/null || true)
    for i in "${!exp_top[@]}"; do
      if [ "$top" = "${exp_top[$i]}" ]; then
        echo "$cwd"
        return 0
      fi
      if [ -z "$common" ] || [ "$common" != "${exp_common[$i]}" ]; then
        continue
      fi
      if [ -n "$sha" ] && [ "$sha" = "${exp_sha[$i]}" ] &&
        [ -z "$(git -C "$top" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "$cwd"
        return 0
      fi
      mismatch="pid $pid on :$port serves $cwd (checkout $top @ ${sha:0:12}), expected ${exp_top[$i]} @ ${exp_sha[$i]:0:12}"
    done
  done

  if [ -n "$mismatch" ]; then
    echo "verify-worktree: wrong checkout served — $mismatch" >&2
    return 1
  fi
  echo "verify-worktree: :$port is not served from a checkout of any repo under test for $ticket_id" >&2
  return 3
}

# verify_env_init <TICKET_ID> [claude_md]
# Every function in this file derives worktree paths from REPOS_ROOT, and every
# SKILL.md bash block is a fresh shell, so REPOS_ROOT is not guaranteed to be
# set there. When it is unset, verify_worktree_exports prints no
# VERIFY_REPO_PATH_* line (env-start.sh serves the primary checkout) and
# verify_served_worktree_check finds nothing to compare against — the exact
# silent wrong-worktree run the check exists to catch. Resolves, first match
# wins: an already-set REPOS_ROOT; the REPOS_ROOT line of the ticket's env file
# (/tmp/ticket-auto-<TID>-env.sh, written by spawn_write_env — read, never
# sourced, so nothing else in it leaks into the caller); the project CLAUDE.md's
# REPOS_ROOT field. Also fills VERIFY_SERVED_PORTS from the CLAUDE.md field
# when the environment does not set it. Exports both.
# rc 0 when REPOS_ROOT resolves to an existing directory, 1 otherwise.
verify_env_init() {
  local ticket_id="$1" claude_md="${2:-./CLAUDE.md}" val=""

  if [ -z "${REPOS_ROOT:-}" ] && [ -n "$ticket_id" ]; then
    local env_file="/tmp/ticket-auto-${ticket_id}-env.sh"
    if [ -f "$env_file" ]; then
      val=$(sed -n 's/^export REPOS_ROOT="\(.*\)"$/\1/p' "$env_file" 2>/dev/null | head -1)
      case "$val" in
      '' | REPOS_ROOT_PLACEHOLDER) val="" ;;
      esac
      [ -n "$val" ] && REPOS_ROOT="$val"
    fi
  fi

  if ! declare -f claude_md_field >/dev/null 2>&1; then
    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    # shellcheck disable=SC1091
    [ -n "$_lib_dir" ] && [ -f "$_lib_dir/claude-md-field.sh" ] && source "$_lib_dir/claude-md-field.sh"
  fi

  if [ -z "${REPOS_ROOT:-}" ] && declare -f claude_md_field >/dev/null 2>&1; then
    val=$(claude_md_field "$claude_md" REPOS_ROOT 2>/dev/null) || val=""
    case "$val" in
    "~"/*) val="$HOME/${val#"~/"}" ;;
    esac
    [ -n "$val" ] && REPOS_ROOT="$val"
  fi

  if [ -z "${VERIFY_SERVED_PORTS:-}" ] && declare -f claude_md_field >/dev/null 2>&1; then
    val=$(claude_md_field "$claude_md" VERIFY_SERVED_PORTS 2>/dev/null) || val=""
    [ -n "$val" ] && VERIFY_SERVED_PORTS="$val"
  fi
  export VERIFY_SERVED_PORTS="${VERIFY_SERVED_PORTS:-}"

  if [ -z "${REPOS_ROOT:-}" ] || [ ! -d "$REPOS_ROOT" ]; then
    echo "verify-worktree: REPOS_ROOT unresolved ('${REPOS_ROOT:-}') — set it in the environment, the ticket env file, or $claude_md" >&2
    return 1
  fi
  export REPOS_ROOT
  return 0
}

# verify_served_ports <spec>...
# Normalises port specs to a deduplicated, space-separated port list. Each
# argument may hold several items separated by commas or whitespace; an item is
# a bare port (3000) or an http(s) URL (http://localhost:3000, whose port is
# taken via verify_url_port). Unparseable items are reported on stderr and
# dropped. Typical call: verify_served_ports "$LOCAL_URL" "$VERIFY_SERVED_PORTS"
# — LOCAL_URL's port plus any extra project-declared ports (an API server, a
# separately served worker health port) that must also run this ticket's code.
verify_served_ports() {
  local arg item port out=" "
  for arg in "$@"; do
    for item in $(printf '%s' "$arg" | tr ',' ' '); do
      case "$item" in
      *[!0-9]*) port=$(verify_url_port "$item") || port="" ;;
      *) port="$item" ;;
      esac
      case "$port" in
      '' | *[!0-9]*)
        echo "verify-worktree: ignoring unparseable served-port item '$item'" >&2
        continue
        ;;
      esac
      case "$out" in
      *" $port "*) ;;
      *) out="$out$port " ;;
      esac
    done
  done
  out="${out# }"
  printf '%s' "${out% }"
}

# verify_served_check_ports <TICKET_ID> <primary_port> [<port>...]
# verify_served_worktree_check over several ports, folded into one verdict and
# one single-line summary on stdout (safe to drop into a pipeline log MSG):
#   ":3000 ok <cwd>; :8080 wrong <diagnostic>; :9000 undetermined <diagnostic>"
# The FIRST port is the primary one (LOCAL_URL's — what the browser checks
# actually hit); the rest are extras from VERIFY_SERVED_PORTS. An extra port
# that serves the right code says nothing about the primary one, so it can
# never stand in for it.
# Return code, most severe first:
#   4 — no verify worktrees for this ticket (nothing to compare; see above)
#   1 — any port serves another checkout of a repo under test
#   0 — the primary port serves this ticket's code and no port serves another's
#   3 — the primary port could not be decided (or no ports were given)
verify_served_check_ports() {
  local ticket_id="$1"
  shift || true
  local -a parts=()
  local port msg rc primary="${1:-}" primary_ok=0 any_wrong=0
  if [ "$#" -eq 0 ]; then
    echo "no ports to check (LOCAL_URL has no resolvable port and VERIFY_SERVED_PORTS is empty)"
    return 3
  fi
  for port in "$@"; do
    rc=0
    msg=$(verify_served_worktree_check "$ticket_id" "$port" 2>&1) || rc=$?
    msg=$(printf '%s' "$msg" | sed 's/^verify-worktree: //' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    case "$rc" in
    0)
      parts+=(":$port ok $msg")
      [ "$port" = "$primary" ] && primary_ok=1
      ;;
    1)
      parts+=(":$port wrong $msg")
      any_wrong=1
      ;;
    4)
      echo "$msg"
      return 4
      ;;
    *) parts+=(":$port undetermined $msg") ;;
    esac
  done
  local IFS=';'
  msg="${parts[*]}"
  printf '%s\n' "${msg//;/; }"
  [ "$any_wrong" -eq 1 ] && return 1
  [ "$primary_ok" -eq 1 ] && return 0
  return 3
}

# verify_served_report <port|url>...
# Human-readable "what is actually being served" report — one line per
# listening pid: port, pid, cwd, checkout root, branch, short sha and a dirty
# marker. Meant for a project's env-status.sh (which otherwise reports only
# up/down) via the CLI below: `bash verify-worktree.sh served 3000 8080`.
# Always returns 0; a port with no visible listener says so.
verify_served_report() {
  local port pid cwd top branch sha dirty
  for port in $(verify_served_ports "$@"); do
    local pids
    pids=$(_verify_listening_pids "$port")
    if [ -z "$pids" ]; then
      echo ":$port no listening process visible"
      continue
    fi
    for pid in $pids; do
      cwd=$(_verify_pid_cwd "$pid")
      if [ -z "$cwd" ]; then
        echo ":$port pid=$pid cwd=unreadable"
        continue
      fi
      top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || top=""
      if [ -z "$top" ]; then
        echo ":$port pid=$pid cwd=$cwd checkout=none"
        continue
      fi
      branch=$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
      sha=$(git -C "$top" rev-parse --short=12 HEAD 2>/dev/null || echo "?")
      dirty=""
      [ -n "$(git -C "$top" status --porcelain --untracked-files=no 2>/dev/null)" ] && dirty=" dirty"
      echo ":$port pid=$pid cwd=$cwd checkout=$top branch=$branch sha=$sha$dirty"
    done
  done
  return 0
}

# release_verify_worktree <TICKET_ID>
# Removes all verify worktrees for a ticket, across every repo. Idempotent —
# safe to call multiple times. Not called automatically after a normal
# verify run (worktrees are left in place for debugging/reuse and reaped by
# verify_worktree_gc's TTL instead) — this is for explicit/manual cleanup.
release_verify_worktree() {
  local ticket_id="$1"
  local root="${REPOS_ROOT:-.}/.verify-worktrees"

  [ -n "$ticket_id" ] || return 0
  [ -d "$root" ] || return 0

  for repo_dir in "$root"/*/; do
    [ -d "$repo_dir" ] || continue
    local wt_dir="${repo_dir}${ticket_id}"
    [ -d "$wt_dir" ] || continue
    _verify_worktree_remove_one "$wt_dir"
    rmdir "$repo_dir" 2>/dev/null || true
  done

  git worktree prune 2>/dev/null || true
  return 0
}

# verify_worktree_gc
# Age-based sweep of $REPOS_ROOT/.verify-worktrees — removes any
# {repo-slug}/{TICKET_ID} directory whose mtime exceeds
# VERIFY_WORKTREE_TTL_HOURS (default 24, matching the pipeline's other
# scratch-file TTL default). Mirrors hooks/tmp-sweep.sh's age-based
# approach rather than querying Linear ticket state, so it stays a cheap,
# zero-network, zero-LLM opportunistic call ticket-verify can make on every
# invocation (see SKILL.md Step 1.6a2) instead of a separate scheduled hook.
# `ensure_verify_worktree` touching the worktree root on every successful
# use (see _verify_worktree_touch) is what makes the TTL a reliable signal
# in the first place — git's own reset/clean side effects don't reliably
# advance a linked worktree's own directory mtime. As a second, independent
# guard: if the single-flight verify lock is currently held by ANYONE, skip
# the whole sweep rather than remove anything. There's no way to tell from
# here which specific ticket's worktree a live holder might be serving
# files from — the lock is one global flight, not per-ticket — so the safe
# rule under contention is to touch nothing at all this pass; the next
# opportunistic call (the very next verify run) tries again.
verify_worktree_gc() {
  if declare -f verify_lock_status >/dev/null 2>&1 && verify_lock_status >/dev/null 2>&1; then
    echo "verify-worktree: skipping GC sweep — the verify lock is currently held" >&2
    return 0
  fi

  local root="${REPOS_ROOT:-.}/.verify-worktrees"
  [ -d "$root" ] || return 0

  local ttl_hours="${VERIFY_WORKTREE_TTL_HOURS:-24}"
  case "$ttl_hours" in
  '' | *[!0-9]*) ttl_hours=24 ;;
  esac
  local cutoff
  cutoff=$(($(date +%s) - ttl_hours * 3600))

  local removed=0
  for repo_dir in "$root"/*/; do
    [ -d "$repo_dir" ] || continue
    for wt_dir in "$repo_dir"*/; do
      [ -d "$wt_dir" ] || continue
      local mtime
      mtime=$(_verify_worktree_mtime "$wt_dir")
      if [ "$mtime" -lt "$cutoff" ]; then
        _verify_worktree_remove_one "$wt_dir"
        removed=$((removed + 1))
      fi
    done
    rmdir "$repo_dir" 2>/dev/null || true
  done

  git worktree prune 2>/dev/null || true

  [ "$removed" -gt 0 ] && echo "verify-worktree: swept $removed stale worktree(s) older than ${ttl_hours}h" >&2
  return 0
}

# ── CLI ─────────────────────────────────────────────────────────────────────
# Lets a project's own scripts (env-status.sh, env-start.sh) ask the same
# question ticket-verify asks, without re-implementing the pid -> cwd ->
# checkout resolution:
#   bash verify-worktree.sh served <port|url>...            # report, always rc 0
#   bash verify-worktree.sh check <TICKET_ID> <port|url>... # rc as verify_served_check_ports
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  served)
    shift
    verify_served_report "$@"
    ;;
  check)
    shift
    _vw_tid="${1:-}"
    shift || true
    if [ -z "$_vw_tid" ]; then
      echo "usage: verify-worktree.sh check <TICKET_ID> <port|url>..." >&2
      exit 2
    fi
    verify_env_init "$_vw_tid" || true
    # shellcheck disable=SC2046
    verify_served_check_ports "$_vw_tid" $(verify_served_ports "$@")
    exit $?
    ;;
  *)
    echo "usage: verify-worktree.sh served <port|url>... | check <TICKET_ID> <port|url>..." >&2
    exit 2
    ;;
  esac
fi
