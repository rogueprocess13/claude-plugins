#!/usr/bin/env bash
# epic-precondition.sh — the epic discriminator and precondition evaluator.
#
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). flow.sh sources this file and calls into it, so tests that source
# it exercise the executor's real evaluation rather than re-implementing the
# condition inline — the failure mode that let the previous, always-true
# discriminator survive with a green suite.
#
# Dependencies: manifest-read.sh, for the epic-manifest-presence check that
# is the discriminator's only signal (tracker-planner-and-fallback-cutover,
# 3.6 — the marker-label and Branch-Directive fallback arms are retired).

# manifest-read.sh backs the epic-manifest-presence check in is_epic_issue
# below (tracker-local-facts-read-migration). Guarded — flow.sh's own
# sourcing of planned-ticket-check.sh already brings this in transitively in
# production, but this file is also sourced standalone in isolated tests.
if ! declare -f epic_manifest_exists >/dev/null 2>&1; then
  _EPC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$_EPC_LIB_DIR/manifest-read.sh" ] && source "$_EPC_LIB_DIR/manifest-read.sh"
fi

# is_epic_issue <issue_json>
# Returns 0 when the issue is an epic, 1 otherwise.
#
# tracker-planner-and-fallback-cutover (3.6): manifest-only — an epic
# manifest existing for this issue's identifier IS proof of epic-ness
# (only EpicGen writes one), with no label or Branch-Directive fallback.
# <issue_json> is kept as the parameter shape (every caller already has a
# payload in hand, even if only `{"identifier": "..."}` — flow.sh's own
# synthetic payload) so only `.identifier`/`.id` is ever read from it; a
# caller with no other reason to build a payload may pass `{}` — with no
# identifier, this correctly reports "not an epic".
is_epic_issue() {
  local issue_json="$1"

  local identifier
  identifier=$(echo "$issue_json" | jq -r '.identifier // .id // empty' 2>/dev/null || true)
  [ -n "$identifier" ] && declare -f epic_manifest_exists >/dev/null 2>&1 &&
    epic_manifest_exists "$identifier" 2>/dev/null
}

# check_precondition <precondition> <subject> <issue_json>
# Evaluates a precondition declared on a trigger or a label.
#
# Exit codes: 0 satisfied, 8 rejected, 9 unknown precondition.
# <subject> names the trigger or label, for the operator-facing message.
check_precondition() {
  local pre="$1"
  local subject="$2"
  local issue_json="$3"

  case "$pre" in
  must_be_epic)
    if is_epic_issue "$issue_json"; then
      return 0
    fi
    echo "precondition failed — '${subject}' applies only to epic issues (no epic manifest found)" >&2
    return 8
    ;;
  must_not_be_epic)
    if is_epic_issue "$issue_json"; then
      echo "precondition failed — '${subject}' is a child lifecycle transition and cannot be applied to an epic issue" >&2
      return 8
    fi
    return 0
    ;;
  "" | null)
    return 0
    ;;
  *)
    echo "unknown precondition '${pre}' declared for '${subject}'" >&2
    return 9
    ;;
  esac
}
