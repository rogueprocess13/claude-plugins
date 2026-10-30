#!/usr/bin/env bash
# planner-draft-carryover.sh — Refinement carry-over of the draft readiness
# verdict and the epic's revision summary (openspec change
# planner-draft-readiness, slice S4: design D13, D14).
#
# A spec that passed draft readiness (planner-draft-readiness-gate.sh) has
# already been scanned, audited and possibly revised before TicketGen. A
# fresh Refinement sample would re-block on findings the gate resolved or
# demoted, so Refinement carries the draft verdict over:
#
#   - Import: the draft verdict is `ready` and the ticket's real body
#     (body.md, after TicketGen stored Linear's rendering) is equivalent to
#     the draft modulo ids, links and the Planner Context timestamp →
#     ticket-auto's dor_semantic_import stores the draft verdict (with the
#     gate's lineage.json) on the ticket. No agent spawn, no added round.
#   - Draft-passed scan: not equivalent, import refused, or the draft was
#     `blocked` but accepted (its blocking findings must not be re-imported)
#     → the ticket's prior lineage is seeded
#     from the draft, with the real unit hash for every unit unchanged modulo
#     ids, and the normal scan runs with DOR_SEMANTIC_PRIOR_PASSED=true
#     (marker file `planner/draft-passed`, read by planner_refinement_apply).
#     Non-structural findings become `draft-passed` advisories; a new
#     structural finding on an unchanged unit becomes
#     `draft-passed-structural`; a structural finding on changed text blocks.
#
# Neither touches a ticket that already has `ready.semantic`.
# PLANNER_DRAFT_VERDICT_IMPORT=false (or PLANNER_REFINEMENT_SEMANTIC=false)
# turns both off — the old Refinement path.
#
# Public API:
#   planner_draft_carryover_enabled
#       rc 0 when carry-over is on.
#   planner_draft_carryover_slug <map-file> <TID>
#       The spec slug whose ticket is <TID> (reverse of the token map).
#   planner_draft_carryover_status <INIT> <slug>
#       ready | accepted | blocked | unavailable | stale | none — the draft
#       verdict, `stale` when it is not for the spec's current draft body or
#       evaluator.
#   planner_draft_carryover_seed <map-file> <real-body-file> <draft-dir> [accepted]
#       Prints the prior lineage for a draft-passed scan (JSON). With
#       `accepted`, the draft's still-blocking findings (the ones the operator
#       accepted) leave the prior, so a re-raise on an unchanged unit is a new
#       finding and the draft-passed policy demotes it; a carried one would
#       stay blocking and re-halt Refinement on an accepted gap.
#   planner_draft_carryover_ticket <INIT> <TID> <pdir> <map-file>
#       Applies the rule to one ticket with no semantic verdict. Prints
#       `import`, `draft-passed` or `none`. Writes the
#       META|refinement-draft-import lines.
#   planner_draft_readiness_epic_summary <INIT>
#       The `## Revised by draft readiness` epic section (stdout), or nothing
#       when no spec was revised and no finding demoted. Epic only — never a
#       ticket body (D14), so ticket body hashes and the D13 equivalence are
#       unaffected.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_DRAFT_CARRYOVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_draft_readiness_combined_hash >/dev/null 2>&1; then
  # shellcheck source=planner-draft-readiness-gate.sh
  source "${_PLANNER_DRAFT_CARRYOVER_LIB_DIR}/planner-draft-readiness-gate.sh"
fi

# Per-ticket import lines are record lines, one per ticket: exempt from the
# duplicate-done suppression (planner-state.sh).
case " ${PLANNER_REPEATABLE_META_STEPS:-} " in
*" refinement-draft-import "*) ;;
*) PLANNER_REPEATABLE_META_STEPS="${PLANNER_REPEATABLE_META_STEPS:-} refinement-draft-import" ;;
esac

# Marker beside body.md: the next semantic apply of this ticket runs with
# DOR_SEMANTIC_PRIOR_PASSED=true. Holds "<slug> <draft body hash>".
PLANNER_DRAFT_PASSED_MARKER="draft-passed"

planner_draft_carryover_enabled() {
  [ "${PLANNER_DRAFT_VERDICT_IMPORT:-true}" != "false" ] &&
    [ "${PLANNER_REFINEMENT_SEMANTIC:-true}" != "false" ]
}

planner_draft_carryover_slug() {
  local map="$1" tid="$2"
  [ -f "$map" ] && [ -n "$tid" ] || return 1
  awk -F'\t' -v p="$PLANNER_DRAFT_ID_PREFIX" -v t="$tid" '
    $2 == t && index($1, p) == 1 { print substr($1, length(p) + 1); found = 1; exit }
    END { exit !found }' "$map"
}

planner_draft_carryover_status() {
  local init="$1" slug="$2" root dir vhash veval vstatus body combined
  root=$(planner_draft_readiness_root "$init") || {
    echo none
    return 0
  }
  dir="${root}/${slug}"
  if [ ! -f "${dir}/verdict" ]; then
    echo none
    return 0
  fi
  read -r vhash veval vstatus <"${dir}/verdict"
  _planner_refinement_source_deps >/dev/null || return 1
  if ! body=$(planner_draft_readiness_compose "$init" "$slug" 2>/dev/null) ||
    [ "$(_dor_body_hash "$body")" != "$vhash" ] ||
    [ "$veval" != "${DOR_SEMANTIC_EVALUATOR:-}" ]; then
    echo stale
    return 0
  fi
  case "$vstatus" in
  ready | unavailable) echo "$vstatus" ;;
  blocked)
    if combined=$(planner_draft_readiness_combined_hash "$init" 2>/dev/null) &&
      _planner_draft_accepted "$init" "$combined" >/dev/null; then
      echo accepted
    else
      echo blocked
    fi
    ;;
  *) echo none ;;
  esac
}

# _planner_draft_carryover_texts <body-text> <mode>
# One "<key>\t<sha256 of the record text>" line per section/unit record, in
# body order.
_planner_draft_carryover_texts() {
  local key text
  while IFS=$'\037' read -r -d '' key text; do
    printf '%s\t%s\n' "$key" "$(printf '%s' "$text" | sha256sum | cut -c1-64)"
  done < <(_dor_section_records "$1" "$2")
}

# _planner_draft_carryover_remap <real-file> <draft-file> <map> <mode> <real-hashes-json> <draft-hashes-json>
# The prior's hash map for a draft-passed scan. Both bodies go through
# planner_draft_readiness_equiv_text first (the real one rewritten to draft
# tokens, Linear links unwrapped, Generated normalised), so a record is
# "unchanged modulo ids" when its rewritten text equals some draft record's
# text. The rewritten real body's records pair with the real body's own
# records by position (the rewrite adds or removes no line); when the counts
# differ nothing pairs, which reads every unit as changed — the blocking
# side. A paired real record gets the REAL hash, so the drift test in
# dor_semantic_lineage_from reads it as unchanged; every other key keeps the
# draft's own hash (changed).
_planner_draft_carryover_remap() {
  local real="$1" draft="$2" map="$3" mode="$4" real_h="$5" draft_h="$6"
  local rtext dtext same
  rtext=$(planner_draft_readiness_equiv_text "$map" real <"$real") || return 1
  dtext=$(planner_draft_readiness_equiv_text "$map" draft <"$draft") || return 1
  same=$(awk -F'\t' '
      FNR == 1 { f++ }
      f == 1 { d[$2] = 1; next }
      f == 2 { rw[++nr] = $2; next }
      { ok[++no] = $1 }
      END { if (nr != no) exit; for (i = 1; i <= no; i++) if (rw[i] in d) print ok[i] }' \
    <(_planner_draft_carryover_texts "$dtext" "$mode") \
    <(_planner_draft_carryover_texts "$rtext" "$mode") \
    <(_planner_draft_carryover_texts "$(cat "$real")" "$mode") | jq -R . | jq -sc .) || return 1
  jq -nc --argjson r "$real_h" --argjson d "$draft_h" --argjson same "$same" \
    '$d + (reduce $same[] as $k ({}; .[$k] = $r[$k]))'
}

# _planner_draft_carryover_lineage <draft-dir>
# The draft's lineage: lineage.json when the gate wrote one (S3b), else a
# round-1 lineage rebuilt from semantic.json on the draft body (the halt-only
# gate keeps no lineage). Prints `null` when neither is possible.
_planner_draft_carryover_lineage() {
  local dir="$1" sem body hash base
  if [ -s "${dir}/lineage.json" ] && jq -e 'type == "object"' "${dir}/lineage.json" >/dev/null 2>&1; then
    jq -c . "${dir}/lineage.json"
    return 0
  fi
  if [ ! -s "${dir}/semantic.json" ] || [ ! -f "${dir}/body.md" ]; then
    echo null
    return 0
  fi
  sem=$(cat "${dir}/semantic.json")
  body=$(cat "${dir}/body.md")
  hash=$(_dor_body_hash "$body")
  base=$(echo "$sem" | jq -c '[(.findings // [])[]
    | {code, dimension, quote, quote_b, detail, verified,
       severity: (if .demoted != null then "blocking" else .severity end)}
    | with_entries(select(.value != null))]') || {
    echo null
    return 0
  }
  DOR_SEMANTIC_PRIOR_PASSED=false dor_semantic_lineage_from null "$body" "$hash" "$base" \
    "$(echo "$sem" | jq -c '.audit // []')" 2>/dev/null | jq -c '.lineage' 2>/dev/null || echo null
}

planner_draft_carryover_seed() {
  local map="$1" real="$2" dir="$3" draft="${3}/body.md" accepted="${4:-}" lineage rbody dbody
  local r_units r_sec d_units d_sec units sec
  lineage=$(_planner_draft_carryover_lineage "$dir")
  [ -n "$lineage" ] && [ "$lineage" != "null" ] || return 1
  rbody=$(cat "$real")
  dbody=$(cat "$draft")
  r_units=$(_dor_unit_hashes "$rbody") || return 1
  r_sec=$(_dor_section_hashes "$rbody") || return 1
  d_units=$(echo "$lineage" | jq -c '.units // empty')
  [ -n "$d_units" ] || d_units=$(_dor_unit_hashes "$dbody") || return 1
  d_sec=$(echo "$lineage" | jq -c '.section_hashes // empty')
  [ -n "$d_sec" ] || d_sec=$(_dor_section_hashes "$dbody") || return 1
  units=$(_planner_draft_carryover_remap "$real" "$draft" "$map" units "$r_units" "$d_units") || return 1
  sec=$(_planner_draft_carryover_remap "$real" "$draft" "$map" sections "$r_sec" "$d_sec") || return 1
  local drop='[]'
  if [ "$accepted" = accepted ] && [ -s "${dir}/semantic.json" ]; then
    drop=$(jq -c '[(.findings // [])[] | select(.severity == "blocking") | .id | select(. != null)]' \
      "${dir}/semantic.json" 2>/dev/null) || drop='[]'
  fi
  echo "$lineage" | jq -c --argjson u "$units" --argjson s "$sec" --argjson drop "$drop" \
    '. + {units: $u, section_hashes: $s, seeded_from: "draft",
          findings: [(.findings // [])[] | select(.id as $i | ($drop | index($i)) == null)]}'
}

planner_draft_carryover_ticket() {
  local init="$1" tid="$2" pdir="$3" map="$4" slug status dir body_file out rc
  body_file="${pdir}/body.md"
  rm -f "${pdir}/${PLANNER_DRAFT_PASSED_MARKER}" 2>/dev/null
  if ! planner_draft_carryover_enabled || ! slug=$(planner_draft_carryover_slug "$map" "$tid"); then
    echo none
    return 0
  fi
  dir="$(planner_draft_readiness_root "$init")/${slug}"
  status=$(planner_draft_carryover_status "$init" "$slug")
  case "$status" in ready | accepted) ;; *)
    echo none
    return 0
    ;;
  esac

  # Import: a `ready` draft (the gate's own end-of-loop demotions included)
  # whose body is equivalent; same evaluator (dor_semantic_import refuses
  # another with rc 2). An accepted draft still holds the blocking findings
  # the operator accepted, so importing it would re-halt Refinement on them:
  # it takes the draft-passed scan instead.
  if [ "$status" = ready ] && [ -s "${dir}/semantic.json" ] &&
    planner_draft_readiness_equivalent "$map" "$body_file" "${dir}/body.md"; then
    local lin="null"
    [ -s "${dir}/lineage.json" ] && lin="${dir}/lineage.json"
    rc=0
    out=$(dor_semantic_import "$tid" "$body_file" "${dir}/semantic.json" "$lin" "$map" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      planner_state_write "$init" "META" "refinement-draft-import" "done" \
        "${tid} from=${PLANNER_DRAFT_ID_PREFIX}${slug} ${out}"
      echo import
      return 0
    fi
  fi

  # Draft-passed scan: not equivalent, import refused, or accepted.
  local prior round
  local acc=""
  [ "$status" = accepted ] && acc=accepted
  if prior=$(planner_draft_carryover_seed "$map" "$body_file" "$dir" "$acc") &&
    set_ticket_lineage "$tid" "$prior" >/dev/null 2>&1; then
    printf '%s %s\n' "$slug" "$(cut -d' ' -f1 "${dir}/verdict")" >"${pdir}/${PLANNER_DRAFT_PASSED_MARKER}"
    round=$(echo "$prior" | jq -r '(.round // 0) + 1')
    planner_state_write "$init" "META" "refinement-draft-import" "skip" \
      "${tid} not-equivalent draft-passed round=${round}"
    echo draft-passed
    return 0
  fi
  echo none
}

# ── Epic summary (D14) ────────────────────────────────────────────────────

# _planner_draft_ac_items <spec-file> — the Acceptance Criteria items, one per
# line, list marker stripped.
_planner_draft_ac_items() {
  [ -f "$1" ] || return 0
  tr -d '\r' <"$1" | awk '
    /^## +Acceptance Criteria[[:space:]]*$/ { on = 1; next }
    on && /^## / { exit }
    on && /^[[:space:]]*(- \[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]+[^[:space:]]/ {
      sub(/^[[:space:]]*(- \[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print
    }'
}

planner_draft_readiness_epic_summary() {
  local init="$1" root specs_dir slug dir out="" any=0
  root=$(planner_draft_readiness_root "$init") || return 0
  specs_dir=$(planner_ticketgen_specs_dir "$init") || return 0
  [ -d "$root" ] || return 0
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    dir="${root}/${slug}"
    [ -d "$dir" ] || continue
    local rounds statuses="" lines="" st f item old new
    rounds=0
    for f in "$dir"/revise.r*.status; do
      [ -f "$f" ] || continue
      rounds=$((rounds + 1))
      st=$(head -1 "$f")
      statuses="${statuses:+${statuses}, }${st}"
    done
    if [ "$rounds" -gt 0 ] && [ -f "${dir}/spec.r0.md" ]; then
      old=$(_planner_draft_ac_items "${dir}/spec.r0.md")
      new=$(_planner_draft_ac_items "${specs_dir}/${slug}.md")
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        grep -qxF -- "$item" <<<"$old" && continue
        local base="" o
        while IFS= read -r o; do
          [ -n "$o" ] && [ "${item#"$o"}" != "$item" ] && base="$o" && break
        done <<<"$old"
        if [ -n "$base" ]; then
          lines+="- Extended criterion: ${item}"$'\n'
        else
          lines+="- Added criterion: ${item}"$'\n'
        fi
      done <<<"$new"
    fi
    if [ "$rounds" -gt 0 ] && [ -f "${dir}/spec.r0.md" ]; then
      # Every assumption the revisions added (no source stated it): listed
      # so a human reviews it. Read from the spec, not the agent's file.
      local a
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        grep -qxF -- "$a" <<<"$(planner_draft_revise_assumptions "${dir}/spec.r0.md")" && continue
        lines+="- Assumption (review): ${a}"$'\n'
      done < <(planner_draft_revise_assumptions "${specs_dir}/${slug}.md")
    fi
    if [ -s "${dir}/semantic.json" ]; then
      lines+=$(jq -r "$(planner_draft_security_def)"' (.findings // [])[] | select(.demoted != null)
        | "- \(if (.verified == true and pdr_security) then "Security finding (review): " else "" end)Demoted \(.code): \(.demoted)\(if .demote_reason then ", \(.demote_reason)" else "" end)"' \
        "${dir}/semantic.json" 2>/dev/null)
      [ -n "$lines" ] && [ "${lines: -1}" != $'\n' ] && lines+=$'\n'
    fi
    [ "$rounds" -gt 0 ] || [ -n "$lines" ] || continue
    any=1
    out+=$'\n'"### $(planner_ticketgen_spec_title "${specs_dir}/${slug}.md" 2>/dev/null || echo "$slug")"$'\n\n'
    out+="- Spec: \`${slug}\`"$'\n'
    out+="- Revision rounds: ${rounds}${statuses:+ (${statuses})}"$'\n'
    out+="$lines"
  done < <(planner_ticketgen_slugs "$specs_dir")
  [ "$any" = 1 ] || return 0
  printf '## Revised by draft readiness\n\nBefore any ticket was created, the draft readiness gate revised these specs or demoted findings to advisory. Demoted findings do not block; they reach each ticket'"'"'s Refinement Carry-over. An assumption is a default the gate chose because no source stated the decision; review each one.\n%s' "$out"
}
