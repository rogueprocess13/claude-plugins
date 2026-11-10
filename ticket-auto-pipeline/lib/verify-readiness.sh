#!/usr/bin/env bash
# verify-readiness.sh — the one verification-readiness scorer.
#
# Does the plan carry what the verify phase needs? gate-check.sh Check 2.6
# calls it and is the one authority that holds a ticket on the answer.
# ticket-appraise-exec Step 3.8 calls the CLI below in advisory mode: it logs
# and records the same verdict, and never stops the pipeline.
#
# Functions (source the file):
#
#   verify_readiness_vplan <TID> <ticket-dir>
#     Verification-plan table from notes.md, else the planner's body.md
#     (resolve_planner_dir, when sourced). Sets VR_VPLAN_FOUND (1 or empty),
#     VR_VPLAN_SOURCE (notes.md|body.md|none), VR_VPLAN_ROWS,
#     VR_VPLAN_VERIFIABLE. The gate adds its own description tier after this.
#
#   verify_readiness_artifact_text <artifact>
#     The text the probes scan: the file, or every *.md under an openspec
#     change directory (proposal, design, tasks, specs), sorted.
#
#   verify_readiness_score <artifact> <mode-text> <vplan-found> <vplan-verifiable>
#     A verifiable plan row marks all prerequisites found; otherwise the
#     artifact is scanned. The ticket mode comes from verify-mode.sh
#     (verify_mode_gate_profile over <mode-text>, the text verify itself
#     classifies). Sets:
#       VR_TEST_USER VR_NAV VR_EXPECTED VR_ENV       probe counts (0 = missing)
#       VR_PLAN_TEST_USER VR_PLAN_NAV VR_PLAN_EXPECTED VR_PLAN_ENV
#                                                    from the plan table only
#       VR_BUILD_COMMAND VR_BUILD_OUTCOME            build-only probes
#       VR_HIT_<probe>   the first matching plan line (artifact scan only)
#       VR_MODE        browser | build-only | api-only
#       VR_VERIFY_MODE browser | build-only | live-backend
#       VR_REQUIRED VR_MISSING VR_THRESHOLD VR_MISSING_LIST (comma list)
#       VR_STATUS      CLEAR (0 missing) | WARNINGS (below the hold
#                      threshold) | INCOMPLETE (the entry gate holds when it
#                      enforces: a plan table exists or a critique has run)
#     Thresholds: browser holds at 2 of 4 missing; the other modes at 1 of 2.
#
# CLI (ticket-appraise-exec Step 3.8, advisory):
#   verify-readiness.sh <TID> --ticket-dir D --artifact A [--no-write] [--no-log]
#   Writes EXEC|verify-readiness|start and |done|<STATUS> — advisory ...,
#   the verify-readiness heartbeat, and the notes.md ## Verification
#   Readiness section (replaced in place). Prints VR_STATUS=, VR_MODE=,
#   VR_MISSING=, VR_REQUIRED=, VR_MISSING_LIST=. Exit 0 always (2 usage):
#   the entry gate, not this call, decides whether the ticket holds.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_VERIFY_READINESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f verify_mode_gate_profile >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_VERIFY_READINESS_DIR/verify-mode.sh"
fi
if ! declare -f vplan_parse >/dev/null 2>&1 && [ -f "$_VERIFY_READINESS_DIR/vplan-parse.sh" ]; then
  # shellcheck source=/dev/null
  source "$_VERIFY_READINESS_DIR/vplan-parse.sh"
fi

verify_readiness_vplan() {
  local tid="${1:-}" td="${2:-.}" text="" pdir=""
  VR_VPLAN_FOUND="" VR_VPLAN_SOURCE="none" VR_VPLAN_ROWS=0 VR_VPLAN_VERIFIABLE=0
  declare -f vplan_parse >/dev/null 2>&1 || return 0
  [ -f "$td/notes.md" ] && text=$(cat "$td/notes.md" 2>/dev/null || true)
  if vplan_parse "$text" 2>/dev/null; then
    VR_VPLAN_FOUND=1 VR_VPLAN_SOURCE="notes.md" VR_VPLAN_ROWS="$VPLAN_ROWS" VR_VPLAN_VERIFIABLE="$VPLAN_VERIFIABLE"
    return 0
  fi
  if declare -f resolve_planner_dir >/dev/null 2>&1; then
    pdir=$(resolve_planner_dir "$tid" 2>/dev/null) || true
    if [ -n "$pdir" ] && [ -f "$pdir/body.md" ]; then
      text=$(cat "$pdir/body.md" 2>/dev/null || true)
      if vplan_parse "$text" 2>/dev/null; then
        VR_VPLAN_FOUND=1 VR_VPLAN_SOURCE="body.md" VR_VPLAN_ROWS="$VPLAN_ROWS" VR_VPLAN_VERIFIABLE="$VPLAN_VERIFIABLE"
      fi
    fi
  fi
  return 0
}

verify_readiness_artifact_text() {
  local a="${1:-}" f
  if [ -d "$a" ]; then
    while IFS= read -r f; do
      cat "$f" 2>/dev/null || true
      echo
    done < <(find "$a" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
  elif [ -f "$a" ]; then
    cat "$a" 2>/dev/null || true
  fi
}

# Test-user role vocabulary: the project catalog's roles, else the known set.
_vr_role_pattern() {
  local p
  p=$(jq -r '[.[].roles[]] | unique | join("|")' "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills}/config/test-users.json" 2>/dev/null | sed 's/_/[-_]/g') || p=""
  [ -n "$p" ] || p='attorney|admin|debtor|collection[-_]?agency|correspondent'
  echo "$p"
}

_vr_count() { # pattern text
  local n
  n=$(grep -ciP "$1" <<<"$2" 2>/dev/null || true)
  echo "${n:-0}"
}

# _vr_hit <pattern> <text> — the first matching line, trimmed, pipes made
# safe for a markdown table cell, cut to 100 chars. ticket-verify Step 1.7
# reads the test user, nav target and expected behaviour from this cell.
_vr_hit() {
  grep -iPm1 "$1" <<<"$2" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/|/\\|/g' | cut -c1-100 || true
}

verify_readiness_score() {
  local artifact="${1:-}" mode_text="${2:-}" vfound="${3:-}" vverif="${4:-0}" text role
  VR_TEST_USER=0 VR_NAV=0 VR_EXPECTED=0 VR_ENV=0 VR_BUILD_COMMAND=0 VR_BUILD_OUTCOME=0
  VR_HIT_TEST_USER="" VR_HIT_NAV="" VR_HIT_EXPECTED="" VR_HIT_ENV="" VR_HIT_BUILD_COMMAND="" VR_HIT_BUILD_OUTCOME=""
  if [ -n "$vfound" ] && [ "${vverif:-0}" -gt 0 ] 2>/dev/null; then
    # At least one criterion is fully verifiable: every prerequisite is
    # present for it (vplan_parse reads only the Verifiable column, #514).
    VR_TEST_USER=1 VR_NAV=1 VR_EXPECTED=1 VR_ENV=1 VR_BUILD_COMMAND=1 VR_BUILD_OUTCOME=1
  fi
  VR_PLAN_TEST_USER=$VR_TEST_USER VR_PLAN_NAV=$VR_NAV VR_PLAN_EXPECTED=$VR_EXPECTED VR_PLAN_ENV=$VR_ENV

  text=$(verify_readiness_artifact_text "$artifact")
  if [ "$VR_TEST_USER" = 0 ]; then
    # Tightened probes (v2): each needs context, not a bare substring.
    role=$(_vr_role_pattern)
    local p_user p_nav p_exp p_env
    p_user='(\*\*User:\*\*\s*\S|email[:\s]*\S+@\S+\.\S+|log in as \S|test as \S|role[:\s]*('"$role"'))'
    p_nav='((navigate|go to|open|visit|click).{0,60}(/(handover|admin|user-permission|organisation|portfolio)/)|(/(handover|admin|user-permission|organisation|portfolio)/).{0,60}(navigate|go to|open|visit|click)|menu path.{0,30}\[|navigate to \S|go to \S)'
    p_exp='(acceptance criteria|expected (behavi|result|outcome)|^\s*\d+[\.\)]\s.*(should |must )|verify that|pass criter|##\s*(Expected|Acceptance|Verification Plan)|AC[-:]\s|###\s*(Acceptance|Expected))'
    p_env='(seed[- ]?data|(test|data|environment|seed)\s+\w+\s+setup|setup\s+(test|data|seed)\s|prerequisite|before (testing|running)|database|migration|service.{0,10}start|data\.sql|fixture|test data)'
    VR_TEST_USER=$(_vr_count "$p_user" "$text")
    VR_NAV=$(_vr_count "$p_nav" "$text")
    VR_EXPECTED=$(_vr_count "$p_exp" "$text")
    VR_ENV=$(_vr_count "$p_env" "$text")
    VR_HIT_TEST_USER=$(_vr_hit "$p_user" "$text")
    VR_HIT_NAV=$(_vr_hit "$p_nav" "$text")
    VR_HIT_EXPECTED=$(_vr_hit "$p_exp" "$text")
    VR_HIT_ENV=$(_vr_hit "$p_env" "$text")
  fi

  VR_VERIFY_MODE=$(verify_mode_classify "$mode_text")
  VR_MODE=$(verify_mode_gate_profile "$mode_text" "$VR_NAV" "$VR_TEST_USER")

  local -a miss=()
  case "$VR_MODE" in
  build-only)
    VR_REQUIRED=2 VR_THRESHOLD=1
    if [ "$VR_BUILD_COMMAND" = 0 ]; then
      local p_cmd p_out
      p_cmd='(\bmvn\b\s|\bgradle\b|\bnpm run\b|\bmake\b\s|clean compile|clean install|clean package|clean test|\bCI run\b|\bworkflow run\b|feature-branch push)'
      p_out='(BUILD SUCCESS|succeeds?\b|compiles?\s+(successfully|cleanly)|passes?\b|no (compile|build) error|exit code 0|green build|runs? successfully|legs? (are )?green)'
      VR_BUILD_COMMAND=$(_vr_count "$p_cmd" "$text")
      VR_BUILD_OUTCOME=$(_vr_count "$p_out" "$text")
      VR_HIT_BUILD_COMMAND=$(_vr_hit "$p_cmd" "$text")
      VR_HIT_BUILD_OUTCOME=$(_vr_hit "$p_out" "$text")
    fi
    [ "$VR_BUILD_COMMAND" = 0 ] && miss+=("build command")
    [ "$VR_BUILD_OUTCOME" = 0 ] && miss+=("build outcome")
    ;;
  api-only)
    VR_REQUIRED=2 VR_THRESHOLD=1
    [ "$VR_EXPECTED" = 0 ] && miss+=("expected behavior")
    [ "$VR_ENV" = 0 ] && miss+=("environment prerequisites")
    ;;
  *)
    VR_REQUIRED=4 VR_THRESHOLD=2
    [ "$VR_TEST_USER" = 0 ] && miss+=("test user")
    [ "$VR_NAV" = 0 ] && miss+=("navigation target")
    [ "$VR_EXPECTED" = 0 ] && miss+=("expected behavior")
    [ "$VR_ENV" = 0 ] && miss+=("environment prerequisites")
    ;;
  esac
  VR_MISSING=${#miss[@]}
  VR_MISSING_LIST=""
  local m
  for m in "${miss[@]}"; do VR_MISSING_LIST="${VR_MISSING_LIST:+$VR_MISSING_LIST, }$m"; done
  if [ "$VR_MISSING" -eq 0 ]; then
    VR_STATUS=CLEAR
  elif [ "$VR_MISSING" -lt "$VR_THRESHOLD" ]; then
    VR_STATUS=WARNINGS
  else
    VR_STATUS=INCOMPLETE
  fi
  return 0
}

# _vr_notes_section <date> — the ## Verification Readiness block for notes.md.
_vr_notes_section() {
  local d="$1"
  # $1 label, $2 count, $3 first matching plan line (artifact scan only)
  _vr_row() {
    if [ "$2" = 0 ]; then
      echo "| $1 | missing | not specified |"
    elif [ "$VR_PLAN_TEST_USER" != 0 ]; then
      echo "| $1 | found | Verification Plan ($VR_VPLAN_SOURCE) |"
    else
      echo "| $1 | found | plan: ${3:-artifact scan} |"
    fi
  }
  echo "## Verification Readiness"
  echo "**Date:** $d"
  echo "**Status:** $VR_STATUS"
  echo "**Mode:** $VR_MODE (verify: $VR_VERIFY_MODE)"
  echo "**Advisory:** the entry gate (gate-check.sh Check 2.6) decides holds"
  echo ""
  echo "| Prerequisite | Status | Source |"
  echo "|-------------|--------|--------|"
  if [ "$VR_MODE" = build-only ]; then
    _vr_row "Build command" "$VR_BUILD_COMMAND" "$VR_HIT_BUILD_COMMAND"
    _vr_row "Build outcome" "$VR_BUILD_OUTCOME" "$VR_HIT_BUILD_OUTCOME"
  else
    _vr_row "Test user" "$VR_TEST_USER" "$VR_HIT_TEST_USER"
    _vr_row "Navigation target" "$VR_NAV" "$VR_HIT_NAV"
    _vr_row "Expected behavior" "$VR_EXPECTED" "$VR_HIT_EXPECTED"
    _vr_row "Environment prerequisites" "$VR_ENV" "$VR_HIT_ENV"
  fi
}

# Replace (or append) the section in notes.md through a temp file + rename.
_vr_write_notes() {
  local notes="$1" tmp
  [ -f "$notes" ] || return 0
  tmp=$(mktemp "$notes.XXXXXX") || return 1
  awk '
    /^## Verification Readiness[[:space:]]*$/ { skip = 1; next }
    skip && /^## / { skip = 0 }
    !skip { print }
  ' "$notes" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  # Drop trailing blank lines, then append the fresh section.
  {
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp"
    printf '\n'
    _vr_notes_section "$(date -u +%Y-%m-%d)"
  } >"$tmp.2" &&
    mv "$tmp.2" "$notes" && rm -f "$tmp" && return 0
  rm -f "$tmp" "$tmp.2"
  return 1
}

_verify_readiness_usage() {
  echo "usage: verify-readiness.sh <TICKET-ID> --ticket-dir D --artifact A [--no-write] [--no-log]" >&2
}

_verify_readiness_main() {
  local tid="" td="" art="" write=1 log=1
  while [ $# -gt 0 ]; do
    case "$1" in
    --ticket-dir | --artifact)
      [ $# -ge 2 ] && [ -n "$2" ] || {
        _verify_readiness_usage
        return 2
      }
      if [ "$1" = --ticket-dir ]; then td="$2"; else art="$2"; fi
      shift 2
      ;;
    --no-write)
      write=0
      shift
      ;;
    --no-log)
      log=0
      shift
      ;;
    -*)
      _verify_readiness_usage
      return 2
      ;;
    *)
      [ -z "$tid" ] || {
        _verify_readiness_usage
        return 2
      }
      tid="$1"
      shift
      ;;
    esac
  done
  [ -n "$tid" ] && [ -n "$td" ] && [ -n "$art" ] || {
    _verify_readiness_usage
    return 2
  }
  if ! declare -f resolve_planner_dir >/dev/null 2>&1 && [ -f "$_VERIFY_READINESS_DIR/planner-artifacts.sh" ]; then
    # shellcheck source=/dev/null
    source "$_VERIFY_READINESS_DIR/planner-artifacts.sh" 2>/dev/null || true
  fi
  [ "$log" = 1 ] && bash "$_VERIFY_READINESS_DIR/plog.sh" EXEC verify-readiness start "Checking plan for verification prerequisites"

  # Verify classifies the simple-fix plan, else notes.md (an openspec ticket).
  local mode_plan="$art"
  [ -d "$art" ] && mode_plan="$td/notes.md"
  verify_readiness_vplan "$tid" "$td"
  verify_readiness_score "$art" "$(verify_mode_text "$mode_plan" "$td")" "$VR_VPLAN_FOUND" "$VR_VPLAN_VERIFIABLE"

  echo "VR_STATUS=$VR_STATUS"
  echo "VR_MODE=$VR_MODE"
  echo "VR_MISSING=$VR_MISSING"
  echo "VR_REQUIRED=$VR_REQUIRED"
  echo "VR_MISSING_LIST=$VR_MISSING_LIST"
  if [ "$write" = 1 ]; then
    _vr_write_notes "$td/notes.md" || echo "verify-readiness: could not update $td/notes.md" >&2
  fi
  if [ "$log" = 1 ]; then
    bash "$_VERIFY_READINESS_DIR/hb-wrap.sh" gate "verify-readiness" "ok" "$VR_STATUS" "{\"missing\":\"$VR_MISSING\",\"required\":\"$VR_REQUIRED\",\"mode\":\"$VR_MODE\",\"advisory\":\"true\"}" || true
    bash "$_VERIFY_READINESS_DIR/plog.sh" EXEC verify-readiness done "$VR_STATUS — advisory, mode=$VR_MODE missing $VR_MISSING/$VR_REQUIRED${VR_MISSING_LIST:+: $VR_MISSING_LIST}"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _verify_readiness_main "$@"
  exit $?
fi
