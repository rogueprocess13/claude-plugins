#!/usr/bin/env bash
# regression-ack.sh — the one way to acknowledge a ticket's Regression Risk
# (GitHub #771). An operator script: a person runs it from a terminal.
#
# Usage:
#   regression-ack.sh <TICKET_ID> [--notes <notes.md>]
#       Show the Regression Risk section and its id. Acknowledges nothing.
#   regression-ack.sh <TICKET_ID> --risk <id> [--note "<why>"] [--notes <notes.md>]
#       Acknowledge the risk with that id (the 12 hex the show step printed;
#       a longer prefix or the full fingerprint also works).
#
# Two steps on purpose: the id names the content that was reviewed. When the
# section changed in between, the id no longer matches and nothing is
# recorded.
#
# An acknowledgement writes, in the ticket's local manifest:
#   regression_ack = {risk, provenance: "human", by, at[, note]}
# and one `gate-released` outbox event ({provenance: "human",
# gate: "regression-risk", risk}). It never edits notes.md and writes no
# pipeline-log line (nothing follows a run's outcome line); the gate
# (lib/regression-risk.sh check) logs the acknowledgement, with who and when,
# on the next ticket-implement run. A repeat for the same risk is a no-op.
# `by` is TICKET_ACK_BY, else `git config user.name`, else $USER.
#
# Refuses agent and fleetd-worker context (exit 4): CLAUDE_CODE_SESSION_ID,
# FLEET_WORKER_PID or FLEET_GENERATION set. This raises the bar; it is not a
# sandbox (same stance as adversarial-override.sh).
#
# Exit: 0 shown, acknowledged or already acknowledged, 2 usage, 3 notes.md or
#       manifest not found, 4 agent context, 5 no Regression Risk section,
#       6 --risk does not match the current section, 1 write failed.
set -eo pipefail

_RA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: regression-ack.sh <TICKET_ID> [--risk <id>] [--note \"<why>\"] [--notes <notes.md>]" >&2
  exit 2
}

tid="" risk="" note="" notes=""
while [ $# -gt 0 ]; do
  case "$1" in
  --risk | --note | --notes)
    [ $# -ge 2 ] || usage
    case "$1" in
    --risk) risk="$2" ;;
    --note) note="$2" ;;
    --notes) notes="$2" ;;
    esac
    shift 2
    ;;
  -*) usage ;;
  *)
    [ -z "$tid" ] || usage
    tid="$1"
    shift
    ;;
  esac
done
[[ "$tid" =~ ^[A-Z]+-[0-9]+$ ]] || usage
note=$(printf '%s' "$note" | tr '\n\r|' '   ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${FLEET_WORKER_PID:-}" ] || [ -n "${FLEET_GENERATION:-}" ]; then
  echo "regression-ack: refusing to run in an agent or fleetd-worker context (CLAUDE_CODE_SESSION_ID/FLEET_WORKER_PID/FLEET_GENERATION set). A person acknowledges a regression risk; run it from a terminal." >&2
  exit 4
fi

# shellcheck source=/dev/null
source "$_RA_DIR/manifest-write.sh"
# shellcheck source=/dev/null
source "$_RA_DIR/regression-risk.sh"

if [ -z "$notes" ]; then
  declare -f resolve_ticket_dir >/dev/null 2>&1 || source "$_RA_DIR/ticket-dir.sh" 2>/dev/null || true
  _dir=$(resolve_ticket_dir "$tid" . 2>/dev/null) || _dir=""
  [ -z "$_dir" ] || notes="$_dir/notes.md"
fi
if [ -z "$notes" ] || [ ! -f "$notes" ]; then
  echo "regression-ack: notes.md for $tid not found — run from the tickets root, or pass --notes <path>" >&2
  exit 3
fi

_rc=0
sha=$(regression_risk_fingerprint "$notes") || _rc=$?
if [ "$_rc" -eq 1 ]; then
  echo "regression-ack: $notes has no Regression Risk section — nothing to acknowledge" >&2
  exit 5
elif [ "$_rc" -ne 0 ]; then
  echo "regression-ack: no sha256 tool (sha256sum or shasum)" >&2
  exit 1
fi
id="${sha:0:12}"

if [ -z "$risk" ]; then
  echo "Regression Risk for $tid ($notes):"
  echo
  regression_risk_body "$notes" | sed 's/^/  /'
  echo
  echo "risk=$id"
  echo "acknowledged=false"
  echo "To acknowledge this risk: regression-ack.sh $tid --risk $id [--note \"<why it is acceptable>\"]"
  exit 0
fi

risk=$(printf '%s' "$risk" | tr 'A-F' 'a-f')
if ! [[ "$risk" =~ ^[0-9a-f]{12,64}$ ]] || [ "${sha:0:${#risk}}" != "$risk" ]; then
  echo "regression-ack: --risk $risk does not match the current Regression Risk section (risk=$id). It changed, or the id is wrong. Review it again: regression-ack.sh $tid" >&2
  exit 6
fi

ensure_ticket_manifest "$tid" || {
  echo "regression-ack: could not make $tid manifest-addressable (is REPOS_ROOT exported?)" >&2
  exit 3
}

ack=$(regression_risk_ack_json "$tid")
if [ -n "$ack" ] && [ "$(jq -r '.risk // ""' <<<"$ack")" = "$sha" ] &&
  [ "$(jq -r '.provenance // ""' <<<"$ack")" = "human" ]; then
  already=true
else
  already=false
  by="${TICKET_ACK_BY:-}"
  [ -n "$by" ] || by=$(git config user.name 2>/dev/null || true)
  [ -n "$by" ] || by="${USER:-unknown}"
  by=$(printf '%s' "$by" | tr '\n\r|;' '    ')
  set_ticket_regression_ack "$tid" "$sha" human "$by" "$note" || {
    echo "regression-ack: manifest write failed for $tid" >&2
    exit 1
  }
  ack=$(regression_risk_ack_json "$tid")
  if [ "$(jq -r '.risk // ""' <<<"$ack")" != "$sha" ]; then
    echo "regression-ack: manifest does not show the acknowledgement after the write" >&2
    exit 1
  fi
  # One gate-released record per acknowledged risk; fail-soft, the manifest
  # fact is the record the gate reads.
  (
    source "$_RA_DIR/events.sh" 2>/dev/null || exit 1
    emit_event --idem "${tid}:regression-ack:${id}" "$tid" gate-released \
      "$(jq -nc --arg r "$sha" '{provenance: "human", gate: "regression-risk", risk: $r}')"
  ) >/dev/null 2>&1 || echo "regression-ack: outbox event not written (the manifest fact stands)" >&2
fi

echo "risk=$id"
echo "acknowledged=true"
echo "already_acknowledged=$already"
echo "provenance=$(jq -r '.provenance' <<<"$ack")"
echo "by=$(jq -r '.by' <<<"$ack")"
echo "at=$(jq -r '.at' <<<"$ack")"
echo "Re-run /ticket-auto $tid (or /ticket-implement $tid) to continue."
