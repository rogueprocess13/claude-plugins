#!/usr/bin/env bash
# seed-scenarios.sh — list the seeder scenarios a ticket ships (GitHub #601).
#
# Feature tickets that ship a seeder scenario (`seed.sh <scenario>` in a task
# or AC, or a `Seed command:` line) only ever ran it inside the VERIFY
# criteria, after ~25 minutes of other checks, where a plain contract bug or
# a clean-DB timing race then cost a re-implement and a second full VERIFY.
# ticket-verify Step 1.6d now runs each scenario twice as a precheck, inside
# its own locked section and on its own clean baseline (env-start.sh + the
# blockers' seed-apply), before any criterion. This script finds the
# scenarios; it runs nothing.
#
# Usage: seed-scenarios.sh <ticket-dir> [plan-file ...]
#   Scans <ticket-dir>/context.md plus each plan file (tasks.md,
#   simple-fix.md, ...).
#
# Output (eval-safe): SEED_SCENARIOS=<%q space-separated names>, empty when
#   none. Flags before a name (`seed.sh --reset x`) are skipped, a name must
#   start with a letter or digit, and `baseline` (the reset step) is never a
#   scenario. A `Seed command:` line with no seed.sh scenario yields
#   `seed-command`.
#
# Exit: 0 (scenarios or none), 2 usage.

ticket_dir="${1:-}"
if [ -z "$ticket_dir" ] || [ ! -d "$ticket_dir" ]; then
  echo "usage: seed-scenarios.sh <ticket-dir> [plan-file ...]" >&2
  exit 2
fi
shift

srcs=()
for f in "$ticket_dir/context.md" "$@"; do
  [ -f "$f" ] && srcs+=("$f")
done

scenarios=""
if [ "${#srcs[@]}" -gt 0 ]; then
  scenarios=$(grep -ohE 'seed\.sh([[:space:]]+-[^[:space:]]+)*[[:space:]]+[A-Za-z0-9][A-Za-z0-9_.-]*' "${srcs[@]}" 2>/dev/null |
    awk '{print $NF}' | grep -vx 'baseline' | sort -u | tr '\n' ' ' || true)
  scenarios="${scenarios% }"
  if [ -z "$scenarios" ] && grep -qE '^[[:space:]*-]*Seed command:' "${srcs[@]}" 2>/dev/null; then
    scenarios="seed-command"
  fi
fi

printf 'SEED_SCENARIOS=%q\n' "$scenarios"
exit 0
