#!/usr/bin/env bash
# adr-gate-parse.sh — deterministic parser for the `=== ADR_GATE_RESULT ===`
# block skills/adr-gate/SKILL.md appends as the last content of its return.
#
# Adapted from human-hold-parse.sh (docs/adr-gate-schema.md § Tolerant
# transport, strict contract mirrors human-hold-schema.md's framing exactly).
# Unlike human-hold, the gate is REQUIRED to emit a result on every
# invocation (docs/adr-gate-schema.md § Every verdict is recorded) — there is
# no "absent block is a normal outcome" case here. A missing block is a
# parser failure like any other malformed block, not a silent non-event.
#
# Tolerant at the transport boundary (whitespace, CRLF, blank lines, field
# order, unknown fields). Strict at the contract boundary (required fields,
# the closed ADR_VERDICT enum, CONFLICT's mandatory ADR_ID/CONFLICT pair, the
# closing marker). A rejection is still logged — a swallowed verdict would
# make park rate unmeasurable — but is NEVER reported as a success object,
# per adr-gate-invocation spec.
#
# Exit codes:
#   0 — a valid block was parsed (parse_status=ok).
#   1 — no usable verdict: block absent, malformed, or contract-violating
#       (parse_status=invalid). A record IS still logged. Normal outcome,
#       not an error — the caller treats it as "no gate-stop-worthy result".
#   2 — the parser could not run (usage, unreadable file, jq missing).
#
# Sourceable lib (`parse_adr_gate_result`) and standalone CLI.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
set -eo pipefail

ADR_GATE_RESULT_SCHEMA_VERSION=1

_AGP_VERDICTS="NOT_ARCHITECTURAL GOVERNED CREATED_PROPOSED CONFLICT SUPERSEDE_REQUIRED"
_AGP_REQUIRED="SCHEMA_VERSION ADR_REQUIRED ADR_VERDICT HUMAN_DECISION_REQUIRED RATIONALE"
_AGP_KNOWN="SCHEMA_VERSION ADR_REQUIRED ADR_VERDICT ADR_ID GOVERNING_ADR CONFLICT HUMAN_DECISION_REQUIRED RATIONALE"

_AGP_OPEN_MARKER="=== ADR_GATE_RESULT ==="
_AGP_CLOSE_MARKER="=== END ADR_GATE_RESULT ==="

_agp_usage() {
  cat >&2 <<'EOF'
Usage: adr-gate-parse.sh --result-file <path> [--log-file <path>] [--ticket-dir <path>]

  --result-file <path>   Captured gate return text (or a file containing
                         just the block). Required.
  --log-file <path>      Pipeline log to append META|adr-gate to. Falls back
                         to LOG_FILE env var. Omit both to skip the log write.
  --ticket-dir <path>    Workspace dir, for resolving a relative
                         --result-file. Falls back to the current directory.

Exit: 0 valid block, 1 no usable verdict (absent/malformed/contract
violation — still logged), 2 parser could not run.
EOF
}

_agp_in_list() {
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Same C-collation forcing as human-hold-parse.sh's _hh_key_ok — bracket
# expressions are locale-sensitive under a UTF-8 locale.
_agp_key_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

# Same envelope-unwrap as human-hold-parse.sh's _hh_unwrap: reduces a
# `claude -p --output-format json|stream-json` capture to the return text
# before line-oriented extraction ever runs.
_agp_unwrap() {
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

# Emit the canonical JSON record and append it to the pipeline log. All
# values are bound as jq arguments — never interpolated into a JSON string.
_agp_emit() {
  local status="$1" err="$2" adr_required="$3" verdict="$4" adr_id="$5"
  local governing_adr="$6" conflict="$7" human_decision_required="$8"
  local rationale="$9" log_file="${10}"

  local json
  json=$(jq -nc \
    --argjson schema_version "$ADR_GATE_RESULT_SCHEMA_VERSION" \
    --arg adr_required "$adr_required" \
    --arg verdict "$verdict" \
    --arg adr_id "$adr_id" \
    --arg governing_adr "$governing_adr" \
    --arg conflict "$conflict" \
    --arg human_decision_required "$human_decision_required" \
    --arg rationale "$rationale" \
    --arg parse_status "$status" \
    --arg parse_error "$err" \
    '{schema_version: $schema_version,
      adr_required: (if $adr_required == "true" then true elif $adr_required == "false" then false else null end),
      verdict: $verdict, adr_id: $adr_id, governing_adr: $governing_adr,
      conflict: $conflict,
      human_decision_required: (if $human_decision_required == "true" then true elif $human_decision_required == "false" then false else null end),
      rationale: $rationale, parse_status: $parse_status, parse_error: $parse_error}' 2>/dev/null) || json=""

  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "[adr-gate-parse] WARN: jq serialization failed, nothing emitted" >&2
    return 2
  fi

  printf '%s\n' "$json"

  if [ -n "$log_file" ]; then
    local iso
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "${iso}|META|adr-gate|info|${json}" >>"$log_file" || {
      echo "[adr-gate-parse] WARN: log write failed (LOG_FILE=${log_file})" >&2
    }
  fi
  return 0
}

# parse_adr_gate_result --result-file <f> [--log-file <l>] [--ticket-dir <d>]
parse_adr_gate_result() {
  local result_file="" log_file="${LOG_FILE:-}" ticket_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
    --result-file)
      result_file="${2:-}"
      shift 2
      ;;
    --log-file)
      log_file="${2:-}"
      shift 2
      ;;
    --ticket-dir)
      ticket_dir="${2:-}"
      shift 2
      ;;
    -h | --help)
      _agp_usage
      return 2
      ;;
    *)
      echo "[adr-gate-parse] ERROR: unknown argument '$1'" >&2
      _agp_usage
      return 2
      ;;
    esac
  done

  if [ -z "$result_file" ]; then
    echo "[adr-gate-parse] ERROR: --result-file is required" >&2
    _agp_usage
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[adr-gate-parse] ERROR: jq not available" >&2
    return 2
  fi

  case "$result_file" in
  /*) ;;
  *) [ -n "$ticket_dir" ] && result_file="${ticket_dir%/}/$result_file" ;;
  esac

  if [ ! -f "$result_file" ]; then
    echo "[adr-gate-parse] ERROR: result file not found: $result_file" >&2
    return 2
  fi

  local body status="ok" err=""

  # ── extract ────────────────────────────────────────────────────────────
  local _extract_rc=0
  body=$(_agp_unwrap "$result_file" | tr -d '\r' | awk -v mopen="$_AGP_OPEN_MARKER" -v mclose="$_AGP_CLOSE_MARKER" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    trim($0) == mopen  { collecting = 1; buf = ""; next }
    collecting && trim($0) == mclose { collecting = 0; closed = 1; last = buf; next }
    collecting { buf = buf $0 "\n"; next }
    END {
      if (collecting) { exit 3 }
      if (closed)     { printf "%s", last; exit 0 }
      exit 4
    }
  ') || _extract_rc=$?

  case "$_extract_rc" in
  0) ;;
  3)
    status="invalid"
    err="missing closing marker"
    ;;
  4)
    status="invalid"
    err="no ADR_GATE_RESULT block in return"
    ;;
  *)
    status="invalid"
    err="block extraction failed (awk exit ${_extract_rc})"
    ;;
  esac

  if [ "$status" = "ok" ] && [ -z "${body//[[:space:]]/}" ]; then
    status="invalid"
    err="empty block"
  fi

  local out_adr_required="" out_verdict="" out_adr_id="" out_governing_adr=""
  local out_conflict="" out_human_decision_required="" out_rationale=""

  if [ "$status" = "ok" ]; then
    # ── parse ──────────────────────────────────────────────────────────
    local -A fields=()
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

      if ! _agp_key_ok "$key"; then
        status="invalid"
        err="key '${key}' does not match [A-Z][A-Z0-9_]*"
        break
      fi

      if _agp_in_list "$key" "$seen_keys"; then
        status="invalid"
        err="duplicate field: ${key}"
        break
      fi
      seen_keys="$seen_keys $key"

      if _agp_in_list "$key" "$_AGP_KNOWN"; then
        fields["$key"]="$value"
      fi
      # Any other well-formed key is an unknown field — silently ignored
      # (transport tolerance), consistent with human-hold-parse.sh.
    done <<<"$body"

    # ── validate ─────────────────────────────────────────────────────────
    if [ "$status" = "ok" ]; then
      local f
      for f in $_AGP_REQUIRED; do
        if [ -z "${fields[$f]+set}" ] || [ -z "${fields[$f]}" ]; then
          status="invalid"
          err="missing required field: ${f}"
          break
        fi
      done
    fi

    if [ "$status" = "ok" ] && [ "${fields[SCHEMA_VERSION]}" != "$ADR_GATE_RESULT_SCHEMA_VERSION" ]; then
      status="invalid"
      err="unsupported SCHEMA_VERSION: ${fields[SCHEMA_VERSION]} (parser supports ${ADR_GATE_RESULT_SCHEMA_VERSION})"
    fi

    if [ "$status" = "ok" ] && [ "${fields[ADR_REQUIRED]}" != "true" ] && [ "${fields[ADR_REQUIRED]}" != "false" ]; then
      status="invalid"
      err="ADR_REQUIRED must be 'true' or 'false', got '${fields[ADR_REQUIRED]}'"
    fi

    if [ "$status" = "ok" ] && [ "${fields[HUMAN_DECISION_REQUIRED]}" != "true" ] && [ "${fields[HUMAN_DECISION_REQUIRED]}" != "false" ]; then
      status="invalid"
      err="HUMAN_DECISION_REQUIRED must be 'true' or 'false', got '${fields[HUMAN_DECISION_REQUIRED]}'"
    fi

    if [ "$status" = "ok" ] && ! _agp_in_list "${fields[ADR_VERDICT]}" "$_AGP_VERDICTS"; then
      status="invalid"
      err="ADR_VERDICT '${fields[ADR_VERDICT]}' is not in the closed set ($_AGP_VERDICTS)"
    fi

    # CONFLICT requires a named ADR — docs/adr-gate-schema.md § CONFLICT
    # requires a named ADR. An LLM-issued conflict claim with nothing to
    # point at could otherwise halt a pipeline on a hallucination.
    if [ "$status" = "ok" ] && [ "${fields[ADR_VERDICT]}" = "CONFLICT" ]; then
      if [ -z "${fields[ADR_ID]:-}" ] || [ -z "${fields[CONFLICT]:-}" ]; then
        status="invalid"
        err="ADR_VERDICT: CONFLICT requires a non-empty ADR_ID and CONFLICT"
      fi
    fi

    if [ "$status" = "ok" ]; then
      out_adr_required="${fields[ADR_REQUIRED]}"
      out_verdict="${fields[ADR_VERDICT]}"
      out_adr_id="${fields[ADR_ID]:-}"
      out_governing_adr="${fields[GOVERNING_ADR]:-}"
      out_conflict="${fields[CONFLICT]:-}"
      out_human_decision_required="${fields[HUMAN_DECISION_REQUIRED]}"
      out_rationale="${fields[RATIONALE]}"
    fi
  fi

  if [ "$status" != "ok" ]; then
    echo "[adr-gate-parse] ${status}: ${err} (file=${result_file})" >&2
  fi

  _agp_emit "$status" "$err" "$out_adr_required" "$out_verdict" "$out_adr_id" \
    "$out_governing_adr" "$out_conflict" "$out_human_decision_required" \
    "$out_rationale" "$log_file" || return 2

  [ "$status" = "invalid" ] && return 1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  parse_adr_gate_result "$@"
  exit $?
fi
