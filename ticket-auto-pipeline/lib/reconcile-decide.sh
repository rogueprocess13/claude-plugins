#!/usr/bin/env bash
# reconcile-decide.sh — the gate-reconcile hold decision (GitHub #599).
#
# ticket-gate-reconcile used to hold on any unprocessed comment. The pipeline
# and the operator post as the same tracker account, so the operator's own
# answer to an open question counted as "unreviewed change" and cost one more
# /ticket-approve round with nothing left to review. The agent still judges
# each comment (answer-only vs new-input) and strikes answered questions in
# notes.md. This script makes the decision from those results.
#
# Usage:
#   reconcile-decide.sh --notes <notes.md> --comments <N> [--new-input <N>]
#
#   --comments   number of unprocessed comments (reconcile-comments.sh)
#   --new-input  how many of them are new input: a new requirement, a scope
#                change, a disagreement with the plan, or a question back.
#                Omitted means all of them (the safe direction: hold).
#
# Reads notes.md AFTER the amendment step: the open questions are the
# unstruck `- [needs-human]` bullets of `## Open Questions` (struck ones read
# `- ~~[needs-human] …~~` and do not match). New questions raised by the
# amendment are open bullets too, so they hold.
#
# Output (KEY=value):
#   OPEN_QUESTIONS=<n>
#   RECONCILE_DECISION=hold | clean-recorded | clean
#     hold            post the amendment, re-claim, hold
#     clean-recorded  answers recorded: post the amendment comment (moves the
#                     reconcile boundary past them) WITHOUT re-claim, then pass
#     clean           nothing to record, pass
#   HOLD_REASON=unanswered_questions | unprocessed_comments | both joined by +
#
# Exit: 0 decided, 2 usage.

_rd_usage() {
  echo "usage: reconcile-decide.sh --notes <notes.md> --comments <N> [--new-input <N>]" >&2
  exit 2
}

notes="" comments="" new_input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --notes)
    notes="${2:-}"
    shift 2 || _rd_usage
    ;;
  --comments)
    comments="${2:-}"
    shift 2 || _rd_usage
    ;;
  --new-input)
    new_input="${2:-}"
    shift 2 || _rd_usage
    ;;
  *) _rd_usage ;;
  esac
done

case "$comments" in '' | *[!0-9]*) _rd_usage ;; esac
[ -n "$new_input" ] || new_input="$comments"
case "$new_input" in *[!0-9]*) _rd_usage ;; esac
[ "$new_input" -le "$comments" ] || new_input="$comments"

open=0
if [ -n "$notes" ] && [ -f "$notes" ]; then
  open=$(awk '
    /^## Open Questions[[:space:]]*$/ { f = 1; next }
    f && /^## / { exit }
    f && /^- \[needs-human\]/ { n++ }
    END { print n + 0 }
  ' "$notes")
fi

reason=""
[ "$open" -gt 0 ] && reason="unanswered_questions"
if [ "$new_input" -gt 0 ]; then
  reason="${reason:+$reason+}unprocessed_comments"
fi

if [ -n "$reason" ]; then
  decision=hold
elif [ "$comments" -gt 0 ]; then
  decision=clean-recorded
else
  decision=clean
fi

echo "OPEN_QUESTIONS=$open"
echo "RECONCILE_DECISION=$decision"
echo "HOLD_REASON=$reason"
exit 0
