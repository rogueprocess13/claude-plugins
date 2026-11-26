#!/usr/bin/env bash
# ticket-approve: the sole actuator for human approval (tracker-approval-
# by-script). An operator script: a person runs it in their own terminal.
#
#   bash ~/.claude/skills/ticket-approve/approve.sh <TICKET-ID>
#
# Run it from the tickets root. REPOS_ROOT comes from the environment, else
# the ticket's env file, else ./CLAUDE.md. When ./CLAUDE.md declares one and
# the root came from elsewhere, the two must agree, and the ticket's manifest
# must already exist under the root (lib/operator-root.sh; else exit 3,
# nothing recorded). The prompt names the manifest the approval goes into.
#
# It shows the ticket and its current stage on the controlling terminal and
# asks for the ticket id to be typed back. Only a matching answer runs
# `flow.sh <TID> human-approve --provenance human` (Approve -> Ready,
# manifest approved: true / approval_provenance: human) and, when the
# manifest carries the needs-info flag, `flow.sh <TID> needs-info-resolved`.
# Applying the (now unread) `approved` label in the tracker's own UI does not
# approve a ticket: only this script does.
#
# The approval is of a specific plan (lib/plan-binding.sh). The prompt shows
# the plan's short id (12 hex) and its files; right after flow.sh it records
# `approved_plan` (type, and per file the relative path, byte size and
# sha256 of the content with task checkboxes unticked). Every reader of a
# person's approval checks the plan on disk against it: appends pass, any
# other change holds the ticket (PLAN_CHANGED_SINCE_APPROVAL) until a person
# runs this again. No plan, or one that cannot be hashed or shown as plain
# text, is a refusal (exit 7).
#
# Who may run it (lib/human-terminal.sh), both refused with exit 4:
#   1. CLAUDE_CODE_SESSION_ID, FLEET_WORKER_PID or FLEET_GENERATION is set
#      (an agent session or a fleetd worker).
#   2. There is no controlling terminal. The prompt is written to and the
#      answer read from /dev/tty, never stdin.
# There is no flag and no variable that skips either check, and flow.sh and
# the manifest writer apply the same refusal for provenance human, so calling
# them directly is no way round. The /ticket-approve skill therefore does not
# run this script: it prints the command for the person to run.
#
# What this guarantees: an unattended agent run, and an agent that only
# unsets the variables, cannot record a human approval. What it does not: a
# process that allocates its own pseudo-terminal and types the id can, and so
# can anything that writes the manifest file directly. Closing that needs a
# store the agent cannot write. The plan binding does not change that: the
# manifest, the record in it included, is still a file an agent can write.
# It binds the approval to one plan version and makes a later rewrite of
# that plan visible and blocking.
#
# Exit: 0 approved (or already approved for this exact plan), 1 usage,
#       2 flow.sh or a library not found, 3 REPOS_ROOT unresolved or disagreeing with
#       ./CLAUDE.md, or no manifest for the ticket under it,
#       4 agent context or no terminal, 5 the manifest does not show the
#       approval after the write, 6 the typed id did not match or the plan
#       changed while on screen (nothing recorded), 7 no plan, or one that
#       cannot be hashed or shown (nothing recorded), 8 the plan binding
#       could not be recorded (the ticket stays held), else flow.sh's code.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"

usage() {
  echo "Usage: $0 <TICKET-ID>" >&2
  exit 1
}

TICKET_ID="${1:-}"
[ -n "$TICKET_ID" ] || usage
[ $# -eq 1 ] || usage
[[ "$TICKET_ID" =~ ^[A-Z]+-[0-9]+$ ]] || usage

# ── A person, at a terminal ─────────────────────────────────────────────────
# First, before anything is read or written. A missing library is a refusal.
source "$LIB_DIR/human-terminal.sh" 2>/dev/null ||
  source "$SCRIPT_DIR/../../lib/human-terminal.sh" 2>/dev/null || {
  echo "ticket-approve: lib/human-terminal.sh not found — reinstall the plugin" >&2
  exit 2
}
human_terminal_require "ticket-approve" "approve $TICKET_ID" || exit 4

source "$LIB_DIR/manifest-write.sh"

# REPOS_ROOT in a person's own shell: the environment, else the ticket's env
# file, else the project CLAUDE.md in the current directory. A root that
# disagrees with ./CLAUDE.md is refused (lib/operator-root.sh, GitHub #818):
# a REPOS_ROOT left exported from another project would record the approval
# there while this project's ticket stays held.
source "$LIB_DIR/operator-root.sh" 2>/dev/null ||
  source "$SCRIPT_DIR/../../lib/operator-root.sh" 2>/dev/null || {
  echo "ticket-approve: lib/operator-root.sh not found — reinstall the plugin" >&2
  exit 2
}
operator_resolve_repos_root "ticket-approve" "$TICKET_ID" || exit 3

# ── Resolve flow.sh (standard _flow_sh pattern, lib/skill-preamble-auto.md) ─
# FLOW_SH, if already set by the caller (tests), is respected as-is.

if [ -z "${FLOW_SH:-}" ]; then
  FLOW_SH="$HOME/.claude/skills/ticket-flow/flow.sh"
  if [ ! -f "$FLOW_SH" ]; then
    source "$LIB_DIR/plugin-cache.sh" 2>/dev/null ||
      source "$SCRIPT_DIR/../../lib/plugin-cache.sh" 2>/dev/null || true
    FLOW_SH=$(tap_cache_find ticket-auto-pipeline skills/ticket-flow/flow.sh 2>/dev/null || true)
  fi
fi
if [ -z "$FLOW_SH" ] || [ ! -f "$FLOW_SH" ]; then
  echo "ticket-approve: flow.sh not found — reinstall the plugin" >&2
  exit 2
fi

# The manifest must already exist under the resolved root (GitHub #818). A
# ticket held at the gate always has one: flow.sh wrote it on the way there,
# for a planned and an ad-hoc ticket alike. A missing one means the wrong
# root, so it is an error here, never a create.
MANIFEST_PATH=$(operator_require_manifest "ticket-approve" "$TICKET_ID") || exit 3

# One approval is one fact (GitHub #767). flow.sh emits an event on every
# invocation by design, so a second /ticket-approve on a ticket this script
# already approved used to write a second `human-approved` record with a new
# idem key. When the manifest already records exactly what this run would
# write — approved, by a human, at Ready — there is nothing to approve:
# report it and fire nothing. Anything that ends the approval (re-claim,
# /ticket-reject, implement-complete) clears the fact or moves the stage, so a
# real re-approval after a re-hold still fires, and a human approving over a
# policy approval still records the new provenance. A manifest still holding
# a pending_event (an earlier emit failed) goes through flow.sh, which
# replays it.
# ── The plan being approved (lib/plan-binding.sh) ───────────────────────────
# A person approves a specific plan. It is found the way the gate finds it
# (the log's artifact record, then simple-fix.md, then the change dir, from
# the current directory), hashed, and shown by its short id and file list.
# No plan, a plan that cannot be hashed, or a file name that is not plain
# text is a refusal: nothing is recorded.
source "$LIB_DIR/plan-binding.sh" 2>/dev/null ||
  source "$SCRIPT_DIR/../../lib/plan-binding.sh" 2>/dev/null || {
  echo "ticket-approve: lib/plan-binding.sh not found — reinstall the plugin" >&2
  exit 2
}
source "$LIB_DIR/log-dir.sh" 2>/dev/null ||
  source "$SCRIPT_DIR/../../lib/log-dir.sh" 2>/dev/null || true
_plan_args=()
if declare -f ticket_log_dir_or >/dev/null 2>&1; then
  _plan_log="$(ticket_log_dir_or "$PWD/logs")/${TICKET_ID}-pipeline.log"
else
  _plan_log="$PWD/logs/${TICKET_ID}-pipeline.log"
fi
[ ! -f "$_plan_log" ] || _plan_args=(--log-file "$_plan_log")
_p_rc=0
PLAN_RECORD=$(plan_binding_compute "$TICKET_ID" "${_plan_args[@]}") || _p_rc=$?
case "$_p_rc" in
0) ;;
12)
  echo "ticket-approve: no plan artifact found for $TICKET_ID (simple-fix.md in its ticket dir, or its openspec change dir). Run this from the tickets root. Nothing was recorded." >&2
  exit 7
  ;;
2)
  echo "ticket-approve: the plan for $TICKET_ID could not be resolved or hashed (more than one match, or no sha256 tool). Nothing was recorded." >&2
  exit 7
  ;;
3)
  echo "ticket-approve: the plan for $TICKET_ID holds an entry that is not a regular file (a symlink or a device). Nothing was recorded." >&2
  exit 7
  ;;
4)
  echo "ticket-approve: the pipeline log for $TICKET_ID names another plan than the one in its ticket dir or change dir. Find out which is the plan and remove the other, then run this again. Nothing was recorded." >&2
  exit 7
  ;;
*)
  echo "ticket-approve: the plan for $TICKET_ID could not be found (rc $_p_rc). Nothing was recorded." >&2
  exit 7
  ;;
esac
plan_binding_names_plain "$PLAN_RECORD" || {
  echo "ticket-approve: a file or directory name in the plan for $TICKET_ID is not plain text: it holds control or invisible characters, a pipe or a tab, or is not valid UTF-8. Such a name can hide what a terminal shows, so nothing is displayed and nothing is recorded. Have it renamed, then run this again." >&2
  exit 7
}
PLAN_ID=$(plan_binding_short_id "$PLAN_RECORD")

ALREADY_APPROVED="false"
_pending=$(get_ticket_manifest_field "$TICKET_ID" pending_event 2>/dev/null || true)
# ...and only while the plan recorded with that approval is the plan as it
# stands, byte for byte: a plan that changed since, even only by appended
# bytes, or an approval from before plan binding, is approved again.
if { [ -z "$_pending" ] || [ "$_pending" = "null" ]; } &&
  [ "$(get_ticket_manifest_field "$TICKET_ID" approved 2>/dev/null || true)" = "true" ] &&
  [ "$(get_ticket_manifest_field "$TICKET_ID" approval_provenance 2>/dev/null || true)" = "human" ] &&
  [ "$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)" = "Ready" ] &&
  plan_binding_matches_exactly "$TICKET_ID" "${_plan_args[@]}"; then
  ALREADY_APPROVED="true"
fi

# ── Confirmation ────────────────────────────────────────────────────────────
# Asked whenever this run would change anything: the approval itself, or the
# needs-info clear below. The stage is the manifest's; it is printed only
# when it is a plain word.
NEEDS_INFO_SET="false"
if declare -f ticket_dispatch_blocked_by_flags >/dev/null 2>&1 &&
  ticket_dispatch_blocked_by_flags "$TICKET_ID" 2>/dev/null; then
  NEEDS_INFO_SET="true"
fi
if [ "$ALREADY_APPROVED" != "true" ] || [ "$NEEDS_INFO_SET" = "true" ]; then
  _stage=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)
  [[ "$_stage" =~ ^[A-Za-z]+$ ]] || _stage="unknown"
  _lines=("Approve $TICKET_ID — current stage: $_stage.")
  _lines+=("Recording in: $MANIFEST_PATH (REPOS_ROOT from the $OPERATOR_ROOT_SOURCE)")
  if [ "$ALREADY_APPROVED" = "true" ]; then
    _lines+=("It is already approved. This clears its needs-info flag.")
  else
    _lines+=("This records your approval of its plan and moves it to Ready.")
    [ "$_stage" = "Approve" ] || _lines+=("Note: it is not at the Approve stage. Check that this is the ticket you mean.")
    [ "$NEEDS_INFO_SET" != "true" ] || _lines+=("It also clears the needs-info flag.")
  fi
  _lines+=("Plan: $(jq -r '.type' <<<"$PLAN_RECORD") $PLAN_ID in $(jq -r '.dir' <<<"$PLAN_RECORD"), $(jq -r '.files | length' <<<"$PLAN_RECORD") file(s):")
  while IFS= read -r _pl; do
    _lines+=("  $_pl")
  done < <(jq -r '.files[] | "\(.path) (\(.size) bytes)"' <<<"$PLAN_RECORD")
  [ "$ALREADY_APPROVED" = "true" ] || _lines+=("Your approval is bound to this plan: a later edit to it holds the ticket until you approve again.")
  _lines+=("Read the plan and the appraisal comment first; answer open questions before you approve.")
  _c_rc=0
  human_terminal_confirm "$TICKET_ID" "${_lines[@]}" || _c_rc=$?
  if [ "$_c_rc" -eq 4 ]; then
    echo "ticket-approve: no terminal. Nothing was recorded." >&2
    exit 4
  elif [ "$_c_rc" -ne 0 ]; then
    echo "ticket-approve: not approved — the id typed did not match. Nothing was recorded." >&2
    exit 6
  fi
fi

if [ "$ALREADY_APPROVED" != "true" ]; then
  # The plan must still be what was shown: one changed while the person was
  # reading is not what they approved.
  _now=$(plan_binding_compute "$TICKET_ID" "${_plan_args[@]}" 2>/dev/null) || _now=""
  if [ "$_now" != "$PLAN_RECORD" ]; then
    echo "ticket-approve: the plan for $TICKET_ID changed while it was on screen. Nothing was recorded; run this again." >&2
    exit 6
  fi
  _rc=0
  bash "$FLOW_SH" "$TICKET_ID" human-approve --provenance human || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "ticket-approve: flow.sh human-approve failed (exit $_rc)" >&2
    exit "$_rc"
  fi
  # flow.sh owns the approval write; the binding is recorded right after it.
  # A failed record is a failed approval: an approval with no binding never
  # passes a gate, so the ticket stays held until this succeeds.
  _b_rc=0
  set_ticket_approved_plan "$TICKET_ID" "$PLAN_RECORD" || _b_rc=$?
  if [ "$_b_rc" -ne 0 ]; then
    echo "ticket-approve: the approval was recorded but the plan it is for could not be (exit $_b_rc). The ticket stays held: run this again." >&2
    exit 8
  fi
fi

APPROVED=$(get_ticket_manifest_field "$TICKET_ID" approved 2>/dev/null || true)
PROVENANCE=$(get_ticket_manifest_field "$TICKET_ID" approval_provenance 2>/dev/null || true)
STAGE=$(get_ticket_manifest_field "$TICKET_ID" stage 2>/dev/null || true)

echo "approved=${APPROVED:-false}"
echo "approval_provenance=${PROVENANCE:-}"
echo "stage=${STAGE:-}"
echo "already_approved=${ALREADY_APPROVED}"
echo "plan_id=${PLAN_ID}"

if [ "$APPROVED" != "true" ]; then
  echo "ticket-approve: manifest does not reflect the approval after flow.sh succeeded" >&2
  exit 5
fi
if ! plan_binding_matches_exactly "$TICKET_ID" "${_plan_args[@]}"; then
  echo "ticket-approve: the manifest does not show the approval bound to plan $PLAN_ID after the write" >&2
  exit 8
fi

# needs-info clear (dor-readiness-gate-foundation task 6.3) — the first call
# site for the needs-info-resolved trigger, declared in workflow.json with
# zero callers before this change. Approval is the moment a human has, by
# definition, just looked at the ticket, so clearing the flag here is what
# lets a ticket gate-stopped at Check 2.7e for FLAG_NEEDS_INFO become
# dispatchable again immediately, regardless of whether its cached `ready`
# object is stale (design.md Decision 8, Decision 3). No-op when the flag
# isn't set.
NEEDS_INFO_CLEARED="false"
if [ "$NEEDS_INFO_SET" = "true" ]; then
  _ni_rc=0
  bash "$FLOW_SH" "$TICKET_ID" needs-info-resolved || _ni_rc=$?
  if [ "$_ni_rc" -eq 0 ]; then
    NEEDS_INFO_CLEARED="true"
  else
    echo "ticket-approve: flow.sh needs-info-resolved failed (exit $_ni_rc) — needs-info flag not cleared" >&2
  fi
fi
echo "needs_info_cleared=${NEEDS_INFO_CLEARED}"
echo "Re-run /ticket-auto $TICKET_ID to continue."

exit 0
