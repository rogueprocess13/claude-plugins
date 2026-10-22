#!/usr/bin/env bash
# test-adversarial-rounds.sh — unit tests for lib/adversarial-rounds.sh
# (GitHub #203: round awareness for ticket-appraise-exec Step 3.6).
# Usage: bash test-adversarial-rounds.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$LIB_DIR/adversarial-rounds.sh"
FILTER="${1:-}"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

# _log <name> <line>... — writes a fixture log and prints its path.
_log() {
  local f="$TMPDIR_T/$1.log"
  shift
  : >"$f"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$f"
  done
  echo "$f"
}

# _count <log> — runs the helper in a fresh shell under set -euo pipefail.
_count() {
  bash -c 'set -euo pipefail; source "$1"; adversarial_round_count "$2"' _ "$LIB" "$1"
}

_expect() {
  local want="$1" got="$2"
  [ "$got" = "$want" ] || {
    echo "  want '$want', got '$got'" >&2
    return 1
  }
}

GS='|META|gate-stop|fail|ADVERSARIAL_BLOCKED'
T='2026-07-05T10:00:00Z'

test_zero_when_no_blocks() {
  local f
  f=$(_log zero "$T|META|schema|info|1" "$T|EXEC|create-artifact|done|openspec" "$T|EXEC|adversarial-review|done|PASS")
  _expect 0 "$(_count "$f")"
}

test_one_block() {
  local f
  f=$(_log one "$T|META|schema|info|1" "$T|EXEC|adversarial-review|done|BLOCKED" "$T$GS — round 1 — X-1 adversarial review found blocking issues")
  _expect 1 "$(_count "$f")"
}

test_three_blocks() {
  local f
  f=$(_log three \
    "$T$GS — X-1 adversarial review found blocking issues" \
    "$T|EXEC|regression-guard|done|clear" \
    "$T|EXEC|adversarial-review|done|BLOCKED" \
    "$T$GS — round 2 — X-1 adversarial review found blocking issues" \
    "$T|EXEC|adversarial-review|done|BLOCKED" \
    "$T$GS — round 3 — X-1")
  _expect 3 "$(_count "$f")"
}

test_bare_code_without_detail() {
  local f
  f=$(_log bare "$T$GS" "$T$GS")
  _expect 2 "$(_count "$f")"
}

test_manual_recovery_does_not_reset() {
  local f
  f=$(_log recovery \
    "$T$GS — X-1 adversarial review found blocking issues" \
    "$T|META|recovery|info|manual-recovery after ADVERSARIAL_BLOCKED gate-stop — plan revised" \
    "$T|META|recovery|info|Resuming from STEP_2" \
    "$T$GS — round 2 — X-1")
  _expect 2 "$(_count "$f")"
}

test_pass_resets_count() {
  local f
  f=$(_log reset \
    "$T$GS — round 1" \
    "$T$GS — round 2" \
    "$T|EXEC|adversarial-review|done|PASS" \
    "$T$GS — round 1")
  _expect 1 "$(_count "$f")"
}

test_warnings_resets_count() {
  local f
  f=$(_log warn "$T$GS — round 1" "$T|EXEC|adversarial-review|done|WARNINGS")
  _expect 0 "$(_count "$f")"
}

test_done_blocked_does_not_reset() {
  local f
  f=$(_log doneblocked "$T$GS — round 1" "$T|EXEC|adversarial-review|done|BLOCKED")
  _expect 1 "$(_count "$f")"
}

test_other_gate_stops_ignored() {
  local f
  f=$(_log other \
    "$T|META|gate-stop|fail|EXEC_NO_ARTIFACT" \
    "$T|META|gate-stop|fail|ADVERSARIAL_BLOCKED_SOMETHING_ELSE" \
    "$T|META|gate-warn|warn|ADVERSARIAL_BLOCKED — not a stop" \
    "$T|EXEC|adversarial-review|done|BLOCKED")
  _expect 0 "$(_count "$f")"
}

test_crlf_lines() {
  local f="$TMPDIR_T/crlf.log"
  printf '%s\r\n' "$T$GS" "$T$GS — round 2" >"$f"
  _expect 2 "$(_count "$f")"
}

test_missing_log_file() {
  _expect 0 "$(_count "$TMPDIR_T/does-not-exist.log")"
}

test_empty_argument() {
  _expect 0 "$(bash -c 'set -euo pipefail; source "$1"; adversarial_round_count ""' _ "$LIB")"
}

test_no_argument_under_nounset() {
  _expect 0 "$(bash -c 'set -euo pipefail; source "$1"; adversarial_round_count' _ "$LIB")"
}

test_empty_log_file() {
  local f
  f=$(_log empty)
  _expect 0 "$(_count "$f")"
}

# The helper must return 0 on every path so `N=$(...)` never trips errexit,
# and a caller's following line must still run.
test_strict_caller_keeps_running() {
  local out
  out=$(bash -c 'set -euo pipefail; source "$1"; n=$(adversarial_round_count "$2"); echo "after:$n"' _ "$LIB" "$TMPDIR_T/nope.log")
  _expect "after:0" "$out"
}

test_sourcing_does_not_change_caller_options() {
  local out
  out=$(bash -c 'set +e; source "$1"; false; echo "still-here:$-"' _ "$LIB")
  case "$out" in
  still-here:*e*) return 1 ;;
  still-here:*) return 0 ;;
  *) return 1 ;;
  esac
}

test_cli_mode() {
  local f
  f=$(_log cli "$T$GS — round 1")
  _expect 1 "$(bash "$LIB" "$f")"
}

for fn in \
  test_zero_when_no_blocks \
  test_one_block \
  test_three_blocks \
  test_bare_code_without_detail \
  test_manual_recovery_does_not_reset \
  test_pass_resets_count \
  test_warnings_resets_count \
  test_done_blocked_does_not_reset \
  test_other_gate_stops_ignored \
  test_crlf_lines \
  test_missing_log_file \
  test_empty_argument \
  test_no_argument_under_nounset \
  test_empty_log_file \
  test_strict_caller_keeps_running \
  test_sourcing_does_not_change_caller_options \
  test_cli_mode; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
