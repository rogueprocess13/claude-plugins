#!/usr/bin/env bash
# verify-env-up.sh — ticket-verify Step 1.6 environment bring-up
# (skill-deterministic-extraction 4, staged).
#
# Usage:
#   verify-env-up.sh served-check <TICKET-ID> --local-url URL [--claude-md F]
#   verify-env-up.sh worktrees <TICKET-ID> --branch B [--services "S..."]
#                    [--tickets-root R] [--claude-md F]
#
# Every subcommand writes the same pipeline-log lines (through plog.sh, so
# TAP_LOG / LOG_FILE select the log) as the SKILL.md block it replaced.
# --claude-md defaults to ./CLAUDE.md, as the blocks did.
#
# served-check — Step 1.6b's served-checkout check. Resolves the process on
# LOCAL_URL's port plus every VERIFY_SERVED_PORTS port and compares each
# checkout with this ticket's verify worktrees (verify_served_check_ports):
#   0 ok            → VERIFY|served-worktree|done|<summary>
#   1 wrong         → META|gate-stop|fail|VERIFY_SERVED_WRONG_WORKTREE — <summary>,
#                     lock released, exit 1
#                     (VERIFY_SERVED_WORKTREE_ENFORCE=false: META|gate-warn instead)
#   4 no worktree   → META|gate-warn|warn|VERIFY_SERVED_UNVERIFIED — <summary>
#   3/other         → META|gate-warn|warn|VERIFY_SERVED_UNVERIFIED — could not tell …
#                     (VERIFY_SERVED_WORKTREE_STRICT=true: 4 and 3 gate-stop
#                     VERIFY_SERVED_UNVERIFIED, lock released, exit 1)
#
# worktrees — Step 1.6a4, run with the lock held. Resolves REPOS_ROOT
# (verify_env_init; unresolved → META|gate-stop|fail|VERIFY_WORKTREE_FAILED —
# REPOS_ROOT unresolved, lock released, exit 1), then for each service that is
# a git repo under REPOS_ROOT runs ensure_verify_worktree (destructive on
# reuse; a failure → VERIFY_WORKTREE_FAILED — <svc> @ <branch>, lock
# released, exit 1). Services: --services, else every REPOS_ROOT/*/ that has
# a .git (sorted), mirroring env-start.sh's "no specific services →
# everything" fallback. No repo matched → META|gate-warn|warn|
# VERIFY_WORKTREE_NONE …; always ends with VERIFY|worktree-setup|done|<n>
# worktree(s) ready for <branch>. With --tickets-root, also warns
# META|verify-worktree-unwired when R/env-start.sh never reads
# VERIFY_REPO_PATH_* (advisory). The exports themselves die with this
# process; env-start.sh's shell re-derives them (verify_worktree_exports).
#
# Exit codes: 0 continue, 1 stopped (gate-stop written, lock released),
# 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_VEU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_veu_usage() {
  cat >&2 <<'USAGE'
usage: verify-env-up.sh served-check <TICKET-ID> --local-url URL [--claude-md F]
       verify-env-up.sh worktrees <TICKET-ID> --branch B [--services "S..."] [--tickets-root R] [--claude-md F]
USAGE
}

_veu_plog() { bash "$_VEU_DIR/plog.sh" "$@"; }

_veu_source_libs() {
  # shellcheck source=/dev/null
  source "$_VEU_DIR/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$_VEU_DIR/verify-worktree.sh"
  # shellcheck source=/dev/null
  source "$_VEU_DIR/verify-lock.sh" 2>/dev/null || true
}

# ── served-check (stage 1) ──────────────────────────────────────────────────
_veu_served_stop() { # code text
  _veu_plog META gate-stop fail "${1} — ${_served_msg}"
  echo "ticket-verify: ${2} — ${_served_msg}" >&2
  declare -f verify_lock_release >/dev/null 2>&1 && verify_lock_release
  return 1
}

veu_served_check() { # tid local_url claude_md
  local tid="$1" local_url="$2" claude_md="$3" _ports _served_rc=0
  verify_env_init "$tid" "$claude_md" || true
  _ports=$(verify_served_ports "$local_url" "${VERIFY_SERVED_PORTS:-}" 2>/dev/null)
  # shellcheck disable=SC2086
  _served_msg=$(verify_served_check_ports "$tid" $_ports) || _served_rc=$?
  _served_msg=$(printf '%s' "$_served_msg" | tr '\n|' ' /')
  case "$_served_rc" in
  0) _veu_plog VERIFY served-worktree done "${_served_msg}" ;;
  1)
    if [ "${VERIFY_SERVED_WORKTREE_ENFORCE:-true}" = "true" ]; then
      _veu_served_stop VERIFY_SERVED_WRONG_WORKTREE "the dev server is not serving this ticket's code. Stop the stale server on that port, or re-run env-start.sh with --restart for that service, so it starts from VERIFY_REPO_PATH_<REPO> (see the contract above)"
      return 1
    fi
    _veu_plog META gate-warn warn "VERIFY_SERVED_WRONG_WORKTREE — ${_served_msg} (VERIFY_SERVED_WORKTREE_ENFORCE=false)"
    ;;
  4)
    if [ "${VERIFY_SERVED_WORKTREE_STRICT:-false}" = "true" ]; then
      _veu_served_stop VERIFY_SERVED_UNVERIFIED "no verify worktree to compare the served checkout with"
      return 1
    fi
    _veu_plog META gate-warn warn "VERIFY_SERVED_UNVERIFIED — ${_served_msg}"
    ;;
  *)
    if [ "${VERIFY_SERVED_WORKTREE_STRICT:-false}" = "true" ]; then
      _veu_served_stop VERIFY_SERVED_UNVERIFIED "could not tell which checkout the dev server serves (VERIFY_SERVED_WORKTREE_STRICT=true)"
      return 1
    fi
    _veu_plog META gate-warn warn "VERIFY_SERVED_UNVERIFIED — could not tell which checkout LOCAL_URL's port serves: ${_served_msg}"
    ;;
  esac
  return 0
}

# ── worktrees (stage 2) ─────────────────────────────────────────────────────
_veu_stop() { # gate-stop-msg stderr-msg
  _veu_plog META gate-stop fail "$1"
  echo "ticket-verify: $2" >&2
  declare -f verify_lock_release >/dev/null 2>&1 && verify_lock_release
  return 1
}

# Every repo directory directly under REPOS_ROOT that has a .git, sorted.
_veu_all_repos() {
  local d
  for d in "$REPOS_ROOT"/*/; do
    [ -d "${d}.git" ] || continue
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done | sort | tr '\n' ' ' | sed 's/ $//'
}

veu_worktrees() { # tid branch services tickets_root claude_md
  local tid="$1" _branch="$2" _verify_services="$3" tickets_root="$4" claude_md="$5"
  verify_env_init "$tid" "$claude_md" || {
    _veu_stop "VERIFY_WORKTREE_FAILED — REPOS_ROOT unresolved" "REPOS_ROOT could not be resolved — see stderr above."
    return 1
  }
  [ -n "$_verify_services" ] || _verify_services=$(_veu_all_repos)
  local _wt_count=0 _svc _repo_path _wt
  for _svc in $_verify_services; do
    _repo_path="$REPOS_ROOT/$_svc"
    [ -d "$_repo_path/.git" ] || continue
    _wt=$(ensure_verify_worktree "$tid" "$_repo_path" "$_branch") || {
      _veu_stop "VERIFY_WORKTREE_FAILED — $_svc @ $_branch" "could not prepare an isolated worktree for $_svc on branch $_branch — see stderr above."
      return 1
    }
    export "$(verify_worktree_env_var "$_svc")=$_wt"
    _wt_count=$((_wt_count + 1))
  done
  if [ "$_wt_count" -eq 0 ]; then
    _veu_plog META gate-warn warn "VERIFY_WORKTREE_NONE — none of '${_verify_services}' is a git repo under ${REPOS_ROOT}; the stack will serve whatever the primary checkouts hold"
  fi
  _veu_plog VERIFY worktree-setup done "${_wt_count} worktree(s) ready for ${_branch}"
  if [ -n "$tickets_root" ] && ! grep -q "VERIFY_REPO_PATH" "$tickets_root/env-start.sh" 2>/dev/null; then
    _veu_plog META verify-worktree-unwired warn "env-start.sh does not read VERIFY_REPO_PATH_* — branch isolation is partial (worktree checkout is correct; the running app stack may still build from the shared clone) until env-start.sh is updated to consume it"
  fi
  return 0
}

# ── CLI ─────────────────────────────────────────────────────────────────────
_veu_main() {
  local cmd="${1:-}"
  shift || true
  local tid="" local_url="" claude_md="./CLAUDE.md" branch="" services="" tickets_root=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --local-url | --claude-md | --branch | --services | --tickets-root)
      [ $# -ge 2 ] || {
        _veu_usage
        return 2
      }
      case "$1" in
      --local-url) local_url="$2" ;;
      --claude-md) claude_md="$2" ;;
      --branch) branch="$2" ;;
      --services) services="$2" ;;
      --tickets-root) tickets_root="$2" ;;
      esac
      shift 2
      ;;
    -*)
      _veu_usage
      return 2
      ;;
    *)
      [ -z "$tid" ] || {
        _veu_usage
        return 2
      }
      tid="$1"
      shift
      ;;
    esac
  done
  [ -n "$tid" ] || {
    _veu_usage
    return 2
  }
  case "$cmd" in
  served-check)
    _veu_source_libs
    veu_served_check "$tid" "$local_url" "$claude_md"
    ;;
  worktrees)
    [ -n "$branch" ] || {
      _veu_usage
      return 2
    }
    _veu_source_libs
    veu_worktrees "$tid" "$branch" "$services" "$tickets_root" "$claude_md"
    ;;
  *)
    _veu_usage
    return 2
    ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _veu_main "$@"
  exit $?
fi
