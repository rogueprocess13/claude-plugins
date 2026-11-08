#!/usr/bin/env bash
# seed-run-check.sh — did implement run the ticket's seeder scenario on a
# clean baseline? (GitHub #601)
#
# Feature tickets that ship a seeder scenario (`seed.sh <scenario>` in a task
# or AC, or a `Seed command:` line) kept deferring the first run to VERIFY,
# where a plain contract bug or a clean-DB timing race cost a whole
# re-implement cycle. ticket-implement now runs the scenario twice from the
# same clean baseline VERIFY uses and records the result in notes.md as one
# of:
#   seed-run: clean <scenario> x2
#   seed-run: consumed-db (<why>)     ran, but on a DB an earlier run used
#   seed-run: static-only (<why>)     could not run; requests checked against
#                                     the API contract only
# This script finds the scenarios and reads the last record.
#
# Usage: seed-run-check.sh <ticket-dir> [plan-file ...] [--log-file L]
#   Scans context.md plus each plan file (tasks.md, simple-fix.md, ...).
#
# Output:
#   SEED_SCENARIOS=<space-separated names, or "seed-command">
#   SEED_RUN_STATUS=none | missing | clean | consumed-db | static-only
#     none = the ticket names no seeder scenario
# --log-file writes META|gate-warn for missing (warn) and for consumed-db /
# static-only (info), so VERIFY and the retro see that the clean-env path
# never ran.
#
# Exit: 0 none or clean, 1 missing / consumed-db / static-only, 2 usage.

_SRC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ticket_dir="" log_file=""
files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
  --log-file)
    log_file="${2:-}"
    shift 2 || exit 2
    ;;
  -*)
    echo "seed-run-check: unknown option $1" >&2
    exit 2
    ;;
  *)
    if [ -z "$ticket_dir" ]; then ticket_dir="$1"; else files+=("$1"); fi
    shift
    ;;
  esac
done
if [ -z "$ticket_dir" ] || [ ! -d "$ticket_dir" ]; then
  echo "usage: seed-run-check.sh <ticket-dir> [plan-file ...] [--log-file L]" >&2
  exit 2
fi

srcs=()
for f in "$ticket_dir/context.md" "${files[@]}"; do
  [ -f "$f" ] && srcs+=("$f")
done

scenarios=""
if [ "${#srcs[@]}" -gt 0 ]; then
  # `baseline` is the reset step VERIFY runs first, not a scenario.
  scenarios=$(grep -ohE 'seed\.sh[[:space:]]+[A-Za-z0-9_.-]+' "${srcs[@]}" 2>/dev/null |
    awk '{print $2}' | grep -vx 'baseline' | sort -u | tr '\n' ' ' || true)
  scenarios="${scenarios% }"
  if [ -z "$scenarios" ] && grep -qE '^[[:space:]*-]*Seed command:' "${srcs[@]}" 2>/dev/null; then
    scenarios="seed-command"
  fi
fi

status=none
if [ -n "$scenarios" ]; then
  status=missing
  if [ -f "$ticket_dir/notes.md" ]; then
    rec=$(grep -oE 'seed-run:[[:space:]]*(clean|consumed-db|static-only)' "$ticket_dir/notes.md" |
      tail -1 | sed -E 's/seed-run:[[:space:]]*//' || true)
    [ -n "$rec" ] && status="$rec"
  fi
fi

echo "SEED_SCENARIOS=${scenarios}"
echo "SEED_RUN_STATUS=${status}"

case "$status" in
none | clean) exit 0 ;;
esac
if [ -n "$log_file" ]; then
  if [ "$status" = missing ]; then
    bash "$_SRC_LIB/plog.sh" --log-file "$log_file" META gate-warn warn \
      "SEED_RUN_MISSING — seeder scenario(s) ${scenarios} never ran in implement; no seed-run: record in notes.md" || true
  else
    bash "$_SRC_LIB/plog.sh" --log-file "$log_file" META gate-warn info \
      "SEED_RUN_$(tr 'a-z-' 'A-Z_' <<<"$status") — seeder scenario(s) ${scenarios} not run on a clean baseline in implement" || true
  fi
fi
exit 1
