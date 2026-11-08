#!/usr/bin/env bash
# grill-telemetry-stop.sh — Stop hook: write the grill_session record of every
# grill work directory this Claude session opened (GitHub #631).
#
# Every grill invocation ends its turn — sealed, waiting for answers, at the
# round cap, aborted or refused — so the turn's Stop is the one point all of
# them share. lib/grill-telemetry.sh registers the session in
# <state>/sessions/<session_id> (one work dir per line); this hook runs
# `finish` for each and removes the marker. Every path exits 0.

LIB="${BASH_SOURCE[0]%/*}/../lib"
STATE_ROOT="${GRILL_TELEMETRY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/grill-me/telemetry}"

payload=$(cat 2>/dev/null)
command -v jq >/dev/null 2>&1 || exit 0
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
[[ "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || exit 0
marker="${STATE_ROOT}/sessions/${sid}"
[ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || exit 0

while IFS= read -r dir; do
  case "$dir" in /*) ;; *) continue ;; esac
  [ -f "$dir/telemetry/open.json" ] || continue
  timeout 25 bash "$LIB/grill-telemetry.sh" finish "$dir" stop-hook >/dev/null 2>&1 || true
done <"$marker"

rm -f "$marker"
exit 0
