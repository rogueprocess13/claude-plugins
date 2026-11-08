#!/usr/bin/env bash
# reconcile-comments.sh — boundary detection for pipeline comment reconciliation.
# Reads normalized comments JSON array from stdin.
# Args: <ticket_id> <log_file>
# Outputs structured key:value data for the orchestrator to parse.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

TICKET_ID="${1:-}"
LOG_FILE="${2:-}"
[ -z "$TICKET_ID" ] && {
  echo "Usage: $0 <ticket_id> <log_file>" >&2
  exit 1
}
[ -z "$LOG_FILE" ] && {
  echo "Usage: $0 <ticket_id> <log_file>" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/linear-api.sh"

# Read stdin and normalize
COMMENTS_JSON=$(cat | normalize_comments)

# Pipeline-authored comments are recognised by a hidden marker the posting
# skill appends verbatim (GitHub #568/#582): agents paraphrase the bold
# heading ("**Ticket appraised.**"), so an exact prefix match let the
# pipeline's own comment count as unprocessed user feedback. Comments
# without the marker (legacy, or a marker the agent dropped) fall back to a
# tolerant heading match.
APPRAISAL_MARKER='<!-- ticket-auto:appraisal -->'
AMENDMENT_MARKER='<!-- ticket-auto:amendment -->'
# shellcheck disable=SC2016 # jq program, not shell expansion
JQ_DEFS='
  def is_appraisal: (.body // "") as $b
    | ($b | contains($appraisal_marker))
      or ($b | test("^\\s*\\*\\*\\s*Ticket appraised\\b"; "i"));
  def is_amendment: (.body // "") as $b
    | ($b | contains($amendment_marker))
      or ($b | test("^\\s*\\*\\*\\s*Amendment cycle\\s*#"; "i"));
'
_jq() {
  jq -r --arg appraisal_marker "$APPRAISAL_MARKER" \
    --arg amendment_marker "$AMENDMENT_MARKER" "$@"
}

# Find appraisal comment
APPRAISAL_COMMENT_AT=$(echo "$COMMENTS_JSON" | _jq \
  "$JQ_DEFS"' .[] | select(is_appraisal) | .createdAt' |
  sort | tail -1)

# Fallback to pipeline log if no appraisal comment found (deleted, or pre-standardization)
if [ -z "$APPRAISAL_COMMENT_AT" ]; then
  APPRAISAL_COMMENT_AT=$(grep '|APPRAISE|appraise|done|' "$LOG_FILE" 2>/dev/null |
    head -1 | cut -d'|' -f1 || true)
fi

# Find last amendment comment from a prior reconciliation cycle
LAST_AMENDMENT_AT=$(echo "$COMMENTS_JSON" | _jq \
  "$JQ_DEFS"' .[] | select(is_amendment) | .createdAt' |
  sort | tail -1)

# LAST_RECONCILE_AT is the later of appraisal vs amendment boundary
if [ -n "$LAST_AMENDMENT_AT" ] && [[ "$LAST_AMENDMENT_AT" > "$APPRAISAL_COMMENT_AT" ]]; then
  LAST_RECONCILE_AT="$LAST_AMENDMENT_AT"
else
  LAST_RECONCILE_AT="$APPRAISAL_COMMENT_AT"
fi

# Extract comments strictly after boundary, excluding pipeline-authored comments
UNPROCESSED_COMMENTS=$(echo "$COMMENTS_JSON" | _jq --arg boundary "$LAST_RECONCILE_AT" \
  "$JQ_DEFS"' .[] | select(.createdAt > $boundary) | select((is_appraisal or is_amendment) | not) | "\(.createdAt)|\(.user.name)|\(.body)"')

echo "LAST_RECONCILE_AT: ${LAST_RECONCILE_AT}"
echo "APPRAISAL_COMMENT_AT: ${APPRAISAL_COMMENT_AT}"
echo "UNPROCESSED_COMMENTS:"
if [ -n "$UNPROCESSED_COMMENTS" ]; then
  echo "$UNPROCESSED_COMMENTS"
else
  echo "(none)"
fi
