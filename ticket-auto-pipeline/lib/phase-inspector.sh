#!/usr/bin/env bash
# phase-inspector.sh — Per-phase inspection context assembler for ticket-auto-pipeline.
# Phase 1 of the RLVR program.
#
# Reads META|verifier-result entries for a completed phase, computes the
# deterministic verdict with lib/inspect-verifiers.sh and writes it as the
# phase's META|phase-inspector line itself (DET-SU-1), then assembles prompt
# context for the guidance-extractor-agent, which classifies the verdict's
# patterns and never writes the verdict. The router handles the actual agent
# spawn using the standard 3-step pattern (spawn_agent_pre → Agent → spawn_agent_post).
#
# Usage: source this file, then call assemble_inspector_context.
#
#   assemble_inspector_context "IMPLEMENT" "CRE-123" "/path/to/log"
#
# Prints either INSPECTOR_SKIP (no verifier results) or INSPECTOR_INSTRUCTIONS
# containing the assembled context block for the agent prompt.
#
# All failure paths return 0 (fail-soft). Callers SHOULD wrap with || true.
# Shell flags intentionally NOT set here — this is a sourceable library.
# Setting -e, -u, or -o pipefail would poison every consumer that sources this file
# (repo convention: heartbeat.sh, spawn-helper.sh, verifier-result.sh all omit flags).
# Every failure path inside the function carries its own guard (|| true, if-else).

_PI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# ── Deterministic verdict (DET-SU-1) ──────────────────────────────────────────

# _pi_verdict_line PHASE VR_JSON_ARRAY HAS_RETURN_INCOMPLETE
# Runs inspect_verifiers and prints this phase's deterministic
# META|phase-inspector JSON ({phase, verdict, signals, detail,
# verifiers_consulted, patterns, source:"bash"}); empty on failure.
_pi_verdict_line() {
  local phase="$1" vr_json="$2" has_ri="$3"
  if ! declare -f inspect_verifiers >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_PI_LIB_DIR/inspect-verifiers.sh" 2>/dev/null || return 0
  fi
  local det=""
  det=$(inspect_verifiers "$vr_json" "$has_ri" "$phase" 2>/dev/null) || det=""
  [ -n "$det" ] || return 0
  jq -c --arg phase "$phase" --argjson vr "$vr_json" \
    '{phase: $phase, verdict, signals, detail,
      verifiers_consulted: ([$vr[] | .verifier // empty] | unique),
      patterns, source: "bash"}' <<<"$det" 2>/dev/null || true
  return 0
}

# _pi_write_verdict PHASE LOG_FILE VR_JSON_ARRAY HAS_RETURN_INCOMPLETE
# Appends _pi_verdict_line's JSON as this phase's META|phase-inspector line
# and prints it. Skips the write when the log's last line already is this
# exact verdict (resume/rerun). Fail-soft: always returns 0.
_pi_write_verdict() {
  local phase="$1" log_file="$2" line=""
  line=$(_pi_verdict_line "$phase" "$3" "$4") || line=""
  [ -n "$line" ] || return 0
  if [ -n "$log_file" ]; then
    local last=""
    last=$(tail -1 "$log_file" 2>/dev/null | awk -F'|' '$2 == "META" && $3 == "phase-inspector" {s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}') || last=""
    if [ "$last" != "$line" ]; then
      printf '%s|META|phase-inspector|info|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$log_file" 2>/dev/null || true
    fi
  fi
  printf '%s\n' "$line"
  return 0
}

# _pi_vr_entries_ts LOG_FILE "PHASE [EXTRA ...]"
# Prints "<ts>\t<json>" for every META|verifier-result line whose .phase is
# one of the listed phases. Awk-join (never cut -f5) recovers JSON holding
# pipes; per-line jq drops a torn line while its neighbours survive.
_pi_vr_entries_ts() {
  local log_file="$1" target_phases="$2"
  [ -n "$log_file" ] && [ -f "$log_file" ] || return 0
  grep '^[^|]*|META|verifier-result|info|' "$log_file" 2>/dev/null |
    awk -F'|' '{ts=$1; s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print ts "\t" s}' |
    while IFS=$'\t' read -r _ts json_line; do
      _phase=$(echo "$json_line" | jq -r '.phase // empty' 2>/dev/null || true)
      [ -n "$_phase" ] || continue
      case " $target_phases " in
      *" $_phase "*) printf '%s\t%s\n' "$_ts" "$json_line" ;;
      esac
    done || true
  return 0
}

# _pi_return_incomplete_warn LOG_FILE FIRST_TS
# Prints the last RETURN_INCOMPLETE gate-warn at or after FIRST_TS (empty if
# none). Only the IMPLEMENT inspector consults it (#418, see below).
_pi_return_incomplete_warn() {
  local log_file="$1" ts_first="$2"
  [ -n "$ts_first" ] && [ -f "$log_file" ] || return 0
  grep '^[^|]*|META|gate-warn|[^|]*|RETURN_INCOMPLETE' "$log_file" 2>/dev/null |
    awk -F'|' -v ts_first="$ts_first" '$1 >= ts_first {print}' | tail -1 || true
  return 0
}

# compute_inspector_verdict PHASE LOG_FILE [EXTRA_PHASES]
# Recomputes, from the log's verifier results, the exact deterministic
# verdict assemble_inspector_context writes — without writing anything.
# Prints nothing when the phases have no verifier results. Fail-soft.
compute_inspector_verdict() {
  local phase="$1" log_file="$2" extra="${3:-}"
  command -v jq >/dev/null 2>&1 || return 0
  local targets="$phase" entries_ts="" ts_first="" has_ri="false"
  [ -n "$extra" ] && targets="$targets $extra"
  entries_ts=$(_pi_vr_entries_ts "$log_file" "$targets")
  [ -n "$entries_ts" ] || return 0
  if [ "$phase" = "IMPLEMENT" ]; then
    ts_first=$(printf '%s\n' "$entries_ts" | head -1 | cut -f1)
    [ -z "$(_pi_return_incomplete_warn "$log_file" "$ts_first")" ] || has_ri="true"
  fi
  _pi_verdict_line "$phase" \
    "$(printf '%s\n' "$entries_ts" | cut -f2- | jq -c -s '.' 2>/dev/null || echo '[]')" "$has_ri"
  return 0
}

# ── Primary function ───────────────────────────────────────────────────────────

assemble_inspector_context() {
  local PHASE="$1"
  local TICKET_ID="$2"
  local LOG_FILE="$3"
  local EXTRA_PHASES="${4:-}" # space-separated additional phases (P1-1: cross-phase context)

  # Validate required params — fail-soft on missing args
  if [ -z "$PHASE" ] || [ -z "$TICKET_ID" ]; then
    echo "[phase-inspector] WARN: missing required param (PHASE or TICKET_ID), skipping" >&2
    echo "INSPECTOR_SKIP=true"
    return 0
  fi

  # ── Extract verifier-result entries for this phase ──────────────────────
  # Use awk-join (never cut -f5) to recover full JSON from pipe-delimited log.
  # Per-line jq for corruption tolerance — a broken JSON line is dropped while
  # its neighbors survive. jq failure count tracked for diagnostics (P2-2).
  local _vr_entries=""
  local _vr_entries_ts=""
  local _vr_skipped_lines=0
  local _vr_total_lines=0
  if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    _vr_total_lines=$(grep -c '^[^|]*|META|verifier-result|info|' "$LOG_FILE" 2>/dev/null || true)
    _vr_total_lines="${_vr_total_lines:-0}"
    # Build target phase list for multi-phase context (P1-1/P1-2)
    local _target_phases="$PHASE"
    [ -n "$EXTRA_PHASES" ] && _target_phases="$_target_phases $EXTRA_PHASES"
    # Carry the source line's timestamp alongside its JSON (tab-separated) so
    # the gate-warn window below can be scoped to matched entries only, not
    # every verifier-result in the whole log (P1-6 regression: a stale
    # gate-warn from an earlier phase kept reappearing in every later
    # phase's inspection context because the window was unscoped).
    _vr_entries_ts=$(_pi_vr_entries_ts "$LOG_FILE" "$_target_phases")
    if [ -n "$_vr_entries_ts" ]; then
      _vr_entries=$(printf '%s\n' "$_vr_entries_ts" | cut -f2-)
    fi
    # Compute skipped_lines: total verifier-result lines minus matched entries.
    # Handles both torn JSON (jq returns empty phase) and non-matching phases.
    local _vr_entry_count=0
    if [ -n "$_vr_entries" ]; then
      _vr_entry_count=$(echo "$_vr_entries" | wc -l | tr -d ' ')
    fi
    _vr_skipped_lines=$((_vr_total_lines - _vr_entry_count))
    [ "$_vr_skipped_lines" -lt 0 ] && _vr_skipped_lines=0
  fi

  # Check for jq availability (P2-1 diagnostic)
  local _jq_available="true"
  command -v jq >/dev/null 2>&1 || _jq_available="false"

  # ── No verifier results: write skip entry, signal skip ──────────────────
  if [ -z "$_vr_entries" ]; then
    local _skip_reason=""
    if [ "$_jq_available" != "true" ]; then
      _skip_reason="jq not available — cannot parse verifier results"
    elif [ "$_vr_skipped_lines" -gt 0 ]; then
      _skip_reason="No verifier results for ${PHASE} (${_vr_skipped_lines} unparseable line(s) found in log)"
    else
      _skip_reason="No verifier results available for ${PHASE}"
    fi
    local _skip_json
    _skip_json=$(printf '{"phase":"%s","verdict":"WARN","signals":0,"detail":"%s","verifiers_consulted":[],"patterns":[]}' \
      "$PHASE" "$_skip_reason")
    if [ -n "$LOG_FILE" ]; then
      # P2-5: tail-check idempotency guard — skip duplicate on resume/rerun
      if ! tail -1 "$LOG_FILE" 2>/dev/null | grep -q '|META|phase-inspector|'; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|phase-inspector|info|${_skip_json}" >>"$LOG_FILE" || true
      fi
    fi
    echo "INSPECTOR_SKIP=true"
    return 0
  fi

  # ── Assemble verifier context as JSON array ─────────────────────────────
  local _vr_json_array
  _vr_json_array=$(echo "$_vr_entries" | jq -s '.' 2>/dev/null || echo "[]")
  # P2-2: include skipped line count in context for agent awareness
  if [ "$_vr_skipped_lines" -gt 0 ]; then
    _vr_json_array=$(echo "$_vr_json_array" | jq -c --argjson skipped "$_vr_skipped_lines" \
      '{data: ., _meta: {skipped_lines: $skipped}}' 2>/dev/null || echo "$_vr_json_array")
  fi

  # Collect gate-warn entries scoped to the inspected phases' time window (P1-6).
  # Find timestamp bounds from the extracted verifier results, then filter
  # gate-warns to that range. Falls back to tail -3 if bounds unavailable.
  local _gate_warns=""
  local _has_return_incomplete="false"
  if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    # Find first/last verifier-result timestamps for the target phases
    local _vr_ts_first="" _vr_ts_last=""
    if [ -n "$_vr_entries_ts" ]; then
      _vr_ts_first=$(printf '%s\n' "$_vr_entries_ts" | head -1 | cut -f1 || true)
      _vr_ts_last=$(printf '%s\n' "$_vr_entries_ts" | tail -1 | cut -f1 || true)
    fi
    if [ -n "$_vr_ts_first" ] && [ -n "$_vr_ts_last" ]; then
      _gate_warns=$(grep '^[^|]*|META|gate-warn|' "$LOG_FILE" 2>/dev/null |
        awk -F'|' -v ts_first="$_vr_ts_first" -v ts_last="$_vr_ts_last" \
          '$1 >= ts_first && $1 <= ts_last {print}' || true)
    else
      _gate_warns=$(grep '^[^|]*|META|gate-warn|' "$LOG_FILE" 2>/dev/null | tail -3 || true)
    fi
    # RETURN_INCOMPLETE is attributed by owning phase, not by time window (#418).
    # It is written only by the router's IMPLEMENT step, AFTER spawn_capture —
    # i.e. after every IMPLEMENT verifier-result — so the window above missed it
    # for the IMPLEMENT inspector, while the VERIFY / PR-REVIEW inspectors
    # (whose window is stretched back over IMPLEMENT by EXTRA_PHASES) picked it
    # up and raised incomplete_implementation against boxes their own phase
    # owns and was in the middle of doing. Strip it from every window, then
    # re-add it only for the IMPLEMENT inspector, with no upper bound.
    _gate_warns=$(printf '%s\n' "$_gate_warns" | grep -v '|META|gate-warn|[^|]*|RETURN_INCOMPLETE' || true)
    if [ "$PHASE" = "IMPLEMENT" ]; then
      local _ri_warns=""
      _ri_warns=$(_pi_return_incomplete_warn "$LOG_FILE" "$_vr_ts_first")
      if [ -n "$_ri_warns" ]; then
        _has_return_incomplete="true"
        if [ -n "$_gate_warns" ]; then
          _gate_warns=$(printf '%s\n%s' "$_gate_warns" "$_ri_warns")
        else
          _gate_warns="$_ri_warns"
        fi
      fi
    fi
  fi

  # ── Deterministic verdict: bash writes it, the agent only reads it ──────
  local _verdict_json=""
  _verdict_json=$(_pi_write_verdict "$PHASE" "$LOG_FILE" \
    "$(printf '%s\n' "$_vr_entries" | jq -c -s '.' 2>/dev/null || echo '[]')" \
    "$_has_return_incomplete") || _verdict_json=""

  # ── Assemble context block for the agent ────────────────────────────────
  # Data section: built with printf %s — no format-string injection, no shell
  # expansion of log-derived content (_vr_json_array, _gate_warns).
  local _data_block
  _data_block=$(printf '## Phase Inspector Context\n\n**Phase**: %s\n**Ticket**: %s\n**Verifier Results** (JSON array):\n```json\n%s\n```\n\n**Gate Warnings**:\n```\n%s\n```\n\n**RETURN_INCOMPLETE present**: %s\n\n**Deterministic verdict** (already in the pipeline log):\n```json\n%s\n```\n' \
    "$PHASE" "$TICKET_ID" "$_vr_json_array" "${_gate_warns:-none}" "$_has_return_incomplete" "${_verdict_json:-unavailable}")

  # Instructions section: quoted heredoc — no shell expansion at all.
  # Safe against backticks, $(), and ${} in the template text itself.
  # The detection rules live in lib/inspect-verifiers.sh (DET-SU-1); this
  # block only names them for the agent's classification pass. To add a
  # pattern, add it there and list it here. Prefer WARN; promote a pattern to
  # FAIL only after >=5 confirmed true positives.
  local _instructions_block
  _instructions_block=$(
    cat <<'PHASEINSPECT'

## Instructions

The deterministic verdict above was computed by `lib/inspect-verifiers.sh` and is already written as this phase's `META|phase-inspector` line. Bash owns it: do not recompute it and do not write another `META|phase-inspector` line. `router-step.sh inspector-done` checks any line you add with `validate_phase_inspector`, and bash overrides a line that disagrees.

The pattern ids bash applies (reference for classification):

1. **flaky_tests** — a PASS verifier and a FAIL verifier in the inspected results (VERIFY also reads IMPLEMENT's results; PR-REVIEW reads both).
2. **missing_requirement** — a review verifier PASS while a critique or audit verifier is WARN or FAIL.
3. **trivial_pass** — a PASS with criteria_total == 1; gate_check and return_completeness are excluded, and criteria_total=0 (outcome-scored) never counts.
4. **verdict_disagreement** — a PASS and a BLOCK, only when flaky_tests did not fire.
5. **incomplete_implementation** — a PASS while RETURN_INCOMPLETE is present; IMPLEMENT only.

In `--mode extract`, classify each entry of the verdict's `patterns` array as the guidance-extractor skill describes. With an empty `patterns` array there is nothing to classify: write the `META|guidance-extractor` summary with zero counts and return.
PHASEINSPECT
  ) || _instructions_block=""

  local _ctx_block
  _ctx_block="${_data_block}${_instructions_block}"
  _ctx_block="${_ctx_block:-<context assembly failed>}"

  # Print the context block as INSPECTOR_INSTRUCTIONS for the router to use
  # with spawn_agent_pre's INSTRUCTIONS parameter.
  echo "INSPECTOR_SKIP=false"
  printf 'INSPECTOR_INSTRUCTIONS=%s\n' "$_ctx_block"

  return 0
}

# ── Spec-compliant wrapper (P1-4) ─────────────────────────────────────────────

# spawn_phase_inspector provides the function signature required by the
# router-integration spec while delegating to assemble_inspector_context.
# HB_LOG_FILE is accepted for spec compliance (unused — the router handles
# the actual agent spawn via spawn_agent_pre).
spawn_phase_inspector() {
  local PHASE="$1"
  local TICKET_ID="$2"
  local LOG_FILE="$3"
  local HB_LOG_FILE="$4"      # accepted, currently unused by the assembler
  local EXTRA_PHASES="${5:-}" # space-separated additional phases

  assemble_inspector_context "$PHASE" "$TICKET_ID" "$LOG_FILE" "$EXTRA_PHASES"
}
