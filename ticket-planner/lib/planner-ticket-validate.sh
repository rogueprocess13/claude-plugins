#!/usr/bin/env bash
# planner-ticket-validate.sh — Pre-creation validation for planner-generated tickets.
#
# Wraps planned-ticket-check.sh to validate tickets before they are created in
# Linear. A ticket that fails validation is not created — the failure surfaces
# as a planner error, not a confusing pipeline error later.
#
# Also provides idempotency helpers: intent recording and existence checking
# for entity-creating phases (EpicGen, TicketGen).
#
# Usage:
#   planner_validate_ticket <description> [has_planned_label] [ticket_type]
#     Validates a ticket description against planned-ticket-check.sh (Planner
#     Context block structure) and, when ticket_type is given, against
#     planned-ticket-body-check.sh's check_planned_body (required ## sections
#     for that type — issue #285). Catches the same gap ticket-auto-pipeline's
#     gate-check (Check 2.7c) would otherwise catch several phases later, at
#     ticket-creation time instead.
#     Returns: 0 if valid, 1 if invalid (reports reason to stderr).
#
#   planner_record_intent <initiative_id> <phase> <entity_type> <entity_key>
#     Records intent before creating an entity (for idempotency).
#
#   planner_entity_exists <initiative_id> <entity_key>
#     Checks if entity was already created. Returns 0 if exists, 1 if not.
#
#   planner_entity_mark_created <initiative_id> <entity_key> <linear_id>
#     Marks entity as created after successful Linear API call.
#
# Sourceable library — no set -euo pipefail.

_source_if_missing() {
  local name="$1" path="$2"
  if ! declare -f "$name" >/dev/null 2>&1; then
    [ -f "$path" ] && source "$path"
  fi
}

# Resolves ticket-auto-pipeline's manifest-write.sh (which itself sources
# manifest-read.sh) — tracker-planner-and-fallback-cutover, 4.4. Same
# plugin-cache → skills-lib fallback as the planned-ticket-check.sh
# resolution below. No bundled copy — a drifting duplicate would silently
# disagree with the schema manifest-write.sh actually writes.
_planner_verify_source_manifest_read() {
  declare -f ticket_manifest_exists >/dev/null 2>&1 && return 0
  local lib
  lib=$(find "${HOME}/.claude/plugins/cache" -name "manifest-write.sh" \
    -path "*/ticket-auto-pipeline/*/lib/manifest-write.sh" 2>/dev/null | sort | tail -1)
  [ -n "$lib" ] || lib="${HOME}/.claude/skills/lib/manifest-write.sh"
  [ -f "$lib" ] && source "$lib"
}

# ── Ticket validation ──────────────────────────────────────────────────────────

# Validate a generated ticket description before creating it in Linear.
# Uses planned-ticket-check.sh inline (source + call) to validate the
# Planner Context block without needing a Linear ticket ID. When ticket_type
# is given, also runs planned-ticket-body-check.sh's check_planned_body
# against the same description, inline, to catch a body missing required
# sections (issue #285) before the ticket is ever created.
#
# Usage: planner_validate_ticket <description> [has_planned_label] [ticket_type]
# Returns: 0 if valid, 1 if invalid (error on stderr), 2 if low confidence,
#          3 if a validator library is unavailable (hard stop).
planner_validate_ticket() {
  local description="$1" has_planned_label="${2:-true}" ticket_type="${3:-}"

  if [ -z "$description" ]; then
    echo "planner-validate: empty description" >&2
    return 1
  fi

  # Check Planner Context block presence
  if ! echo "$description" | grep -q '## Planner Context'; then
    echo "planner-validate: missing Planner Context block" >&2
    return 1
  fi

  # Resolve planned-ticket-check.sh
  local checker
  checker=$(find "${HOME}/.claude/plugins/cache" -name "planned-ticket-check.sh" \
    -path "*/ticket-auto-pipeline/*/lib/planned-ticket-check.sh" 2>/dev/null | sort | tail -1)
  if [ -z "$checker" ]; then
    checker="${HOME}/.claude/skills/lib/planned-ticket-check.sh"
  fi
  if [ ! -f "$checker" ]; then
    # Try relative path (same repo)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    checker="${script_dir}/../../ticket-auto-pipeline/lib/planned-ticket-check.sh"
  fi

  if [ ! -f "$checker" ]; then
    echo "planner-validate: planned-ticket-check.sh not found — HARD STOP (validator unavailable)" >&2
    return 3 # Fail closed: missing validator is a hard stop
  fi

  # Source and check. Pass the description inline to avoid API dependency.
  local exit_code=0
  source "$checker"
  # Use a fake TID — the checker only needs it for logging
  check_planned_ticket "PLANNER-PREVIEW" "$description" "$has_planned_label" 2>/dev/null || exit_code=$?

  case "$exit_code" in
  0) ;; # Planner Context block valid — fall through to the body-section check
  1)
    echo "planner-validate: ticket failed validation (malformed/missing fields)" >&2
    echo "  CHECK_RESULT=${CHECK_RESULT:-unknown}" >&2
    return 1
    ;;
  2)
    echo "planner-validate: ticket has low confidence + not pre-approved" >&2
    echo "  CHECK_RESULT=${CHECK_RESULT:-unknown}" >&2
    return 2
    ;;
  *)
    echo "planner-validate: unexpected exit code ${exit_code}" >&2
    return 1
    ;;
  esac

  # ── Body-section completeness (issue #285) ──────────────────────────────
  # planned-ticket-check.sh above validates only the Planner Context metadata
  # block. It never checks whether the body itself has the sections
  # ticket-auto-pipeline's gate-check (Check 2.7c, planned-ticket-body-check.sh)
  # requires before a planned ticket can leave the approve gate. Skipped when
  # the caller doesn't pass a ticket_type — existing callers that validate only
  # the Planner Context block keep prior behavior.
  if [ -n "$ticket_type" ]; then
    if ! declare -f check_planned_body >/dev/null 2>&1; then
      local body_checker
      body_checker="$(dirname "$checker")/planned-ticket-body-check.sh"
      [ -f "$body_checker" ] && source "$body_checker"
    fi
    if ! declare -f check_planned_body >/dev/null 2>&1; then
      echo "planner-validate: planned-ticket-body-check.sh not found — HARD STOP (body validator unavailable)" >&2
      return 3 # Fail closed: missing validator is a hard stop
    fi

    # has_planned_label="false" here on purpose: this is a pre-creation preview
    # of $description, not yet a real Linear ticket, so there is no artifact
    # plane directory to prefer — check_planned_body must validate exactly the
    # text this call is about to send to Linear, not a stale body.md.
    local body_exit_code=0
    check_planned_body "PLANNER-PREVIEW" "$ticket_type" "$description" "false" 2>/dev/null || body_exit_code=$?
    case "$body_exit_code" in
    0) return 0 ;;
    1)
      echo "planner-validate: ticket body missing required section(s) for type '${ticket_type}': ${BODY_CHECK_MISSING:-unknown}" >&2
      return 1
      ;;
    *)
      echo "planner-validate: body-section check failed (exit ${body_exit_code}, missing='${BODY_CHECK_MISSING:-unknown}')" >&2
      return 1
      ;;
    esac
  fi

  return 0
}

# ── Idempotency helpers ────────────────────────────────────────────────────────

# Intent file path for a given entity.
# Usage: _planner_intent_file <initiative_id> <entity_key>
_planner_intent_file() {
  local initiative_id="$1" entity_key="$2"
  # No ~/repos fallback (#459): an intent file in a stray tree would defeat
  # the idempotency check it exists for.
  local repos_root="${REPOS_ROOT:-}"
  if [ -z "$repos_root" ]; then
    echo "ERROR: REPOS_ROOT is not set — refusing to guess the intent directory" >&2
    return 1
  fi
  echo "${repos_root}/.ticket-auto/initiatives/${initiative_id}/.intents/${entity_key}.json"
}

# Record intent before creating an entity. Call BEFORE the Linear API call.
# Idempotent — if intent already exists, this is a no-op.
#
# Usage: planner_record_intent <initiative_id> <phase> <entity_type> <entity_key>
planner_record_intent() {
  local initiative_id="$1" phase="$2" entity_type="$3" entity_key="$4"
  local intent_file iso
  intent_file=$(_planner_intent_file "$initiative_id" "$entity_key") || return 1
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Already recorded — skip
  if [ -f "$intent_file" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$intent_file")"

  jq -nc \
    --arg initiative_id "$initiative_id" \
    --arg phase "$phase" \
    --arg entity_type "$entity_type" \
    --arg entity_key "$entity_key" \
    --arg iso "$iso" \
    '{
      initiative_id: $initiative_id,
      phase: $phase,
      entity_type: $entity_type,
      entity_key: $entity_key,
      intent_created: $iso,
      status: "intent"
    }' >"$intent_file"
}

# Check if an entity was already created (Linear ID recorded).
# Used BEFORE the Linear API call — if the entity exists, skip creation.
#
# Usage: planner_entity_exists <initiative_id> <entity_key>
# Returns: 0 if entity exists (linear_id recorded), 1 if not.
planner_entity_exists() {
  local initiative_id="$1" entity_key="$2"
  local intent_file
  intent_file=$(_planner_intent_file "$initiative_id" "$entity_key")

  if [ -f "$intent_file" ] && grep -q '"status"[[:space:]]*:[[:space:]]*"created"' "$intent_file" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Get the Linear ID of an already-created entity.
# Usage: planner_entity_get_id <initiative_id> <entity_key>
planner_entity_get_id() {
  local initiative_id="$1" entity_key="$2"
  local intent_file
  intent_file=$(_planner_intent_file "$initiative_id" "$entity_key")

  if [ -f "$intent_file" ]; then
    jq -r '.linear_id // empty' "$intent_file" 2>/dev/null
  fi
}

# Mark an entity as created after a successful Linear API call.
# Call AFTER the Linear API call succeeds.
#
# Usage: planner_entity_mark_created <initiative_id> <entity_key> <linear_id>
planner_entity_mark_created() {
  local initiative_id="$1" entity_key="$2" linear_id="$3"
  local intent_file iso
  intent_file=$(_planner_intent_file "$initiative_id" "$entity_key") || return 1
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Read existing intent, update with creation info
  local existing
  if [ -f "$intent_file" ]; then
    existing=$(cat "$intent_file")
  else
    existing="{}"
  fi

  echo "$existing" | jq -c \
    --arg linear_id "$linear_id" \
    --arg iso "$iso" \
    '. + {linear_id: $linear_id, created_at: $iso, status: "created"}' \
    >"$intent_file"
}

# ── Post-creation verification ────────────────────────────────────────────────

# Verify that created tickets actually exist in Linear with correct labels.
# This is the last checkpoint after entity creation — catches transient API
# failures that returned success but didn't persist, and label drift.
#
# Usage: planner_verify_tickets <initiative_id> <ticket_ids_json>
#   initiative_id: the initiative ID
#   ticket_ids_json: JSON array of ticket identifiers (e.g., ["PRO-101", "PRO-102"])
# Returns: 0 if all verified, 1 if mismatches found (reports to stdout).
planner_verify_tickets() {
  local initiative_id="$1" ticket_ids_json="$2"
  local intent_dir="${REPOS_ROOT:-${HOME}/repos}/.ticket-auto/initiatives/${initiative_id}/.intents"

  local failures=0 verified=0 missing=0
  local ticket_id entity_key intent_file linear_id

  for ticket_id in $(echo "$ticket_ids_json" | jq -r '.[]'); do
    # Reverse-lookup: find the intent file that recorded this Linear ID.
    # Intent files are keyed by entity slug ("ticket-{spec-slug}", e.g.
    # "ticket-vs-1a-client-web-upload-source-hash-verification.json"),
    # written by planner_record_intent BEFORE the ticket is created — the
    # Linear ID doesn't exist yet at that point, which is the entire reason
    # intent recording happens first (idempotency across a crash between
    # intent and creation). Deriving a filename FROM the post-creation
    # Linear ID (the previous "ticket-${lowercased ticket_id}.json" guess)
    # can never match anything on disk, since nothing is ever written under
    # that name — every ticket showed up as "missing-intent" regardless of
    # whether it was actually fine, silently no-opping the label check.
    intent_file=""
    if [ -d "$intent_dir" ]; then
      local candidate cand_linear_id
      for candidate in "$intent_dir"/ticket-*.json; do
        [ -f "$candidate" ] || continue
        cand_linear_id=$(jq -r '.linear_id // ""' "$candidate" 2>/dev/null)
        if [ "$cand_linear_id" = "$ticket_id" ]; then
          intent_file="$candidate"
          break
        fi
      done
    fi
    if [ -z "$intent_file" ]; then
      echo "planner-verify: WARNING — no intent file for $ticket_id (created outside planner?)"
      missing=$((missing + 1))
      continue
    fi

    linear_id=$(jq -r '.linear_id // ""' "$intent_file" 2>/dev/null)
    if [ -z "$linear_id" ] || [ "$linear_id" = "null" ]; then
      echo "planner-verify: FAIL — no Linear ID recorded for $ticket_id"
      failures=$((failures + 1))
      continue
    fi

    # Verify the ticket manifest exists and carries type + initiative
    # (tracker-planner-and-fallback-cutover, 4.4) — manifest-only, no live
    # Linear fetch or label read. write_ticket_manifest ran synchronously at
    # creation time (TicketGen step 5), so its absence here is a real
    # failure, not a timing race.
    _planner_verify_source_manifest_read
    if declare -f ticket_manifest_exists >/dev/null 2>&1 && ticket_manifest_exists "$linear_id"; then
      local manifest_type manifest_init
      manifest_type=$(get_ticket_manifest_field "$linear_id" type 2>/dev/null)
      manifest_init=$(get_ticket_manifest_field "$linear_id" initiative 2>/dev/null)

      if [ -n "$manifest_type" ] && [ -n "$manifest_init" ]; then
        echo "planner-verify: OK — $ticket_id ($linear_id) manifest carries type=$manifest_type initiative=$manifest_init"
        verified=$((verified + 1))
      else
        echo "planner-verify: FAIL — $ticket_id ($linear_id) manifest missing type or initiative"
        failures=$((failures + 1))
      fi
    else
      echo "planner-verify: FAIL — $ticket_id ($linear_id) no ticket manifest found"
      failures=$((failures + 1))
    fi
  done

  echo "planner-verify: $verified verified, $failures failed, $missing missing-intent"
  return $((failures > 0 ? 1 : 0))
}
