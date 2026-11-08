#!/usr/bin/env bash
# ac-drift.sh — compare the tracker's acceptance criteria with the ticket
# workspace (GitHub #604).
#
# context.md is written once by ticket-setup. An operator can still edit the
# ticket's acceptance criteria in the tracker while the ticket is held at the
# gate. Before this check nothing carried those edits into context.md or the
# notes.md Verification Plan, so VERIFY planned from a stale AC list and
# under-counted.
#
# Usage:
#   ac-drift.sh <ticket-dir> [--description-file F] [--refresh]
#               [--tag GATE|VERIFY] [--log-file L]
#
# The tracker description is read from --description-file, else stdin.
#
# Output (eval-safe KEY=value lines, values %q-quoted):
#   AC_LINEAR, AC_CONTEXT, AC_VPLAN   item counts (AC_VPLAN = per-criterion
#                                     Verification Plan rows in notes.md)
#   AC_DRIFT                          true | false | unknown (the description
#                                     has no Acceptance Criteria items)
#   AC_ADDED_COUNT, AC_REMOVED_COUNT  items only in the tracker / only in
#                                     context.md (compared by normalised text)
#   AC_ADDED_<n>                      the tracker text of each added item
#   AC_REFRESHED                      true when --refresh rewrote context.md
#
# On drift, --log-file writes one line:
#   META|gate-warn|info|AC_DRIFT_AT_<TAG> — tracker N ACs, context.md M, ...
# --refresh replaces context.md's Acceptance Criteria section with the
# tracker's, so every later phase reads the current list.
#
# Exit: 0 no drift or unknown, 1 drift, 2 usage / ticket dir unreadable.

_AC_DRIFT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _ac_section — print the Acceptance Criteria section (heading excluded) of
# stdin. It ends at the next level-1/2 heading or a `---` rule (context.md
# separates its Description from Links with one). Fenced lines are skipped.
_ac_section() {
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    tolower($0) ~ /^##?[[:space:]]*acceptance criteria/ { f = 1; next }
    f && /^##?[[:space:]]/ { exit }
    f && /^---[[:space:]]*$/ { exit }
    f { print }
  '
}

# _ac_items — AC item lines of stdin's section. Checkbox items when there
# are any, else top-level bullets and numbered items.
_ac_items() {
  local section n
  section=$(_ac_section)
  n=$(grep -cE '^[[:space:]]*- \[[ xX]\][[:space:]]+[^[:space:]]' <<<"$section" || true)
  if [ "${n:-0}" -gt 0 ]; then
    grep -E '^[[:space:]]*- \[[ xX]\][[:space:]]+[^[:space:]]' <<<"$section"
  else
    grep -E '^([-*]|[0-9]+[.)])[[:space:]]+[^[:space:]]' <<<"$section" || true
  fi
}

# _ac_norm — strip the marker, lowercase, collapse whitespace.
_ac_norm() {
  sed -E 's/^[[:space:]]*(- \[[ xX]\]|[-*]|[0-9]+[.)])[[:space:]]*//' |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

_ac_count() { grep -c . <<<"$1" || true; }

# _ac_refresh <context.md> <description> — replace (or append) the AC
# section of context.md with the description's, heading included.
_ac_refresh() {
  local ctx="$1" desc="$2" new tmp
  new=$(printf '%s\n' "$desc" | _ac_section)
  new="## Acceptance Criteria"$'\n'"${new%$'\n'}"
  tmp="$ctx.ac-drift.$$"
  if grep -qiE '^##?[[:space:]]*acceptance criteria' "$ctx"; then
    NEW_AC="$new" awk '
      state == 1 && (/^##?[[:space:]]/ || /^---[[:space:]]*$/) { state = 2; print "" }
      state == 1 { next }
      state == 0 && tolower($0) ~ /^##?[[:space:]]*acceptance criteria/ { print ENVIRON["NEW_AC"]; state = 1; next }
      { print }
    ' "$ctx" >"$tmp"
  else
    {
      cat "$ctx"
      printf '\n%s\n' "$new"
    } >"$tmp"
  fi
  mv "$tmp" "$ctx"
}

ac_drift_main() {
  local ticket_dir="" desc_file="" refresh=false tag="GATE" log_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --description-file)
      desc_file="${2:-}"
      shift 2 || return 2
      ;;
    --refresh)
      refresh=true
      shift
      ;;
    --tag)
      tag="${2:-}"
      shift 2 || return 2
      ;;
    --log-file)
      log_file="${2:-}"
      shift 2 || return 2
      ;;
    -*)
      echo "ac-drift: unknown option $1" >&2
      return 2
      ;;
    *)
      ticket_dir="$1"
      shift
      ;;
    esac
  done
  if [ -z "$ticket_dir" ] || [ ! -f "$ticket_dir/context.md" ]; then
    echo "usage: ac-drift.sh <ticket-dir> [--description-file F] [--refresh] [--tag T] [--log-file L] (context.md required)" >&2
    return 2
  fi
  local desc
  if [ -n "$desc_file" ]; then
    [ -r "$desc_file" ] || {
      echo "ac-drift: cannot read $desc_file" >&2
      return 2
    }
    desc=$(cat "$desc_file")
  else
    desc=$(cat)
  fi
  desc="${desc//$'\r'/}"

  local lin_items ctx_items lin_norm ctx_norm
  lin_items=$(printf '%s\n' "$desc" | _ac_items)
  ctx_items=$(_ac_items <"$ticket_dir/context.md")
  lin_norm=$(_ac_norm <<<"$lin_items" | grep . | sort -u || true)
  ctx_norm=$(_ac_norm <<<"$ctx_items" | grep . | sort -u || true)

  local n_lin n_ctx n_vplan=0
  n_lin=$(_ac_count "$lin_items")
  n_ctx=$(_ac_count "$ctx_items")
  if [ -f "$ticket_dir/notes.md" ]; then
    # shellcheck source=vplan-parse.sh
    declare -f vplan_parse >/dev/null 2>&1 || source "$_AC_DRIFT_LIB/vplan-parse.sh"
    VPLAN_ROWS=0
    vplan_parse "$(cat "$ticket_dir/notes.md")" >/dev/null 2>&1 || true
    n_vplan="${VPLAN_ROWS:-0}"
  fi

  printf 'AC_LINEAR=%q\nAC_CONTEXT=%q\nAC_VPLAN=%q\n' "$n_lin" "$n_ctx" "$n_vplan"
  if [ "$n_lin" -eq 0 ]; then
    printf 'AC_DRIFT=unknown\nAC_ADDED_COUNT=0\nAC_REMOVED_COUNT=0\nAC_REFRESHED=false\n'
    return 0
  fi

  local added removed n_added n_removed
  added=$(comm -23 <(printf '%s\n' "$lin_norm") <(printf '%s\n' "$ctx_norm") | grep . || true)
  removed=$(comm -13 <(printf '%s\n' "$lin_norm") <(printf '%s\n' "$ctx_norm") | grep . || true)
  n_added=$(_ac_count "$added")
  n_removed=$(_ac_count "$removed")

  local drift=false
  if [ "$n_added" -gt 0 ] || [ "$n_removed" -gt 0 ]; then drift=true; fi
  # A Verification Plan that exists but is shorter than the AC list leaves
  # criteria unplanned even when context.md already matches.
  if [ "$n_vplan" -gt 0 ] && [ "$n_vplan" -lt "$n_lin" ]; then drift=true; fi

  printf 'AC_DRIFT=%s\nAC_ADDED_COUNT=%q\nAC_REMOVED_COUNT=%q\n' "$drift" "$n_added" "$n_removed"
  local i=0 line norm
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    norm=$(_ac_norm <<<"$line")
    if grep -qxF -- "$norm" <<<"$added"; then
      i=$((i + 1))
      printf 'AC_ADDED_%d=%q\n' "$i" "$(sed -E 's/^[[:space:]]*(- \[[ xX]\]|[-*]|[0-9]+[.)])[[:space:]]*//' <<<"$line")"
    fi
  done <<<"$lin_items"

  local refreshed=false
  if [ "$drift" = true ] && [ "$refresh" = true ] && { [ "$n_added" -gt 0 ] || [ "$n_removed" -gt 0 ]; }; then
    _ac_refresh "$ticket_dir/context.md" "$desc" && refreshed=true
  fi
  printf 'AC_REFRESHED=%s\n' "$refreshed"

  if [ "$drift" = true ]; then
    if [ -n "$log_file" ]; then
      bash "$_AC_DRIFT_LIB/plog.sh" --log-file "$log_file" META gate-warn info \
        "AC_DRIFT_AT_${tag} — tracker ${n_lin} ACs, context.md ${n_ctx}, vplan rows ${n_vplan}; added ${n_added}, removed ${n_removed}; context.md refreshed=${refreshed}" || true
    fi
    return 1
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ac_drift_main "$@"
  exit $?
fi
