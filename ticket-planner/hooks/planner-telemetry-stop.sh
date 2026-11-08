#!/usr/bin/env bash
# planner-telemetry-stop.sh — Stop hook: close the planner run telemetry of
# every initiative this Claude session opened (GitHub #631).
#
# A planner invocation always ends its turn: on completion, on every halt
# (`exit 0` after a report) and on an error. So the turn's Stop is the one
# point every exit path shares, and the run summary is written here rather
# than at each halt in SKILL.md. `planner_telemetry_begin` registers the
# session in <state>/sessions/<session_id> (one initiative dir per line);
# this hook runs `finish` for each and removes the marker.
#
# Never blocks or fails the session: every path exits 0, and a session with
# no marker (any session that ran no planner) costs one stat.

LIB="${BASH_SOURCE[0]%/*}/../lib"
STATE_ROOT="${PLANNER_TELEMETRY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ticket-planner/telemetry}"

payload=$(cat 2>/dev/null)
command -v jq >/dev/null 2>&1 || exit 0
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
[[ "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || exit 0
marker="${STATE_ROOT}/sessions/${sid}"
[ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || exit 0

while IFS= read -r dir; do
  case "$dir" in
  /*/.ticket-auto/initiatives/INIT-*) ;;
  *) continue ;;
  esac
  [ -f "$dir/telemetry/open-run.json" ] || continue
  init="${dir##*/}"
  REPOS_ROOT="${dir%/.ticket-auto/initiatives/*}" \
    timeout 25 bash "$LIB/planner-run-telemetry.sh" finish "$init" stop-hook >/dev/null 2>&1 || true
done <"$marker"

rm -f "$marker"
exit 0
