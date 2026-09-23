#!/usr/bin/env bash
# gate-check.sh — deterministic bash gate logic for pipeline entry and re-approval.
# Replaces inline LLM gate reasoning in the orchestrator.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
source "$LIB_DIR/linear-api.sh"
# F2: guard source of verifier-result.sh — it may not exist on fresh installs
# (the runtime lib path ~/.claude/skills/lib/ is populated by install.sh/Makefile)
if [ -f "$LIB_DIR/verifier-result.sh" ]; then
  source "$LIB_DIR/verifier-result.sh"
elif [ -f "$SCRIPT_DIR/verifier-result.sh" ]; then
  source "$SCRIPT_DIR/verifier-result.sh"
fi
source "$LIB_DIR/notes-parse.sh"
if [ -f "$LIB_DIR/events.sh" ]; then
  source "$LIB_DIR/events.sh"
elif [ -f "$SCRIPT_DIR/events.sh" ]; then
  source "$SCRIPT_DIR/events.sh"
fi
# manifest-read.sh backs the approval/stage decision reads below
# (tracker-approval-by-script) — gate-check.sh runs as its own `bash`
# subprocess (not sourced into a caller's shell), so it must source this
# itself rather than relying on a caller having already done so. Also
# backs Check 2.7b's pre-existing manifest-first type read, which was
# unreachable in production without this (get_ticket_manifest_field was
# never declared when gate-check.sh ran as a real subprocess).
if [ -f "$LIB_DIR/manifest-read.sh" ]; then
  source "$LIB_DIR/manifest-read.sh"
elif [ -f "$SCRIPT_DIR/manifest-read.sh" ]; then
  source "$SCRIPT_DIR/manifest-read.sh"
fi

# ── Verifier-result helper (Phase 0 RLVR) ──────────────────────────────────────
# Writes a META|verifier-result at gate decision time.
# Wrapped for set -e safety; failure never alters gate behaviour.
_write_gate_verdict() {
  local verdict="$1" criteria_met="${2:-0}" criteria_total="${3:-1}" phase="${4:-GATE}"
  # F8: PASS defaults to 1/1 criteria (not 0/1 — contradictory with score=1.0)
  if [ "$verdict" = "PASS" ] && [ "$criteria_met" = "0" ] && [ "$criteria_total" = "1" ]; then
    criteria_met=1
  fi
  write_verifier_result \
    verifier=gate_check verdict="$verdict" \
    criteria_met="$criteria_met" criteria_total="$criteria_total" \
    attempt=1 phase="$phase" || true
  # F13: 2>/dev/null removed — in a jq-less environment, silently dropping
  # every gate verdict with zero trace is worse than noisy stderr warnings.
  # write_verifier_result is fail-open (returns 0 on all error paths),
  # so stderr is the only signal of a configuration problem.
}

# ── Outbox dual-write (tracker-event-vocabulary-and-emitter) ──────────────────
# gate-check.sh never calls flow.sh for a hold — a hold changes no Linear
# label or state, so flow.sh's own idempotency rule would swallow the
# emission even if it did. Guarded: not every gate-check.sh invocation runs
# from a context where the outbox lib is installed alongside it, and this
# must never fail the gate decision itself.
_gate_emit_held() {
  declare -f emit_event >/dev/null 2>&1 || return 0
  emit_event "$TICKET_ID" gate-held "$(jq -nc --arg r "$1" '{reason: $r}')" 2>/dev/null || true
}

_gate_emit_released() {
  declare -f emit_event >/dev/null 2>&1 || return 0
  emit_event "$TICKET_ID" gate-released "$(jq -nc --arg p "$1" '{provenance: $p}')" 2>/dev/null || true
}

# _gate_manifest_approved <TID> <expected-stage>
# tracker-approval-by-script: the sole approval decision read for Checks
# 2.8b/2.8c/4 and _gate_reapprove — no tracker fetch, no fallback. Two-
# factor (design D1): approved AND staged, so a manifest carrying a stale
# approval fact for a ticket that never actually transitioned cannot pass.
# Echoes exactly one of:
#   pass                 — approved=true and stage matches
#   hold                 — manifest read cleanly; not approved, or wrong stage
#   hold-missing-manifest — no manifest (or the lib itself/REPOS_ROOT is
#                           unavailable) — a migration/provisioning gap
#                           distinct from an ordinary hold (D3); the caller
#                           logs META|manifest|warn|MANIFEST_MISSING for
#                           this case only.
# Always exits 0 — callers branch on the echoed word, never on a coerced
# `|| echo false` (tracker-read-failure-policy: "empty is never substituted
# for unreadable").
_gate_manifest_approved() {
  local tid="$1" expected_stage="$2"
  if ! declare -f get_ticket_manifest_field >/dev/null 2>&1; then
    echo "hold-missing-manifest"
    return 0
  fi
  local approved approved_rc=0
  approved=$(get_ticket_manifest_field "$tid" approved 2>/dev/null) || approved_rc=$?
  if [ "$approved_rc" -ne 0 ]; then
    echo "hold-missing-manifest"
    return 0
  fi
  if [ "$approved" != "true" ]; then
    echo "hold"
    return 0
  fi
  local stage stage_rc=0
  stage=$(get_ticket_manifest_field "$tid" stage 2>/dev/null) || stage_rc=$?
  if [ "$stage_rc" -eq 0 ] && [ "$stage" = "$expected_stage" ]; then
    echo "pass"
  else
    echo "hold"
  fi
}

source "$SCRIPT_DIR/planned-ticket-check.sh"
source "$SCRIPT_DIR/template-select.sh"
source "$SCRIPT_DIR/planned-ticket-body-check.sh"
source "$SCRIPT_DIR/planner-artifacts.sh"

# Source ticket-dir.sh for resolve_ticket_dir — check multiple locations
if [ -f "$SCRIPT_DIR/ticket-dir.sh" ]; then
  source "$SCRIPT_DIR/ticket-dir.sh"
elif [ -f "$LIB_DIR/ticket-dir.sh" ]; then
  source "$LIB_DIR/ticket-dir.sh"
fi

usage() {
  echo "Usage: $0 <TICKET-ID> <LOG-FILE> <HB-LOG-FILE> --mode <entry|reapprove>" >&2
  exit 1
}

# ── Resolve flow.sh path dynamically ───────────────────────────────────────────
_resolve_flow_sh() {
  if [ -f "$HOME/.claude/skills/ticket-flow/flow.sh" ]; then
    echo "$HOME/.claude/skills/ticket-flow/flow.sh"
  elif command -v find &>/dev/null; then
    find "$HOME/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-flow/*" 2>/dev/null | head -1 || true
  fi
}

FLOW_SH=$(_resolve_flow_sh)

# ── Helpers ────────────────────────────────────────────────────────────────────

# Extract artifact path from pipeline log
# Checks META|artifact|info|plan: first, falls back to EXEC|create-artifact|done|
_get_artifact_path() {
  local artifact_path
  # Prefer explicit META|artifact entry
  artifact_path=$(grep '^[^|]*|META|artifact|info|plan:' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- | sed 's/^plan://' || true)
  if [ -z "$artifact_path" ]; then
    # Fall back to EXEC|create-artifact|done| line — the value field there may
    # be a type like "simple-fix", not a path.  Resolve it relative to the
    # ticket directory.
    local artifact_type td
    artifact_type=$(grep '^[^|]*|EXEC|create-artifact|done|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)
    if [ -n "$artifact_type" ] && command -v resolve_ticket_dir &>/dev/null; then
      td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)
      [ -n "$td" ] && artifact_path="$td/${artifact_type}.md"
    fi
  fi
  echo "$artifact_path"
}

# Extract AUTONOMY from pipeline log (defaults to manual)
_get_autonomy() {
  local autonomy
  autonomy=$(grep '^[^|]*|META|autonomy|info|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)
  echo "${autonomy:-manual}"
}

# Extract COMPLEXITY — uses get_complexity from notes-parse.sh which reads notes.md
# from the ticket directory. We resolve the ticket dir via ticket-dir.sh or fallback.
_get_complexity() {
  local td complexity
  if command -v resolve_ticket_dir &>/dev/null; then
    td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)
  fi
  if [ -z "$td" ]; then
    # Fallback: check PWD notes.md
    td="."
  fi
  complexity=$(get_complexity "$td" 2>/dev/null || true)
  echo "${complexity:-simple}"
}

# Determine artifact type from the pipeline log EXEC|create-artifact|done| line
_get_artifact_type() {
  local artifact_line atype
  artifact_line=$(grep '^[^|]*|EXEC|create-artifact|done|' "$LOG_FILE" 2>/dev/null | tail -1 || true)
  if echo "$artifact_line" | grep -q 'openspec'; then
    atype="openspec"
  elif echo "$artifact_line" | grep -q 'simple-fix'; then
    atype="simple-fix"
  else
    atype="simple-fix"
  fi
  echo "$atype"
}

# Fetch an issue for gate/label evaluation and fail closed on an unreadable
# payload (issue #362, LINEAR_GET_ISSUE_NULL_CONTINUES). Never substitutes a
# 'null' placeholder for a failed fetch — a missing/malformed payload is
# never silently absorbed into an ambiguous "no labels" state a jq `?`/`//`
# guard could produce.
#
# Usage: _gate_fetch_issue <ticket-id> [hb-gate-context]
# Echoes the validated issue JSON and returns 0 on success. On failure,
# delegates to _gate_fetch_issue_fail (tracker-read-failure-policy) and
# propagates its return code — the caller must `|| return $?` immediately so
# a retryable hold (1) and a structural gate-stop (2) both surface correctly.
# [hb-gate-context] defaults to "entry-gate"; pass "reapprove-gate" from
# _gate_reapprove so a fetch failure there is never conflated with a real
# APPROVAL_REVOKED verdict.
_gate_fetch_issue() {
  local ticket_id="$1"
  local hb_ctx="${2:-entry-gate}"
  local issue_json
  if ! issue_json=$(get_issue "$ticket_id" 2>/dev/null); then
    # _gate_fetch_issue_fail always returns non-zero (1=hold, 2=gate-stop);
    # the `||` is load-bearing under this file's `set -e` — without it, the
    # helper's own non-zero return would abort the script before the
    # `return $?` below ever ran.
    _gate_fetch_issue_fail "$ticket_id" "$hb_ctx" "get_issue($ticket_id) failed (see stderr/heartbeat for detail)" || return $?
  fi
  if ! require_issue_payload "$issue_json" 2>/dev/null; then
    _gate_fetch_issue_fail "$ticket_id" "$hb_ctx" "get_issue($ticket_id) returned an unparseable/incomplete payload" "malformed_payload" || return $?
  fi
  echo "$issue_json"
  return 0
}

# _gate_fetch_issue's failure handling (tracker-read-failure-policy section
# 6). entry-gate context gets a retryable hold: it writes the same "held: "
# shape every other entry-gate hold uses (complex ticket, manual mode, ...),
# so it rides the existing hold infrastructure verbatim — fleetd's
# gate_hold.py reconciler already re-runs `gate-check.sh --mode entry` on its
# own cadence for any held ticket, and detect-resume.sh's GATE_HELD handling
# already resumes a held ticket once the approved label appears — with zero
# new code in either. It gate-stops only after GATE_FETCH_MAX_ATTEMPTS (3,
# matching the verify/PR-iterate/reconcile caps) consecutive failures.
#
# reapprove-gate context still gate-stops immediately, unchanged from
# before this section. A "held: " line looks identical, in the log's
# PHASE/STEP fields, whether it came from entry or reapprove context — only
# the message text differs — and detect-resume.sh's GATE_HELD resume logic
# (which checks for the approved label, an entry-gate-only condition, and
# resumes to STEP_3_5, entry-gate's own reconcile step) has no way to route
# a resumed reapprove-context hold back into the PR-review loop it actually
# came from. Giving reapprove-context fetch failures the same retry
# machinery would need that routing built first; until then, an immediate,
# correctly-attributed (never APPROVAL_REVOKED) gate-stop is the safe
# choice (design task 6.11).
_gate_fetch_issue_fail() {
  local ticket_id="$1" hb_ctx="$2" detail="$3" reason="${4:-}"

  if [ "$hb_ctx" != "entry-gate" ]; then
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "LINEAR_FETCH_FAILED — ${detail}"
    hb_gate "$hb_ctx" "fail" "LINEAR_FETCH_FAILED" "{\"ticket\":\"$ticket_id\"${reason:+,\"reason\":\"$reason\"}}"
    return 2
  fi

  local max_attempts="${GATE_FETCH_MAX_ATTEMPTS:-3}"
  local prior_attempts attempt
  prior_attempts=$(grep -c '|META|gate-fetch-fail|fail|' "$LOG_FILE" 2>/dev/null || true)
  attempt=$((${prior_attempts:-0} + 1))

  _plog "$LOG_FILE" "META" "gate-fetch-fail" "fail" "attempt=${attempt}/${max_attempts} ticket=${ticket_id} ${detail}"

  if [ "$attempt" -ge "$max_attempts" ]; then
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "LINEAR_FETCH_FAILED — ${detail} (attempt ${attempt}/${max_attempts}, retries exhausted)"
    hb_gate "$hb_ctx" "fail" "LINEAR_FETCH_FAILED" "{\"ticket\":\"$ticket_id\",\"attempt\":$attempt,\"max\":$max_attempts}"
    return 2
  fi

  _plog "$LOG_FILE" "GATE" "gate" "fail" "held: linear fetch failed (attempt ${attempt}/${max_attempts}) — ${detail}"
  hb_gate "$hb_ctx" "fail" "held: linear fetch failed" "{\"ticket\":\"$ticket_id\",\"attempt\":$attempt,\"max\":$max_attempts}"
  _gate_emit_held "linear-fetch-failed"
  return 1
}

# ── Mode: entry ────────────────────────────────────────────────────────────────

_gate_entry() {
  # Write gate start event
  _plog "$LOG_FILE" "GATE" "gate" "start" ""

  local artifact_path complexity autonomy artifact_type
  artifact_path=$(_get_artifact_path)
  complexity=$(_get_complexity)
  autonomy=$(_get_autonomy)
  artifact_type=$(_get_artifact_type)

  # Commercial Evidence MVP (Branch B): single canonical writer for
  # META|complexity, guarded to fire once per ticket — present on both the
  # standard route (this function) and the planned-ticket fast-path, which
  # also flows through _gate_entry.
  if ! grep -q '|META|complexity|info|' "$LOG_FILE" 2>/dev/null; then
    _plog "$LOG_FILE" "META" "complexity" "info" "$complexity"
  fi

  # Check 1: Artifact file existence (accepts files and openspec directories)
  if [ -n "$artifact_path" ] && [ ! -f "$artifact_path" ] && [ ! -d "$artifact_path" ]; then
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "EXEC_NO_ARTIFACT"
    hb_gate "entry-gate" "fail" "artifact missing" "{\"path\":\"$artifact_path\"}"
    return 2
  fi

  # Check 2: Complexity-artifact coherence
  # Normalize both values to canonical forms before comparison:
  #   simple / simple-fix → "simple"
  #   complex / openspec  → "complex"
  # This prevents false positives when complexity="simple" and artifact="simple-fix"
  # (they are equivalent) and catches the reverse mismatch (simple + openspec).
  local _norm_complexity _norm_artifact
  case "$complexity" in
  simple | simple-fix) _norm_complexity="simple" ;;
  complex | openspec) _norm_complexity="complex" ;;
  *) _norm_complexity="$complexity" ;;
  esac
  case "$artifact_type" in
  simple-fix | simple) _norm_artifact="simple" ;;
  openspec | complex) _norm_artifact="complex" ;;
  *) _norm_artifact="$artifact_type" ;;
  esac
  if [ "$_norm_complexity" != "$_norm_artifact" ]; then
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "COMPLEXITY_ARTIFACT_MISMATCH — complexity=$complexity (normalized=$_norm_complexity) artifact=$artifact_type (normalized=$_norm_artifact)"
    hb_gate "entry-gate" "fail" "complexity-artifact mismatch" "{\"complexity\":\"$complexity\",\"normalized_complexity\":\"$_norm_complexity\",\"artifact\":\"$artifact_type\",\"normalized_artifact\":\"$_norm_artifact\"}"
    return 2
  fi

  # Check 2.5: Content quality score (from critique in notes.md)
  # Distinguish: critique never ran (section absent → skip, backward compat) vs.
  #              critique ran but failed (section present but no score → gate-stop)
  local critique_score critique_status td has_critique
  if command -v resolve_ticket_dir &>/dev/null; then
    td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)
  fi
  if [ -z "$td" ]; then
    td="."
  fi
  critique_score=$(get_critique_score "$td" 2>/dev/null || true)
  critique_status=$(get_critique_status "$td" 2>/dev/null || true)
  # Check whether the Readiness Critique section exists at all
  if [ -f "$td/notes.md" ] && grep -q '## Readiness Critique' "$td/notes.md" 2>/dev/null; then
    has_critique="true"
  else
    has_critique="false"
  fi

  if [ "${has_critique}" = "true" ] && [ -z "$critique_score" ]; then
    # Critique ran but produced no score — structural failure, do not proceed
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "CRITIQUE_SCORE_MISSING — ## Readiness Critique exists but **Score:** absent or unparseable"
    hb_gate "entry-gate" "fail" "critique score missing" "{\"has_critique\":\"true\"}"
    return 2
  fi

  if [ -n "$critique_score" ]; then
    # BLOCKED status is a hard stop
    if [ "$critique_status" = "BLOCKED" ]; then
      _plog "$LOG_FILE" "META" "gate-stop" "fail" "CRITIQUE_BLOCKED"
      hb_gate "entry-gate" "fail" "critique blocked" "{\"score\":\"$critique_score\",\"status\":\"$critique_status\"}"
      return 2
    fi

    # Score below 40 holds the ticket — validate integer before comparison
    if [[ "$critique_score" =~ ^[0-9]+$ ]] && [ "$critique_score" -lt 40 ]; then
      _plog "$LOG_FILE" "GATE" "gate" "fail" "held: content quality score $critique_score < 40"
      hb_gate "entry-gate" "fail" "held: content quality score below threshold" "{\"score\":\"$critique_score\",\"threshold\":40}"
      _gate_emit_held "critique-score-below-threshold"
      return 1
    fi

    # Score plausibility cross-check: if BLOCKERs exist, score must be ≤ 70
    # Each BLOCKER deducts at least 30 (0 AC) or 20 (no test user) or 25 (no bug repro)
    # Worst case for 1 BLOCKER = -30 → max 70. For 2 BLOCKERs = max 50.
    local critique_blocker_count
    critique_blocker_count=$(get_critique_blocker_count "$td" 2>/dev/null || echo "0")
    if [[ "$critique_blocker_count" =~ ^[0-9]+$ ]] && [[ "$critique_score" =~ ^[0-9]+$ ]]; then
      local max_score=$((100 - (critique_blocker_count * 25)))
      [ "$max_score" -lt 40 ] && max_score=40 # floor at 40 — below this is already caught
      if [ "$critique_blocker_count" -ge 2 ] && [ "$critique_score" -gt 50 ]; then
        _plog "$LOG_FILE" "META" "gate-stop" "fail" "CRITIQUE_SCORE_IMPLAUSIBLE — score $critique_score with $critique_blocker_count BLOCKERs (max plausible: 50)"
        hb_gate "entry-gate" "fail" "critique score implausible" "{\"score\":\"$critique_score\",\"blockers\":\"$critique_blocker_count\",\"max_plausible\":50}"
        return 2
      elif [ "$critique_blocker_count" -ge 1 ] && [ "$critique_score" -gt 70 ]; then
        _plog "$LOG_FILE" "META" "gate-stop" "fail" "CRITIQUE_SCORE_IMPLAUSIBLE — score $critique_score with $critique_blocker_count BLOCKER(s) (max plausible: 70)"
        hb_gate "entry-gate" "fail" "critique score implausible" "{\"score\":\"$critique_score\",\"blockers\":\"$critique_blocker_count\",\"max_plausible\":70}"
        return 2
      fi
    fi
  fi

  # Check 2.5a: Zero-AC structural gate
  # A ticket with zero acceptance criteria has nothing to verify — hard stop.
  # Runs even without critique (reads context.md directly).
  # When ac_count resolves empty (context.md missing or unreadable), default to
  # blocking — a missing context.md is not a signal that ACs exist. This prevents
  # the ZERO_AC→auto-approve inconsistency where the gate blocks on attempts 1-2
  # but auto-approves on attempt 3 when context.md resolution silently fails.
  local ac_count
  ac_count=$(get_ac_count "$td" 2>/dev/null || echo "")
  if [ -z "$ac_count" ]; then
    # context.md missing or unreadable — can't determine AC count
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "ZERO_AC — unable to determine acceptance criteria count (context.md missing or unreadable)"
    hb_gate "entry-gate" "fail" "zero acceptance criteria — count unresolvable" "{\"ac_count\":\"unresolvable\"}"
    return 2
  fi
  if [ "$ac_count" = "0" ]; then
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "ZERO_AC — ticket has zero acceptance criteria; nothing verifiable exists"
    hb_gate "entry-gate" "fail" "zero acceptance criteria" "{\"ac_count\":\"0\"}"
    return 2
  fi

  # Check 2.5b: Bug repro structural gate
  # A bug ticket without reproduction steps cannot be verified — hard stop.
  # Reproductions steps cannot be derived by the LLM; they must come from the ticket.
  local ticket_type has_repro
  ticket_type=$(get_ticket_type "$td" 2>/dev/null || echo "feature")
  if [ "$ticket_type" = "bug" ]; then
    has_repro=$(get_has_repro_steps "$td" 2>/dev/null || echo "false")
    if [ "$has_repro" = "false" ]; then
      _plog "$LOG_FILE" "META" "gate-stop" "fail" "BUG_NO_REPRO — bug ticket has no reproduction steps; verifier cannot reproduce the issue"
      hb_gate "entry-gate" "fail" "bug without repro steps" "{\"ticket_type\":\"bug\"}"
      return 2
    fi
  fi

  # Save ticket directory before Check 2.6 overwrites it — cross-validation needs the
  # original td (ticket workspace) to read notes.md, not the artifact scan target.
  local gate_td="${td:-.}"

  # Check 2.6: Verification readiness — check plan artifact for all 4 prerequisites
  # Verification prerequisites are independent of critique readiness. Check them
  # whenever we have an artifact, regardless of whether a critique has run yet.
  if [ -n "$artifact_path" ] && { [ -f "$artifact_path" ] || [ -d "$artifact_path" ]; }; then
    local has_test_user has_nav_path has_expected_behavior has_env_prereqs role_pattern missing_count
    # Build role pattern from test-users.json catalog if available, fall back to known roles
    role_pattern=$(jq -r '[.[].roles[]] | unique | join("|")' "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills}/config/test-users.json" 2>/dev/null | sed 's/_/[-_]/g' || echo 'attorney|admin|debtor|collection[-_]?agency|correspondent')
    # Primary: check the derived verification plan in notes.md when present
    local notes_path vplan_section
    notes_path="$gate_td/notes.md"
    vplan_section=""

    if [ -f "$notes_path" ] && grep -q '## Verification Plan' "$notes_path" 2>/dev/null; then
      # Extract the per-criterion table between "### Per-Criterion Verification" and the next ## heading
      vplan_section=$(awk '/^### Per-Criterion Verification$/,/^## /' "$notes_path" 2>/dev/null || true)
      if [ -n "$vplan_section" ]; then
        # Check the Verifiable column for ✓ or Y entries. If at least one criterion
        # is marked verifiable, the plan has enough info. If none are marked, all 4
        # prereqs are effectively missing (fallback triggers).
        local verifiable_count
        verifiable_count=$(echo "$vplan_section" | grep -ciP '[✓Y]' 2>/dev/null || true)
        if [ "${verifiable_count:-0}" -gt 0 ] 2>/dev/null; then
          # At least one criterion is fully verifiable — all 4 prereqs are present
          # for that criterion. Mark all as found.
          has_test_user=1
          has_nav_path=1
          has_expected_behavior=1
          has_env_prereqs=1
        else
          # No criteria are verifiable — plan is incomplete
          has_test_user=0
          has_nav_path=0
          has_expected_behavior=0
          has_env_prereqs=0
        fi
      fi
    fi

    # Save pre-fallback values for cross-validation: the plan's own data
    # (not artifact fallback) determines whether critique gaps were truly resolved.
    local plan_has_test_user="${has_test_user:-0}"
    local plan_has_nav_path="${has_nav_path:-0}"
    local plan_has_expected="${has_expected_behavior:-0}"
    local plan_has_env="${has_env_prereqs:-0}"

    # Fallback: scan the plan artifact directly when:
    # - no verification plan section exists, OR
    # - any prerequisite grep returned 0 (grep may have missed data the LLM wrote)
    if [ -z "$vplan_section" ] || [ "${has_test_user:-0}" = "0" ] || [ "${has_nav_path:-0}" = "0" ] || [ "${has_expected_behavior:-0}" = "0" ] || [ "${has_env_prereqs:-0}" = "0" ]; then
      # grep -c outputs "0" on no match (and exits 1) — use || true to suppress exit code
      # Tightened patterns (v2): require context proximity, not just substring match.
      # Test user: require actual user identification — email, **User:** field with content,
      # or explicit role with a named role (not just "log in as" alone).
      has_test_user=$(grep -ciP '(\*\*User:\*\*\s*\S|email[:\s]*\S+@\S+\.\S+|log in as \S|test as \S|role[:\s]*('"$role_pattern"'))' "$artifact_path" 2>/dev/null || true)
      # Navigation target: require URL path near a navigation verb (same line), OR
      # explicit menu path with bracket notation, OR "navigate to" / "go to" with a target.
      has_nav_path=$(grep -ciP '((navigate|go to|open|visit|click).{0,60}(/(handover|admin|user-permission|organisation|portfolio)/)|(/(handover|admin|user-permission|organisation|portfolio)/).{0,60}(navigate|go to|open|visit|click)|menu path.{0,30}\[|navigate to \S|go to \S)' "$artifact_path" 2>/dev/null || true)
      # Expected behavior: remove bare "should " (matches every implementation instruction).
      # Require AC context: acceptance criteria headings, numbered ACs with should/must,
      # expected behavior sections, or verify/pass criterion phrasing.
      has_expected_behavior=$(grep -ciP '(acceptance criteria|expected (behavi|result|outcome)|^\s*\d+[\.\)]\s.*(should |must )|verify that|pass criter|##\s*(Expected|Acceptance|Verification Plan)|AC[-:]\s|###\s*(Acceptance|Expected))' "$artifact_path" 2>/dev/null || true)
      # Environment prerequisites: remove bare "setup" (matches "setup the project").
      # Require data/test context: seed data, test data setup, migrations, fixtures,
      # or "setup" qualified by "data"/"test"/"seed" within 3 words.
      has_env_prereqs=$(grep -ciP '(seed[- ]?data|(test|data|environment|seed)\s+\w+\s+setup|setup\s+(test|data|seed)\s|prerequisite|before (testing|running)|database|migration|service.{0,10}start|data\.sql|fixture|test data)' "$artifact_path" 2>/dev/null || true)
    fi

    # Count missing prerequisites, adjusted for ticket type.
    # API-only tickets (no browser nav patterns in artifact, no test user refs)
    # only require expected_behavior + env_prereqs. Browser tickets require all 4.
    # Build-only tickets (no UI, no API — pure compile/build verification, e.g.
    # parent-POM/dependency-management changes) only require a concrete build/
    # verify command + a stated success outcome — the browser/API prerequisites
    # (test user, nav path) are meaningless for them and would always false-hold.
    # Detection precedence: browser signals present → browser; else build-tool
    # signals present → build-only; else → api-only (existing fallback).
    local _ticket_mode="browser" _required_count has_build_command has_build_outcome
    has_build_command=0
    has_build_outcome=0
    if [ "${has_nav_path:-0}" = "0" ] && [ "${has_test_user:-0}" = "0" ]; then
      # Neither nav paths nor test users found in artifact — check for browser
      # signals. "open" alone is too weak (matches "open question", "open a PR")
      # so it's scoped to an actual UI object.
      local _browser_signals _build_signals
      _browser_signals=$(grep -ciP '(navigate|go to|open(s|ed|ing)?\s+(the\s+)?(page|browser|url|dialog|modal|menu|tab|app)\b|visit|click|browser|playwright|page\.|selector|screenshot|viewport)' "$artifact_path" 2>/dev/null || true)
      if [ "${_browser_signals//[^0-9]/}" = "0" ] 2>/dev/null; then
        _build_signals=$(grep -ciP '(\bmvn\b|\bgradle\b|\bnpm run\b|\bmake\b|pom\.xml|build\.gradle|clean compile|clean install|clean package|BUILD SUCCESS)' "$artifact_path" 2>/dev/null || true)
        if [ "${_build_signals//[^0-9]/}" != "0" ] 2>/dev/null; then
          _ticket_mode="build-only"
        else
          _ticket_mode="api-only"
        fi
      fi
    elif [ "${has_nav_path:-0}" = "0" ]; then
      # has_nav_path=0 but has_test_user=1 (the only other way to reach this
      # branch) — a ticket can have a genuine test user (e.g. an API-auth smoke
      # test) while its only navigation targets are infra dashboards/registries
      # (Eureka, Zipkin, a bare host:port) that has_nav_path's regex never
      # recognizes. Left unhandled, _ticket_mode falls through to its "browser"
      # default and the cross-validation block below false-holds on nav_gap no
      # matter how the plan phrases its navigation targets.
      # A bare localhost:PORT/127.0.0.1:PORT mention is NOT sufficient on its own to
      # signal infra: this project's own convention (LOCAL_URL in CLAUDE.md) is almost
      # always a bare localhost:PORT value, and it's routine for a plan's Setup/
      # Environment line to state it separately from the step-by-step nav instructions.
      # Two-step check: a named infra keyword (Eureka/Zipkin/actuator/registry/
      # discovery/config-server) must be present somewhere in the artifact for
      # infra-only reclassification — a bare host:port mention with no named infra
      # term anywhere in the artifact never triggers it on its own.
      local _feature_path_signals _infra_named_signals
      _feature_path_signals=$(grep -ciP '/(handover|admin|user-permission|organisation|portfolio)/' "$artifact_path" 2>/dev/null || true)
      _infra_named_signals=$(grep -ciP '(eureka|zipkin|actuator|config[- ]server|service registry|discovery server)' "$artifact_path" 2>/dev/null || true)
      if [ "${_feature_path_signals//[^0-9]/}" = "0" ] 2>/dev/null && [ "${_infra_named_signals//[^0-9]/}" != "0" ] 2>/dev/null; then
        _ticket_mode="infra-only"
      fi
    fi

    missing_count=0
    case "$_ticket_mode" in
    infra-only)
      # Infra-only: dashboards/registries with no feature-path UI to navigate.
      # Same shape as api-only (expected behavior + env prereqs only) — and,
      # since this moves _ticket_mode away from "browser", it also prevents the
      # nav_gap cross-validation false-hold at the block below (gated on
      # `_ticket_mode = "browser"`).
      _required_count=2
      [ "$has_expected_behavior" = "0" ] && missing_count=$((missing_count + 1))
      [ "$has_env_prereqs" = "0" ] && missing_count=$((missing_count + 1))
      ;;
    build-only)
      # Build-only: require a concrete build/verify command plus a stated
      # success outcome, in place of browser/API-shaped prerequisites that
      # don't apply to a no-UI, no-API ticket.
      _required_count=2
      has_build_command=$(grep -ciP '(\bmvn\b\s|\bgradle\b|\bnpm run\b|\bmake\b\s|clean compile|clean install|clean package|clean test|\bCI run\b|\bworkflow run\b|feature-branch push)' "$artifact_path" 2>/dev/null || true)
      has_build_outcome=$(grep -ciP '(BUILD SUCCESS|succeeds?\b|compiles?\s+(successfully|cleanly)|passes?\b|no (compile|build) error|exit code 0|green build|runs? successfully|legs? (are )?green)' "$artifact_path" 2>/dev/null || true)
      [ "${has_build_command:-0}" = "0" ] && missing_count=$((missing_count + 1))
      [ "${has_build_outcome:-0}" = "0" ] && missing_count=$((missing_count + 1))
      ;;
    api-only)
      # API-only: skip browser-specific prerequisites
      _required_count=2
      [ "$has_expected_behavior" = "0" ] && missing_count=$((missing_count + 1))
      [ "$has_env_prereqs" = "0" ] && missing_count=$((missing_count + 1))
      ;;
    *)
      # Browser: all 4 required
      _required_count=4
      [ "$has_test_user" = "0" ] && missing_count=$((missing_count + 1))
      [ "$has_nav_path" = "0" ] && missing_count=$((missing_count + 1))
      [ "$has_expected_behavior" = "0" ] && missing_count=$((missing_count + 1))
      [ "$has_env_prereqs" = "0" ] && missing_count=$((missing_count + 1))
      ;;
    esac

    # Hold if 2+ missing for browser tickets, or any missing for API-only/
    # build-only (INCOMPLETE threshold from appraise-exec Step 3.8).
    # Only enforce when a verification plan was attempted (plan section exists)
    # or a critique has been run (indicating the plan SHOULD exist). Tickets
    # without either are pre-verification-plan and the hold would be a false
    # positive — skip enforcement for them.
    if [ -n "$vplan_section" ] || [ -n "$critique_score" ]; then
      local _hold_threshold=2
      [ "$_ticket_mode" != "browser" ] && _hold_threshold=1
      if [ "$missing_count" -ge "$_hold_threshold" ] 2>/dev/null; then
        if [ "$_ticket_mode" = "build-only" ]; then
          _plog "$LOG_FILE" "GATE" "gate" "fail" "held: plan missing $missing_count/${_required_count} verification prerequisites (mode=$_ticket_mode build_command=$has_build_command build_outcome=$has_build_outcome)"
          hb_gate "entry-gate" "fail" "held: plan missing verification prerequisites" "{\"artifact\":\"$artifact_path\",\"missing\":\"$missing_count\",\"required\":\"$_required_count\",\"mode\":\"$_ticket_mode\",\"build_command\":\"$has_build_command\",\"build_outcome\":\"$has_build_outcome\"}"
          _gate_emit_held "verification-prerequisites-missing"
        else
          _plog "$LOG_FILE" "GATE" "gate" "fail" "held: plan missing $missing_count/${_required_count} verification prerequisites (mode=$_ticket_mode test_user=$has_test_user nav=$has_nav_path expected=$has_expected_behavior env=$has_env_prereqs)"
          hb_gate "entry-gate" "fail" "held: plan missing verification prerequisites" "{\"artifact\":\"$artifact_path\",\"missing\":\"$missing_count\",\"required\":\"$_required_count\",\"mode\":\"$_ticket_mode\",\"test_user\":\"$has_test_user\",\"nav\":\"$has_nav_path\",\"expected\":\"$has_expected_behavior\",\"env\":\"$has_env_prereqs\"}"
          _gate_emit_held "verification-prerequisites-missing"
        fi
        return 1
      fi
    fi # vplan_section || critique_score guard

    # Cross-validation: if critique flagged specific gaps, verify the PLAN resolved them.
    # Uses pre-fallback plan_has_* values — the verification plan must resolve critique
    # gaps with its own data. Artifact fallback data doesn't count (it wasn't derived).
    # A critique BLOCKER that's still unaddressed in the plan means the LLM couldn't
    # derive the missing info from code/nav-hints/app-knowledge either → hold.
    # Uses gate_td (ticket workspace) — td was reassigned in Check 2.6.
    # NOTE: bare ((x++)) exits 1 when x=0 (post-increment evaluates as falsy),
    # triggering set -e. Use || true or $((x+1)) to avoid this.
    # Browser-only: nav_path/test_user gaps are meaningless for build-only/api-only
    # tickets (no UI exists to navigate, no test user to log in as) — mirrors the
    # mode-aware missing_count check above. Without this guard, a critique correctly
    # flagging "no navigation path" on a build-only ticket held it forever, since the
    # plan can never supply a navigation path that doesn't exist.
    if [ "$_ticket_mode" = "browser" ]; then
      local critique_nav_gap critique_user_gap critique_repro_gap cross_failures
      cross_failures=0
      if get_critique_has_finding "$gate_td" 'No navigation path' 2>/dev/null; then
        critique_nav_gap="true"
        if [ "${plan_has_nav_path:-0}" = "0" ]; then
          cross_failures=$((cross_failures + 1))
        fi
      fi
      if get_critique_has_finding "$gate_td" 'No test user' 2>/dev/null; then
        critique_user_gap="true"
        if [ "${plan_has_test_user:-0}" = "0" ]; then
          cross_failures=$((cross_failures + 1))
        fi
      fi
      # Repro steps are special: they can't be derived by the LLM. If the critique flagged
      # no repro steps, the ticket author must provide them — no plan can compensate.
      if get_critique_has_finding "$gate_td" 'Bug without repro steps' 2>/dev/null; then
        critique_repro_gap="true"
        cross_failures=$((cross_failures + 1))
      fi

      if [ "$cross_failures" -ge 1 ] 2>/dev/null; then
        _plog "$LOG_FILE" "GATE" "gate" "fail" "held: critique-plan cross-validation failed — $cross_failures critique gap(s) still unaddressed (nav_gap=${critique_nav_gap:-false} user_gap=${critique_user_gap:-false} repro_gap=${critique_repro_gap:-false})"
        hb_gate "entry-gate" "fail" "held: critique-plan cross-validation failed" "{\"nav_gap\":\"${critique_nav_gap:-false}\",\"user_gap\":\"${critique_user_gap:-false}\",\"repro_gap\":\"${critique_repro_gap:-false}\",\"cross_failures\":\"$cross_failures\"}"
        _gate_emit_held "critique-cross-validation-failed"
        return 1
      fi
    fi
  fi

  # Check 2.7: Planned ticket validation (template + body completeness)
  # For planned-labeled tickets, validates:
  #   1. Planner Context block is well-formed (passive, observe-only)
  #   2. Type label resolves to a known template (active gate-stop)
  #   3. Body has all required sections for the type (active gate-stop)
  # Phase 2 (appraise-fast-path) runs independently in ticket-appraise Step 1.3
  # via check_fast_path_eligible, which re-validates the Planner Context block
  # and routes to fast-path or full investigation based on the result.
  local issue_json planned_check_rc
  issue_json=$(_gate_fetch_issue "$TICKET_ID") || return $?
  # tracker-local-facts-read-migration (task 5.1): a local ticket manifest is
  # authoritative proof this is a planned ticket — skip the live label read
  # when one exists. Falls back to the live label exactly as before when no
  # manifest exists (predates this migration, or the write failed). The
  # description is still needed regardless for 2.7a/2.7c's field-level
  # validation, so this only narrows what decides the boolean gate, not
  # what's fetched.
  local has_planned_label
  if declare -f ticket_manifest_exists >/dev/null 2>&1 && ticket_manifest_exists "$TICKET_ID" 2>/dev/null; then
    has_planned_label="true"
  else
    has_planned_label=$(echo "$issue_json" | jq -r '[.labels.nodes[].name] | index("planned") != null' 2>/dev/null || echo 'false')
  fi
  if [ "$has_planned_label" = "true" ]; then
    local planned_desc label_names
    planned_desc=$(echo "$issue_json" | jq -r '.description // ""')
    label_names=$(echo "$issue_json" | jq -r '[.labels.nodes[].name] | join(",")' 2>/dev/null || echo '')

    # 2.7a: Passive Planner Context block validation (existing behavior)
    check_planned_ticket_description "$planned_desc" 2>/dev/null || planned_check_rc=$?
    case "${planned_check_rc:-0}" in
    0) _plog "$LOG_FILE" "GATE" "planned-check" "done" "valid" ;;
    1) _plog "$LOG_FILE" "GATE" "planned-check" "warn" "malformed — Planner Context block missing or invalid" ;;
    2) _plog "$LOG_FILE" "GATE" "planned-check" "warn" "low-confidence — confidence below threshold, not pre-approved" ;;
    esac
    hb_gate "planned-check" "info" "planned ticket validated" "{\"exit_code\":\"${planned_check_rc:-0}\",\"result\":\"$CHECK_RESULT\"}"

    # 2.7b: Resolve Type label → template (active gate-stop)
    # tracker-local-facts-read-migration (task 5.12): manifest's type field
    # first, live label resolution as fallback.
    local ticket_type=""
    if declare -f get_ticket_manifest_field >/dev/null 2>&1 && ticket_manifest_exists "$TICKET_ID" 2>/dev/null; then
      ticket_type=$(get_ticket_manifest_field "$TICKET_ID" type 2>/dev/null)
    fi
    [ -n "$ticket_type" ] || ticket_type=$(_resolve_type_label "$label_names")
    local template_path
    template_path=$(resolve_template "$ticket_type" 2>/dev/null) || true
    local template_rc=$?
    if [ "$template_rc" = "3" ] || [ -z "$template_path" ]; then
      local display_type="${ticket_type:-<none>}"
      _plog "$LOG_FILE" "META" "gate-stop" "fail" "NO_TEMPLATE_FOR_TYPE — no template for task type '$display_type'; add templates/${display_type}.md"
      hb_gate "entry-gate" "fail" "NO_TEMPLATE_FOR_TYPE" "{\"type\":\"$display_type\"}"
      return 2
    fi
    _plog "$LOG_FILE" "GATE" "planned-check" "done" "template resolved: $template_path"

    # 2.7c: Body completeness check (active gate-stop)
    local body_check_rc=0
    check_planned_body "$TICKET_ID" "$ticket_type" "$planned_desc" "true" 2>/dev/null || body_check_rc=$?
    if [ "$body_check_rc" != "0" ]; then
      local missing_sections="${BODY_CHECK_MISSING:-unknown}"
      _plog "$LOG_FILE" "META" "gate-stop" "fail" "PLANNED_BODY_INCOMPLETE — $ticket_type ticket missing $missing_sections"
      hb_gate "entry-gate" "fail" "PLANNED_BODY_INCOMPLETE" "{\"type\":\"$ticket_type\",\"missing\":\"$missing_sections\"}"
      return 2
    fi
    _plog "$LOG_FILE" "GATE" "planned-check" "done" "body complete for type $ticket_type"

    # 2.7d: Exploration depth mismatch detection (soft signal, never blocks)
    local exploration_depth
    exploration_depth=$(echo "$planned_desc" | sed -n '/## Planner Context/,/^## /p' | grep -i '^\*\*Exploration Depth:\*\*' | head -1 | sed 's/.*\*\*Exploration Depth:\*\*\s*//' || true)
    if [ -n "$exploration_depth" ]; then
      local affected_services_str svc_count
      affected_services_str=$(echo "$planned_desc" | sed -n '/## Planner Context/,/^## /p' | grep -i '^\*\*Affected Services:\*\*' | head -1 | sed 's/.*\*\*Affected Services:\*\*\s*//' || true)
      svc_count=$(echo "$affected_services_str" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -cv '^$' || echo 1)
      local mismatch_rc=0
      check_exploration_depth_mismatch "$exploration_depth" "$complexity" "$svc_count" 2>/dev/null || mismatch_rc=$?
      if [ "$mismatch_rc" = "1" ]; then
        _plog "$LOG_FILE" "GATE" "planned-check" "warn" "exploration depth mismatch: depth=$exploration_depth complexity=$complexity services=$svc_count"
        hb_gate "planned-check" "warn" "exploration depth mismatch" "{\"depth\":\"$exploration_depth\",\"complexity\":\"$complexity\",\"services\":\"$svc_count\"}"
      fi
    fi
  fi

  # Check 2.8b: Complex + auto/semi-auto + approved → auto-approve.
  # tracker-approval-by-script: manifest is the sole approval decision read
  # — no tracker fetch, no fallback. In auto and semi-auto modes, a local
  # approval fact means the human has explicitly signaled approval via
  # /ticket-approve — don't hold complex tickets that have it. Only applies
  # to non-manual modes (manual has its own check at Check 4).
  if [ "$complexity" = "complex" ] && { [ "$autonomy" = "auto" ] || [ "$autonomy" = "semi-auto" ]; }; then
    local _c28b_verdict
    _c28b_verdict=$(_gate_manifest_approved "$TICKET_ID" "Ready")
    if [ "$_c28b_verdict" = "hold-missing-manifest" ]; then
      _plog "$LOG_FILE" "META" "manifest" "warn" "MANIFEST_MISSING — no local manifest for $TICKET_ID at approval check 2.8b"
    fi
    if [ "$_c28b_verdict" = "pass" ]; then
      _plog "$LOG_FILE" "GATE" "gate" "done" "auto-approved (complex + $autonomy + approved)"
      hb_gate "entry-gate" "ok" "complex auto-approved" "{\"complexity\":\"$complexity\",\"autonomy\":\"$autonomy\",\"approved\":true}"
      _write_gate_verdict PASS
      # Pass through to verify flow.sh's post-trigger assertion still holds
      return 0
    fi
  fi

  # Check 2.8c: Complex + manual + approved + staged → pass.
  # Mirrors 2.8b for manual autonomy. Without this, Check 3 below ("complex
  # tickets are always held") unconditionally intercepts every complex ticket
  # before Check 4 (manual mode's own approved+Ready override) ever runs —
  # Check 4's condition was unreachable for any complex ticket in manual mode,
  # contradicting 2.8b's own comment ("manual has its own check at Check 4").
  if [ "$complexity" = "complex" ] && [ "$autonomy" = "manual" ]; then
    local _c28c_verdict
    _c28c_verdict=$(_gate_manifest_approved "$TICKET_ID" "Ready")
    if [ "$_c28c_verdict" = "hold-missing-manifest" ]; then
      _plog "$LOG_FILE" "META" "manifest" "warn" "MANIFEST_MISSING — no local manifest for $TICKET_ID at approval check 2.8c"
    fi
    if [ "$_c28c_verdict" = "pass" ]; then
      _plog "$LOG_FILE" "GATE" "gate" "done" "manual mode overridden: approved + staged confirmed in local manifest (complex ticket)"
      hb_gate "entry-gate" "ok" "manual mode overridden by manifest approval (complex)" "{\"autonomy\":\"manual\",\"complexity\":\"complex\"}"
      _gate_emit_released "human"
      _write_gate_verdict PASS
      return 0
    fi
  fi

  # Check 3: Complex tickets are always held (unless bypassed above)
  if [ "$complexity" = "complex" ]; then
    _plog "$LOG_FILE" "GATE" "gate" "fail" "held: complex ticket"
    hb_gate "entry-gate" "fail" "held: complex ticket" "{\"complexity\":\"$complexity\"}"
    _gate_emit_held "complex-ticket"
    return 1
  fi

  # Check 4: Manual mode tickets are held UNLESS already approved locally.
  # If the manifest records approved=true and stage=Ready, the human has
  # already approved via /ticket-approve — override the local autonomy
  # setting and pass.
  if [ "$autonomy" = "manual" ]; then
    local _c4_verdict
    _c4_verdict=$(_gate_manifest_approved "$TICKET_ID" "Ready")
    if [ "$_c4_verdict" = "hold-missing-manifest" ]; then
      _plog "$LOG_FILE" "META" "manifest" "warn" "MANIFEST_MISSING — no local manifest for $TICKET_ID at approval check 4"
    fi
    if [ "$_c4_verdict" = "pass" ]; then
      _plog "$LOG_FILE" "GATE" "gate" "done" "manual mode overridden: approved + staged confirmed in local manifest"
      hb_gate "entry-gate" "ok" "manual mode overridden by manifest approval" "{\"autonomy\":\"manual\"}"
      _gate_emit_released "human"
      _write_gate_verdict PASS
      return 0
    fi
    _plog "$LOG_FILE" "GATE" "gate" "fail" "held: manual mode"
    hb_gate "entry-gate" "fail" "held: manual mode" "{\"autonomy\":\"$autonomy\"}"
    _gate_emit_held "manual-mode"
    return 1
  fi

  # Check 5: Simple + auto/semi-auto → auto-approve via flow.sh
  if [ "$complexity" = "simple" ] && { [ "$autonomy" = "auto" ] || [ "$autonomy" = "semi-auto" ]; }; then
    if [ -n "$FLOW_SH" ] && [ -f "$FLOW_SH" ]; then
      bash "$FLOW_SH" "$TICKET_ID" "human-approve" --provenance policy || true
    fi
    _plog "$LOG_FILE" "GATE" "gate" "done" "auto-approved"
    hb_gate "entry-gate" "ok" "auto-approved" "{\"complexity\":\"$complexity\",\"autonomy\":\"$autonomy\"}"
    _gate_emit_released "policy"
    _write_gate_verdict PASS
    return 0
  fi

  # Fallback: held (should not reach here given the checks above, but safety net)
  _plog "$LOG_FILE" "GATE" "gate" "fail" "held: default"
  hb_gate "entry-gate" "fail" "held: default fallback" "{}"
  _gate_emit_held "default-fallback"
  return 1
}

# ── Mode: reapprove ────────────────────────────────────────────────────────────

_gate_reapprove() {
  # tracker-approval-by-script: the manifest is the sole approval decision
  # read here too — no tracker fetch, so the LINEAR_FETCH_FAILED distinction
  # this comment used to describe (issue #362) no longer applies: there is
  # no fetch left to fail. APPROVAL_REVOKED (D6) keeps its name and
  # gate-stop semantics, now meaning "the manifest records no approval at
  # reapprove time" — reachable only via re-claim or /ticket-reject.
  local _reapprove_verdict
  _reapprove_verdict=$(_gate_manifest_approved "$TICKET_ID" "Ready")
  if [ "$_reapprove_verdict" = "hold-missing-manifest" ]; then
    _plog "$LOG_FILE" "META" "manifest" "warn" "MANIFEST_MISSING — no local manifest for $TICKET_ID at reapprove gate"
  fi

  # Count prior verification failures in the plan artifact (informational only)
  local artifact_path verify_count
  artifact_path=$(_get_artifact_path)
  if [ -n "$artifact_path" ] && [ -f "$artifact_path" ]; then
    verify_count=$(grep -c '^## Verification #' "$artifact_path" 2>/dev/null || echo "0")
    if [ "$verify_count" -gt 0 ] 2>/dev/null; then
      _plog "$LOG_FILE" "GATE" "reapprove" "info" "plan has $verify_count prior verification failure(s)"
    fi
  fi

  if [ "$_reapprove_verdict" = "pass" ]; then
    _plog "$LOG_FILE" "GATE" "reapprove" "done" ""
    hb_gate "reapprove-gate" "ok" "re-approval confirmed" "{\"prior_failures\":\"${verify_count:-0}\"}"
    # reapprove-mode is only ever entered because a human approved via
    # /ticket-approve on a previously-held ticket — no automatic
    # re-evaluation path exists in the current pipeline, so provenance is
    # always "human" here.
    _gate_emit_released "human"
    _write_gate_verdict PASS
    return 0
  fi

  local reason="manifest records no approval"
  [ "$_reapprove_verdict" = "hold-missing-manifest" ] && reason="no local manifest"

  _plog "$LOG_FILE" "META" "gate-stop" "fail" "APPROVAL_REVOKED"
  hb_gate "reapprove-gate" "fail" "APPROVAL_REVOKED" "{\"reason\":\"$reason\"}"
  _write_gate_verdict BLOCK
  return 2
}

# _resolve_type_label <label-names-csv>
# Extracts the Type label from a comma-separated list of Linear label names.
# Known Type labels: bug, feature, improvement, security, chore, refactor.
# refactor is an alias for improvement — it resolves to the same template
# but is a valid Type label that must not trigger NO_TEMPLATE_FOR_TYPE.
# Emits the first matching type, or empty string if none found.
_resolve_type_label() {
  local labels="$1"
  local IFS=','
  for label in $labels; do
    # Trim whitespace and lowercase — Linear labels are commonly title-cased
    # (e.g. "Feature"), and this match must be case-insensitive to match the
    # convention already used by validate-linear-config.sh.
    label=$(echo "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    case "$label" in
    bug | feature | improvement | security | chore | refactor)
      echo "$label"
      return 0
      ;;
    esac
  done
  return 0
}

# ── Dispatch (only when executed directly, not when sourced for testing) ──────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  TICKET_ID="${1:-}"
  LOG_FILE="${2:-}"
  HB_LOG_FILE="${3:-}"
  MODE=""

  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    *) usage ;;
    esac
  done

  [ -z "$TICKET_ID" ] && usage
  [ -z "$LOG_FILE" ] && usage
  [ -z "$MODE" ] && usage
  [[ "$MODE" =~ ^(entry|reapprove)$ ]] || {
    echo "Invalid mode: $MODE (expected entry or reapprove)" >&2
    exit 1
  }

  hb_init

  case "$MODE" in
  entry) _gate_entry ;;
  reapprove) _gate_reapprove ;;
  *) usage ;;
  esac
fi
