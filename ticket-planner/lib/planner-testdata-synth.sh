#!/usr/bin/env bash
# planner-testdata-synth.sh — Crosscheck's test-data synthesis (planner-test-data-derivation).
#
# Specify writes `Source: generate` for test data nothing produces yet, and
# answers a TESTDATA_CONFIRM question with `generate: <what>` when a criterion
# implies data the Verification Notes never recorded. This file turns those
# unowned needs into test-data (TD) enabler specs, in bash, with no LLM:
#
#   planner_testdata_synth_needs <INIT>    one record per unowned need
#   planner_testdata_synth_assign <INIT>   each need placed in its TD spec, keyed td-<init>-<n>
#   planner_testdata_synth_groups <INIT>   one record per TD spec (pack | single)
#   planner_testdata_synth_render <td_slug> <INIT> <kind>
#                                          the TD spec text (stdin: assign records)
#   planner_testdata_synthesize <INIT>     entry point: full recompute, writes the
#                                          TD specs, artifacts/testdata-synth.json
#                                          and the INDEX.md block (Crosscheck's
#                                          first sub-step, planner-crosscheck.sh)
#   planner_testdata_synth_overrides <INIT> sidecar Source overrides (readers)
#   planner_testdata_synth_edges <INIT>    sidecar blocked-by edges (readers)
#
# Grouping (design Decision 5, hybrid): a need's key is the inventory entity
# its data names, else its normalized data text. A key two or more consumer
# specs use goes to one `<prefix>-test-data-pack`; a key one consumer uses
# goes to `<consumer>-test-data`. Rows sourced exists:/external:/seeded-by:,
# needs naming a cited artifact still waiting on its answer, and specs the
# synthesis wrote itself (PLANNER_TESTDATA_SYNTH_MARKER) are never consumers.
#
# Records are \x1f-separated, one per line, in a stable (LC_ALL=C) order: the
# same specs and answers always give the same records and the same bytes.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_TESTDATA_SYNTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_testdata_confirm_resolved >/dev/null 2>&1; then
  # shellcheck source=planner-crosscheck-testdata.sh
  [ -f "${_PLANNER_TESTDATA_SYNTH_LIB_DIR}/planner-crosscheck-testdata.sh" ] &&
    source "${_PLANNER_TESTDATA_SYNTH_LIB_DIR}/planner-crosscheck-testdata.sh"
fi

# A TD slug longer than this is truncated (stem cut, 6-hex hash, suffix kept).
PLANNER_TESTDATA_SYNTH_SLUG_MAX=60

# The `Load via` / `Seed channel:` vocabulary, in the order a mixed channel
# list is written.
PLANNER_TESTDATA_SYNTH_CHANNELS="sql api factories files ui-forms"

# Seed channel when no need's inventory row names a Load via: application
# factories go through the model code, so foreign keys and defaults hold
# without knowing the schema.
PLANNER_TESTDATA_SYNTH_DEFAULT_CHANNEL="factories"

# ── Small helpers ───────────────────────────────────────────────────────────

_planner_tds_specs_dir() {
  printf '%s' "$(_planner_testdata_state_dir "$1")/artifacts/specs"
}

# The initiative id as it appears in record keys and prefixes: lowercased,
# `INIT-` dropped, anything outside [a-z0-9-] removed. INIT-42 → 42.
_planner_tds_init_token() {
  local t
  t=$(printf '%s' "${1#INIT-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
  printf '%s' "${t:-0}"
}

# Consumer spec files: every spec except INDEX and synth-marked ones, sorted.
_planner_tds_consumer_specs() {
  local specs_dir f base
  specs_dir=$(_planner_tds_specs_dir "$1")
  [ -d "$specs_dir" ] || return 0
  for f in "$specs_dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    [ "$base" = "INDEX" ] && continue
    _planner_testdata_spec_is_synth "$f" && continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

# Grouping key for free text (no entity named): lowercased, punctuation
# (anything but [a-z0-9] and whitespace) replaced by a space, whitespace
# collapsed, trimmed, then ONE trailing `s` dropped ("5 paid invoices." and
# "5 paid invoice" share a key).
# Usage: planner_testdata_synth_norm_key <text>
planner_testdata_synth_norm_key() {
  local k
  k=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9[:space:]]+/ /g; s/[[:space:]]+/ /g')
  k=$(_planner_testdata_trim "$k")
  k="${k%s}"
  printf '%s' "$(_planner_testdata_trim "$k")"
}

# Does normalized <span> name inventory entity <e> (singular, +s, +es,
# y→ies on the last word)?
_planner_tds_entity_eq() {
  local span="$1" e="$2"
  [ "$span" = "$e" ] || [ "$span" = "${e}s" ] || [ "$span" = "${e}es" ] ||
    { [[ "$e" == *y ]] && [ "$span" = "${e%y}ies" ]; }
}

# The entity a need's data text names, as "<entity>\x1f<load via>", or
# nothing. Precedence: a backticked span that is an inventory entity; an
# inventory entity named in the words (longest at the earliest position); a
# backticked span shaped like an entity (`^[a-z][a-z0-9 -]{0,40}$`, the
# tripwire's rule) that the inventory does not list (load via empty).
# Usage: planner_testdata_synth_entity <data> <inventory-records>
#   inventory-records: planner_testdata_inventory_entities output.
planner_testdata_synth_entity() {
  local data="$1" inv="$2" rest span n e lv
  local -a ents=() lvs=()
  while IFS=$'\037' read -r e lv; do
    [ -n "$e" ] || continue
    ents+=("$e")
    lvs+=("$lv")
  done <<<"$inv"
  local -a spans=()
  rest="$data"
  while [[ "$rest" =~ \`([^\`]+)\` ]]; do
    spans+=("${BASH_REMATCH[1]}")
    rest="${rest#*\`"${BASH_REMATCH[1]}"\`}"
  done
  local i
  for span in "${spans[@]}"; do
    n=$(_planner_testdata_entity_norm "$span")
    for i in "${!ents[@]}"; do
      if _planner_tds_entity_eq "$n" "${ents[i]}"; then
        printf '%s\037%s\n' "${ents[i]}" "${lvs[i]}"
        return 0
      fi
    done
  done
  if [ "${#ents[@]}" -gt 0 ]; then
    local -a w=()
    read -r -a w <<<"$(_planner_testdata_entity_norm "$data")"
    local j len best=0 besti=""
    for ((j = 0; j < ${#w[@]}; j++)); do
      for i in "${!ents[@]}"; do
        len=$(_planner_testdata_entity_len_at "${ents[i]}" "$j" "${w[@]}")
        if [ "$len" -gt "$best" ]; then
          best=$len
          besti=$i
        fi
      done
      if [ -n "$besti" ]; then
        printf '%s\037%s\n' "${ents[besti]}" "${lvs[besti]}"
        return 0
      fi
    done
  fi
  for span in "${spans[@]}"; do
    if [[ "$span" =~ ^[a-z][a-z0-9\ -]{0,40}$ ]]; then
      printf '%s\037\n' "$(_planner_testdata_entity_norm "$span")"
      return 0
    fi
  done
  return 0
}

# Every test-data need in one spec WITH its criterion, one record per line:
#   <label>\x1f<criterion>\x1f<data>\x1f<kind>\x1f<value>
# label/data/kind/value are exactly _planner_testdata_spec_needs' (same
# parsers). criterion is the table row's Criterion cell; for a numbered or
# bullet line it is the line's text before its first `Test data:` marker
# (list marker, trailing separators stripped).
# Usage: _planner_testdata_rows <spec_file>
_planner_testdata_rows() {
  local spec_file="$1" line label bullets=0 rest seg parsed section crit
  section=$(_planner_testdata_section "$spec_file" "Verification Notes")
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[.\)][[:space:]] ]]; then
      label="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*[-*+][[:space:]] ]]; then
      bullets=$((bullets + 1))
      label="b${bullets}"
    else
      continue
    fi
    line=$(_planner_testdata_norm_line "$line")
    [[ "$line" == *"Test data:"* ]] || continue
    crit=$(sed -E 's/^[[:space:]]*([0-9]+[.)]|[-*+])[[:space:]]+//' <<<"${line%%Test data:*}")
    crit=$(_planner_testdata_trim "$crit")
    while [[ "$crit" =~ [.,\;:—–-]$ ]]; do crit=$(_planner_testdata_trim "${crit%?}"); done
    rest="$line"
    while [[ "$rest" == *"Test data:"* ]]; do
      rest="${rest#*Test data:}"
      seg="${rest%%Test data:*}"
      parsed=$(_planner_testdata_parse_segment "$seg")
      printf '%s\037%s\037%s\n' "$label" "$crit" "$parsed"
    done
  done <<<"$section"

  local rows header di si ci k=0 row
  rows=$(_planner_testdata_notes_table <<<"$section")
  [ -n "$rows" ] || return 0
  header=$(head -1 <<<"$rows")
  di=$(_planner_testdata_col "$header" "test data")
  si=$(_planner_testdata_col "$header" "source")
  ci=$(_planner_testdata_col "$header" "criterion")
  [ -n "$di" ] || return 0
  while IFS= read -r row; do
    k=$((k + 1))
    local -a cells=()
    IFS=$'\037' read -r -a cells <<<"$row"
    crit=""
    [ -n "$ci" ] && crit=$(_planner_testdata_trim "${cells[ci - 1]:-}")
    printf '%s\037%s\037%s\n' "$k" "$crit" \
      "$(_planner_testdata_cell_need "${cells[di - 1]:-}" "${si:+${cells[si - 1]:-}}")"
  done < <(tail -n +2 <<<"$rows")
}

# Cited artifacts discovery.md lists NOT FOUND whose consensus.md answer is
# still missing or malformed — the same "pending" set planner_crosscheck_testdata
# uses: a generate need naming one is CITED_ARTIFACT_UNRESOLVED's business.
_planner_tds_pending_cited() {
  local state_dir name qn qk qv qr
  state_dir=$(_planner_testdata_state_dir "$1")
  local -A answer_kind=()
  while IFS=$'\037' read -r qn qk qv qr; do answer_kind["$qn"]="$qk"; done \
    < <(_planner_cited_answers "${state_dir}/artifacts/consensus.md")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "${answer_kind[$(_planner_testdata_name_key "$name")]:-unresolved}" in
    unresolved) printf '%s\n' "$name" ;;
    esac
  done < <(planner_cited_artifacts_missing "$1")
}

# ── 4.2 Need collection ─────────────────────────────────────────────────────

# Every unowned need in the initiative, one record per line, sorted, unique:
#   <consumer_slug>\x1f<criterion>\x1f<data>\x1f<key>\x1f<entity>\x1f<load_via>
# Sources: Verification Notes rows with Source `generate` (not naming a
# pending cited artifact), and TESTDATA_CONFIRM `generate: <what>` answers
# that still apply (criterion = the spec's trigger criterion, data = <what>).
# Not collected: exists:/external:/seeded-by:/none rows, rows with no
# Source, and synth-marked specs. Field text has `\x1f` removed.
# Usage: planner_testdata_synth_needs <initiative_id>
planner_testdata_synth_needs() {
  [ -n "${REPOS_ROOT:-}" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local init="$1" inv ents spec_file slug label crit data kind value p skip
  inv=$(planner_testdata_inventory_entities "$init")
  ents=$(cut -d$'\037' -f1 <<<"$inv")
  local -a pending=()
  mapfile -t pending < <(_planner_tds_pending_cited "$init")
  local -A is_consumer=()
  {
    while IFS= read -r spec_file; do
      [ -n "$spec_file" ] || continue
      slug=$(basename "$spec_file" .md)
      is_consumer["$slug"]=1
      while IFS=$'\037' read -r label crit data kind value; do
        [ "$kind" = "generate" ] || continue
        skip=false
        for p in "${pending[@]}"; do
          [ -n "$p" ] && _planner_testdata_names_artifact "$data" "$p" && skip=true
        done
        [ "$skip" = true ] && continue
        _planner_tds_need_record "$slug" "$crit" "$data" "$inv"
      done < <(_planner_testdata_rows "$spec_file")
    done < <(_planner_tds_consumer_specs "$init")

    local r_slug r_hash r_kind r_value r_crit r_phrase
    while IFS=$'\037' read -r r_slug r_hash r_kind r_value r_crit r_phrase; do
      [ "$r_kind" = "generate" ] || continue
      [ -n "${is_consumer[$r_slug]+set}" ] || continue
      data="${r_value#generate:}"
      data=$(_planner_testdata_trim "$data")
      [ -n "$data" ] || continue
      _planner_tds_need_record "$r_slug" "$r_crit" "$data" "$inv"
    done < <(planner_testdata_confirm_resolved "$init" "$ents")
  } | LC_ALL=C sort -u
}

# One need record. Usage: _planner_tds_need_record <slug> <criterion> <data> <inventory>
_planner_tds_need_record() {
  local slug="$1" crit="${2//$'\037'/ }" data="${3//$'\037'/ }" inv="$4" ent key e lv
  ent=$(planner_testdata_synth_entity "$data" "$inv")
  IFS=$'\037' read -r e lv <<<"$ent"
  if [ -n "$e" ]; then
    key="$e"
  else
    key=$(planner_testdata_synth_norm_key "$data")
    lv=""
  fi
  [ -n "$key" ] || return 0
  printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$slug" "$crit" "$data" "$key" "$e" "$lv"
}

# ── 4.3 Grouping, slugs, collisions ─────────────────────────────────────────

# The pack prefix: the longest `-`-bounded slug prefix every consumer spec
# of the initiative shares (lowercased; `inv-0-list` + `inv-0-export` →
# `inv-0`), else `init-<id token>` (INIT-42 → `init-42`).
# Usage: planner_testdata_synth_prefix <initiative_id>
planner_testdata_synth_prefix() {
  local init="$1" f slug prefix="" first=true cand
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    slug=$(basename "$f" .md | tr '[:upper:]' '[:lower:]')
    if [ "$first" = true ]; then
      prefix="$slug"
      first=false
      continue
    fi
    while [ -n "$prefix" ] && [ "$slug" != "$prefix" ] && [[ "$slug" != "${prefix}-"* ]]; do
      cand="${prefix%-*}"
      [ "$cand" = "$prefix" ] && cand=""
      prefix="$cand"
    done
  done < <(_planner_tds_consumer_specs "$init")
  prefix=$(printf '%s' "$prefix" | tr -cd 'a-z0-9_-')
  prefix="${prefix%-}"
  [ -n "$prefix" ] || prefix="init-$(_planner_tds_init_token "$init")"
  printf '%s' "$prefix"
}

# A TD slug from <stem> + <suffix>, lowercased (seed-apply's make-target
# grammar is lowercase). Longer than PLANNER_TESTDATA_SYNTH_SLUG_MAX: the stem
# is cut so stem + `-` + 6 hex + suffix fits, the hex being the first 6 of
# sha256(full untruncated slug) — deterministic, and two long stems sharing
# their first characters still get distinct slugs.
# Usage: planner_testdata_synth_slug <stem> <suffix>
planner_testdata_synth_slug() {
  local stem suffix="$2" full h keep
  stem=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  full="${stem}${suffix}"
  if [ "${#full}" -le "$PLANNER_TESTDATA_SYNTH_SLUG_MAX" ]; then
    printf '%s' "$full"
    return 0
  fi
  h=$(printf '%s' "$full" | sha256sum | cut -c1-6)
  keep=$((PLANNER_TESTDATA_SYNTH_SLUG_MAX - ${#suffix} - 7))
  [ "$keep" -gt 0 ] || keep=1
  stem="${stem:0:keep}"
  while [[ "$stem" == *- ]]; do stem="${stem%-}"; done
  printf '%s-%s%s' "$stem" "$h" "$suffix"
}

# Is <specs_dir>/<slug>.md free for synthesis (absent, or synth-marked)?
# Returns 1 with the reason on stderr when an unmarked file holds the slug.
# Usage: planner_testdata_synth_collision <specs_dir> <slug>
planner_testdata_synth_collision() {
  local f="$1/$2.md"
  [ -e "$f" ] || return 0
  _planner_testdata_spec_is_synth "$f" && return 0
  echo "planner-testdata-synth: TD_SLUG_COLLISION ${2}.md already exists without the synthesis marker (${f}) — rename or remove that spec, or add the needs it covers as Source seeded-by:${2}" >&2
  return 1
}

# ── 4.5 Dispatched TD specs, stable record numbers ──────────────────────────

# The sidecar synthesis writes (task 4.6). Usage: _planner_tds_sidecar <INIT>
_planner_tds_sidecar() {
  printf '%s' "$(_planner_testdata_state_dir "$1")/artifacts/testdata-synth.json"
}

# Comment line a rendered TD spec carries right under the marker: the
# grouping keys it owns, `; `-joined. Recompute reads it back from a
# dispatched TD spec's frozen file to re-attach needs to it.
PLANNER_TESTDATA_SYNTH_KEYS_PREFIX='<!-- planner:testdata-synth keys: '

# Does the TD spec <slug> already have a ticket? The signal is TicketGen's
# own idempotency record, `.intents/ticket-<slug>.json` under the initiative
# (planner_record_intent, written BEFORE the tracker create call). Any status
# counts: `created` is a real ticket, and `intent` may be one (a crash between
# the create call and planner_entity_mark_created) — keeping the spec is the
# safe side either way. ticket-auto's per-ticket manifests are keyed by the
# tracker id, not the spec slug, so they cannot answer this without the
# intent file anyway.
# Usage: planner_testdata_synth_has_ticket <initiative_id> <slug>
planner_testdata_synth_has_ticket() {
  [ -f "$(_planner_testdata_state_dir "$1")/.intents/ticket-${2}.json" ]
}

# Synth-marked spec slugs on disk, sorted. Usage: _planner_tds_marked_slugs <INIT>
_planner_tds_marked_slugs() {
  local specs_dir f
  specs_dir=$(_planner_tds_specs_dir "$1")
  [ -d "$specs_dir" ] || return 0
  for f in "$specs_dir"/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "INDEX.md" ] && continue
    _planner_testdata_spec_is_synth "$f" && basename "$f" .md
  done | LC_ALL=C sort
}

# Keys a TD spec file owns, one per line: its keys comment line, else the
# previous sidecar's td_specs entry for that slug.
# Usage: _planner_tds_spec_keys <INIT> <slug>
_planner_tds_spec_keys() {
  local f line sc
  f="$(_planner_tds_specs_dir "$1")/${2}.md"
  line=$(grep -F -m1 -- "$PLANNER_TESTDATA_SYNTH_KEYS_PREFIX" "$f" 2>/dev/null)
  if [ -n "$line" ]; then
    line="${line#*"$PLANNER_TESTDATA_SYNTH_KEYS_PREFIX"}"
    line="${line% -->*}"
    tr ';' '\n' <<<"$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d'
    return 0
  fi
  sc=$(_planner_tds_sidecar "$1")
  [ -f "$sc" ] && jq -r --arg s "$2" '.td_specs[]? | select(.slug == $s) | .keys[]?' "$sc" 2>/dev/null
}

# Dispatched TD specs: synth-marked files whose slug has a ticket, one
# `<slug>\x1f<key>` record per owned key (a dispatched spec with no readable
# key still prints `<slug>\x1f`). Sorted.
# Usage: _planner_tds_dispatched <INIT>
_planner_tds_dispatched() {
  local slug k any
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    planner_testdata_synth_has_ticket "$1" "$slug" || continue
    any=false
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      printf '%s\037%s\n' "$slug" "$k"
      any=true
    done < <(_planner_tds_spec_keys "$1" "$slug")
    [ "$any" = true ] || printf '%s\037\n' "$slug"
  done < <(_planner_tds_marked_slugs "$1")
}

# Needs a TD spec file lists under `## Test Data Provided`, one per line, as
# the render writes them after the record key:
#   <data> — for `<consumer>`: <criterion>
# A dispatched (frozen) TD spec takes on only the needs its file — and so its
# ticket body — already lists.
# Usage: _planner_tds_spec_listed <INIT> <slug>
_planner_tds_spec_listed() {
  local f
  f="$(_planner_tds_specs_dir "$1")/${2}.md"
  [ -f "$f" ] || return 0
  tr -d '\r' <"$f" | awk '
    /^(```|~~~)/ { fence = !fence }
    !fence && /^## / { on = ($0 ~ /^## Test Data Provided[[:space:]]*$/); next }
    on && /^- `td-[^`]*` — / { sub(/^- `td-[^`]*` — /, ""); print }'
}

# The previous run's record numbers, from the sidecar's overrides:
#   <consumer>\x1f<criterion>\x1f<data>\x1f<n>
# Usage: _planner_tds_prev_numbers <INIT>
_planner_tds_prev_numbers() {
  local sc
  sc=$(_planner_tds_sidecar "$1")
  [ -f "$sc" ] || return 0
  jq -r '.overrides[]? | select((.record // "") | test("-[0-9]+$"))
    | [.consumer, .criterion, (.data // ""), (.record | capture("-(?<n>[0-9]+)$").n)] | join("\u001f")' "$sc" 2>/dev/null
}

# ── 4.3 Assignment ──────────────────────────────────────────────────────────

# Every need placed in its TD spec, sorted by td_slug, consumer, criterion,
# data:
#   <td_slug>\x1f<n>\x1f<consumer>\x1f<criterion>\x1f<data>\x1f<key>\x1f<entity>\x1f<load_via>
# Placement: a need whose key a dispatched TD spec owns
# (planner_testdata_synth_has_ticket + its keys line; the first by slug when
# several own it) goes to that spec only when the spec's frozen file already
# lists that exact need (_planner_tds_spec_listed) — its ticket is in the
# tracker and never lists a need added later. Every other need is placed
# fresh: a key used by >= 2 distinct consumers (counting only fresh needs) →
# the pack, else → <consumer>-test-data. A fresh slug that a dispatched spec
# already holds gets `-2`, `-3`, … appended — the dispatched file is frozen,
# so it cannot take on a new need or key.
# Numbering (record key td-<init>-<n>) is stable across runs: a need the
# previous sidecar numbered keeps its n; new needs get max(previous n)+1, …
# in the order above. With no sidecar, n is 1.. in that order.
# Returns 1 (nothing printed, every collision named on stderr) when a TD slug
# is held by an unmarked spec.
# Usage: planner_testdata_synth_assign <initiative_id>
planner_testdata_synth_assign() {
  local init="$1" needs prefix specs_dir
  needs=$(planner_testdata_synth_needs "$init") || return 1
  [ -n "$needs" ] || return 0
  specs_dir=$(_planner_tds_specs_dir "$init")
  prefix=$(planner_testdata_synth_prefix "$init")

  local -A key_consumers=() key_n=() owner=() dispatched=() listed=()
  local c crit data key ent lv d_slug d_key l
  while IFS=$'\037' read -r d_slug d_key; do
    [ -n "$d_slug" ] || continue
    if [ -z "${dispatched[$d_slug]:-}" ]; then
      while IFS= read -r l; do
        [ -n "$l" ] && listed["${d_slug}"$'\037'"${l}"]=1
      done < <(_planner_tds_spec_listed "$init" "$d_slug")
    fi
    dispatched["$d_slug"]=1
    [ -n "$d_key" ] && [ -z "${owner[$d_key]:-}" ] && owner["$d_key"]="$d_slug"
  done < <(_planner_tds_dispatched "$init")

  while IFS=$'\037' read -r c crit data key ent lv; do
    # A need the frozen owner already lists is not placed fresh.
    [ -n "${owner[$key]:-}" ] &&
      [ -n "${listed["${owner[$key]}"$'\037'"${data} — for \`${c}\`: ${crit:-(criterion not recorded)}"]:-}" ] &&
      continue
    [[ " ${key_consumers[$key]:-} " == *" ${c} "* ]] && continue
    key_consumers["$key"]="${key_consumers[$key]:-} ${c}"
    key_n["$key"]=$((${key_n[$key]:-0} + 1))
  done <<<"$needs"

  local placed td bad=0 i suffix stem
  placed=$(while IFS=$'\037' read -r c crit data key ent lv; do
    if [ -n "${owner[$key]:-}" ] &&
      [ -n "${listed["${owner[$key]}"$'\037'"${data} — for \`${c}\`: ${crit:-(criterion not recorded)}"]:-}" ]; then
      td="${owner[$key]}"
    else
      if [ "${key_n[$key]}" -ge 2 ]; then stem="$prefix" suffix="-test-data-pack"; else stem="$c" suffix="-test-data"; fi
      td=$(planner_testdata_synth_slug "$stem" "$suffix")
      i=2
      while [ -n "${dispatched[$td]:-}" ]; do
        td=$(planner_testdata_synth_slug "$stem" "${suffix}-${i}")
        i=$((i + 1))
      done
    fi
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$td" "$c" "$crit" "$data" "$key" "$ent" "$lv"
  done <<<"$needs" | LC_ALL=C sort -t$'\037' -k1,1 -k2,2 -k3,3 -k4,4 -u)

  while IFS= read -r td; do
    planner_testdata_synth_collision "$specs_dir" "$td" || bad=1
  done < <(cut -d$'\037' -f1 <<<"$placed" | LC_ALL=C sort -u)
  [ "$bad" = 0 ] || return 1

  awk -F'\037' 'BEGIN { OFS = "\037" }
    FILENAME == ARGV[1] { if (NF >= 4) { prev[$1 FS $2 FS $3] = $4; if ($4 + 0 > max) max = $4 + 0 } next }
    { k = $2 FS $3 FS $4
      if ((k in prev) && !(prev[k] in used)) { n = prev[k] } else { n = "" }
      if (n != "") used[n] = 1
      last++; rec[last] = $0; num[last] = n }
    END {
      for (i = 1; i <= last; i++) if (num[i] == "") { max++; num[i] = max }
      for (i = 1; i <= last; i++) {
        split(rec[i], f, FS)
        print f[1], num[i], f[2], f[3], f[4], f[5], f[6], f[7]
      }
    }' <(_planner_tds_prev_numbers "$init") <(printf '%s\n' "$placed")
}

# One record per TD spec, sorted by slug, from assign records on stdin:
#   <td_slug>\x1f<kind pack|single>\x1f<keys, comma-joined, sorted>\x1f<consumers, comma-joined, sorted>
# kind is pack for a `-test-data-pack` slug (with or without a `-<n>`
# disambiguation suffix), single otherwise.
_planner_tds_groups_of() {
  local td n c crit data key ent lv s
  local -A keys=() cons=()
  while IFS=$'\037' read -r td n c crit data key ent lv; do
    [ -n "$td" ] || continue
    keys["$td"]+="${key}"$'\n'
    cons["$td"]+="${c}"$'\n'
  done
  for s in "${!keys[@]}"; do
    printf '%s\037%s\037%s\037%s\n' "$s" \
      "$([[ "$s" =~ -test-data-pack(-[0-9]+)?$ ]] && echo pack || echo single)" \
      "$(sed '/^$/d' <<<"${keys[$s]}" | LC_ALL=C sort -u | paste -sd, -)" \
      "$(sed '/^$/d' <<<"${cons[$s]}" | LC_ALL=C sort -u | paste -sd, -)"
  done | LC_ALL=C sort
}

# One record per TD spec, sorted by slug (see _planner_tds_groups_of).
# Keys are normalized (entity or norm_key text), so they carry no comma.
# Returns 1 on a slug collision (planner_testdata_synth_assign).
# Usage: planner_testdata_synth_groups <initiative_id>
planner_testdata_synth_groups() {
  local assigned
  assigned=$(planner_testdata_synth_assign "$1") || return 1
  [ -n "$assigned" ] || return 0
  _planner_tds_groups_of <<<"$assigned"
}

# ── 4.4 The TD spec template ────────────────────────────────────────────────

# `Seed channel:` value: the distinct known Load via values of the needs, in
# PLANNER_TESTDATA_SYNTH_CHANNELS order, comma-joined (persona-select reads a
# list); PLANNER_TESTDATA_SYNTH_DEFAULT_CHANNEL when none is known.
# Usage: planner_testdata_synth_channel <load-via newline list>
planner_testdata_synth_channel() {
  local c out=""
  for c in $PLANNER_TESTDATA_SYNTH_CHANNELS; do
    grep -qxF -- "$c" <<<"$1" && out="${out}${out:+, }${c}"
  done
  printf '%s' "${out:-$PLANNER_TESTDATA_SYNTH_DEFAULT_CHANNEL}"
}

# Outcome ids the consumers serve (business: Serves, enabler: Enables),
# sorted, unique, one per line. Consumers without a parseable Signals block
# contribute nothing.
_planner_tds_consumer_outcomes() {
  local specs_dir="$1" c sig
  shift
  for c in "$@"; do
    [ -f "${specs_dir}/${c}.md" ] || continue
    sig=$(_planner_tds_signals "${specs_dir}/${c}.md") || continue
    jq -r '[(.Serves // []), (.Enables // [])] | flatten | .[] | strings' <<<"$sig" 2>/dev/null
  done | LC_ALL=C sort -u | sed '/^$/d'
}

# The services the consumers touch (their Signals AffectedServices, CSV), as
# one sorted, unique CSV — the seed targets live where the consumers' code
# does. `test-data` when no consumer names one: planned-ticket-check.sh
# requires a non-empty Affected Services, so TicketGen would refuse the TD
# ticket with an empty one (task 6.6).
_planner_tds_consumer_services() {
  local specs_dir="$1" c sig out
  shift
  out=$(for c in "$@"; do
    [ -f "${specs_dir}/${c}.md" ] || continue
    sig=$(_planner_tds_signals "${specs_dir}/${c}.md") || continue
    jq -r '.AffectedServices // "" | strings' <<<"$sig" 2>/dev/null | tr ',' '\n'
  done | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, - | sed 's/,/, /g')
  printf '%s\n' "${out:-test-data}"
}

# The first fenced block of `## Signals` as a compact JSON object — the
# reading planner_ticketgen_signals does (planner-ticket-body.sh sources the
# crosscheck libs, so it is not sourced from here). rc 1 when unparseable.
_planner_tds_signals() {
  tr -d '\r' <"$1" 2>/dev/null | awk '
    /^(```|~~~)/ && !sec { fence = !fence; next }
    !fence && /^## / { h = tolower($0); sub(/^## +/, "", h); sub(/[[:space:]]+$/, "", h); sec = (h == "signals"); next }
    sec && /^(```|~~~)/ { if (inb) exit; inb = 1; next }
    sec && inb { print }' | jq -ce 'select(type == "object")' 2>/dev/null
}

# Render one TD spec (design Decision 8). Reads planner_testdata_synth_assign
# records on stdin and keeps those whose td_slug is <td_slug>. Pure over its
# input plus the consumer specs' Signals (for Enables). Prints the spec.
#
# Contract points (each one checked by a later reader):
#   - PLANNER_TESTDATA_SYNTH_MARKER — tripwires skip it, recompute owns it;
#   - Labels `planned, INIT-<id>, chore` — chore: body-check and dor-check
#     test-data exemptions; no FE row in Scope → backend-only body;
#   - `Seed command: make seed-<slug>` / `Verify command: make
#     verify-seed-<slug>` — the only shape seed-apply runs;
#   - `Seed channel:` — persona-select's explicit channel line;
#   - AC phrases "the seed command exits 0 on two consecutive runs" and "the
#     verify command passes" + `make ` — gate-check's build-only mode; no
#     browser words (navigate/click/page/…) anywhere in the text;
#   - Verification Notes rows all `none` — self-verifying;
#   - Signals: Kind enabler, Serves [], Enables = consumers' outcome ids,
#     Strategy Conservative (appraise fast-path → simple), Priority High
#     (read by TicketGen, task 5.2), and raw confidence signals that derive
#     0.86 with planner_confidence_derive (>= the 0.85 default threshold, so
#     Pre-approved comes out true — it is never written here; see handoff);
#     AffectedServices (the consumers' union, else `test-data`) and
#     TargetSymbols (`seed-<slug>:Makefile; verify-seed-<slug>:Makefile`)
#     are non-empty because planned-ticket-check.sh requires both — TicketGen
#     refuses a body whose Planner Context leaves them blank. The Makefile
#     targets do not exist until the TD ticket lands, so the citation linter
#     skips a synth-marked spec's TargetSymbols.
# Usage: planner_testdata_synth_render <td_slug> <initiative_id> <pack|single>
planner_testdata_synth_render() {
  local slug="$1" init="$2" kind="$3"
  local recs
  recs=$(awk -F'\037' -v s="$slug" '$1 == s')
  [ -n "$recs" ] || {
    echo "planner-testdata-synth: no needs for ${slug}" >&2
    return 1
  }
  local init_label tok specs_dir
  init_label="INIT-${init#INIT-}"
  tok=$(_planner_tds_init_token "$init")
  specs_dir=$(_planner_tds_specs_dir "$init")

  local -a consumers=()
  mapfile -t consumers < <(cut -d$'\037' -f3 <<<"$recs" | LC_ALL=C sort -u)
  local channel outcomes enables_json title cons_md c services
  channel=$(planner_testdata_synth_channel "$(cut -d$'\037' -f8 <<<"$recs")")
  services=$(_planner_tds_consumer_services "$specs_dir" "${consumers[@]}")
  outcomes=$(_planner_tds_consumer_outcomes "$specs_dir" "${consumers[@]}")
  if [ -n "$outcomes" ]; then
    enables_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$outcomes")
  else
    enables_json='[]'
  fi
  cons_md=""
  for c in "${consumers[@]}"; do cons_md="${cons_md}${cons_md:+, }\`${c}\`"; done
  if [ "$kind" = "pack" ]; then
    title="Seed shared test data for ${#consumers[@]} specs"
  else
    title="Seed test data for ${consumers[0]}"
  fi

  local enables_line
  if [ -n "$outcomes" ]; then
    enables_line="**Enables:** $(paste -sd, - <<<"$outcomes" | sed 's/,/, /g') — the outcomes ${cons_md} deliver. Their acceptance criteria cannot be verified until the records below exist."
  else
    enables_line="**Enables:** none — ${cons_md} name no stated outcome. This ticket exists because their acceptance criteria cannot be verified until the records below exist."
  fi

  local provided="" n crit data r_td r_c r_key r_ent r_lv
  while IFS=$'\037' read -r r_td n r_c crit data r_key r_ent r_lv; do
    provided+="- \`td-${tok}-${n}\` — ${data} — for \`${r_c}\`: ${crit:-(criterion not recorded)}"$'\n'
  done <<<"$recs"

  local signals
  signals=$(jq -n --argjson enables "$enables_json" --arg slug "$slug" --arg services "$services" '{
    services_identified: 1,
    symbols_resolved: 2,
    prior_art_found: true,
    complexity: "simple",
    exploration_depth: "deep",
    Strategy: "Conservative",
    Decision: ("Seed the listed records through the make targets seed-" + $slug + " and verify-seed-" + $slug + "."),
    AffectedServices: $services,
    TargetSymbols: ("seed-" + $slug + ":Makefile; verify-seed-" + $slug + ":Makefile"),
    Kind: "enabler",
    Serves: [],
    Enables: $enables,
    Priority: "High"
  }')

  local keys_line
  keys_line="${PLANNER_TESTDATA_SYNTH_KEYS_PREFIX}$(cut -d$'\037' -f6 <<<"$recs" | LC_ALL=C sort -u | sed '/^$/d' | paste -sd';' - | sed 's/;/; /g') -->"

  cat <<EOF
# ${slug}

${PLANNER_TESTDATA_SYNTH_MARKER}
${keys_line}

## Title

${title}

## Description

## Summary

Seeds the synthetic test data that ${cons_md} need before their acceptance criteria can be verified, and adds a verify target that proves the data is in place.

## Enables

${enables_line}

## Background / Motivation

No existing seed set, fixture or external party provides these records. The needs come from the consumers' acceptance criteria, grouped here so one ticket owns the data and every consumer reads the same records. The consumer tickets are blocked by this one.

## Proposed Changes

- Add a \`seed-${slug}\` Make target that loads every record under Test Data Provided through the ${channel} channel. A second run leaves the same data: upsert by record key, never duplicate.
- Add a \`verify-seed-${slug}\` Make target that checks every record key is present in the stated state and exits non-zero when one is not.
- Add a \`reset-seed-${slug}\` Make target that removes only the records this ticket seeds.
- Add a README beside the seed scripts that maps each record key to its record and the consumer criterion it serves.

## Seed Commands

Seed command: make seed-${slug}
Verify command: make verify-seed-${slug}
Seed channel: ${channel}

Both commands must stay \`make <target>\` (or \`make -C <relpath> <target>\`); VERIFY refuses any other shape. Keep the seeding logic in the Makefile target, and keep these target names.

## Test Data Provided

${provided}
## Acceptance Criteria

- [ ] the seed command exits 0 on two consecutive runs
- [ ] the verify command passes
- [ ] Every seeded foreign key resolves to a seeded or existing parent record
- [ ] All seeded data is synthetic or masked, with no production personal data
- [ ] make reset-seed-${slug} removes only the records this ticket seeds and exits 0
- [ ] A README maps every record key under Test Data Provided to its record and consumer criterion

## Out of Scope

Application behaviour and the consumers' own acceptance criteria. Data that an external party must supply.

## Scope

| Layer | Service   | Area                                          |
| ----- | --------- | --------------------------------------------- |
| BE    | test data | seed, verify and reset scripts               |
| Infra | Makefile  | seed-${slug}, verify-seed-${slug}, reset-seed-${slug} |

## Test User

None — the seed, verify and reset commands run without signing in.

## Labels

planned, ${init_label}, chore

## Signals

\`\`\`json
${signals}
\`\`\`

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| the seed command exits 0 on two consecutive runs | implementer | none | — | — | exit code 0 on both runs | yes |
| the verify command passes | implementer | none | — | — | exit code 0 | yes |
| Every seeded foreign key resolves to a seeded or existing parent record | implementer | none | — | — | verify target reports no orphan rows | yes |
| All seeded data is synthetic or masked, with no production personal data | reviewer | none | — | — | needs human judgement of the seed scripts, no checkable value | no |
| make reset-seed-${slug} removes only the records this ticket seeds and exits 0 | implementer | none | — | — | exit code 0 and the verify target then fails | yes |
| A README maps every record key under Test Data Provided to its record and consumer criterion | reviewer | none | — | — | every td-${tok}-n key appears in the README | yes |
EOF
}

# ── 4.6 Writing: files only when their bytes change ─────────────────────────

# Move <tmp> onto <dest> only when the bytes differ (so an unchanged file
# keeps its mtime); otherwise drop <tmp>. Prints `changed` when it wrote.
# Usage: _planner_tds_commit <tmp> <dest>
_planner_tds_commit() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    rm -f "$1"
    return 0
  fi
  # mktemp files are 0600; give the result the mode the file had, else the
  # mode a plain redirect would have created under the current umask.
  if [ -f "$2" ]; then
    chmod --reference="$2" "$1" 2>/dev/null
  else
    chmod "$(printf '%o' $((0666 & ~$(umask))))" "$1" 2>/dev/null
  fi
  mv -f "$1" "$2" && echo changed
}

# The sidecar document (jq -S, pretty) for assign records on stdin.
#   td_specs  [{slug, kind, keys, consumers, dispatched}]   sorted by slug
#   overrides [{consumer, criterion, data, record, source}] sorted
#   edges     [{consumer, blocked_by}]                      sorted, unique,
#             a consumer never blocked by itself
# version 1. <dispatched_records> is _planner_tds_dispatched output (so a
# dispatched TD spec no need routes to any more is still listed).
# Usage: _planner_tds_sidecar_json <INIT> <dispatched_records>  (stdin: assign records)
_planner_tds_sidecar_json() {
  local tok
  tok=$(_planner_tds_init_token "$1")
  jq -Rn --arg tok "$tok" --arg disp "$2" '
    def uniqsort: unique | sort;
    [inputs | select(length > 0) | split("\u001f")
      | {td: .[0], n: .[1], consumer: .[2], criterion: .[3], data: .[4], key: .[5]}] as $recs
    | ($disp | split("\n") | map(select(length > 0) | split("\u001f") | {slug: .[0], key: (.[1] // "")})) as $d
    | ($d | map(.slug) | unique) as $dslugs
    | ([$recs[].td] + $dslugs | unique) as $slugs
    | {
        version: 1,
        td_specs: [$slugs[] as $s | {
          slug: $s,
          kind: (if ($s | test("-test-data-pack(-[0-9]+)?$")) then "pack" else "single" end),
          keys: ([$recs[] | select(.td == $s) | .key] + [$d[] | select(.slug == $s and .key != "") | .key] | uniqsort),
          consumers: ([$recs[] | select(.td == $s) | .consumer] | uniqsort),
          dispatched: ($dslugs | index($s) != null)
        }],
        overrides: ([$recs[] | {consumer, criterion, data,
          record: ("td-" + $tok + "-" + .n), source: ("seeded-by:" + .td)}]
          | sort_by(.consumer, .criterion, .data, .source)),
        edges: ([$recs[] | select(.consumer != .td) | {consumer, blocked_by: .td}] | unique | sort_by(.consumer, .blocked_by))
      }' | jq -S .
}

# INDEX.md block markers. Everything between them is synthesis-owned and
# rewritten whole; the rest of INDEX.md (Specify's) is never touched.
PLANNER_TESTDATA_SYNTH_INDEX_BEGIN='<!-- planner:testdata-synth index begin -->'
PLANNER_TESTDATA_SYNTH_INDEX_END='<!-- planner:testdata-synth index end -->'

# Rewrite the synthesis block of specs/INDEX.md from <sidecar>: one line per
# TD spec. Removes the block when the sidecar lists none. Leaves INDEX.md
# alone (no write, mtime kept) when the result equals what is on disk, or
# when there is nothing to add and no block to remove. Deletes an INDEX.md
# that held nothing but the block.
# Usage: _planner_tds_index_update <specs_dir> <sidecar_json_file>
_planner_tds_index_update() {
  local index="$1/INDEX.md" sc="$2" block base tmp
  block=$(jq -r '.td_specs[]? | "- `\(.slug)` — synthesized test data (\(.kind))"
      + (if (.consumers | length) > 0 then " for " + (.consumers | map("`" + . + "`") | join(", ")) else "" end)
      + (if .dispatched then " — ticket exists" else "" end)' "$sc" 2>/dev/null)
  if [ ! -f "$index" ]; then
    [ -n "$block" ] || return 0
    base=""
  else
    if [ -z "$block" ] && ! grep -qxF -- "$PLANNER_TESTDATA_SYNTH_INDEX_BEGIN" "$index"; then
      return 0
    fi
    base=$(awk -v b="$PLANNER_TESTDATA_SYNTH_INDEX_BEGIN" -v e="$PLANNER_TESTDATA_SYNTH_INDEX_END" '
      $0 == b { skip = 1; next }
      skip && $0 == e { skip = 0; next }
      !skip' "$index")
  fi
  tmp=$(mktemp "${index}.XXXXXX") || return 1
  {
    [ -n "$base" ] && printf '%s\n' "$base"
    if [ -n "$block" ]; then
      [ -n "$base" ] && printf '\n'
      printf '%s\n## Test data specs (synthesized by Crosscheck)\n\n%s\n%s\n' \
        "$PLANNER_TESTDATA_SYNTH_INDEX_BEGIN" "$block" "$PLANNER_TESTDATA_SYNTH_INDEX_END"
    fi
  } >"$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$index"
    return 0
  fi
  _planner_tds_commit "$tmp" "$index" >/dev/null
}

# ── Sidecar reader (Crosscheck row walker; TicketGen composer, task 4.8) ────

# Source overrides synthesis recorded, one per line, sorted:
#   <consumer>\x1f<criterion>\x1f<data>\x1f<source seeded-by:<td>>\x1f<record td-<init>-<n>>
# Only overrides whose TD spec exists on disk with the synthesis marker are
# printed — a stale sidecar entry for a deleted or hand-replaced spec owns
# nothing. Match a consumer row on consumer + criterion + data (data is the
# row's Test data text exactly as _planner_testdata_rows / spec_needs parse
# it; criterion is its Criterion cell); consumer + criterion alone is
# ambiguous when one criterion has two generate rows.
# Usage: planner_testdata_synth_overrides <initiative_id>
planner_testdata_synth_overrides() {
  [ -n "${REPOS_ROOT:-}" ] || return 0
  _planner_tds_overrides_of "$(_planner_tds_sidecar "$1")" "$(_planner_tds_specs_dir "$1")"
}

# The same, from a sidecar path and the specs dir it governs (the TicketGen
# composer only has the spec file; the sidecar is <specs_dir>/../testdata-synth.json).
# Usage: _planner_tds_overrides_of <sidecar_file> <specs_dir>
_planner_tds_overrides_of() {
  local sc="$1" specs_dir="$2" c crit data src rec
  [ -f "$sc" ] || return 0
  while IFS=$'\037' read -r c crit data src rec; do
    [ -n "$c" ] || continue
    _planner_testdata_spec_is_synth "${specs_dir}/${src#seeded-by:}.md" || continue
    printf '%s\037%s\037%s\037%s\037%s\n' "$c" "$crit" "$data" "$src" "$rec"
  done < <(jq -r '.overrides[]? | [.consumer, .criterion, (.data // ""), .source, (.record // "")] | join("\u001f")' "$sc" 2>/dev/null) |
    LC_ALL=C sort
}

# Sidecar edges, one `<consumer>\x1f<blocked_by>` per line, sorted (task 4.8/4.9
# reader). Like the overrides, an edge whose TD spec is not on disk with the
# synthesis marker is dropped — a stale sidecar must not invent a dangling
# dependency. The ONE edge reader: TicketGen (planner_ticketgen_spec_deps)
# and Crosscheck's cycle check both go through _planner_tds_edges_of.
# Usage: planner_testdata_synth_edges <initiative_id>
planner_testdata_synth_edges() {
  [ -n "${REPOS_ROOT:-}" ] || return 0
  _planner_tds_edges_of "$(_planner_tds_sidecar "$1")" "$(_planner_tds_specs_dir "$1")"
}

# The same, from a sidecar path and the specs dir it governs (TicketGen only
# has the specs dir; the sidecar is <specs_dir>/../testdata-synth.json).
# Usage: _planner_tds_edges_of <sidecar_file> <specs_dir>
_planner_tds_edges_of() {
  local sc="$1" specs_dir="$2" c b
  [ -f "$sc" ] || return 0
  while IFS=$'\037' read -r c b; do
    [ -n "$c" ] && [ -n "$b" ] || continue
    _planner_testdata_spec_is_synth "${specs_dir}/${b}.md" || continue
    printf '%s\037%s\n' "$c" "$b"
  done < <(jq -r '.edges[]? | select(.consumer != .blocked_by) | [.consumer, .blocked_by] | join("\u001f")' "$sc" 2>/dev/null) |
    LC_ALL=C sort -u
}

# ── Entry point ─────────────────────────────────────────────────────────────

# Crosscheck's synthesis sub-step (tasks 4.5-4.6): a full recompute.
#   1. plan: planner_testdata_synth_assign (needs → TD specs, dispatched TD
#      specs keep their keys, stable record numbers); a slug collision
#      returns 1 before anything is written;
#   2. delete every synth-marked spec that is not in the plan and has no
#      ticket (planner_testdata_synth_has_ticket);
#   3. render each planned TD spec and write it only when its bytes change;
#      a dispatched TD spec's file is never rewritten (its ticket body is
#      already in the tracker);
#   4. write artifacts/testdata-synth.json and the INDEX.md block, each only
#      when its bytes change. With nothing to synthesize and no sidecar on
#      disk, no sidecar is created.
# Consumer specs are never written. A second run with no input change
# changes no file (content or mtime).
# Prints one `<td_slug>\x1f<pack|single>\x1f<need count>` line per TD spec
# in the sidecar (dispatched ones with no routed need print 0).
# Returns 0 ok, 1 collision / REPOS_ROOT unset / write failure.
# Usage: planner_testdata_synthesize <initiative_id>
planner_testdata_synthesize() {
  local init="$1" assigned disp specs_dir sc tmp slug kind
  assigned=$(planner_testdata_synth_assign "$init") || return 1
  specs_dir=$(_planner_tds_specs_dir "$init")
  sc=$(_planner_tds_sidecar "$init")
  disp=$(_planner_tds_dispatched "$init")

  local -A planned=() is_disp=()
  while IFS=$'\037' read -r slug _; do [ -n "$slug" ] && is_disp["$slug"]=1; done <<<"$disp"
  while IFS=$'\037' read -r slug _; do [ -n "$slug" ] && planned["$slug"]=1; done <<<"$assigned"

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    [ -n "${planned[$slug]:-}" ] && continue
    [ -n "${is_disp[$slug]:-}" ] && continue
    rm -f "${specs_dir}/${slug}.md" || return 1
  done < <(_planner_tds_marked_slugs "$init")

  local g_slug g_kind g_keys g_cons
  if [ -n "$assigned" ]; then
    while IFS=$'\037' read -r g_slug g_kind g_keys g_cons; do
      [ -n "$g_slug" ] || continue
      [ -n "${is_disp[$g_slug]:-}" ] && continue
      tmp=$(mktemp "${specs_dir}/.${g_slug}.XXXXXX") || return 1
      planner_testdata_synth_render "$g_slug" "$init" "$g_kind" <<<"$assigned" >"$tmp" || {
        rm -f "$tmp"
        return 1
      }
      _planner_tds_commit "$tmp" "${specs_dir}/${g_slug}.md" >/dev/null || return 1
    done < <(_planner_tds_groups_of <<<"$assigned")
  fi

  if [ -n "$assigned" ] || [ -n "$disp" ] || [ -f "$sc" ]; then
    mkdir -p "$(dirname "$sc")" || return 1
    tmp=$(mktemp "${sc}.XXXXXX") || return 1
    if ! _planner_tds_sidecar_json "$init" "$disp" <<<"$assigned" >"$tmp" || [ ! -s "$tmp" ]; then
      rm -f "$tmp"
      echo "planner-testdata-synth: could not render $(basename "$sc")" >&2
      return 1
    fi
    _planner_tds_commit "$tmp" "$sc" >/dev/null || return 1
    _planner_tds_index_update "$specs_dir" "$sc" || return 1

    jq -r '.td_specs[] | .slug as $s | [$s, .kind] | join("\u001f")' "$sc" | while IFS=$'\037' read -r slug kind; do
      printf '%s\037%s\037%s\n' "$slug" "$kind" "$(awk -F'\037' -v s="$slug" '$1 == s' <<<"$assigned" | grep -c .)"
    done
  fi
  return 0
}

# ── 5.1 EpicGen: the UAT policy a TD-bearing shared-branch epic gets ────────

# The `uat_policy` EpicGen hands the Branch Directive generator (design
# Decision 10). Under per-ticket UAT on a shared epic branch, a TD ticket's PR
# parked in UAT never reaches Done, so every consumer it blocks deadlocks; epic
# UAT routes the children Review → Done instead.
#
#   <explicit> non-empty (the operator's `uat-policy` config) → <explicit>, always;
#   <shared> != true (no directive / develop)                → empty (unchanged);
#   artifacts/testdata-synth.json lists ≥1 TD spec           → epic;
#   otherwise                                                → empty (the
#     validator then resolves per-ticket, as before).
#
# Pure over the sidecar: no spec is read, nothing is written.
# Usage: planner_testdata_synth_uat_policy <initiative_id> <shared:true|false> [explicit]
planner_testdata_synth_uat_policy() {
  local init="$1" shared="$2" explicit="${3:-}" sc n
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  [ "$shared" = "true" ] || return 0
  sc=$(_planner_tds_sidecar "$init")
  [ -f "$sc" ] || return 0
  n=$(jq -r '[.td_specs[]? | select((.slug // "") != "")] | length' "$sc" 2>/dev/null) || n=0
  [ "${n:-0}" -ge 1 ] 2>/dev/null && printf 'epic\n'
  return 0
}
