#!/usr/bin/env bash
# verify-env-up.sh — ticket-verify Step 1.6 environment bring-up
# (skill-deterministic-extraction 4, staged).
#
# Usage:
#   verify-env-up.sh served-check <TICKET-ID> --local-url URL [--claude-md F]
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
# Exit codes: 0 continue, 1 stopped (gate-stop written, lock released),
# 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_VEU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_veu_usage() {
  cat >&2 <<'USAGE'
usage: verify-env-up.sh served-check <TICKET-ID> --local-url URL [--claude-md F]
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

# ── CLI ─────────────────────────────────────────────────────────────────────
_veu_main() {
  local cmd="${1:-}"
  shift || true
  local tid="" local_url="" claude_md="./CLAUDE.md"
  while [ $# -gt 0 ]; do
    case "$1" in
    --local-url | --claude-md)
      [ $# -ge 2 ] || {
        _veu_usage
        return 2
      }
      case "$1" in
      --local-url) local_url="$2" ;;
      --claude-md) claude_md="$2" ;;
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
