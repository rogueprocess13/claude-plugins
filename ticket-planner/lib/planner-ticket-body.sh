#!/usr/bin/env bash
# planner-ticket-body.sh — Deterministic TicketGen inputs and body composer.
#
# Issue #499: the TicketGen prompt used to hand the agent example/placeholder
# values (`deps_json`, `ticket_ids`, `description`) and leave it to improvise
# everything that turns a spec file into a ticket body — the dependency set
# from each spec's `## Labels` tokens, the body itself (Description up to
# `## Labels`, minus Labels/Signals/Verification Notes), `## Related Tickets`,
# the `## Verification Plan` rows, the Planner Context block. Every one of
# those is a place where two runs over the same specs could produce different
# bodies. This file moves all of it to bash so the same spec set always
# produces byte-identical bodies.
#
# What lives here (all pure over the spec files + the initiative's state log
# and intent files — no Linear calls, no clock):
#
#   planner_ticketgen_specs_dir <initiative_id>
#   planner_ticketgen_slugs <specs_dir>              sorted spec slugs (INDEX excluded)
#   planner_ticketgen_spec_deps <spec_file> <specs_dir>
#                                                    blocked-by refs, sibling refs resolved
#                                                    to full slugs (exact, then unambiguous
#                                                    `-`-bounded prefix — the same rule
#                                                    planner_crosscheck_deps enforces),
#                                                    then the test-data synthesis edges
#                                                    from ../testdata-synth.json
#   planner_ticketgen_deps_json <specs_dir>          {slug: [refs]} for every spec
#   planner_ticketgen_ids_json <specs_dir>           ["slug", ...]
#   planner_ticketgen_order <specs_dir>              creation order: Kahn's algorithm over
#                                                    sibling edges, ties broken by slug
#   planner_ticketgen_spec_title <spec_file>
#   planner_ticketgen_spec_type <spec_file>          feature|bug|improvement|chore|security
#   planner_ticketgen_signals <spec_file>            Signals JSON (compact), {} when absent
#   planner_ticketgen_generated_ts <initiative_id>   the Planner Context `Generated` value
#   planner_ticketgen_context_block <initiative_id> <epic_id> <spec_file> [<generated_ts>]
#   planner_ticketgen_vplan <spec_file>              the `## Verification Plan` section
#   planner_ticketgen_testdata_prereqs <spec_file>   the `## Test Data Prerequisites` section
#                                                    (from the notes table, with Source — #503)
#   planner_ticketgen_dep_refs <initiative_id> <spec_file>
#                                                    "<linear-id>\t<title>" per dependency
#   planner_ticket_body_compose <spec_file> <planner_context_block> [<id>\t<title> ...]
#   planner_ticketgen_body <initiative_id> <epic_id> <slug>
#
# Verification Plan mapping (#499). Specify's `## Verification Notes` is
# matched to Acceptance Criteria by criterion TEXT, never by position: the
# numbering of a hand-amended notes list does not follow AC order (an
# amendment that inserts ACs 14-17 appends its notes as 28-31). The current
# Specify contract writes the notes as a table whose `Criterion` column
# repeats each AC line verbatim; rows are emitted in AC order whatever order
# the notes table is in. A note whose criterion matches no AC, and an AC no
# note covers, are reported on stderr and the AC still gets a row (cells say
# "not recorded in spec", Verifiable blank) — the table is always complete.
# Legacy numbered notes (`N. Role: … Test data: …`, no criterion text) are
# reported and left unmapped rather than guessed: a list numbered 1..N for N
# criteria can still be out of AC order, and nothing in it says so.
#
# `Generated` is the timestamp of the EpicGen line that recorded the epic id,
# not the wall clock — the body must not change between two runs.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_TICKET_BODY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_deps_is_external_ref >/dev/null 2>&1; then
  # shellcheck source=planner-deps-check.sh
  source "${_PLANNER_TICKET_BODY_LIB_DIR}/planner-deps-check.sh"
fi
if ! declare -f planner_context_generate >/dev/null 2>&1; then
  # shellcheck source=planner-context-gen.sh
  source "${_PLANNER_TICKET_BODY_LIB_DIR}/planner-context-gen.sh"
fi
if ! declare -f planner_entity_get_id >/dev/null 2>&1; then
  # shellcheck source=planner-ticket-validate.sh
  source "${_PLANNER_TICKET_BODY_LIB_DIR}/planner-ticket-validate.sh"
fi
if ! declare -f _planner_testdata_cell_need >/dev/null 2>&1; then
  # shellcheck source=planner-crosscheck-testdata.sh
  source "${_PLANNER_TICKET_BODY_LIB_DIR}/planner-crosscheck-testdata.sh"
fi
if ! declare -f _planner_tds_edges_of >/dev/null 2>&1; then
  # shellcheck source=planner-testdata-synth.sh
  source "${_PLANNER_TICKET_BODY_LIB_DIR}/planner-testdata-synth.sh"
fi
if ! declare -f planner_state_log >/dev/null 2>&1; then
  # shellcheck source=planner-state.sh
  source "${_PLANNER_TICKET_BODY_LIB_DIR}/planner-state.sh"
fi

# Ticket types the body contract (ticket-auto-pipeline templates/{type}.md)
# knows about.
PLANNER_TICKET_TYPES="feature bug improvement chore security"

# Sections the composer owns or drops. Labels/Signals/Verification Notes are
# planning metadata; Title is the issue title; Verification Plan, Related
# Tickets and Planner Context are regenerated from the spec, so a hand-written
# copy in the spec never reaches the ticket twice.
_PLANNER_TB_DROP="|title|description|labels|signals|verification notes|verification plan|related tickets|planner context|"

# ── Spec reading helpers ─────────────────────────────────────────────────────

# The spec's text with CR stripped — a CRLF spec otherwise yields an empty
# title and a misleading "no ticket type" error. Every reader below goes
# through this, never the file directly.
_planner_tb_read() {
  tr -d '\r' <"$1" 2>/dev/null
}

# Content of one `## <heading>` section (heading matched case-insensitively),
# up to the next `## ` heading. Headings inside fenced code blocks are not
# section boundaries.
# Usage: _planner_tb_section <spec_file> <heading-lowercase>
_planner_tb_section() {
  local spec_file="$1" want="$2"
  awk -v want="$want" '
    /^(```|~~~)/ { fence = !fence }
    !fence && /^## / {
      h = tolower($0); sub(/^## +/, "", h); sub(/[[:space:]]+$/, "", h)
      on = (h == want); next
    }
    on { print }
  ' < <(_planner_tb_read "$spec_file")
}

# Acceptance Criteria items, original text, one per line, markers stripped.
# Same bullet shapes dor-check.sh's _dor_ac_lines accepts.
_planner_tb_ac_items() {
  local spec_file="$1"
  _planner_tb_section "$spec_file" "acceptance criteria" |
    { grep -E '^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]+[^[:space:]]' || true; } |
    sed -E 's/^[[:space:]]*(-[[:space:]]*\[[ xX]\]|-|\*|[0-9]+[.)])[[:space:]]*//; s/[[:space:]]+$//' |
    awk '!seen[$0]++'
}

# `blocked-by:` tokens (backticks stripped) from the `## Labels` line —
# identical extraction to planner_crosscheck_deps.
_planner_tb_dep_tokens() {
  local spec_file="$1" labels_line
  labels_line=$(_planner_tb_read "$spec_file" | awk '/^## Labels/{f=1;next} f && NF{print; exit}')
  [ -z "$labels_line" ] && return 0
  echo "$labels_line" | { grep -oE 'blocked-by:`?[A-Za-z0-9_-]+`?' || true; } |
    sed -E 's/blocked-by:`?([A-Za-z0-9_-]+)`?/\1/'
}

# The test-data synthesis sidecar governing <specs_dir>
# (artifacts/specs → artifacts/testdata-synth.json).
_planner_tb_sidecar() {
  printf '%s' "$(dirname "$1")/testdata-synth.json"
}

# ── Initiative-level helpers ─────────────────────────────────────────────────

planner_ticketgen_specs_dir() {
  local initiative_id="$1"
  if [ -z "${REPOS_ROOT:-}" ]; then
    echo "planner-ticket-body: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  fi
  echo "${REPOS_ROOT}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"
}

planner_ticketgen_slugs() {
  local specs_dir="$1" f
  for f in "$specs_dir"/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "INDEX.md" ] && continue
    basename "$f" .md
  done | LC_ALL=C sort
}

# Resolved dependency refs for one spec, one per line, de-duplicated in
# Labels order. A sibling ref resolves to the full slug (exact match, else an
# unambiguous `-`-bounded prefix). An existing Linear identifier (#227) is
# kept verbatim. Anything else is kept verbatim too, so
# planner_deps_validate_targets reports it as dangling instead of it
# vanishing. Then the spec's test-data synthesis edges (sidecar
# `edges[].blocked_by` for this consumer, sorted; planner-test-data-derivation
# 4.8) not already listed — the consumer spec never names its TD spec, so the
# sidecar is the only place that edge lives. Every reader of the dependency
# set (deps_json, order, dep_refs, Crosscheck's cycle check) goes through
# here.
planner_ticketgen_spec_deps() {
  local spec_file="$1" specs_dir="$2"
  local -a slugs matches
  mapfile -t slugs < <(planner_ticketgen_slugs "$specs_dir")
  local tok s resolved
  local -A seen=()
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    resolved=""
    for s in "${slugs[@]}"; do
      [ "$s" = "$tok" ] && resolved="$s" && break
    done
    if [ -z "$resolved" ] && ! planner_deps_is_external_ref "$tok"; then
      matches=()
      for s in "${slugs[@]}"; do
        case "$s" in "${tok}-"*) matches+=("$s") ;; esac
      done
      [ "${#matches[@]}" -eq 1 ] && resolved="${matches[0]}"
    fi
    [ -z "$resolved" ] && resolved="$tok"
    [ -n "${seen[$resolved]:-}" ] && continue
    seen[$resolved]=1
    echo "$resolved"
  done < <(_planner_tb_dep_tokens "$spec_file")
  local slug c b
  slug=$(basename "$spec_file" .md)
  while IFS=$'\037' read -r c b; do
    [ "$c" = "$slug" ] && [ -n "$b" ] || continue
    [ -n "${seen[$b]:-}" ] && continue
    seen[$b]=1
    echo "$b"
  done < <(_planner_tds_edges_of "$(_planner_tb_sidecar "$specs_dir")" "$specs_dir")
}

planner_ticketgen_deps_json() {
  local specs_dir="$1" slug
  {
    while IFS= read -r slug; do
      [ -z "$slug" ] && continue
      planner_ticketgen_spec_deps "${specs_dir}/${slug}.md" "$specs_dir" |
        jq -R . | jq -sc --arg slug "$slug" '{($slug): .}'
    done < <(planner_ticketgen_slugs "$specs_dir")
  } | jq -sc 'add // {}'
}

planner_ticketgen_ids_json() {
  planner_ticketgen_slugs "$1" | jq -R . | jq -sc .
}

# Creation order: dependencies first. Only sibling edges order the set (an
# external prerequisite already exists). Among ready tickets the smallest slug
# goes first, so the order is a pure function of the spec set — tsort's tie
# order is implementation-defined and drops isolated nodes.
# Returns 1 (nothing printed) on a cycle.
planner_ticketgen_order() {
  local specs_dir="$1" deps_json
  deps_json=$(planner_ticketgen_deps_json "$specs_dir") || return 1
  jq -r '
    . as $g
    | ($g | keys) as $ids
    | ($g | map_values(map(select(. as $d | $ids | index($d))))) as $sib
    | {order: [], left: $ids}
    | until((.left | length) == 0 or .stuck;
        . as $s
        | [ $s.left[] | select(($sib[.] // []) | all(. as $d | $s.order | index($d))) ] as $ready
        | if ($ready | length) == 0 then .stuck = true
          else .order += [$ready[0]] | .left -= [$ready[0]] end)
    | if .stuck then error("cycle") else .order[] end
  ' <<<"$deps_json" 2>/dev/null || {
    echo "planner-ticket-body: dependency graph is cyclic — no creation order" >&2
    return 1
  }
}

# ── Per-spec facts ───────────────────────────────────────────────────────────

# `## Title` section's first non-empty line; else the first `# ` heading when
# it is not just the slug; else the slug.
planner_ticketgen_spec_title() {
  local spec_file="$1" slug title
  slug=$(basename "$spec_file" .md)
  title=$(_planner_tb_section "$spec_file" "title" | awk 'NF{print; exit}')
  if [ -z "$title" ]; then
    title=$(_planner_tb_read "$spec_file" | awk '/^# /{sub(/^# +/, ""); print; exit}')
    [ "$title" = "$slug" ] && title=""
  fi
  [ -z "$title" ] && title="$slug"
  printf '%s\n' "$title" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# The ticket type from the `## Labels` line: the first token that is (or is
# `type:` +) one of PLANNER_TICKET_TYPES. Returns 1 when none is present.
planner_ticketgen_spec_type() {
  local spec_file="$1" labels_line tok t
  labels_line=$(_planner_tb_read "$spec_file" | awk '/^## Labels/{f=1;next} f && NF{print; exit}')
  for tok in $(echo "$labels_line" | tr ',`' '  '); do
    t=$(echo "${tok#type:}" | tr '[:upper:]' '[:lower:]')
    case " ${PLANNER_TICKET_TYPES} " in
    *" ${t} "*)
      echo "$t"
      return 0
      ;;
    esac
  done
  echo "planner-ticket-body: no ticket type (${PLANNER_TICKET_TYPES}) on the Labels line of $(basename "$spec_file")" >&2
  return 1
}

# The Signals JSON: the first fenced block inside the `## Signals` section only
# — a JSON example elsewhere in the spec (Technical Context) must never be
# read as the signals. Returns 1 when the section, its block, or valid JSON
# object is missing: a silent `{}` would derive a confident-looking score
# from nothing.
planner_ticketgen_signals() {
  local spec_file="$1" sig
  sig=$(_planner_tb_section "$spec_file" "signals" |
    awk '/^(```|~~~)/ { if (on) exit; on = 1; next } on { print }' |
    jq -ce 'select(type == "object")' 2>/dev/null) || sig=""
  if [ -z "$sig" ]; then
    echo "planner-ticket-body: $(basename "$spec_file"): ## Signals has no parseable JSON object" >&2
    return 1
  fi
  echo "$sig"
}

# The Linear priority (integer) TicketGen passes for one spec
# (planner-test-data-derivation, task 5.2). Only a synth-marked test-data (TD)
# spec gets one: every consumer it blocks waits on it, so it is filed High. Its
# Signals `Priority` names the level (Urgent 1, High 2, Medium/Normal 3,
# Low 4); a missing or unknown value on a TD spec falls back to High. Any
# other spec prints nothing — the team default applies, exactly as before.
# Usage: planner_ticketgen_priority <spec_file>
planner_ticketgen_priority() {
  local spec_file="$1" level
  [ -f "$spec_file" ] && [ -n "${PLANNER_TESTDATA_SYNTH_MARKER:-}" ] || return 0
  grep -qF -- "$PLANNER_TESTDATA_SYNTH_MARKER" "$spec_file" 2>/dev/null || return 0
  level=$(planner_ticketgen_signals "$spec_file" 2>/dev/null | jq -r '.Priority // "" | ascii_downcase' 2>/dev/null) || level=""
  case "$level" in
  urgent) echo 1 ;;
  medium | normal) echo 3 ;;
  low) echo 4 ;;
  *) echo 2 ;;
  esac
}

# Timestamp of the EpicGen line that recorded EPIC_ID (first one — the epic
# is created once). Falls back to the state log's first line. Never the clock.
planner_ticketgen_generated_ts() {
  local initiative_id="$1" log_file ts=""
  log_file=$(planner_state_log "$initiative_id" 2>/dev/null) || log_file=""
  if [ -n "$log_file" ] && [ -f "$log_file" ]; then
    ts=$(grep -m1 -E '^[^|]*\|EpicGen\|[^|]*\|done\|EPIC_ID=[^|]*$' "$log_file" 2>/dev/null | cut -d'|' -f1)
    [ -n "$ts" ] || ts=$(head -1 "$log_file" | cut -d'|' -f1)
  fi
  [ -n "$ts" ] || ts="1970-01-01T00:00:00Z"
  echo "$ts"
}

# The `## Planner Context` block for one spec — confidence and Pre-approved
# computed here from the Signals JSON, never by the agent. The optional 4th
# argument overrides the `Generated` timestamp (planner-draft-readiness D2:
# drafts pass the latest `Crosscheck|check|done` timestamp). Empty or absent
# keeps planner_ticketgen_generated_ts, so TicketGen's output is unchanged.
planner_ticketgen_context_block() {
  local initiative_id="$1" epic_id="$2" spec_file="$3" generated_ts="${4:-}"
  local signals confidence threshold pre_approved generated context_json
  signals=$(planner_ticketgen_signals "$spec_file") || return 1
  confidence=$(planner_confidence_derive "$signals")
  threshold="${PLANNER_CONFIDENCE_THRESHOLD:-0.85}"
  pre_approved=$(awk -v c="$confidence" -v t="$threshold" 'BEGIN { print ((c + 0 >= t + 0) ? "true" : "false") }')
  if [ -n "$generated_ts" ]; then
    generated="$generated_ts"
  else
    generated=$(planner_ticketgen_generated_ts "$initiative_id")
  fi
  context_json=$(jq -nc \
    --argjson signals "$signals" \
    --arg confidence "$confidence" \
    --arg pre_approved "$pre_approved" \
    --arg initiative "$initiative_id" \
    --arg epic "$epic_id" \
    --arg generated "$generated" \
    '{
      "Schema-Version": 1,
      "Initiative": $initiative,
      "Epic": $epic,
      "Confidence": ($confidence | tonumber),
      "Strategy": ($signals.Strategy // "Balanced"),
      "Decision": ($signals.Decision // ""),
      "Affected Services": ($signals.AffectedServices // ""),
      "Target Symbols": ($signals.TargetSymbols // ""),
      "Pre-approved": ($pre_approved == "true"),
      "Generated": $generated,
      "Regenerate": false,
      "Kind": ($signals.Kind // ""),
      "Serves": (($signals.Serves // []) | if type == "array" then join(",") else tostring end),
      "Enables": (($signals.Enables // []) | if type == "array" then join(",") else tostring end)
    }') || return 1
  planner_context_generate "$context_json"
}

# ── Verification Plan ────────────────────────────────────────────────────────

# Verification Notes table rows → JSON [{criterion, role, nav, expected,
# verifiable, cell, data, src, none}]. The table is read by Crosscheck's own
# parser (_planner_testdata_notes_table) and each row's need by Crosscheck's
# own cell parser (_planner_testdata_cell_need): the Source this composer
# renders is, by construction, the Source Crosscheck checked. `cell` is
# whether the Test data cell is non-empty; `src` is the canonical
# `kind[:value]`. [] when there is no table with a Criterion column.
_planner_tb_notes_table() {
  local section="$1" rows header ci ri di si ni ei vi row need d kind value
  rows=$(_planner_testdata_notes_table <<<"$section")
  [ -n "$rows" ] || {
    echo "[]"
    return 0
  }
  header=$(head -1 <<<"$rows")
  ci=$(_planner_testdata_col "$header" "criterion")
  [ -n "$ci" ] || {
    echo "[]"
    return 0
  }
  ri=$(_planner_testdata_col "$header" "role")
  di=$(_planner_testdata_col "$header" "test data")
  si=$(_planner_testdata_col "$header" "source")
  ni=$(_planner_testdata_col "$header" "navigation")
  ei=$(_planner_testdata_col "$header" "expected")
  vi=$(_planner_testdata_col "$header" "verifiable")
  while IFS= read -r row; do
    local -a c=()
    IFS=$'\037' read -r -a c <<<"$row"
    d="${di:+${c[di - 1]:-}}"
    need=$(_planner_testdata_cell_need "$d" "${si:+${c[si - 1]:-}}")
    IFS=$'\037' read -r d kind value <<<"$need"
    jq -nc \
      --arg criterion "${c[ci - 1]:-}" \
      --arg role "${ri:+${c[ri - 1]:-}}" \
      --arg nav "${ni:+${c[ni - 1]:-}}" \
      --arg expected "${ei:+${c[ei - 1]:-}}" \
      --arg verifiable "${vi:+${c[vi - 1]:-}}" \
      --arg cell "${di:+${c[di - 1]:-}}" \
      --arg data "$d" \
      --arg src "${kind}${value:+:${value}}" \
      --arg none "$(_planner_testdata_is_none "$d" && echo true || echo false)" \
      '{criterion: $criterion, role: $role, nav: $nav, expected: $expected,
        verifiable: $verifiable, cell: (($cell | gsub("\\s"; "") | length) > 0),
        data: $data, src: $src, none: ($none == "true")}'
  done < <(tail -n +2 <<<"$rows") | jq -sc .
}

# Apply the test-data synthesis Source overrides (sidecar `overrides`,
# planner-test-data-derivation 4.8) to notes-table rows: a `generate` row of
# this consumer whose criterion + data match an override reads Source
# `seeded-by:<td-slug>` — the TD spec Crosscheck synthesized owns it. Matched
# on consumer + criterion + data exactly, as the Crosscheck row walker does.
# The spec file itself is never changed.
# Usage: _planner_tb_apply_overrides <spec_file> <table_json>
_planner_tb_apply_overrides() {
  local spec_file="$1" table="$2" specs_dir ov
  specs_dir=$(dirname "$spec_file")
  ov=$(_planner_tds_overrides_of "$(_planner_tb_sidecar "$specs_dir")" "$specs_dir" |
    jq -Rsc --arg c "$(basename "$spec_file" .md)" '
      split("\n") | map(select(length > 0) | split("\u001f") | select(.[0] == $c)
        | {key: (.[1] + "\u001f" + .[2]), value: .[3]}) | from_entries')
  [ -n "$ov" ] && [ "$ov" != "{}" ] || {
    printf '%s\n' "$table"
    return 0
  }
  jq -c --argjson ov "$ov" '
    map(if .src == "generate" and ($ov[(.criterion + "\u001f" + .data)] // null) != null
        then .src = $ov[(.criterion + "\u001f" + .data)] else . end)' <<<"$table"
}

# Count of legacy numbered notes (`N. Role: … Test data: …`) — they carry no
# criterion text, so they are reported, never mapped by position.
_planner_tb_notes_legacy_count() {
  printf '%s\n' "$1" | { grep -cE '^[[:space:]]*[0-9]+[a-z]?[.)][[:space:]]+' || true; }
}

# Verification Notes → AC-ordered rows + mapping warnings, as JSON
# {rows: [...], warnings: [...], table: <rows in the notes table>}.
_planner_tb_vplan_json() {
  local spec_file="$1"
  local ac_json notes table_json legacy_count nav
  ac_json=$(_planner_tb_ac_items "$spec_file" | jq -R . | jq -sc .)
  notes=$(_planner_testdata_section "$spec_file" "Verification Notes")
  table_json=$(_planner_tb_notes_table "$notes")
  table_json=$(_planner_tb_apply_overrides "$spec_file" "${table_json:-[]}")
  legacy_count=$(_planner_tb_notes_legacy_count "$notes")
  nav=$(_planner_tb_section "$spec_file" "navigation path" | awk 'NF{print; exit}' |
    tr -d '`' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

  jq -nc \
    --argjson acs "$ac_json" \
    --argjson table "${table_json:-[]}" \
    --argjson legacy "${legacy_count:-0}" \
    --arg nav "$nav" \
    --arg spec "$(basename "$spec_file")" '
    def norm: ascii_downcase | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ") | rtrimstr(".");
    def present: . != null and (tostring | gsub("\\s"; "") | length) > 0;
    def nr: "not recorded in spec";
    (reduce $table[] as $r ({}; ($r.criterion // "" | norm) as $k
        | if $k == "" or has($k) then . else .[$k] = $r end)) as $byText
    | ($acs | map(norm)) as $acKeys
    | [ range(0; $acs | length) as $i
        | $byText[$acKeys[$i]] as $n
        | ( if ($n.expected | present) then $n.expected else nr end ) as $exp
        | (if $n != null and $n.cell then $n else null end) as $td
        | {
            i: ($i + 1),
            criterion: $acs[$i],
            role: (if ($n.role | present) then $n.role else nr end),
            nav: (if ($n.nav | present) then $n.nav elif ($nav | present) then $nav else "n/a" end),
            data: (if $td == null then nr else $td.data end),
            src: (if $td == null then "" else $td.src end),
            none: (if $td == null then false else $td.none end),
            recorded: ($td != null),
            expected: $exp,
            verifiable: (if ($n.expected | present)
                           and (($n.verifiable // "") | norm | IN("yes", "y", "✓", "true", "x"))
                         then "✓" else "" end),
            mapped: ($n != null)
          } ] as $rows
    | {
        rows: $rows,
        all: $table,
        table: ($table | length),
        warnings: (
          (if ($table | length) == 0 then
             (if $legacy > 0 or ($acs | length) == 0 then []
              else [ "\($spec): no Verification Notes table — every row marked not recorded" ] end)
           else [ $rows[] | select(.mapped | not) | "\($spec): AC \(.i) has no Verification Notes entry — row marked not recorded" ] end)
          + [ $table | group_by(.criterion // "" | norm)[] | select(length > 1)
              | "\($spec): \(length) Verification Notes rows share the criterion \(.[0].criterion // "") — the Verification Plan shows the first; Test Data Prerequisites lists every row" ]
          + [ $table[] | select((.criterion // "" | norm) as $k | $acKeys | index($k) | not)
              | "\($spec): Verification Notes criterion matches no Acceptance Criteria line: \(.criterion // "")" ]
          + (if ($table | length) == 0 and $legacy > 0
             then [ "\($spec): \($legacy) numbered Verification Notes carry no criterion text — not mapped by position (#499); rewrite them as the Criterion table" ]
             else [] end)
        )
      }
  '
}

# The full `## Verification Plan` section for a spec: one row per Acceptance
# Criteria line, in AC order. The Test data needed cell carries the need's
# Source as `<what> (Source: <source>)` (#503) whenever the data is not none.
# Mapping warnings go to stderr; always exit 0 when the spec is readable.
planner_ticketgen_vplan() {
  local spec_file="$1" result
  result=$(_planner_tb_vplan_json "$spec_file") || return 1

  jq -r '.warnings[] | "planner-ticket-body: WARNING " + .' <<<"$result" >&2

  echo "## Verification Plan"
  echo ""
  echo "### Per-Criterion Verification"
  echo ""
  echo "| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |"
  echo "|---|-----------|------------|-----------------|------------------|-------------------|------------|"
  jq -r '
    def esc: tostring | gsub("\\|"; "\\|");
    .rows[]
    | (if .recorded and (.none | not) and .src != "" then "\(.data) (Source: \(.src))" else .data end) as $cell
    | "| \(.i) | \(.criterion | esc) | \(.role | esc) | \(.nav | esc) | \($cell | esc) | \(.expected | esc) | \(.verifiable) |"
  ' <<<"$result"
}

# The `## Test Data Prerequisites` section generated from the Verification
# Notes table (#503): one `- <what>. Source: <source>` bullet per distinct need
# whose test data is not none, from EVERY table row in table order — exactly
# the needs Crosscheck checked, including a row whose criterion matches no AC
# or repeats another row's (`- <what>` when the row records no
# Source — the readiness check reads that as unsourced, which it is). When no
# criterion needs data, a single none bullet. Sidecar Source overrides apply
# (`Source: seeded-by:<td-slug>`).
# A spec with no Verification Notes table:
#   - keeps its own hand-written, non-blank `## Test Data Prerequisites`
#     (legacy specs) — prints nothing and returns 1;
#   - otherwise the section is still written (planned-ticket-body-check.sh
#     requires it on feature/improvement/bug bodies; design Decision 11):
#     one bullet per non-none need the legacy numbered/bullet notes record,
#     else the none bullet.
planner_ticketgen_testdata_prereqs() {
  local spec_file="$1" result
  result=$(_planner_tb_vplan_json "$spec_file" 2>/dev/null) || return 1
  if [ "$(jq -r '.table' <<<"$result")" -eq 0 ]; then
    _planner_tb_section "$spec_file" "test data prerequisites" | grep -q '[^[:space:]]' && return 1
    echo "## Test Data Prerequisites"
    echo ""
    local label data kind value bullets=""
    while IFS=$'\037' read -r label data kind value; do
      [ -n "$data" ] || continue
      _planner_testdata_is_none "$data" && continue
      bullets+="- ${data}${kind:+. Source: ${kind}${value:+:${value}}}"$'\n'
    done < <(_planner_testdata_spec_needs "$spec_file")
    if [ -n "$bullets" ]; then
      printf '%s' "$bullets" | awk '!seen[$0]++'
    else
      echo "- None — no acceptance criterion needs test data."
    fi
    return 0
  fi
  echo "## Test Data Prerequisites"
  echo ""
  jq -r '
    [ .all[] | select(.cell and (.none | not))
      | if .src != "" then "- \(.data). Source: \(.src)" else "- \(.data)" end ]
    | reduce .[] as $b ([]; if index([$b]) then . else . + [$b] end)
    | if length == 0 then "- None — no acceptance criterion needs test data." else .[] end
  ' <<<"$result"
}

# ── Related Tickets ──────────────────────────────────────────────────────────

# One "<linear-id>\t<title>" line per dependency, in Labels order. A sibling
# resolves to the ticket THIS initiative created for it (intent file); an
# external Linear identifier is used verbatim with an empty title. Returns 1
# (naming the ref) when a sibling has not been created yet or a ref resolves
# to nothing — the ticket must not be created with a dependency missing.
planner_ticketgen_dep_refs() {
  local initiative_id="$1" spec_file="$2"
  local specs_dir ref id
  specs_dir=$(dirname "$spec_file")
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ -f "${specs_dir}/${ref}.md" ]; then
      id=$(planner_entity_get_id "$initiative_id" "ticket-${ref}")
      if [ -z "$id" ]; then
        echo "planner-ticket-body: dependency ${ref} of $(basename "$spec_file" .md) has no created ticket yet" >&2
        return 1
      fi
      printf '%s\t%s\n' "$id" "$(planner_ticketgen_spec_title "${specs_dir}/${ref}.md")"
    elif planner_deps_is_external_ref "$ref"; then
      printf '%s\t\n' "$ref"
    else
      echo "planner-ticket-body: blocked-by:${ref} in $(basename "$spec_file" .md) resolves to no sibling spec" >&2
      return 1
    fi
  done < <(planner_ticketgen_spec_deps "$spec_file" "$specs_dir")
}

# ── Body composer ────────────────────────────────────────────────────────────

# Refuse a spec whose structure downstream parsers would read differently
# from this composer (#499 review):
#   - the substring `## Planner Context` anywhere — fenced, `### Planner
#     Context`, or mid-sentence. The composer appends the only legitimate
#     block, and downstream readers (planned-ticket-check.sh's section
#     extractor, gate-check.sh / planned-feedback-write.sh /
#     fleet-feedback.sh's unanchored `sed -n '/## Planner Context/,/^## /p'`)
#     are neither fence- nor anchor-aware, so any copy could be read as the
#     real one (forged Pre-approved / Confidence);
#   - anything but exactly one Acceptance Criteria heading spelled exactly
#     `## Acceptance Criteria`, outside a fence. dor-check.sh's _dor_ac_lines
#     matches `^##[[:space:]]*Acceptance Criteria` (any suffix) and takes the
#     first one, fenced or not, while this composer reads the exact,
#     unfenced, case-insensitive section — any variant lets the AC count and
#     the Verification Plan rows disagree. Counted case-insensitively, with
#     any suffix.
# Usage: _planner_tb_guard <spec_file>   Returns 1 (reason on stderr) on refusal.
_planner_tb_guard() {
  local spec_file="$1" verdict
  verdict=$(_planner_tb_read "$spec_file" | awk '
    /^(```|~~~)/ { fence = !fence }
    index($0, "## Planner Context") { pc++ }
    tolower($0) ~ /^##[[:space:]]*acceptance criteria/ {
      ac++
      if (fence) acf++
      line = $0; sub(/[[:space:]]+$/, "", line)
      if (line != "## Acceptance Criteria") acv++
    }
    END { printf "%d %d %d %d\n", pc, ac, acf, acv }')
  local pc ac acf acv name
  read -r pc ac acf acv <<<"$verdict"
  name=$(basename "$spec_file")
  if [ "${pc:-0}" -gt 0 ]; then
    echo "planner-ticket-body: ${name}: contains '## Planner Context' — the composer writes the only one; remove every occurrence from the spec" >&2
    return 1
  fi
  if [ "${ac:-0}" -ne 1 ] || [ "${acf:-0}" -gt 0 ] || [ "${acv:-0}" -gt 0 ]; then
    echo "planner-ticket-body: ${name}: needs exactly one heading spelled '## Acceptance Criteria', outside any code fence (found ${ac:-0} AC-like heading(s), ${acf:-0} fenced, ${acv:-0} misspelled)" >&2
    return 1
  fi
  if [ -z "$(_planner_tb_ac_items "$spec_file")" ]; then
    echo "planner-ticket-body: ${name}: '## Acceptance Criteria' has no criteria items" >&2
    return 1
  fi
  # Verification Notes must read the same to Crosscheck and to this composer
  # (#499 x #503): the same refusal list Crosscheck blocks on.
  local problems
  problems=$(_planner_testdata_notes_problems "$spec_file")
  if [ -n "$problems" ]; then
    echo "planner-ticket-body: ${name}: Verification Notes: $(paste -sd';' <<<"$problems" | sed 's/;/; /g')" >&2
    return 1
  fi
  # Dependencies and type come from the first line starting `## Labels`
  # (same awk as planner_crosscheck_deps), fenced or not — a second or fenced
  # copy would let a code sample choose them.
  local lab
  lab=$(_planner_testdata_heading_lookalikes "$spec_file" "labels")
  if [ -n "$lab" ] && { [ "$(grep -c . <<<"$lab")" -gt 1 ] || [ "${lab%%$'\037'*}" = 1 ]; }; then
    echo "planner-ticket-body: ${name}: needs exactly one '## Labels' heading, outside any code fence" >&2
    return 1
  fi
  # vplan-parse.sh reads every `### Per-Criterion Verification` range in the
  # body, not only the one under the generated `## Verification Plan` — a copy
  # anywhere in the spec would be read as the real table (forged ✓ marks).
  if tr -d '\r' <"$spec_file" | _planner_testdata_fold_ws | grep -qi 'per-criterion verification'; then
    echo "planner-ticket-body: ${name}: contains 'Per-Criterion Verification' — the composer writes the only one; remove it from the spec" >&2
    return 1
  fi
  # Sections the composer generates: the exact unfenced heading is dropped and
  # regenerated; any other spelling (`##Verification Plan`, `### Related
  # Tickets`, NBSP, fenced) would survive into the body ahead of the generated
  # one, and downstream readers take the first. Test Data Prerequisites is
  # generated too, unless a table-less (legacy) spec keeps its own non-blank
  # section (planner_ticketgen_testdata_prereqs).
  local -a owned=("verification plan" "related tickets")
  if [ "$(_planner_tb_notes_table "$(_planner_testdata_section "$spec_file" "Verification Notes")")" != "[]" ] ||
    ! _planner_tb_section "$spec_file" "test data prerequisites" | grep -q '[^[:space:]]'; then
    owned+=("test data prerequisites")
  fi
  local h looks fenced raw
  for h in "${owned[@]}"; do
    looks=$(_planner_testdata_heading_lookalikes "$spec_file" "$h")
    [ -n "$looks" ] || continue
    if [ "$(grep -c . <<<"$looks")" -gt 1 ]; then
      echo "planner-ticket-body: ${name}: more than one '${h}' heading — the composer writes this section" >&2
      return 1
    fi
    IFS=$'\037' read -r fenced raw <<<"$looks"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [ "$fenced" = 1 ] || [ "$(tr '[:upper:]' '[:lower:]' <<<"$raw")" != "## ${h}" ]; then
      echo "planner-ticket-body: ${name}: '${raw}' looks like the generated '${h}' section — remove it, the composer writes it" >&2
      return 1
    fi
  done
  return 0
}

# Compose a ticket body from a spec. Pure: the same arguments always produce
# the same bytes.
#
#   1. The spec minus its `# ` heading and the sections in _PLANNER_TB_DROP
#      (the `## Description` heading goes; its content stays), blank-line runs
#      outside code fences squeezed, leading/trailing blank lines trimmed.
#      `## Test Data Prerequisites` comes from planner_ticketgen_testdata_prereqs
#      (`- <what>. Source: <source>`, #503; sidecar overrides applied); the
#      spec's own copy is dropped — except a legacy table-less spec's own
#      non-blank section, which is kept verbatim.
#   2. `## Verification Plan` from planner_ticketgen_vplan.
#   3. `## Related Tickets` — one "- Blocked by <id> — <title>" per dependency
#      argument, then the spec's own Related Tickets text unless it is a
#      placeholder ("None", "N/A", "-"); "None." when both are empty.
#   4. The Planner Context block, verbatim.
#
# Usage: planner_ticket_body_compose <spec_file> <planner_context_block> [<id>\t<title> ...]
planner_ticket_body_compose() {
  local spec_file="$1" context_block="$2"
  shift 2
  [ -f "$spec_file" ] || {
    echo "planner-ticket-body: spec not found: $spec_file" >&2
    return 1
  }

  _planner_tb_guard "$spec_file" || return 1

  local body vplan prereqs spec_related related="" entry id title drop
  drop="$_PLANNER_TB_DROP"
  # Test Data Prerequisites is generated from the Verification Notes table
  # (#503); a hand-written copy is dropped so the ticket carries one. A spec
  # with no table keeps its own non-blank section (legacy); without one the
  # section is still generated (none bullet), so every body carries it.
  if prereqs=$(planner_ticketgen_testdata_prereqs "$spec_file"); then
    drop="${drop}test data prerequisites|"
  else
    prereqs=""
  fi
  # The Verification Notes section is dropped by the shared reader's rule
  # (_planner_testdata_section: a `##`/`###` heading starting with it, up to
  # the next heading), so `### Verification Notes` never leaks into the body.
  body=$(awk -v drop="$drop" '
    {
      isfence = ($0 ~ /^(```|~~~)/)
      if (!fence && $0 ~ /^#+[[:space:]]/) {
        vn = tolower($0); sub(/^#+[[:space:]]+/, "", vn); gsub(/[*_]/, "", vn)
        vskip = ($0 ~ /^###?[[:space:]]/ && index(vn, "verification notes") == 1)
        if (vskip) next
      }
      if (vskip) next
      if (!fence && $0 ~ /^## /) {
        h = tolower($0); sub(/^## +/, "", h); sub(/[[:space:]]+$/, "", h)
        skip = (index(drop, "|" h "|") > 0)
        if (skip) next
      }
      if (!fence && $0 ~ /^# /) next
      if (isfence) fence = !fence
      if (skip) next
      if (!fence && !isfence && $0 ~ /^[[:space:]]*$/) { if (started) blank = 1; next }
      if (blank) { print ""; blank = 0 }
      print; started = 1
    }
  ' < <(_planner_tb_read "$spec_file"))
  vplan=$(planner_ticketgen_vplan "$spec_file") || return 1

  spec_related=$(_planner_tb_section "$spec_file" "related tickets" |
    sed -E '/^[[:space:]]*$/d')
  if printf '%s' "$spec_related" | tr -d '[:space:]' | grep -qiE '^(none|n/?a|-|—|tbd)?\.?$'; then
    spec_related=""
  fi

  for entry in "$@"; do
    [ -z "$entry" ] && continue
    id="${entry%%$'\t'*}"
    title=""
    [[ "$entry" == *$'\t'* ]] && title="${entry#*$'\t'}"
    if [ -n "$title" ]; then
      related+="- Blocked by ${id} — ${title}"$'\n'
    else
      related+="- Blocked by ${id}"$'\n'
    fi
  done
  [ -n "$spec_related" ] && related+="${spec_related}"$'\n'
  [ -n "$related" ] || related="None."$'\n'

  [ -n "$prereqs" ] && body="${body}"$'\n\n'"${prereqs}"
  printf '%s\n\n%s\n\n## Related Tickets\n\n%s\n%s\n' \
    "$body" "$vplan" "$related" "$context_block"
}

# The complete, deterministic description for one spec slug.
# Usage: planner_ticketgen_body <initiative_id> <epic_id> <slug>
planner_ticketgen_body() {
  local initiative_id="$1" epic_id="$2" slug="$3"
  local specs_dir spec_file context refs
  specs_dir=$(planner_ticketgen_specs_dir "$initiative_id") || return 1
  spec_file="${specs_dir}/${slug}.md"
  [ -f "$spec_file" ] || {
    echo "planner-ticket-body: spec not found: $spec_file" >&2
    return 1
  }
  context=$(planner_ticketgen_context_block "$initiative_id" "$epic_id" "$spec_file") || return 1
  refs=$(planner_ticketgen_dep_refs "$initiative_id" "$spec_file") || return 1
  local -a entries=()
  [ -n "$refs" ] && mapfile -t entries <<<"$refs"
  planner_ticket_body_compose "$spec_file" "$context" "${entries[@]}"
}
