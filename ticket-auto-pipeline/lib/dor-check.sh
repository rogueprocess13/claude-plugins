#!/usr/bin/env bash
# dor-check.sh — the Definition of Ready readiness check (dor-readiness-gate-
# foundation). Sourceable bash library. Does NOT set -euo pipefail at file
# scope (caller controls error handling) — matching planned-ticket-body-
# check.sh's convention, since gate-check.sh and fleet-dispatch.sh both
# source this file and neither may have its own errexit/pipefail settings
# perturbed by doing so.
#
# Evaluates a ticket's readiness from its body alone — no tracker mutation,
# no model invocation. See design.md and
# openspec/changes/dor-readiness-gate-foundation/specs/ticket-readiness-gate/
# spec.md for the full decision record; this file implements Decisions 1-4
# and 6-11's `check_ticket_ready`/`ensure_ticket_readiness`/`--waive` surface.
#
# Public API:
#   check_ticket_ready <TID> [--body <file>] [--type <type>]
#                       [--catalog <file>] [--no-fetch]
#     Sets DOR_STATUS (ready|not-ready|unavailable), DOR_MISSING (JSON array
#     of failing hard codes), DOR_ADVISORY (JSON array of failing advisory
#     codes), DOR_CHECKS (JSON object: code -> {pass, class, detail}).
#     Exit 0 ready, 1 not-ready, 2 unavailable (no body could be resolved).
#
#   ensure_ticket_readiness <TID> [--body <file>] [--type <type>]
#     The single resolution path every consumer of readiness should use
#     instead of a raw manifest read (design.md Decision 3 — self-healing
#     cache). Returns the manifest's cached `ready` verdict if present;
#     otherwise computes live via check_ticket_ready and caches the result
#     via set_ticket_readiness before returning it. Sets the same
#     DOR_STATUS/DOR_MISSING/DOR_ADVISORY globals. Exit 0 ready, 1 not-ready,
#     2 unavailable/uncacheable.
#
#   dor-check.sh --waive <TID> <CODE> <reason> [--by <name>]
#     CLI-only (direct execution): wraps waive_ticket_readiness_code and
#     prints the resulting status. The minimal operator escape hatch for a
#     hard-code false positive (design.md Decision 2's revision).
#
# Hard codes (decide ready/not-ready): SCOPE_MISSING, NAV_PATH_MISSING,
# TEST_USER_MISSING, AC_MISSING, AC_VAGUE, REPRO_MISSING, FLAG_NEEDS_INFO.
# Advisory codes (reported, never block): TEST_USER_UNRESOLVED,
# TEST_DATA_MISSING, TEST_DATA_UNSEEDED, VPLAN_MISSING, VPLAN_ROW_GAP,
# VPLAN_UNVERIFIABLE. DOR_STRICT_CATALOG/DOR_STRICT_TEST_DATA (both default
# false) promote the catalog/test-data advisory codes to hard.

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

  local type body
  type=$(_dor_resolve_type "$tid" "$type_override")
  body=$(_dor_resolve_body "$tid" "$body_file" "$no_fetch")

  if [ -z "$body" ]; then
    DOR_STATUS="unavailable"
    return 2
  fi

  local missing=() advisory=()
  local strict_catalog="${DOR_STRICT_CATALOG:-false}"
  local strict_test_data="${DOR_STRICT_TEST_DATA:-false}"

  # ── Scope + structural hard codes ────────────────────────────────────────
  local backend_only="false"
  if _scope_is_backend_only "$body"; then
    backend_only="true"
  fi

  if _has_section_scope "$body"; then
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

  if [ "$backend_only" = "true" ]; then
    _dor_record "TEST_USER_MISSING" "null" "inapplicable" "backend-only scope"
    _dor_record "NAV_PATH_MISSING" "null" "inapplicable" "backend-only scope"
  else
    if _has_section_test_user "$body"; then
      _dor_record "TEST_USER_MISSING" "false" "hard" "Test User section present"
    else
      missing+=("TEST_USER_MISSING")
      _dor_record "TEST_USER_MISSING" "true" "hard" "no Test User section found"
    fi

    if _has_section_nav_path "$body"; then
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

  # AC_VAGUE — audit_ac_testability also echoes its VAGUE_AC_COUNT/... to
  # stdout as a side effect (its own established output contract); redirect
  # that away so it never pollutes this function's caller.
  audit_ac_testability "$body" >/dev/null 2>&1 || true
  if [ "${VAGUE_AC_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    missing+=("AC_VAGUE")
    _dor_record "AC_VAGUE" "true" "hard" "${VAGUE_AC_COUNT} vague acceptance criteria: ${VAGUE_ACS}"
  else
    _dor_record "AC_VAGUE" "false" "hard" "no vague acceptance criteria detected"
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

  if [ "$backend_only" != "true" ] && _has_section_test_user "$body"; then
    if [ -z "$catalog_path" ]; then
      _dor_record "CATALOG_ABSENT" "true" "informational" "no test-user catalog resolved on this host"
      _dor_record "TEST_USER_UNRESOLVED" "null" "unevaluated" "CATALOG_ABSENT"
    else
      if _dor_test_user_resolves "$body" "$catalog_path"; then
        _dor_record "TEST_USER_UNRESOLVED" "false" "$test_user_class" "test user resolves against catalog"
      else
        _dor_record "TEST_USER_UNRESOLVED" "true" "$test_user_class" "test user does not resolve against catalog"
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

  # VPLAN_MISSING / VPLAN_ROW_GAP / VPLAN_UNVERIFIABLE
  if declare -f vplan_parse >/dev/null 2>&1 && vplan_parse "$body" 2>/dev/null; then
    _dor_record "VPLAN_MISSING" "false" "advisory" "Verification Plan table present"

    if [ "${VPLAN_VERIFIABLE:-0}" -eq 0 ] 2>/dev/null; then
      advisory+=("VPLAN_UNVERIFIABLE")
      _dor_record "VPLAN_UNVERIFIABLE" "true" "advisory" "no criteria marked verifiable in the table"
    else
      _dor_record "VPLAN_UNVERIFIABLE" "false" "advisory" "${VPLAN_VERIFIABLE} criteria marked verifiable"
    fi

    local ac_count
    ac_count=$(_dor_ac_count "$body")
    if [ "$ac_count" -gt 0 ] 2>/dev/null && [ "${VPLAN_ROWS:-0}" -lt "$ac_count" ] 2>/dev/null; then
      advisory+=("VPLAN_ROW_GAP")
      _dor_record "VPLAN_ROW_GAP" "true" "advisory" "${VPLAN_ROWS} table rows vs ${ac_count} acceptance criteria"
    else
      _dor_record "VPLAN_ROW_GAP" "false" "advisory" "table rows cover acceptance criteria count"
    fi
  else
    advisory+=("VPLAN_MISSING")
    _dor_record "VPLAN_MISSING" "true" "advisory" "no Verification Plan table found"
    _dor_record "VPLAN_ROW_GAP" "null" "inapplicable" "VPLAN_MISSING already covers this"
    _dor_record "VPLAN_UNVERIFIABLE" "null" "inapplicable" "VPLAN_MISSING already covers this"
  fi

  DOR_MISSING=$(_dor_json_array "${missing[@]}")
  DOR_ADVISORY=$(_dor_json_array "${advisory[@]}")

  if [ "${#missing[@]}" -eq 0 ]; then
    DOR_STATUS="ready"
    return 0
  fi
  DOR_STATUS="not-ready"
  return 1
}

# ensure_ticket_readiness <TID> [--body <file>] [--type <type>]
# The self-healing resolution path (design.md Decision 3). Trusts and
# returns a cached `ready` object verbatim; computes and caches a live
# verdict when none exists yet. Only a concrete ready/not-ready verdict is
# ever cached — an `unavailable` live result (no body resolvable) is
# returned as-is without writing, since set_ticket_readiness only accepts
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

  local ready_json rc=0
  ready_json=$(get_ticket_manifest_field "$tid" ready 2>/dev/null) || rc=$?

  if [ "$rc" -eq 0 ] && [ -n "$ready_json" ]; then
    DOR_STATUS=$(echo "$ready_json" | jq -r '.status // "unavailable"' 2>/dev/null) || DOR_STATUS="unavailable"
    DOR_MISSING=$(echo "$ready_json" | jq -c '.missing // []' 2>/dev/null) || DOR_MISSING="[]"
    DOR_ADVISORY=$(echo "$ready_json" | jq -c '.advisory // []' 2>/dev/null) || DOR_ADVISORY="[]"
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
    set_ticket_readiness "$tid" "$DOR_STATUS" "$DOR_MISSING" "$DOR_ADVISORY" >/dev/null 2>&1 || true
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
