#!/usr/bin/env bash
# seed-run-check.sh — run a ticket's seeder scenario in implement, safely,
# and check that it happened (GitHub #601).
#
# Feature tickets that ship a seeder scenario (`seed.sh <scenario>` in a task
# or AC, or a `Seed command:` line) kept deferring the first run to VERIFY,
# where a plain contract bug or a clean-DB timing race cost a whole
# re-implement cycle. ticket-implement now runs the scenario twice from a
# clean baseline before commit.
#
# The local app stack and its database are shared, on fixed ports, and
# ticket-verify holds lib/verify-lock.sh's single-flight lock while it uses
# them. A seeder run in implement therefore takes the same lock, and resets
# the baseline only with the command the project names in its CLAUDE.md
# (`SEED_RESET_CMD`). Nothing here improvises a reset.
#
# Subcommands:
#   prepare <TID> <ticket-dir> [--claude-md F] [--lock-timeout SECS]
#       Resolve SEED_RESET_CMD (CLAUDE.md, default ./CLAUDE.md) and acquire
#       the verify lock (default wait 600s). Prints SEED_RUN_PREPARE=locked
#       and SEED_RESET_CMD=<%q value>, exit 0. Otherwise records
#       `static-only` (no SEED_RESET_CMD / stack busy), prints
#       SEED_RUN_PREPARE=static-only, exit 1 — check the requests against
#       the API contract instead of running the scenario.
#   release
#       Release the verify lock (idempotent). Always run after prepare.
#   record <ticket-dir> <clean|consumed-db|static-only> <detail...>
#       Append `- seed-run: <status> <detail> (at <ISO>)` to notes.md.
#   check <ticket-dir> [plan-file ...] [--log-file L]
#       (also the default when the first argument is a directory)
#       Finds scenarios in context.md + plan files and reads the newest
#       seed-run record written after this implement cycle started (the last
#       IMPLEMENT|implement start/waiting line in --log-file). Records from
#       an earlier cycle, and untimestamped ones once a cycle start is
#       known, do not count.
#       Output: SEED_SCENARIOS=<names or "seed-command">,
#               SEED_RUN_STATUS=none|missing|clean|consumed-db|static-only
#       --log-file writes META|gate-warn|info|SEED_RUN_<STATUS> unless the
#       status is none or clean. Advisory: never blocks.
#
# Exit: 0 ok (none/clean, locked, recorded), 1 not ok, 2 usage.

_SRC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_src_usage() {
  echo "usage: seed-run-check.sh [check] <ticket-dir> [plan-file ...] [--log-file L]" >&2
  echo "       seed-run-check.sh prepare <TID> <ticket-dir> [--claude-md F] [--lock-timeout SECS]" >&2
  echo "       seed-run-check.sh record <ticket-dir> <clean|consumed-db|static-only> <detail...>" >&2
  echo "       seed-run-check.sh release" >&2
  exit 2
}

_src_record() {
  local dir="$1" status="$2"
  shift 2
  case "$status" in clean | consumed-db | static-only) ;; *) _src_usage ;; esac
  [ -d "$dir" ] || _src_usage
  printf -- '- seed-run: %s %s (at %s)\n' "$status" "$*" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$dir/notes.md"
}

_src_prepare() {
  local tid="${1:-}" dir="${2:-}" claude_md="./CLAUDE.md" timeout=600 reset=""
  [ -n "$tid" ] && [ -d "$dir" ] || _src_usage
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --claude-md | --lock-timeout)
      [ "$#" -ge 2 ] || _src_usage
      if [ "$1" = --claude-md ]; then claude_md="$2"; else timeout="$2"; fi
      shift 2
      ;;
    *) _src_usage ;;
    esac
  done
  # shellcheck source=claude-md-field.sh
  source "$_SRC_LIB/claude-md-field.sh"
  reset=$(claude_md_field "$claude_md" SEED_RESET_CMD 2>/dev/null) || reset=""
  if [ -z "$reset" ]; then
    _src_record "$dir" static-only "(no SEED_RESET_CMD in $claude_md: baseline reset not configured)"
    echo "SEED_RUN_PREPARE=static-only"
    return 1
  fi
  # shellcheck source=verify-lock.sh
  source "$_SRC_LIB/verify-lock.sh"
  if ! verify_lock_acquire "$tid" "$timeout"; then
    _src_record "$dir" static-only "(stack busy: verify lock not free after ${timeout}s)"
    echo "SEED_RUN_PREPARE=static-only"
    return 1
  fi
  echo "SEED_RUN_PREPARE=locked"
  printf 'SEED_RESET_CMD=%q\n' "$reset"
}

_src_check() {
  local ticket_dir="" log_file="" f
  local files=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --log-file)
      [ "$#" -ge 2 ] || _src_usage
      log_file="$2"
      shift 2
      ;;
    -*) _src_usage ;;
    *)
      if [ -z "$ticket_dir" ]; then ticket_dir="$1"; else files+=("$1"); fi
      shift
      ;;
    esac
  done
  [ -n "$ticket_dir" ] && [ -d "$ticket_dir" ] || _src_usage

  local srcs=()
  for f in "$ticket_dir/context.md" "${files[@]}"; do
    [ -f "$f" ] && srcs+=("$f")
  done

  local scenarios=""
  if [ "${#srcs[@]}" -gt 0 ]; then
    # Flags before the name are skipped; the name starts alphanumeric.
    # `baseline` is the reset step, not a scenario.
    scenarios=$(grep -ohE 'seed\.sh([[:space:]]+-[^[:space:]]+)*[[:space:]]+[A-Za-z0-9][A-Za-z0-9_.-]*' "${srcs[@]}" 2>/dev/null |
      awk '{print $NF}' | grep -vx 'baseline' | sort -u | tr '\n' ' ' || true)
    scenarios="${scenarios% }"
    if [ -z "$scenarios" ] && grep -qE '^[[:space:]*-]*Seed command:' "${srcs[@]}" 2>/dev/null; then
      scenarios="seed-command"
    fi
  fi

  local status=none since="" rec
  if [ -n "$scenarios" ]; then
    status=missing
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
      since=$(grep -E '^[^|]*\|IMPLEMENT\|implement\|(start|waiting)\|' "$log_file" | tail -1 | cut -d'|' -f1)
    fi
    if [ -f "$ticket_dir/notes.md" ]; then
      rec=$(SINCE="$since" awk '
        match($0, /seed-run:[ \t]*(clean|consumed-db|static-only)/) {
          s = substr($0, RSTART, RLENGTH); sub(/seed-run:[ \t]*/, "", s)
          ts = ""
          if (match($0, /\(at [0-9T:Z-]+\)/)) ts = substr($0, RSTART + 4, RLENGTH - 5)
          if (ENVIRON["SINCE"] != "" && (ts == "" || ts < ENVIRON["SINCE"])) next
          last = s
        }
        END { print last }
      ' "$ticket_dir/notes.md")
      [ -n "$rec" ] && status="$rec"
    fi
  fi

  echo "SEED_SCENARIOS=${scenarios}"
  echo "SEED_RUN_STATUS=${status}"

  case "$status" in none | clean) return 0 ;; esac
  if [ -n "$log_file" ]; then
    bash "$_SRC_LIB/plog.sh" --log-file "$log_file" META gate-warn info \
      "SEED_RUN_$(tr 'a-z-' 'A-Z_' <<<"$status") — seeder scenario(s) ${scenarios}: no clean-baseline run recorded in this implement cycle" || true
  fi
  return 1
}

case "${1:-}" in
prepare)
  shift
  _src_prepare "$@"
  ;;
release)
  # shellcheck source=verify-lock.sh
  source "$_SRC_LIB/verify-lock.sh"
  verify_lock_release
  ;;
record)
  shift
  [ "$#" -ge 2 ] || _src_usage
  _src_record "$@"
  ;;
check)
  shift
  _src_check "$@"
  ;;
'') _src_usage ;;
*) _src_check "$@" ;;
esac
exit $?
