#!/usr/bin/env bash
# branch-resolve.sh — deterministic branch decision for ticket-auto.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Resolves which branches a ticket should target: the ticket's own
# branch, the base branch it builds on, and an optional integration branch.
#
# Precedence chain (first match wins):
#   1. --branch flag               (BRANCH_SOURCE=flag)
#   2. Parent epic branch directive (BRANCH_SOURCE=epic-directive)
#   3. config.sh BASE_BRANCH        (BRANCH_SOURCE=default)
#
# Dependencies: config.sh, linear-api.sh, branch-directive-check.sh, jq
#
# Usage:
#   source lib/branch-resolve.sh

# Source dependencies (main path — previously only self-test mode did this,
# leaving check_branch_directive_description undefined during real resolution).
_BR_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$_BR_LIB_DIR/config.sh" 2>/dev/null || true
source "$_BR_LIB_DIR/linear-api.sh" 2>/dev/null || true
source "$_BR_LIB_DIR/planned-ticket-check.sh" 2>/dev/null || true
source "$_BR_LIB_DIR/branch-directive-check.sh" 2>/dev/null || true
source "$_BR_LIB_DIR/manifest-read.sh" 2>/dev/null || true
# events.sh backs uat_decide_trigger's pr-review-passed{uat_required} dual-write
# (tracker-event-vocabulary-and-emitter). Guarded — not every branch-resolve.sh
# caller runs from a context where the outbox lib is installed alongside it.
declare -f emit_event >/dev/null 2>&1 || source "$_BR_LIB_DIR/events.sh" 2>/dev/null || true

#   resolve_branch_context "CRE-123"
#   resolve_branch_context "CRE-123" --branch "epic/test-x"
#   resolve_branch_context "CRE-123" --title "Fix auth" --parent-json '{"id":"CRE-100","description":"..."}'

# _epic_branch_directive <epic_id> <description>
# Resolves an epic's directive fields (branch, uat_policy, merge_policy) —
# the epic manifest first (tracker-local-facts-read-migration), falling back
# to a live parse of <description> only when no epic manifest exists (a
# ticket created before this migration, or a manifest write that failed).
# Never fetches anything itself — the fallback parses whatever description
# the caller already has in hand.
#
# Sets _EBD_BRANCH / _EBD_UAT_POLICY / _EBD_MERGE_POLICY and _EBD_SOURCE
# ("manifest" | "live" | "invalid" | ""). Returns 2 when the live-fallback
# parse finds a malformed directive (mirrors check_branch_directive_
# description's own exit 2) — a cached manifest value is never re-validated
# here, since it was already validated once when written.
_epic_branch_directive() {
  local epic_id="$1" description="$2"
  _EBD_BRANCH="" _EBD_UAT_POLICY="" _EBD_MERGE_POLICY="" _EBD_SOURCE=""

  if [ -n "$epic_id" ] && declare -f epic_manifest_exists >/dev/null 2>&1 &&
    epic_manifest_exists "$epic_id" 2>/dev/null; then
    _EBD_BRANCH=$(get_epic_manifest_field "$epic_id" branch 2>/dev/null)
    _EBD_UAT_POLICY=$(get_epic_manifest_field "$epic_id" uat_policy 2>/dev/null)
    _EBD_MERGE_POLICY=$(get_epic_manifest_field "$epic_id" merge_policy 2>/dev/null)
    _EBD_SOURCE="manifest"
    return 0
  fi

  [ -z "$description" ] && return 0

  local directive_output directive_exit=0
  directive_output=$(check_branch_directive_description "$description" 2>/dev/null) || directive_exit=$?
  if [ "$directive_exit" -eq 2 ]; then
    _EBD_SOURCE="invalid"
    return 2
  fi

  if [ -n "$directive_output" ]; then
    _EBD_BRANCH=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_BRANCH='\\(.*\\)'\$/\\1/p")
    _EBD_UAT_POLICY=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_UAT_POLICY='\\(.*\\)'\$/\\1/p")
    _EBD_MERGE_POLICY=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_MERGE_POLICY='\\(.*\\)'\$/\\1/p")
    _EBD_SOURCE="live"
  fi
  return 0
}

# ── Public API ──────────────────────────────────────────────────────────────

# resolve_branch_context <TICKET_ID> [--branch <override>] [--title <title>] [--parent-json <json>]
# Resolves branch decisions for a ticket. Emits BRANCH_CONTEXT_RESULT block.
# When --title and --parent-json are provided, skips the get_issue API call
# (test mode). On directive validation failure, emits BRANCH_DIRECTIVE_INVALID
# marker and exits non-zero.
resolve_branch_context() {
  local ticket_id="$1"
  shift

  local branch_override=""
  local inline_title=""
  local inline_parent_json=""

  while [ $# -gt 0 ]; do
    case "$1" in
    --branch)
      branch_override="$2"
      shift 2
      ;;
    --title)
      inline_title="$2"
      shift 2
      ;;
    --parent-json)
      inline_parent_json="$2"
      shift 2
      ;;
    *)
      echo "branch-resolve: unknown option: $1" >&2
      shift
      ;;
    esac
  done

  local title="$inline_title"
  local parent_id=""
  local parent_description=""
  # Kept even if parent_id is cleared by a --branch override below — UAT/merge
  # policy is a property of the epic and must resolve regardless of which
  # precedence rule chose the branch itself.
  local epic_ref=""

  # Fetch ticket data if not provided inline
  if [ -z "$inline_title" ]; then
    local issue_json
    issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
      echo "branch-resolve: failed to fetch ticket $ticket_id" >&2
      return 1
    }

    # Type guard
    if ! echo "$issue_json" | jq -e '.id and .title' >/dev/null 2>&1; then
      echo "branch-resolve: unexpected response shape for $ticket_id" >&2
      return 1
    fi

    title=$(echo "$issue_json" | jq -r '.title // ""')
    parent_id=$(echo "$issue_json" | jq -r '.parent.id // ""')
    parent_description=$(echo "$issue_json" | jq -r '.parent.description // ""')
  else
    # Extract parent info from inline JSON
    if [ -n "$inline_parent_json" ]; then
      parent_id=$(echo "$inline_parent_json" | jq -r '.id // ""')
      parent_description=$(echo "$inline_parent_json" | jq -r '.description // ""')
    fi
  fi
  epic_ref="$parent_id"

  # ── Generate ticket branch name ───────────────────────────────────────────
  local ticket_branch
  ticket_branch=$(_generate_branch_name "$ticket_id" "$title")

  # ── Resolve base and integration branches ─────────────────────────────────
  local base_branch
  local integration_branch=""
  local branch_source=""

  # Precedence 1: --branch flag
  if [ -n "$branch_override" ]; then
    if ! _validate_branch_name "$branch_override"; then
      echo "branch-resolve: --branch override '$branch_override' failed branch-name validation" >&2
      return 2
    fi
    base_branch="$branch_override"
    integration_branch="$branch_override"
    branch_source="flag"
    parent_id="" # explicit override, ignore parent

  # Precedence 2: parent epic directive — epic manifest first
  # (tracker-local-facts-read-migration), live description parse as fallback.
  elif [ -n "$parent_id" ]; then
    _epic_branch_directive "$epic_ref" "$parent_description"
    local _ebd_rc=$?
    if [ "$_ebd_rc" -eq 2 ]; then
      # Malformed directive (live-fallback path only — a cached manifest
      # value is never re-validated here) — gate-stop.
      echo "BRANCH_DIRECTIVE_INVALID" >&2
      echo "branch-resolve: parent $parent_id has a malformed Branch Directive — gate-stop" >&2
      return 2
    fi

    if [ -n "$_EBD_BRANCH" ]; then
      base_branch="$_EBD_BRANCH"
      integration_branch="$_EBD_BRANCH"
      branch_source="epic-directive"
    fi
  fi

  # Precedence 3: config default
  if [ -z "$branch_source" ]; then
    base_branch="${BASE_BRANCH:-develop}"
    branch_source="default"
  fi

  # ── Resolve UAT policy and merge policy ───────────────────────────────────
  # Both are properties of the epic, not of the branch target, so they are
  # read from the parent directive regardless of which precedence rule chose
  # the branch — an explicit --branch override retargets the branch, it does
  # not detach the ticket from its epic's acceptance model. Reuses whatever
  # _epic_branch_directive already resolved above when the branch itself came
  # from precedence 2; re-resolves (manifest-first, same helper) otherwise,
  # since a --branch/default branch_source never populated _EBD_*.
  if [ "$branch_source" != "epic-directive" ]; then
    _epic_branch_directive "$epic_ref" "$parent_description" >/dev/null 2>&1 || true
  fi
  local uat_policy="${_EBD_UAT_POLICY:-per-ticket}"
  # Unlike UAT policy, merge policy has no normalised default — a ticket with
  # no epic directive has no Merge Policy opinion at all, and callers must not
  # treat empty as "auto" (that would defeat the point of the field).
  local merge_policy="${_EBD_MERGE_POLICY:-}"

  # ── Emit result block ─────────────────────────────────────────────────────
  cat <<EOF
BRANCH_CONTEXT_RESULT
  TICKET_BRANCH:        ${ticket_branch}
  BASE_BRANCH:          ${base_branch}
  INTEGRATION_BRANCH:   ${integration_branch:-}
  EPIC_ID:              ${parent_id:-}
  BRANCH_SOURCE:        ${branch_source}
  UAT_POLICY:           ${uat_policy}
  MERGE_POLICY:         ${merge_policy}
END_BRANCH_CONTEXT_RESULT
EOF

  return 0
}

# resolve_uat_policy <TICKET_ID>
# Standalone resolution of a ticket's UAT policy, for skills invoked outside a
# pipeline run and therefore without an agent environment file. Echoes
# 'per-ticket' or 'epic'.
#
# Reuses the parent-description read and the directive parser the pipeline path
# already uses, so the standalone and pipeline answers cannot diverge. No new
# component fetches parent descriptions.
#
# On fetch failure it echoes the 'per-ticket' default AND returns 1: a caller
# that checks the status can react, while one that does not still gets the
# pre-change behaviour rather than an empty string.
resolve_uat_policy() {
  local ticket_id="$1"

  # Zero-fetch path: the ticket's own manifest already names its initiative
  # (== epic id in this codebase), so no live ticket fetch is needed at all
  # when both manifests exist (tracker-local-facts-read-migration).
  local parent_id="" parent_description=""
  if declare -f get_ticket_manifest_field >/dev/null 2>&1 && ticket_manifest_exists "$ticket_id" 2>/dev/null; then
    parent_id=$(get_ticket_manifest_field "$ticket_id" initiative 2>/dev/null)
  fi

  if [ -z "$parent_id" ]; then
    local issue_json
    issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
      echo "branch-resolve: failed to fetch ticket $ticket_id for UAT policy" >&2
      echo "per-ticket"
      return 1
    }
    parent_id=$(echo "$issue_json" | jq -r '.parent.id // ""' 2>/dev/null)
    parent_description=$(echo "$issue_json" | jq -r '.parent.description // ""' 2>/dev/null)
  fi

  _epic_branch_directive "$parent_id" "$parent_description" >/dev/null 2>&1 || true
  echo "${_EBD_UAT_POLICY:-per-ticket}"
}

# resolve_merge_policy <TICKET_ID>
# Standalone resolution of a ticket's epic Merge Policy, for skills invoked
# outside a pipeline run and therefore without an agent environment file.
# Echoes the declared policy (`manual` | `on-all-children-done`), or an empty
# string when the ticket has no parent epic or the parent has no directive.
#
# Mirrors resolve_uat_policy — same parent-description read, same directive
# parser — so the standalone and pipeline answers cannot diverge.
#
# On fetch failure it echoes nothing and returns 1: a caller that checks the
# status can react, one that does not gets an empty (non-blocking) policy.
resolve_merge_policy() {
  local ticket_id="$1"

  # Zero-fetch path — see resolve_uat_policy above.
  local parent_id="" parent_description=""
  if declare -f get_ticket_manifest_field >/dev/null 2>&1 && ticket_manifest_exists "$ticket_id" 2>/dev/null; then
    parent_id=$(get_ticket_manifest_field "$ticket_id" initiative 2>/dev/null)
  fi

  if [ -z "$parent_id" ]; then
    local issue_json
    issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
      echo "branch-resolve: failed to fetch ticket $ticket_id for Merge Policy" >&2
      return 1
    }
    parent_id=$(echo "$issue_json" | jq -r '.parent.id // ""' 2>/dev/null)
    parent_description=$(echo "$issue_json" | jq -r '.parent.description // ""' 2>/dev/null)
  fi

  _epic_branch_directive "$parent_id" "$parent_description" >/dev/null 2>&1 || true
  echo "${_EBD_MERGE_POLICY:-}"
}

# uat_decide_trigger [--policy <policy>] [--uat-url <url>] [--ticket <TICKET_ID>]
#                    [--project-dir <dir>]
# Echoes the ticket-flow trigger to fire after a passing PR review:
#   pr-review-pass-done  (Review → Done)
#   pr-review-pass-uat   (Review → UAT)
#
# This is the single UAT-vs-Done decision site. It is a function that echoes a
# trigger name rather than prose in a SKILL file, so the decision cannot vary
# between runs with the same inputs.
#
# Policy resolution order: --policy → UAT_POLICY in the environment (delivered
# by the agent env file) → standalone resolution from --ticket → 'per-ticket'.
#
# Policy is evaluated BEFORE the UAT URL, and that ordering is load-bearing:
# the UAT URL is exported into every pipeline agent's environment
# unconditionally, so it is effectively always set. An epic-policy check placed
# after a "is a UAT target configured?" check would never be reached.
uat_decide_trigger() {
  local policy=""
  local uat_url=""
  local uat_url_given=false
  local ticket_id=""
  local project_dir="."

  while [ $# -gt 0 ]; do
    case "$1" in
    --policy)
      policy="$2"
      shift 2
      ;;
    --uat-url)
      uat_url="$2"
      uat_url_given=true
      shift 2
      ;;
    --ticket)
      ticket_id="$2"
      shift 2
      ;;
    --project-dir)
      project_dir="$2"
      shift 2
      ;;
    *)
      echo "uat_decide_trigger: unknown option: $1" >&2
      shift
      ;;
    esac
  done

  [ -z "$policy" ] && policy="${UAT_POLICY:-}"
  if [ -z "$policy" ] && [ -n "$ticket_id" ]; then
    policy=$(resolve_uat_policy "$ticket_id" 2>/dev/null) || true
  fi
  policy="${policy:-per-ticket}"

  # Epic policy wins outright — there is no environment in which one child of a
  # shared epic branch can be observed, so a UAT target is irrelevant.
  local _uat_required=false
  local _trigger
  if [ "$policy" = "epic" ]; then
    _trigger="pr-review-pass-done"
  else
    if ! $uat_url_given; then
      uat_url=$(resolve_uat_url "$project_dir" 2>/dev/null) || uat_url=""
    fi

    if [ -n "$uat_url" ]; then
      _trigger="pr-review-pass-uat"
      _uat_required=true
    else
      _trigger="pr-review-pass-done"
    fi
  fi

  # Dual-write (tracker-event-vocabulary-and-emitter): pr-review-pass-done and
  # pr-review-pass-uat collapse into one outbox fact, pr-review-passed,
  # carrying the resolved boolean instead of a destination-encoding name.
  # flow.sh's own generic dual-write wrapper deliberately does not emit for
  # either trigger, to avoid double emission — this is the single site.
  if [ -n "$ticket_id" ] && declare -f emit_event >/dev/null 2>&1; then
    emit_event "$ticket_id" "pr-review-passed" \
      "$(jq -nc --argjson u "$_uat_required" '{uat_required: $u}')" 2>/dev/null || true
  fi

  echo "$_trigger"
  return 0
}

# ── Internal helpers ────────────────────────────────────────────────────────

# _generate_branch_name <ticket-id> <title>
# Deterministically generates a branch name: {BRANCH_PREFIX}{ID}-{slug}
# Capped at 60 characters. Uses BRANCH_PREFIX from config (default feat/).
_generate_branch_name() {
  local id="$1"
  local title="$2"
  local prefix="${BRANCH_PREFIX:-feat/}"

  # Slugify title: lowercase, replace non-alphanumeric with hyphens, collapse
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')

  # Build full name
  local full_name="${prefix}${id}-${slug}"

  # Cap at 60 chars, trimming from the slug end
  if [ ${#full_name} -gt 60 ]; then
    local prefix_len=$((${#prefix} + ${#id} + 1)) # +1 for the hyphen
    local max_slug_len=$((60 - prefix_len))
    if [ "$max_slug_len" -lt 1 ]; then
      # Prefix+ID alone exceeds 60 chars — trim the ID suffix
      full_name="${full_name:0:60}"
    else
      slug="${slug:0:$max_slug_len}"
      # Remove trailing hyphen from truncation
      slug="${slug%-}"
      full_name="${prefix}${id}-${slug}"
    fi
  fi

  echo "$full_name"
}

# ── Self-test mode ──────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  # Save and clear positional args so sourced deps don't inherit --self-test
  set -- ""
  source "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null || true
  source "$(dirname "${BASH_SOURCE[0]}")/planned-ticket-check.sh" 2>/dev/null || true
  source "$(dirname "${BASH_SOURCE[0]}")/branch-directive-check.sh" 2>/dev/null || true

  echo "Running self-tests..."

  # Slug generation
  result=$(_generate_branch_name "CRE-123" "Fix authentication bug")
  [[ "$result" == feat/CRE-123-fix-authentication-bug ]] && echo "✓ basic slug" || echo "✗ basic slug: got '$result'"

  result=$(_generate_branch_name "CRE-123" "Add User Profile & Settings!!!")
  [[ "$result" == feat/CRE-123-add-user-profile-settings ]] && echo "✓ special chars collapsed" || echo "✗ special chars: got '$result'"

  result=$(_generate_branch_name "CRE-123" "  Leading and trailing spaces  ")
  [[ "$result" == feat/CRE-123-leading-and-trailing-spaces ]] && echo "✓ trimmed" || echo "✗ trimmed: got '$result'"

  result=$(_generate_branch_name "CRE-123" "a very long title that goes on and on and on way past the sixty character limit for branch names")
  [ ${#result} -le 60 ] && echo "✓ capped at 60 chars (len=${#result})" || echo "✗ not capped: len=${#result} '$result'"

  # Determinism
  a=$(_generate_branch_name "CRE-123" "Fix auth")
  b=$(_generate_branch_name "CRE-123" "Fix auth")
  [ "$a" = "$b" ] && echo "✓ deterministic" || echo "✗ not deterministic: '$a' vs '$b'"

  echo "Self-tests complete."
  exit 0
fi
