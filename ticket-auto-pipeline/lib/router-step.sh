#!/usr/bin/env bash
# router-step.sh — the ticket-auto router's deterministic per-phase tails
# (skill-deterministic-extraction 3). One entry point for the manual router
# (skills/ticket-auto/SKILL.md) and, later, fleetd (fleetd-shared-router-steps).
#
# Usage:
#   router-step.sh post-spawn <PHASE> <TICKET-ID> --log-file F
#                  [--attempt N] [--ticket-dir D] [--repos-root R] [--result-file P]
#   router-step.sh inspector <PHASE> <TICKET-ID> --log-file F
#                  [--hb-log-file H] [--out P]
#   router-step.sh inspector-done <PHASE> <TICKET-ID> [--result-file P] [--log-file F]
#   router-step.sh retro-check --log-file F [--hb-log-file H] [--no-drift-log]
#
# Every option value that is still an unfilled `{PLACEHOLDER}` reads as empty.
# --result-file defaults to ./logs/<TICKET-ID>-agent-return.txt, the file the
# router writes the agent's return into (quoted heredoc). Paths under ./logs
# are relative to the current directory, as spawn_capture's are.
#
# post-spawn — runs after the agent's return is written to --result-file and
# BEFORE spawn_agent_post (the router still picks RESULT=/VERDICT=):
#   1. spawn_capture TICKET_ID PHASE RESULT_FILE [ATTEMPT=--attempt]
#      → ./logs/<TID>-<phase>-agent.log (append per attempt when ATTEMPT is set)
#   2. IMPLEMENT | VERIFY | PR-REVIEW: phase-result-parse.sh on that capture
#      (advisory, writes META|phase-result|info|{json}; || true)
#   3. VERIFY: verdict-recompute.sh --ticket-dir D (advisory, META|claim-delta)
#   4. IMPLEMENT: return-completeness-check.sh --repos-root R; when the status
#      is not `complete`, writes
#        META|gate-warn|info|RETURN_INCOMPLETE — <REASON> (unchecked=U/T, artifact=A)
#      Warn-only (Phase 1): never changes RESULT=. Prints
#      RETURN_COMPLETENESS_STATUS=<status>.
#
# inspector — RLVR Phase 1 advisory inspection prelude. Calls
# spawn_phase_inspector (lib/phase-inspector.sh) `|| true` with the phase's
# cross-phase context (VERIFY adds IMPLEMENT; PR-REVIEW adds IMPLEMENT VERIFY).
# With verifier results, the library itself writes the deterministic
# META|phase-inspector verdict (inspect_verifiers, "source":"bash"; DET-SU-1).
# With no verifier results the function writes its own
# META|phase-inspector|info|{... "verdict":"WARN" ...} skip line and this prints
#   PHASE_INSPECTOR_READY=skip
# Otherwise it writes the agent instructions to --out (default
# ./logs/<TID>-<phase>-inspector-instructions.txt) and prints
#   PHASE_INSPECTOR_READY=<PHASE>
#   INSPECTOR_INSTRUCTIONS_FILE=<path>
# The guidance-extractor-agent spawn itself stays with the caller.
#
# inspector-done — after the inspector agent returns:
#   validate: recomputes bash's verdict from the verifier results in the log
#     (--log-file, else ./logs/<TID>-pipeline.log) with
#     compute_inspector_verdict (lib/phase-inspector.sh); a "source":"bash"
#     field is never trusted. If <PHASE>'s last META|phase-inspector line is
#     missing, malformed, or differs in .verdict/.signals, bash's verdict is
#     appended ("agent_overridden":true), so the last line for the phase is
#     bash's. Validation failure fails closed (still appends).
#   spawn_capture ... ATTEMPT=inspector   (appends; never overwrites the phase
#                                          agent's own capture)
#   spawn_agent_post RESULT=done MSG="Phase inspector completed for <PHASE>"
#                    PHASE=<PHASE> STEP=phase-inspector-<phase>   (|| true)
#
# retro-check — STEP_6's five retro-trigger conditions:
#   1. a |META|gate-stop|fail| line
#   2. no ^…|VERIFY|verify|done|PASS line, or no ^…|PR-REVIEW|pr-review|done|(OK|N/A)
#      line (#149: PR-REVIEW never says PASS; #318: N/A is a clean no-diff run)
#   3. a |fallback| event in the heartbeat log — also writes
#      META|drift|warn|drift detected — heartbeat fallback events present
#      (skipped with --no-drift-log, for a caller that writes it itself)
#   4. VERIFY_EXHAUSTED anywhere in the log
#   5. a ^…|VERIFY|verify|fail| line
#   Prints NEEDS_RETRO=true|false, DRIFT=true|false and RETRO_REASONS=<list>
#   (comma-separated, shell-quoted), all eval-safe.
#
# No subcommand changes a log step name, a phase name or the grammar
# detect-resume.sh parses, and none writes META|outcome.
#
# Exit codes: 0 done (every advisory failure is swallowed, as the prose
# swallowed it); 2 usage.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_RS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_rs_usage() {
  sed -n '4,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# _rs_val VALUE — empty for an unfilled {PLACEHOLDER}.
_rs_val() {
  case "$1" in "{"*"}") printf '' ;; *) printf '%s' "$1" ;; esac
}

_rs_plog() {
  bash "$_RS_DIR/plog.sh" --log-file "$_rs_log_file" "$@" || true
}

_rs_spawn_helper() {
  if ! declare -f spawn_capture >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_RS_DIR/spawn-helper.sh"
  fi
}

_rs_cmd="${1:-}"
[ -n "$_rs_cmd" ] || _rs_usage
shift

_rs_phase="" _rs_tid=""
case "$_rs_cmd" in
post-spawn | inspector | inspector-done)
  [ $# -ge 2 ] || _rs_usage
  _rs_phase="$1" _rs_tid="$2"
  shift 2
  case "$_rs_phase" in "" | -* | "{"*"}") _rs_usage ;; esac
  case "$_rs_tid" in "" | -* | "{"*"}") _rs_usage ;; esac
  ;;
retro-check) ;;
*) _rs_usage ;;
esac

_rs_log_file="" _rs_hb_log_file="" _rs_attempt="" _rs_ticket_dir="" _rs_repos_root=""
_rs_result_file="" _rs_out="" _rs_drift_log=true
while [ $# -gt 0 ]; do
  case "$1" in
  --log-file | --hb-log-file | --attempt | --ticket-dir | --repos-root | --result-file | --out)
    [ $# -ge 2 ] || _rs_usage
    _v=$(_rs_val "$2")
    case "$1" in
    --log-file) _rs_log_file="$_v" ;;
    --hb-log-file) _rs_hb_log_file="$_v" ;;
    --attempt) _rs_attempt="$_v" ;;
    --ticket-dir) _rs_ticket_dir="$_v" ;;
    --repos-root) _rs_repos_root="$_v" ;;
    --result-file) _rs_result_file="$_v" ;;
    --out) _rs_out="$_v" ;;
    esac
    shift 2
    ;;
  --no-drift-log)
    _rs_drift_log=false
    shift
    ;;
  *) _rs_usage ;;
  esac
done

_rs_phase_lower=$(printf '%s' "$_rs_phase" | tr '[:upper:]' '[:lower:]')
[ -n "$_rs_result_file" ] || _rs_result_file="./logs/${_rs_tid}-agent-return.txt"

# ── post-spawn ────────────────────────────────────────────────────────────────
_rs_post_spawn() {
  [ -n "$_rs_log_file" ] || _rs_usage
  _rs_spawn_helper
  if [ -n "$_rs_attempt" ]; then
    spawn_capture TICKET_ID="$_rs_tid" PHASE="$_rs_phase" \
      RESULT_FILE="$_rs_result_file" ATTEMPT="$_rs_attempt" ||
      echo "router-step: spawn_capture failed for $_rs_phase (continuing)" >&2
  else
    spawn_capture TICKET_ID="$_rs_tid" PHASE="$_rs_phase" \
      RESULT_FILE="$_rs_result_file" ||
      echo "router-step: spawn_capture failed for $_rs_phase (continuing)" >&2
  fi

  local _capture="./logs/${_rs_tid}-${_rs_phase_lower}-agent.log"
  case "$_rs_phase" in
  IMPLEMENT | VERIFY | PR-REVIEW)
    # Advisory, observe-only: exit 1 (absent/malformed block →
    # claimed_verdict=UNKNOWN) is normal and nothing routes on it.
    bash "$_RS_DIR/phase-result-parse.sh" --phase "$_rs_phase" \
      --return-file "$_capture" \
      --log-file "$_rs_log_file" >/dev/null 2>&1 || true
    ;;
  esac

  if [ "$_rs_phase" = VERIFY ]; then
    # Advisory, observe-only: never gates, never halts on a mismatch.
    bash "$_RS_DIR/verdict-recompute.sh" --phase VERIFY \
      --return-file "$_capture" \
      --ticket-dir "$_rs_ticket_dir" \
      --log-file "$_rs_log_file" >/dev/null 2>&1 || true
  fi

  if [ "$_rs_phase" = IMPLEMENT ]; then
    local _rcc_out="" RETURN_COMPLETENESS_STATUS="" REASON="" UNCHECKED_COUNT="" TOTAL_COUNT="" ARTIFACT_TYPE=""
    _rcc_out=$(bash "$_RS_DIR/return-completeness-check.sh" "$_rs_tid" \
      --repos-root "$_rs_repos_root" --log-file "$_rs_log_file") || true
    eval "$_rcc_out" 2>/dev/null || true
    if [ "${RETURN_COMPLETENESS_STATUS:-complete}" != "complete" ]; then
      _rs_plog META gate-warn info "RETURN_INCOMPLETE — ${REASON:-unknown} (unchecked=${UNCHECKED_COUNT:-?}/${TOTAL_COUNT:-?}, artifact=${ARTIFACT_TYPE:-?})"
    fi
    printf 'RETURN_COMPLETENESS_STATUS=%s\n' "${RETURN_COMPLETENESS_STATUS:-complete}"
  fi
  return 0
}

# ── inspector ─────────────────────────────────────────────────────────────────
# _rs_extra_phases — the phase's cross-phase inspector context.
_rs_extra_phases() {
  case "$_rs_phase" in
  VERIFY) echo "IMPLEMENT" ;;
  PR-REVIEW) echo "IMPLEMENT VERIFY" ;;
  esac
}

_rs_inspector() {
  [ -n "$_rs_log_file" ] || _rs_usage
  local _extra=""
  _extra=$(_rs_extra_phases)
  local _pi_out=""
  # Sourced and called in a subshell: nothing the library does (an `exit`, a
  # stray `set -e` failure) can end this script or change its exit code.
  _pi_out=$(
    # shellcheck source=/dev/null
    source "$_RS_DIR/phase-inspector.sh" 2>/dev/null || exit 0
    declare -f spawn_phase_inspector >/dev/null 2>&1 || exit 0
    spawn_phase_inspector "$_rs_phase" "$_rs_tid" "$_rs_log_file" \
      "$_rs_hb_log_file" "$_extra"
  ) || true
  if grep -q '^INSPECTOR_INSTRUCTIONS=' <<<"$_pi_out"; then
    local _out="${_rs_out:-./logs/${_rs_tid}-${_rs_phase_lower}-inspector-instructions.txt}"
    mkdir -p "$(dirname "$_out")" 2>/dev/null || true
    if printf '%s\n' "$_pi_out" |
      awk '/^INSPECTOR_INSTRUCTIONS=/{sub(/^INSPECTOR_INSTRUCTIONS=/,""); found=1; print; next} found{print}' \
        >"$_out.tmp.$$" 2>/dev/null && mv -f "$_out.tmp.$$" "$_out" 2>/dev/null; then
      echo "PHASE_INSPECTOR_READY=$_rs_phase"
      echo "INSPECTOR_INSTRUCTIONS_FILE=$_out"
      return 0
    fi
    rm -f "$_out.tmp.$$" 2>/dev/null || true
    echo "router-step: could not write inspector instructions to $_out" >&2
  fi
  echo "PHASE_INSPECTOR_READY=skip"
  return 0
}

# ── inspector-done ────────────────────────────────────────────────────────────
# _rs_inspector_validate — DET-SU-1: bash has the final word on the verdict.
# Bash's verdict is recomputed here from the log's verifier results
# (compute_inspector_verdict, the same call the inspector prelude makes) and
# never read back from the log, so a line claiming "source":"bash" earns no
# trust. When the phase has verifier results and its last META|phase-inspector
# line is missing, malformed, or differs from the recomputed verdict in
# .verdict or .signals (typed jq comparison, so "2" is not 2), the
# recomputed verdict is appended with "agent_overridden":true. Fails closed:
# an unparseable claim or a failing validate_phase_inspector still appends.
# With no verifier results, or no jq, the log is left as it is.
_rs_inspector_validate() {
  local log="${_rs_log_file:-./logs/${_rs_tid}-pipeline.log}"
  [ -f "$log" ] && command -v jq >/dev/null 2>&1 || return 0
  local det=""
  det=$(
    # shellcheck source=/dev/null
    source "$_RS_DIR/phase-inspector.sh" 2>/dev/null || exit 0
    compute_inspector_verdict "$_rs_phase" "$log" "$(_rs_extra_phases)"
  ) || det=""
  jq -e 'type == "object" and has("verdict") and has("signals")' <<<"$det" >/dev/null 2>&1 || return 0
  # Last line for this phase, whatever its claimed source. A line with no
  # parseable .phase cannot be attributed elsewhere, so it counts as a claim
  # for this phase (at worst bash re-asserts its own verdict).
  local claim="" j="" ph=""
  while IFS= read -r j; do
    if ph=$(jq -er '.phase' <<<"$j" 2>/dev/null); then
      [ "$ph" = "$_rs_phase" ] && claim="$j"
    else
      claim="$j"
    fi
  done < <(grep '^[^|]*|META|phase-inspector|' "$log" 2>/dev/null |
    awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}')
  if [ -n "$claim" ] && jq -e --argjson d "$det" \
    'type == "object" and .verdict == $d.verdict and .signals == $d.signals' \
    <<<"$claim" >/dev/null 2>&1; then
    return 0
  fi
  # Disagreement. validate_phase_inspector builds the override line; its
  # output is used only if it really re-asserts bash's verdict.
  local out=""
  out=$(
    # shellcheck source=/dev/null
    source "$_RS_DIR/inspect-verifiers.sh" 2>/dev/null || exit 0
    validate_phase_inspector "$claim" "$det" "$_rs_phase" 2>/dev/null
  ) || out=""
  if ! jq -e --argjson d "$det" --arg p "$_rs_phase" \
    'type == "object" and .agent_overridden == true and .phase == $p
     and .verdict == $d.verdict and .signals == $d.signals' <<<"$out" >/dev/null 2>&1; then
    out=$(jq -c --arg p "$_rs_phase" \
      '. + {phase: $p, bash_validated: true, agent_overridden: true, agent_claim: null}' \
      <<<"$det" 2>/dev/null) || return 0
  fi
  out=$(jq -c . <<<"$out" 2>/dev/null) || return 0
  printf '%s|META|phase-inspector|info|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$out" >>"$log" 2>/dev/null || true
  echo "router-step: $_rs_phase inspector verdict re-asserted by bash (last line missing or disagreed)" >&2
  return 0
}

_rs_inspector_done() {
  _rs_inspector_validate || true
  _rs_spawn_helper
  spawn_capture TICKET_ID="$_rs_tid" PHASE="$_rs_phase" \
    RESULT_FILE="$_rs_result_file" ATTEMPT=inspector ||
    echo "router-step: inspector spawn_capture failed for $_rs_phase (continuing)" >&2
  spawn_agent_post TICKET_ID="$_rs_tid" RESULT=done \
    MSG="Phase inspector completed for $_rs_phase" \
    PHASE="$_rs_phase" STEP="phase-inspector-$_rs_phase_lower" 2>/dev/null || true
  return 0
}

# ── retro-check ───────────────────────────────────────────────────────────────
_rs_retro_check() {
  [ -n "$_rs_log_file" ] || _rs_usage
  local needs=false drift=false reasons=()
  if grep -q '|META|gate-stop|fail|' "$_rs_log_file" 2>/dev/null; then
    needs=true
    reasons+=("gate-stop fired")
  fi
  if ! grep -q '^[^|]*|VERIFY|verify|done|PASS' "$_rs_log_file" 2>/dev/null ||
    ! grep -qE '^[^|]*\|PR-REVIEW\|pr-review\|done\|(OK|N/A)' "$_rs_log_file" 2>/dev/null; then
    needs=true
    reasons+=("no VERIFY PASS + PR-REVIEW OK")
  fi
  if [ -n "$_rs_hb_log_file" ] && grep -q '|fallback|' "$_rs_hb_log_file" 2>/dev/null; then
    needs=true
    drift=true
    reasons+=("heartbeat fallback event")
    if [ "$_rs_drift_log" = true ]; then
      _rs_plog META drift warn "drift detected — heartbeat fallback events present"
    fi
  fi
  if grep -q 'VERIFY_EXHAUSTED' "$_rs_log_file" 2>/dev/null; then
    needs=true
    reasons+=("VERIFY exhaustion code present")
  fi
  if grep -q '^[^|]*|VERIFY|verify|fail|' "$_rs_log_file" 2>/dev/null; then
    needs=true
    reasons+=("VERIFY fail")
  fi
  local joined=""
  if [ ${#reasons[@]} -gt 0 ]; then
    joined=$(
      IFS=,
      printf '%s' "${reasons[*]}"
    )
  fi
  printf 'NEEDS_RETRO=%s\n' "$needs"
  printf 'DRIFT=%s\n' "$drift"
  printf 'RETRO_REASONS=%q\n' "$joined"
  return 0
}

case "$_rs_cmd" in
post-spawn) _rs_post_spawn ;;
inspector) _rs_inspector ;;
inspector-done) _rs_inspector_done ;;
retro-check) _rs_retro_check ;;
esac
exit 0
