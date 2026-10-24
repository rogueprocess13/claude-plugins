#!/usr/bin/env bash
# critique-status.sh — ticket-critique status + action decision (DET-AP-1, bug part).
#
# The skill's "Determine status" rules produce BLOCKED three ways (any BLOCKER,
# score < 40, >= 3 WARNINGs), but "Act on results" only branched on "any
# BLOCKERs found" — so a ticket BLOCKED by a low score or by cumulative WARNING
# escalation got no needs-info comment or label, and its "WARNINGs only"
# branch claimed it. This script is the one decision both sections now use:
# the action follows the status, never the BLOCKER count alone.
#
# Usage: critique-status.sh --score N --blockers B --warnings W
# Output (eval-safe KEY=VALUE):
#   CRITIQUE_STATUS=BLOCKED|WARNINGS|CLEAR
#   CRITIQUE_BLOCK_REASON=blocker|low-score|cumulative-warnings|none
#   CRITIQUE_ACTION=needs-info|warn|clear
#   CRITIQUE_VERDICT=BLOCK|WARN|PASS        (write_verifier_result verdict)
#   CRITIQUE_CRITERIA_MET=<score/10>        (write_verifier_result criteria_met)
# Exit: 0 ok, 2 usage / non-integer input.
#
# Rules (ticket-critique "Determine status", first match wins):
#   1. blockers >= 1          → BLOCKED (blocker)
#   2. score < 40             → BLOCKED (low-score)
#   3. warnings >= 3          → BLOCKED (cumulative-warnings)
#   4. score 40-69            → WARNINGS
#   5. score >= 70            → CLEAR
set -euo pipefail

score="" blockers="" warnings=""
while [ $# -gt 0 ]; do
  case "$1" in
  --score) score="${2:-}" ;;
  --blockers) blockers="${2:-}" ;;
  --warnings) warnings="${2:-}" ;;
  *)
    echo "critique-status: unknown argument: $1" >&2
    exit 2
    ;;
  esac
  shift 2 || {
    echo "critique-status: $1 requires a value" >&2
    exit 2
  }
done

for v in "$score" "$blockers" "$warnings"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "Usage: critique-status.sh --score N --blockers B --warnings W (non-negative integers)" >&2
    exit 2
  fi
done
if [ "$score" -gt 100 ]; then
  echo "critique-status: score out of range: $score" >&2
  exit 2
fi

if [ "$blockers" -ge 1 ]; then
  status=BLOCKED reason=blocker
elif [ "$score" -lt 40 ]; then
  status=BLOCKED reason=low-score
elif [ "$warnings" -ge 3 ]; then
  status=BLOCKED reason=cumulative-warnings
elif [ "$score" -lt 70 ]; then
  status=WARNINGS reason=none
else
  status=CLEAR reason=none
fi

case "$status" in
BLOCKED) action=needs-info verdict=BLOCK ;;
WARNINGS) action=warn verdict=WARN ;;
*) action=clear verdict=PASS ;;
esac

echo "CRITIQUE_STATUS=$status"
echo "CRITIQUE_BLOCK_REASON=$reason"
echo "CRITIQUE_ACTION=$action"
echo "CRITIQUE_VERDICT=$verdict"
echo "CRITIQUE_CRITERIA_MET=$((score / 10))"
