#!/usr/bin/env bash
# plan-binding.sh — binds a person's approval to the plan they approved.
#
# skills/ticket-approve/approve.sh records, with a human approval, the plan
# it showed the person. Every reader that needs a person's approval (the
# entry gate's human checks and `--mode implement` in gate-check.sh, and
# detect-resume.sh's release of a held ticket) checks the plan on disk
# against that record with plan_binding_check. This file is the one
# implementation of the hashing, the normalization and the comparison.
#
# The record, in the ticket's local manifest:
#   "approved_plan": {
#     "type": "simple-fix" | "openspec",
#     "dir": "<the plan directory as resolved; for display only>",
#     "location": "<physical path of simple-fix.md, or of the change dir>",
#     "id": "<sha256 of the canonical file list>",
#     "normalization": "task-checkbox-v1",
#     "files": [{"path": "<relative to dir>", "size": <bytes>, "sha256": "<hex>"}],
#     "recorded_at": "<ISO>"
#   }
# The plan files are simple-fix.md, or every file under the openspec change
# dir (hidden ones included), with paths relative to that dir, sorted.
#
# Normalization: a markdown task checkbox `[x]` / `[X]` at the start of a
# list item becomes `[ ]`. Same byte length, so IMPLEMENT ticking tasks.md
# changes neither a hash nor a size. `size` and `sha256` are of the
# normalized content.
#
# The check (append-only rule). A plan passes when the type and the
# location are the same, every approved file still exists as a regular
# file, and the first `size` bytes of its normalized content hash to the
# recorded sha256. Bytes after them are allowed only in the shape
# gate-reconcile appends after an approval (Step 6): after optional blank
# lines, an `## Amendment #<N>` section, plain text. When there are some, the
# check logs one `META|plan-binding|info|appended to approved plan <id>:
# <file>:+<n> (## Amendment #<N>, …)` line (once per distinct message).
# Anything else fails: other appended text, an approved file edited,
# shortened, removed or replaced, a file in the change dir that was not
# approved, a plan at another location, and a pipeline log that names
# another plan than the ticket's own. A human approval with no record
# (written before this change) fails too.
#
# Sourced:
#   plan_binding_resolve <TID> [--log-file F]   sets PB_TYPE, PB_DIR, PB_LOCATION, PB_FILES (array)
#   plan_binding_compute <TID> [--log-file F]   prints the record (no recorded_at); rc != 0 refuses
#   plan_binding_short_id <record-json>         first 12 hex of the id
#   plan_binding_check <TID> [--log-file F]     sets PB_STATUS, PB_DETAIL, PB_APPENDED
#       rc 0 match | appended, 1 changed | unbound, 2 could not evaluate
#   plan_binding_matches_exactly <TID> [--log-file F]
#       rc 0 only when the record equals the plan as it stands (no appended bytes)
#   plan_binding_display_name <name>            the name, or a placeholder when not plain
#   plan_binding_names_plain <record-json>      rc 0 when every file name and the dir are plain
#   plan_binding_hold_message <TID>             the operator text for PLAN_CHANGED_SINCE_APPROVAL
#
# CLI:
#   plan-binding.sh check <TID> [--log-file F]     PLAN_BINDING=match|appended|changed|unbound|error
#                                                  PLAN_BINDING_DETAIL=...  (exit as above)
#   plan-binding.sh compute <TID> [--log-file F]   the record as JSON
#
# The plan is found where the ticket's own files are (ticket-dir.sh
# resolve_plan_artifact without a log, from the current directory, the
# tickets root): simple-fix.md in the ticket dir, else the ticket's change
# dir. The pipeline log is an agent-written file, so its artifact record is
# never the source; when it names a plan, that must be the same plan (rc 4
# otherwise), because the consumers that read the plan look there first.
#
# What this does not guarantee: the manifest is a file an agent can write.
# The binding makes a rewrite of an approved plan visible and blocking; it
# does not stop an agent that also rewrites the record.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.

_PB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Already-loaded functions win: a caller (or a test) may have its own.
declare -f resolve_plan_artifact >/dev/null 2>&1 ||
  source "$_PB_LIB_DIR/ticket-dir.sh" 2>/dev/null || true
declare -f get_ticket_manifest_path >/dev/null 2>&1 ||
  source "$_PB_LIB_DIR/manifest-read.sh" 2>/dev/null || true
declare -f regression_risk_plain >/dev/null 2>&1 ||
  source "$_PB_LIB_DIR/regression-risk.sh" 2>/dev/null || true

PB_NORMALIZATION="task-checkbox-v1"
PB_HOLD_CODE="PLAN_CHANGED_SINCE_APPROVAL"

# _pb_sha_stdin — 64 hex of stdin; rc 2 when no sha256 tool gives one.
_pb_sha_stdin() {
  local sum=""
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum | awk '{print $1}') || sum=""
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 | awk '{print $1}') || sum=""
  fi
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || return 2
  printf '%s\n' "$sum"
}

# plan_binding_normalize <file> — the file with every list-item task checkbox
# `[x]`/`[X]` written as `[ ]`. Byte for byte otherwise.
plan_binding_normalize() {
  LC_ALL=C sed -E 's/^([[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+)\[[xX]\]/\1[ ]/' "$1"
}

# plan_binding_display_name <name> — the name when it is plain text with no
# pipe, tab or newline; a placeholder otherwise, so nothing an agent named a
# file reaches a terminal or the pipeline log as it is.
plan_binding_display_name() {
  local n="$1"
  if [ -n "$n" ] && declare -f regression_risk_plain >/dev/null 2>&1 &&
    regression_risk_plain "$n" && [[ "$n" != *[$'|\t\n']* ]]; then
    printf '%s' "$n"
  else
    printf '%s' "(a file whose name is not plain text)"
  fi
}

# _pb_resolve_one <TID> [<log>] — one resolve_plan_artifact call (with the
# log's artifact record when <log> is given). Sets PB_TYPE, PB_DIR,
# PB_LOCATION (canonical: the physical path of simple-fix.md, or of the
# change dir) and PB_FILES. rc 12 no plan, 2 ambiguous, 3 a plan entry is
# not a regular file.
_pb_resolve_one() {
  local tid="$1" log="${2:-}"
  PB_TYPE="" PB_DIR="" PB_LOCATION=""
  PB_FILES=()
  declare -f resolve_plan_artifact >/dev/null 2>&1 || return 2
  local out rc=0 PLAN_MODE="" PLAN_PATH="" CHANGE_DIR="" phys
  if [ -n "$log" ]; then
    out=$(resolve_plan_artifact "$tid" --log-file "$log" 2>/dev/null) || rc=$?
  else
    out=$(resolve_plan_artifact "$tid" 2>/dev/null) || rc=$?
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  eval "$out"
  case "$PLAN_MODE" in
  simple-fix)
    [ -f "$PLAN_PATH" ] && [ ! -L "$PLAN_PATH" ] || return 3
    PB_TYPE="simple-fix"
    PB_DIR=$(dirname "$PLAN_PATH")
    PB_FILES=("$(basename "$PLAN_PATH")")
    phys=$(cd "$PB_DIR" 2>/dev/null && pwd -P) || return 2
    PB_LOCATION="$phys/${PB_FILES[0]}"
    ;;
  openspec)
    [ -n "$CHANGE_DIR" ] && [ -d "$CHANGE_DIR" ] || return 12
    PB_TYPE="openspec"
    PB_DIR="${CHANGE_DIR%/}"
    PB_LOCATION=$(cd "$PB_DIR" 2>/dev/null && pwd -P) || return 2
    local f bad=0
    while IFS= read -r -d '' f; do
      [ -f "$f" ] && [ ! -L "$f" ] || bad=1
      PB_FILES+=("${f#"$PB_DIR"/}")
    done < <(find "$PB_DIR" -mindepth 1 ! -type d -print0 2>/dev/null | LC_ALL=C sort -z)
    [ "${#PB_FILES[@]}" -gt 0 ] || return 12
    [ "$bad" -eq 0 ] || return 3
    ;;
  *) return 12 ;;
  esac
  return 0
}

# plan_binding_resolve <TID> [--log-file F]
# The ticket's plan, found where the ticket's own files are: simple-fix.md in
# its ticket dir, else its openspec change dir (never from the log alone: a
# pipeline log is a file an agent writes). When a log is given and names a
# plan, that plan must be the same one; a log that points anywhere else is
# rc 4 (PB_LOG_LOCATION is what it named). Sets PB_TYPE, PB_DIR, PB_LOCATION,
# PB_FILES. rc 12 no plan, 2 ambiguous, 3 a plan entry is not a regular file,
# 4 the log names another plan, 64 usage.
plan_binding_resolve() {
  local tid="" log=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --log-file)
      log="${2:-}"
      shift 2
      ;;
    *)
      tid="$1"
      shift
      ;;
    esac
  done
  PB_LOG_LOCATION=""
  [ -n "$tid" ] || return 64
  local rc=0
  if [ -n "$log" ] && [ -f "$log" ]; then
    _pb_resolve_one "$tid" "$log" || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
      PB_LOG_LOCATION="$PB_LOCATION"
    fi
  fi
  rc=0
  _pb_resolve_one "$tid" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || return "$rc"
  if [ -n "$PB_LOG_LOCATION" ] && [ "$PB_LOG_LOCATION" != "$PB_LOCATION" ]; then
    return 4
  fi
  return "$rc"
}

# _pb_file_entry <dir> <rel> — {"path","size","sha256"} of the normalized file.
_pb_file_entry() {
  local dir="$1" rel="$2" tmp size sha
  tmp=$(mktemp) || return 2
  if ! plan_binding_normalize "$dir/$rel" >"$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  size=$(wc -c <"$tmp" | tr -d ' ') || size=""
  sha=$(_pb_sha_stdin <"$tmp") || sha=""
  rm -f "$tmp"
  [[ "$size" =~ ^[0-9]+$ ]] && [ -n "$sha" ] || return 2
  jq -nc --arg p "$rel" --argjson s "$size" --arg h "$sha" '{path: $p, size: $s, sha256: $h}'
}

# _pb_files_id <files-json-array> — sha256 over the sorted [path,size,sha256] list.
_pb_files_id() {
  jq -c 'sort_by(.path) | map([.path, .size, .sha256])' <<<"$1" | _pb_sha_stdin
}

# plan_binding_compute <TID> [--log-file F] — prints the record (without
# recorded_at). rc from plan_binding_resolve, or 2 when hashing failed.
plan_binding_compute() {
  local rc=0
  plan_binding_resolve "$@" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  command -v jq >/dev/null 2>&1 || return 2
  local f entry files="[]" id
  for f in "${PB_FILES[@]}"; do
    entry=$(_pb_file_entry "$PB_DIR" "$f") || return 2
    files=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$files") || return 2
  done
  files=$(jq -c 'sort_by(.path)' <<<"$files") || return 2
  id=$(_pb_files_id "$files") || return 2
  jq -nc --arg t "$PB_TYPE" --arg d "$PB_DIR" --arg l "$PB_LOCATION" --arg id "$id" --arg n "$PB_NORMALIZATION" \
    --argjson files "$files" '{type: $t, dir: $d, location: $l, id: $id, normalization: $n, files: $files}'
}

plan_binding_short_id() {
  jq -r '.id // "" | .[0:12]' <<<"$1" 2>/dev/null
}

# plan_binding_names_plain <record-json> — 0 when the dir and every file name
# can be shown as they are.
plan_binding_names_plain() {
  local n
  while IFS= read -r -d '' n; do
    [ "$(plan_binding_display_name "$n")" = "$n" ] || return 1
  done < <(jq -j '(.dir, .location, .files[].path) | . + "\u0000"' <<<"$1" 2>/dev/null)
  return 0
}

# _pb_amendment_headings <file> <offset> — the appended bytes of <file>
# after its first <offset> bytes, accepted only when they are what
# gate-reconcile appends after an approval: after optional blank lines, an
# `## Amendment #<N>` section (ticket-gate-reconcile Step 6), plain text with
# no NUL byte. Prints the `## Amendment #<N>` headings found; rc 1 otherwise.
_pb_amendment_headings() {
  local file="$1" off="$2" text n
  n=$(tail -c +"$((off + 1))" "$file" | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')
  [ "$n" = "$(($(wc -c <"$file" | tr -d ' ') - off))" ] || return 1
  text=$(
    tail -c +"$((off + 1))" "$file"
    printf x
  )
  text="${text%x}"
  local re=$'^([ \t\r]*\n)*## Amendment #[0-9]+([ \t\r\n]|$)'
  [[ "$text" =~ $re ]] || return 1
  declare -f regression_risk_plain >/dev/null 2>&1 && regression_risk_plain "$text" || return 1
  printf '%s\n' "$text" | grep -oE '^## Amendment #[0-9]+' | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}

# _pb_recorded <TID> — the record from the manifest. rc 1 none, 2 unreadable
# or not the expected shape.
_pb_recorded() {
  local path
  declare -f get_ticket_manifest_path >/dev/null 2>&1 || return 2
  path=$(get_ticket_manifest_path "$1" 2>/dev/null) || return 2
  [ -f "$path" ] || return 2
  jq -e 'has("approved_plan") and .approved_plan != null' "$path" >/dev/null 2>&1 || {
    jq -e 'type == "object"' "$path" >/dev/null 2>&1 && return 1
    return 2
  }
  jq -ec '.approved_plan
    | select(type == "object"
        and (.type == "simple-fix" or .type == "openspec")
        and (.location | type == "string" and startswith("/"))
        and (.files | type == "array" and length > 0)
        and all(.files[]; (.path | type == "string" and length > 0)
                          and (.size | type == "number" and . >= 0 and . == floor)
                          and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))))' "$path" 2>/dev/null || return 2
}

# _pb_log <log> <msg> — one META|plan-binding|info line, unless the same
# message is already in the log.
_pb_log() {
  local log="$1" msg="$2"
  [ -n "$log" ] || return 0
  msg=$(printf '%s' "$msg" | tr '|\n\r' '/  ')
  grep -qF -- "|META|plan-binding|info|$msg" "$log" 2>/dev/null && return 0
  printf '%s|META|plan-binding|info|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >>"$log" 2>/dev/null || true
}

# plan_binding_check <TID> [--log-file F]
# PB_STATUS match|appended|changed|unbound|error, PB_DETAIL (what changed,
# names shown only when plain), PB_APPENDED ("<file>:+<n>, ...").
plan_binding_check() {
  local tid="" log=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --log-file)
      log="${2:-}"
      shift 2
      ;;
    *)
      tid="$1"
      shift
      ;;
    esac
  done
  PB_STATUS="error" PB_DETAIL="" PB_APPENDED=""
  command -v jq >/dev/null 2>&1 || {
    PB_DETAIL="jq not found; the plan cannot be checked"
    return 2
  }
  local rec rc=0
  rec=$(_pb_recorded "$tid") || rc=$?
  if [ "$rc" -eq 1 ]; then
    PB_STATUS="unbound"
    PB_DETAIL="the approval predates plan binding: no approved plan is recorded for it"
    return 1
  elif [ "$rc" -ne 0 ]; then
    PB_STATUS="changed"
    PB_DETAIL="the recorded approved plan is unreadable or malformed"
    return 1
  fi

  local rtype rloc
  rtype=$(jq -r '.type' <<<"$rec")
  rloc=$(jq -r '.location' <<<"$rec")
  rc=0
  if [ -n "$log" ]; then plan_binding_resolve "$tid" --log-file "$log" || rc=$?; else plan_binding_resolve "$tid" || rc=$?; fi
  if [ "$rc" -eq 12 ] || [ "$rc" -eq 2 ]; then
    PB_STATUS="changed"
    PB_DETAIL="the approved $rtype plan is no longer found"
    [ "$rc" -eq 2 ] && PB_DETAIL="more than one plan matches this ticket"
    return 1
  elif [ "$rc" -eq 4 ]; then
    PB_STATUS="changed"
    PB_DETAIL="the pipeline log names another plan ($(plan_binding_display_name "$PB_LOG_LOCATION")) than the ticket's own ($(plan_binding_display_name "$PB_LOCATION"))"
    return 1
  elif [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    PB_DETAIL="the plan could not be resolved (rc $rc)"
    return 2
  fi
  if [ "$PB_TYPE" != "$rtype" ]; then
    PB_STATUS="changed"
    PB_DETAIL="the plan type changed: approved $rtype, now $PB_TYPE"
    return 1
  fi
  if [ "$PB_LOCATION" != "$rloc" ]; then
    PB_STATUS="changed"
    PB_DETAIL="the plan moved: approved $(plan_binding_display_name "$rloc"), now $(plan_binding_display_name "$PB_LOCATION")"
    return 1
  fi

  local -a changed=() appended=()
  local -A approved=()
  local path size sha cur tmp cur_size prefix heads
  while IFS=$'\t' read -r path size sha; do
    path=$(jq -r '.' <<<"$path")
    approved["$path"]=1
    case "$path" in
    /* | ../* | */../* | .. | */..)
      changed+=("$(plan_binding_display_name "$path") (not a path inside the plan)")
      continue
      ;;
    esac
    cur="$PB_DIR/$path"
    if [ ! -e "$cur" ] && [ ! -L "$cur" ]; then
      changed+=("$(plan_binding_display_name "$path") (removed)")
      continue
    fi
    if [ ! -f "$cur" ] || [ -L "$cur" ]; then
      changed+=("$(plan_binding_display_name "$path") (replaced: not a regular file)")
      continue
    fi
    tmp=$(mktemp) || {
      PB_DETAIL="mktemp failed"
      return 2
    }
    if ! plan_binding_normalize "$cur" >"$tmp"; then
      rm -f "$tmp"
      PB_DETAIL="$(plan_binding_display_name "$path") could not be read"
      return 2
    fi
    cur_size=$(wc -c <"$tmp" | tr -d ' ')
    if [ "$cur_size" -lt "$size" ]; then
      rm -f "$tmp"
      changed+=("$(plan_binding_display_name "$path") (shortened)")
      continue
    fi
    prefix=$(head -c "$size" "$tmp" | _pb_sha_stdin) || {
      rm -f "$tmp"
      PB_DETAIL="no sha256 tool (sha256sum or shasum)"
      return 2
    }
    heads=""
    if [ "$prefix" = "$sha" ] && [ "$cur_size" -gt "$size" ]; then
      heads=$(_pb_amendment_headings "$tmp" "$size") || heads="-"
    fi
    rm -f "$tmp"
    if [ "$prefix" != "$sha" ]; then
      changed+=("$(plan_binding_display_name "$path") (edited)")
    elif [ "$heads" = "-" ]; then
      changed+=("$(plan_binding_display_name "$path") (appended text that is not an ## Amendment section)")
    elif [ "$cur_size" -gt "$size" ]; then
      appended+=("$(plan_binding_display_name "$path"):+$((cur_size - size)) ($heads)")
    fi
  done < <(jq -r '.files[] | [(.path | tojson), (.size | tostring), .sha256] | @tsv' <<<"$rec")

  local f
  for f in "${PB_FILES[@]}"; do
    [ -n "${approved[$f]:-}" ] || changed+=("$(plan_binding_display_name "$f") (new file, not approved)")
  done

  if [ "${#appended[@]}" -gt 0 ]; then
    PB_APPENDED=$(
      IFS=';'
      printf '%s' "${appended[*]}"
    )
    PB_APPENDED="${PB_APPENDED//;/; }"
  fi
  if [ "${#changed[@]}" -gt 0 ]; then
    PB_STATUS="changed"
    PB_DETAIL=$(
      IFS=';'
      printf '%s' "${changed[*]}"
    )
    PB_DETAIL="the plan changed after a person approved it: ${PB_DETAIL//;/; }"
    return 1
  fi
  if [ -n "$PB_APPENDED" ]; then
    PB_STATUS="appended"
    PB_DETAIL="approved plan $(plan_binding_short_id "$rec"), bytes appended after the approved content: $PB_APPENDED"
    _pb_log "$log" "appended to approved plan $(plan_binding_short_id "$rec"): $PB_APPENDED"
    return 0
  fi
  PB_STATUS="match"
  PB_DETAIL="approved plan $(plan_binding_short_id "$rec") unchanged"
  return 0
}

# plan_binding_matches_exactly <TID> [--log-file F] — 0 only when the record
# equals the plan as it stands now, byte for byte (normalized): no appended
# bytes either. approve.sh's "already approved" shortcut.
plan_binding_matches_exactly() {
  local tid="$1"
  shift
  local rec cur
  rec=$(_pb_recorded "$tid") || return 1
  cur=$(plan_binding_compute "$tid" "$@") || return 1
  jq -e -n --argjson a "$rec" --argjson b "$cur" \
    '$a.type == $b.type and $a.location == $b.location and ($a.files | sort_by(.path)) == ($b.files | sort_by(.path))' >/dev/null 2>&1
}

# plan_binding_hold_message <TID> — the operator text, after a
# plan_binding_check that did not pass (uses PB_DETAIL).
plan_binding_hold_message() {
  printf '%s — %s. Read the plan, then a person runs, in their own terminal from the tickets root: bash ~/.claude/skills/ticket-approve/approve.sh %s' \
    "$PB_HOLD_CODE" "${PB_DETAIL:-the plan could not be checked}" "$1"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _pb_cmd="${1:-}"
  shift || true
  case "$_pb_cmd" in
  check)
    [ -n "${1:-}" ] || {
      echo "usage: plan-binding.sh check <TICKET-ID> [--log-file F]" >&2
      exit 64
    }
    _pb_rc=0
    plan_binding_check "$@" || _pb_rc=$?
    echo "PLAN_BINDING=$PB_STATUS"
    echo "PLAN_BINDING_DETAIL=$PB_DETAIL"
    exit "$_pb_rc"
    ;;
  compute)
    [ -n "${1:-}" ] || {
      echo "usage: plan-binding.sh compute <TICKET-ID> [--log-file F]" >&2
      exit 64
    }
    plan_binding_compute "$@"
    exit $?
    ;;
  *)
    echo "usage: plan-binding.sh check|compute <TICKET-ID> [--log-file F]" >&2
    exit 64
    ;;
  esac
fi
