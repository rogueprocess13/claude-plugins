#!/usr/bin/env bash
# prescan-run.sh — the ticket-auto router's prescan gate (skill-deterministic-
# extraction 3). Everything around the ticket-prescan-agent spawn; the spawn
# itself (spawn_agent_pre → Agent tool) stays in skills/ticket-auto/SKILL.md.
#
# Usage:
#   prescan-run.sh gate --log-file F --repos-root R [--resume-step S]
#                  [--branch B] [--after REPO]
#   prescan-run.sh done <TICKET-ID> --slug S --status ST --log-file F
#                  [--result-file P]
#
# Unfilled `{PLACEHOLDER}` values read as empty.
#
# gate — walks the repos under REPOS_ROOT (every `.git` directory at depth ≤ 3,
# sorted, so a repeat call with --after sees the same order) and stops at the
# first repo that needs a prescan spawn. Per repo, in order:
#   prescan-check.sh <repo> --repos-root R --branch B   (PRESCAN_CHECK_SH overrides)
#     fresh            → nothing logged
#     decayed|missing  → MAINTENANCE|prescan|skip|<slug> <status> — full fan-out needs an
#                        interactive /ticket-prescan <repo> (headless prescan agent has no Agent tool)
#     anything else    → MAINTENANCE|prescan|skip|<slug> unknown prescan status '<status>' — not spawning
#     stale            → non-blocking flock probe on R/.ticket-auto/<slug>/.lock:
#                          held  → MAINTENANCE|prescan|skip|<slug> locked by another process
#                          free  → MAINTENANCE|prescan|waiting|<slug> prescan triggered (stale)
#                                  and stop: this repo is the one to spawn for.
# Before the walk: --resume-step STEP_4 | STEP_4_5 | STEP_4_6 | STEP_5 | STEP_5_5 |
# STEP_6 | done → MAINTENANCE|prescan|skip|resuming at <S> — prescan skipped, and
# no repo is walked; no repos at all → MAINTENANCE|prescan|skip|no repos found
# under REPOS_ROOT. --after REPO resumes the walk after that repo (the one the
# previous call returned), so a failed scan is not retried in a loop.
#
# The lock is a probe: it is released before this script exits. ticket-prescan
# takes the same lock itself while it writes, and a router Bash call never kept
# the lock past its own end anyway (the Agent spawn is a separate tool call).
# An EXIT trap installed before the acquire releases it on every exit path.
#
# Stdout (eval-safe, always all three):
#   PRESCAN_REPO=<path>    empty: nothing to spawn, go on to the dispatch loop
#   PRESCAN_SLUG=<slug>
#   PRESCAN_STATUS=<status of that repo>
#
# done — after the agent's return is written to --result-file (default
# ./logs/<TID>-agent-return.txt):
#   spawn_capture TICKET_ID PHASE=MAINTENANCE RESULT_FILE
#   "<slug>: scanned" in the return (the PRESCAN_RESULT marker, never
#   spawn_capture's exit code) →
#     spawn_agent_post RESULT=done MSG="<slug> prescan complete: <status> → fresh" NEXT_PHASE=APPRAISE
#     MAINTENANCE|prescan|done|<slug> prescan complete
#   otherwise →
#     FAIL_ACTION=warn-continue spawn_agent_post RESULT=fail MSG="<slug> prescan failed (non-blocking)"
#     MAINTENANCE|prescan|fail|<slug> prescan failed
#
# Prescan is an optimization: nothing here blocks the pipeline. Exit codes:
# 0 always, except 2 usage.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_PR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_pr_usage() {
  sed -n '6,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

_pr_val() {
  case "$1" in "{"*"}") printf '' ;; *) printf '%s' "$1" ;; esac
}

_pr_cmd="${1:-}"
[ -n "$_pr_cmd" ] || _pr_usage
shift
_pr_tid=""
case "$_pr_cmd" in
gate) ;;
done)
  [ $# -ge 1 ] || _pr_usage
  _pr_tid="$1"
  shift
  case "$_pr_tid" in "" | -* | "{"*"}") _pr_usage ;; esac
  ;;
*) _pr_usage ;;
esac

_pr_log_file="" _pr_repos_root="" _pr_resume_step="" _pr_branch="" _pr_after=""
_pr_slug="" _pr_status="" _pr_result_file=""
while [ $# -gt 0 ]; do
  case "$1" in
  --log-file | --repos-root | --resume-step | --branch | --after | --slug | --status | --result-file)
    [ $# -ge 2 ] || _pr_usage
    _v=$(_pr_val "$2")
    case "$1" in
    --log-file) _pr_log_file="$_v" ;;
    --repos-root) _pr_repos_root="$_v" ;;
    --resume-step) _pr_resume_step="$_v" ;;
    --branch) _pr_branch="$_v" ;;
    --after) _pr_after="$_v" ;;
    --slug) _pr_slug="$_v" ;;
    --status) _pr_status="$_v" ;;
    --result-file) _pr_result_file="$_v" ;;
    esac
    shift 2
    ;;
  *) _pr_usage ;;
  esac
done
[ -n "$_pr_log_file" ] || _pr_usage

_pr_plog() {
  # The lock fd (if any) is closed for the child, so only this process holds it.
  if [ -n "${_pr_lock_fd:-}" ]; then
    bash "$_PR_DIR/plog.sh" --log-file "$_pr_log_file" "$@" {_pr_lock_fd}>&- || true
  else
    bash "$_PR_DIR/plog.sh" --log-file "$_pr_log_file" "$@" || true
  fi
}

_pr_emit() {
  printf 'PRESCAN_REPO=%q\n' "${1:-}"
  printf 'PRESCAN_SLUG=%q\n' "${2:-}"
  printf 'PRESCAN_STATUS=%q\n' "${3:-}"
}

# ── gate ──────────────────────────────────────────────────────────────────────
_pr_lock_fd=""
_pr_release() {
  if [ -n "${_pr_lock_fd:-}" ]; then
    flock -u "$_pr_lock_fd" 2>/dev/null || true
    exec {_pr_lock_fd}>&- 2>/dev/null || true
    _pr_lock_fd=""
  fi
}

_pr_gate() {
  case "$_pr_resume_step" in
  STEP_4 | STEP_4_5 | STEP_4_6 | STEP_5 | STEP_5_5 | STEP_6 | done)
    _pr_plog MAINTENANCE prescan skip "resuming at $_pr_resume_step — prescan skipped"
    _pr_emit
    return 0
    ;;
  esac

  local repos=() repo_dir
  if [ -n "$_pr_repos_root" ]; then
    # -type d excludes git-worktree ".git" *files* (pointer files under
    # .ticket-auto/worktrees/**). %h is already the repo root.
    while IFS= read -r -d '' repo_dir; do
      repos+=("$repo_dir")
    done < <(find "$_pr_repos_root" -maxdepth 3 -name ".git" -type d -printf '%h\0' 2>/dev/null | sort -z || true)
  fi
  if [ ${#repos[@]} -eq 0 ]; then
    _pr_plog MAINTENANCE prescan skip "no repos found under REPOS_ROOT"
    _pr_emit
    return 0
  fi

  local check_sh="${PRESCAN_CHECK_SH:-$_PR_DIR/prescan-check.sh}"
  local skipping=false repo slug out PRESCAN_STATUS lock_file
  [ -z "$_pr_after" ] || skipping=true
  trap _pr_release EXIT
  for repo in "${repos[@]}"; do
    if [ "$skipping" = true ]; then
      [ "$repo" = "$_pr_after" ] && skipping=false
      continue
    fi
    slug=$(basename "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
    PRESCAN_STATUS=""
    out=$(bash "$check_sh" "$repo" --repos-root "$_pr_repos_root" --branch "$_pr_branch" 2>/dev/null) || true
    eval "$(printf '%s\n' "$out" | grep '^PRESCAN_STATUS=' | tail -1)" 2>/dev/null || PRESCAN_STATUS=""
    case "${PRESCAN_STATUS}" in
    fresh)
      continue
      ;;
    stale) ;;
    decayed | missing)
      _pr_plog MAINTENANCE prescan skip "$slug ${PRESCAN_STATUS} — full fan-out needs an interactive /ticket-prescan $repo (headless prescan agent has no Agent tool)"
      continue
      ;;
    *)
      _pr_plog MAINTENANCE prescan skip "$slug unknown prescan status '${PRESCAN_STATUS}' — not spawning"
      continue
      ;;
    esac

    lock_file="$_pr_repos_root/.ticket-auto/$slug/.lock"
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
    if exec {_pr_lock_fd}>"$lock_file" 2>/dev/null && flock -n "$_pr_lock_fd"; then
      _pr_plog MAINTENANCE prescan waiting "$slug prescan triggered ($PRESCAN_STATUS)"
      _pr_release
      _pr_emit "$repo" "$slug" "$PRESCAN_STATUS"
      return 0
    fi
    _pr_release
    _pr_plog MAINTENANCE prescan skip "$slug locked by another process"
  done
  _pr_emit
  return 0
}

# ── done ──────────────────────────────────────────────────────────────────────
_pr_done() {
  [ -n "$_pr_slug" ] || _pr_usage
  [ -n "$_pr_result_file" ] || _pr_result_file="./logs/${_pr_tid}-agent-return.txt"
  if ! declare -f spawn_capture >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_PR_DIR/spawn-helper.sh"
  fi
  spawn_capture TICKET_ID="$_pr_tid" PHASE=MAINTENANCE RESULT_FILE="$_pr_result_file" ||
    echo "prescan-run: spawn_capture failed (continuing)" >&2
  # Judge success by the PRESCAN_RESULT block's per-repo marker, not by
  # spawn_capture's exit code (a log write that succeeds regardless).
  if grep -q "$_pr_slug: scanned" "$_pr_result_file" 2>/dev/null; then
    spawn_agent_post TICKET_ID="$_pr_tid" RESULT=done \
      MSG="$_pr_slug prescan complete: $_pr_status → fresh" NEXT_PHASE=APPRAISE || true
    _pr_plog MAINTENANCE prescan done "$_pr_slug prescan complete"
  else
    FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID="$_pr_tid" RESULT=fail \
      MSG="$_pr_slug prescan failed (non-blocking)" || true
    _pr_plog MAINTENANCE prescan fail "$_pr_slug prescan failed"
  fi
  return 0
}

case "$_pr_cmd" in
gate) _pr_gate ;;
done) _pr_done ;;
esac
exit 0
