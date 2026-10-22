#!/usr/bin/env bash
# refinement-carryover.sh — carries the planner Refinement phase's non-blocking
# leftovers into ticket-auto's notes.md (planner-refinement-convergence design
# D7), and holds a ready planned ticket whose Linear text drifted from the body
# Refinement evaluated (design D6, appraisal half).
#
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling) and does not change SCRIPT_DIR. Reads only the local ticket
# manifest and planner directory; performs no tracker write. The single
# tracker read (the drift check's get_issue) happens only when the caller has
# sourced linear-api.sh itself and did not pass the description it already
# fetched.
#
# Public API:
#   refinement_carryover_section <TID>
#     Prints the `## Refinement Carry-over` markdown section built from
#     ready.semantic and ready.demoted, or nothing when there is nothing to
#     carry. Items:
#       - [agent-resolvable]  verified advisory EDGE_CASE_GAP, AC_NOT_TESTABLE,
#                             TEST_DATA_GAP (and any other advisory semantic
#                             code), and every ready.demoted code;
#       - [needs-human]       verified advisory SCOPE_AMBIGUOUS;
#       - ### Test candidates one item per verified advisory MISSING_CORE_AC.
#     Unverified findings, blocking findings and a stale or unavailable verdict
#     carry nothing. Exit 0 (including nothing to carry); 1 no manifest.
#
#   refinement_carryover_append <notes-file> <TID>
#     Writes the section into notes.md, replacing an existing one in place
#     (appending it at the end otherwise); removes it when there is nothing to
#     carry. Each [needs-human] item is also mirrored into `## Open Questions`
#     — the only section ticket-gate-reconcile reads — once, keyed by its
#     `(carry-over <key>)` suffix, so a struck-through answer is never re-added.
#     Idempotent. Exit 0; 1 notes file missing or manifest unreadable.
#
#   refinement_carryover_drift_check <TID> <notes-file> [<linear-desc>]
#     For a planned ticket whose cached ready.status is `ready`, classifies the
#     Linear description against the planner baseline (body-baseline.sh). On
#     adopt | conflict | local-ahead it adds a [needs-human] Open Question
#     naming `/ticket-planner resume <INIT> --refresh-bodies` and, when
#     LOG_FILE is set, logs `META|body-drift|info|<class>`. Never writes
#     body.md. Prints the class, or `skip:<reason>` (not-planned, not-ready,
#     no-body, read-failed). With no <linear-desc> argument it calls get_issue
#     when that function is defined. Exit 0; 1 usage error.

if ! declare -f get_ticket_manifest_field >/dev/null 2>&1 || ! declare -f body_baseline_classify >/dev/null 2>&1; then
  _RCO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if ! declare -f get_ticket_manifest_field >/dev/null 2>&1 && [ -f "$_RCO_LIB_DIR/manifest-read.sh" ]; then
    source "$_RCO_LIB_DIR/manifest-read.sh"
  fi
  if ! declare -f body_baseline_classify >/dev/null 2>&1 && [ -f "$_RCO_LIB_DIR/body-baseline.sh" ]; then
    source "$_RCO_LIB_DIR/body-baseline.sh"
  fi
fi

REFINEMENT_CARRYOVER_HEADING="## Refinement Carry-over"

# _rco_items <ready-json> — one JSON object per line:
#   {kind: "item"|"candidate", tag, key, text}
_rco_items() {
  printf '%s' "$1" | jq -c '
    def flat: tostring | gsub("[\r\n]+"; " ") | gsub("^\\s+|\\s+$"; "");
    def quoted: if (.quote // "") != "" then " — quote: \"" + (.quote | flat) + "\"" else "" end;
    def detail: if (.detail // "") != "" then ": " + (.detail | flat) else "" end;
    def dem: if (.demoted // "") != "" then " (demoted: " + (.demoted | flat) + ", does not block)" else "" end;
    (.semantic // {}) as $s
    | (if ($s.stale == true or $s.unavailable == true) then []
       else [($s.findings // [])[] | select(.verified == true and .severity == "advisory")] end) as $f
    | ($f[]
       | (.id // .code) as $k
       | if .code == "MISSING_CORE_AC" then
           {kind: "candidate", tag: "", key: $k,
            text: ("`" + .code + "`" + detail + quoted)}
         elif .code == "SCOPE_AMBIGUOUS" then
           {kind: "item", tag: "needs-human", key: $k,
            text: ("`" + .code + "`" + dem + detail + quoted)}
         else
           {kind: "item", tag: "agent-resolvable", key: $k,
            text: ("`" + .code + "`" + dem + detail + quoted)}
         end),
      ((.demoted // {}) | to_entries | sort_by(.key) | .[]
       | {kind: "item", tag: "agent-resolvable", key: ("demoted:" + .key),
          text: ("`" + .key + "` demoted by audit dispute (does not block): "
                 + ((.value.reason // "audit dispute") | flat)
                 + (.value | quoted))})
  ' 2>/dev/null
}

# _rco_ready <TID> — prints the manifest's ready object ("{}" when absent).
# Exit 1 when there is no manifest or it cannot be read.
_rco_ready() {
  local tid="$1" ready="" rc=0
  ready=$(get_ticket_manifest_field "$tid" ready 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 1
  if [ -z "$ready" ] || ! printf '%s' "$ready" | jq -e 'type == "object"' >/dev/null 2>&1; then
    ready="{}"
  fi
  printf '%s\n' "$ready"
}

refinement_carryover_section() {
  local tid="${1-}"
  [ -n "$tid" ] || {
    echo "refinement-carryover: usage: refinement_carryover_section <TID>" >&2
    return 1
  }
  local ready="" items=""
  ready=$(_rco_ready "$tid") || return 1
  items=$(_rco_items "$ready") || items=""
  [ -n "$items" ] || return 0

  local bullets="" cands=""
  bullets=$(printf '%s\n' "$items" | jq -r 'select(.kind == "item") | "- [" + .tag + "] " + .text + " (carry-over " + .key + ")"') || bullets=""
  cands=$(printf '%s\n' "$items" | jq -r 'select(.kind == "candidate") | "- " + .text + " (candidate " + .key + ")"') || cands=""
  [ -n "$bullets" ] || [ -n "$cands" ] || return 0

  printf '%s\n\n' "$REFINEMENT_CARRYOVER_HEADING"
  printf '%s\n' "_From the planner's Refinement phase. These items do not block by themselves: [agent-resolvable] items are investigation prompts, [needs-human] items are mirrored into Open Questions._"
  if [ -n "$bullets" ]; then
    printf '\n%s\n' "$bullets"
  fi
  if [ -n "$cands" ]; then
    printf '\n### Test candidates\n\n'
    printf '%s\n' "_Behaviour Refinement found no acceptance criterion for. ticket-implement adds a test per candidate or records why not; ticket-verify checks each as \`carry-over\` without failing the verdict._"
    printf '\n%s\n' "$cands"
  fi
  return 0
}

# _rco_replace_section <notes-file> <section-file> — replaces the carry-over
# section in place (heading to the next `## ` heading), appends it at the end
# when absent, removes it when <section-file> is empty.
_rco_replace_section() {
  local notes="$1" secfile="$2" tmp="$1.rco.$$"
  awk -v secfile="$secfile" -v heading="$REFINEMENT_CARRYOVER_HEADING" '
    BEGIN { while ((getline l < secfile) > 0) S[++ns] = l }
    function emit() { for (i = 1; i <= ns; i++) print S[i]; done = 1 }
    skip && /^## / { skip = 0; if (ns > 0) print "" }
    skip { next }
    $0 ~ "^" heading "[[:space:]]*$" {
      if (!done) emit()
      skip = 1
      next
    }
    { L[++nl] = $0 }
    { print }
    END {
      if (!done && ns > 0) {
        if (nl > 0 && L[nl] !~ /^[[:space:]]*$/) print ""
        emit()
      }
    }' "$notes" >"$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$notes" || {
    rm -f "$tmp"
    return 1
  }
}

# _rco_open_questions_add <notes-file> <lines-file> — inserts each line of
# <lines-file> at the end of `## Open Questions` (creating the section at the
# end of the file when absent).
_rco_open_questions_add() {
  local notes="$1" addfile="$2" tmp="$1.rco.$$"
  awk -v addfile="$addfile" '
    BEGIN { while ((getline l < addfile) > 0) A[++na] = l }
    function flush(   i, j, last) {
      last = 0
      for (i = 1; i <= nb; i++) if (B[i] !~ /^[[:space:]]*$/) last = i
      for (i = 1; i <= last; i++) print B[i]
      if (last == 1) print ""
      for (j = 1; j <= na; j++) print A[j]
      for (i = last + 1; i <= nb; i++) print B[i]
      nb = 0
      done = 1
    }
    insec && /^## / { flush(); insec = 0 }
    insec { B[++nb] = $0; next }
    !done && /^## Open Questions[[:space:]]*$/ { insec = 1; B[++nb] = $0; next }
    { print }
    END {
      if (insec) flush()
      if (!done && na > 0) {
        print ""
        print "## Open Questions"
        print ""
        for (j = 1; j <= na; j++) print A[j]
      }
    }' "$notes" >"$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$notes" || {
    rm -f "$tmp"
    return 1
  }
}

# _rco_mirror_questions <notes-file> <lines> — adds each "- [needs-human] …
# (carry-over <key>)" line to Open Questions unless that key already appears
# in Open Questions (open or struck through).
_rco_mirror_questions() {
  local notes="$1" lines="$2" line key addfile
  [ -n "$lines" ] || return 0
  addfile=$(mktemp) || return 1
  local oq=""
  oq=$(awk '/^## Open Questions[[:space:]]*$/ { on = 1; next } on && /^## / { on = 0 } on' "$notes" 2>/dev/null) || oq=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # sed, not ${line##*(…}: a caller with extglob on would read `*(` as a
    # pattern operator.
    key=$(printf '%s\n' "$line" | sed -n 's/.*\((carry-over [^)]*)\)[[:space:]]*$/\1/p') || key=""
    [ -n "$key" ] || continue
    if ! printf '%s\n' "$oq" | grep -qF -- "$key"; then
      printf '%s\n' "$line" >>"$addfile"
    fi
  done <<<"$lines"
  local rc=0
  if [ -s "$addfile" ]; then
    _rco_open_questions_add "$notes" "$addfile" || rc=1
  fi
  rm -f "$addfile"
  return "$rc"
}

refinement_carryover_append() {
  local notes="${1-}" tid="${2-}"
  [ -n "$notes" ] && [ -n "$tid" ] || {
    echo "refinement-carryover: usage: refinement_carryover_append <notes-file> <TID>" >&2
    return 1
  }
  [ -f "$notes" ] || {
    echo "refinement-carryover: no notes file '$notes'" >&2
    return 1
  }

  local section="" rc=0
  section=$(refinement_carryover_section "$tid") || rc=$?
  [ "$rc" -eq 0 ] || return 1

  local secfile
  secfile=$(mktemp) || return 1
  if [ -n "$section" ]; then
    printf '%s\n' "$section" >"$secfile"
  fi
  _rco_replace_section "$notes" "$secfile" || rc=1
  rm -f "$secfile"
  [ "$rc" -eq 0 ] || return 1

  # Mirror the [needs-human] items (top-level bullets only — never a test
  # candidate) into Open Questions, where the gate's hold rule reads them.
  local human=""
  human=$(printf '%s\n' "$section" | awk '/^### /{exit} /^- \[needs-human\] /{print}') || human=""
  _rco_mirror_questions "$notes" "$human" || return 1
  return 0
}

refinement_carryover_drift_check() {
  local tid="${1-}" notes="${2-}"
  [ -n "$tid" ] && [ -n "$notes" ] || {
    echo "refinement-carryover: usage: refinement_carryover_drift_check <TID> <notes-file> [<linear-desc>]" >&2
    return 1
  }

  if ! ticket_is_planned "$tid" >/dev/null 2>&1; then
    echo "skip:not-planned"
    return 0
  fi
  if ! ticket_is_ready "$tid" >/dev/null 2>&1; then
    echo "skip:not-ready"
    return 0
  fi

  local mpath="" pdir=""
  mpath=$(get_ticket_manifest_path "$tid" 2>/dev/null) || mpath=""
  [ -n "$mpath" ] && pdir=$(dirname "$mpath")
  if [ -z "$pdir" ] || [ ! -f "$pdir/body.md" ]; then
    echo "skip:no-body"
    return 0
  fi

  local desc=""
  if [ "$#" -ge 3 ]; then
    desc="$3"
  elif declare -f get_issue >/dev/null 2>&1; then
    local issue=""
    if ! issue=$(get_issue "$tid" 2>/dev/null) || [ -z "$issue" ]; then
      echo "skip:read-failed"
      return 0
    fi
    desc=$(printf '%s' "$issue" | jq -r '.description // ""' 2>/dev/null) || desc=""
  else
    echo "skip:read-failed"
    return 0
  fi

  local class=""
  class=$(body_baseline_classify "$pdir" "$desc" 2>/dev/null) || class=""
  if [ -z "$class" ]; then
    echo "skip:no-body"
    return 0
  fi

  case "$class" in
  adopt | conflict | local-ahead)
    local init=""
    init=$(_manifest_initiative_for_ticket "$tid" 2>/dev/null) || init="<INIT>"
    [ -f "$notes" ] || : >"$notes"
    _rco_mirror_questions "$notes" "- [needs-human] Linear description differs from the body Refinement evaluated (${class}) — run \`/ticket-planner resume ${init} --refresh-bodies\` or confirm the Linear text. (carry-over body-drift)" || true
    if [ -n "${LOG_FILE:-}" ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|body-drift|info|${class}" >>"$LOG_FILE" 2>/dev/null || true
    fi
    ;;
  esac
  echo "$class"
  return 0
}
