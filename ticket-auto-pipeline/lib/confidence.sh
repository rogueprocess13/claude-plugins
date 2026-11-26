#!/usr/bin/env bash
# confidence.sh — Shared confidence-computation helpers.
# Phase 0 RLVR — extracted from verifier-result.sh and planned-feedback-write.sh
# to prevent drift (F9).
#
# Usage: source this file, then call _compute_actual_confidence.
#
#   _compute_actual_confidence <outcome> [corrections]
#
# Outcome → base: Smooth → 0.90, Rough → 0.65, Hard → 0.40, unknown → 0.70.
# Corrections subtract 0.05 each. Floor at 0.10.
# Emits score string on [0.00, 0.90] scale (0.xx format).

# -u (nounset) intentionally omitted: sourced by callers that also omit -u
# for Claude Code shell snapshot ZSH_VERSION compatibility.
set -eo pipefail

_compute_actual_confidence() {
  local outcome="$1" corrections="${2:-0}"
  local base

  case "$outcome" in
  Smooth) base=90 ;;
  Rough) base=65 ;;
  Hard) base=40 ;;
  *) base=70 ;; # Unknown outcome — neutral
  esac

  local penalty=$((corrections * 5))
  local score=$((base - penalty))

  # Floor at 10
  [ "$score" -lt 10 ] && score=10

  # Convert to 0-1 scale (divide by 100)
  echo "0.${score}"
}

# _confidence_tier <value>
# The shared scale decision drift compares on (issue #826). The planner's
# confidence (planner_confidence_derive: 0.50 neutral, rarely above 0.75) and
# _compute_actual_confidence (Smooth 0.90) are different scales, so a raw
# difference was "major" on every Smooth ticket. Both map to one rank:
#   high   >= 0.75  (Smooth with at most 3 corrections; a well-evidenced plan)
#   medium 0.50-0.74 (Rough; Smooth with 4+ corrections; unknown outcome 0.70;
#                     the planner's neutral-to-moderate evidence)
#   low    <  0.50  (Hard; Rough with 4+ corrections; a thin or complex plan)
# Prints 2 / 1 / 0. A value that is not a plain decimal prints nothing, rc 1.
_confidence_tier() {
  local v="$1" int frac h
  [[ "$v" =~ ^([0-9]+)(\.([0-9]+))?$ ]] || return 1
  int="${BASH_REMATCH[1]}" frac="${BASH_REMATCH[3]}00"
  h=$((10#$int * 100 + 10#${frac:0:2}))
  if [ "$h" -ge 75 ]; then
    echo 2
  elif [ "$h" -ge 50 ]; then
    echo 1
  else
    echo 0
  fi
}
