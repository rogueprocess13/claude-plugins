#!/usr/bin/env bash
# planned-ticket-body-check.sh — deterministic body section validator.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Validates that a planned ticket's body has all required sections
# for its task type.
#
# Exit codes:
#   0 — body complete (all required sections present and non-empty)
#   1 — body incomplete (missing/empty required section)
#   2 — body source unavailable (no plane body, no Linear description)
#
# Dependencies: planner-artifacts.sh (for plane resolution), linear-api.sh,
#               planned-ticket-check.sh (for block extraction)
#
# Sources planner-artifacts.sh explicitly so consumers don't need a
# separate source just to call check_planned_body (declared-guard safe).
#
# Usage:
#   source lib/planned-ticket-body-check.sh
#   check_planned_body "CRE-123" "bug"               # fetches via API
#   check_planned_body "CRE-123" "feature" "$desc" "true"  # inline for testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/planned-ticket-check.sh"

# Source planner-artifacts.sh for resolve_planner_dir — declare-guard so
# re-sourcing by a caller that already loaded it is harmless.
if ! declare -f resolve_planner_dir >/dev/null 2>&1; then
  source "$SCRIPT_DIR/planner-artifacts.sh"
fi

# ── Configuration ─────────────────────────────────────────────────────────────

# Required sections per type:
#   all:       Acceptance Criteria, Scope
#   bug:       + Steps to Reproduce, Test Data Prerequisites
#   feature:   + Navigation Path
#   improvement: + Navigation Path
#   security:  universal only (no type-specific extras beyond bug/feature context)
#
# Test User and Navigation Path are additionally skipped whenever the body's
# own Scope table declares no FE layer — see _scope_is_backend_only. A
# backend-only ticket (worker/API/migration work, no UI) has no test user to
# log in as and no screen to navigate to; requiring those sections on every
# `feature`-labeled ticket regardless of whether it touches a UI produces a
# permanent, unresolvable PLANNED_BODY_INCOMPLETE gate-stop for backend-only
# feature work (WIL-78).

# ── Public API ────────────────────────────────────────────────────────────────

# check_planned_body <ticket-id> <type> [description] [has_planned_label]
# Validates the ticket body has all required sections for its type.
# Sets BODY_CHECK_MISSING (space-separated missing section identifiers) and
# BODY_CHECK_EXIT_CODE for callers.
# Section identifiers use the canonical names from the spec:
#   Acceptance Criteria, Test User, Scope, Navigation Path,
#   Steps to Reproduce, Test Data Prerequisites
check_planned_body() {
  local ticket_id="$1"
  local type="$2"
  local description="${3:-}"
  local has_planned_label="${4:-}"

  # Reset globals
  BODY_CHECK_MISSING=""
  BODY_CHECK_EXIT_CODE=0

  # Fetch if not provided inline (test mode bypass)
  if [ -z "$description" ]; then
    local issue_json
    issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
      BODY_CHECK_EXIT_CODE=2
      BODY_CHECK_MISSING="body_source_unavailable"
      return 2
    }
    description=$(echo "$issue_json" | jq -r '.description // ""')
    has_planned_label=$(echo "$issue_json" | jq -r \
      '[.labels.nodes[].name] | index("planned") != null')
  fi

  # Resolve body source: plane body.md preferred, else Linear description
  local body_content=""

  # Attempt plane resolution
  if [ "$has_planned_label" = "true" ]; then
    local planner_dir
    planner_dir=$(resolve_planner_dir "$ticket_id" "$description" "$has_planned_label" 2>/dev/null) || true
    if [ -n "$planner_dir" ] && [ -f "$planner_dir/body.md" ]; then
      body_content=$(cat "$planner_dir/body.md" 2>/dev/null || true)
    fi
  fi

  # Fallback to Linear description
  if [ -z "$body_content" ]; then
    body_content="$description"
  fi

  if [ -z "$body_content" ]; then
    BODY_CHECK_EXIT_CODE=2
    BODY_CHECK_MISSING="body_source_unavailable"
    return 2
  fi

  # ── Section checks ──────────────────────────────────────────────────────────

  local missing=()

  # Universal: Acceptance Criteria (atomic - [ ] items)
  if ! _has_section_ac "$body_content"; then
    missing+=("Acceptance Criteria")
  fi

  # A body whose Scope table declares no FE layer has no UI — Test User and
  # Navigation Path are meaningless for it. A body with no Scope table at all
  # is ambiguous (mode can't be determined), so it keeps the full requirement
  # set rather than being assumed backend-only.
  local backend_only=0
  if _scope_is_backend_only "$body_content"; then
    backend_only=1
  fi

  # Universal (UI tickets only): Test User
  if [ "$backend_only" != "1" ] && ! _has_section_test_user "$body_content"; then
    missing+=("Test User")
  fi

  # Universal: Scope table
  if ! _has_section_scope "$body_content"; then
    missing+=("Scope")
  fi

  # Type-specific checks
  case "$type" in
  bug)
    if ! _has_section_repro_steps "$body_content"; then
      missing+=("Steps to Reproduce")
    fi
    if ! _has_section_test_data "$body_content"; then
      missing+=("Test Data Prerequisites")
    fi
    ;;
  feature | improvement)
    if [ "$backend_only" != "1" ] && ! _has_section_nav_path "$body_content"; then
      missing+=("Navigation Path")
    fi
    ;;
  security | chore)
    # Universal only — no type-specific extras
    ;;
  *)
    # Unknown type — still check universal sections, don't add type-specific
    ;;
  esac

  if [ ${#missing[@]} -gt 0 ]; then
    # Join with "," — "${missing[*]}" joins on $IFS (a space), which renders a
    # multi-section miss as one unreadable run-on name (e.g. "Test User Scope
    # Navigation Path" for three separate missing sections, indistinguishable
    # from a two-section miss one word shorter). Commas are safe in both
    # _plog MSG (only "|" is rejected) and hb_write DETAIL (JSON string).
    BODY_CHECK_MISSING=$(IFS=,; echo "${missing[*]}")
    BODY_CHECK_EXIT_CODE=1
    return 1
  fi

  BODY_CHECK_EXIT_CODE=0
  return 0
}

# ── Section detectors ─────────────────────────────────────────────────────────

# _has_section_ac <body> — true if body has atomic acceptance criteria
_has_section_ac() {
  local body="$1"
  # Acceptance Criteria heading OR at least one checkbox line (- [ ] or - [x])
  if echo "$body" | grep -qiP '(acceptance criteria|##\s*Acceptance)' 2>/dev/null; then
    return 0
  fi
  # Check for checkbox items even without heading
  if echo "$body" | grep -cP '^\s*- \[[ xX]\]\s' 2>/dev/null | grep -qP '[1-9]'; then
    return 0
  fi
  return 1
}

# _has_section_test_user <body> — true if body identifies a test user
_has_section_test_user() {
  local body="$1"
  # Test User heading — must have non-whitespace content after it
  if echo "$body" | grep -qiP '##\s*Test User' 2>/dev/null; then
    local section_content
    section_content=$(echo "$body" | awk '/^##[[:space:]]*Test User/ {found=1; next} found && /^##/ {exit} found {print}')
    if [ -n "$(echo "$section_content" | tr -d '[:space:]')" ]; then
      return 0
    fi
    return 1 # heading present but empty — spec requires non-empty sections
  fi
  # Legacy "test user" loose text match (case-insensitive, anywhere in body)
  if echo "$body" | grep -qiP 'test user' 2>/dev/null; then
    return 0
  fi
  # User identification patterns
  if echo "$body" | grep -qiP '(\*\*User:\*\*\s*\S|email[:\s]*\S+@\S+\.\S+|log in as \S|password.*`admin`)' 2>/dev/null; then
    return 0
  fi
  return 1
}

# _has_section_scope <body> — true if body has a Scope table
_has_section_scope() {
  local body="$1"
  # Scope heading — must have a table row following it
  if echo "$body" | grep -qiP '##\s*Scope' 2>/dev/null; then
    local section_content
    section_content=$(echo "$body" | awk '/^##[[:space:]]*Scope/ {found=1; next} found && /^##/ {exit} found {print}')
    if echo "$section_content" | grep -qiP '\|\s*Layer\s*\|' 2>/dev/null; then
      return 0
    fi
    return 1 # heading present but no table — spec requires non-empty sections
  fi
  # Fallback: bold Scope label with content OR a scope table anywhere in the body
  if echo "$body" | grep -qiP '(\*\*Scope:?\*\*\s*\S)' 2>/dev/null; then
    return 0
  fi
  # Scope table pattern: | Layer | Service | Area | (anywhere, even without heading)
  if echo "$body" | grep -qiP '\|\s*Layer\s*\|' 2>/dev/null; then
    return 0
  fi
  return 1
}

# _scope_layers <body> — space-separated, deduplicated, uppercased Layer
# values from the body's Scope table. Empty if no Scope table is present.
_scope_layers() {
  local body="$1"
  local section_content
  if echo "$body" | grep -qiP '##\s*Scope' 2>/dev/null; then
    section_content=$(echo "$body" | awk '/^##[[:space:]]*Scope/ {found=1; next} found && /^##/ {exit} found {print}')
  else
    section_content="$body"
  fi
  echo "$section_content" |
    grep -oP '^\s*\|\s*\K[A-Za-z]+(?=\s*\|)' 2>/dev/null |
    grep -viP '^layer$' |
    tr '[:lower:]' '[:upper:]' | sort -u | tr '\n' ' '
}

# _scope_is_backend_only <body> — true when the body's Scope table lists at
# least one layer and none of them is FE. A body with no Scope table at all
# is ambiguous, not backend-only — mode can't be determined without one, so
# this returns false (full requirement set) in that case.
_scope_is_backend_only() {
  local body="$1"
  local layers
  layers=$(_scope_layers "$body")
  [ -z "$layers" ] && return 1
  case " $layers " in
  *" FE "*) return 1 ;;
  *) return 0 ;;
  esac
}

# _has_section_nav_path <body> — true if body has a navigation path
_has_section_nav_path() {
  local body="$1"
  # Navigation Path heading OR explicit click-path notation
  if echo "$body" | grep -qiP '(navigation path|##\s*Navigation Path|\*\*Navigation Path:?\*\*)' 2>/dev/null; then
    return 0
  fi
  # Menu > Submenu > Page pattern
  if echo "$body" | grep -qiP '`[^`]+ > [^`]+( > [^`]+)*`' 2>/dev/null; then
    return 0
  fi
  return 1
}

# _has_section_repro_steps <body> — true if body has steps to reproduce
_has_section_repro_steps() {
  local body="$1"
  # Steps to Reproduce heading
  if echo "$body" | grep -qiP '(steps to repro|reproduc|how to repro|reproduction steps|to reproduce|##\s*Steps to Reproduce)' 2>/dev/null; then
    return 0
  fi
  # Numbered browser-action steps (at least 2)
  local numbered_count
  numbered_count=$(echo "$body" | grep -ciP '^\s*\d+[\.\)]\s+(Go to|Navigate|Click|Open|Log in|Select|Type|Enter|Press|Choose|Check|Verify|See|Observe|Confirm)' 2>/dev/null || true)
  if [ "${numbered_count//[^0-9]/}" -ge 2 ] 2>/dev/null; then
    return 0
  fi
  return 1
}

# _has_section_test_data <body> — true if body has test data prerequisites
_has_section_test_data() {
  local body="$1"
  # Test Data Prerequisites heading OR test-data-like content
  if echo "$body" | grep -qiP '(test data|prerequisite|##\s*Test Data Prerequisites|before (testing|running)|seed[- ]?data|fixture)' 2>/dev/null; then
    return 0
  fi
  return 1
}

# ── Self-test mode ────────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  echo "Running self-tests..."

  # Complete bug body
  bug_body='## Acceptance Criteria
- [ ] Save button works
- [ ] Error toast appears
## Test User
`admin` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |
## Steps to Reproduce
1. Log in as admin
2. Navigate to Settings
3. Click Save
## Test Data Prerequisites
At least one active handover.'

  check_planned_body "TEST-1" "bug" "$bug_body" "true"
  if [ "$BODY_CHECK_EXIT_CODE" = "0" ]; then
    echo "✓ complete bug body passes"
  else
    echo "✗ complete bug body failed: missing=${BODY_CHECK_MISSING}"
  fi

  # Feature missing Navigation Path
  feat_body='## Acceptance Criteria
- [ ] Feature works
## Test User
`admin` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |'

  check_planned_body "TEST-2" "feature" "$feat_body" "true"
  if [ "$BODY_CHECK_EXIT_CODE" != "0" ] && echo "$BODY_CHECK_MISSING" | grep -q "Navigation Path"; then
    echo "✓ feature missing Nav Path fails with correct identifier"
  else
    echo "✗ feature missing Nav Path: exit=$BODY_CHECK_EXIT_CODE missing=$BODY_CHECK_MISSING"
  fi

  # Empty body → body_source_unavailable
  check_planned_body "TEST-3" "bug" "" "true"
  if [ "$BODY_CHECK_EXIT_CODE" = "2" ]; then
    echo "✓ empty body → exit 2 (body_source_unavailable)"
  else
    echo "✗ empty body: exit=$BODY_CHECK_EXIT_CODE (expected 2)"
  fi

  echo "Self-tests complete — run test-planned-body-check.sh for full coverage."
  exit 0
fi
