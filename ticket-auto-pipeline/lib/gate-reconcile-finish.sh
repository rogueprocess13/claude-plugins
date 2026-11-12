#!/usr/bin/env bash
# gate-reconcile-finish.sh — ticket-gate-reconcile Steps 7-8
# (skill-deterministic-extraction 6a). Run from the tickets repo root.
#
# Usage:
#   gate-reconcile-finish.sh <TICKET-ID> decide --comments N --new-input N
#   gate-reconcile-finish.sh <TICKET-ID> hold --reason R
#   gate-reconcile-finish.sh <TICKET-ID> clean
#
# The pipeline log is <log-dir>/<TID>-pipeline.log and the heartbeat log
# <log-dir>/<TID>-heartbeat.log, as in gate-reconcile-prep.sh. RECONCILE_N is
# recomputed from the log the same way (this cycle's done line is not written
# yet, so prep and finish agree).
#
# decide  reconcile-decide.sh over notes.md (#599: hold on an unstruck
#         [needs-human] bullet or new-input comment, never on answers alone);
#         prints RECONCILE_DECISION=clean|clean-recorded|hold, HOLD_REASON,
#         RECONCILE_N. Writes nothing.
# hold    flow-run.sh re-claim (non-fatal), then
#         GATE|reconcile|done|cycle#N held: R and the reconcile-result
#         heartbeat. Run after the amendment comment is posted.
# clean   ac-drift.sh --refresh --tag GATE over
#         <ticket-dir>/artifacts/tracker-description.md (its AC_* output is
#         printed; exit 1 there means drift, not failure), then
#         GATE|reconcile|done|clean and the three clean heartbeats.
#
# Exit codes: 0 done, 2 usage; decide passes reconcile-decide.sh's own code.

_GF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_gf_usage() {
  sed -n '6,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
TID="${1:-}"
MODE="${2:-}"
[ -n "$TID" ] && [ "${TID#-}" = "$TID" ] || _gf_usage
shift 2 2>/dev/null || _gf_usage

# shellcheck source=ticket-env.sh
source "$_GF_DIR/ticket-env.sh" "$TID"
# The logs live in the anchored per-ticket state dir (lib/log-dir.sh,
# state-root-anchor), else (legacy, with a warning) ./logs under the tickets
# repo root; STATE_ROOT_STRICT=true and unresolved exits 13.
_gr_log_dir="$PWD/logs"
if [ -f "$_GF_DIR/log-dir.sh" ]; then
  # shellcheck source=log-dir.sh
  source "$_GF_DIR/log-dir.sh"
  _gr_ld_rc=0
  ticket_log_dir_or_legacy_set "$PWD/logs" || _gr_ld_rc=$?
  if [ "$_gr_ld_rc" -ne 0 ]; then
    exit "$_gr_ld_rc"
  fi
  _gr_log_dir="$TICKET_LOG_DIR_RESOLVED"
fi
export TAP_LOG="$_gr_log_dir/$TID-pipeline.log"
export HB_LOG_FILE="$_gr_log_dir/$TID-heartbeat.log"
# shellcheck source=ticket-dir.sh
source "$_GF_DIR/ticket-dir.sh"
set +eo pipefail
TICKET_DIR=$(resolve_ticket_dir "$TID" "." 2>/dev/null || echo ".")
NOTES_PATH="$TICKET_DIR/notes.md"
RECONCILE_N=$(grep -o '^[^|]*|GATE|reconcile|done|cycle#[0-9]*' "$TAP_LOG" 2>/dev/null |
  sed 's/.*cycle#//' | sort -u | wc -l | tr -d ' ')
RECONCILE_N=$((${RECONCILE_N:-0} + 1))
_hb() { bash "$_GF_DIR/hb-wrap.sh" "$@"; }

case "$MODE" in
decide)
  _c="" _n=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || _gf_usage
    case "$1" in
    --comments) _c="$2" ;;
    --new-input) _n="$2" ;;
    *) _gf_usage ;;
    esac
    shift 2
  done
  [ -n "$_c" ] || _gf_usage
  _rc=0
  _out=$(bash "$_GF_DIR/reconcile-decide.sh" --notes "$NOTES_PATH" --comments "$_c" --new-input "${_n:-0}") || _rc=$?
  printf '%s\n' "$_out"
  echo "RECONCILE_N=$RECONCILE_N"
  exit "$_rc"
  ;;
hold)
  [ "${1:-}" = --reason ] && [ -n "${2:-}" ] && [ $# -eq 2 ] || _gf_usage
  _reason="$2"
  # flow-run.sh logs any failure itself; it is non-fatal.
  bash "$_GF_DIR/flow-run.sh" --log-file "$TAP_LOG" "$TID" re-claim || true
  bash "$_GF_DIR/plog.sh" GATE reconcile done "cycle#${RECONCILE_N} held: ${_reason}"
  _hb decision "reconcile-result" "fired" "held: ${_reason}" "{\"cycle\":\"${RECONCILE_N}\",\"reason\":\"${_reason}\"}"
  ;;
clean)
  [ $# -eq 0 ] || _gf_usage
  bash "$_GF_DIR/ac-drift.sh" "$TICKET_DIR" --description-file "$TICKET_DIR/artifacts/tracker-description.md" --refresh --tag GATE --log-file "$TAP_LOG" || true
  bash "$_GF_DIR/plog.sh" GATE reconcile done "clean"
  _hb decision "reconcile-result" "fired" "clean pass — no open questions or new input" "{\"cycle\":\"${RECONCILE_N}\"}"
  _hb gate "reconcile" "ok" "clean pass — proceeding to implement"
  _hb gate "phase-transition" "ok" "GATE → IMPLEMENT"
  ;;
*) _gf_usage ;;
esac
exit 0
