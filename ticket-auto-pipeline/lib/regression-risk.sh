#!/usr/bin/env bash
# regression-risk.sh — the Regression Risk gate of ticket-implement Step 1
# (GitHub #771), as deterministic bash.
#
# ticket-appraise-exec Step 3.5 writes a `## ⚠️ Regression Risk` section into
# notes.md when the plan touches a file a prior fix touched. A person must
# acknowledge that risk before implementation starts. The acknowledgement is
# a fact in the ticket's local manifest, written only by the operator script
# lib/regression-ack.sh (which refuses agent and fleetd-worker context):
#
#   "regression_ack": {"risk": "<sha256>", "provenance": "human",
#                      "by": "<who>", "at": "<ISO>", "note": "<optional>"}
#
# The gate never reads a status line in notes.md. Changing
# `**Status:** UNACKNOWLEDGED` to `ACKNOWLEDGED` by hand acknowledges nothing.
#
# The fact names the risk it acknowledges: `risk` is the fingerprint of the
# section's content. When a re-appraisal changes the table, the fingerprint
# changes and the gate holds again until a person acknowledges the new risk.
#
# Sourced:
#   regression_risk_body <notes.md>         normalised section text; rc 1 = no section
#   regression_risk_fingerprint <notes.md>  64-hex sha256 of that text; rc 1 = no section
#   regression_risk_ack_json <TID>          the manifest's regression_ack object, or nothing
#
# CLI:
#   regression-risk.sh check <TID> [<notes.md>]
#     Prints REGRESSION_RISK_GATE=clear|pass|hold and REGRESSION_RISK_ID=<12 hex>.
#     clear  no Regression Risk section                              exit 0
#     pass   the manifest holds a human acknowledgement of this risk exit 0
#            log: IMPLEMENT|regression-risk|done|acknowledged: risk=…; provenance=human; by=…; at=…
#     hold   anything else                                           exit 1
#            log: META|gate-stop|fail|REGRESSION_RISK_UNACKNOWLEDGED — reason=…; risk=…
#            outbox: gate-held, once per risk
#     notes.md not found or no sha256 tool                           exit 2
#     Hold reasons: unacknowledged, risk-changed (an acknowledgement exists for
#     different content), hand-edit (notes.md says ACKNOWLEDGED, the manifest
#     does not), provenance (the fact is not a human's).
#   regression-risk.sh fingerprint <notes.md>
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.

_RR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# regression_risk_body <notes.md>
# The section's content with everything a hand edit of the status could touch
# removed: the heading, any `**Status:**` line, any `→` instruction line and
# blank lines. Whitespace runs collapse to one space. The section ends at the
# next level-2 heading.
regression_risk_body() {
  local notes="$1"
  [ -f "$notes" ] || return 1
  awk '
    /^##[[:space:]]/ {
      insec = ($0 ~ /Regression Risk/)
      if (insec) found = 1
      next
    }
    !insec { next }
    /^[[:space:]]*\*\*Status:\*\*/ { next }
    /^[[:space:]]*→/ { next }
    {
      gsub(/\r/, "")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, ""); sub(/ $/, "")
      if ($0 != "") print
    }
    END { exit(found ? 0 : 1) }
  ' "$notes"
}

regression_risk_fingerprint() {
  local body sum=""
  body=$(regression_risk_body "$1") || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$body" | sha256sum | awk '{print $1}') || sum=""
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s' "$body" | shasum -a 256 | awk '{print $1}') || sum=""
  fi
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || return 2
  printf '%s\n' "$sum"
}

# regression_risk_hand_edited <notes.md> — 0 when the section carries a
# `**Status:** ACKNOWLEDGED` line (the retired hand-edit acknowledgement).
regression_risk_hand_edited() {
  awk '
    /^##[[:space:]]/ { insec = ($0 ~ /Regression Risk/); next }
    insec && /^[[:space:]]*\*\*Status:\*\*[[:space:]]*ACKNOWLEDGED/ { hit = 1 }
    END { exit(hit ? 0 : 1) }
  ' "$1" 2>/dev/null
}

regression_risk_ack_json() {
  local tid="$1" path
  declare -f get_ticket_manifest_path >/dev/null 2>&1 ||
    source "$_RR_LIB_DIR/manifest-read.sh" 2>/dev/null || return 0
  path=$(get_ticket_manifest_path "$tid" 2>/dev/null) || return 0
  [ -f "$path" ] || return 0
  jq -c '.regression_ack // empty | select(type == "object")' "$path" 2>/dev/null || true
}

_rr_check() {
  local tid="$1" notes="${2:-}" dir
  [[ "$tid" =~ ^[A-Z]+-[0-9]+$ ]] || {
    echo "regression-risk: invalid ticket id '$tid'" >&2
    return 2
  }
  if [ -z "$notes" ]; then
    declare -f resolve_ticket_dir >/dev/null 2>&1 || source "$_RR_LIB_DIR/ticket-dir.sh" 2>/dev/null || true
    dir=$(resolve_ticket_dir "$tid" . 2>/dev/null) || dir=""
    [ -z "$dir" ] || notes="$dir/notes.md"
  fi
  if [ -z "$notes" ] || [ ! -f "$notes" ]; then
    echo "regression-risk: notes.md for $tid not found — pass its path: regression-risk.sh check $tid <notes.md>" >&2
    return 2
  fi

  local sha rc=0
  sha=$(regression_risk_fingerprint "$notes") || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "REGRESSION_RISK_GATE=clear"
    return 0
  elif [ "$rc" -ne 0 ]; then
    echo "regression-risk: no sha256 tool (sha256sum or shasum) — cannot fingerprint the risk" >&2
    return 2
  fi
  local id="${sha:0:12}" ack ack_risk="" ack_prov="" ack_by="" ack_at=""
  ack=$(regression_risk_ack_json "$tid")
  if [ -n "$ack" ]; then
    ack_risk=$(jq -r '.risk // ""' <<<"$ack")
    ack_prov=$(jq -r '.provenance // ""' <<<"$ack")
    ack_by=$(jq -r '.by // ""' <<<"$ack")
    ack_at=$(jq -r '.at // ""' <<<"$ack")
  fi

  export TICKET_ID="${TICKET_ID:-$tid}"
  echo "REGRESSION_RISK_ID=$id"
  if [ "$ack_risk" = "$sha" ] && [ "$ack_prov" = "human" ]; then
    bash "$_RR_LIB_DIR/plog.sh" IMPLEMENT regression-risk done \
      "acknowledged: risk=${id}; provenance=human; by=${ack_by:-unknown}; at=${ack_at:-unknown}" 2>/dev/null || true
    echo "REGRESSION_RISK_GATE=pass"
    return 0
  fi

  local reason="unacknowledged"
  if [ -n "$ack_risk" ] && [ "$ack_risk" != "$sha" ]; then
    reason="risk-changed"
  elif [ -n "$ack" ] && [ "$ack_prov" != "human" ]; then
    reason="provenance"
  elif regression_risk_hand_edited "$notes"; then
    reason="hand-edit"
  fi

  bash "$_RR_LIB_DIR/plog.sh" META gate-stop fail \
    "REGRESSION_RISK_UNACKNOWLEDGED — reason=${reason}; risk=${id}" 2>/dev/null || true
  # One gate-held record per risk (the idem key), fail-soft: the gate's
  # verdict never depends on the outbox.
  (
    source "$_RR_LIB_DIR/events.sh" 2>/dev/null || exit 0
    emit_event --idem "${tid}:regression-hold:${id}" "$tid" gate-held \
      "$(jq -nc --arg r "$sha" '{reason: "regression-risk-unacknowledged", gate: "regression-risk", risk: $r}')"
  ) >/dev/null 2>&1 || true

  echo "REGRESSION_RISK_GATE=hold"
  echo "REGRESSION_RISK_REASON=$reason"
  cat <<EOF

Implementation blocked — unacknowledged regression risk (${reason}).

The plan for ${tid} touches code a prior fix touched. A person must review the
"Regression Risk" section of notes.md and acknowledge it, from a terminal:

  bash ~/.claude/skills/lib/regression-ack.sh ${tid}

Editing notes.md does not acknowledge the risk, and the script refuses to run
inside an agent session. Re-run /ticket-implement ${tid} after the
acknowledgement.
EOF
  case "$reason" in
  hand-edit) echo "notes.md says ACKNOWLEDGED, but no acknowledgement is recorded. A hand edit no longer counts." ;;
  risk-changed) echo "The risk changed since it was last acknowledged (${ack_risk:0:12} by ${ack_by:-unknown}). It needs a new acknowledgement." ;;
  esac
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  check)
    [ -n "${2:-}" ] || {
      echo "usage: regression-risk.sh check <TICKET-ID> [<notes.md>]" >&2
      exit 2
    }
    _rr_check "$2" "${3:-}"
    exit $?
    ;;
  fingerprint)
    [ -n "${2:-}" ] || {
      echo "usage: regression-risk.sh fingerprint <notes.md>" >&2
      exit 2
    }
    regression_risk_fingerprint "$2"
    exit $?
    ;;
  *)
    echo "usage: regression-risk.sh check <TICKET-ID> [<notes.md>] | fingerprint <notes.md>" >&2
    exit 2
    ;;
  esac
fi
