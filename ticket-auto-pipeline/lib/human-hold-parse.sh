#!/usr/bin/env bash
# human-hold-parse.sh — deterministic parser for the `=== HUMAN_HOLD ===` block
# an agent appends to its return when it cannot proceed without human input.
#
# Modelled line-for-line on phase-result-parse.sh: extracts the block from a
# captured-return file, parses its `KEY: value` body, validates it against
# docs/human-hold-schema.md, redacts secret-shaped values, serializes
# canonical JSON with jq, and appends `META|human-hold|waiting|{json}` to the
# pipeline log.
#
# Tolerant at the transport boundary (whitespace, CRLF, blank lines, field
# order, unknown fields), strict at the contract boundary (enums, required
# fields, closing marker, and the fields an agent is not permitted to set).
# A rejection degrades to `parse_status=invalid` and is STILL LOGGED — a
# swallowed ask is the exact bug this parser exists to fix. A rejected or
# absent block never creates a hold and is never eligible for release.
#
# Exit codes (deliberately narrower than phase-result-parse.sh's, because the
# human-hold-request spec is explicit that "no block at all" is a non-event):
#   0 — a valid block was parsed (parse_status=ok), OR no block was present
#       at all (parse_status=absent) — nothing is logged for the latter.
#   1 — a block was present but failed the contract (parse_status=invalid).
#       A record IS still emitted and logged — a swallowed ask is the bug
#       this parser exists to fix. Still a normal outcome, not an error.
#   2 — the parser could not run (usage, unreadable file, jq missing).
#
# Sourceable lib (`parse_human_hold`) and standalone CLI.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
set -eo pipefail

_HH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HUMAN_HOLD_SCHEMA_VERSION=1
# Highest version this parser reads. A version-1 block still serializes with
# schema_version 1 and none of the version-2 keys, byte-identical to the
# output before version 2 existed (docs/human-hold-schema.md § Schema-Version 2).
HUMAN_HOLD_SCHEMA_VERSION_MAX=2

_HH_PHASES="APPRAISE REPRODUCE EXEC GATE IMPLEMENT VERIFY PR-REVIEW MAINTENANCE"
_HH_REASONS="AC_CONFLICT SCOPE_UNDEFINED ARCH_COMMITMENT CREDENTIALS_MISSING EXTERNAL_DEPENDENCY APPROVAL_REQUIRED"

# Version 2 widens both enums for the two headless emitters outside the
# ticket pipeline — ticket-planner's stop describer and grill-me's question
# rounds. A version-1 block naming one of these is still rejected.
_HH_PHASES_V2="PLANNER GRILL"
_HH_REASONS_V2="CREATE_GATE CROSSCHECK_BLOCKED ADR_GATE PROJECT_GATE REFINEMENT_HALT UNTIL_STOP READINESS_GAPS ROUND_CAP"
_HH_KINDS="approval input"
_HH_AUDIENCES="client operator either"

_HH_REQUIRED="SCHEMA_VERSION PHASE REASON BLOCKS"
_HH_KNOWN="SCHEMA_VERSION PHASE REASON BLOCKS SUPERSEDES"
_HH_KNOWN_V2="ROUND KIND AUDIENCE"

# Fields whose authority lies elsewhere and which the parser therefore
# refuses outright, rather than tolerating them under `extra` — see
# docs/human-hold-schema.md "What the field set does not carry". Position is
# `store.record_position`'s; held-at and hold-id are fleetd's (minted at
# transition time, never agent-chosen); severity/priority are orchestration's,
# derived from age.
_HH_FORBIDDEN="POSITION RESUME_STEP RESUME_POSITION STEP HELD_AT HOLD_ID SEVERITY PRIORITY"

_HH_OPEN_MARKER="=== HUMAN_HOLD ==="
_HH_CLOSE_MARKER="=== END HUMAN_HOLD ==="

_hh_usage() {
  cat >&2 <<'EOF'
Usage: human-hold-parse.sh --phase <PHASE> --return-file <path>
                            [--log-file <path>] [--ticket-dir <path>]

  --phase <PHASE>        Emitting phase. Required. Always carried into the
                         record, including on rejection.
  --return-file <path>   Captured agent return text. Required.
  --log-file <path>      Pipeline log to append META|human-hold to. Falls
                         back to LOG_FILE env var. Omit both to skip the log
                         write.
  --ticket-dir <path>    Ticket workspace, for resolving a relative
                         --return-file. Falls back to the current directory.

Exit: 0 valid block or no block at all (absent), 1 a present block failed
the contract (invalid — still logged), 2 parser could not run.
EOF
}

_hh_in_list() {
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Same C-collation forcing as phase-result-parse.sh's _pr_key_ok — bracket
# expressions are locale-sensitive under a UTF-8 locale.
_hh_key_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

_hh_is_question_key() {
  local LC_ALL=C
  [[ "$1" =~ ^QUESTION_[1-9][0-9]*$ ]]
}

# QUESTION_n_ID / _OPTIONS / _DEFAULT / _BINDING — the per-question
# version-2 attributes. Only consulted for a SCHEMA_VERSION 2 block; in a
# version-1 block these are ordinary unknown keys and are ignored.
_hh_is_question_attr_key() {
  local LC_ALL=C
  [[ "$1" =~ ^QUESTION_[1-9][0-9]*_(ID|OPTIONS|DEFAULT|BINDING)$ ]]
}

# Binding grammar (docs/human-hold-schema.md § Binding grammar). The binding
# names the deterministic action an answer feeds; the consumer, never an
# agent, performs it. `consensus-answer:cited:<n>` (#515) addresses a cited
# artifact by its 1-based position in consensus.md's CITED_ARTIFACT list:
# artifact names carry spaces and parentheses, so a name never appears in a
# binding.
_hh_binding_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^(note|flag:create|flag:project|flag:accept:[A-Z][A-Z0-9_]*|waive:[A-Za-z0-9-]+:[A-Z][A-Z0-9_]*|adr:[A-Za-z0-9-]+|grill:[a-z][a-z0-9_-]*|consensus-answer:cited:[1-9][0-9]{0,3})$ ]]
}

_hh_question_id_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]
}

# Mask secret-shaped values before they can reach the log — and therefore
# before they can reach Linear or Slack, both of which read from the
# redacted record, never from the raw agent return (docs/human-hold-schema.md
# § Redaction). Reimplemented here rather than sourced from
# fleet-controller/lib/fleet-notify.sh's _notify_mask: ticket-auto-pipeline
# does not depend on fleet-controller, and the direction must stay that way.
_hh_redact() {
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

# Same envelope-unwrap as phase-result-parse.sh's _pr_unwrap: reduces a
# `claude -p --output-format json|stream-json` capture to the return text
# before line-oriented extraction ever runs.
_hh_unwrap() {
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

# Emit the canonical JSON record and append it to the pipeline log.
# All values are bound as jq arguments — never interpolated into a JSON
# string.
_hh_emit() {
  local status="$1" err="$2" phase="$3" reason="$4" blocks="$5"
  local supersedes="$6" questions_json="$7" log_file="$8"
  local schema_version="${9:-$HUMAN_HOLD_SCHEMA_VERSION}" v2_json="${10:-}"

  local json
  json=$(jq -nc \
    --argjson schema_version "$schema_version" \
    --arg phase "$phase" \
    --arg reason "$reason" \
    --arg blocks "$blocks" \
    --arg supersedes "$supersedes" \
    --argjson questions "$questions_json" \
    --arg parse_status "$status" \
    --arg parse_error "$err" \
    '{schema_version: $schema_version, phase: $phase, reason: $reason,
      blocks: $blocks, supersedes: $supersedes, questions: $questions,
      parse_status: $parse_status, parse_error: $parse_error}' 2>/dev/null) || json=""

  # Version-2 block-level keys (round/kind/audience) are merged in only when
  # present, ahead of parse_status, so a version-1 record keeps its exact key
  # set and order.
  if [ -n "$json" ] && [ -n "$v2_json" ] && [ "$v2_json" != "{}" ]; then
    json=$(jq -nc --argjson base "$json" --argjson v2 "$v2_json" \
      '($base | del(.parse_status, .parse_error)) + $v2
       + {parse_status: $base.parse_status, parse_error: $base.parse_error}' 2>/dev/null) || json=""
  fi

  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "[human-hold] WARN: jq serialization failed, nothing emitted" >&2
    return 2
  fi

  printf '%s\n' "$json"

  # "No block at all" is a non-event (human-hold-request spec): nothing is
  # written to the pipeline log for it, unlike phase-result-parse.sh's
  # UNKNOWN-on-absent convention. An `invalid` record IS written — a
  # swallowed ask is the bug this parser exists to fix.
  if [ "$status" = "absent" ]; then
    return 0
  fi

  # F4 guard, copied from phase-result-parse.sh: an unwritable log degrades,
  # it never aborts the caller.
  if [ -n "$log_file" ]; then
    local iso
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "${iso}|META|human-hold|waiting|${json}" >>"$log_file" || {
      echo "[human-hold] WARN: log write failed (LOG_FILE=${log_file})" >&2
    }
  fi

  # Dual-write to the event outbox (tracker-event-vocabulary-and-emitter).
  # Only on a genuinely valid block — an "invalid" record is still logged
  # above (a swallowed ask is the bug this parser exists to fix) but is not
  # a real question, so it emits no fact. Never calls flow.sh — a hold
  # changes no Linear label or state. TID is derived from LOG_FILE's own
  # {tid}-pipeline.log naming convention since this parser takes no
  # explicit ticket id argument.
  if [ "$status" = "ok" ] && [ -n "$log_file" ]; then
    local _events_sh="" _cand _hh_tid _hh_question_text
    for _cand in "$_HH_LIB_DIR/events.sh" "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/events.sh"; do
      [ -f "$_cand" ] && {
        _events_sh="$_cand"
        break
      }
    done
    if [ -n "$_events_sh" ]; then
      _hh_tid=$(basename "$log_file")
      _hh_tid="${_hh_tid%-pipeline.log}"
      if [ -n "$_hh_tid" ] && [ "$_hh_tid" != "$(basename "$log_file")" ]; then
        (
          source "$_events_sh"
          _hh_question_text=$(printf '%s' "$questions_json" | jq -r '[.[].text] | join("; ")' 2>/dev/null)
          emit_event "$_hh_tid" human-hold-requested \
            "$(jq -nc --arg q "$_hh_question_text" '{question: $q}')"
        ) 2>/dev/null || true
      fi
    fi
  fi

  return 0
}

# ── version-2 helpers ──────────────────────────────────────────────────────
# These read and set parse_human_hold's own locals (fields, q_ids, q_vals,
# q_attrs, status, err) through bash's dynamic scoping — they are only ever
# called from inside it.

# Validate the optional version-2 keys. On a violation, sets status=invalid
# and err in the caller and returns 1.
_hh_validate_v2() {
  local LC_ALL=C
  if [ -n "${fields[ROUND]+set}" ] && ! [[ "${fields[ROUND]}" =~ ^[1-9][0-9]*$ ]]; then
    status="invalid"
    err="ROUND '${fields[ROUND]}' is not a positive integer"
    return 1
  fi
  if [ -n "${fields[KIND]+set}" ] && ! _hh_in_list "${fields[KIND]}" "$_HH_KINDS"; then
    status="invalid"
    err="KIND '${fields[KIND]}' is not in the enum ($_HH_KINDS)"
    return 1
  fi
  if [ -n "${fields[AUDIENCE]+set}" ] && ! _hh_in_list "${fields[AUDIENCE]}" "$_HH_AUDIENCES"; then
    status="invalid"
    err="AUDIENCE '${fields[AUDIENCE]}' is not in the enum ($_HH_AUDIENCES)"
    return 1
  fi

  local attr n kind seen_ids="" qid opt default
  for attr in "${!q_attrs[@]}"; do
    n="${attr%%_*}"
    kind="${attr#*_}"
    if ! _hh_in_list "$n" "${q_ids[*]}"; then
      status="invalid"
      err="QUESTION_${attr} names no QUESTION_${n}"
      return 1
    fi
    case "$kind" in
    ID)
      qid="${q_attrs[$attr]}"
      if ! _hh_question_id_ok "$qid"; then
        status="invalid"
        err="QUESTION_${attr} '${qid}' is not a valid question id"
        return 1
      fi
      if _hh_in_list "$qid" "$seen_ids"; then
        status="invalid"
        err="duplicate question id: ${qid}"
        return 1
      fi
      seen_ids="$seen_ids $qid"
      ;;
    BINDING)
      if ! _hh_binding_ok "${q_attrs[$attr]}"; then
        status="invalid"
        err="QUESTION_${attr} '${q_attrs[$attr]}' does not match the binding grammar"
        return 1
      fi
      ;;
    OPTIONS)
      local _optv="${q_attrs[$attr]}" _opt
      local -a _opts=()
      IFS='|' read -r -a _opts <<<"$_optv"
      # read -a drops a trailing empty field, so check the separators too.
      case "$_optv" in
      "|"* | *"|" | *"||"*) _opts=("") ;;
      esac
      [ "${#_opts[@]}" -eq 0 ] && _opts=("")
      for _opt in "${_opts[@]}"; do
        if [ -z "${_opt//[[:space:]]/}" ]; then
          status="invalid"
          err="QUESTION_${attr} has an empty option"
          return 1
        fi
      done
      ;;
    esac
  done

  # A DEFAULT must be one of the question's OPTIONS when both are given.
  for n in "${q_ids[@]}"; do
    default="${q_attrs[${n}_DEFAULT]:-}"
    [ -n "${q_attrs[${n}_DEFAULT]+set}" ] || continue
    [ -n "${q_attrs[${n}_OPTIONS]+set}" ] || continue
    if ! printf '%s\n' "${q_attrs[${n}_OPTIONS]}" | tr '|' '\n' | grep -qxF -- "$default"; then
      status="invalid"
      err="QUESTION_${n}_DEFAULT '${default}' is not one of its OPTIONS"
      return 1
    fi
  done
  return 0
}

# Redact each `|`-separated option on its own: run over the joined string,
# the key=value pattern would swallow the separator and the next option.
_hh_redact_options() {
  local opt out="" first=1
  local -a opts=()
  IFS='|' read -r -a opts <<<"$1"
  for opt in "${opts[@]}"; do
    [ "$first" -eq 1 ] || out="${out}|"
    out="${out}$(_hh_redact "$opt")"
    first=0
  done
  printf '%s' "$out"
}

# Serialize version-2 questions: id is QUESTION_n_ID when given, else n.
# Every free-text value (text, options, default) is redacted, same as v1
# question text — any of them can reach Linear and Slack.
# Attributes appear only when the block carried them.
_hh_questions_v2_json() {
  local i n out="[]" q
  for i in "${!q_ids[@]}"; do
    n="${q_ids[$i]}"
    q=$(jq -nc \
      --arg n "$n" \
      --arg text "$(_hh_redact "${q_vals[$i]}")" \
      --arg qid "${q_attrs[${n}_ID]:-}" \
      --arg has_opts "${q_attrs[${n}_OPTIONS]+set}" \
      --arg opts "$(_hh_redact_options "${q_attrs[${n}_OPTIONS]:-}")" \
      --arg has_def "${q_attrs[${n}_DEFAULT]+set}" \
      --arg def "$(_hh_redact "${q_attrs[${n}_DEFAULT]:-}")" \
      --arg has_bind "${q_attrs[${n}_BINDING]+set}" \
      --arg bind "${q_attrs[${n}_BINDING]:-}" \
      '{id: (if $qid == "" then ($n|tonumber) else $qid end), n: ($n|tonumber), text: $text}
       + (if $has_opts == "set" then {options: ($opts | split("|") | map(gsub("^\\s+|\\s+$"; "")))} else {} end)
       + (if $has_def == "set" then {default: $def} else {} end)
       + (if $has_bind == "set" then {binding: $bind} else {} end)') || return 1
    out=$(jq -nc --argjson a "$out" --argjson q "$q" '$a + [$q]') || return 1
  done
  printf '%s' "$out" | jq -c 'sort_by(.n)'
}

# Serialize version-2 block-level keys, only those present.
_hh_block_v2_json() {
  jq -nc \
    --arg has_round "${fields[ROUND]+set}" --arg round "${fields[ROUND]:-}" \
    --arg has_kind "${fields[KIND]+set}" --arg kind "${fields[KIND]:-}" \
    --arg has_aud "${fields[AUDIENCE]+set}" --arg aud "${fields[AUDIENCE]:-}" \
    '(if $has_round == "set" then {round: ($round|tonumber)} else {} end)
     + (if $has_kind == "set" then {kind: $kind} else {} end)
     + (if $has_aud == "set" then {audience: $aud} else {} end)'
}

# parse_human_hold --phase <P> --return-file <f> [--log-file <l>] [--ticket-dir <d>]
parse_human_hold() {
  local phase="" return_file="" log_file="${LOG_FILE:-}" ticket_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
    --phase)
      phase="${2:-}"
      shift 2
      ;;
    --return-file)
      return_file="${2:-}"
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
      _hh_usage
      return 2
      ;;
    *)
      echo "[human-hold] ERROR: unknown argument '$1'" >&2
      _hh_usage
      return 2
      ;;
    esac
  done

  if [ -z "$phase" ] || [ -z "$return_file" ]; then
    echo "[human-hold] ERROR: --phase and --return-file are required" >&2
    _hh_usage
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[human-hold] ERROR: jq not available" >&2
    return 2
  fi

  # A version-2 phase is accepted here; the block itself must then declare
  # SCHEMA_VERSION 2 to pass the enum check below.
  if ! _hh_in_list "$phase" "$_HH_PHASES $_HH_PHASES_V2"; then
    echo "[human-hold] ERROR: --phase '$phase' is not a known phase ($_HH_PHASES $_HH_PHASES_V2)" >&2
    return 2
  fi

  case "$return_file" in
  /*) ;;
  *) [ -n "$ticket_dir" ] && return_file="${ticket_dir%/}/$return_file" ;;
  esac

  if [ ! -f "$return_file" ]; then
    echo "[human-hold] ERROR: return file not found: $return_file" >&2
    return 2
  fi

  local body status="ok" err=""

  # ── extract ────────────────────────────────────────────────────────────
  local _extract_rc=0
  body=$(_hh_unwrap "$return_file" | tr -d '\r' | awk -v mopen="$_HH_OPEN_MARKER" -v mclose="$_HH_CLOSE_MARKER" '
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
    status="absent"
    err="no HUMAN_HOLD block in return"
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

  local out_phase="" out_reason="" out_blocks="" out_supersedes=""
  local out_version="$HUMAN_HOLD_SCHEMA_VERSION" v2_json=""
  local questions_json="[]"

  if [ "$status" = "ok" ]; then
    # ── parse ──────────────────────────────────────────────────────────
    local -A fields=() q_attrs=()
    local -a q_ids=() q_vals=()
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

      if ! _hh_key_ok "$key"; then
        status="invalid"
        err="key '${key}' does not match [A-Z][A-Z0-9_]*"
        break
      fi

      if _hh_in_list "$key" "$seen_keys"; then
        status="invalid"
        err="duplicate field: ${key}"
        break
      fi
      seen_keys="$seen_keys $key"

      if _hh_in_list "$key" "$_HH_FORBIDDEN"; then
        status="invalid"
        err="field '${key}' is not accepted from an agent — its authority lies elsewhere"
        break
      fi

      if _hh_is_question_key "$key"; then
        q_ids+=("${key#QUESTION_}")
        q_vals+=("$value")
      elif _hh_in_list "$key" "$_HH_KNOWN"; then
        fields["$key"]="$value"
      elif _hh_in_list "$key" "$_HH_KNOWN_V2"; then
        fields["$key"]="$value"
      elif _hh_is_question_attr_key "$key"; then
        q_attrs["${key#QUESTION_}"]="$value"
      fi
      # Any other well-formed key is an unknown field — silently ignored
      # rather than rejected (transport tolerance), and rather than
      # recorded under an `extra` bag: this block has no such carrier, and
      # an unknown key here is never load-bearing for the request.
    done <<<"$body"

    # ── validate ─────────────────────────────────────────────────────────
    if [ "$status" = "ok" ]; then
      local f
      for f in $_HH_REQUIRED; do
        if [ -z "${fields[$f]+set}" ] || [ -z "${fields[$f]}" ]; then
          status="invalid"
          err="missing required field: ${f}"
          break
        fi
      done
    fi

    if [ "$status" = "ok" ] && [ "${#q_ids[@]}" -eq 0 ]; then
      status="invalid"
      err="at least one QUESTION_n is required"
    fi

    local block_version="" reasons="$_HH_REASONS" phases="$_HH_PHASES"
    if [ "$status" = "ok" ]; then
      block_version="${fields[SCHEMA_VERSION]}"
      case "$block_version" in
      1) ;;
      2)
        reasons="$_HH_REASONS $_HH_REASONS_V2"
        phases="$_HH_PHASES $_HH_PHASES_V2"
        ;;
      *)
        status="invalid"
        err="unsupported SCHEMA_VERSION: ${block_version} (parser supports 1..${HUMAN_HOLD_SCHEMA_VERSION_MAX})"
        ;;
      esac
    fi

    if [ "$status" = "ok" ] && ! _hh_in_list "${fields[REASON]}" "$reasons"; then
      status="invalid"
      err="REASON '${fields[REASON]}' is not in the enum ($reasons)"
    fi

    if [ "$status" = "ok" ] && ! _hh_in_list "${fields[PHASE]}" "$phases"; then
      status="invalid"
      err="PHASE '${fields[PHASE]}' is not in the enum ($phases)"
    fi

    if [ "$status" = "ok" ] && [ "${fields[PHASE]}" != "$phase" ]; then
      status="invalid"
      err="block PHASE '${fields[PHASE]}' does not match the invoking phase '${phase}'"
    fi

    # ── version-2 validation ─────────────────────────────────────────────
    if [ "$status" = "ok" ] && [ "$block_version" = "2" ]; then
      _hh_validate_v2 || true
    fi

    if [ "$status" = "ok" ]; then
      out_phase="${fields[PHASE]}"
      out_reason="${fields[REASON]}"
      out_blocks=$(_hh_redact "${fields[BLOCKS]}")
      out_supersedes="${fields[SUPERSEDES]:-}"
      out_version="$block_version"

      if [ "$block_version" = "2" ]; then
        questions_json=$(_hh_questions_v2_json) || questions_json="[]"
        v2_json=$(_hh_block_v2_json) || v2_json=""
      else
        local i args=() filter="["
        for i in "${!q_ids[@]}"; do
          local qval
          qval=$(_hh_redact "${q_vals[$i]}")
          args+=(--arg "id$i" "${q_ids[$i]}" --arg "v$i" "$qval")
          [ "$i" -gt 0 ] && filter="$filter,"
          filter="$filter{id: (\$id$i|tonumber), text: \$v$i}"
        done
        filter="$filter]"
        questions_json=$(jq -nc "${args[@]}" "$filter" 2>/dev/null) || questions_json="[]"
        questions_json=$(printf '%s' "$questions_json" | jq -c 'sort_by(.id)' 2>/dev/null) || true
      fi
    fi
  fi

  if [ "$status" != "ok" ]; then
    out_phase="$phase"
    echo "[human-hold] ${status}: ${err} (phase=${phase}, file=${return_file})" >&2
  fi

  _hh_emit "$status" "$err" "$out_phase" "$out_reason" "$out_blocks" \
    "$out_supersedes" "$questions_json" "$log_file" "$out_version" "$v2_json" || return 2

  [ "$status" = "invalid" ] && return 1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  parse_human_hold "$@"
  exit $?
fi
