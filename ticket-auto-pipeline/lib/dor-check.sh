#!/usr/bin/env bash
# dor-check.sh — the Definition of Ready readiness check (dor-readiness-gate-
# foundation, extended by dor-quality-score). Sourceable bash library. Does
# NOT set -euo pipefail at file scope (caller controls error handling) —
# matching planned-ticket-body-check.sh's convention, since gate-check.sh and
# fleet-dispatch.sh both source this file and neither may have its own
# errexit/pipefail settings perturbed by doing so.
#
# Evaluates a ticket's readiness from its body alone — no tracker mutation,
# no model invocation. See design.md and
# openspec/changes/dor-readiness-gate-foundation/specs/ticket-readiness-gate/
# spec.md (promoted to openspec/specs/) and
# openspec/changes/dor-quality-score/{design.md,specs/} for the full decision
# record.
#
# Public API:
#   check_ticket_ready <TID> [--body <file>] [--type <type>]
#                       [--catalog <file>] [--no-fetch]
#     Sets DOR_STATUS (ready|not-ready|unavailable), DOR_MISSING (JSON array
#     of failing hard codes), DOR_ADVISORY (JSON array of failing advisory
#     codes), DOR_CHECKS (JSON object: code -> {pass, class, detail}),
#     DOR_SCORE (integer 0-100, diagnostic only, never part of the
#     ready/not-ready decision), DOR_DIMENSIONS (JSON object: dimension key
#     -> earned points or null when inapplicable), DOR_GAPS (JSON array of
#     semantic coverage gap names), DOR_BODY_HASH (sha256:<hex> of the
#     resolved body, or empty). Exit 0 ready, 1 not-ready, 2 unavailable (no
#     body could be resolved).
#
#   ensure_ticket_readiness <TID> [--body <file>] [--type <type>]
#     The single resolution path every consumer of readiness should use
#     instead of a raw manifest read (design.md Decision 3 — self-healing
#     cache). Returns the manifest's cached `ready` verdict if present and
#     still fresh (body-hash checked against local sources only — see
#     Decision 7 in dor-quality-score/design.md); otherwise computes live via
#     check_ticket_ready and caches the result (including score/dimensions/
#     gaps/body_hash) via set_ticket_readiness before returning it. Sets the
#     same DOR_STATUS/DOR_MISSING/DOR_ADVISORY globals, plus DOR_SCORE/
#     DOR_DIMENSIONS/DOR_GAPS when present in the returned verdict, and
#     DOR_SEMANTIC — the cached `ready.semantic` object, or empty — on every
#     return path (dor-semantic-evaluator design.md Decision 12/spec
#     "Semantic verdict exposed to readers"). Exit 0 ready, 1 not-ready, 2
#     unavailable/uncacheable.
#
#   dor-check.sh --waive <TID> <CODE> <reason> [--by <name>]
#     CLI-only (direct execution): wraps waive_ticket_readiness_code and
#     prints the resulting status. The minimal operator escape hatch for a
#     hard-code false positive (design.md Decision 2's revision).
#
# Hard codes (decide ready/not-ready): SCOPE_MISSING, NAV_PATH_MISSING,
# TEST_USER_MISSING, AC_MISSING, AC_VAGUE, REPRO_MISSING, FLAG_NEEDS_INFO,
# INTENT_MISSING, REPRO_NO_EXPECTED_ACTUAL.
# Advisory codes (reported, never block): TEST_USER_UNRESOLVED,
# TEST_DATA_MISSING, TEST_DATA_UNSEEDED, VPLAN_MISSING, VPLAN_ROW_GAP,
# VPLAN_UNVERIFIABLE, AC_IMPLEMENTATION_ONLY,
# VERIFICATION_REQUIRED_NOT_SELF_VERIFYING. DOR_STRICT_CATALOG/
# DOR_STRICT_TEST_DATA/DOR_STRICT_AC_IMPL/DOR_STRICT_VERIFICATION/
# DOR_STRICT_VPLAN (all default false) promote the catalog/test-data/
# impl-only/verification/verification-plan advisory codes to hard.
# DOR_STRICT_VPLAN (planner-ready-by-construction) promotes VPLAN_MISSING,
# VPLAN_ROW_GAP and VPLAN_UNVERIFIABLE together — it does not affect the
# self-verifying-AC escape hatch (VPLAN_MISSING's "satisfied-by-ac" class,
# which stays non-blocking regardless of this flag) or
# VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, which is governed by its own
# DOR_STRICT_VERIFICATION switch.
#
# `dor_quality_score` and `semantic_coverage_gaps` are diagnostic only — they
# NEVER affect DOR_STATUS. See docs/dor-readiness.md.

_DOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Declare-guard sourcing (planned-ticket-body-check.sh's convention, task
# 4.1) — a caller that already loaded these (gate-check.sh sources most of
# them at its own top) is not made to pay for a second parse, and no
# caller's own copy is clobbered.
if ! declare -f check_planned_body >/dev/null 2>&1; then
  source "$_DOR_SCRIPT_DIR/planned-ticket-body-check.sh"
fi
# notes-parse.sh is deliberately NOT sourced here, unlike this block's other
# entries — it sets `set -eo pipefail` unconditionally at file scope like
# the audit libraries did, but unlike them several of its functions
# (get_complexity, get_test_users_by_role, ...) genuinely rely on that
# errexit being active for their own internal error_return-based early
# returns to work (confirmed by test-notes-parse.sh regressing when this
# was tried), so it isn't safe to fix with the same BASH_SOURCE guard
# without a wider audit that's out of this change's scope. resolve_test_
# user_catalog/get_test_users_by_role are used below only when a caller
# (gate-check.sh always has, by already sourcing notes-parse.sh itself at
# its own top under its own errexit) has already made them available;
# otherwise the catalog-dependent checks resolve to CATALOG_ABSENT, which
# never blocks — the same safe degradation as no catalog file existing.
if ! declare -f vplan_parse >/dev/null 2>&1; then
  source "$_DOR_SCRIPT_DIR/vplan-parse.sh"
fi
if ! declare -f get_ticket_manifest_field >/dev/null 2>&1; then
  source "$_DOR_SCRIPT_DIR/manifest-read.sh"
fi
if ! declare -f set_ticket_readiness >/dev/null 2>&1; then
  source "$_DOR_SCRIPT_DIR/manifest-write.sh"
fi
if ! declare -f audit_ac_testability >/dev/null 2>&1; then
  source "$_DOR_SCRIPT_DIR/audit-ac-testability.sh"
fi
if ! declare -f audit_test_data_check >/dev/null 2>&1; then
  source "$_DOR_SCRIPT_DIR/audit-test-data-check.sh"
fi
# linear-api.sh is deliberately NOT sourced here — it sets `set -eo pipefail`
# unconditionally at file scope (a pre-existing leak this change does not
# fix, out of scope per design.md's Decision 11). Sourcing it would break
# this file's own "no set -e at file scope" contract. The live-fetch tier
# below is used only when a caller that already sourced linear-api.sh
# (gate-check.sh always has) has made get_issue available; otherwise that
# tier is skipped and DOR_STATUS resolves to unavailable/2 same as any other
# unreachable body source.

# ── Shared dimension vocabulary (dor-quality-score design.md Decision 6) ───
# The one place these keys are defined. Documented in
# docs/dor-readiness.md. `requirement_completeness` carries no weight — only
# a future semantic evaluator scores it (see ready.semantic in the manifest
# spec); it stays in the vocabulary array so the score's keys and the
# semantic evaluator's keys are drawn from one source.
DOR_DIMENSION_KEYS=(intent scope acceptance_criteria verification context test_uat dependencies constraints edge_cases completion requirement_completeness)

declare -A _DOR_DIMENSION_WEIGHTS=(
  [acceptance_criteria]=20
  [verification]=18
  [scope]=15
  [intent]=10
  [test_uat]=10
  [context]=8
  [completion]=5
  [dependencies]=5
  [constraints]=5
  [edge_cases]=4
)

# ── AC line pattern sets (design.md Decision 2/3/4) ─────────────────────────
# _DOR_OUTCOME_RE/_DOR_SELFVERIFY_RE deliberately do NOT match a bare
# backtick-quoted identifier — `PaymentRetryPolicy`, `InvoiceRepository` and
# similar class/file references are implementation detail, not an
# observable result, and matching them would let any AC that merely names a
# symbol dodge AC_IMPLEMENTATION_ONLY (every classifier below matches
# case-insensitively via `grep -qiP`, and AC lines are themselves
# lowercased by _dor_ac_lines, so an ALL_CAPS-vs-identifier distinction
# cannot survive either transform — a quoted *value*, never a quoted
# *name*, is the only safe backtick signal, and even that is covered below
# by the double-quote pattern instead). A bare 3-digit number in the HTTP
# status range (1xx-5xx) covers "returns 422"/"a 409 error" without
# requiring the word "status" immediately before it.
_DOR_IMPL_VERB_RE='\b(add|create|implement|refactor|migrate|wire|introduce|update|extract|rename|install|configure)\b'
_DOR_OUTCOME_RE='\b(returns?|responds?|displays?|shows?|renders?|emits?|logs?)\b|\b[1-5][0-9]{2}\b|within [0-9]+ ?(ms|s)\b|\bequals?\b|\bis (set|stored|visible|rejected|accepted)\b|\buser (can|cannot|sees)\b|error message|\bcount\b|[0-9]+ ?(ms|s|%|kb|mb)\b|"[^"]+"'
_DOR_SELFVERIFY_RE='\b[1-5][0-9]{2}\b|within [0-9]+ ?(ms|s)\b|\bequals?\b|\bis (set|stored|visible|rejected|accepted)\b|\buser (can|cannot|sees)\b|error message|[0-9]+ ?(ms|s|%|kb|mb)\b|"[^"]+"'
_DOR_EDGE_RE='\b(error|invalid|empty|expired|duplicate|limit|timeout|unauthori[sz]ed)\b'
_DOR_VAGUE_WIDENED_RE='\b(appropriate(ly)?|reasonabl[ey]|sufficient(ly)?|robust(ly)?|intuitive(ly)?|seamless(ly)?|graceful(ly)?)\b|\b(is|are|be|gets?) handled\b'
_DOR_BACKEND_CONTEXT_RE='`[A-Za-z0-9_./:-]*/[A-Za-z0-9_./:-]*`|\b(endpoint|controller|service|job|cron|worker|consumer|queue|CLI|command)\b'

# ── Internal helpers ─────────────────────────────────────────────────────

# _dor_test_user_content/_dor_test_data_content <body> — the same awk
# section-extraction pattern already used by planned-ticket-body-check.sh's
# _has_section_test_user/_has_section_scope, fixed per heading this file
# needs directly (no variable-built regex is ever passed to awk).
_dor_test_user_content() {
  echo "$1" | awk '/^##[[:space:]]*Test User/ {found=1; next} found && /^##/ {exit} found {print}'
}

_dor_test_data_content() {
  echo "$1" | awk '/^##[[:space:]]*Test Data/ {found=1; next} found && /^##/ {exit} found {print}'
}

# _dor_section_content <body> <alias-set-name> — one shared extractor for
# every new-hard-code section lookup (task 3.1). Alias sets are fixed
# literal lists defined right here — no caller-built regex ever reaches
# awk, matching _dor_test_user_content's safety convention. Tries each
# alias heading in order (case-insensitive), echoes the first non-blank
# section content found. Returns 1 when no alias heading yields content.
_dor_section_content() {
  local body="$1" set_name="$2"
  local -a aliases=()
  case "$set_name" in
  why) aliases=("Background / Motivation" "Motivation" "Problem" "Why" "Context") ;;
  outcome) aliases=("Proposed Behaviour" "Proposed Changes" "Desired Outcome" "Goal") ;;
  expected) aliases=("Expected Behaviour") ;;
  actual) aliases=("Actual Behaviour") ;;
  summary) aliases=("Summary") ;;
  out_of_scope) aliases=("Out of Scope") ;;
  constraints) aliases=("Constraints" "Non-functional" "Non-functional Requirements" "Performance" "Security") ;;
  dependencies) aliases=("Related Tickets" "Dependencies") ;;
  environment) aliases=("Environment") ;;
  *) return 1 ;;
  esac

  local a lower_a content
  for a in "${aliases[@]}"; do
    lower_a=$(echo "$a" | tr '[:upper:]' '[:lower:]')
    content=$(echo "$body" | awk -v h="$lower_a" '
      { line = tolower($0) }
      line ~ ("^##[[:space:]]*" h "[[:space:]]*$") { found=1; next }
      found && /^##/ { exit }
      found { print }
    ')
    if [ -n "$(echo "$content" | tr -d '[:space:]')" ]; then
      echo "$content"
      return 0
    fi
  done
  return 1
}

# _dor_is_placeholder <text> [summary] — true (exit 0) when <text> is blank,
# a bare TBD/TODO/N/A/none marker, consists only of unfilled `{...}`
# template token(s), or (when a summary is given) is a near-restatement of
# it (token Jaccard >= 0.8 — same tokenizer approach as
# audit-title-similarity.sh).
_dor_is_placeholder() {
  local text="$1" summary="${2:-}"
  local trimmed
  trimmed=$(echo "$text" | tr -d '[:space:]')
  [ -z "$trimmed" ] && return 0

  local stripped
  stripped=$(echo "$text" | grep -viP '^\s*(TBD|TODO|N/?A|none)\s*$' | tr -d '[:space:]')
  [ -z "$stripped" ] && return 0

  # Unfilled template token: every non-blank line is a bare {...} — no
  # actual prose remains once brace-only lines are dropped.
  local no_braces
  no_braces=$(echo "$text" | grep -vP '^\s*\{[^}]*\}\s*$' | tr -d '[:space:]')
  [ -z "$no_braces" ] && return 0

  if [ -n "$summary" ]; then
    local set1 set2 intersection union score
    set1=$(echo "$text" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9[:space:]]//g' | tr -s '[:space:]' '\n' | sort -u | grep -v '^$')
    set2=$(echo "$summary" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9[:space:]]//g' | tr -s '[:space:]' '\n' | sort -u | grep -v '^$')
    if [ -n "$set1" ] && [ -n "$set2" ]; then
      intersection=$(comm -12 <(echo "$set1") <(echo "$set2") | wc -l)
      union=$(comm <(echo "$set1") <(echo "$set2") | wc -l)
      if [ "$union" -gt 0 ] 2>/dev/null; then
        score=$(awk -v i="$intersection" -v u="$union" 'BEGIN { printf "%.2f", i / u }')
        if awk -v s="$score" 'BEGIN { exit !(s >= 0.8) }'; then
          return 0
        fi
      fi
    fi
  fi

  return 1
}

# _dor_ac_lines <body> — Acceptance Criteria section lines, normalised
# (lowercase, collapsed whitespace, bullet/checkbox/number stripped) and
# deduplicated (task 4.1). Falls back to the whole body when no `##
# Acceptance Criteria` heading is found (mirrors _has_section_ac's loose
# checkbox-anywhere fallback). Shared by every AC-derived signal: AC_VAGUE,
# AC_IMPLEMENTATION_ONLY, VERIFICATION_REQUIRED_NOT_SELF_VERIFYING,
# VPLAN_MISSING's satisfied-by-AC rule, and the score/gaps computation.
_dor_ac_lines() {
  local body="$1" section
  section=$(echo "$body" | awk '/^##[[:space:]]*Acceptance Criteria/ {found=1; next} found && /^##/ {exit} found {print}')
  [ -n "$(echo "$section" | tr -d '[:space:]')" ] || section="$body"
  echo "$section" |
    grep -E '^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]+\S' |
    sed -E 's/^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]*//' |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' |
    awk '!seen[$0]++ && length($0) > 0'
}

# Per-line classifiers (task 4.2/design.md Decision 2/4).
_dor_ac_is_impl() {
  echo "$1" | grep -qiP "$_DOR_IMPL_VERB_RE" 2>/dev/null
}
_dor_ac_is_outcome() {
  echo "$1" | grep -qiP "$_DOR_OUTCOME_RE" 2>/dev/null
}
_dor_ac_is_self_verifying() {
  echo "$1" | grep -qiP "$_DOR_SELFVERIFY_RE" 2>/dev/null
}
_dor_ac_is_edge_case() {
  echo "$1" | grep -qiP "$_DOR_EDGE_RE" 2>/dev/null
}

# _dor_ac_count <body> — approximate acceptance-criteria row count, used only
# to size VPLAN_ROW_GAP's comparison. Checkbox items first (the documented
# `- [ ]` shape), falling back to any bullet/numbered/AC-prefixed line.
_dor_ac_count() {
  local body="$1" n
  n=$(echo "$body" | grep -cP '^\s*- \[[ xX]\]\s' 2>/dev/null || true)
  n="${n//[^0-9]/}"
  if [ -z "$n" ] || [ "$n" -eq 0 ] 2>/dev/null; then
    n=$(echo "$body" | grep -cE '^\s*[-*]\s|^\s*[0-9]+[.)]\s|^\s*AC[:]' 2>/dev/null || true)
    n="${n//[^0-9]/}"
  fi
  [ -n "$n" ] || n=0
  echo "$n"
}

# _dor_test_user_resolves <body> <catalog-path> — exit 0 resolved, 1
# unresolved (task 4.6). An explicit email+password pair always resolves
# without touching the catalog; otherwise a role token is extracted from the
# section (a `role:` label or a backticked identifier) and checked against
# the catalog's roles[] via get_test_users_by_role. No extractable role is
# unresolved.
_dor_test_user_resolves() {
  local body="$1" catalog_path="$2" content role count
  content=$(_dor_test_user_content "$body")

  if echo "$content" | grep -qiP 'email[:\s]*\S+@\S+\.\S+' 2>/dev/null &&
    echo "$content" | grep -qiP 'password' 2>/dev/null; then
    return 0
  fi

  role=$(echo "$content" | grep -oiP '(role[:\s]*\K[A-Za-z_-]+|`\K[A-Za-z_-]+(?=`))' 2>/dev/null | head -1)
  [ -n "$role" ] || return 1

  count=$(get_test_users_by_role "$role" "$catalog_path" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
  [ "${count:-0}" -gt 0 ] 2>/dev/null
}

# _dor_test_data_state <body> — echoes missing|unseeded|ok (task 4.7). A
# heading absent, or present with only whitespace, is "missing". A heading
# present whose only non-blank lines are the loose check's own bare trigger
# words (planned-ticket-body-check.sh's _has_section_test_data accepts any
# of these appearing ANYWHERE with no further detail) is "unseeded" — that
# loose check is satisfied but no concrete data setup was actually
# described. Anything else is "ok".
_dor_test_data_state() {
  local body="$1" content trimmed stripped
  content=$(_dor_test_data_content "$body")
  trimmed=$(echo "$content" | tr -d '[:space:]')

  if [ -z "$trimmed" ]; then
    echo "missing"
    return
  fi

  stripped=$(echo "$content" |
    grep -viP '^\s*(test data( prerequisites)?:?|prerequisites?:?|n/?a|none|tbd|todo)\s*$' |
    tr -d '[:space:]')
  if [ -z "$stripped" ]; then
    echo "unseeded"
    return
  fi

  echo "ok"
}

# _dor_record <code> <pass:true|false|null> <class> <detail>
# Merges one entry into the running $DOR_CHECKS object.
_dor_record() {
  local code="$1" pass="$2" class="$3" detail="$4"
  DOR_CHECKS=$(jq -c --arg code "$code" --argjson pass "$pass" --arg class "$class" --arg detail "$detail" \
    '.[$code] = {pass: $pass, class: $class, detail: $detail}' <<<"$DOR_CHECKS")
}

# _dor_json_array <elements...> — bash array to a compact JSON array.
_dor_json_array() {
  if [ "$#" -eq 0 ]; then
    echo "[]"
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -cs .
}

# _dor_resolve_type <TID> <override>
_dor_resolve_type() {
  local tid="$1" override="$2" type=""
  if [ -n "$override" ]; then
    echo "$override"
    return
  fi
  if declare -f get_ticket_manifest_field >/dev/null 2>&1; then
    type=$(get_ticket_manifest_field "$tid" type 2>/dev/null) || type=""
  fi
  [ -n "$type" ] && [ "$type" != "null" ] || type="feature"
  echo "$type"
}

# _dor_resolve_body <TID> <body-file> <no-fetch> — echoes resolved body text
# (empty if none found). Source order matches design.md Decision 5's gate
# order: an explicit --body file, then the planner's body.md, then (unless
# --no-fetch) the live ticket description.
_dor_resolve_body() {
  local tid="$1" body_file="$2" no_fetch="$3" body=""

  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    body=$(cat "$body_file" 2>/dev/null || true)
  fi

  if [ -z "$body" ] && declare -f resolve_planner_dir >/dev/null 2>&1; then
    local pdir
    pdir=$(resolve_planner_dir "$tid" 2>/dev/null) || true
    if [ -n "$pdir" ] && [ -f "$pdir/body.md" ]; then
      body=$(cat "$pdir/body.md" 2>/dev/null || true)
    fi
  fi

  if [ -z "$body" ] && [ "$no_fetch" != "true" ] && declare -f get_issue >/dev/null 2>&1; then
    local issue_json
    issue_json=$(get_issue "$tid" 2>/dev/null) || issue_json=""
    if [ -n "$issue_json" ]; then
      body=$(echo "$issue_json" | jq -r '.description // ""' 2>/dev/null || true)
    fi
  fi

  echo "$body"
}

# _dor_body_hash <text> — echoes "sha256:<hex>", or empty if neither
# sha256sum nor shasum is available (task 5.4).
_dor_body_hash() {
  local text="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "sha256:$(printf '%s' "$text" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    echo "sha256:$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')"
  else
    echo ""
  fi
}

# _dor_score — pure function over check_ticket_ready's own already-computed
# local variables (design.md Decision 4). Bash's dynamic scoping makes the
# caller's `local`s visible here without threading two dozen parameters
# through an explicit signature — this must only ever be called from inside
# check_ticket_ready, after every dimension input below has been computed.
# Sets DOR_SCORE (integer) and DOR_DIMENSIONS (JSON object, dimension key ->
# earned points or null when inapplicable).
_dor_score() {
  local -A dims=()

  # acceptance_criteria (20) — 0 if no AC; else mean over unique AC lines of
  # (not vague * not impl-only).
  if [ "$ac_count" -eq 0 ]; then
    dims[acceptance_criteria]="0"
  else
    local _sum=0 _idx2
    for ((_idx2 = 0; _idx2 < ac_count; _idx2++)); do
      local _ok=1
      [ "${ac_is_vague[$_idx2]}" = "1" ] && _ok=0
      if [ "${ac_is_impl[$_idx2]}" = "1" ] && [ "${ac_is_outcome[$_idx2]}" != "1" ]; then
        _ok=0
      fi
      _sum=$((_sum + _ok))
    done
    dims[acceptance_criteria]=$(awk -v s="$_sum" -v n="$ac_count" -v w=20 'BEGIN { printf "%.2f", (s / n) * w }')
  fi

  # verification (18) — 1 if vplan with >=1 verifiable and no row gap; else
  # self-verifying AC ratio; 0.5 floor if vplan present.
  if [ "$vplan_found" = "true" ]; then
    local _vfrac="1"
    if [ "${VPLAN_VERIFIABLE:-0}" -eq 0 ] 2>/dev/null; then _vfrac="0.5"; fi
    local _ac_cnt_raw
    _ac_cnt_raw=$(_dor_ac_count "$body")
    if [ "$_ac_cnt_raw" -gt 0 ] 2>/dev/null && [ "${VPLAN_ROWS:-0}" -lt "$_ac_cnt_raw" ] 2>/dev/null; then
      _vfrac="0.5"
    fi
    dims[verification]=$(awk -v f="$_vfrac" -v w=18 'BEGIN { printf "%.2f", f * w }')
  elif [ "$ac_count" -gt 0 ]; then
    dims[verification]=$(awk -v s="$selfverify_count" -v n="$ac_count" -v w=18 'BEGIN { printf "%.2f", (s / n) * w }')
  else
    dims[verification]="0"
  fi

  # scope (15) — 0 absent; 0.6 present; 1 present + layer column parseable.
  if [ "$scope_present" != "true" ]; then
    dims[scope]="0"
  else
    local _layers
    _layers=$(_scope_layers "$body" 2>/dev/null)
    if [ -n "$_layers" ]; then
      dims[scope]="15.00"
    else
      dims[scope]="9.00"
    fi
  fi

  # intent (10) — 0/0.5/1 for neither/one/both of why + outcome.
  local _intent_frac="0"
  if [ "$has_why" = "true" ] && [ "$has_outcome" = "true" ]; then
    _intent_frac="1"
  elif [ "$has_why" = "true" ] || [ "$has_outcome" = "true" ]; then
    _intent_frac="0.5"
  fi
  dims[intent]=$(awk -v f="$_intent_frac" -v w=10 'BEGIN { printf "%.2f", f * w }')

  # test_uat (10) — inapplicable for backend-only scope; else mean of
  # test-user present, resolvable-or-catalog-absent, test-data ok.
  if [ "$backend_only" = "true" ]; then
    dims[test_uat]=""
  else
    local _tu_ok=0 _td_ok=0 _tu_resolve_ok=0
    [ "$test_user_present" = "true" ] && _tu_ok=1
    { [ "$test_user_resolved_state" = "resolved" ] || [ "$test_user_resolved_state" = "unevaluated" ]; } && _tu_resolve_ok=1
    [ "$test_data_state" = "ok" ] && _td_ok=1
    dims[test_uat]=$(awk -v a="$_tu_ok" -v b="$_tu_resolve_ok" -v c="$_td_ok" -v w=10 'BEGIN { printf "%.2f", ((a + b + c) / 3) * w }')
  fi

  # context (8) — FE: nav path present; BE: entry point named; + environment
  # present.
  local _ctx_frac="0"
  if [ "$backend_only" = "true" ]; then
    echo "$body" | grep -qiP "$_DOR_BACKEND_CONTEXT_RE" 2>/dev/null && _ctx_frac="0.6"
  else
    [ "$nav_path_present" = "true" ] && _ctx_frac="0.6"
  fi
  local _env_present="false"
  _dor_section_content "$body" environment >/dev/null 2>&1 && _env_present="true"
  if [ "$_env_present" = "true" ]; then
    _ctx_frac=$(awk -v f="$_ctx_frac" 'BEGIN { v = f + 0.4; if (v > 1) v = 1; printf "%.2f", v }')
  fi
  dims[context]=$(awk -v f="$_ctx_frac" -v w=8 'BEGIN { printf "%.2f", f * w }')

  # completion (5) — 1 if Out of Scope non-placeholder or AC count >= 2;
  # else 0.5 if AC present.
  local _oos_content=""
  _oos_content=$(_dor_section_content "$body" out_of_scope 2>/dev/null) || _oos_content=""
  if { [ -n "$_oos_content" ] && ! _dor_is_placeholder "$_oos_content"; } || [ "$ac_count" -ge 2 ]; then
    dims[completion]="5.00"
  elif [ "$ac_count" -gt 0 ]; then
    dims[completion]="2.50"
  else
    dims[completion]="0"
  fi

  # dependencies (5) — 1 if Related Tickets/Dependencies non-placeholder or
  # manifest blocked_by non-empty; 0.5 if section present with "none".
  local _dep_content="" _blocked_by_nonempty="false"
  _dep_content=$(_dor_section_content "$body" dependencies 2>/dev/null) || _dep_content=""
  if [ -n "${tid:-}" ] && declare -f get_ticket_manifest_field >/dev/null 2>&1; then
    local _bb _bb_len
    _bb=$(get_ticket_manifest_field "$tid" blocked_by 2>/dev/null)
    _bb_len=$(echo "$_bb" | jq 'length' 2>/dev/null) || _bb_len=0
    [ "${_bb_len:-0}" -gt 0 ] 2>/dev/null && _blocked_by_nonempty="true"
  fi
  if { [ -n "$_dep_content" ] && ! _dor_is_placeholder "$_dep_content"; } || [ "$_blocked_by_nonempty" = "true" ]; then
    dims[dependencies]="5.00"
  elif [ -n "$_dep_content" ]; then
    dims[dependencies]="2.50"
  else
    dims[dependencies]="0"
  fi

  # constraints (5) — 1 if a Constraints/Non-functional/Performance/Security
  # section, or an AC with a numeric bound.
  local _constraints_content=""
  _constraints_content=$(_dor_section_content "$body" constraints 2>/dev/null) || _constraints_content=""
  local _has_numeric_bound="false" _idx3
  for ((_idx3 = 0; _idx3 < ac_count; _idx3++)); do
    echo "${ac_lines[$_idx3]}" | grep -qP '[0-9]+ ?(ms|s|%|kb|mb)\b' 2>/dev/null && _has_numeric_bound="true"
  done
  if { [ -n "$_constraints_content" ] && ! _dor_is_placeholder "$_constraints_content"; } || [ "$_has_numeric_bound" = "true" ]; then
    dims[constraints]="5.00"
  else
    dims[constraints]="0"
  fi

  # edge_cases (4) — min(1, distinct edge-case AC lines / 2).
  local _edge_count=0 _idx4
  for ((_idx4 = 0; _idx4 < ac_count; _idx4++)); do
    [ "${ac_is_edge[$_idx4]}" = "1" ] && _edge_count=$((_edge_count + 1))
  done
  dims[edge_cases]=$(awk -v e="$_edge_count" -v w=4 'BEGIN { f = e / 2; if (f > 1) f = 1; printf "%.2f", f * w }')

  # ── assemble DOR_DIMENSIONS + DOR_SCORE ──────────────────────────────────
  local dim_json="{}" total_earned="0" total_weight=0 _k
  for _k in "${DOR_DIMENSION_KEYS[@]}"; do
    if [ "$_k" = "requirement_completeness" ]; then
      dim_json=$(jq -c --arg k "$_k" '.[$k] = null' <<<"$dim_json")
      continue
    fi
    local _w="${_DOR_DIMENSION_WEIGHTS[$_k]:-0}"
    local _v="${dims[$_k]:-}"
    if [ -z "$_v" ]; then
      dim_json=$(jq -c --arg k "$_k" '.[$k] = null' <<<"$dim_json")
      continue
    fi
    dim_json=$(jq -c --arg k "$_k" --argjson v "$_v" '.[$k] = $v' <<<"$dim_json")
    total_earned=$(awk -v t="$total_earned" -v v="$_v" 'BEGIN { printf "%.4f", t + v }')
    total_weight=$((total_weight + _w))
  done

  DOR_DIMENSIONS="$dim_json"
  if [ "$total_weight" -gt 0 ]; then
    DOR_SCORE=$(awk -v e="$total_earned" -v t="$total_weight" 'BEGIN { printf "%.0f", (e / t) * 100 }')
  else
    DOR_SCORE=0
  fi
}

# _dor_gaps — derives DOR_GAPS from already-computed caller locals plus the
# just-computed DOR_DIMENSIONS (design.md Decision 5). Must run after
# _dor_score.
_dor_gaps() {
  local -a gaps=()
  [ "$ac_count" -gt 0 ] && gaps+=("requirement_completeness")
  [ "$ac_count" -ge 2 ] && gaps+=("contradictory_requirements")
  [ "$scope_present" = "true" ] && gaps+=("deep_scope_ambiguity")
  local _edge_frac
  _edge_frac=$(echo "$DOR_DIMENSIONS" | jq -r '.edge_cases // 0' 2>/dev/null)
  if awk -v f="${_edge_frac:-0}" 'BEGIN { exit !(f > 0) }'; then
    gaps+=("edge_case_sufficiency")
  fi
  DOR_GAPS=$(_dor_json_array "${gaps[@]}")
}

# ── Public API ────────────────────────────────────────────────────────────

# check_ticket_ready <TID> [--body <file>] [--type <type>] [--catalog <file>]
#                     [--no-fetch]
check_ticket_ready() {
  local tid="$1"
  shift || true
  local body_file="" type_override="" catalog_override="" no_fetch="false"
  while [ $# -gt 0 ]; do
    case "$1" in
    --body)
      body_file="${2:-}"
      shift 2
      ;;
    --type)
      type_override="${2:-}"
      shift 2
      ;;
    --catalog)
      catalog_override="${2:-}"
      shift 2
      ;;
    --no-fetch)
      no_fetch="true"
      shift
      ;;
    *) shift ;;
    esac
  done

  DOR_STATUS="unavailable"
  DOR_MISSING="[]"
  DOR_ADVISORY="[]"
  DOR_CHECKS="{}"
  DOR_SCORE=""
  DOR_DIMENSIONS="{}"
  DOR_GAPS="[]"
  DOR_BODY_HASH=""

  local type body
  type=$(_dor_resolve_type "$tid" "$type_override")
  body=$(_dor_resolve_body "$tid" "$body_file" "$no_fetch")

  if [ -z "$body" ]; then
    DOR_STATUS="unavailable"
    return 2
  fi

  DOR_BODY_HASH=$(_dor_body_hash "$body")

  local missing=() advisory=()
  local strict_catalog="${DOR_STRICT_CATALOG:-false}"
  local strict_test_data="${DOR_STRICT_TEST_DATA:-false}"
  local strict_ac_impl="${DOR_STRICT_AC_IMPL:-false}"
  local strict_verification="${DOR_STRICT_VERIFICATION:-false}"
  local strict_vplan="${DOR_STRICT_VPLAN:-false}"

  # ── Scope + structural hard codes ────────────────────────────────────────
  local backend_only="false"
  if _scope_is_backend_only "$body"; then
    backend_only="true"
  fi

  local scope_present="false"
  if _has_section_scope "$body"; then
    scope_present="true"
    _dor_record "SCOPE_MISSING" "false" "hard" "Scope table present"
  else
    missing+=("SCOPE_MISSING")
    _dor_record "SCOPE_MISSING" "true" "hard" "no Scope table found"
  fi

  if _has_section_ac "$body"; then
    _dor_record "AC_MISSING" "false" "hard" "Acceptance Criteria present"
  else
    missing+=("AC_MISSING")
    _dor_record "AC_MISSING" "true" "hard" "no Acceptance Criteria found"
  fi

  local test_user_present="false" nav_path_present="false"
  if [ "$backend_only" = "true" ]; then
    _dor_record "TEST_USER_MISSING" "null" "inapplicable" "backend-only scope"
    _dor_record "NAV_PATH_MISSING" "null" "inapplicable" "backend-only scope"
  else
    if _has_section_test_user "$body"; then
      test_user_present="true"
      _dor_record "TEST_USER_MISSING" "false" "hard" "Test User section present"
    else
      missing+=("TEST_USER_MISSING")
      _dor_record "TEST_USER_MISSING" "true" "hard" "no Test User section found"
    fi

    if _has_section_nav_path "$body"; then
      nav_path_present="true"
      _dor_record "NAV_PATH_MISSING" "false" "hard" "Navigation Path present"
    else
      missing+=("NAV_PATH_MISSING")
      _dor_record "NAV_PATH_MISSING" "true" "hard" "no Navigation Path found"
    fi
  fi

  if [ "$type" = "bug" ]; then
    if _has_section_repro_steps "$body"; then
      _dor_record "REPRO_MISSING" "false" "hard" "reproduction steps present"
    else
      missing+=("REPRO_MISSING")
      _dor_record "REPRO_MISSING" "true" "hard" "no reproduction steps found (bug)"
    fi
  else
    _dor_record "REPRO_MISSING" "null" "inapplicable" "type=$type, not a bug"
  fi

  # ── INTENT_MISSING (design.md Decision 1) ────────────────────────────────
  local summary_content why_content outcome_content has_why="false" has_outcome="false"
  summary_content=$(_dor_section_content "$body" summary) || summary_content=""
  if [ "$type" = "bug" ]; then
    why_content=$(_dor_section_content "$body" actual) || why_content=""
    outcome_content=$(_dor_section_content "$body" expected) || outcome_content=""
  else
    why_content=$(_dor_section_content "$body" why) || why_content=""
    outcome_content=$(_dor_section_content "$body" outcome) || outcome_content=""
  fi
  if [ -n "$why_content" ] && ! _dor_is_placeholder "$why_content" "$summary_content"; then
    has_why="true"
  fi
  if [ -n "$outcome_content" ] && ! _dor_is_placeholder "$outcome_content" "$summary_content"; then
    has_outcome="true"
  fi

  if [ "$has_why" = "true" ] && [ "$has_outcome" = "true" ]; then
    _dor_record "INTENT_MISSING" "false" "hard" "why and outcome both present"
  else
    missing+=("INTENT_MISSING")
    _dor_record "INTENT_MISSING" "true" "hard" "missing intent (why=$has_why outcome=$has_outcome)"
  fi

  # ── REPRO_NO_EXPECTED_ACTUAL (bug only, independent of REPRO_MISSING) ────
  if [ "$type" = "bug" ]; then
    local expected_content actual_content
    expected_content=$(_dor_section_content "$body" expected) || expected_content=""
    actual_content=$(_dor_section_content "$body" actual) || actual_content=""
    if [ -n "$expected_content" ] && ! _dor_is_placeholder "$expected_content" "$summary_content" &&
      [ -n "$actual_content" ] && ! _dor_is_placeholder "$actual_content" "$summary_content"; then
      _dor_record "REPRO_NO_EXPECTED_ACTUAL" "false" "hard" "expected and actual behaviour both present"
    else
      missing+=("REPRO_NO_EXPECTED_ACTUAL")
      _dor_record "REPRO_NO_EXPECTED_ACTUAL" "true" "hard" "missing expected/actual behaviour"
    fi
  else
    _dor_record "REPRO_NO_EXPECTED_ACTUAL" "null" "inapplicable" "type=$type, not a bug"
  fi

  # ── AC line derivation (single canonical extraction + per-line
  # classification, task 4.1/4.2 — reused by AC_VAGUE, AC_IMPLEMENTATION_ONLY,
  # VERIFICATION_REQUIRED_NOT_SELF_VERIFYING, VPLAN_MISSING's satisfied-by-AC
  # rule, and the score/gaps computation) ──────────────────────────────────
  local -a ac_lines=()
  local _al
  while IFS= read -r _al; do
    [ -n "$_al" ] && ac_lines+=("$_al")
  done < <(_dor_ac_lines "$body")
  local ac_count=${#ac_lines[@]}

  local -a ac_is_vague=() ac_is_impl=() ac_is_outcome=() ac_is_selfverify=() ac_is_edge=()
  local _idx
  for ((_idx = 0; _idx < ac_count; _idx++)); do
    _al="${ac_lines[$_idx]}"
    audit_ac_testability "$_al" >/dev/null 2>&1 || true
    if [ "${VAGUE_AC_COUNT:-0}" -gt 0 ] 2>/dev/null; then
      ac_is_vague+=("1")
    elif echo "$_al" | grep -qiP "$_DOR_VAGUE_WIDENED_RE" 2>/dev/null && ! _dor_ac_is_self_verifying "$_al"; then
      ac_is_vague+=("1")
    else
      ac_is_vague+=("0")
    fi
    _dor_ac_is_impl "$_al" && ac_is_impl+=("1") || ac_is_impl+=("0")
    _dor_ac_is_outcome "$_al" && ac_is_outcome+=("1") || ac_is_outcome+=("0")
    _dor_ac_is_self_verifying "$_al" && ac_is_selfverify+=("1") || ac_is_selfverify+=("0")
    _dor_ac_is_edge_case "$_al" && ac_is_edge+=("1") || ac_is_edge+=("0")
  done

  # ── AC_VAGUE — original audit_ac_testability patterns (per line) plus the
  # DoR-only widened pass (design.md Decision 3), merged into one code
  # (task 4.3). audit-ac-testability.sh itself is never modified. ─────────
  local vague_count=0 vague_lines_list=""
  for ((_idx = 0; _idx < ac_count; _idx++)); do
    if [ "${ac_is_vague[$_idx]}" = "1" ]; then
      vague_count=$((vague_count + 1))
      vague_lines_list="${vague_lines_list}${vague_lines_list:+|}${ac_lines[$_idx]:0:80}"
    fi
  done
  if [ "$vague_count" -gt 0 ]; then
    missing+=("AC_VAGUE")
    _dor_record "AC_VAGUE" "true" "hard" "${vague_count} vague acceptance criteria: ${vague_lines_list}"
  else
    _dor_record "AC_VAGUE" "false" "hard" "no vague acceptance criteria detected"
  fi

  # ── AC_IMPLEMENTATION_ONLY (task 4.4, design.md Decision 2) ──────────────
  local impl_only_count=0
  for ((_idx = 0; _idx < ac_count; _idx++)); do
    if [ "${ac_is_impl[$_idx]}" = "1" ] && [ "${ac_is_outcome[$_idx]}" != "1" ]; then
      impl_only_count=$((impl_only_count + 1))
    fi
  done
  local ac_impl_class="advisory"
  [ "$strict_ac_impl" = "true" ] && ac_impl_class="hard"
  if [ "$ac_count" -gt 0 ] && [ "$impl_only_count" -eq "$ac_count" ]; then
    _dor_record "AC_IMPLEMENTATION_ONLY" "true" "$ac_impl_class" "all ${ac_count} acceptance criteria are implementation-only"
    if [ "$strict_ac_impl" = "true" ]; then
      missing+=("AC_IMPLEMENTATION_ONLY")
    else
      advisory+=("AC_IMPLEMENTATION_ONLY")
    fi
  else
    _dor_record "AC_IMPLEMENTATION_ONLY" "false" "$ac_impl_class" "at least one outcome-bearing acceptance criterion, or no acceptance criteria"
  fi

  # ── VERIFICATION_REQUIRED_NOT_SELF_VERIFYING + VPLAN_* (task 4.5/4.6) ────
  local selfverify_count=0
  for ((_idx = 0; _idx < ac_count; _idx++)); do
    [ "${ac_is_selfverify[$_idx]}" = "1" ] && selfverify_count=$((selfverify_count + 1))
  done

  local vplan_found="false"
  if declare -f vplan_parse >/dev/null 2>&1 && vplan_parse "$body" 2>/dev/null; then
    vplan_found="true"
  fi

  local satisfied_by_ac="false"
  if [ "$vplan_found" != "true" ] && [ "$ac_count" -gt 0 ] && [ $((selfverify_count * 2)) -ge "$ac_count" ]; then
    satisfied_by_ac="true"
  fi

  local verification_class="advisory"
  [ "$strict_verification" = "true" ] && verification_class="hard"
  if [ "$vplan_found" != "true" ] && [ "$selfverify_count" -eq 0 ]; then
    _dor_record "VERIFICATION_REQUIRED_NOT_SELF_VERIFYING" "true" "$verification_class" "no Verification Plan and no self-verifying acceptance criteria"
    if [ "$strict_verification" = "true" ]; then
      missing+=("VERIFICATION_REQUIRED_NOT_SELF_VERIFYING")
    else
      advisory+=("VERIFICATION_REQUIRED_NOT_SELF_VERIFYING")
    fi
  else
    _dor_record "VERIFICATION_REQUIRED_NOT_SELF_VERIFYING" "false" "$verification_class" "Verification Plan present, or acceptance criteria are self-verifying"
  fi

  local vplan_class="advisory"
  [ "$strict_vplan" = "true" ] && vplan_class="hard"

  if [ "$vplan_found" = "true" ]; then
    _dor_record "VPLAN_MISSING" "false" "$vplan_class" "Verification Plan table present"

    if [ "${VPLAN_VERIFIABLE:-0}" -eq 0 ] 2>/dev/null; then
      _dor_record "VPLAN_UNVERIFIABLE" "true" "$vplan_class" "no criteria marked verifiable in the table"
      if [ "$strict_vplan" = "true" ]; then
        missing+=("VPLAN_UNVERIFIABLE")
      else
        advisory+=("VPLAN_UNVERIFIABLE")
      fi
    else
      _dor_record "VPLAN_UNVERIFIABLE" "false" "$vplan_class" "${VPLAN_VERIFIABLE} criteria marked verifiable"
    fi

    local ac_count_raw
    ac_count_raw=$(_dor_ac_count "$body")
    if [ "$ac_count_raw" -gt 0 ] 2>/dev/null && [ "${VPLAN_ROWS:-0}" -lt "$ac_count_raw" ] 2>/dev/null; then
      _dor_record "VPLAN_ROW_GAP" "true" "$vplan_class" "${VPLAN_ROWS} table rows vs ${ac_count_raw} acceptance criteria"
      if [ "$strict_vplan" = "true" ]; then
        missing+=("VPLAN_ROW_GAP")
      else
        advisory+=("VPLAN_ROW_GAP")
      fi
    else
      _dor_record "VPLAN_ROW_GAP" "false" "$vplan_class" "table rows cover acceptance criteria count"
    fi
  elif [ "$satisfied_by_ac" = "true" ]; then
    _dor_record "VPLAN_MISSING" "null" "satisfied-by-ac" "no Verification Plan table, but ${selfverify_count}/${ac_count} acceptance criteria are self-verifying"
    _dor_record "VPLAN_ROW_GAP" "null" "inapplicable" "VPLAN_MISSING satisfied by self-verifying AC"
    _dor_record "VPLAN_UNVERIFIABLE" "null" "inapplicable" "VPLAN_MISSING satisfied by self-verifying AC"
  else
    _dor_record "VPLAN_MISSING" "true" "$vplan_class" "no Verification Plan table found"
    if [ "$strict_vplan" = "true" ]; then
      missing+=("VPLAN_MISSING")
    else
      advisory+=("VPLAN_MISSING")
    fi
    _dor_record "VPLAN_ROW_GAP" "null" "inapplicable" "VPLAN_MISSING already covers this"
    _dor_record "VPLAN_UNVERIFIABLE" "null" "inapplicable" "VPLAN_MISSING already covers this"
  fi

  # FLAG_NEEDS_INFO — reported here for completeness (design.md Decision 3:
  # the *live* exclusion consumers actually gate on is
  # ticket_dispatch_blocked_by_flags, evaluated independently and always
  # fresh — never satisfied from this cached report).
  if declare -f ticket_dispatch_blocked_by_flags >/dev/null 2>&1 &&
    ticket_dispatch_blocked_by_flags "$tid" 2>/dev/null; then
    missing+=("FLAG_NEEDS_INFO")
    _dor_record "FLAG_NEEDS_INFO" "true" "hard" "manifest flags contain needs-info"
  else
    _dor_record "FLAG_NEEDS_INFO" "false" "hard" "no needs-info flag"
  fi

  # ── Advisory codes ────────────────────────────────────────────────────────

  # TEST_USER_UNRESOLVED / CATALOG_ABSENT
  local catalog_path=""
  if [ -n "$catalog_override" ]; then
    [ -f "$catalog_override" ] && catalog_path="$catalog_override"
  elif declare -f resolve_test_user_catalog >/dev/null 2>&1; then
    catalog_path=$(resolve_test_user_catalog 2>/dev/null) || catalog_path=""
  fi

  local test_user_class="advisory"
  [ "$strict_catalog" = "true" ] && test_user_class="hard"
  local test_user_resolved_state="inapplicable"

  if [ "$backend_only" != "true" ] && _has_section_test_user "$body"; then
    if [ -z "$catalog_path" ]; then
      _dor_record "CATALOG_ABSENT" "true" "informational" "no test-user catalog resolved on this host"
      _dor_record "TEST_USER_UNRESOLVED" "null" "unevaluated" "CATALOG_ABSENT"
      test_user_resolved_state="unevaluated"
    else
      if _dor_test_user_resolves "$body" "$catalog_path"; then
        _dor_record "TEST_USER_UNRESOLVED" "false" "$test_user_class" "test user resolves against catalog"
        test_user_resolved_state="resolved"
      else
        _dor_record "TEST_USER_UNRESOLVED" "true" "$test_user_class" "test user does not resolve against catalog"
        test_user_resolved_state="unresolved"
        if [ "$strict_catalog" = "true" ]; then
          missing+=("TEST_USER_UNRESOLVED")
        else
          advisory+=("TEST_USER_UNRESOLVED")
        fi
      fi
    fi
  else
    _dor_record "TEST_USER_UNRESOLVED" "null" "inapplicable" "no Test User section to resolve"
  fi

  # TEST_DATA_MISSING / TEST_DATA_UNSEEDED
  local test_data_class="advisory"
  [ "$strict_test_data" = "true" ] && test_data_class="hard"

  local test_data_state
  test_data_state=$(_dor_test_data_state "$body")
  case "$test_data_state" in
  missing)
    _dor_record "TEST_DATA_MISSING" "true" "$test_data_class" "no Test Data section found"
    _dor_record "TEST_DATA_UNSEEDED" "null" "inapplicable" "TEST_DATA_MISSING already covers this"
    if [ "$strict_test_data" = "true" ]; then
      missing+=("TEST_DATA_MISSING")
    else
      advisory+=("TEST_DATA_MISSING")
    fi
    ;;
  unseeded)
    _dor_record "TEST_DATA_MISSING" "false" "$test_data_class" "Test Data section present"
    _dor_record "TEST_DATA_UNSEEDED" "true" "$test_data_class" "Test Data section has no concrete detail"
    if [ "$strict_test_data" = "true" ]; then
      missing+=("TEST_DATA_UNSEEDED")
    else
      advisory+=("TEST_DATA_UNSEEDED")
    fi
    ;;
  *)
    _dor_record "TEST_DATA_MISSING" "false" "$test_data_class" "Test Data section present"
    _dor_record "TEST_DATA_UNSEEDED" "false" "$test_data_class" "Test Data section has concrete detail"
    ;;
  esac

  DOR_MISSING=$(_dor_json_array "${missing[@]}")
  DOR_ADVISORY=$(_dor_json_array "${advisory[@]}")

  # ── Diagnostic score, dimensions, gaps (dor-quality-score) — computed
  # after every hard/advisory code so the score never influences DOR_STATUS
  # below, only reflects it. ────────────────────────────────────────────────
  _dor_score
  _dor_gaps

  if [ "${#missing[@]}" -eq 0 ]; then
    DOR_STATUS="ready"
    return 0
  fi
  DOR_STATUS="not-ready"
  return 1
}

# ensure_ticket_readiness <TID> [--body <file>] [--type <type>]
# The self-healing resolution path (design.md Decision 3). Trusts and
# returns a cached `ready` object when it is still fresh; computes and
# caches a live verdict when none exists yet, or when the cached object's
# body_hash no longer matches a locally-resolvable body (dor-quality-score
# design.md Decision 7). Only a concrete ready/not-ready verdict is ever
# cached — an `unavailable` live result (no body resolvable) is returned
# as-is without writing, since set_ticket_readiness only accepts
# ready|not-ready and a transient "no body yet" state deserves another
# attempt later, not a frozen cache entry.
ensure_ticket_readiness() {
  local tid="$1"
  shift || true
  local body_file="" type_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --body)
      body_file="${2:-}"
      shift 2
      ;;
    --type)
      type_override="${2:-}"
      shift 2
      ;;
    *) shift ;;
    esac
  done

  DOR_STATUS="unavailable"
  DOR_MISSING="[]"
  DOR_ADVISORY="[]"
  DOR_SCORE=""
  DOR_DIMENSIONS=""
  DOR_GAPS=""
  DOR_SEMANTIC=""

  local ready_json rc=0
  ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null) || rc=$?

  if [ "$rc" -eq 0 ] && [ -n "$ready_json" ]; then
    # Local-only body resolution (Decision 7) — --body file, then planner
    # body.md; NEVER a live tracker fetch on a cache hit (that would add a
    # Linear read to every fleet dispatch tick).
    local local_body="" local_body_path="" pdir=""
    if [ -n "$body_file" ] && [ -f "$body_file" ]; then
      local_body=$(cat "$body_file" 2>/dev/null || true)
      local_body_path="$body_file"
    elif declare -f resolve_planner_dir >/dev/null 2>&1; then
      pdir=$(resolve_planner_dir "$tid" 2>/dev/null) || true
      if [ -n "$pdir" ] && [ -f "$pdir/body.md" ]; then
        local_body=$(cat "$pdir/body.md" 2>/dev/null || true)
        local_body_path="$pdir/body.md"
      fi
    fi

    local cached_hash
    cached_hash=$(echo "$ready_json" | jq -r '.body_hash // ""' 2>/dev/null) || cached_hash=""

    local recompute="false"
    if [ -n "$local_body" ] && [ -n "$cached_hash" ]; then
      local fresh_hash
      fresh_hash=$(_dor_body_hash "$local_body")
      if [ -n "$fresh_hash" ] && [ "$fresh_hash" != "$cached_hash" ]; then
        recompute="true"
      fi
    fi

    if [ "$recompute" = "true" ]; then
      local extra_args=(--body "$local_body_path" --no-fetch)
      [ -n "$type_override" ] && extra_args+=(--type "$type_override")

      local check_rc=0
      check_ticket_ready "$tid" "${extra_args[@]}" || check_rc=$?

      case "$DOR_STATUS" in
      ready | not-ready)
        local extras
        extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
          --argjson gaps "${DOR_GAPS:-null}" --arg hash "${DOR_BODY_HASH:-}" \
          '{score: $score, dimensions: $dims, gaps: $gaps} + (if $hash != "" then {body_hash: $hash} else {} end)')
        set_ticket_readiness "$tid" "$DOR_STATUS" "$DOR_MISSING" "$DOR_ADVISORY" "$extras" >/dev/null 2>&1 || true
        # set_ticket_readiness recomputes `status` against the manifest's
        # preserved `ready.waived` — a status this function's own caller
        # never sees unless it re-reads the write. Without this, a waiver
        # covering the only fresh failure would write status:"ready" to the
        # manifest while this call still reported/returned not-ready.
        local rewritten
        rewritten=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
        if [ -n "$rewritten" ]; then
          DOR_STATUS=$(echo "$rewritten" | jq -r '.status // "unavailable"' 2>/dev/null) || true
          DOR_SEMANTIC=$(echo "$rewritten" | jq -c 'if has("semantic") then .semantic else empty end' 2>/dev/null) || DOR_SEMANTIC=""
          [ "$DOR_STATUS" = "ready" ] && check_rc=0 || check_rc=1
        fi
        ;;
      esac
      return "$check_rc"
    fi

    # No local body, hash matches, or legacy cache with no hash — trust the
    # cached verdict as-is.
    DOR_STATUS=$(echo "$ready_json" | jq -r '.status // "unavailable"' 2>/dev/null) || DOR_STATUS="unavailable"
    DOR_MISSING=$(echo "$ready_json" | jq -c '.missing // []' 2>/dev/null) || DOR_MISSING="[]"
    DOR_ADVISORY=$(echo "$ready_json" | jq -c '.advisory // []' 2>/dev/null) || DOR_ADVISORY="[]"
    DOR_SCORE=$(echo "$ready_json" | jq -r 'if has("score") then (.score | tostring) else empty end' 2>/dev/null) || DOR_SCORE=""
    DOR_DIMENSIONS=$(echo "$ready_json" | jq -c 'if has("dimensions") then .dimensions else empty end' 2>/dev/null) || DOR_DIMENSIONS=""
    DOR_GAPS=$(echo "$ready_json" | jq -c 'if has("gaps") then .gaps else empty end' 2>/dev/null) || DOR_GAPS=""
    DOR_SEMANTIC=$(echo "$ready_json" | jq -c 'if has("semantic") then .semantic else empty end' 2>/dev/null) || DOR_SEMANTIC=""
    [ "$DOR_STATUS" = "ready" ] && return 0
    return 1
  fi

  # rc==2/3 (malformed manifest / usage error) resolves the same as no cache
  # at all: compute live below rather than propagating an opaque failure —
  # the live computation either succeeds (and caches, if a manifest path
  # resolves) or itself reports unavailable.

  local extra_args=()
  [ -n "$body_file" ] && extra_args+=(--body "$body_file")
  [ -n "$type_override" ] && extra_args+=(--type "$type_override")

  local check_rc=0
  check_ticket_ready "$tid" "${extra_args[@]}" || check_rc=$?

  case "$DOR_STATUS" in
  ready | not-ready)
    local extras
    extras=$(jq -nc --argjson score "${DOR_SCORE:-null}" --argjson dims "${DOR_DIMENSIONS:-null}" \
      --argjson gaps "${DOR_GAPS:-null}" --arg hash "${DOR_BODY_HASH:-}" \
      '{score: $score, dimensions: $dims, gaps: $gaps} + (if $hash != "" then {body_hash: $hash} else {} end)')
    set_ticket_readiness "$tid" "$DOR_STATUS" "$DOR_MISSING" "$DOR_ADVISORY" "$extras" >/dev/null 2>&1 || true
    # A manifest that already carried a semantic verdict (e.g. rc==2/3
    # malformed-manifest fallback above) keeps or stales it per
    # set_ticket_readiness's own preserve/stale rule — re-read it so this
    # path exports DOR_SEMANTIC exactly like the other two return paths.
    local _rewritten2
    _rewritten2=$(get_ticket_manifest_field "$tid" ready 2>/dev/null)
    [ -n "$_rewritten2" ] &&
      DOR_SEMANTIC=$(echo "$_rewritten2" | jq -c 'if has("semantic") then .semantic else empty end' 2>/dev/null) || DOR_SEMANTIC=""
    ;;
  esac

  return "$check_rc"
}

# ── CLI (direct execution only) ──────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--waive" ]; then
  shift
  _WAIVE_TID="${1:-}"
  _WAIVE_CODE="${2:-}"
  _WAIVE_REASON="${3:-}"
  shift 3 2>/dev/null || true
  _WAIVE_BY="operator"
  while [ $# -gt 0 ]; do
    case "$1" in
    --by)
      _WAIVE_BY="${2:-operator}"
      shift 2
      ;;
    *) shift ;;
    esac
  done

  if [ -z "$_WAIVE_TID" ] || [ -z "$_WAIVE_CODE" ] || [ -z "$_WAIVE_REASON" ]; then
    echo "usage: dor-check.sh --waive <TID> <CODE> <reason> [--by <name>]" >&2
    exit 1
  fi

  if ! waive_ticket_readiness_code "$_WAIVE_TID" "$_WAIVE_CODE" "$_WAIVE_BY" "$_WAIVE_REASON"; then
    echo "dor-check: failed to record waiver for $_WAIVE_TID $_WAIVE_CODE" >&2
    exit 1
  fi

  _WAIVE_STATUS=$(get_ticket_manifest_field "$_WAIVE_TID" ready 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null)
  echo "$_WAIVE_TID: $_WAIVE_CODE waived by $_WAIVE_BY — status now $_WAIVE_STATUS"
  exit 0
fi
