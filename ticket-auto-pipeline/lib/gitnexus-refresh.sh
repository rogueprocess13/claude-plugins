#!/usr/bin/env bash
# gitnexus-refresh.sh — best-effort GitNexus re-index after a ticket's PRs
# (GitHub #609).
#
# gitnexus_verify_branch (gitnexus-preflight.sh) detects a stale index, but
# nothing refreshed it: every later ticket on the same repo fell back to grep,
# and the lag grew with each merge. The router runs this script in MAINTENANCE
# (STEP_5), in its own Bash call. It returns in seconds: the analyze itself
# runs detached.
#
# Usage:
#   gitnexus-refresh.sh [--repo OWNER/NAME --base BRANCH] <TICKET-ID> <LOG-FILE>
#
# Targets: every distinct repo named by a META|pr-created line (a ticket can
# open several PRs), each with its own base: the PR's baseRefName (`gh pr
# view`), else the log's META|branch-context integration=/base= value.
# --repo/--base name one target by hand instead. Every base must pass
# `git check-ref-format --branch`. The agent env file in /tmp is never read.
#
# Indexed clones come from the GitNexus registry (GITNEXUS_REGISTRY, default
# ~/.gitnexus/registry.json), matched on remoteUrl. Two kinds:
#
#   Pipeline-owned index worktrees (path under */.ticket-auto/worktrees/gitnexus/*,
#   a detached HEAD by design). Under a per-path lock in ~/.gitnexus/locks
#   (mode 0700, a symlinked dir or lock file is refused), when the tree is
#   clean outside .gitnexus/:
#     git fetch origin <base>, then git checkout --detach FETCH_HEAD
#   with GIT_TERMINAL_PROMPT=0, ssh BatchMode, core.hooksPath=/dev/null and a
#   fetch timeout. No branch is ever moved. When HEAD differs from the
#   registry's lastCommit, `gitnexus analyze --skip-agents-md <path>` starts
#   detached (setsid/nohup), holding the lock, logging to
#   ~/.gitnexus/refresh-logs/<name>.log (GITNEXUS_REFRESH_LOG_DIR). It backs up
#   .gitnexus/lbug* first and restores the backup when analyze fails: gitnexus
#   deletes the old database before rebuilding, so a failed run would
#   otherwise leave an empty index. There is no kill timeout for the same
#   reason; GITNEXUS_REFRESH_TIMEOUT sets one, and a timeout also restores.
#
#   Any other clone is the user's own checkout: it is never fetched, pulled or
#   checked out. When its indexed commit differs from its own
#   refs/remotes/origin/<base>, one META|gitnexus-stale|warn line names the
#   manual command.
#
# Pipeline-log lines, written at once, one per indexed clone (or one per repo
# when nothing is indexed). META lines on purpose: detect-resume.sh reads
# MAINTENANCE|*|done lines as resume points.
#   META|gitnexus-refresh|start|<name> <old7>→<new7>, log: <file>
#   META|gitnexus-refresh|skip|<name>: <reason>
#   META|gitnexus-refresh|warn|<name>: <failure> — run: gitnexus analyze <path>
#   META|gitnexus-stale|warn|<name>: ... — run: git -C <p> pull && gitnexus analyze <p>
# The analyze result goes to the analyze log only, so META|outcome stays the
# pipeline log's last line.
#
# Exit 0 on every refresh outcome, 2 on bad usage.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -o pipefail

_GR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GR_SELF="${_GR_DIR}/$(basename "${BASH_SOURCE[0]}")"
_GR_LOG=""

_gr_usage() {
  echo "Usage: gitnexus-refresh.sh [--repo OWNER/NAME --base BRANCH] <TICKET-ID> <LOG-FILE>" >&2
  exit 2
}

_gr_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_gr_log() {
  [ -n "$_GR_LOG" ] || return 0
  echo "$(_gr_iso)|META|$1|$2|$3" >>"$_GR_LOG" 2>/dev/null || true
}

# _gr_slug <url> — owner/name of a git remote URL, lower-cased.
_gr_slug() {
  local u="${1%/}"
  u="${u%.git}"
  u="${u##*:}"
  printf '%s\n' "$u" | awk -F/ 'NF>=2 {print tolower($(NF-1) "/" $NF)}'
}

_gr_valid_branch() { [ -n "$1" ] && git check-ref-format --branch "$1" >/dev/null 2>&1; }

# git with no hooks, no prompts, no interactive ssh.
_gr_git() {
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
    git -c core.hooksPath=/dev/null "$@"
}

_gr_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=10 "$@"
  else
    shift
    "$@"
  fi
}

# _gr_branch_ctx <field> — a field of the log's last META|branch-context line.
_gr_branch_ctx() {
  local line
  line=$(grep '^[^|]*|META|branch-context|info|' "$_GR_LOG" 2>/dev/null | tail -1) || line=""
  [ -n "$line" ] || return 0
  printf '%s\n' "${line#*|META|branch-context|info|}" | tr ';' '\n' | sed -n "s/^$1=//p" | head -1
}

# _gr_targets — "repo<TAB>pr" per distinct repo across every META|pr-created
# line (the latest PR per repo wins).
_gr_targets() {
  grep '|META|pr-created|info|' "$_GR_LOG" 2>/dev/null |
    awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' |
    jq -r 'select(.repo != null and .repo != "") | [.repo, ((.pr // "") | tostring)] | @tsv' 2>/dev/null |
    awk -F'\t' '{last[$1]=$2; if (!($1 in seen)) {seen[$1]=1; order[++n]=$1}}
      END {for (i=1;i<=n;i++) print order[i] "\t" last[order[i]]}'
}

# _gr_lock_dir — ~/.gitnexus/locks, created 0700; refused when it is a
# symlink or not owned by this user.
_gr_lock_dir() {
  local d="${HOME}/.gitnexus/locks"
  [ -L "$d" ] && return 1
  mkdir -p -m 700 "$d" 2>/dev/null || return 1
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || return 1
  printf '%s\n' "$d"
}

# _gr_user_clone <name> <path> <indexed> <base> — read-only staleness check.
_gr_user_clone() {
  local name="$1" path="$2" old="$3" base="$4" tip
  tip=$(git -C "$path" rev-parse --verify -q "refs/remotes/origin/${base}^{commit}" 2>/dev/null) || tip=""
  if [ -n "$tip" ] && [ "$tip" = "$old" ]; then
    _gr_log gitnexus-refresh skip "${name}: user clone index already at origin/${base}"
    return 0
  fi
  _gr_log gitnexus-stale warn "${name}: index of user clone ${path} is not at origin/${base}, not refreshed automatically — run: git -C ${path} pull && gitnexus analyze ${path}"
}

# _gr_owned <name> <path> <indexed> <base> — refresh a pipeline-owned worktree.
_gr_owned() {
  local name="$1" path="$2" old="$3" base="$4"
  local hint="run: gitnexus analyze ${path}"

  if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _gr_log gitnexus-refresh skip "${name}: ${path} is not a git work tree"
    return 0
  fi
  local ldir lock fd
  if ! ldir=$(_gr_lock_dir); then
    _gr_log gitnexus-refresh warn "${name}: lock dir ~/.gitnexus/locks is unsafe or missing — ${hint}"
    return 0
  fi
  lock="${ldir}/$(printf '%s' "$path" | cksum | cut -d' ' -f1).lock"
  if [ -L "$lock" ] || { [ -e "$lock" ] && [ ! -f "$lock" ]; }; then
    _gr_log gitnexus-refresh warn "${name}: refusing lock ${lock} (not a regular file) — ${hint}"
    return 0
  fi
  exec {fd}>>"$lock" || {
    _gr_log gitnexus-refresh warn "${name}: cannot open lock ${lock} — ${hint}"
    return 0
  }
  if ! flock -n "$fd"; then
    exec {fd}>&-
    _gr_log gitnexus-refresh skip "${name}: a refresh of ${path} is already running"
    return 0
  fi

  if [ -n "$(git -C "$path" status --porcelain --untracked-files=no -- . ':(exclude).gitnexus' 2>/dev/null)" ]; then
    exec {fd}>&-
    _gr_log gitnexus-refresh warn "${name}: index worktree ${path} has local changes, not refreshed — ${hint}"
    return 0
  fi
  if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
    _gr_timeout "${GITNEXUS_REFRESH_FETCH_TIMEOUT:-120}" \
    git -c core.hooksPath=/dev/null -C "$path" fetch --quiet origin "$base" >/dev/null 2>&1 ||
    ! _gr_git -C "$path" checkout --quiet --detach FETCH_HEAD >/dev/null 2>&1; then
    exec {fd}>&-
    _gr_log gitnexus-refresh warn "${name}: fetch/checkout of origin/${base} failed in ${path} — ${hint}"
    return 0
  fi
  local new
  new=$(git -C "$path" rev-parse HEAD 2>/dev/null) || new=""
  if [ -n "$old" ] && [ "$old" = "$new" ]; then
    exec {fd}>&-
    _gr_log gitnexus-refresh skip "${name}: index already at ${new:0:7} (origin/${base})"
    return 0
  fi

  local logdir="${GITNEXUS_REFRESH_LOG_DIR:-$HOME/.gitnexus/refresh-logs}" alog
  mkdir -p -m 700 "$logdir" 2>/dev/null || true
  alog="${logdir}/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_').log"
  # The detached worker inherits the lock fd, so the lock stays held until
  # analyze ends; this process then drops its own copy.
  local runner=()
  command -v setsid >/dev/null 2>&1 && runner=(setsid)
  "${runner[@]}" nohup bash "$_GR_SELF" --analyze-worker "$name" "$path" "$old" "$new" \
    </dev/null >>"$alog" 2>&1 &
  exec {fd}>&-
  _gr_log gitnexus-refresh start "${name} ${old:0:7}→${new:0:7}, log: ${alog}"
  return 0
}

# _gr_analyze_worker <name> <path> <old> <new> — runs detached; output goes
# to the analyze log only.
_gr_analyze_worker() {
  local name="$1" path="$2" old="$3" new="$4" bak rc=0 f
  bak="${path}/.gitnexus/.refresh-backup"
  rm -rf "$bak" 2>/dev/null
  mkdir -p "$bak" 2>/dev/null || true
  for f in "$path"/.gitnexus/lbug*; do
    [ -e "$f" ] && cp -pR "$f" "$bak/"
  done
  echo "$(_gr_iso)|gitnexus-refresh|start|${name} ${old:0:7}→${new:0:7} in ${path}"
  if [ -n "${GITNEXUS_REFRESH_TIMEOUT:-}" ]; then
    _gr_timeout "$GITNEXUS_REFRESH_TIMEOUT" "${GITNEXUS_BIN:-gitnexus}" analyze --skip-agents-md "$path" || rc=$?
  else
    "${GITNEXUS_BIN:-gitnexus}" analyze --skip-agents-md "$path" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    rm -rf "$bak"
    echo "$(_gr_iso)|gitnexus-refresh|done|${name} ${old:0:7}→${new:0:7}"
    return 0
  fi
  rm -rf "$path"/.gitnexus/lbug* 2>/dev/null
  for f in "$bak"/lbug*; do
    [ -e "$f" ] && cp -pR "$f" "$path/.gitnexus/"
  done
  rm -rf "$bak"
  echo "$(_gr_iso)|gitnexus-refresh|fail|${name}: analyze exited ${rc}; previous index restored — run: gitnexus analyze ${path}"
  return 0
}

_gr_refresh_repo() {
  local repo="$1" base="$2" registry="$3"
  local want name path last url found=0
  want=$(printf '%s\n' "$repo" | tr '[:upper:]' '[:lower:]')
  while IFS=$'\t' read -r name path last url; do
    [ -n "$path" ] && [ -n "$url" ] || continue
    [ "$(_gr_slug "$url")" = "$want" ] || continue
    found=1
    case "$path" in
    */.ticket-auto/worktrees/gitnexus/*) _gr_owned "${name:-$want}" "$path" "$last" "$base" ;;
    *) _gr_user_clone "${name:-$want}" "$path" "$last" "$base" ;;
    esac
  done < <(jq -r '(if type == "array" then . else (.repos // []) end)[]
    | [(.name // ""), (.path // ""), (.lastCommit // ""), (.remoteUrl // "")] | @tsv' \
    "$registry" 2>/dev/null)
  [ "$found" = 1 ] || _gr_log gitnexus-refresh skip "${repo}: not indexed by GitNexus"
}

main() {
  if [ "${1:-}" = "--analyze-worker" ]; then
    shift
    [ $# -eq 4 ] || exit 2
    _gr_analyze_worker "$@"
    return 0
  fi
  local repo="" base=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --repo | --base)
      [ $# -ge 2 ] || _gr_usage
      if [ "$1" = --repo ]; then repo="$2"; else base="$2"; fi
      shift 2
      ;;
    --) shift && break ;;
    -*) _gr_usage ;;
    *) break ;;
    esac
  done
  [ $# -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || _gr_usage
  local tid="$1"
  _GR_LOG="$2"

  local targets
  if [ -n "$repo" ]; then
    targets=$(printf '%s\t\n' "$repo")
  else
    targets=$(_gr_targets)
  fi
  if [ -z "$targets" ]; then
    _gr_log gitnexus-refresh skip "no PR repo recorded for ${tid}"
    return 0
  fi
  if ! command -v "${GITNEXUS_BIN:-gitnexus}" >/dev/null 2>&1; then
    _gr_log gitnexus-refresh skip "gitnexus CLI not installed"
    return 0
  fi
  local registry="${GITNEXUS_REGISTRY:-$HOME/.gitnexus/registry.json}"
  if [ ! -f "$registry" ]; then
    _gr_log gitnexus-refresh skip "no GitNexus registry at ${registry}"
    return 0
  fi

  local ctx_base r pr b
  ctx_base=$(_gr_branch_ctx integration)
  [ -n "$ctx_base" ] || ctx_base=$(_gr_branch_ctx base)
  while IFS=$'\t' read -r r pr; do
    [ -n "$r" ] || continue
    b="$base"
    if [ -z "$b" ] && [ -n "$pr" ] && command -v gh >/dev/null 2>&1; then
      b=$(_gr_timeout 30 gh pr view "$pr" --repo "$r" --json baseRefName --jq '.baseRefName' 2>/dev/null) || b=""
    fi
    [ -n "$b" ] || b="$ctx_base"
    if ! _gr_valid_branch "$b"; then
      _gr_log gitnexus-refresh skip "${r}: base branch unknown or invalid"
      continue
    fi
    _gr_refresh_repo "$r" "$b" "$registry"
  done <<<"$targets"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit 0
fi
