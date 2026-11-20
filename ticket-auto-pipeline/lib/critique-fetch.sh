#!/usr/bin/env bash
# critique-fetch.sh — ticket-critique's Input step (skill-deterministic-
# extraction 6a): load the ticket text the Checklist runs on.
#
# Usage:
#   critique-fetch.sh <TICKET-ID> --from-audit [--source-marker M]
#   critique-fetch.sh <TICKET-ID> --from-appraise | --workspace
#
# --from-audit (also --no-post): no workspace is guaranteed, so the ticket
#   comes from the Linear API. A failed fetch or an unreadable payload is a
#   hard stop (exit 1): never score blank fields as an empty ticket (#362).
#   Prints TITLE/LABELS/STATE (shell-quoted), SOURCE_MARKER when given, then
#   `=== DESCRIPTION ===`, `=== COMMENTS ===` (the first 5 comment body
#   lines) and `=== CLAUDE.md ===` (test users / UAT_URL / LOCAL_URL lines of
#   ./CLAUDE.md).
# --from-appraise: the workspace is guaranteed; prints TICKET_DIR.
# --workspace (no recognised flag): finds the `<TID>*` workspace dir under
#   ., prints TICKET_DIR, exit 3 when there is none (run /ticket-appraise
#   first).
# Every mode also prints TICKET_TYPE (#677): ticket-type.sh's answer — the
#   local manifest type, else `bug` for a whole `bug` label (the issue's
#   labels, or context.md's `**Labels:**` line), else `feature`. Checks 5/6
#   branch on it, so a planned bug, which has no label, gets the bug checks.
#   REPOS_ROOT comes from the env, else ./CLAUDE.md.
#
# Exit codes: 0 ok, 1 fetch failed, 3 no workspace, 2 usage.

_CF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_cf_usage() {
  sed -n '6,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
TID="${1:-}"
MODE="${2:-}"
[ -n "$TID" ] && [ "${TID#-}" = "$TID" ] || _cf_usage
shift 2 2>/dev/null || _cf_usage
_marker=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || _cf_usage
  case "$1" in
  --source-marker) _marker="$2" ;;
  *) _cf_usage ;;
  esac
  shift 2
done

# shellcheck source=ticket-type.sh
source "$_CF_DIR/ticket-type.sh"
# shellcheck source=claude-md-field.sh
source "$_CF_DIR/claude-md-field.sh"
_cf_type() {
  local t
  if [ -z "${REPOS_ROOT:-}" ]; then
    REPOS_ROOT=$(claude_md_field CLAUDE.md REPOS_ROOT 2>/dev/null) || REPOS_ROOT=""
    export REPOS_ROOT
  fi
  t=$(ticket_type_resolve "$TID" "$1")
  printf 'TICKET_TYPE=%q\n' "${t:-feature}"
}

_cf_workspace() {
  local d
  d=$(find . -maxdepth 3 -type d -name "${TID}*" 2>/dev/null | head -1)
  if [ -z "$d" ]; then
    echo "critique-fetch: no workspace for $TID — run /ticket-appraise $TID first" >&2
    exit 3
  fi
  printf 'TICKET_DIR=%q\n' "$d"
  _cf_type "$(ticket_type_context_labels "$d/context.md")"
}

case "$MODE" in
--from-appraise | --workspace)
  [ -z "$_marker" ] || _cf_usage
  _cf_workspace
  exit 0
  ;;
--from-audit) ;;
*) _cf_usage ;;
esac

# shellcheck source=linear-api.sh
source "$_CF_DIR/linear-api.sh"
# shellcheck source=config.sh
source "$_CF_DIR/config.sh"
set +eo pipefail

ISSUE_JSON=$(get_issue "$TID") || {
  echo "ticket-critique: get_issue failed for $TID — stopping" >&2
  exit 1
}
require_issue_payload "$ISSUE_JSON" || {
  echo "ticket-critique: get_issue returned an unreadable payload for $TID — stopping" >&2
  exit 1
}
printf 'TITLE=%q\n' "$(jq -r '.title' <<<"$ISSUE_JSON")"
printf 'LABELS=%q\n' "$(jq -r '[(.labels.nodes? // .labels // [])[]?.name] | join(", ")' <<<"$ISSUE_JSON" 2>/dev/null)"
printf 'STATE=%q\n' "$(jq -r '.state.name' <<<"$ISSUE_JSON")"
_cf_type "$(jq -r '[(.labels.nodes? // .labels // [])[]?.name] | join(",")' <<<"$ISSUE_JSON" 2>/dev/null)"
[ -z "$_marker" ] || printf 'SOURCE_MARKER=%q\n' "$_marker"
echo "=== DESCRIPTION ==="
jq -r '.description // ""' <<<"$ISSUE_JSON"
echo "=== COMMENTS ==="
_comments=$(get_comments "$TID" 2>/dev/null) || _comments="[]"
jq -r '.[]?.body // ""' <<<"$_comments" 2>/dev/null | head -5
echo "=== CLAUDE.md ==="
grep -A5 "test users\|UAT_URL\|LOCAL_URL" CLAUDE.md 2>/dev/null || true
exit 0
