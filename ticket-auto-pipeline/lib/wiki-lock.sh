#!/usr/bin/env bash
# wiki-lock.sh — cross-process write lock and scoped commit for WIKI_ROOT.
#
# WIKI_ROOT is one docs repo shared by every concurrent fleet worker on the
# host. Two tickets' MAINTENANCE phases running wiki-maintenance at the same
# time used to have nothing serialising them: the second run could edit files
# the first had changed but not yet committed, and Step 4's
# `git -C "$WIKI_ROOT" add -A` would then commit the other ticket's half-done
# edits under the wrong ticket's message. The only thing that ever prevented
# it was an agent happening to notice the dirty tree and choosing to wait.
#
# Why a lock *directory* and not flock: wiki-maintenance runs as many separate
# Bash tool calls, each its own process. A flock taken in one call is released
# the moment that call exits, so it cannot cover the edit -> lint -> commit
# window. `mkdir` is atomic and the directory outlives the process that made
# it. flock is still used, but only around the few-millisecond
# check-and-take critical section inside a single call (so two waiters cannot
# both break the same stale lock).
#
# Ownership is the ticket id, not a pid: the pid of a Bash tool call is dead
# before the next call starts, so it says nothing about whether the run is
# still alive. A holder that crashed is detected by age instead
# (WIKI_LOCK_STALE_SECS since the owner last acquired or refreshed). The same
# ticket re-acquiring is a refresh, which is what lets a resumed run continue
# and lets Step 4 prove it still owns the lock just before committing.
#
# The scoped commit is the second, independent layer: at acquire time the lock
# records a baseline of every path already dirty in WIKI_ROOT (another
# ticket's errata appends, a crashed run's leftovers). `commit` stages and
# commits only paths that are new or changed since that baseline, and passes
# them as an explicit pathspec, so nothing the run did not touch is swept in
# even if something else was already in the index.
#
# Subcommands (also usable as sourced functions wiki_lock_<subcommand>):
#   acquire --wiki-root R --ticket T [--log-file F]
#       0 held (WIKI_LOCK_STATUS=acquired|reacquired|stale-broken)
#       3 busy: another ticket holds it; waited WIKI_LOCK_WAIT_SECS this call.
#         Run acquire again — the overall wait is bounded across calls.
#       4 gave up: waited more than WIKI_LOCK_MAX_WAIT_SECS in total.
#   release --wiki-root R --ticket T
#       0 released or not held; 5 held by another ticket (left in place).
#   status --wiki-root R
#       0 always; prints WIKI_LOCK_HOLDER / WIKI_LOCK_AGE (empty when free).
#   commit --wiki-root R --ticket T --message M
#       0 committed (WIKI_LOCK_COMMIT=<sha>), 6 nothing of this run's to
#       commit, 5 lock not held by T, 1 git failure.
#   2 usage error on any subcommand.
#
# Env: WIKI_LOCK_WAIT_SECS (per-call wait, default 90 — fits inside the Bash
# tool's default 2-minute timeout), WIKI_LOCK_POLL_SECS (default 15),
# WIKI_LOCK_MAX_WAIT_SECS (total wait across calls, default 3600),
# WIKI_LOCK_STALE_SECS (default 3600).
#
# Sourceable lib and standalone CLI. No `set -e` at file scope, so sourcing
# never changes the caller's error handling.

_wiki_lock_now() { date +%s; }

_wiki_lock_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Lock directory for a wiki root. Inside .git when the wiki is a repo, so the
# lock itself can never be staged; otherwise a per-path dir under TMPDIR.
_wiki_lock_dir() {
  local root="${1}"
  if [ -d "$root/.git" ]; then
    echo "$root/.git/wiki-maintenance.lock.d"
  else
    local key
    key=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
    echo "${TMPDIR:-/tmp}/wiki-maintenance-${key}.lock.d"
  fi
}

_wiki_lock_sanitize() { printf '%s' "${1}" | tr -c 'A-Za-z0-9._-' '_'; }

# Prints "<ticket> <epoch>" for the current holder, or nothing when free.
# A directory with no owner file yet (mid-acquire, or a crash between mkdir
# and the owner write) is aged by the directory's own mtime.
_wiki_lock_read_owner() {
  local dir="${1}"
  [ -d "$dir" ] || return 0
  if [ -s "$dir/owner" ]; then
    head -1 "$dir/owner"
  else
    local mt
    mt=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)
    echo "? $mt"
  fi
}

_wiki_lock_write_owner() {
  local dir="${1}" ticket="${2}"
  printf '%s %s\n' "$ticket" "$(_wiki_lock_now)" >"$dir/owner.tmp" &&
    mv -f "$dir/owner.tmp" "$dir/owner"
}

# Emit "<hash>\t<path>" for every dirty path in the wiki repo (worktree or
# index differs from HEAD, plus untracked files). A deleted path hashes as
# "-". Silent (no output) when the root is not a git repo.
_wiki_lock_dirty_snapshot() {
  local root="${1}"
  [ -d "$root/.git" ] || return 0
  local entry path xy h skip_next=0
  while IFS= read -r -d '' entry; do
    if [ "$skip_next" = 1 ]; then
      skip_next=0
      continue
    fi
    xy="${entry:0:2}"
    path="${entry:3}"
    # Rename/copy entries carry the source path as the next NUL field.
    case "$xy" in R* | C*) skip_next=1 ;; esac
    if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
      h=$(git -C "$root" hash-object -- "$path" 2>/dev/null || echo "?")
    else
      h="-"
    fi
    printf '%s\t%s\n' "$h" "$path"
  done < <(git -C "$root" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
}

# One check-and-take attempt. Caller holds the guard flock (when available).
# Prints acquired|reacquired|stale-broken:<prev>|busy:<holder>:<age>.
_wiki_lock_try() {
  local root="${1}" dir="${2}" ticket="${3}"
  local stale="${WIKI_LOCK_STALE_SECS:-3600}"
  if mkdir "$dir" 2>/dev/null; then
    _wiki_lock_write_owner "$dir" "$ticket"
    _wiki_lock_dirty_snapshot "$root" >"$dir/baseline"
    echo "acquired"
    return 0
  fi
  local owner holder ts age
  owner=$(_wiki_lock_read_owner "$dir")
  holder="${owner%% *}"
  ts="${owner##* }"
  case "$ts" in '' | *[!0-9]*) ts=0 ;; esac
  if [ "$holder" = "$ticket" ]; then
    # Refresh: keeps a long run from aging into "stale", and keeps the
    # original baseline so the commit still excludes pre-existing edits.
    _wiki_lock_write_owner "$dir" "$ticket"
    [ -f "$dir/baseline" ] || _wiki_lock_dirty_snapshot "$root" >"$dir/baseline"
    echo "reacquired"
    return 0
  fi
  age=$(($(_wiki_lock_now) - ts))
  if [ "$age" -gt "$stale" ]; then
    rm -rf "$dir"
    if mkdir "$dir" 2>/dev/null; then
      _wiki_lock_write_owner "$dir" "$ticket"
      _wiki_lock_dirty_snapshot "$root" >"$dir/baseline"
      echo "stale-broken:${holder}"
      return 0
    fi
  fi
  echo "busy:${holder}:${age}"
  return 1
}

# Run _wiki_lock_try under a short flock on a guard file next to the lock dir.
_wiki_lock_try_guarded() {
  local root="${1}" dir="${2}" ticket="${3}"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 10 9 || {
        echo "busy:?:0"
        exit 1
      }
      _wiki_lock_try "$root" "$dir" "$ticket"
    ) 9>"${dir}.guard"
  else
    _wiki_lock_try "$root" "$dir" "$ticket"
  fi
}

_wiki_lock_log() {
  local log="${1}" msg="${2}"
  [ -n "$log" ] || return 0
  echo "$(_wiki_lock_iso)|${msg}" >>"$log" 2>/dev/null || true
}

_wiki_lock_parse_args() {
  _WL_ROOT="" _WL_TICKET="" _WL_LOG="${LOG_FILE:-}" _WL_MSG=""
  while [ $# -gt 0 ]; do
    case "${1}" in
    --wiki-root)
      _WL_ROOT="${2:-}"
      shift 2 || return 2
      ;;
    --ticket)
      _WL_TICKET="${2:-}"
      shift 2 || return 2
      ;;
    --log-file)
      _WL_LOG="${2:-}"
      shift 2 || return 2
      ;;
    --message)
      _WL_MSG="${2:-}"
      shift 2 || return 2
      ;;
    *)
      echo "wiki-lock: unknown argument: ${1}" >&2
      return 2
      ;;
    esac
  done
  if [ -z "$_WL_ROOT" ] || [ ! -d "$_WL_ROOT" ]; then
    echo "wiki-lock: --wiki-root must name an existing directory" >&2
    return 2
  fi
  return 0
}

_wiki_lock_require_ticket() {
  if [ -z "$_WL_TICKET" ]; then
    echo "wiki-lock: --ticket is required" >&2
    return 2
  fi
  _WL_TICKET=$(_wiki_lock_sanitize "$_WL_TICKET")
}

wiki_lock_acquire() {
  _wiki_lock_parse_args "$@" || return 2
  _wiki_lock_require_ticket || return 2
  local root="$_WL_ROOT" ticket="$_WL_TICKET" log="$_WL_LOG"
  local dir wait_file res
  dir=$(_wiki_lock_dir "$root")
  wait_file="${dir}.wait.${ticket}"
  local wait="${WIKI_LOCK_WAIT_SECS:-90}" poll="${WIKI_LOCK_POLL_SECS:-15}"
  local max_wait="${WIKI_LOCK_MAX_WAIT_SECS:-3600}"
  local deadline=$(($(_wiki_lock_now) + wait))
  while :; do
    if res=$(_wiki_lock_try_guarded "$root" "$dir" "$ticket"); then
      rm -f "$wait_file"
      case "$res" in
      stale-broken:*)
        _wiki_lock_log "$log" "META|wiki-lock|warn|broke stale WIKI_ROOT lock held by ${res#stale-broken:}"
        echo "WIKI_LOCK_STATUS=stale-broken"
        echo "WIKI_LOCK_PREVIOUS_HOLDER=${res#stale-broken:}"
        ;;
      *) echo "WIKI_LOCK_STATUS=${res}" ;;
      esac
      echo "WIKI_LOCK_DIR=${dir}"
      return 0
    fi
    local rest="${res#busy:}" holder age now first
    holder="${rest%%:*}"
    age="${rest##*:}"
    now=$(_wiki_lock_now)
    if [ ! -f "$wait_file" ]; then
      echo "$now" >"$wait_file"
      _wiki_lock_log "$log" "META|wiki-contention|warn|WIKI_ROOT lock held by ${holder} (age ${age}s); waiting"
    fi
    first=$(head -1 "$wait_file" 2>/dev/null)
    case "$first" in '' | *[!0-9]*) first=$now ;; esac
    if [ $((now - first)) -ge "$max_wait" ]; then
      rm -f "$wait_file"
      _wiki_lock_log "$log" "META|wiki-contention|fail|gave up after $((now - first))s waiting on WIKI_ROOT lock held by ${holder}"
      echo "WIKI_LOCK_STATUS=gave-up"
      echo "WIKI_LOCK_HOLDER=${holder}"
      return 4
    fi
    if [ "$now" -ge "$deadline" ]; then
      echo "WIKI_LOCK_STATUS=busy"
      echo "WIKI_LOCK_HOLDER=${holder}"
      echo "WIKI_LOCK_WAITED=$((now - first))"
      return 3
    fi
    sleep "$poll"
  done
}

wiki_lock_release() {
  _wiki_lock_parse_args "$@" || return 2
  _wiki_lock_require_ticket || return 2
  local root="$_WL_ROOT" ticket="$_WL_TICKET" dir rc=0
  dir=$(_wiki_lock_dir "$root")
  rm -f "${dir}.wait.${ticket}"
  _release_inner() {
    local owner holder
    owner=$(_wiki_lock_read_owner "$dir")
    if [ -z "$owner" ]; then
      echo "WIKI_LOCK_STATUS=not-held"
      return 0
    fi
    holder="${owner%% *}"
    if [ "$holder" != "$ticket" ]; then
      echo "WIKI_LOCK_STATUS=held-by-other"
      echo "WIKI_LOCK_HOLDER=${holder}"
      return 5
    fi
    rm -rf "$dir"
    echo "WIKI_LOCK_STATUS=released"
    return 0
  }
  if command -v flock >/dev/null 2>&1 && [ -d "$(dirname "$dir")" ]; then
    (
      flock -w 10 9 || exit 1
      _release_inner
    ) 9>"${dir}.guard" || rc=$?
  else
    _release_inner || rc=$?
  fi
  return "$rc"
}

wiki_lock_status() {
  _wiki_lock_parse_args "$@" || return 2
  local dir owner
  dir=$(_wiki_lock_dir "$_WL_ROOT")
  owner=$(_wiki_lock_read_owner "$dir")
  if [ -z "$owner" ]; then
    echo "WIKI_LOCK_HOLDER="
    echo "WIKI_LOCK_AGE="
  else
    local ts="${owner##* }"
    case "$ts" in '' | *[!0-9]*) ts=0 ;; esac
    echo "WIKI_LOCK_HOLDER=${owner%% *}"
    echo "WIKI_LOCK_AGE=$(($(_wiki_lock_now) - ts))"
  fi
  return 0
}

wiki_lock_commit() {
  _wiki_lock_parse_args "$@" || return 2
  _wiki_lock_require_ticket || return 2
  local root="$_WL_ROOT" ticket="$_WL_TICKET" msg="$_WL_MSG"
  if [ -z "$msg" ]; then
    echo "wiki-lock: --message is required" >&2
    return 2
  fi
  if [ ! -d "$root/.git" ]; then
    echo "wiki-lock: $root is not a git repo root" >&2
    return 2
  fi
  local dir owner
  dir=$(_wiki_lock_dir "$root")
  owner=$(_wiki_lock_read_owner "$dir")
  if [ "${owner%% *}" != "$ticket" ]; then
    echo "WIKI_LOCK_STATUS=not-owner"
    echo "WIKI_LOCK_HOLDER=${owner%% *}"
    return 5
  fi
  # Paths that are dirty now and either were clean at acquire time or have
  # changed since. Pre-existing, untouched edits stay out of this commit.
  local -a paths=()
  local h path base
  while IFS=$'\t' read -r h path; do
    [ -n "$path" ] || continue
    base=$(awk -F'\t' -v p="$path" '$2 == p { print $1; exit }' "$dir/baseline" 2>/dev/null)
    if [ -z "$base" ] || [ "$base" != "$h" ]; then
      paths+=("$path")
    fi
  done < <(_wiki_lock_dirty_snapshot "$root")
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "WIKI_LOCK_STATUS=nothing-to-commit"
    return 6
  fi
  # Literal pathspecs: a wiki filename containing glob characters must name
  # exactly that file, never a pattern matching someone else's.
  GIT_LITERAL_PATHSPECS=1 git -C "$root" add -A -- "${paths[@]}" || return 1
  if GIT_LITERAL_PATHSPECS=1 git -C "$root" diff --cached --quiet -- "${paths[@]}"; then
    echo "WIKI_LOCK_STATUS=nothing-to-commit"
    return 6
  fi
  GIT_LITERAL_PATHSPECS=1 git -C "$root" commit -q -m "$msg" -- "${paths[@]}" || return 1
  echo "WIKI_LOCK_STATUS=committed"
  echo "WIKI_LOCK_COMMIT=$(git -C "$root" rev-parse HEAD)"
  printf 'WIKI_LOCK_PATH=%s\n' "${paths[@]}"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _sub="${1:-}"
  shift || true
  case "$_sub" in
  acquire) wiki_lock_acquire "$@" ;;
  release) wiki_lock_release "$@" ;;
  status) wiki_lock_status "$@" ;;
  commit) wiki_lock_commit "$@" ;;
  *)
    echo "usage: wiki-lock.sh acquire|release|status|commit --wiki-root <dir> [--ticket <id>] [--log-file <f>] [--message <m>]" >&2
    exit 2
    ;;
  esac
  exit $?
fi
