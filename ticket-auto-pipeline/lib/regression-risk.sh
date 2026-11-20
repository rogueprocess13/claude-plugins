#!/usr/bin/env bash
# regression-risk.sh — the Regression Risk gate of ticket-implement Step 1
# (GitHub #771), as deterministic bash.
#
# ticket-appraise-exec Step 3.5 writes a `## ⚠️ Regression Risk` section into
# notes.md when the plan touches a file a prior fix touched. A person must
# acknowledge that risk before implementation starts.
#
# Two append-only lists in the ticket's local manifest carry the gate.
# notes.md is only where the risk is described:
#
#   "regression_risks": [{"risk": "<sha256>", "recorded_at": "<ISO>", "body": "<text>"}]
#       Every version of the risk that was ever seen. Written by `record`
#       (ticket-appraise-exec, right after the section is written) and by
#       `check` for any section it sees. Entries are never changed or removed.
#   "regression_acks": [{"risk": "<sha256>", "provenance": "human",
#                        "by": "<who>", "at": "<ISO>", "note": "<optional>"}]
#       A person acknowledged that version. Written only by the operator
#       script lib/regression-ack.sh.
#
# The gate passes only when EVERY recorded risk has a human acknowledgement.
# So none of these clears it: changing `**Status:** UNACKNOWLEDGED` to
# `ACKNOWLEDGED` by hand, deleting or renaming the section, or putting an
# earlier, already acknowledged text back while a later version was never
# acknowledged. A section the gate sees and cannot record is a hold.
#
# Sourced:
#   regression_risk_body <notes.md>         normalised section text; rc 1 = no section
#   regression_risk_fingerprint <notes.md>  64-hex sha256 of that text; rc 1 = no section
#   regression_risk_recorded <TID>          recorded risk shas, oldest first
#   regression_risk_outstanding <TID>       recorded shas with no human acknowledgement
#   regression_risk_ack_json <TID>          the latest human acknowledgement, or nothing
#
# CLI:
#   regression-risk.sh record <TID> [<notes.md>]
#     Records the section's fingerprint. Prints
#     REGRESSION_RISK_RECORDED=<12 hex>|none. Exit 0, 1 the manifest write
#     failed (the caller stops), 2 usage / notes.md not found.
#   regression-risk.sh check <TID> [<notes.md>]
#     Prints REGRESSION_RISK_GATE=clear|pass|hold and REGRESSION_RISK_ID=<12 hex>.
#     clear  no section and nothing ever recorded                     exit 0
#     pass   every recorded risk has a human acknowledgement          exit 0
#            log: IMPLEMENT|regression-risk|done|acknowledged: risk=…; provenance=human; by=…; at=…
#     hold   anything else                                            exit 1
#            log: META|gate-stop|fail|REGRESSION_RISK_UNACKNOWLEDGED — reason=…; risk=…
#            outbox: gate-held, once per risk
#     notes.md not found, REPOS_ROOT unresolved, no sha256 tool       exit 2
#     Only exit 0 lets the caller proceed. Hold reasons: unacknowledged,
#     risk-changed (the section differs from what was acknowledged),
#     earlier-risk (the section as it stands is acknowledged, another
#     recorded version is not), section-removed, record-failed (the section
#     could not be written to the manifest), hand-edit (notes.md says
#     ACKNOWLEDGED, the manifest does not), provenance (an entry that is not
#     a human's).
#   regression-risk.sh fingerprint <notes.md>
#
# What this does not guarantee: the manifest is a file an agent can write.
# The gate stops an agent that edits notes.md or skips a step; it does not
# stop one that rewrites the manifest by hand.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.

_RR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# regression_risk_body <notes.md>
# Every line of every Regression Risk section, whitespace-normalised. A
# section starts at a heading of any level (two or more `#`) whose text
# contains "regression risk" in any case, and ends at the next heading of
# the same or a higher level. Dropped: the heading, blank lines, and exactly
# three boilerplate lines, matched as whole lines: the status line
# (`**Status:** UNACKNOWLEDGED` / `ACKNOWLEDGED`) and the two fixed
# instruction lines ticket-appraise-exec has written. Any other line is part
# of the risk, including one that only starts with `**Status:**` or `→`.
regression_risk_body() {
  local notes="$1"
  [ -f "$notes" ] || return 1
  awk '
    function hlevel(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    {
      gsub(/\r/, "")
      line = $0
    }
    line ~ /^##+[ \t]/ {
      lv = hlevel(line)
      if (tolower(line) ~ /regression risk/) { insec = 1; seclv = lv; found = 1; next }
      if (insec && lv <= seclv) insec = 0
      if (!insec) next
    }
    !insec { next }
    {
      gsub(/[ \t]+/, " ", line)
      sub(/^ /, "", line); sub(/ $/, "", line)
      if (line == "") next
      if (line ~ /^\*\*Status:\*\* ?(UNACKNOWLEDGED|ACKNOWLEDGED)$/) next
      if (line ~ /^→ Edit this file and change Status to `ACKNOWLEDGED` before running `\/ticket-implement [A-Za-z{}-]+[0-9]*`\.$/) next
      if (line ~ /^→ A person acknowledges this from a terminal: `bash ~\/\.claude\/skills\/lib\/regression-ack\.sh [A-Za-z{}-]+[0-9]*`\. An edit here does not\.$/) next
      print line
    }
    END { exit(found ? 0 : 1) }
  ' "$notes"
}

_rr_sha256() {
  local sum=""
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum | awk '{print $1}') || sum=""
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 | awk '{print $1}') || sum=""
  else
    cat >/dev/null
  fi
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || return 2
  printf '%s\n' "$sum"
}

regression_risk_fingerprint() {
  local body
  body=$(regression_risk_body "$1") || return 1
  printf '%s' "$body" | _rr_sha256
}

# regression_risk_hand_edited <notes.md> — 0 when a `**Status:** ACKNOWLEDGED`
# line stands in the file (the retired hand-edit acknowledgement).
regression_risk_hand_edited() {
  grep -qE '^[[:space:]]*\*\*Status:\*\*[[:space:]]*ACKNOWLEDGED[[:space:]]*$' "$1" 2>/dev/null
}

_rr_manifest_path() {
  declare -f get_ticket_manifest_path >/dev/null 2>&1 ||
    source "$_RR_LIB_DIR/manifest-read.sh" 2>/dev/null || return 1
  local path
  path=$(get_ticket_manifest_path "$1" 2>/dev/null) || return 1
  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

regression_risk_recorded() {
  local path
  path=$(_rr_manifest_path "$1") || return 0
  jq -r '(.regression_risks // [])[] | .risk // empty' "$path" 2>/dev/null || true
}

regression_risk_outstanding() {
  local path
  path=$(_rr_manifest_path "$1") || return 0
  jq -r '(.regression_acks // []) as $a
    | (.regression_risks // [])[] | .risk as $r
    | select(($a | any(.risk == $r and .provenance == "human")) | not) | $r' \
    "$path" 2>/dev/null || true
}

regression_risk_ack_json() {
  local path
  path=$(_rr_manifest_path "$1") || return 0
  jq -c '[(.regression_acks // [])[] | select(.provenance == "human")] | last // empty' \
    "$path" 2>/dev/null || true
}

# _rr_record <TID> <sha> <notes.md> — append this version to the recorded
# list unless it is there, then confirm it is. rc 1 when it is not on record
# afterwards, whatever the reason.
_rr_record() {
  local tid="$1" sha="$2" notes="$3"
  if ! regression_risk_recorded "$tid" | grep -qx "$sha"; then
    declare -f set_ticket_regression_risk >/dev/null 2>&1 ||
      source "$_RR_LIB_DIR/manifest-write.sh" 2>/dev/null || return 1
    ensure_ticket_manifest "$tid" >/dev/null 2>&1 || return 1
    set_ticket_regression_risk "$tid" "$sha" "$(regression_risk_body "$notes")" >/dev/null 2>&1 || return 1
  fi
  regression_risk_recorded "$tid" | grep -qx "$sha"
}

# _rr_resolve <TID> <notes-arg> — sets RR_NOTES; rc 2 with a message when the
# ticket id is bad, notes.md is not found or REPOS_ROOT cannot be resolved.
_rr_resolve() {
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
    echo "regression-risk: notes.md for $tid not found — pass its path as the last argument" >&2
    return 2
  fi
  if [ -z "${REPOS_ROOT:-}" ] && [ -f "$_RR_LIB_DIR/ticket-env.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RR_LIB_DIR/ticket-env.sh" "$tid" 2>/dev/null || true
  fi
  if [ -z "${REPOS_ROOT:-}" ]; then
    echo "regression-risk: REPOS_ROOT is not set — the gate cannot read the ticket manifest for $tid. Export REPOS_ROOT and retry." >&2
    return 2
  fi
  RR_NOTES="$notes"
}

_rr_record_cli() {
  local tid="$1" sha rc=0
  _rr_resolve "$1" "${2:-}" || return 2
  sha=$(regression_risk_fingerprint "$RR_NOTES") || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "REGRESSION_RISK_RECORDED=none"
    return 0
  elif [ "$rc" -ne 0 ]; then
    echo "regression-risk: no sha256 tool (sha256sum or shasum)" >&2
    return 2
  fi
  _rr_record "$tid" "$sha" "$RR_NOTES" || {
    echo "regression-risk: could not record the risk in the manifest for $tid — stop; do not continue without it" >&2
    return 1
  }
  echo "REGRESSION_RISK_RECORDED=${sha:0:12}"
}

_rr_check() {
  local tid="$1" notes cur="" rc=0 record_failed=false
  _rr_resolve "$1" "${2:-}" || return 2
  notes="$RR_NOTES"

  cur=$(regression_risk_fingerprint "$notes") || rc=$?
  if [ "$rc" -eq 1 ]; then
    cur=""
  elif [ "$rc" -ne 0 ]; then
    echo "regression-risk: no sha256 tool (sha256sum or shasum) — cannot fingerprint the risk" >&2
    return 2
  else
    _rr_record "$tid" "$cur" "$notes" || record_failed=true
  fi

  local recorded outstanding
  recorded=$(regression_risk_recorded "$tid")
  outstanding=$(regression_risk_outstanding "$tid")
  if [ -z "$cur" ] && [ -z "$recorded" ]; then
    echo "REGRESSION_RISK_GATE=clear"
    return 0
  fi

  # The risk named in the output: the section as it stands when that is what
  # holds, else the newest version still waiting for a person.
  local sha="$cur"
  if [ -z "$sha" ] || { ! $record_failed && ! grep -qx "$sha" <<<"$outstanding"; }; then
    sha=$(tail -n 1 <<<"$outstanding")
  fi
  [ -n "$sha" ] || sha="${cur:-$(tail -n 1 <<<"$recorded")}"
  local id="${sha:0:12}"

  export TICKET_ID="${TICKET_ID:-$tid}"
  echo "REGRESSION_RISK_ID=$id"
  if ! $record_failed && [ -z "$outstanding" ]; then
    local ack ack_by ack_at
    ack=$(regression_risk_ack_json "$tid")
    [ -n "$ack" ] || ack='{}'
    ack_by=$(jq -r '.by // "unknown"' <<<"$ack" 2>/dev/null) || ack_by="unknown"
    ack_at=$(jq -r '.at // "unknown"' <<<"$ack" 2>/dev/null) || ack_at="unknown"
    bash "$_RR_LIB_DIR/plog.sh" IMPLEMENT regression-risk done \
      "acknowledged: risk=${id}; provenance=human; by=${ack_by}; at=${ack_at}" 2>/dev/null || true
    echo "REGRESSION_RISK_GATE=pass"
    return 0
  fi

  local path any_ack="" foreign=""
  path=$(_rr_manifest_path "$tid") || path=""
  if [ -n "$path" ]; then
    any_ack=$(jq -r '[(.regression_acks // [])[] | select(.provenance == "human")] | length' "$path" 2>/dev/null) || any_ack=""
    foreign=$(jq -r --arg r "$sha" '[(.regression_acks // [])[] | select(.risk == $r and .provenance != "human")] | length' "$path" 2>/dev/null) || foreign=""
  fi
  local reason="unacknowledged"
  if $record_failed; then
    reason="record-failed"
  elif [ -z "$cur" ]; then
    reason="section-removed"
  elif ! grep -qx "$cur" <<<"$outstanding"; then
    reason="earlier-risk"
  elif [ "${foreign:-0}" != "0" ] && [ -n "$foreign" ]; then
    reason="provenance"
  elif [ "${any_ack:-0}" != "0" ] && [ -n "$any_ack" ]; then
    reason="risk-changed"
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
"Regression Risk" section of notes.md and acknowledge it, in a terminal:

  bash ~/.claude/skills/lib/regression-ack.sh ${tid}

Editing or removing the section does not acknowledge the risk, and the script
needs a person at a terminal. Re-run /ticket-implement ${tid} after the
acknowledgement.
EOF
  case "$reason" in
  hand-edit) echo "notes.md says ACKNOWLEDGED, but no acknowledgement is recorded. A hand edit no longer counts." ;;
  risk-changed) echo "The risk changed since it was last acknowledged. The new version needs its own acknowledgement." ;;
  earlier-risk) echo "notes.md shows a version that was acknowledged, but another recorded version of the risk never was. Putting old text back does not clear it." ;;
  section-removed) echo "A regression risk was recorded for this ticket, and notes.md no longer has the section. Removing it does not clear the gate." ;;
  record-failed) echo "The risk could not be written to the ticket manifest, so the gate holds. Fix the manifest (permissions, disk) and re-run." ;;
  esac
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  check | record)
    [ -n "${2:-}" ] || {
      echo "usage: regression-risk.sh $1 <TICKET-ID> [<notes.md>]" >&2
      exit 2
    }
    if [ "$1" = "check" ]; then
      _rr_check "$2" "${3:-}"
    else
      _rr_record_cli "$2" "${3:-}"
    fi
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
    echo "usage: regression-risk.sh check|record <TICKET-ID> [<notes.md>] | fingerprint <notes.md>" >&2
    exit 2
    ;;
  esac
fi
