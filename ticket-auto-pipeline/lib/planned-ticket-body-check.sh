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
#   all:         Acceptance Criteria, Scope
#   bug:         + Steps to Reproduce, Test Data Prerequisites (loose match)
#   feature:     + Navigation Path, Test Data Prerequisites (heading)
#   improvement: + Navigation Path, Test Data Prerequisites (heading)
#   security:    universal only
#   chore:       universal only
#
# Test Data Prerequisites (planner-test-data-derivation): required on every
# type except chore and security. The planner composer always writes it —
# "None — no acceptance criterion needs test data." when nothing needs data —
# so its absence on a planned feature/improvement body means the body was
# not composed from a Verification Notes table at all. feature/improvement
# need a real `## Test Data…` heading with non-blank content
# (_has_heading_test_data): the loose _has_section_test_data match would be
# satisfied by the Verification Plan's own `Test data needed` column header,
# which every composed body carries. bug keeps its original loose match so
# no in-flight bug body changes verdict.
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
    # tracker-planner-and-fallback-cutover (3.2): manifest presence is the
    # ONLY proof of "planned" — no live label fallback. Description is
    # always live-fetched regardless.
    has_planned_label="false"
    if declare -f ticket_manifest_exists >/dev/null 2>&1 && ticket_manifest_exists "$ticket_id" 2>/dev/null; then
      has_planned_label="true"
    fi
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
    if ! _has_heading_test_data "$body_content"; then
      missing+=("Test Data Prerequisites")
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
    BODY_CHECK_MISSING=$(
      IFS=,
      echo "${missing[*]}"
    )
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

# _has_section_nav_path <body> — true (exit 0) only when the body carries
# real evidence of a click path. Accepted evidence, any one of:
#   1. A `## Navigation Path` (or `###`, optional trailing colon) heading
#      followed, before the next `#` heading, by at least one line that is
#      not a placeholder. Placeholder lines: blank, bare TBD/TODO/N/A/none,
#      a lone `{...}` token, or a lone dash/bullet/rule (`-`, `---`, `*`,
#      `_`, en/em dash), optionally followed by one of those bare markers
#      (`- TBD`).
#   2. A `**Navigation Path:**` (or `**Navigation Path**:`) label followed by
#      text on the same line.
#   3. A backticked click path: `A > B` (optionally `A > B > C`).
#   4. A pipe-table row whose `Navigation path` column cell contains ` > `.
#      The column index comes from the header row and is forgotten on every
#      line that does not start with `|`, so a later unrelated table's
#      same-numbered column never counts.
# The bare phrase "navigation path" does NOT count anywhere — in particular
# the planner Verification Plan's `Navigation path` column header alone is
# not a path. All patterns are fixed literals; no caller text reaches awk
# or grep as a regex.
_has_section_nav_path() {
  local body="$1" content
  # Rule 1 — heading with non-placeholder content.
  content=$(echo "$body" | awk '
    { line = tolower($0) }
    line ~ /^###?[[:space:]]*navigation path:?[[:space:]]*$/ { f=1; next }
    f && /^#/ { f=0 }
    f { print }
  ' | grep -vP '^\s*((-|\*|_|–|—)+\s*)?(\{[^}]*\}|TBD|TODO|N/?A|none)?\s*$' 2>/dev/null || true)
  if [ -n "$content" ]; then
    return 0
  fi
  # Rule 2 — inline bold label with text after it.
  if echo "$body" | grep -qiP '\*\*Navigation Path:?\*\*:?\s*\S' 2>/dev/null; then
    return 0
  fi
  # Rule 3 — backticked Menu > Submenu > Page click path.
  if echo "$body" | grep -qiP '`[^`]+ > [^`]+( > [^`]+)*`' 2>/dev/null; then
    return 0
  fi
  # Rule 4 — a `Navigation path` table column whose data cell holds A > B.
  if echo "$body" | awk -F'|' '
    !/^[[:space:]]*\|/ { col = 0; next }
    {
      hdr = 0
      for (i = 1; i <= NF; i++) {
        c = tolower($i)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
        if (c == "navigation path") { col = i; hdr = 1 }
      }
      if (hdr) next
    }
    col && index($col, " > ") { ok = 1; exit }
    END { exit !ok }
  '; then
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

# _has_heading_test_data <body> — true when the body has a `## Test Data…`
# heading (case-insensitive, `###` excluded) with at least one non-blank
# line before the next `##` heading. Fenced code blocks are skipped, so an
# example heading inside a fence never counts. `## Test Data Provided` (what
# a test-data chore supplies) does not count. Same section boundary as
# dor-check.sh's _dor_test_data_content.
_has_heading_test_data() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^##[ \t]/ && !/^###/ {
      h = tolower($0); sub(/^##[ \t]+/, "", h)
      insec = (index(h, "test data") == 1 && index(h, "test data provided") != 1)
      next
    }
    insec && $0 ~ /[^ \t]/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  '
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
