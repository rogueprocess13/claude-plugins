#!/usr/bin/env bash
# prescan-run-repo.sh — ticket-prescan's deterministic steps around the
# persona fan-out (skill-deterministic-extraction 6a). The Agent spawns and
# the gitnexus / claude-mem MCP calls stay in the skill.
#
# Usage:
#   prescan-run-repo.sh list [REPO_PATH]
#   prescan-run-repo.sh gate <repo> [--force]
#   prescan-run-repo.sh corrections <repo>
#   prescan-run-repo.sh verify <repo> --cadence C
#   prescan-run-repo.sh <repo> --write-meta --cadence C [--gitnexus-indexed true|false] [--symbols N]
#
# Log: ~/.claude/logs/prescan-<slug>.log (ISO|PHASE|STEP|STATUS|MSG through
# plog.sh), ~/.claude/logs/prescan.log for lines with no repo yet. Not a
# pipeline phase log: detect-resume.sh knows no PRESCAN phase.
#
# REPOS_ROOT / WIKI_ROOT: the environment, else ./CLAUDE.md, else
# ~/.claude/CLAUDE.md (claude-md-field.sh grammar). slug = basename,
# lowercased, non-[a-z0-9] -> '-'.
#
# list     (Step 0) REPOS_ROOT unset -> PRESCAN|env-check|fail|REPOS_ROOT not set,
#          exit 1. Prints REPOS_ROOT, WIKI_ROOT, then `REPO=<path>|<slug>` for
#          REPO_PATH, else every git repo under REPOS_ROOT (depth <= 3), sorted.
# gate     (Step 1 + the lock) PRESCAN|freshness-gate|start, prescan-check.sh,
#          the prescan-gate heartbeat, then skip (fresh) or done (stale |
#          decayed | missing) with the old messages. --force skips the check:
#          freshness-gate|done|<slug>: forced — full re-dive. A repo to scan
#          gets a non-blocking flock probe on
#          REPOS_ROOT/.ticket-auto/<slug>/.lock (released before exit; an
#          EXIT trap is installed before the acquire): held ->
#          PRESCAN|lock|skip|<slug>: locked by another process.
#          Prints SLUG, PRESCAN_STATUS, PRESCAN_REASON, CADENCE,
#          RESULT=scan|skipped-fresh|skipped-locked, CHANGED_FILES.
# corrections (Step 4.0) collect_corrections_by_source prescan over the
#          ticket workspaces under .; logs corrections-collect with the
#          count; prints the `  - fact: corrected` lines.
# verify   (scaffold-verify gate) prescan-verify.sh on the repo's docs.
#          Violations -> META|gate-stop|fail|PRESCAN_NO_DOCS — quality
#          violations: N, the prescan-scaffold fail heartbeat, exit 1; clean ->
#          the ok heartbeat. The verifier output is printed.
# --write-meta (Step 6) meta.json: missing | decayed | forced writes every
#          field incl. the full-dive pair; stale bumps last_scanned_* and
#          incremental_scan_count, keeping the full-dive fields. Then
#          prescan-wire-claude-md.sh (with --wiki-root when WIKI_ROOT is set)
#          and PRESCAN|wire|done|<slug>: CLAUDE.md wired. Prints META_PATH.
#
# Exit codes: 0 ok, 1 stop (env, verify or write failure), 2 usage.

_PR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_pr_usage() {
  sed -n '7,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
# shellcheck source=claude-md-field.sh
source "$_PR_DIR/claude-md-field.sh"
set +eo pipefail

_pr_slug() { basename "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }
_pr_log() { # <slug or ""> PHASE STEP STATUS MSG
  local f="$HOME/.claude/logs/prescan.log"
  [ -z "$1" ] || f="$HOME/.claude/logs/prescan-$1.log"
  mkdir -p "$HOME/.claude/logs"
  shift
  bash "$_PR_DIR/plog.sh" --log-file "$f" "$@"
}
_pr_field() { # <KEY>: env, ./CLAUDE.md, ~/.claude/CLAUDE.md
  local v="${!1:-}"
  [ -n "$v" ] || v=$(claude_md_field ./CLAUDE.md "$1" 2>/dev/null) || v=""
  [ -n "$v" ] || v=$(claude_md_field "$HOME/.claude/CLAUDE.md" "$1" 2>/dev/null) || v=""
  printf '%s' "$v"
}
_pr_hb() { bash "$_PR_DIR/hb-wrap.sh" "$@" || true; }

REPOS_ROOT=$(_pr_field REPOS_ROOT)
WIKI_ROOT=$(_pr_field WIKI_ROOT)

_pr_list() {
  [ $# -le 1 ] || _pr_usage
  if [ -z "$REPOS_ROOT" ]; then
    _pr_log "" PRESCAN env-check fail "REPOS_ROOT not set"
    echo "prescan-run-repo: REPOS_ROOT not set" >&2
    exit 1
  fi
  printf 'REPOS_ROOT=%q\nWIKI_ROOT=%q\n' "$REPOS_ROOT" "$WIKI_ROOT"
  if [ -n "${1:-}" ] && [ -d "$1" ]; then
    printf 'REPO=%s|%s\n' "$1" "$(_pr_slug "$1")"
    return 0
  fi
  local d
  while IFS= read -r d; do
    [ -d "$d/.git" ] && printf 'REPO=%s|%s\n' "$d" "$(_pr_slug "$d")"
  done < <(find "$REPOS_ROOT" -maxdepth 3 -name ".git" -printf '%h\n' 2>/dev/null | sort)
  return 0
}

_pr_need_root() {
  [ -n "$REPOS_ROOT" ] || {
    echo "prescan-run-repo: REPOS_ROOT not set" >&2
    exit 1
  }
}

_PR_LOCK_FD=""
_pr_unlock() { [ -z "$_PR_LOCK_FD" ] || flock -u "$_PR_LOCK_FD" 2>/dev/null || true; }

_pr_gate() {
  local repo="$1" force=0 slug cadence result check
  shift
  [ "${1:-}" = --force ] && force=1 && shift
  [ $# -eq 0 ] && [ -d "$repo" ] || _pr_usage
  _pr_need_root
  slug=$(_pr_slug "$repo")
  PRESCAN_STATUS="" PRESCAN_REASON="" CHANGED_FILES=""
  if [ "$force" = 1 ]; then
    cadence=forced result=scan PRESCAN_STATUS=forced PRESCAN_REASON="--force"
    _pr_log "$slug" PRESCAN freshness-gate done "$slug: forced — full re-dive"
  else
    _pr_log "$slug" PRESCAN freshness-gate start "$slug"
    check=$(bash "${PRESCAN_CHECK_SH:-$_PR_DIR/prescan-check.sh}" "$repo" --repos-root "$REPOS_ROOT" 2>/dev/null)
    eval "$check"
    _pr_hb decision "prescan-gate" "fired" "$PRESCAN_STATUS:$PRESCAN_REASON" \
      "{\"status\":\"$PRESCAN_STATUS\",\"reason\":\"$PRESCAN_REASON\"}"
    result=scan
    case "$PRESCAN_STATUS" in
    fresh)
      _pr_log "$slug" PRESCAN freshness-gate skip "$slug: fresh ($PRESCAN_REASON)"
      cadence="" result=skipped-fresh
      ;;
    stale)
      _pr_log "$slug" PRESCAN freshness-gate done "$slug: stale — incremental refresh"
      cadence=stale
      ;;
    decayed)
      _pr_log "$slug" PRESCAN freshness-gate done "$slug: decayed — full re-dive"
      cadence=decayed
      ;;
    missing)
      _pr_log "$slug" PRESCAN freshness-gate done "$slug: missing — first-time scan"
      cadence=missing
      ;;
    *)
      _pr_log "$slug" PRESCAN freshness-gate fail "$slug: unknown prescan status '$PRESCAN_STATUS'"
      cadence="" result=failed
      ;;
    esac
  fi
  if [ "$result" = scan ]; then
    local lock="$REPOS_ROOT/.ticket-auto/$slug/.lock"
    trap _pr_unlock EXIT
    mkdir -p "$(dirname "$lock")"
    exec {_PR_LOCK_FD}>"$lock"
    if ! flock -n "$_PR_LOCK_FD"; then
      _PR_LOCK_FD=""
      _pr_log "$slug" PRESCAN lock skip "$slug: locked by another process"
      result=skipped-locked
    fi
  fi
  printf 'SLUG=%s\nPRESCAN_STATUS=%q\nPRESCAN_REASON=%q\nCADENCE=%s\nRESULT=%s\nCHANGED_FILES=%q\n' \
    "$slug" "$PRESCAN_STATUS" "$PRESCAN_REASON" "$cadence" "$result" "$CHANGED_FILES"
}

_pr_corrections() {
  [ $# -eq 1 ] || _pr_usage
  local slug summary n
  slug=$(_pr_slug "$1")
  # shellcheck source=corrections-parse.sh
  source "$_PR_DIR/corrections-parse.sh"
  set +eo pipefail
  summary=$(collect_corrections_by_source prescan .)
  if [ -n "$summary" ]; then
    n=$(grep -c . <<<"$summary")
    _pr_log "$slug" PRESCAN corrections-collect done "$slug: $n prescan corrections found"
    printf '%s\n' "$summary"
  else
    _pr_log "$slug" PRESCAN corrections-collect done "$slug: no prescan corrections found"
  fi
}

_pr_verify() {
  local repo="$1" cadence="" slug out rc=0 n
  shift
  [ "${1:-}" = --cadence ] && [ -n "${2:-}" ] && [ $# -eq 2 ] || _pr_usage
  cadence="$2"
  _pr_need_root
  slug=$(_pr_slug "$repo")
  out=$(bash "$_PR_DIR/prescan-verify.sh" --docs-dir "$REPOS_ROOT/.ticket-auto/$slug/docs" --cadence "$cadence" 2>&1) || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    n=$(grep -c 'PRESCAN_VERIFY_VIOLATION=' <<<"$out")
    _pr_log "$slug" META gate-stop fail "PRESCAN_NO_DOCS — quality violations: $n"
    _pr_hb gate "prescan-scaffold" "fail" "quality violations" "{\"cadence\":\"$cadence\",\"violations\":\"$n\"}"
    exit 1
  fi
  _pr_hb gate "prescan-scaffold" "ok" "all docs present and valid" "{\"cadence\":\"$cadence\"}"
}

_pr_write_meta() {
  local repo="$1" cadence="" idx=false sym=0 slug meta sha now docs
  shift
  [ "${1:-}" = --write-meta ] || _pr_usage
  shift
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || _pr_usage
    case "$1" in
    --cadence) cadence="$2" ;;
    --gitnexus-indexed) idx="$2" ;;
    --symbols) sym="$2" ;;
    *) _pr_usage ;;
    esac
    shift 2
  done
  case "$idx" in true | false) ;; *) _pr_usage ;; esac
  [[ "$sym" =~ ^[0-9]+$ ]] || _pr_usage
  [ -d "$repo" ] || _pr_usage
  _pr_need_root
  slug=$(_pr_slug "$repo")
  meta="$REPOS_ROOT/.ticket-auto/$slug/meta.json"
  sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || {
    echo "prescan-run-repo: $repo has no HEAD" >&2
    exit 1
  }
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$meta")"
  case "$cadence" in
  missing | decayed | forced)
    docs=$(find "$REPOS_ROOT/.ticket-auto/$slug/docs" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    jq -n --arg sha "$sha" --arg now "$now" --argjson idx "$idx" --argjson sym "$sym" --argjson docs "$docs" '{
      schema_version: "1", last_scanned_sha: $sha, last_scanned_at: $now,
      last_full_dive_sha: $sha, last_full_dive_ts: $now, incremental_scan_count: 0,
      gitnexus_indexed: $idx, gitnexus_symbol_count: $sym, doc_count: $docs }' >"$meta.tmp" &&
      mv "$meta.tmp" "$meta" || exit 1
    ;;
  stale)
    jq --arg sha "$sha" --arg now "$now" \
      '.last_scanned_sha = $sha | .last_scanned_at = $now | .incremental_scan_count = ((.incremental_scan_count // 0) + 1)' \
      "$meta" >"$meta.tmp" && mv "$meta.tmp" "$meta" || {
      rm -f "$meta.tmp"
      echo "prescan-run-repo: cannot update $meta" >&2
      exit 1
    }
    ;;
  *) _pr_usage ;;
  esac
  local wire=(--claude-md "$repo/CLAUDE.md" --prescan-index "$REPOS_ROOT/.ticket-auto/$slug/docs/INDEX.md" --repo-slug "$slug")
  [ -n "$WIKI_ROOT" ] && wire+=(--wiki-root "$WIKI_ROOT")
  bash "$_PR_DIR/prescan-wire-claude-md.sh" "${wire[@]}"
  _pr_log "$slug" PRESCAN wire done "$slug: CLAUDE.md wired"
  echo "META_PATH=$meta"
}

case "${1:-}" in
list)
  shift
  _pr_list "$@"
  ;;
gate)
  shift
  [ $# -ge 1 ] || _pr_usage
  _pr_gate "$@"
  ;;
corrections)
  shift
  _pr_corrections "$@"
  ;;
verify)
  shift
  [ $# -ge 1 ] || _pr_usage
  _pr_verify "$@"
  ;;
"" | -*) _pr_usage ;;
*) _pr_write_meta "$@" ;;
esac
exit 0
