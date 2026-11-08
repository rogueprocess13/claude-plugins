#!/usr/bin/env bash
# verifier-result.sh — Uniform verifier-result recording for ticket-auto-pipeline.
# Phase 0 of the RLVR program.
#
# Usage: source this file, then call write_verifier_result with named params.
#
#   write_verifier_result \
#     verifier=<id> verdict=<PASS|FAIL|WARN|BLOCK> \
#     [criteria_met=<int>] [criteria_total=<int>] \
#     [attempt=<int>] [phase=<token>] \
#     [outcome=<Smooth|Rough|Hard>] [corrections=<int>]
#
# All params after the first nine are ignored (forward-compat).
# If LOG_FILE is unset or empty, the function logs to stderr and returns 0.

# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention
# across 10+ lib files omits -u for this reason (F3).
set -eo pipefail

# ── Score helpers ────────────────────────────────────────────────────────────────

# F9: _compute_actual_confidence extracted to lib/confidence.sh to prevent drift
# between verifier-result.sh and planned-feedback-write.sh.
VERIFIER_RESULT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$VERIFIER_RESULT_DIR/confidence.sh" ]; then
  source "$VERIFIER_RESULT_DIR/confidence.sh"
elif [ -f "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/confidence.sh" ]; then
  source "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/confidence.sh"
fi

# ── Primary function ─────────────────────────────────────────────────────────────

write_verifier_result() {
  local verifier="" verdict="" criteria_met=0 criteria_total=0 attempt=1 phase=""
  local outcome="" corrections=0

  # Parse named params
  # F14: ${arg#prefix=} strips only the first '=' — verifier names MUST NOT
  # contain '='. All current verifier names are constants (gate_check,
  # return_completeness, playwright_uat, etc.) so this is safe in practice.
  for arg in "$@"; do
    case "$arg" in
    verifier=*) verifier="${arg#verifier=}" ;;
    verdict=*) verdict="${arg#verdict=}" ;;
    criteria_met=*) criteria_met="${arg#criteria_met=}" ;;
    criteria_total=*) criteria_total="${arg#criteria_total=}" ;;
    attempt=*) attempt="${arg#attempt=}" ;;
    phase=*) phase="${arg#phase=}" ;;
    outcome=*) outcome="${arg#outcome=}" ;;
    corrections=*) corrections="${arg#corrections=}" ;;
    esac
  done

  # Validate required fields
  if [ -z "$verifier" ] || [ -z "$verdict" ]; then
    echo "[verifier-result] WARN: missing required field (verifier or verdict), skipping" >&2
    return 0
  fi

  # Validate verdict enum
  case "$verdict" in
  PASS | FAIL | WARN | BLOCK) ;;
  *)
    echo "[verifier-result] WARN: invalid verdict '${verdict}', skipping" >&2
    return 0
    ;;
  esac

  # Validate criteria_met/criteria_total are integers
  if ! [[ "$criteria_met" =~ ^[0-9]+$ ]]; then
    criteria_met=0
  fi
  if ! [[ "$criteria_total" =~ ^[0-9]+$ ]]; then
    criteria_total=0
  fi
  if ! [[ "$attempt" =~ ^[0-9]+$ ]]; then
    attempt=1
  fi
  if ! [[ "$corrections" =~ ^[0-9]+$ ]]; then
    corrections=0
  fi

  # Compute score
  local score
  case "$verdict" in
  PASS) score="1.0" ;;
  FAIL)
    if [ "$criteria_total" -eq 0 ]; then
      score="0.0"
    else
      # Bash division to 3 decimal places
      score=$(awk "BEGIN { printf \"%.3f\", $criteria_met / $criteria_total }")
    fi
    ;;
  WARN) score="0.7" ;;
  BLOCK) score="0.0" ;;
  esac

  # If outcome is provided, override with confidence scale score
  if [ -n "$outcome" ]; then
    score=$(_compute_actual_confidence "$outcome" "$corrections")
  fi

  # F8: clamp score to [0,1] — criteria_met > criteria_total would produce
  # score > 1.0; PASS defaults to 1.0 which is within range but any future
  # code path that computes a ratio on PASS must stay bounded.
  # awk float comparison: exit 0 if score > 1.0, exit 1 otherwise.
  if awk "BEGIN { exit($score > 1.0 ? 0 : 1) }" 2>/dev/null; then
    score="1.0"
  elif awk "BEGIN { exit($score < 0.0 ? 0 : 1) }" 2>/dev/null; then
    score="0.0"
  fi

  # Build JSON payload
  local iso
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Validate JSON with jq; skip on failure
  if ! command -v jq >/dev/null 2>&1; then
    echo "[verifier-result] WARN: jq not available, skipping verifier-result write" >&2
    return 0
  fi

  local json
  json=$(jq -nc \
    --arg verifier "$verifier" \
    --arg verdict "$verdict" \
    --argjson score "$score" \
    --argjson criteria_met "$criteria_met" \
    --argjson criteria_total "$criteria_total" \
    --argjson attempt "$attempt" \
    --arg phase "$phase" \
    '{verifier: $verifier, verdict: $verdict, score: $score, criteria_met: $criteria_met, criteria_total: $criteria_total, attempt: $attempt, phase: $phase}' 2>/dev/null)

  if [ -z "$json" ] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
    echo "[verifier-result] WARN: jq validation failed for payload, skipping" >&2
    return 0
  fi

  # Write to pipeline log (TAP_LOG is the name phase agents export, #575)
  local _vr_log="${LOG_FILE:-${TAP_LOG:-}}"
  if [ -z "$_vr_log" ]; then
    echo "[verifier-result] WARN: LOG_FILE unset, skipping verifier-result write" >&2
    return 0
  fi

  # F4: guard the final log append — disk full or unwritable LOG_FILE must not
  # abort the caller (all 6 pre-write validation paths return 0 gracefully)
  echo "${iso}|META|verifier-result|info|${json}" >>"$_vr_log" || {
    echo "[verifier-result] WARN: log write failed (LOG_FILE=${_vr_log})" >&2
    return 0
  }
  return 0
}

# ── Reader (VERDICT_FAIL_NOT_ENFORCED, issue #368) ──────────────────────────
#
# verifier_latest_verdict <log_file>
#
# One rule: for each (verifier, phase) pair, the LATEST verdict-bearing
# record in the log wins. A later PASS/WARN supersedes an earlier FAIL/BLOCK
# for the same pair, and a later FAIL/BLOCK re-arms it. Verdict-bearing
# records are:
#
#   1. `META|verifier-result|info|<json>` — every verifier.
#   2. `META|adversarial-override|info|reason=…` — written only by the
#      operator script lib/adversarial-override.sh (GitHub #610), which
#      refuses agent and fleetd-worker context. It counts as WARN for the
#      `adversarial_review|EXEC` pair (the script also writes that WARN as a
#      verifier-result), so a human override supersedes an earlier BLOCK
#      and a fresh BLOCK round after it re-arms the gate.
#
# A plain `EXEC|adversarial-review|done|PASS/WARNINGS` line is NOT a
# record: any phase agent can write it with plog.sh, so it must never clear
# a BLOCK on its own. The gate stays the independent second reader. Like
# verify-attempts-reset.sh this raises the bar and is not a sandbox:
# plog.sh refuses to write the marker (exit 3), but an agent that appends it
# with a raw `>>`, or writes a PASS/WARN verifier-result itself, is
# deliberately forging operator state, and no prompt tells it how. The log
# is a same-user file, so no in-process check can make it tamper-proof.
#
# A stale return_completeness FAIL (GitHub #598) clears the same way: the
# post-VERIFY `return-completeness-check.sh --refresh` writes a later
# verifier-result for the same pair.
#
# Prints one line per pair whose latest verdict is FAIL or BLOCK, in the
# form:
#
#   <verifier>|<phase>|<verdict>
#
# Prints nothing (and always returns 0) when the log is missing, empty, has
# no verdict-bearing records, or every pair's latest verdict is PASS/WARN.
# Absence of evidence is deliberately not failure — a ticket with zero
# verifier-results must transition exactly as it did before this reader
# existed.
#
# Per pipeline-log-format.md's MSG parsing rule: join fields 5+ with awk,
# never `cut -f5` — a JSON payload's own `|` characters would be truncated.
verifier_latest_verdict() {
  local log_file="$1"
  [ -n "$log_file" ] && [ -f "$log_file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  awk -F'|' '
    $2=="META" && $3=="verifier-result" {
      s=$5; for (i=6;i<=NF;i++) s=s"|"$i; print s; next
    }
    $2=="META" && $3=="adversarial-override" && $4=="info" && $5 ~ /^reason=./ {
      print "{\"verifier\":\"adversarial_review\",\"phase\":\"EXEC\",\"verdict\":\"WARN\"}"
    }' "$log_file" 2>/dev/null | jq -s -r '
    reduce .[] as $e ({}; .[(($e.verifier // "")) + "|" + ($e.phase // "")] = ($e.verdict // ""))
    | to_entries[]
    | select(.value == "FAIL" or .value == "BLOCK")
    | .key + "|" + .value
  ' 2>/dev/null || true
}
