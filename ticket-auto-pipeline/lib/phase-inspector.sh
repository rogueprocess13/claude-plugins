#!/usr/bin/env bash
# phase-inspector.sh — Per-phase inspection context assembler for ticket-auto-pipeline.
# Phase 1 of the RLVR program.
#
# Reads META|verifier-result entries for a completed phase and assembles prompt
# context for the guidance-extractor-agent. The router handles the actual agent
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
    _vr_entries_ts=$(grep '^[^|]*|META|verifier-result|info|' "$LOG_FILE" 2>/dev/null |
      awk -F'|' '{ts=$1; s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print ts "\t" s}' |
      while IFS=$'\t' read -r _ts json_line; do
        _phase=$(echo "$json_line" | jq -r '.phase // empty' 2>/dev/null || true)
        if [ -z "$_phase" ]; then
          continue
        fi
        # Match against primary phase + any extra phases (space-delimited)
        case " $_target_phases " in
        *" $_phase "*) printf '%s\t%s\n' "$_ts" "$json_line" ;;
        esac
      done || true)
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
      if [ -n "$_vr_ts_first" ]; then
        _ri_warns=$(grep '^[^|]*|META|gate-warn|[^|]*|RETURN_INCOMPLETE' "$LOG_FILE" 2>/dev/null |
          awk -F'|' -v ts_first="$_vr_ts_first" '$1 >= ts_first {print}' | tail -1 || true)
      fi
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

  # ── Assemble context block for the agent ────────────────────────────────
  # Data section: built with printf %s — no format-string injection, no shell
  # expansion of log-derived content (_vr_json_array, _gate_warns).
  local _data_block
  _data_block=$(printf '## Phase Inspector Context\n\n**Phase**: %s\n**Ticket**: %s\n**Verifier Results** (JSON array):\n```json\n%s\n```\n\n**Gate Warnings**:\n```\n%s\n```\n\n**RETURN_INCOMPLETE present**: %s\n' \
    "$PHASE" "$TICKET_ID" "$_vr_json_array" "${_gate_warns:-none}" "$_has_return_incomplete")

  # Instructions section: quoted heredoc — no shell expansion at all.
  # Safe against backticks, $(), and ${} in the template text itself.
  local _instructions_block
  _instructions_block=$(
    cat <<'PHASEINSPECT'

## Instructions

Inspect the verifier results above. Check for these known defect patterns:

1. **flaky_tests** (WARN): A PASS verifier followed by a FAIL verifier on overlapping criteria (cross-phase — check for PASS+FAIL pairs within the available results or across phases when multi-phase context is provided)
2. **missing_requirement** (WARN): PR review OK but critique/audit found gaps
3. **trivial_pass** (WARN): Any non-gate verifier PASS with criteria_total between 1 and 1 (single-criterion verification). Exclude verifiers with criteria_total=0 (outcome-scored) and known single-criterion gates (gate_check, return_completeness).
4. **verdict_disagreement** (WARN): Two verifiers in the inspected phase(s) disagree (e.g., one PASS and one FAIL/BLOCK)
5. **incomplete_implementation** (WARN): PASS verifier + "RETURN_INCOMPLETE present" is true above. Only the IMPLEMENT inspection ever reports it true — unchecked boxes left at VERIFY / PR-REVIEW time belong to those later phases and are not an implementation gap, so never raise this pattern from the gate-warn text alone.

Verdict computation: worst severity wins across all detected patterns (PASS if 0 patterns, WARN if ≥1 WARN and 0 FAIL, FAIL if ≥1 FAIL).

Write exactly one line to the pipeline log (`$LOG_FILE`) with this command block, filling in only the single JSON line between the `JSON` markers. The written line MUST start with the ISO-8601 UTC timestamp field — the pipeline log format is `ISO|PHASE|STEP|STATUS|MSG`, and a line without its leading timestamp breaks every consumer that splits on `|`. Keep the rest of the block exactly as written:
```bash
_pi_json=$(cat <<'PHASE_INSPECTOR_VERDICT_EOF'
{"phase":"<phase>","verdict":"<PASS|WARN|FAIL>","signals":<N>,"detail":"<summary ≤ 200 chars>","verifiers_consulted":["<id1>","<id2>"],"patterns":[{"pattern":"<id>","severity":"<warn|fail>","evidence":"<specific>"}]}
PHASE_INSPECTOR_VERDICT_EOF
)
if _pi_line=$(printf '%s' "$_pi_json" | jq -c . 2>/dev/null) && [ -n "$_pi_line" ]; then
  printf '%s|META|phase-inspector|info|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_pi_line" >>"$LOG_FILE"
else
  echo "[phase-inspector] WARN: verdict JSON invalid or jq unavailable, nothing written" >&2
fi
```

Never put the JSON inside a double-quoted `echo` string: `detail` and `evidence` quote verifier output (test names, PR text), and a double-quoted string would run any `$(...)` or backtick in that text. The quoted `<<'PHASE_INSPECTOR_VERDICT_EOF'` heredoc keeps it literal; `jq -c` rejects invalid JSON so no partial line is ever written. Keep the JSON on that single line: JSON strings never hold a raw newline (escape it as `\n`), so verifier text can never form a line equal to the heredoc delimiter and end the heredoc early.

The JSON must be valid (jq-parseable) and on one line. Detail must be ≤ 200 chars. Use the phase value from the context above for the "phase" field.
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
