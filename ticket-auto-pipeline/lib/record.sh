#!/usr/bin/env bash
# record.sh — the recording mode's one library (openspec change
# ticket-auto-record, design D1/D2/D4).
#
# Recording is opt-in per ticket. The router preamble writes
# `META|record|info|on` once (on `--record`, or `TICKET_RECORD=true`, and only
# when RECORD_ALLOWED is valid); every later reader asks record_enabled, never
# the flag. Captured files are named, environment-checked and listed here, in
# bash, never by an agent's judgement:
#
#   <ticket dir>/artifacts/recordings/manifest.jsonl   one JSON object per line
#   <ticket dir>/artifacts/recordings/.manifest.lock   flock for every append
#   <ticket dir>/artifacts/recordings/{phase}-a{attempt}-{NNN}.png
#
# Manifest fields: ts tid source phase attempt step file env event seq column
# status reason. `source` is app|board, `status` ok|skipped|fail. Readers skip
# a line that does not parse (a torn last line costs one entry).
#
# Recording never changes a verdict and never writes to the pipeline log: the
# only log line is the preamble's META|record. Every function returns 0 on a
# runtime problem (predicates return 1 for "no"); only argument errors are
# non-zero. Callers still add `|| true` (the set -e bare-&& gotcha).
#
# Sourced API:
#   record_enabled <log>             0 when the log holds META|record|info|on and
#                                    RECORD_DISABLE is not true, else 1
#   record_allowed_parse <raw> [<synthetic>]
#                                    print the allowed environment names, one
#                                    per line. Nothing when the field is invalid
#                                    (empty, or a name other than local/uat) or
#                                    allows nothing. `uat` counts only with
#                                    <synthetic> (default RECORD_UAT_SYNTHETIC)
#                                    = true; otherwise it is dropped with a
#                                    warning on stderr
#   record_env_allowed <env>         0 when <env> is in the parsed RECORD_ALLOWED
#   record_field <name>              env first, then $REPOS_ROOT/CLAUDE.md
#   record_url_env <url>             print local|uat for the URL's origin, or
#                                    nothing
#   record_append_entry <dir> <json> append one compact JSON line to
#                                    <dir>/manifest.jsonl under flock
#
# CLI:
#   record.sh append --tid ID --phase P --step LABEL --src FILE --url URL
#       Exit 2 on a missing or malformed argument, 0 otherwise. Prints one
#       line: `ok <file>`, `skipped <reason>` or `fail <reason>`.
#   record.sh enabled <log>          exit 0 when recording is on for that log
#
# Sourceable: sets no shell options.

_REC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f claude_md_field >/dev/null 2>&1 ||
  source "$_REC_LIB_DIR/claude-md-field.sh"

# Ticket ids join paths, so they must look like one (CRE-12, WIL-4).
_REC_TID_RE='^[A-Za-z][A-Za-z0-9]*-[0-9]+$'
# A phase becomes part of a file name.
_REC_PHASE_RE='^[a-z][a-z0-9]*$'

record_enabled() {
  local log="${1:-}"
  [ -n "$log" ] && [ -f "$log" ] || return 1
  [ "${RECORD_DISABLE:-}" = "true" ] && return 1
  grep -q '^[^|]*|META|record|info|on$' "$log" 2>/dev/null
}

record_field() {
  local name="${1:-}" val
  [ -n "$name" ] || return 2
  val="${!name:-}"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
    return 0
  fi
  [ -n "${REPOS_ROOT:-}" ] || return 0
  claude_md_field "$REPOS_ROOT/CLAUDE.md" "$name" || true
  return 0
}

record_allowed_parse() {
  local raw="${1:-}" synthetic="${2-__unset__}" item names=() out=()
  if [ "$synthetic" = "__unset__" ]; then
    synthetic=$(record_field RECORD_UAT_SYNTHETIC)
  fi
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  local IFS=','
  read -r -a names <<<"$raw" || true
  unset IFS
  for item in "${names[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    case "$item" in
    local) ;;
    uat)
      if [ "$synthetic" != "true" ]; then
        echo "record: RECORD_ALLOWED names uat but RECORD_UAT_SYNTHETIC is not true; uat is not recorded" >&2
        continue
      fi
      ;;
    "") continue ;;
    *)
      # One unknown name makes the whole field invalid.
      return 0
      ;;
    esac
    case " ${out[*]} " in *" $item "*) ;; *) out+=("$item") ;; esac
  done
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

record_env_allowed() {
  local env="${1:-}"
  [ -n "$env" ] || return 1
  record_allowed_parse "$(record_field RECORD_ALLOWED)" 2>/dev/null | grep -qx -- "$env"
}

# _record_origin <url> — scheme://host[:port], lowercased, default port dropped.
_record_origin() {
  local url="${1:-}" scheme rest host
  [[ "$url" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+) ]] || return 0
  scheme=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
  rest="${BASH_REMATCH[2]}"
  rest="${rest##*@}" # drop userinfo
  host=$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')
  case "$scheme:$host" in
  http:*:80) host="${host%:80}" ;;
  https:*:443) host="${host%:443}" ;;
  esac
  printf '%s://%s\n' "$scheme" "$host"
}

record_url_env() {
  local origin local_o uat_o
  origin=$(_record_origin "${1:-}")
  [ -n "$origin" ] || return 0
  local_o=$(_record_origin "$(record_field LOCAL_URL)")
  uat_o=$(_record_origin "$(record_field UAT_URL)")
  if [ -n "$local_o" ] && [ "$origin" = "$local_o" ]; then
    echo local
  elif [ -n "$uat_o" ] && [ "$origin" = "$uat_o" ]; then
    echo uat
  fi
  return 0
}

_record_now() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ
}

# _record_write_line <dir> <json> — append, no lock (caller holds it).
_record_write_line() {
  local dir="$1" json="$2" f="$1/manifest.jsonl"
  # A torn last line (crash mid-write) must not swallow this entry: start it
  # on a line of its own. The torn line itself stays, and readers skip it.
  if [ -s "$f" ] && [ -n "$(tail -c 1 "$f" 2>/dev/null)" ]; then
    printf '\n' >>"$f" 2>/dev/null || true
  fi
  printf '%s\n' "$json" >>"$f" 2>/dev/null || {
    echo "record: cannot append to $dir/manifest.jsonl" >&2
  }
  return 0
}

record_append_entry() {
  local dir="${1:-}" json="${2:-}"
  [ -n "$dir" ] && [ -n "$json" ] || return 2
  # One JSON object on one line, or nothing.
  json=$(printf '%s' "$json" | jq -c . 2>/dev/null) || json=""
  if [ -z "$json" ] || [ "$(printf '%s\n' "$json" | wc -l)" -ne 1 ]; then
    echo "record: not a single JSON object; not appended" >&2
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null || {
    echo "record: cannot create $dir" >&2
    return 0
  }
  (
    flock -w 30 9 || {
      echo "record: manifest lock timed out" >&2
      exit 0
    }
    _record_write_line "$dir" "$json"
  ) 9>>"$dir/.manifest.lock" 2>/dev/null || true
  return 0
}

# _record_entry — build one manifest line (all fields present; absent = null).
# Args: tid source phase attempt step file env status reason
_record_entry() {
  jq -nc --arg ts "$(_record_now)" --arg tid "$1" --arg source "$2" \
    --arg phase "$3" --arg attempt "$4" --arg step "$5" --arg file "$6" \
    --arg env "$7" --arg status "$8" --arg reason "$9" '
    def n: if . == "" then null else . end;
    {ts: $ts, tid: $tid, source: $source, phase: ($phase | n),
     attempt: (if $attempt == "" then null else ($attempt | tonumber) end),
     step: ($step | n), file: ($file | n), env: ($env | n),
     event: null, seq: null, column: null,
     status: $status, reason: ($reason | n)}'
}

# _record_pipeline_log <tid> — the ticket's pipeline log path, or nothing.
_record_pipeline_log() {
  local tid="$1" dir
  if [ -n "${TAP_LOG:-}" ]; then
    printf '%s\n' "$TAP_LOG"
    return 0
  fi
  if [ -f "$_REC_LIB_DIR/log-dir.sh" ]; then
    dir=$(
      source "$_REC_LIB_DIR/log-dir.sh"
      ticket_log_dir 2>/dev/null
    ) || dir=""
    [ -n "$dir" ] && printf '%s/%s-pipeline.log\n' "$dir" "$tid"
  fi
  return 0
}

# _record_attempt <phase> <log> — 1-based attempt number. For verify: the
# failed VERIFY attempts verify_attempt_count sees, plus one. Operator resets
# are deliberately not honoured here (VERIFY_RESET_MAX=0), so attempt numbers
# only ever grow and a later attempt's frames never share a prefix with an
# earlier one's.
_record_attempt() {
  local phase="$1" log="$2" n=0
  if [ "$phase" = "verify" ] && [ -n "$log" ] && [ -f "$log" ] &&
    [ -f "$_REC_LIB_DIR/verify-checkpoint.sh" ]; then
    n=$(
      source "$_REC_LIB_DIR/verify-checkpoint.sh"
      VERIFY_RESET_MAX=0 verify_attempt_count "$log"
    ) || n=0
    case "$n" in '' | *[!0-9]*) n=0 ;; esac
  fi
  echo $((n + 1))
}

_record_cli_append() {
  local tid="" phase="" step="" src="" url=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --tid | --phase | --step | --src | --url)
      if [ $# -lt 2 ]; then
        echo "record.sh append: $1 needs a value" >&2
        return 2
      fi
      case "$1" in
      --tid) tid="$2" ;;
      --phase) phase="$2" ;;
      --step) step="$2" ;;
      --src) src="$2" ;;
      --url) url="$2" ;;
      esac
      shift 2
      ;;
    *)
      echo "record.sh append: unknown argument '$1'" >&2
      return 2
      ;;
    esac
  done
  if [ -z "$tid" ] || [ -z "$phase" ] || [ -z "$step" ] || [ -z "$src" ] || [ -z "$url" ]; then
    echo "Usage: record.sh append --tid ID --phase P --step LABEL --src FILE --url URL" >&2
    return 2
  fi
  if ! [[ "$tid" =~ $_REC_TID_RE ]]; then
    echo "record.sh append: '$tid' is not a ticket id" >&2
    return 2
  fi
  if ! [[ "$phase" =~ $_REC_PHASE_RE ]]; then
    echo "record.sh append: '$phase' is not a phase name" >&2
    return 2
  fi

  local root tdir rc=0
  root=$(record_field REPOS_ROOT)
  if [ -z "$root" ]; then
    echo "fail no-repos-root"
    return 0
  fi
  source "$_REC_LIB_DIR/ticket-dir.sh" 2>/dev/null || true
  tdir=$(resolve_ticket_dir "$tid" "$root" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$tdir" ] || [ ! -d "$tdir" ]; then
    echo "fail no-ticket-dir"
    return 0
  fi
  local rec_dir="$tdir/artifacts/recordings"
  if ! mkdir -p "$rec_dir" 2>/dev/null; then
    echo "fail no-recordings-dir"
    return 0
  fi

  local log attempt env
  log=$(_record_pipeline_log "$tid")
  attempt=$(_record_attempt "$phase" "$log")
  env=$(record_url_env "$url")

  if [ -z "$env" ] || ! record_env_allowed "$env"; then
    # Not a recordable environment: the frame must not survive anywhere.
    [ -f "$src" ] && [ ! -L "$src" ] && rm -f -- "$src" 2>/dev/null
    record_append_entry "$rec_dir" \
      "$(_record_entry "$tid" app "$phase" "$attempt" "$step" "" "$env" skipped env-not-recordable)"
    echo "skipped env-not-recordable"
    return 0
  fi
  if [ ! -f "$src" ] || [ -L "$src" ] || [ ! -s "$src" ]; then
    record_append_entry "$rec_dir" \
      "$(_record_entry "$tid" app "$phase" "$attempt" "$step" "" "$env" fail src-missing)"
    echo "fail src-missing"
    return 0
  fi

  # Name, copy and list under one lock, so concurrent appends never pick the
  # same number and the manifest order matches the file numbers.
  local result
  result=$(
    exec 9>>"$rec_dir/.manifest.lock" || {
      echo "fail lock-failed"
      exit 0
    }
    flock -w 30 9 || {
      echo "fail lock-timeout"
      exit 0
    }
    last=$(find "$rec_dir" -maxdepth 1 -type f \
      -name "${phase}-a${attempt}-[0-9][0-9][0-9].png" -printf '%f\n' 2>/dev/null |
      sed -E 's/.*-([0-9]{3})\.png$/\1/' | sort -n | tail -1)
    next=$((10#${last:-0} + 1))
    if [ "$next" -gt 999 ]; then
      _record_write_line "$rec_dir" \
        "$(_record_entry "$tid" app "$phase" "$attempt" "$step" "" "$env" fail frame-limit)"
      echo "fail frame-limit"
      exit 0
    fi
    name=$(printf '%s-a%s-%03d.png' "$phase" "$attempt" "$next")
    tmp=$(mktemp "$rec_dir/.${name}.XXXXXX" 2>/dev/null) || tmp=""
    if [ -z "$tmp" ] || ! cp -- "$src" "$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$rec_dir/$name" 2>/dev/null; then
      [ -n "$tmp" ] && rm -f -- "$tmp"
      _record_write_line "$rec_dir" \
        "$(_record_entry "$tid" app "$phase" "$attempt" "$step" "" "$env" fail copy-failed)"
      echo "fail copy-failed"
      exit 0
    fi
    _record_write_line "$rec_dir" \
      "$(_record_entry "$tid" app "$phase" "$attempt" "$step" "$name" "$env" ok "")"
    echo "ok $name"
  ) || result="fail lock-failed"
  echo "${result:-fail unknown}"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  append)
    shift
    _record_cli_append "$@"
    exit $?
    ;;
  enabled)
    [ $# -eq 2 ] || {
      echo "Usage: record.sh enabled <pipeline log>" >&2
      exit 2
    }
    record_enabled "$2"
    exit $?
    ;;
  *)
    echo "Usage: record.sh append --tid ID --phase P --step LABEL --src FILE --url URL | enabled <log>" >&2
    exit 2
    ;;
  esac
fi
