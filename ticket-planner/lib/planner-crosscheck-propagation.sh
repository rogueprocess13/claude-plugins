#!/usr/bin/env bash
# planner-crosscheck-propagation.sh — Deterministic cross-ticket propagation linter.
#
# Part of the Crosscheck check family (github issue #178). This is #173: does a
# Consensus resolution or an in-spec forward reference that names more than one
# ticket actually reach every ticket it names?
#
# WHY THIS IS A HEURISTIC, NOT A DIFF
# ------------------------------------
# In the current phase order (Appraisal → Discovery → Architecture → Specify →
# Review → Consensus → EpicGen → TicketGen → Completed), Specify writes
# artifacts/specs/*.md BEFORE Review and Consensus run, and
# planner_prompt_consensus only ever rewrites proposal.md — it never patches the
# spec files. There is no preserved "pre-consensus" snapshot of proposal.md to
# diff against, and specs have no canonical, machine-delimited Acceptance
# Criteria section (ACs live inside free-form ## Description prose). True
# semantic "did the fix reach the AC" verification needs an LLM in the loop.
#
# This script instead checks the artifacts we do have with a bounded, testable
# heuristic: does the *substance* named in a resolution/forward-reference (its
# backtick-quoted identifiers, or significant words when none exist) actually
# show up in the ticket(s) it's supposed to reach? That catches the audit's
# worked examples (a missing `status` field; zero overlap between "lock/override
# display" and the ticket it was promised to land in) without needing an agent.
#
# Three checks:
#
#   planner_crosscheck_consensus_propagation — for each "accepted" finding block
#   in consensus.md that names 2+ known ticket slugs, checks whether the
#   finding's substance shows up in some of those specs but not others.
#   Code: RESOLUTION_NOT_PROPAGATED (fires only on asymmetric propagation — a
#   resolution that reaches none, or a resolution naming only one ticket, is a
#   different problem and out of scope here; see issue #173 AC3).
#
#   planner_crosscheck_forward_references — scans every spec for "lands in
#   `X`" / "delivered by `X`" / "see `X`" / "additive to `X`" naming another
#   known ticket slug, and checks the promised substance shows up in the named
#   spec. Code: FORWARD_REF_UNFULFILLED.
#
#   planner_crosscheck_carve_scope — detection only (see header note above): if
#   the ticket count Specify declared in state.log ("...for N tickets") doesn't
#   match the actual spec file count, a carve or drop happened after Specify
#   and needs a human scope audit — this script cannot reconstruct the
#   pre-carve proposal to diff automatically. Code: CARVE_SCOPE_LOST.
#
# Usage:
#   planner_crosscheck_propagation <initiative_id>
#     Runs all three checks. Returns 0 if clean, 1 if any finding was reported.
#
# Sourceable library — no set -euo pipefail.

# ── Config ──────────────────────────────────────────────────────────────────

# Below this length, a bare (non-backtick) word is considered noise, not a
# meaningful term to track propagation of.
PLANNER_CROSSCHECK_PROP_MIN_WORD_LEN=4

# Generic planner/prose vocabulary excluded from bare-word term extraction —
# these appear in nearly every ticket regardless of substance and would make
# every finding "propagate" trivially.
PLANNER_CROSSCHECK_PROP_STOPWORDS=(
  "this" "that" "with" "from" "into" "does" "not" "and" "for" "are" "was"
  "will" "lands" "land" "delivered" "deliver" "additive" "existing" "already"
  "reaches" "reach" "ticket" "tickets" "spec" "specs" "page" "same" "also"
  "only" "both" "other" "others" "sibling" "siblings" "still" "never" "ever"
  "which" "have" "has" "been" "being" "here" "there" "when" "then" "than"
)

# Fraction of extracted terms that must be present in a target file for the
# substance to count as "reached" it (ceil(n/2) — a bare majority).
_planner_crosscheck_prop_threshold() {
  local n="$1"
  echo $(((n + 1) / 2))
}

# ── Term extraction ──────────────────────────────────────────────────────────

# Extract the significant terms from a chunk of text: backtick-quoted spans if
# any exist (these are the precise, code-level claims — same priority as
# planner-crosscheck-citations.sh's precedent check), otherwise bare words at
# least PLANNER_CROSSCHECK_PROP_MIN_WORD_LEN long that aren't stopwords.
# Usage: _planner_crosscheck_prop_terms <text>
# Output: one lowercased term per line, deduped.
_planner_crosscheck_prop_terms() {
  local text="$1"
  local backticked
  backticked=$(echo "$text" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//')

  if [ -n "$backticked" ]; then
    echo "$backticked" | tr '[:upper:]' '[:lower:]' | sort -u
    return 0
  fi

  local word is_stopword stopword
  echo "$text" |
    tr -c '[:alnum:]_' '\n' |
    tr '[:upper:]' '[:lower:]' |
    while IFS= read -r word; do
      [ ${#word} -ge "$PLANNER_CROSSCHECK_PROP_MIN_WORD_LEN" ] || continue
      is_stopword=0
      for stopword in "${PLANNER_CROSSCHECK_PROP_STOPWORDS[@]}"; do
        if [ "$word" = "$stopword" ]; then
          is_stopword=1
          break
        fi
      done
      [ "$is_stopword" -eq 0 ] && echo "$word"
    done | sort -u
}

# Count how many of the given terms appear (literal, case-insensitive) in a
# file. A term also counts when it appears once the file's double quotes are
# removed, so prose `complexity: moderate` matches the Signals JSON line
# "complexity": "moderate" (rehearsal F25).
# Usage: _planner_crosscheck_prop_presence_count <file> <term1> [<term2> ...]
_planner_crosscheck_prop_presence_count() {
  local file="$1"
  shift
  local term count=0 unquoted
  unquoted=$(tr -d '"' <"$file" 2>/dev/null)
  for term in "$@"; do
    if grep -qiF -- "$term" "$file" 2>/dev/null ||
      grep -qiF -- "$term" <<<"$unquoted"; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# ── Known slugs ───────────────────────────────────────────────────────────────

# List ticket slugs with a spec file in specs_dir (basename minus .md, minus
# INDEX). Usage: _planner_crosscheck_known_slugs <specs_dir>
_planner_crosscheck_known_slugs() {
  local specs_dir="$1"
  local f base
  [ -d "$specs_dir" ] || return 0
  for f in "$specs_dir"/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .md)"
    [ "$base" = "INDEX" ] && continue
    echo "$base"
  done
}

# Which known slugs appear as a whole word/hyphenated-token match in text.
# Usage: _planner_crosscheck_slugs_in_text <text> <slug1> [<slug2> ...]
_planner_crosscheck_slugs_in_text() {
  local text="$1"
  shift
  local slug
  for slug in "$@"; do
    if echo "$text" | grep -qE "(^|[^A-Za-z0-9_-])${slug}([^A-Za-z0-9_-]|\$)"; then
      echo "$slug"
    fi
  done
}

# Strip ticket-slug mentions (with any surrounding backticks) out of text
# before term extraction. Without this, a sentence whose only backtick span is
# the slug reference itself ("...lands in `vs6-a`.") would make backtick-
# priority extraction return the slug as the only "term" — leaving nothing to
# check propagation of once the slug itself is filtered back out.
# Usage: _planner_crosscheck_strip_slugs <text> <slug1> [<slug2> ...]
_planner_crosscheck_strip_slugs() {
  local text="$1"
  shift
  local slug
  for slug in "$@"; do
    text=$(echo "$text" | sed -E "s/\`?${slug}\`?//g")
  done
  echo "$text"
}

# ── Check 1/2: Consensus resolution propagation ──────────────────────────────

# Split consensus.md into "finding blocks" (blank-line-separated paragraphs)
# and keep only blocks that read as an accepted disposition.
# Usage: _planner_crosscheck_accepted_blocks <consensus_file>
# Output: blocks separated by a NUL byte (blocks may contain embedded newlines).
_planner_crosscheck_accepted_blocks() {
  local consensus_file="$1"
  awk 'BEGIN{RS=""; ORS="\0"} tolower($0) ~ /accepted/ && tolower($0) !~ /reject|defer/ {print}' \
    "$consensus_file" 2>/dev/null
}

# Attribute a block's text to the ticket slugs it names. A Consensus block
# often hands each ticket a different piece of the resolution ("- auth-api:
# requireAuth checks ...", "- backend-foundation: every user gets a UUID
# `id`"), so pooling the whole block's terms and asking every named spec to
# hold a majority of them reported specs that had their own piece (dispatch
# rehearsal F25: 3 false RESOLUTION_NOT_PROPAGATED findings).
#
# Units are list items (a "-", "*", "+" or "N." line plus its continuation
# lines); text before the first item is one more unit. Within a unit, a slug
# mention or a run of mentions joined only by commas/"and"/"or" ("a, b and c")
# forms a group. The text after a group, up to the next group, belongs to
# every slug in it; the unit's lead (text before its first group) also goes to
# the first group, so "Both paths set `status`. Applies to a and b." still
# reaches both. A unit that names no slug ("Applies to a and b." above a
# bullet holding the resolution) is printed as a block-wide "free" line, the
# last fallback for a slug whose own share carries no terms. Mentions are
# matched literally on token boundaries, with surrounding backticks removed
# with them.
# Usage: printf '%s\n' "$block" | _planner_crosscheck_prop_segments <slug1> [<slug2> ...]
# Output: "<slug>\tseg\t<text>", "<slug>\tlead\t<unit lead>" and
# "\tfree\t<unit text>" lines.
_planner_crosscheck_prop_segments() {
  PROP_SLUGS="$*" awk '
    function isword(c) { return c ~ /[A-Za-z0-9_-]/ }
    function emit(u,   ns, sl, i, s, off, p, a, b, n, st, en, nm, j, k, t, g, gs, ge, gm, gap, lead, seg, ms, mm, endp) {
      if (u == "") return
      ns = split(ENVIRON["PROP_SLUGS"], sl, " ")
      n = 0
      for (i = 1; i <= ns; i++) {
        s = sl[i]
        off = 0
        while ((p = index(substr(u, off + 1), s)) > 0) {
          a = off + p
          b = a + length(s) - 1
          off = b
          if (a > 1 && isword(substr(u, a - 1, 1))) continue
          if (b < length(u) && isword(substr(u, b + 1, 1))) continue
          if (a > 1 && b < length(u) && substr(u, a - 1, 1) == "`" && substr(u, b + 1, 1) == "`") { a--; b++ }
          n++; st[n] = a; en[n] = b; nm[n] = s
        }
      }
      if (n == 0) { print "\tfree\t" u; return }
      for (j = 2; j <= n; j++) {
        for (k = j; k > 1 && st[k - 1] > st[k]; k--) {
          t = st[k]; st[k] = st[k - 1]; st[k - 1] = t
          t = en[k]; en[k] = en[k - 1]; en[k - 1] = t
          t = nm[k]; nm[k] = nm[k - 1]; nm[k - 1] = t
        }
      }
      g = 0
      for (j = 1; j <= n; j++) {
        if (g > 0 && st[j] <= ge[g]) continue
        if (g > 0) {
          gap = substr(u, ge[g] + 1, st[j] - ge[g] - 1)
          if (gap ~ /^[ \t,]*((and|or)[ \t]+)?$/) { gm[g] = gm[g] " " nm[j]; ge[g] = en[j]; continue }
        }
        g++; gs[g] = st[j]; ge[g] = en[j]; gm[g] = nm[j]
      }
      lead = substr(u, 1, gs[1] - 1)
      for (i = 1; i <= g; i++) {
        endp = (i < g) ? gs[i + 1] : length(u) + 1
        seg = substr(u, ge[i] + 1, endp - ge[i] - 1)
        if (i == 1) seg = lead " " seg
        ms = split(gm[i], mm, " ")
        for (k = 1; k <= ms; k++) {
          print mm[k] "\tseg\t" seg
          print mm[k] "\tlead\t" lead
        }
      }
    }
    { gsub(/\t/, " ") }
    /^[ \t]*([-*+]|[0-9]+\.)[ \t]/ { emit(cur); cur = $0; next }
    { cur = (cur == "") ? $0 : cur " " $0 }
    END { emit(cur) }
  '
}

# Check every accepted consensus finding that names 2+ known tickets for
# asymmetric propagation into those tickets' specs. Each named spec is checked
# against the terms of its own share of the block (_planner_crosscheck_prop_segments).
# Usage: planner_crosscheck_consensus_propagation <consensus_file> <specs_dir>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_consensus_propagation() {
  local consensus_file="$1" specs_dir="$2"
  local failures=0

  [ -f "$consensus_file" ] || return 0

  local -a known_slugs
  mapfile -t known_slugs < <(_planner_crosscheck_known_slugs "$specs_dir")
  [ "${#known_slugs[@]}" -ge 2 ] || return 0

  local block
  while IFS= read -r -d '' block; do
    [ -z "$block" ] && continue

    local -a named_slugs
    mapfile -t named_slugs < <(_planner_crosscheck_slugs_in_text "$block" "${known_slugs[@]}")
    [ "${#named_slugs[@]}" -ge 2 ] || continue

    local -A seg_text=() lead_text=()
    local free_text="" s_line s_slug s_kind s_text
    while IFS= read -r s_line; do
      s_slug="${s_line%%$'\t'*}"
      s_line="${s_line#*$'\t'}"
      s_kind="${s_line%%$'\t'*}"
      s_text="${s_line#*$'\t'}"
      case "$s_kind" in
      seg) seg_text[$s_slug]+=" ${s_text}" ;;
      lead) lead_text[$s_slug]+=" ${s_text}" ;;
      free) free_text+=" ${s_text}" ;;
      esac
    done < <(printf '%s\n' "$block" | _planner_crosscheck_prop_segments "${named_slugs[@]}")

    # Backtick priority holds block-wide: when the block quotes identifiers,
    # a share made only of prose ("store and auth are unchanged") carries no
    # checkable claim and is skipped rather than matched word by word.
    local backticked_only=0
    case "$block" in *'`'*'`'*) backticked_only=1 ;; esac

    local -a present absent missing_terms terms
    present=()
    absent=()
    missing_terms=()
    local slug spec_file count threshold share
    for slug in "${named_slugs[@]}"; do
      spec_file="${specs_dir}/${slug}.md"
      [ -f "$spec_file" ] || continue
      terms=()
      for share in "${seg_text[$slug]:-}" "${lead_text[$slug]:-}" "$free_text"; do
        if [ "$backticked_only" -eq 1 ]; then
          case "$share" in *'`'*'`'*) ;; *) continue ;; esac
        fi
        mapfile -t terms < <(_planner_crosscheck_prop_terms "$share")
        [ "${#terms[@]}" -gt 0 ] && break
      done
      [ "${#terms[@]}" -eq 0 ] && continue
      threshold=$(_planner_crosscheck_prop_threshold "${#terms[@]}")
      count=$(_planner_crosscheck_prop_presence_count "$spec_file" "${terms[@]}")
      if [ "$count" -ge "$threshold" ]; then
        present+=("$slug")
      else
        absent+=("$slug")
        missing_terms+=("${terms[@]}")
      fi
    done

    if [ "${#present[@]}" -gt 0 ] && [ "${#absent[@]}" -gt 0 ]; then
      local snippet
      snippet=$(echo "$block" | tr '\n' ' ' | cut -c1-140)
      echo "planner-crosscheck-propagation: RESOLUTION_NOT_PROPAGATED has-it=[${present[*]}] missing-it=[${absent[*]}] terms=[${missing_terms[*]}] — \"${snippet}...\""
      failures=$((failures + 1))
    fi
  done < <(_planner_crosscheck_accepted_blocks "$consensus_file")

  return $((failures > 0 ? 1 : 0))
}

# ── Check 3: forward references ──────────────────────────────────────────────

_PLANNER_CROSSCHECK_FORWARD_REF_PATTERNS=(
  "lands in"
  "delivered by"
  "\\bsee\\b"
  "additive to"
)

# Combined alternation of the patterns above, for a single grep -E pass.
_planner_crosscheck_forward_ref_regex() {
  local IFS='|'
  echo "${_PLANNER_CROSSCHECK_FORWARD_REF_PATTERNS[*]}"
}

# Scan every spec for a forward-reference to another known ticket and check
# the promised substance shows up there.
# Usage: planner_crosscheck_forward_references <specs_dir>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_forward_references() {
  local specs_dir="$1"
  local failures=0

  [ -d "$specs_dir" ] || return 0

  local -a known_slugs
  mapfile -t known_slugs < <(_planner_crosscheck_known_slugs "$specs_dir")
  [ "${#known_slugs[@]}" -ge 2 ] || return 0

  local spec_file
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    local base
    base="$(basename "$spec_file" .md)"
    [ "$base" = "INDEX" ] && continue
    # A TD spec Crosscheck's test-data synthesis wrote quotes its consumers'
    # criteria verbatim ("for `x`: … and see the row count"); those are back
    # references to the consumer, not promises (planner-test-data-derivation).
    grep -qF -- "${PLANNER_TESTDATA_SYNTH_MARKER:-<!-- planner:testdata-synth v1 -->}" "$spec_file" 2>/dev/null && continue

    local line_num line
    while IFS=: read -r line_num line; do
      [ -z "$line" ] && continue

      local -a named_slugs
      mapfile -t named_slugs < <(_planner_crosscheck_slugs_in_text "$line" "${known_slugs[@]}")

      local target
      for target in "${named_slugs[@]}"; do
        [ "$target" = "$base" ] && continue

        local target_file="${specs_dir}/${target}.md"
        [ -f "$target_file" ] || continue

        local stripped_line
        stripped_line=$(_planner_crosscheck_strip_slugs "$line" "$target" "$base")

        local -a filtered
        mapfile -t filtered < <(_planner_crosscheck_prop_terms "$stripped_line")
        [ "${#filtered[@]}" -eq 0 ] && continue

        local count
        count=$(_planner_crosscheck_prop_presence_count "$target_file" "${filtered[@]}")
        if [ "$count" -eq 0 ]; then
          echo "planner-crosscheck-propagation: FORWARD_REF_UNFULFILLED ${spec_file}:${line_num} → ${target} (promised terms=[${filtered[*]}] found in neither ${target_file})"
          failures=$((failures + 1))
        fi
      done
    done < <(grep -niE "$(_planner_crosscheck_forward_ref_regex)" "$spec_file" 2>/dev/null)
  done

  return $((failures > 0 ? 1 : 0))
}

# ── Check 4: carve scope (detection only) ────────────────────────────────────

# Detect a post-Specify ticket-count change. Cannot diff pre/post-carve scope
# — see header note — this only flags that a manual scope audit is needed.
# Usage: planner_crosscheck_carve_scope <state_log> <specs_dir>
# Returns: 0 if clean/undetectable, 1 if a mismatch was reported.
planner_crosscheck_carve_scope() {
  local state_log="$1" specs_dir="$2"

  [ -f "$state_log" ] || return 0

  local declared_n
  declared_n=$(grep '|Specify|synthesize|start|' "$state_log" 2>/dev/null |
    tail -1 | grep -oE 'for [0-9]+ tickets' | grep -oE '[0-9]+')
  [ -n "$declared_n" ] || return 0

  local actual_n=0
  if [ -d "$specs_dir" ]; then
    local f base
    for f in "$specs_dir"/*.md; do
      [ -f "$f" ] || continue
      base="$(basename "$f" .md)"
      [ "$base" = "INDEX" ] && continue
      # A TD spec Crosscheck's test-data synthesis wrote is not one Specify
      # declared (planner-test-data-derivation).
      grep -qF -- "${PLANNER_TESTDATA_SYNTH_MARKER:-<!-- planner:testdata-synth v1 -->}" "$f" 2>/dev/null && continue
      actual_n=$((actual_n + 1))
    done
  fi

  if [ "$declared_n" -ne "$actual_n" ]; then
    echo "planner-crosscheck-propagation: CARVE_SCOPE_LOST Specify declared ${declared_n} tickets, ${actual_n} spec files exist — a ticket was carved or dropped after Specify; manual scope audit needed (no pre-carve proposal snapshot is retained to diff automatically)"
    return 1
  fi

  return 0
}

# ── Public entry point ────────────────────────────────────────────────────────

# Run all three propagation checks for an initiative.
# Usage: planner_crosscheck_propagation <initiative_id>
# Returns: 0 if all clean, 1 if any check reported a finding.
planner_crosscheck_propagation() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local artifacts_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts"
  local state_log="${repos_root}/.ticket-auto/initiatives/${initiative_id}/state.log"
  local specs_dir="${artifacts_dir}/specs"
  local consensus_file="${artifacts_dir}/consensus.md"

  if [ ! -d "$artifacts_dir" ]; then
    echo "planner-crosscheck-propagation: artifacts directory not found: $artifacts_dir" >&2
    return 1
  fi

  local failures=0

  planner_crosscheck_consensus_propagation "$consensus_file" "$specs_dir" || failures=$((failures + 1))
  planner_crosscheck_forward_references "$specs_dir" || failures=$((failures + 1))
  planner_crosscheck_carve_scope "$state_log" "$specs_dir" || failures=$((failures + 1))

  return $((failures > 0 ? 1 : 0))
}
