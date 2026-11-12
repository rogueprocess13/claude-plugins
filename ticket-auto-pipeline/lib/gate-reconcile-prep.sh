#!/usr/bin/env bash
# gate-reconcile-prep.sh — ticket-gate-reconcile Steps 1-4 in one call
# (skill-deterministic-extraction 6a). Run from the tickets repo root.
#
# Usage:
#   gate-reconcile-prep.sh <TICKET-ID> [--comments-file F]
#
# 1. Sources the ticket env file; the pipeline log is <log-dir>/<TID>-pipeline.log
#    and the heartbeat log <log-dir>/<TID>-heartbeat.log (<log-dir>: the
#    lib/log-dir.sh anchor, else ./logs).
# 2. Resolves the ticket dir, notes.md, COMPLEXITY (get_complexity), the
#    artifact type (EXEC create-artifact line, else notes.md, else
#    simple-fix) and the plan artifact (lib/ticket-dir.sh's one resolver).
#    An openspec ticket with no unique change dir under ./openspec/changes/
#    logs GATE|reconcile|fail|openspec tasks.md for <TID> not found under …
#    and exits 1: never amend another change's tasks.md.
# 3. hb_init + the `reconcile` gate-start heartbeat.
# 4. RECONCILE_N = distinct `GATE|reconcile|done|cycle#N` numbers + 1.
# 5. Comments: F when given (the MCP list_comments JSON), else get_comments
#    with LINEAR_API_KEY; neither -> exit 4. Normalized, then run through
#    reconcile-comments.sh. With LINEAR_API_KEY the tracker description is
#    written to <ticket-dir>/artifacts/tracker-description.md for Step 8.
# 6. The unstruck `- [needs-human]` bullets of notes.md `## Open Questions`.
#
# Prints TICKET_DIR, NOTES_PATH, ARTIFACT_TYPE, ARTIFACT_PATH, COMPLEXITY,
# RECONCILE_N, TAP_LOG (KEY=value lines), then `=== RECONCILE_OUTPUT ===`
# (reconcile-comments.sh's output) and `=== OPEN_QUESTIONS ===`.
#
# Exit codes: 0 ok, 1 no plan artifact for an openspec ticket, 4 no way to
# fetch comments, 2 usage.

_GR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_gr_usage() {
  sed -n '6,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
TID="${1:-}"
[ -n "$TID" ] && [ "${TID#-}" = "$TID" ] || _gr_usage
shift
_comments_file=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || _gr_usage
  case "$1" in
  --comments-file) _comments_file="$2" ;;
  *) _gr_usage ;;
  esac
  shift 2
done

# shellcheck source=ticket-env.sh
source "$_GR_DIR/ticket-env.sh" "$TID"
# The logs live in the anchored per-ticket state dir (lib/log-dir.sh,
# state-root-anchor), else (legacy, with a warning) ./logs under the tickets
# repo root; STATE_ROOT_STRICT=true and unresolved exits 13.
_gr_log_dir="$PWD/logs"
if [ -f "$_GR_DIR/log-dir.sh" ]; then
  # shellcheck source=log-dir.sh
  source "$_GR_DIR/log-dir.sh"
  _gr_ld_rc=0
  ticket_log_dir_or_legacy_set "$PWD/logs" || _gr_ld_rc=$?
  if [ "$_gr_ld_rc" -ne 0 ]; then
    exit "$_gr_ld_rc"
  fi
  _gr_log_dir="$TICKET_LOG_DIR_RESOLVED"
fi
export TAP_LOG="$_gr_log_dir/$TID-pipeline.log"
export HB_LOG_FILE="$_gr_log_dir/$TID-heartbeat.log"
# Sourced libs set errexit/pipefail at file scope; this script decides its
# own exits.
# shellcheck source=ticket-dir.sh
source "$_GR_DIR/ticket-dir.sh"
# shellcheck source=notes-parse.sh
source "$_GR_DIR/notes-parse.sh"
set +eo pipefail

TICKET_DIR=$(resolve_ticket_dir "$TID" "." 2>/dev/null || echo ".")
NOTES_PATH="$TICKET_DIR/notes.md"
if [ -f "$NOTES_PATH" ]; then
  COMPLEXITY=$(get_complexity "$TICKET_DIR" 2>/dev/null || echo "$COMPLEXITY")
fi
ARTIFACT_TYPE=$(resolve_artifact_type "$TAP_LOG" "$NOTES_PATH")
ARTIFACT_TYPE="${ARTIFACT_TYPE:-simple-fix}"

PLAN_PATH=""
_plan_rc=0
_plan_out=$(resolve_plan_artifact "$TID" --root . --ticket-dir "$TICKET_DIR" --type "$ARTIFACT_TYPE") || _plan_rc=$?
[ "$_plan_rc" -eq 0 ] && eval "$_plan_out"
if [ "$ARTIFACT_TYPE" = "openspec" ]; then
  ARTIFACT_PATH="$PLAN_PATH"
  if [ "$_plan_rc" -ne 0 ] || [ ! -f "$ARTIFACT_PATH" ]; then
    bash "$_GR_DIR/plog.sh" GATE reconcile fail "openspec tasks.md for $TID not found under $PWD/openspec/changes/ (resolver rc=$_plan_rc)"
    echo "ticket-gate-reconcile: no unique openspec change for $TID under $PWD/openspec/changes/ — cannot amend the plan" >&2
    exit 1
  fi
else
  ARTIFACT_PATH="${PLAN_PATH:-$TICKET_DIR/simple-fix.md}"
fi

(
  # shellcheck source=heartbeat.sh
  source "$_GR_DIR/heartbeat.sh"
  hb_init
) >/dev/null 2>&1 || true
bash "$_GR_DIR/hb-wrap.sh" gate "reconcile" "info" "gate-reconcile agent starting" "{\"complexity\":\"$COMPLEXITY\"}"

# Distinct cycle numbers, not lines — the router echoes `cycle#N` in its own
# done line, so a line count double-counts (same rule as detect-resume.sh).
RECONCILE_N=$(grep -o '^[^|]*|GATE|reconcile|done|cycle#[0-9]*' "$TAP_LOG" 2>/dev/null |
  sed 's/.*cycle#//' | sort -u | wc -l | tr -d ' ')
RECONCILE_N=$((${RECONCILE_N:-0} + 1))

if [ -n "$_comments_file" ]; then
  COMMENTS_JSON=$(cat "$_comments_file" 2>/dev/null) || COMMENTS_JSON=""
elif [ -n "${LINEAR_API_KEY:-}" ]; then
  COMMENTS_JSON=$(bash -c 'source "$1/linear-api.sh"; get_comments "$2"' _ "$_GR_DIR" "$TID")
else
  echo "gate-reconcile-prep: LINEAR_API_KEY unset — fetch the comments with mcp__linear-server__list_comments, save the JSON to a file and re-run with --comments-file <file>" >&2
  exit 4
fi
COMMENTS_JSON=$(bash -c 'source "$1/linear-api.sh"; normalize_comments' _ "$_GR_DIR" <<<"$COMMENTS_JSON")

if [ -n "${LINEAR_API_KEY:-}" ]; then
  mkdir -p "$TICKET_DIR/artifacts"
  bash -c 'source "$1/linear-api.sh"; get_issue "$2"' _ "$_GR_DIR" "$TID" | jq -r '.description // ""' >"$TICKET_DIR/artifacts/tracker-description.md"
fi

RECONCILE_OUTPUT=$(bash "$_GR_DIR/reconcile-comments.sh" "$TID" "$TAP_LOG" <<<"$COMMENTS_JSON")

RAW_SECTION=$(sed -n '/^## Open Questions/,/^## /p' "$NOTES_PATH" 2>/dev/null)
if grep -q '^## ' <<<"$RAW_SECTION"; then
  RAW_SECTION=$(sed '/^## Open Questions$/!{/^## /q}' <<<"$RAW_SECTION")
fi
# Only unstruck [needs-human] bullets reach the gate; [agent-resolvable] ones
# are closed by ticket-appraise Step 3.5 with a verified path:line citation.
OPEN_QUESTIONS_LIST=$(grep '^\- \[needs-human\]' <<<"$RAW_SECTION" || true)

printf 'TICKET_DIR=%q\nNOTES_PATH=%q\nARTIFACT_TYPE=%q\nARTIFACT_PATH=%q\nCOMPLEXITY=%q\nRECONCILE_N=%s\nTAP_LOG=%q\n' \
  "$TICKET_DIR" "$NOTES_PATH" "$ARTIFACT_TYPE" "$ARTIFACT_PATH" "$COMPLEXITY" "$RECONCILE_N" "$TAP_LOG"
echo "=== RECONCILE_OUTPUT ==="
printf '%s\n' "$RECONCILE_OUTPUT"
echo "=== OPEN_QUESTIONS ==="
[ -z "$OPEN_QUESTIONS_LIST" ] || printf '%s\n' "$OPEN_QUESTIONS_LIST"
exit 0
