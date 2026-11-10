#!/usr/bin/env bash
# ai-context-prep.sh — ticket-document Steps 0-2 in one call
# (skill-deterministic-extraction 6a): the corrections count, the
# `document start` log line, the worktree/branch, and the branch's diff and
# log against the base's remote ref.
#
# Usage:
#   ai-context-prep.sh <TICKET-ID> --ticket-dir D [--worktree W] [--branch B]
#
# Sources the ticket's env file (ticket-env.sh) for BASE_BRANCH/BASE_REF and
# the pipeline log. An empty --worktree/--branch counts as not given; both
# then come from the last `Branch: … | Worktree: …` line of D/notes.md (the
# ticket-implement pre-implementation checkpoint), and the branch, if still
# missing, from `git -C W branch --show-current`.
#
# Writes MAINTENANCE|document|start|Reading notes.md for context, then prints:
#   CORRECTION_COUNT=<n>  WORKTREE_PATH=<w>  BRANCH=<b>  BASE_REF=<ref>
#   CORRECTION_<i>_FACT/_SOURCE/_CORRECTED lines (corrections-parse.sh)
#   === GIT LOG ===   `git log BASE_REF..B --oneline`
#   === GIT DIFF ===  `git diff BASE_REF...B`
#
# The diff is against the remote ref after a fetch: on a per-epic branch the
# local epic ref only moves when someone fetches, so a stale local ref would
# attribute a previous ticket's commits to this one.
#
# Exit codes: 0 ok, 3 worktree or branch unresolved (nothing fetched; pass
# them from the spawn instruction), 2 usage.

_AP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ap_usage() {
  sed -n '7,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

_tid="${1:-}"
[ -n "$_tid" ] && [ "${_tid#-}" = "$_tid" ] || _ap_usage
shift
_td="" _wt="" _br=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || _ap_usage
  case "$1" in
  --ticket-dir) _td="$2" ;;
  --worktree) _wt="$2" ;;
  --branch) _br="$2" ;;
  *) _ap_usage ;;
  esac
  shift 2
done
[ -n "$_td" ] || _ap_usage

# shellcheck source=ticket-env.sh
source "$_AP_DIR/ticket-env.sh" "$_tid"
# shellcheck source=corrections-parse.sh
source "$_AP_DIR/corrections-parse.sh"
set +eo pipefail # corrections-parse.sh sets them at file scope

_corr=$(get_corrections "$_td/notes.md" 2>/dev/null) || _corr="CORRECTION_COUNT=0"
eval "$_corr"
bash "$_AP_DIR/plog.sh" MAINTENANCE document start "Reading notes.md for context"

if [ -z "$_wt" ] || [ -z "$_br" ]; then
  _ck=$(grep -E 'Branch: .*\| *Worktree: ' "$_td/notes.md" 2>/dev/null | tail -1)
  if [ -n "$_ck" ]; then
    [ -n "$_br" ] || _br=$(sed -E 's/.*Branch: *([^ |]+).*/\1/' <<<"$_ck")
    [ -n "$_wt" ] || _wt=$(sed -E 's/.*Worktree: *([^ |]+).*/\1/' <<<"$_ck")
  fi
fi
if [ -n "$_wt" ] && [ -z "$_br" ]; then
  _br=$(git -C "$_wt" branch --show-current 2>/dev/null) || _br=""
fi
_base_ref="${BASE_REF:-origin/${BASE_BRANCH:-develop}}"

echo "CORRECTION_COUNT=${CORRECTION_COUNT:-0}"
printf 'WORKTREE_PATH=%q\n' "$_wt"
printf 'BRANCH=%q\n' "$_br"
printf 'BASE_REF=%q\n' "$_base_ref"
grep '^CORRECTION_[0-9]' <<<"$_corr" || true

if [ -z "$_wt" ] || [ ! -d "$_wt" ] || [ -z "$_br" ]; then
  echo "ai-context-prep: worktree or branch unresolved (worktree='$_wt' branch='$_br') — pass --worktree/--branch" >&2
  exit 3
fi

git -C "$_wt" fetch origin "${BASE_BRANCH:-develop}" --quiet 2>/dev/null || true
echo "=== GIT LOG ==="
git -C "$_wt" log "$_base_ref..$_br" --oneline
echo "=== GIT DIFF ==="
git -C "$_wt" diff "$_base_ref...$_br"
exit 0
