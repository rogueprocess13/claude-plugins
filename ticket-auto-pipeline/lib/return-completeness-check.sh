#!/usr/bin/env bash
# return-completeness-check.sh — deterministic bash gate that counts unchecked
# `- [ ]` boxes in a ticket's plan artifact (openspec tasks.md or simple-fix.md's
# ## Completion Checklist). Modeled on gate-check.sh's exit-code idiom:
# 0 complete, 1 incomplete, 2 error. Zero LLM tokens.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_RCC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RCC_LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
# heartbeat.sh is optional — source if available, degrade gracefully if not
if [ -f "$_RCC_LIB_DIR/heartbeat.sh" ]; then
  source "$_RCC_LIB_DIR/heartbeat.sh"
elif [ -f "$_RCC_SCRIPT_DIR/heartbeat.sh" ]; then
  source "$_RCC_SCRIPT_DIR/heartbeat.sh"
fi
# Phase 0 RLVR — verifier-result recording
if [ -f "$_RCC_LIB_DIR/verifier-result.sh" ]; then
  source "$_RCC_LIB_DIR/verifier-result.sh"
elif [ -f "$_RCC_SCRIPT_DIR/verifier-result.sh" ]; then
  source "$_RCC_SCRIPT_DIR/verifier-result.sh"
fi
# Whole-ID name matching (ticket_id_matches_name) — the same rule every
# plan-artifact lookup uses (review finding DET-IP-2). Sibling copy first so
# both files come from the same version.
if [ -f "$_RCC_SCRIPT_DIR/ticket-dir.sh" ]; then
  source "$_RCC_SCRIPT_DIR/ticket-dir.sh"
elif [ -f "$_RCC_LIB_DIR/ticket-dir.sh" ]; then
  source "$_RCC_LIB_DIR/ticket-dir.sh"
fi

usage() {
  cat >&2 <<'EOF'
Usage: return-completeness-check.sh <TICKET-ID> [--repos-root <path>]
                                     [--tasks-file <path>] [--simple-fix-file <path>]
                                     [--log-file <path>] [--refresh]

Counts unchecked `- [ ]` boxes in the ticket's plan artifact — openspec
tasks.md (whole-file count) or simple-fix.md's ## Completion Checklist
(section-scoped count). Tasks.md is tried first; simple-fix.md is the
fallback when no openspec change directory matches.

  --tasks-file <path>       Use this tasks.md directly, skip repo search.
  --simple-fix-file <path>  Use this simple-fix.md directly, skip repo search.
  --repos-root <path>       Root under which to search for the ticket's openspec
                             change directory or ticket workspace directory.
                             Falls back to the REPOS_ROOT env var.
  --log-file <path>         Pipeline log for the verifier-result. Falls back to
                             LOG_FILE, then TAP_LOG. With none, the result is
                             not recorded: VERIFIER_RESULT=unrecorded plus a
                             stderr warning (the verdict gate is unarmed).
  --refresh                 Post-VERIFY re-check: runs only when the latest
                             return_completeness result is FAIL/BLOCK, else
                             prints RETURN_COMPLETENESS_STATUS=current, exit 0.

Emits KEY=value lines:
  RETURN_COMPLETENESS_STATUS   complete | incomplete | error
  UNCHECKED_COUNT              integer
  TOTAL_COUNT                  integer
  TASKS_FILE                   resolved path (empty on error)
  UNCHECKED_ITEMS              first few unchecked lines, ; -separated
  REASON                       reason code
  ARTIFACT_TYPE                openspec | simple-fix | (empty on error)
  VERIFIER_RESULT              recorded | unrecorded

Exit codes: 0 complete, 1 incomplete, 2 error (no plan artifact found/unresolvable)
EOF
  exit 1
}

# ── Resolution ────────────────────────────────────────────────────────────────

# Search REPOS_ROOT for an openspec change directory matching TICKET-ID.
# Mirrors the CHANGE_DIR pattern used inline by ticket-appraise-exec, but
# generalized across every repo under REPOS_ROOT since this script runs
# router-side (bash-only, no per-repo cwd).
_find_tasks_file() {
  local ticket_id="$1" repos_root="$2"
  local repo change_dir

  while IFS= read -r -d '' repo; do
    for change_dir in "$repo"/openspec/changes/*/; do
      [ -d "$change_dir" ] || continue
      if ticket_id_matches_name "$ticket_id" "$(basename "$change_dir")" &&
        [ -f "${change_dir}tasks.md" ]; then
        echo "${change_dir}tasks.md"
        return 0
      fi
    done
  done < <(find "$repos_root" -maxdepth 3 -name ".git" -printf '%h\0' 2>/dev/null || true)

  return 1
}

# Search REPOS_ROOT for a simple-fix.md in a ticket workspace directory
# matching TICKET-ID. Workspace dirs follow the pattern {TICKET-ID}--{slug}.
_find_simple_fix_file() {
  local ticket_id="$1" repos_root="$2"
  while IFS= read -r -d '' sf; do
    if ticket_id_matches_name "$ticket_id" "$(basename "$(dirname "$sf")")"; then
      echo "$sf"
      return 0
    fi
  done < <(find "$repos_root" -maxdepth 4 -name "simple-fix.md" -print0 2>/dev/null || true)

  return 1
}

# ── Counting ──────────────────────────────────────────────────────────────────

_count_boxes() {
  local tasks_file="$1"
  UNCHECKED_COUNT=$(grep -c '^- \[ \]' "$tasks_file" 2>/dev/null || true)
  UNCHECKED_COUNT="${UNCHECKED_COUNT:-0}"
  local checked_count
  checked_count=$(grep -c '^- \[x\]' "$tasks_file" 2>/dev/null || true)
  checked_count="${checked_count:-0}"
  TOTAL_COUNT=$((UNCHECKED_COUNT + checked_count))
  UNCHECKED_ITEMS=$(grep '^- \[ \]' "$tasks_file" 2>/dev/null | head -5 | sed 's/^- \[ \] //' | paste -sd';' - || true)
}

# Count - [ ] and - [x] boxes within a named markdown section of a file.
# Only counts items inside the section body between the heading and the next
# ## heading or EOF. Sets: UNCHECKED_COUNT, TOTAL_COUNT, UNCHECKED_ITEMS.
_count_checklist_boxes() {
  local file="$1" section_heading="$2"
  local section_content
  # Extract between the section heading and the next ## heading or EOF.
  # The sed range /^## Heading/,/^## / captures everything from the target
  # heading to the next ## heading inclusive; we delete the boundary lines.
  section_content=$(sed -n "/^${section_heading}/,/^## /{ /^${section_heading}/d; /^## /d; p; }" "$file" 2>/dev/null || true)
  UNCHECKED_COUNT=$(echo "$section_content" | grep -c '^- \[ \]' 2>/dev/null || true)
  UNCHECKED_COUNT="${UNCHECKED_COUNT:-0}"
  local checked_count
  checked_count=$(echo "$section_content" | grep -c '^- \[x\]' 2>/dev/null || true)
  checked_count="${checked_count:-0}"
  TOTAL_COUNT=$((UNCHECKED_COUNT + checked_count))
  UNCHECKED_ITEMS=$(echo "$section_content" | grep '^- \[ \]' 2>/dev/null | head -5 | sed 's/^- \[ \] //' | paste -sd';' - || true)
}

# ── Emit results ──────────────────────────────────────────────────────────────

_emit() {
  printf 'RETURN_COMPLETENESS_STATUS=%s\n' "${RETURN_COMPLETENESS_STATUS:-error}"
  printf 'UNCHECKED_COUNT=%s\n' "${UNCHECKED_COUNT:-0}"
  printf 'TOTAL_COUNT=%s\n' "${TOTAL_COUNT:-0}"
  printf 'TASKS_FILE=%q\n' "${TASKS_FILE:-}"
  printf 'UNCHECKED_ITEMS=%q\n' "${UNCHECKED_ITEMS:-}"
  printf 'REASON=%s\n' "${REASON:-unknown}"
  printf 'ARTIFACT_TYPE=%s\n' "${ARTIFACT_TYPE:-}"

  # Phase 0 RLVR — record verifier result after return-completeness check.
  # PASS records the real box count (36/36), not 1/1 (GitHub #598 C); 1/1
  # only when the artifact has no boxes at all.
  local verdict="PASS" criteria_met="${TOTAL_COUNT:-0}" criteria_total="${TOTAL_COUNT:-0}"
  if [ "$criteria_total" -eq 0 ] 2>/dev/null || ! [[ "$criteria_total" =~ ^[0-9]+$ ]]; then
    criteria_met=1 criteria_total=1
  fi
  if [ "${RETURN_COMPLETENESS_STATUS:-error}" = "incomplete" ]; then
    verdict="FAIL"
    criteria_met=$((TOTAL_COUNT - UNCHECKED_COUNT))
    criteria_total="$TOTAL_COUNT"
    [ "$criteria_total" -eq 0 ] && criteria_total=1
  elif [ "${RETURN_COMPLETENESS_STATUS:-error}" = "error" ]; then
    verdict="BLOCK"
    criteria_met=0 criteria_total=1
  fi

  # No pipeline log means no verifier-result, which leaves flow.sh's verdict
  # gate unarmed for this check (GitHub #598 B). Say so loudly — on stdout
  # for the caller's eval, on stderr, and as a heartbeat — never silently.
  local _rcc_log="${LOG_FILE:-${TAP_LOG:-}}"
  if [ -z "$_rcc_log" ] || ! declare -f write_verifier_result >/dev/null 2>&1; then
    printf 'VERIFIER_RESULT=unrecorded\n'
    echo "[return-completeness] WARN: no pipeline log (--log-file, LOG_FILE or TAP_LOG) or verifier-result.sh missing — return_completeness ${verdict} NOT recorded; the verdict gate is unarmed for this check" >&2
    hb_gate "return-completeness" "warn" "verifier-result not recorded: no pipeline log" \
      "{\"ticket\":\"${TICKET_ID:-}\",\"verdict\":\"$verdict\"}" 2>/dev/null || true
    return 0
  fi
  printf 'VERIFIER_RESULT=recorded\n'
  # attempt = this pair's record count + 1, so a post-VERIFY refresh reads
  # as attempt 2 rather than a second attempt 1.
  local _rcc_attempt
  _rcc_attempt=$(grep -c '|META|verifier-result|info|{"verifier":"return_completeness"' "$_rcc_log" 2>/dev/null || true)
  _rcc_attempt=$((${_rcc_attempt:-0} + 1))
  LOG_FILE="$_rcc_log" write_verifier_result \
    verifier=return_completeness verdict="$verdict" \
    criteria_met="$criteria_met" criteria_total="$criteria_total" \
    attempt="$_rcc_attempt" phase=IMPLEMENT || true
}

# --refresh (GitHub #598 A): IMPLEMENT may leave tasks for VERIFY to tick
# (they need the running build), so the IMPLEMENT-time FAIL goes stale. Run
# after VERIFY, this re-counts only when the latest return_completeness
# result is FAIL/BLOCK; the fresh record then supersedes the stale one
# under verifier_latest_verdict's latest-record-wins rule. Otherwise it
# writes nothing. Returns 0 when a re-check is due, 1 when not.
_rcc_refresh_due() {
  local _log="${LOG_FILE:-${TAP_LOG:-}}"
  [ -n "$_log" ] && declare -f verifier_latest_verdict >/dev/null 2>&1 || return 0
  local _failing
  _failing=$(verifier_latest_verdict "$_log")
  [[ $'\n'"$_failing" == *$'\n'"return_completeness|IMPLEMENT|"* ]]
}

# ── Main dispatch (only when executed directly, not when sourced for testing) ─

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  TICKET_ID=""
  REPOS_ROOT="${REPOS_ROOT:-}"
  TASKS_FILE_ARG=""
  SIMPLE_FIX_FILE_ARG=""
  REFRESH=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --repos-root)
      REPOS_ROOT="${2:-}"
      shift 2
      ;;
    --tasks-file)
      TASKS_FILE_ARG="${2:-}"
      shift 2
      ;;
    --simple-fix-file)
      SIMPLE_FIX_FILE_ARG="${2:-}"
      shift 2
      ;;
    --log-file)
      # An unsubstituted "{LOG_FILE}" placeholder counts as absent.
      case "${2:-}" in "{"*"}" | "") ;; *) LOG_FILE="$2" ;; esac
      shift 2
      ;;
    --refresh)
      REFRESH=true
      shift
      ;;
    --help | -h)
      usage
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      usage
      ;;
    *)
      if [ -z "$TICKET_ID" ]; then
        TICKET_ID="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage
      fi
      ;;
    esac
  done

  [ -z "$TICKET_ID" ] && usage

  if [ "$REFRESH" = "true" ] && ! _rcc_refresh_due; then
    printf 'RETURN_COMPLETENESS_STATUS=current\nREASON=LATEST_NOT_FAILING\n'
    exit 0
  fi

  TASKS_FILE=""
  SIMPLE_FIX_FILE=""
  ARTIFACT_TYPE=""

  # Explicit flags take priority over repo search
  if [ -n "$TASKS_FILE_ARG" ]; then
    TASKS_FILE="$TASKS_FILE_ARG"
    ARTIFACT_TYPE="openspec"
  elif [ -n "$SIMPLE_FIX_FILE_ARG" ]; then
    SIMPLE_FIX_FILE="$SIMPLE_FIX_FILE_ARG"
    ARTIFACT_TYPE="simple-fix"
  elif [ -n "$REPOS_ROOT" ]; then
    # Dual-mode search: tasks.md first (openspec), then simple-fix.md fallback
    TASKS_FILE=$(_find_tasks_file "$TICKET_ID" "$REPOS_ROOT" || true)
    if [ -n "$TASKS_FILE" ] && [ -f "$TASKS_FILE" ]; then
      ARTIFACT_TYPE="openspec"
    else
      SIMPLE_FIX_FILE=$(_find_simple_fix_file "$TICKET_ID" "$REPOS_ROOT" || true)
      if [ -n "$SIMPLE_FIX_FILE" ] && [ -f "$SIMPLE_FIX_FILE" ]; then
        ARTIFACT_TYPE="simple-fix"
      fi
    fi
  fi

  # ── openspec path (tasks.md, whole-file count) ──
  if [ "$ARTIFACT_TYPE" = "openspec" ]; then
    _count_boxes "$TASKS_FILE"

    if [ "$UNCHECKED_COUNT" -gt 0 ] 2>/dev/null; then
      RETURN_COMPLETENESS_STATUS="incomplete"
      REASON="UNCHECKED_BOXES"
      _emit
      hb_gate "return-completeness" "warn" "$UNCHECKED_COUNT unchecked box(es)" \
        "{\"ticket\":\"$TICKET_ID\",\"unchecked\":\"$UNCHECKED_COUNT\",\"total\":\"$TOTAL_COUNT\",\"artifact\":\"openspec\"}" 2>/dev/null || true
      exit 1
    fi

    RETURN_COMPLETENESS_STATUS="complete"
    REASON="ALL_CHECKED"
    _emit
    hb_gate "return-completeness" "ok" "all boxes checked" \
      "{\"ticket\":\"$TICKET_ID\",\"total\":\"$TOTAL_COUNT\",\"artifact\":\"openspec\"}" 2>/dev/null || true
    exit 0
  fi

  # ── simple-fix path (Completion Checklist section, section-scoped count) ──
  if [ "$ARTIFACT_TYPE" = "simple-fix" ]; then
    # Verify the Completion Checklist section exists
    if ! grep -q '^## Completion Checklist' "$SIMPLE_FIX_FILE" 2>/dev/null; then
      RETURN_COMPLETENESS_STATUS="error"
      REASON="COMPLETION_CHECKLIST_MISSING"
      _emit
      hb_gate "return-completeness" "fail" "simple-fix.md lacks ## Completion Checklist" \
        "{\"ticket\":\"$TICKET_ID\",\"artifact\":\"simple-fix\"}" 2>/dev/null || true
      exit 2
    fi

    _count_checklist_boxes "$SIMPLE_FIX_FILE" "## Completion Checklist"

    if [ "$UNCHECKED_COUNT" -gt 0 ] 2>/dev/null; then
      RETURN_COMPLETENESS_STATUS="incomplete"
      REASON="UNCHECKED_BOXES"
      _emit
      hb_gate "return-completeness" "warn" "$UNCHECKED_COUNT unchecked box(es)" \
        "{\"ticket\":\"$TICKET_ID\",\"unchecked\":\"$UNCHECKED_COUNT\",\"total\":\"$TOTAL_COUNT\",\"artifact\":\"simple-fix\"}" 2>/dev/null || true
      exit 1
    fi

    RETURN_COMPLETENESS_STATUS="complete"
    REASON="ALL_CHECKED"
    _emit
    hb_gate "return-completeness" "ok" "all checklist items checked" \
      "{\"ticket\":\"$TICKET_ID\",\"total\":\"$TOTAL_COUNT\",\"artifact\":\"simple-fix\"}" 2>/dev/null || true
    exit 0
  fi

  # ── Neither artifact found ──
  RETURN_COMPLETENESS_STATUS="error"
  REASON="NO_PLAN_ARTIFACT_FOUND"
  _emit
  hb_gate "return-completeness" "fail" "no plan artifact found" \
    "{\"ticket\":\"$TICKET_ID\"}" 2>/dev/null || true
  exit 2
fi
