#!/usr/bin/env bash
# adversarial-rounds.sh — round awareness for ticket-appraise-exec Step 3.6
# (adversarial review). GitHub issue #203: a plan that keeps coming back
# BLOCKED was re-reviewed with the identical prompt every round, so the gate
# never asked whether the *approach* — not the plan's level of detail — was
# the problem.
#
# adversarial_round_count <LOG_FILE>
#   Prints the number of CONSECUTIVE prior ADVERSARIAL_BLOCKED rounds for the
#   ticket whose pipeline log is LOG_FILE, i.e. the number of
#   `|META|gate-stop|fail|ADVERSARIAL_BLOCKED…` lines since the last passing
#   review. The round about to run is therefore round N+1.
#
#   Counting rules:
#   - Matched by code prefix: trailing detail text after the bare code
#     (`ADVERSARIAL_BLOCKED — round 2 — …`) is tolerated, the same way
#     exit-path.sh and detect-resume.sh match gate-stop codes.
#   - Reset by a passing verdict: an `|EXEC|adversarial-review|done|PASS` or
#     `|done|WARNINGS` line sets the count back to 0, so a ticket whose plan
#     later changes again starts its next streak fresh. A `done|BLOCKED` line
#     does NOT reset — it is written immediately before its own gate-stop.
#   - NOT reset by recovery lines: `|META|recovery|…` lines — including the
#     operator's `manual-recovery after ADVERSARIAL_BLOCKED gate-stop — plan
#     revised` note — are written between every pair of rounds (revising the
#     plan IS the recovery), so resetting on them would pin every round at 1
#     and defeat the point of counting.
#
#   A missing, empty, or unreadable LOG_FILE prints 0. Always returns 0 and
#   always prints exactly one integer, so it is safe to call as
#   `N=$(adversarial_round_count "$LOG_FILE")` under `set -euo pipefail`.
#
# CLI: bash adversarial-rounds.sh <LOG_FILE>

adversarial_round_count() {
  local log_file="${1:-}"
  if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
    echo 0
    return 0
  fi
  # awk (not grep -c) so a zero-match log still exits 0 and the count can be
  # reset mid-file by a passing verdict.
  awk -F'|' '
    { sub(/\r$/, "") }
    $2 == "META" && $3 == "gate-stop" && $4 == "fail" && $5 ~ /^ADVERSARIAL_BLOCKED([^A-Za-z0-9_]|$)/ { n++; next }
    $2 == "EXEC" && $3 == "adversarial-review" && $4 == "done" && $5 ~ /^(PASS|WARNINGS)([^A-Za-z0-9_]|$)/ { n = 0 }
    END { print n + 0 }
  ' "$log_file" 2>/dev/null || echo 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  adversarial_round_count "${1:-}"
fi
