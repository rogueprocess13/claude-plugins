#!/usr/bin/env bash
# dor-semantic-parse.sh — deterministic parser for the `=== DOR_SEMANTIC_SCAN
# ===` and `=== DOR_SEMANTIC_AUDIT ===` blocks agents/dor-semantic-agent.md
# writes to its result file (dor-semantic-evaluator).
#
# Adapted from adr-gate-parse.sh/human-hold-parse.sh (docs/dor-semantic-
# schema.md mirrors their tolerant-transport/strict-contract framing).
# Unlike human-hold, a scan/audit run is REQUIRED to produce a usable block —
# there is no "absent block is a normal outcome" case: absent is bucketed
# with every other invalid block, exit 1.
#
# Tolerant at the transport boundary (whitespace, CRLF, blank lines, field
# order, unknown fields, a claude -p json|stream-json envelope). Strict at
# the contract boundary (required fields, closed enums, SCHEMA_VERSION
# equality, duplicate keys, the quote/gap/audit cross-field rules in
# docs/dor-semantic-schema.md). Writes NO pipeline log line — the caller
# owns its own log grammar.
#
# Exit codes:
#   0 — a valid block was parsed (parse_status=ok).
#   1 — no usable block: absent, malformed, or contract-violating
#       (parse_status=invalid). Canonical JSON is still printed on stdout.
#   2 — the parser could not run (usage, unreadable file, jq missing).
#
# Sourceable lib (`parse_dor_semantic`) and standalone CLI.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
#
# Deliberate deviation from adr-gate-parse.sh/human-hold-parse.sh (design.md
# Decision 7): `set -eo pipefail` is scoped to the BASH_SOURCE==$0 CLI block
# only, NOT file scope — sourcing this file never enables errexit in the
# caller.

DOR_SEMANTIC_PARSE_SCHEMA_VERSION=1

_DSP_SCAN_OPEN="=== DOR_SEMANTIC_SCAN ==="
_DSP_SCAN_CLOSE="=== END DOR_SEMANTIC_SCAN ==="
_DSP_AUDIT_OPEN="=== DOR_SEMANTIC_AUDIT ==="
_DSP_AUDIT_CLOSE="=== END DOR_SEMANTIC_AUDIT ==="

# Kept in sync with dor-semantic.sh's DOR_SEMANTIC_CODES, but self-contained
# — a caller that only needs the parser is not forced to pull in
# dor-check.sh/manifest-write.sh's heavier dependency chain.
_DSP_KNOWN_CODES="MISSING_CORE_AC NEEDS_HUMAN_DECISION INTENT_AC_MISMATCH CONTRADICTORY_REQUIREMENTS SCOPE_AMBIGUOUS EDGE_CASE_GAP UNSTATED_DEPENDENCY AC_NOT_TESTABLE"

_DSP_GAP_NAMES="REQUIREMENT_COMPLETENESS CONTRADICTORY_REQUIREMENTS DEEP_SCOPE_AMBIGUITY EDGE_CASE_SUFFICIENCY"
_DSP_GAP_VERDICTS="clear finding not-applicable"
_DSP_AUDIT_VERDICTS="agree disputed uncertain"

_dsp_code_dimension() {
  case "$1" in
  MISSING_CORE_AC | NEEDS_HUMAN_DECISION) echo "requirement_completeness" ;;
  INTENT_AC_MISMATCH) echo "intent" ;;
  CONTRADICTORY_REQUIREMENTS) echo "acceptance_criteria" ;;
  SCOPE_AMBIGUOUS) echo "scope" ;;
  EDGE_CASE_GAP) echo "edge_cases" ;;
  UNSTATED_DEPENDENCY) echo "dependencies" ;;
  AC_NOT_TESTABLE) echo "verification" ;;
  esac
}

_dsp_in_list() {
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Same C-collation forcing as human-hold-parse.sh's _hh_key_ok — bracket
# expressions are locale-sensitive under a UTF-8 locale.
_dsp_key_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

# Same redaction as human-hold-parse.sh's _hh_redact, reimplemented rather
# than sourced (this file must stay independently sourceable).
_dsp_redact() {
  local text="$1"
  printf '%s' "$text" | sed -E \
    -e 's/(gh[pousr]_)[A-Za-z0-9]{20,}/\1***REDACTED***/g' \
    -e 's/(xox[abp]-)[A-Za-z0-9-]+/\1***REDACTED***/g' \
    -e 's/(sk-)[A-Za-z0-9]{20,}/\1***REDACTED***/g' \
    -e 's/AKIA[0-9A-Z]{16}/***REDACTED***/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/***REDACTED***/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._-]{10,}/\1***REDACTED***/g' \
    -e 's/((api[_-]?key|token|secret|password|credential)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+/\1***REDACTED***/gI'
}

# Same envelope-unwrap as adr-gate-parse.sh's _agp_unwrap/human-hold-parse.
# sh's _hh_unwrap: reduces a `claude -p --output-format json|stream-json`
# capture to the return text before line-oriented extraction ever runs.
_dsp_unwrap() {
  local file="$1" out
  out=$(jq -r 'if type == "object" and (.result | type) == "string"
               then .result else empty end' <"$file" 2>/dev/null) || out=""
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  out=$(jq -sr '[.[] | select(type == "object" and (.result | type) == "string")
                | .result] | last // empty' <"$file" 2>/dev/null) || out=""
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  cat -- "$file"
}

_dsp_usage() {
  cat >&2 <<'EOF'
Usage: dor-semantic-parse.sh --kind scan|audit --result-file <path> [--det-result <path>]

  --kind scan|audit      Which block to extract. Required.
  --result-file <path>   Captured agent return text. Required.
  --det-result <path>    JSON file with {"missing": [...], "advisory": [...]}
                         (the deterministic check's own arrays). Audit only —
                         enables the "every hard code audited" contract check.
                         Omit to skip that check.

Exit: 0 valid block, 1 no usable block (absent/malformed/contract violation
— still prints JSON), 2 parser could not run.
EOF
}

# extract_block <kind> <text>
# Prints the last complete block's body (or nothing) and returns via globals
# _DSP_EXTRACT_RC (0 found, 3 unclosed-with-no-prior-close, 4 absent).
_dsp_extract_block() {
  local kind="$1" text="$2"
  local mopen mclose
  if [ "$kind" = "scan" ]; then
    mopen="$_DSP_SCAN_OPEN"
    mclose="$_DSP_SCAN_CLOSE"
  else
    mopen="$_DSP_AUDIT_OPEN"
    mclose="$_DSP_AUDIT_CLOSE"
  fi
  local rc=0
  _DSP_EXTRACTED=$(printf '%s' "$text" | tr -d '\r' | awk -v mopen="$mopen" -v mclose="$mclose" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    trim($0) == mopen  { collecting = 1; buf = ""; next }
    collecting && trim($0) == mclose { collecting = 0; closed = 1; last = buf; next }
    collecting { buf = buf $0 "\n"; next }
    END {
      if (closed)     { printf "%s", last; exit 0 }
      if (collecting) { exit 3 }
      exit 4
    }
  ') || rc=$?
  _DSP_EXTRACT_RC="$rc"
}

# parse_dor_semantic --kind scan|audit --result-file <f> [--det-result <f>]
parse_dor_semantic() {
  local kind="" result_file="" det_result=""

  while [ $# -gt 0 ]; do
    case "$1" in
    --kind)
      kind="${2:-}"
      shift 2
      ;;
    --result-file)
      result_file="${2:-}"
      shift 2
      ;;
    --det-result)
      det_result="${2:-}"
      shift 2
      ;;
    -h | --help)
      _dsp_usage
      return 2
      ;;
    *)
      echo "[dor-semantic-parse] ERROR: unknown argument '$1'" >&2
      _dsp_usage
      return 2
      ;;
    esac
  done

  case "$kind" in
  scan | audit) ;;
  *)
    echo "[dor-semantic-parse] ERROR: --kind must be 'scan' or 'audit', got '${kind}'" >&2
    _dsp_usage
    return 2
    ;;
  esac

  if [ -z "$result_file" ]; then
    echo "[dor-semantic-parse] ERROR: --result-file is required" >&2
    _dsp_usage
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[dor-semantic-parse] ERROR: jq not available" >&2
    return 2
  fi

  if [ ! -f "$result_file" ]; then
    echo "[dor-semantic-parse] ERROR: result file not found: $result_file" >&2
    return 2
  fi

  if [ -n "$det_result" ] && [ ! -f "$det_result" ]; then
    echo "[dor-semantic-parse] ERROR: det-result file not found: $det_result" >&2
    return 2
  fi

  local status="ok" err=""

  # ── extract ────────────────────────────────────────────────────────────
  local unwrapped
  unwrapped=$(_dsp_unwrap "$result_file")
  _dsp_extract_block "$kind" "$unwrapped"

  local body="$_DSP_EXTRACTED"
  case "$_DSP_EXTRACT_RC" in
  0) ;;
  3)
    status="invalid"
    err="missing closing marker"
    ;;
  4)
    status="invalid"
    err="no DOR_SEMANTIC_${kind^^} block in return"
    ;;
  *)
    status="invalid"
    err="block extraction failed (awk exit ${_DSP_EXTRACT_RC})"
    ;;
  esac

  if [ "$status" = "ok" ] && [ -z "${body//[[:space:]]/}" ]; then
    status="invalid"
    err="empty block"
  fi

  # ── parse KEY: value lines ────────────────────────────────────────────
  local -A fields=()
  if [ "$status" = "ok" ]; then
    local seen_keys=""
    local line key value
    while IFS= read -r line; do
      [ -z "${line//[[:space:]]/}" ] && continue

      if [[ "$line" != *:* ]]; then
        status="invalid"
        err="malformed line (no ':'): ${line}"
        break
      fi

      key="${line%%:*}"
      value="${line#*:}"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"

      if ! _dsp_key_ok "$key"; then
        status="invalid"
        err="key '${key}' does not match [A-Z][A-Z0-9_]*"
        break
      fi

      if _dsp_in_list "$key" "$seen_keys"; then
        status="invalid"
        err="duplicate field: ${key}"
        break
      fi
      seen_keys="$seen_keys $key"

      fields["$key"]="$value"
    done <<<"$body"
  fi

  # ── validate top-level fields ─────────────────────────────────────────
  if [ "$status" = "ok" ]; then
    local f _required="SCHEMA_VERSION TICKET BODY_HASH"
    [ "$kind" = "audit" ] && _required="$_required SCORE_PLAUSIBLE SCORE_REASON"
    for f in $_required; do
      if [ -z "${fields[$f]+set}" ] || [ -z "${fields[$f]}" ]; then
        status="invalid"
        err="missing required field: ${f}"
        break
      fi
    done
  fi

  if [ "$status" = "ok" ] && [ "${fields[SCHEMA_VERSION]}" != "$DOR_SEMANTIC_PARSE_SCHEMA_VERSION" ]; then
    status="invalid"
    err="unsupported SCHEMA_VERSION: ${fields[SCHEMA_VERSION]} (parser supports ${DOR_SEMANTIC_PARSE_SCHEMA_VERSION})"
  fi

  if [ "$status" = "ok" ] && [ "$kind" = "audit" ] &&
    [ "${fields[SCORE_PLAUSIBLE]}" != "yes" ] && [ "${fields[SCORE_PLAUSIBLE]}" != "no" ]; then
    status="invalid"
    err="SCORE_PLAUSIBLE must be 'yes' or 'no', got '${fields[SCORE_PLAUSIBLE]}'"
  fi

  local findings_json="[]" gaps_json="{}" audit_json="[]" missed_json="[]"

  # ── scan: findings + gaps ─────────────────────────────────────────────
  if [ "$status" = "ok" ] && [ "$kind" = "scan" ]; then
    local -A _fidx_seen=()
    local key
    for key in "${!fields[@]}"; do
      if [[ "$key" =~ ^FINDING_([1-9][0-9]*)_CODE$ ]]; then
        _fidx_seen["${BASH_REMATCH[1]}"]=1
      fi
    done
    local -a _findices=()
    if [ "${#_fidx_seen[@]}" -gt 0 ]; then
      mapfile -t _findices < <(printf '%s\n' "${!_fidx_seen[@]}" | sort -n)
    fi

    local jq_args=() filter="[" first=1 idx code quote quote_b detail dim
    for idx in "${_findices[@]}"; do
      code="${fields[FINDING_${idx}_CODE]:-}"
      quote="${fields[FINDING_${idx}_QUOTE]:-}"
      quote_b="${fields[FINDING_${idx}_QUOTE_B]:-}"
      detail="${fields[FINDING_${idx}_DETAIL]:-}"

      if ! _dsp_in_list "$code" "$_DSP_KNOWN_CODES"; then
        status="invalid"
        err="FINDING_${idx}_CODE '${code}' is not a known code"
        break
      fi
      if [ -z "$quote" ]; then
        status="invalid"
        err="FINDING_${idx} missing QUOTE"
        break
      fi
      if [ "$code" = "CONTRADICTORY_REQUIREMENTS" ] && [ -z "$quote_b" ]; then
        status="invalid"
        err="FINDING_${idx} (CONTRADICTORY_REQUIREMENTS) missing QUOTE_B"
        break
      fi

      dim=$(_dsp_code_dimension "$code")
      detail=$(_dsp_redact "$detail")

      jq_args+=(--arg "code${idx}" "$code" --arg "dim${idx}" "$dim"
        --arg "quote${idx}" "$quote" --arg "quoteb${idx}" "$quote_b"
        --arg "detail${idx}" "$detail")
      [ "$first" -eq 1 ] || filter="$filter,"
      first=0
      filter="$filter{code:\$code${idx},dimension:\$dim${idx},quote:\$quote${idx},quote_b:(if \$quoteb${idx}==\"\" then null else \$quoteb${idx} end),detail:\$detail${idx}}"
    done
    filter="$filter]"

    if [ "$status" = "ok" ]; then
      findings_json=$(jq -nc "${jq_args[@]}" "$filter" 2>/dev/null) || findings_json="[]"
    fi

    if [ "$status" = "ok" ]; then
      local g_jq_args=() g_filter="{" g_first=1 g verdict reason gkey
      for g in $_DSP_GAP_NAMES; do
        verdict="${fields[GAP_${g}]:-}"
        reason="${fields[GAP_${g}_REASON]:-}"
        if [ -z "$verdict" ]; then
          status="invalid"
          err="missing GAP_${g}"
          break
        fi
        if ! _dsp_in_list "$verdict" "$_DSP_GAP_VERDICTS"; then
          status="invalid"
          err="GAP_${g} verdict '${verdict}' is not in the closed set ($_DSP_GAP_VERDICTS)"
          break
        fi
        if [ -z "$reason" ]; then
          status="invalid"
          err="missing GAP_${g}_REASON"
          break
        fi
        gkey=$(printf '%s' "$g" | tr '[:upper:]' '[:lower:]')
        reason=$(_dsp_redact "$reason")
        g_jq_args+=(--arg "v_${g}" "$verdict" --arg "r_${g}" "$reason")
        [ "$g_first" -eq 1 ] || g_filter="$g_filter,"
        g_first=0
        g_filter="$g_filter\"${gkey}\":{verdict:\$v_${g},reason:\$r_${g}}"
      done
      g_filter="$g_filter}"
      if [ "$status" = "ok" ]; then
        gaps_json=$(jq -nc "${g_jq_args[@]}" "$g_filter" 2>/dev/null) || gaps_json="{}"
      fi
    fi
  fi

  # ── audit: audit entries + missed + det-result cross-check ────────────
  if [ "$status" = "ok" ] && [ "$kind" = "audit" ]; then
    local -A _aidx_seen=() _midx_seen=()
    local key
    for key in "${!fields[@]}"; do
      if [[ "$key" =~ ^AUDIT_([1-9][0-9]*)_CODE$ ]]; then
        _aidx_seen["${BASH_REMATCH[1]}"]=1
      elif [[ "$key" =~ ^MISSED_([1-9][0-9]*)_CODE$ ]]; then
        _midx_seen["${BASH_REMATCH[1]}"]=1
      fi
    done
    local -a _aindices=() _mindices=()
    [ "${#_aidx_seen[@]}" -gt 0 ] && mapfile -t _aindices < <(printf '%s\n' "${!_aidx_seen[@]}" | sort -n)
    [ "${#_midx_seen[@]}" -gt 0 ] && mapfile -t _mindices < <(printf '%s\n' "${!_midx_seen[@]}" | sort -n)

    local jq_args=() filter="[" first=1 idx code verdict reason
    local audited_codes=""
    for idx in "${_aindices[@]}"; do
      code="${fields[AUDIT_${idx}_CODE]:-}"
      verdict="${fields[AUDIT_${idx}_VERDICT]:-}"
      reason="${fields[AUDIT_${idx}_REASON]:-}"

      if [ -z "$code" ]; then
        status="invalid"
        err="AUDIT_${idx} missing CODE"
        break
      fi
      if ! _dsp_in_list "$verdict" "$_DSP_AUDIT_VERDICTS"; then
        status="invalid"
        err="AUDIT_${idx}_VERDICT '${verdict}' is not in the closed set ($_DSP_AUDIT_VERDICTS)"
        break
      fi
      if [ "$verdict" = "disputed" ] && [ -z "$reason" ]; then
        status="invalid"
        err="AUDIT_${idx} verdict 'disputed' requires a non-empty REASON"
        break
      fi

      audited_codes="$audited_codes $code"
      reason=$(_dsp_redact "$reason")
      jq_args+=(--arg "code${idx}" "$code" --arg "verdict${idx}" "$verdict" --arg "reason${idx}" "$reason")
      [ "$first" -eq 1 ] || filter="$filter,"
      first=0
      filter="$filter{code:\$code${idx},verdict:\$verdict${idx},reason:\$reason${idx}}"
    done
    filter="$filter]"
    if [ "$status" = "ok" ]; then
      audit_json=$(jq -nc "${jq_args[@]}" "$filter" 2>/dev/null) || audit_json="[]"
    fi

    if [ "$status" = "ok" ]; then
      local m_jq_args=() m_filter="[" m_first=1 mcode mreason
      for idx in "${_mindices[@]}"; do
        mcode="${fields[MISSED_${idx}_CODE]:-}"
        mreason="${fields[MISSED_${idx}_REASON]:-}"
        if [ -z "$mcode" ] || [ -z "$mreason" ]; then
          status="invalid"
          err="MISSED_${idx} requires both CODE and REASON"
          break
        fi
        mreason=$(_dsp_redact "$mreason")
        m_jq_args+=(--arg "code${idx}" "$mcode" --arg "reason${idx}" "$mreason")
        [ "$m_first" -eq 1 ] || m_filter="$m_filter,"
        m_first=0
        m_filter="$m_filter{code:\$code${idx},reason:\$reason${idx}}"
      done
      m_filter="$m_filter]"
      if [ "$status" = "ok" ]; then
        missed_json=$(jq -nc "${m_jq_args[@]}" "$m_filter" 2>/dev/null) || missed_json="[]"
      fi
    fi

    # ── det-result cross-check: every hard code in `missing` audited ────
    if [ "$status" = "ok" ] && [ -n "$det_result" ]; then
      local det_missing hc
      det_missing=$(jq -r '.missing // [] | .[]' "$det_result" 2>/dev/null) || det_missing=""
      while IFS= read -r hc; do
        [ -z "$hc" ] && continue
        if ! _dsp_in_list "$hc" "$audited_codes"; then
          status="invalid"
          err="hard code '${hc}' (in det-result missing) has no AUDIT_n entry"
          break
        fi
      done <<<"$det_missing"
    fi
  fi

  if [ "$status" != "ok" ]; then
    echo "[dor-semantic-parse] ${status}: ${err} (kind=${kind}, file=${result_file})" >&2
  fi

  local ticket body_hash score_plausible score_reason json
  ticket="${fields[TICKET]:-}"
  body_hash="${fields[BODY_HASH]:-}"

  if [ "$kind" = "scan" ]; then
    json=$(jq -nc \
      --argjson schema_version "$DOR_SEMANTIC_PARSE_SCHEMA_VERSION" \
      --arg kind "scan" --arg ticket "$ticket" --arg body_hash "$body_hash" \
      --argjson findings "$findings_json" --argjson gaps "$gaps_json" \
      --arg parse_status "$status" --arg parse_error "$err" \
      '{schema_version:$schema_version, kind:$kind, ticket:$ticket,
        body_hash:$body_hash, findings:$findings, gaps:$gaps,
        parse_status:$parse_status, parse_error:$parse_error}' 2>/dev/null) || json=""
  else
    score_plausible="${fields[SCORE_PLAUSIBLE]:-}"
    score_reason=$(_dsp_redact "${fields[SCORE_REASON]:-}")
    json=$(jq -nc \
      --argjson schema_version "$DOR_SEMANTIC_PARSE_SCHEMA_VERSION" \
      --arg kind "audit" --arg ticket "$ticket" --arg body_hash "$body_hash" \
      --argjson audit "$audit_json" --argjson missed "$missed_json" \
      --arg score_plausible "$score_plausible" --arg score_reason "$score_reason" \
      --arg parse_status "$status" --arg parse_error "$err" \
      '{schema_version:$schema_version, kind:$kind, ticket:$ticket,
        body_hash:$body_hash, audit:$audit, missed:$missed,
        score_plausible: (if $score_plausible == "yes" then true elif $score_plausible == "no" then false else null end),
        score_reason:$score_reason,
        parse_status:$parse_status, parse_error:$parse_error}' 2>/dev/null) || json=""
  fi

  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "[dor-semantic-parse] WARN: jq serialization failed, nothing emitted" >&2
    return 2
  fi

  printf '%s\n' "$json"

  [ "$status" = "invalid" ] && return 1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eo pipefail
  parse_dor_semantic "$@"
  exit $?
fi
