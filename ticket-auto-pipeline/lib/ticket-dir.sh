#!/usr/bin/env bash
# ticket-dir.sh — ticket workspace and plan-artifact resolution.
#
# resolve_ticket_dir <TICKET_ID> [<root>]
# Single match: emits path on stdout, exit 0.
# Multiple matches: exits 2, lists all matches on stderr.
# No match: exits 12, empty stdout.
#
# resolve_plan_artifact / resolve_change_dir / resolve_artifact_type /
# ticket_id_matches_name — see the "Plan-artifact resolution" section below.
#
# Sourceable lib, plus a CLI:
#   ticket-dir.sh plan <TICKET_ID> [--root R] [--ticket-dir D] [--log-file F] [--type T]
#   ticket-dir.sh change-dir <TICKET_ID> [<root>]
#   ticket-dir.sh artifact-type <log_file> [<notes_path>]

_TICKET_DIR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_TICKET_DIR_DIR/error-handler.sh" ]; then
  source "$_TICKET_DIR_DIR/error-handler.sh"
fi

resolve_ticket_dir() {
  local ticket_id="$1"
  local root="${2:-.}"
  local matches
  matches=$(find "$root" -maxdepth 2 -type d \
    -iregex ".*/${ticket_id}--[a-z0-9-]+$" 2>/dev/null || true)
  local count
  count=$(echo "$matches" | grep -c . 2>/dev/null || true)
  if [ -z "$matches" ] || [ "$count" -eq 0 ]; then
    hb_heartbeat "ticket-dir-not-found" "no workspace directory for ${ticket_id}" 2>/dev/null || true
    error_return 12 "ticket directory not found for ${ticket_id}"
  elif [ "$count" -eq 1 ]; then
    echo "$matches"
    return 0
  else
    echo "Multiple ticket dirs found for $ticket_id:" >&2
    echo "$matches" >&2
    return 2
  fi
}

# ── Plan-artifact resolution (one resolver, whole-ID matching) ──────────────
#
# Every plan-artifact lookup in the pipeline goes through the functions below
# (review findings DET-IP-2 / DET-AP-4). Earlier copies matched the ticket id
# as a substring (`grep -i wil-4`, `find -path "*WIL-4*"`, `*"$id"*`), so WIL-4
# picked up wil-42-..., wil-40-..., and `head -1` chose whichever sorted first.
#
# Naming conventions on disk:
#   ticket workspace dir  {ID}--{slug}           (ticket-setup)
#   openspec change dir   {id-lc}-{title-slug}   (ticket-appraise-exec Step 3)
#                         {id-lc}--{slug} and a bare {id-lc} are also accepted
# Whole-ID rule: the name, lowercased, equals the id or starts with "{id}-".
# A digit straight after the id (wil-42 for WIL-4) never matches, and neither
# does an id in the middle of a name. A ticket id never continues with
# "-<more>" after its number, so "{id}-" followed by anything (including a
# slug that starts with a digit, e.g. wil-4-2fa-login) belongs to that id.

# ticket_id_matches_name <TICKET_ID> <name>
# Exit 0 when <name> belongs to <TICKET_ID> under the whole-ID rule.
ticket_id_matches_name() {
  local tid name
  tid=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  name=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$tid" ] || return 1
  [ "$name" = "$tid" ] && return 0
  case "$name" in
  "$tid"-*) return 0 ;;
  esac
  return 1
}

# resolve_change_dir <TICKET_ID> [<root>]
# Finds this ticket's openspec change dir under <root>/openspec/changes/.
# Prints the dir with a trailing slash: "openspec/changes/<name>/" when root
# is "." (default), else "<root>/openspec/changes/<name>/".
# Exit 0 one match, 12 none, 2 several (all listed on stderr).
resolve_change_dir() {
  local ticket_id="$1"
  local root="${2:-.}"
  local base d name
  local -a found=()
  if [ "$root" = "." ]; then
    base="openspec/changes"
  else
    base="${root%/}/openspec/changes"
  fi
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    if ticket_id_matches_name "$ticket_id" "$name"; then
      found+=("$d")
    fi
  done
  case "${#found[@]}" in
  0)
    echo "ERROR [12]: no openspec change dir for ${ticket_id} under ${base}/" >&2
    return 12
    ;;
  1)
    echo "${found[0]}"
    return 0
    ;;
  *)
    echo "Multiple openspec change dirs found for $ticket_id:" >&2
    printf '%s\n' "${found[@]}" >&2
    return 2
    ;;
  esac
}

# resolve_artifact_type <log_file> [<notes_path>]
# Prints "openspec" or "simple-fix" from the last EXEC|create-artifact|done|
# log line, else from notes.md's "Artifact type:" line. Prints nothing when
# neither source names a type. Always exit 0.
resolve_artifact_type() {
  local log_file="${1:-}" notes_path="${2:-}" raw=""
  if [ -n "$log_file" ] && [ -f "$log_file" ]; then
    raw=$(grep '^[^|]*|EXEC|create-artifact|done|' "$log_file" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)
  fi
  if [ -z "$raw" ] && [ -n "$notes_path" ] && [ -f "$notes_path" ]; then
    raw=$(grep -i 'artifact.type' "$notes_path" 2>/dev/null | tail -1 | cut -d: -f2- || true)
  fi
  case "$raw" in
  *openspec*) echo "openspec" ;;
  *simple-fix*) echo "simple-fix" ;;
  esac
  return 0
}

# resolve_plan_artifact <TICKET_ID> [--root R] [--ticket-dir D] [--log-file F]
#                       [--type openspec|simple-fix]
# The one plan-artifact resolver. <root> is the tickets repo (default "."),
# which holds both the ticket workspace dirs and openspec/changes/.
# Order:
#   1. META|artifact|info|plan:<path> from the log, when that file exists
#      (a relative path is tried as-is, then under <root>)
#   2. simple-fix.md in the ticket dir (--ticket-dir, else resolve_ticket_dir)
#   3. this ticket's change dir (resolve_change_dir) containing tasks.md
# --type restricts the result to one mode (the log entry and steps 2/3).
# Emits eval-able lines: PLAN_MODE=simple-fix|openspec, PLAN_PATH=..., and
# CHANGE_DIR=... (openspec only, trailing slash).
# Exit 0 found, 12 none, 2 ambiguous (several change dirs or ticket dirs —
# all listed on stderr), 64 usage.
resolve_plan_artifact() {
  local ticket_id="" root="." ticket_dir="" log_file="" want=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --root)
      root="${2:-.}"
      shift 2
      ;;
    --ticket-dir)
      ticket_dir="${2:-}"
      shift 2
      ;;
    --log-file)
      log_file="${2:-}"
      shift 2
      ;;
    --type)
      want="${2:-}"
      shift 2
      ;;
    *)
      if [ -z "$ticket_id" ]; then
        ticket_id="$1"
        shift
      else
        echo "resolve_plan_artifact: unexpected argument: $1" >&2
        return 64
      fi
      ;;
    esac
  done
  if [ -z "$ticket_id" ]; then
    echo "Usage: resolve_plan_artifact <TICKET_ID> [--root R] [--ticket-dir D] [--log-file F] [--type openspec|simple-fix]" >&2
    return 64
  fi
  case "$want" in
  "" | openspec | simple-fix) ;;
  *)
    echo "resolve_plan_artifact: --type must be openspec or simple-fix" >&2
    return 64
    ;;
  esac

  # 1. The log's own record of the artifact it wrote.
  local logged="" cand mode
  if [ -n "$log_file" ] && [ -f "$log_file" ]; then
    logged=$(grep '^[^|]*|META|artifact|info|plan:' "$log_file" 2>/dev/null | tail -1 | cut -d'|' -f5- | sed 's/^plan://' || true)
  fi
  if [ -n "$logged" ]; then
    for cand in "$logged" "${root%/}/$logged"; do
      [ -f "$cand" ] || continue
      if [ "$(basename "$cand")" = "simple-fix.md" ]; then mode=simple-fix; else mode=openspec; fi
      if [ -n "$want" ] && [ "$want" != "$mode" ]; then
        break
      fi
      echo "PLAN_MODE=$mode"
      printf 'PLAN_PATH=%q\n' "$cand"
      if [ "$mode" = openspec ]; then
        printf 'CHANGE_DIR=%q\n' "$(dirname "$cand")/"
      fi
      return 0
    done
  fi

  local rc
  # 2. simple-fix.md in this ticket's workspace dir.
  if [ "$want" != openspec ]; then
    if [ -z "$ticket_dir" ]; then
      rc=0
      ticket_dir=$(resolve_ticket_dir "$ticket_id" "$root" 2>/dev/null) || rc=$?
      if [ "$rc" -eq 2 ]; then
        resolve_ticket_dir "$ticket_id" "$root" >/dev/null || true
        return 2
      fi
    fi
    if [ -n "$ticket_dir" ] && [ -f "${ticket_dir%/}/simple-fix.md" ]; then
      echo "PLAN_MODE=simple-fix"
      printf 'PLAN_PATH=%q\n' "${ticket_dir%/}/simple-fix.md"
      return 0
    fi
  fi

  # 3. This ticket's openspec change dir.
  if [ "$want" != simple-fix ]; then
    local change_dir
    rc=0
    change_dir=$(resolve_change_dir "$ticket_id" "$root" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 2 ]; then
      resolve_change_dir "$ticket_id" "$root" >/dev/null || true
      return 2
    fi
    if [ "$rc" -eq 0 ] && [ -f "${change_dir}tasks.md" ]; then
      echo "PLAN_MODE=openspec"
      printf 'PLAN_PATH=%q\n' "${change_dir}tasks.md"
      printf 'CHANGE_DIR=%q\n' "${change_dir}"
      return 0
    fi
  fi

  echo "ERROR [12]: no plan artifact found for ${ticket_id}${want:+ (type $want)}" >&2
  return 12
}

# Resolve the plan artifact path with full fallback chain (legacy signature,
# kept for callers that pass a log file and ticket dir). Thin wrapper over
# the steps resolve_plan_artifact uses.
# Args: <log_file> <ticket_dir> [ticket_id]
#   1. Pipeline log META|artifact|info|plan: entry
#   2. simple-fix.md in ticket directory
#   3. openspec/changes/*/tasks.md for the ticket ID (whole-ID match, CWD)
# Emits the resolved path on stdout; exit 12 if not found, 2 if ambiguous.
resolve_plan_path() {
  local log_file="$1"
  local ticket_dir="$2"
  local ticket_id="${3:-}"
  local plan_path

  plan_path=$(grep '|META|artifact|info|plan:' "$log_file" 2>/dev/null | tail -1 | cut -d'|' -f5 | sed 's/^plan://' || true)
  if [ -n "$plan_path" ] && [ -f "$plan_path" ]; then
    echo "$plan_path"
    return 0
  fi

  if [ -n "$ticket_dir" ] && [ -f "${ticket_dir%/}/simple-fix.md" ]; then
    echo "${ticket_dir%/}/simple-fix.md"
    return 0
  fi

  if [ -n "$ticket_id" ]; then
    local change_dir rc=0
    change_dir=$(resolve_change_dir "$ticket_id" ".") || rc=$?
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    if [ "$rc" -eq 0 ]; then
      echo "${change_dir}tasks.md"
      return 0
    fi
  fi

  error_return 12 "plan path not resolved for ${ticket_dir}"
}

# ── CLI (only when executed directly, not when sourced) ─────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _td_cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$_td_cmd" in
  plan)
    resolve_plan_artifact "$@"
    exit $?
    ;;
  change-dir)
    resolve_change_dir "$@"
    exit $?
    ;;
  artifact-type)
    resolve_artifact_type "$@"
    exit $?
    ;;
  ticket-dir)
    resolve_ticket_dir "$@"
    exit $?
    ;;
  *)
    echo "Usage: ticket-dir.sh plan|change-dir|artifact-type|ticket-dir ..." >&2
    exit 64
    ;;
  esac
fi
