#!/usr/bin/env bash
# implement-rate.sh — ticket-implement Step 4c outcome rating
# (skill-deterministic-extraction 5).
#
# Usage:
#   implement-rate.sh --summary FILE
#   implement-rate.sh --fix-cycles N --discovery-rounds N --plan-deviation D
#
# FILE is the openspec agent's {DIFFICULTY_SUMMARY} JSON (fix_cycles,
# discovery_rounds, plan_deviation); a simple-fix run passes its own counts.
# Each signal maps to a label and the worst one wins:
#   fix_cycles        0 → Smooth, 1-2 → Rough, 3+ → Hard
#   discovery_rounds  0 → Smooth (none), 1-2 → Rough (minor), 3+ → Hard (significant)
#   plan_deviation    followed → Smooth, adapted → Rough, rewrote → Hard
# Prints OUTCOME=Smooth|Rough|Hard. Exit 0, 2 usage or an unreadable signal.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_ir_usage() {
  echo "usage: implement-rate.sh --summary FILE | --fix-cycles N --discovery-rounds N --plan-deviation followed|adapted|rewrote" >&2
  return 2
}

_ir_count_rank() { # N → 0|1|2
  [[ "$1" =~ ^[0-9]+$ ]] || return 2
  if [ "$1" -eq 0 ]; then echo 0; elif [ "$1" -le 2 ]; then echo 1; else echo 2; fi
}

implement_rate_main() {
  local fix="" disc="" dev="" summary=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || {
      _ir_usage
      return 2
    }
    case "$1" in
    --summary) summary="$2" ;;
    --fix-cycles) fix="$2" ;;
    --discovery-rounds) disc="$2" ;;
    --plan-deviation) dev="$2" ;;
    *)
      _ir_usage
      return 2
      ;;
    esac
    shift 2
  done
  if [ -n "$summary" ]; then
    [ -f "$summary" ] || {
      _ir_usage
      return 2
    }
    fix=$(jq -r '.fix_cycles // empty' "$summary" 2>/dev/null) || fix=""
    disc=$(jq -r '.discovery_rounds // empty' "$summary" 2>/dev/null) || disc=""
    dev=$(jq -r '.plan_deviation // empty' "$summary" 2>/dev/null) || dev=""
  fi
  local r1 r2 r3
  r1=$(_ir_count_rank "$fix") || {
    _ir_usage
    return 2
  }
  r2=$(_ir_count_rank "$disc") || {
    _ir_usage
    return 2
  }
  case "$dev" in
  followed) r3=0 ;;
  adapted) r3=1 ;;
  rewrote) r3=2 ;;
  *)
    _ir_usage
    return 2
    ;;
  esac
  local worst=$r1
  [ "$r2" -gt "$worst" ] && worst=$r2
  [ "$r3" -gt "$worst" ] && worst=$r3
  case "$worst" in
  0) echo "OUTCOME=Smooth" ;;
  1) echo "OUTCOME=Rough" ;;
  *) echo "OUTCOME=Hard" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  implement_rate_main "$@"
  exit $?
fi
