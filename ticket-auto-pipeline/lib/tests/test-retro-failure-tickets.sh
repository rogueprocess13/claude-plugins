#!/usr/bin/env bash
# test-retro-failure-tickets.sh — retro.sh attributes failure codes to the
# tickets (or planner initiatives) that produced them (DET-SU-2).
#
# failure_histogram only carries {CODE: count}, so ticket-retro's SKILL.md had
# to guess which tickets contributed to a code. retro.sh now also emits
#   failure_tickets: {CODE: [tid, ...]}          sorted, unique
#   failure_context: {CODE: [{ticket, errors, transcripts}, ...]}
# where errors come from error_diagnostics.errors_by_ticket and transcripts
# are the existing <logs>/<tid>-*-agent.log captures.
#
# Usage: bash test-retro-failure-tickets.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RETRO_SH="$(cd "$LIB_DIR/../skills/ticket-retro" && pwd)/retro.sh"

PASS=0
FAIL=0
FILTER="${1:-}"
_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_TEST_TMPDIRS=()
_ws() {
  local d
  d=$(mktemp -d)
  _TEST_TMPDIRS+=("$d")
  mkdir -p "$d/logs" "$d/reposroot"
  echo "$d"
}
_cleanup() {
  local d
  for d in "${_TEST_TMPDIRS[@]}"; do rm -rf "$d" 2>/dev/null || true; done
}
trap _cleanup EXIT

# retro.sh calls _iso_now without sourcing heartbeat.sh (see
# test-retro-outcome-parse.sh); stub it.
_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export -f _iso_now

_log() { # DIR TID LINE...
  local d="$1" tid="$2"
  shift 2
  {
    echo '2026-11-10T10:00:00Z|META|schema|info|1'
    printf '%s\n' "$@"
  } >"$d/logs/$tid-pipeline.log"
}

_retro() { # DIR [ARGS...]
  local d="$1"
  shift
  (cd "$d" && CURSOR_FILE="$d/cursor.json" REPOS_ROOT="$d/reposroot" \
    bash "$RETRO_SH" --window 30 "$@" 2>/dev/null)
}

_EXEC='2026-11-10T10:01:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT missing simple-fix.md'

test_two_tickets_sorted_unique() {
  local d out
  d=$(_ws)
  _log "$d" A-2 "$_EXEC"
  _log "$d" A-1 "$_EXEC"
  out=$(_retro "$d" --force)
  [ "$(jq -c '.failure_tickets.EXEC_NO_ARTIFACT' <<<"$out")" = '["A-1","A-2"]' ]
}

test_heartbeat_error_in_context() {
  local d out
  d=$(_ws)
  _log "$d" A-1 "$_EXEC"
  _log "$d" A-2 "$_EXEC"
  echo '2026-11-10T10:00:30Z|api|get-issue|fail|linear 502|{"exit_code":1}' >"$d/logs/A-1-heartbeat.log"
  out=$(_retro "$d" --force)
  [ "$(jq -r '.failure_context.EXEC_NO_ARTIFACT[0].ticket' <<<"$out")" = A-1 ] &&
    [ "$(jq -r '.failure_context.EXEC_NO_ARTIFACT[0].errors[0].event' <<<"$out")" = get-issue ] &&
    [ "$(jq -c '.failure_context.EXEC_NO_ARTIFACT[1].errors' <<<"$out")" = '[]' ]
}

test_same_code_twice_counts_two_lists_once() {
  local d out
  d=$(_ws)
  _log "$d" A-1 "$_EXEC" '2026-11-10T10:02:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT again'
  out=$(_retro "$d" --force)
  [ "$(jq -r '.failure_histogram.EXEC_NO_ARTIFACT' <<<"$out")" = 2 ] &&
    [ "$(jq -c '.failure_tickets.EXEC_NO_ARTIFACT' <<<"$out")" = '["A-1"]' ]
}

test_every_histogram_code_attributed() {
  local d out
  d=$(_ws)
  _log "$d" A-1 "$_EXEC" \
    '2026-11-10T10:02:00Z|GATE|gate|fail|held: complex ticket' \
    '2026-11-10T10:03:00Z|META|verify-crash|fail|boom'
  out=$(_retro "$d" --force)
  [ "$(jq -c '.failure_histogram | keys' <<<"$out")" = "$(jq -c '.failure_tickets | keys' <<<"$out")" ] &&
    [ "$(jq -c '.failure_tickets.GATE_HELD_COMPLEX_TICKET' <<<"$out")" = '["A-1"]' ] &&
    [ "$(jq -c '.failure_tickets["verify-crash"]' <<<"$out")" = '["A-1"]' ]
}

test_planner_code_carries_initiative_id() {
  local d out init=INIT-1788079219-1490
  d=$(_ws)
  mkdir -p "$d/reposroot/.ticket-auto/initiatives/$init"
  printf '%s\n' '2026-11-10T10:00:00Z|META|schema|info|1' \
    '2026-11-10T10:01:00Z|META|crosscheck|fail|CITATION_UNRESOLVED vs-a.md: lib/x.ts:42' \
    >"$d/reposroot/.ticket-auto/initiatives/$init/state.log"
  out=$(_retro "$d" --force)
  [ "$(jq -c '.failure_tickets.CITATION_UNRESOLVED' <<<"$out")" = "[\"$init\"]" ] &&
    [ "$(jq -c '.failure_context.CITATION_UNRESOLVED[0].transcripts' <<<"$out")" = '[]' ]
}

test_transcripts_present_and_absent() {
  local d out
  d=$(_ws)
  _log "$d" A-1 "$_EXEC"
  _log "$d" A-2 "$_EXEC"
  : >"$d/logs/A-1-implement-agent.log"
  : >"$d/logs/A-12-implement-agent.log" # another ticket's prefix must not match
  out=$(_retro "$d" --force)
  [ "$(jq -c '.failure_context.EXEC_NO_ARTIFACT[0].transcripts' <<<"$out")" = '["./logs/A-1-implement-agent.log"]' ] &&
    [ "$(jq -c '.failure_context.EXEC_NO_ARTIFACT[1].transcripts' <<<"$out")" = '[]' ]
}

test_cursor_skipped_log_adds_no_ticket() {
  local d out
  d=$(_ws)
  _log "$d" A-1 "$_EXEC"
  _retro "$d" >/dev/null # first run writes the cursor
  out=$(_retro "$d")     # unchanged log: cursor-skipped
  [ "$(jq -r '.logs_skipped' <<<"$out")" = 1 ] &&
    [ "$(jq -c '.failure_tickets' <<<"$out")" = '{}' ] &&
    [ "$(jq -c '.failure_histogram' <<<"$out")" = '{}' ] &&
    [ "$(jq -c '.failure_context' <<<"$out")" = '{}' ]
}

test_no_failures_gives_empty_objects() {
  local d out
  d=$(_ws)
  _log "$d" A-1 '2026-11-10T10:01:00Z|IMPLEMENT|implement|done|ok'
  out=$(_retro "$d" --force)
  [ "$(jq -c '.failure_tickets' <<<"$out")" = '{}' ] &&
    [ "$(jq -c '.failure_context' <<<"$out")" = '{}' ]
}

echo "=== test-retro-failure-tickets.sh ==="
_run "two tickets give a sorted unique list" test_two_tickets_sorted_unique
_run "heartbeat error event lands in failure_context" test_heartbeat_error_in_context
_run "same code twice: counted 2, ticket listed once" test_same_code_twice_counts_two_lists_once
_run "every histogram code (gate-held, step fail) is attributed" test_every_histogram_code_attributed
_run "planner code carries the initiative id" test_planner_code_carries_initiative_id
_run "transcripts listed when present, [] when absent" test_transcripts_present_and_absent
_run "cursor-skipped log adds no ticket" test_cursor_skipped_log_adds_no_ticket
_run "no failures gives empty objects" test_no_failures_gives_empty_objects
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
