#!/usr/bin/env bash
# planner-draft-readiness.sh — pure draft helpers for the draft readiness gate
# (openspec change planner-draft-readiness, slice S2a: design D2, D4, D13).
#
# The gate (S2b) evaluates each spec's would-be ticket body before the first
# Linear write. This file holds the parts that need no agent and no gate:
#
#   - D2 drafts: the body TicketGen would compose, with epic `DRAFT`, sibling
#     ids `DRAFT-<slug>` and the first `Crosscheck|check|done` timestamp as
#     the Planner Context `Generated` value. Pure over the specs and the state
#     log — no Linear call, no clock, byte-stable across runs.
#   - D4 per-spec files and the cache: `artifacts/draft-readiness/<slug>/`,
#     result files deleted when the body changes, `verdict` written last, the
#     directory of a removed spec dropped.
#   - D13 equivalence: a draft-to-real token map and the normalised hash that
#     decides whether a ticket body Linear stored is the draft the evaluator
#     saw. Refinement's carry-over (S4) and `dor_semantic_import` (S1) use it.
#
# The gate itself (S2b) is planner-draft-readiness-gate.sh.
#
# Public API:
#   planner_draft_readiness_root <INIT>          artifacts/draft-readiness
#   planner_draft_readiness_generated_ts <INIT>  first Crosscheck|check|done ts (rc 1: none)
#   planner_draft_readiness_dep_refs <INIT> <spec_file>
#                                                "DRAFT-<slug>\t<title>" per sibling,
#                                                "<ext-id>\t" per external ref
#   planner_draft_readiness_compose <INIT> <slug>
#                                                the draft body (stdout)
#   planner_draft_readiness_body_hash <file>     _dor_body_hash of the file's text
#   planner_draft_readiness_verdict_write <INIT> <slug> <hash> <evaluator> <ready|blocked|unavailable>
#   planner_draft_readiness_verdict_read <INIT> <slug>
#   planner_draft_readiness_refresh <INIT>       recompose every draft; one
#                                                "<slug>\t<hash>\t<cached|stale|error>" line each
#   planner_draft_readiness_token_map <INIT>     "<draft-token>\t<real-token>" lines
#   planner_draft_readiness_rewrite <map-file> <to-draft|to-real>
#                                                stdin → stdout token rewrite
#   planner_draft_readiness_equiv_text <map-file> <real|draft>
#                                                stdin → normalised comparison text
#   planner_draft_readiness_equiv_hash <map-file> <real|draft> <body-file>
#   planner_draft_readiness_equivalent <map-file> <real-body-file> <draft-body-file>
#                                                rc 0 equivalent, 1 not, 2 cannot tell
#
# Sourceable library — no set -euo pipefail.

_PLANNER_DRAFT_READINESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_ticket_body_compose >/dev/null 2>&1; then
  # shellcheck source=planner-ticket-body.sh
  source "${_PLANNER_DRAFT_READINESS_LIB_DIR}/planner-ticket-body.sh"
fi
if ! declare -f _planner_refinement_source_deps >/dev/null 2>&1; then
  # shellcheck source=planner-refinement.sh
  source "${_PLANNER_DRAFT_READINESS_LIB_DIR}/planner-refinement.sh"
fi

# Draft tokens (D2). The epic of every draft, and the prefix of a sibling's id.
PLANNER_DRAFT_EPIC="DRAFT"
PLANNER_DRAFT_ID_PREFIX="DRAFT-"
# Fixed token both sides' Planner Context `Generated` value becomes (D13).
PLANNER_DRAFT_GENERATED_TOKEN="DRAFT-GENERATED"

# Evaluation result files (D4): deleted when the body or the evaluator
# changes, before any spawn. `lineage.json` (the prior for the next round,
# D11) and the revision history (spec.r*, findings.r*, revise.r*, D14) are
# never in this list — they survive a body change and go only with the
# spec's directory.
PLANNER_DRAFT_RESULT_FILES="verdict dor-result.json scan-result.txt audit-result.txt semantic.json"

# ── Layout ────────────────────────────────────────────────────────────────

planner_draft_readiness_root() {
  local specs_dir
  specs_dir=$(planner_ticketgen_specs_dir "$1") || return 1
  echo "$(dirname "$specs_dir")/draft-readiness"
}

# ── D2: draft bodies ──────────────────────────────────────────────────────

# Timestamp of the first `Crosscheck|check|done` line — the draft's
# `Generated` value, so the hash is stable and the clock is never read. The
# first, not the latest: the gate re-runs Crosscheck after a spec edit (D5),
# and a moving timestamp would change every draft and re-evaluate them all
# instead of only the edited spec (S2b). rc 1 (nothing printed) when
# Crosscheck has not passed.
planner_draft_readiness_generated_ts() {
  local log_file ts=""
  log_file=$(planner_state_log "$1" 2>/dev/null) || return 1
  [ -f "$log_file" ] || return 1
  ts=$(grep -E '^[^|]*\|Crosscheck\|check\|done\|' "$log_file" 2>/dev/null | head -1 | cut -d'|' -f1)
  [ -n "$ts" ] || return 1
  echo "$ts"
}

# planner_ticketgen_dep_refs' draft twin: same dependency set (both read
# planner_ticketgen_spec_deps), but a sibling becomes DRAFT-<slug> instead of
# the created Linear id, so it never needs a ticket to exist. An external id
# is kept verbatim; a ref that resolves to nothing fails, as in TicketGen.
planner_draft_readiness_dep_refs() {
  local spec_file="$2" specs_dir ref
  specs_dir=$(dirname "$spec_file")
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ -f "${specs_dir}/${ref}.md" ]; then
      printf '%s%s\t%s\n' "$PLANNER_DRAFT_ID_PREFIX" "$ref" "$(planner_ticketgen_spec_title "${specs_dir}/${ref}.md")"
    elif planner_deps_is_external_ref "$ref"; then
      printf '%s\t\n' "$ref"
    else
      echo "planner-draft-readiness: blocked-by:${ref} in $(basename "$spec_file" .md) resolves to no sibling spec" >&2
      return 1
    fi
  done < <(planner_ticketgen_spec_deps "$spec_file" "$specs_dir")
}

# The draft body for one spec: planner_ticket_body_compose, unchanged, with
# the draft Planner Context and draft Related Tickets.
planner_draft_readiness_compose() {
  local initiative_id="$1" slug="$2" specs_dir spec_file ts context refs
  specs_dir=$(planner_ticketgen_specs_dir "$initiative_id") || return 1
  spec_file="${specs_dir}/${slug}.md"
  [ -f "$spec_file" ] || {
    echo "planner-draft-readiness: spec not found: $spec_file" >&2
    return 1
  }
  ts=$(planner_draft_readiness_generated_ts "$initiative_id") || {
    echo "planner-draft-readiness: no Crosscheck|check|done line for ${initiative_id} — drafts need a passed Crosscheck" >&2
    return 1
  }
  context=$(planner_ticketgen_context_block "$initiative_id" "$PLANNER_DRAFT_EPIC" "$spec_file" "$ts") || return 1
  refs=$(planner_draft_readiness_dep_refs "$initiative_id" "$spec_file") || return 1
  local -a entries=()
  [ -n "$refs" ] && mapfile -t entries <<<"$refs"
  planner_ticket_body_compose "$spec_file" "$context" "${entries[@]}"
}

# ── D4: per-spec files and cache ──────────────────────────────────────────

# The evaluator's own hash of a body file (`sha256:<hex>`), computed by
# ticket-auto-pipeline's _dor_body_hash over `$(cat file)` — the same text
# dor_semantic_apply hashes, so a verdict's hash is the one the findings
# builder checks.
planner_draft_readiness_body_hash() {
  local f="$1" h
  [ -f "$f" ] || return 1
  _planner_refinement_source_deps >/dev/null || return 1
  h=$(_dor_body_hash "$(cat "$f")")
  [ -n "$h" ] || return 1
  echo "$h"
}

# Writes `verdict` = "<hash> <evaluator> <status>" (tmp + mv). The caller
# writes it LAST, after semantic.json and lineage.json: a crash before this
# leaves no verdict, so the next run re-evaluates.
planner_draft_readiness_verdict_write() {
  local initiative_id="$1" slug="$2" hash="$3" evaluator="$4" status="$5" dir
  case "$status" in ready | blocked | unavailable) ;; *)
    echo "planner-draft-readiness: invalid verdict status '${status}'" >&2
    return 1
    ;;
  esac
  [ -n "$hash" ] && [ -n "$evaluator" ] || return 1
  dir="$(planner_draft_readiness_root "$initiative_id")/${slug}" || return 1
  mkdir -p "$dir" || return 1
  printf '%s %s %s\n' "$hash" "$evaluator" "$status" >"${dir}/verdict.tmp" &&
    mv -f "${dir}/verdict.tmp" "${dir}/verdict"
}

planner_draft_readiness_verdict_read() {
  local f
  f="$(planner_draft_readiness_root "$1")/$2/verdict" || return 1
  [ -f "$f" ] || return 1
  head -1 "$f"
}

_planner_draft_readiness_clear_results() {
  local dir="$1" f
  for f in $PLANNER_DRAFT_RESULT_FILES; do
    rm -f "${dir}/${f}"
  done
}

# planner_draft_readiness_refresh <INIT>
# Recomposes every draft (bash, cheap) and prints one line per spec:
#   <slug>\t<hash>\tcached   verdict matches the body hash and evaluator
#   <slug>\t<hash>\tstale    needs a scan + audit (no verdict, or a mismatch)
#   <slug>\t\terror          compose refused the spec (reason on stderr)
# `stale` is the spawn list's input; an unchanged resume prints no `stale`.
# Side effects, all under artifacts/draft-readiness/:
#   - body.md is rewritten only when its bytes differ;
#   - a changed body, or a verdict from another evaluator, deletes the
#     result files first (PLANNER_DRAFT_RESULT_FILES), so no stale scan or
#     audit result can be applied to the new text;
#   - a spec that no longer exists loses its whole directory.
# The evaluator is $DOR_SEMANTIC_EVALUATOR from ticket-auto-pipeline's
# dor-semantic.sh. rc 1 when the specs or the evaluator cannot be read.
planner_draft_readiness_refresh() {
  local initiative_id="$1" specs_dir root evaluator slug dir hash v_hash v_eval v_status
  specs_dir=$(planner_ticketgen_specs_dir "$initiative_id") || return 1
  [ -d "$specs_dir" ] || {
    echo "planner-draft-readiness: no specs directory: $specs_dir" >&2
    return 1
  }
  root=$(planner_draft_readiness_root "$initiative_id") || return 1
  _planner_refinement_source_deps >/dev/null || return 1
  evaluator="${DOR_SEMANTIC_EVALUATOR:-}"
  [ -n "$evaluator" ] || {
    echo "planner-draft-readiness: DOR_SEMANTIC_EVALUATOR is not set" >&2
    return 1
  }
  mkdir -p "$root" || return 1

  local -A present=()
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    present[$slug]=1
    dir="${root}/${slug}"
    mkdir -p "$dir" || return 1
    local body
    if ! body=$(planner_draft_readiness_compose "$initiative_id" "$slug"); then
      # The old verdict describes a body that no longer composes.
      _planner_draft_readiness_clear_results "$dir"
      printf '%s\t\terror\n' "$slug"
      continue
    fi
    if [ ! -f "${dir}/body.md" ] || [ "$(cat "${dir}/body.md")" != "$body" ]; then
      _planner_draft_readiness_clear_results "$dir"
      printf '%s' "$body" >"${dir}/body.md.tmp" && mv -f "${dir}/body.md.tmp" "${dir}/body.md" || return 1
    fi
    hash=$(planner_draft_readiness_body_hash "${dir}/body.md") || return 1
    v_hash="" v_eval="" v_status=""
    if [ -f "${dir}/verdict" ]; then
      read -r v_hash v_eval v_status <"${dir}/verdict"
    fi
    if [ "$v_hash" = "$hash" ] && [ "$v_eval" = "$evaluator" ] && [ -n "$v_status" ]; then
      printf '%s\t%s\tcached\n' "$slug" "$hash"
    else
      if [ -f "${dir}/verdict" ]; then
        _planner_draft_readiness_clear_results "$dir"
      fi
      printf '%s\t%s\tstale\n' "$slug" "$hash"
    fi
  done < <(planner_ticketgen_slugs "$specs_dir")

  local d
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    slug=$(basename "$d")
    [ -n "${present[$slug]:-}" ] || rm -rf "${root:?}/${slug}"
  done
  return 0
}

# ── D13: draft-equivalent rewrite and normalisation ───────────────────────

# planner_draft_readiness_token_map <INIT>
# The token map: one "<draft-token>\t<real-token>" line per known id —
# `DRAFT\t<epic id>` once EpicGen recorded it, `DRAFT-<slug>\t<ticket id>`
# for every spec with a created ticket. Sorted longest draft token first.
# The Planner Context `Generated` timestamp is NOT in the map: it is
# normalised to a fixed token on both sides (planner_draft_readiness_equiv_text).
# Prints nothing (rc 0) before EpicGen.
planner_draft_readiness_token_map() {
  local initiative_id="$1" specs_dir epic slug id
  specs_dir=$(planner_ticketgen_specs_dir "$initiative_id") || return 1
  {
    if epic=$(planner_epic_id "$initiative_id" 2>/dev/null) && [ -n "$epic" ]; then
      printf '%s\t%s\n' "$PLANNER_DRAFT_EPIC" "$epic"
    fi
    while IFS= read -r slug; do
      [ -z "$slug" ] && continue
      id=$(planner_entity_get_id "$initiative_id" "ticket-${slug}" 2>/dev/null) || id=""
      if [ -n "$id" ]; then
        printf '%s%s\t%s\n' "$PLANNER_DRAFT_ID_PREFIX" "$slug" "$id"
      fi
    done < <(planner_ticketgen_slugs "$specs_dir")
  } | awk -F'\t' '{ printf "%d\t%s\n", length($1), $0 }' | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 | cut -f2-
}

# planner_draft_readiness_rewrite <map-file> <to-draft|to-real>
# stdin → stdout. Replaces whole tokens only: a match must not touch a
# letter, digit, `_` or `-` on either side, so `DRAFT` never matches inside
# `DRAFT-a`, nor `CRE-1` inside `CRE-10`. `to-draft` first unwraps Linear's
# links around an issue id — `[CRE-11](https://linear.app/…)` and a bare
# `https://linear.app/<ws>/issue/CRE-11[/<slug>]` both become `CRE-11` —
# because that is how Linear re-renders a mention. awk reads the map and
# the direction only through ENVIRON/files, never as program text.
planner_draft_readiness_rewrite() {
  local map="$1" dir="$2"
  case "$dir" in to-draft | to-real) ;; *)
    echo "planner-draft-readiness: rewrite direction must be to-draft or to-real" >&2
    return 1
    ;;
  esac
  [ -f "$map" ] || {
    echo "planner-draft-readiness: token map not found: $map" >&2
    return 1
  }
  PDR_DIR="$dir" awk -F'\t' '
    function bound(c) { return c == "" || c !~ /[A-Za-z0-9_-]/ }
    function swap(s, from, to,   out, i, pre, post) {
      out = ""
      while ((i = index(s, from)) > 0) {
        pre = substr(s, i - 1, 1); if (i == 1) pre = ""
        post = substr(s, i + length(from), 1)
        if (bound(pre) && bound(post)) { out = out substr(s, 1, i - 1) to }
        else { out = out substr(s, 1, i - 1 + length(from)) }
        s = substr(s, i + length(from))
      }
      return out s
    }
    function unlink(s,   out, m, inner) {
      out = ""
      while (match(s, /\[[A-Z][A-Z0-9]*-[0-9]+\]\(https?:\/\/linear\.app\/[^)]*\)/)) {
        inner = substr(s, RSTART + 1, RLENGTH)
        sub(/\].*/, "", inner)
        out = out substr(s, 1, RSTART - 1) inner
        s = substr(s, RSTART + RLENGTH)
      }
      s = out s; out = ""
      while (match(s, /https?:\/\/linear\.app\/[^ \t\/]+\/issue\/[A-Z][A-Z0-9]*-[0-9]+(\/[A-Za-z0-9_-]*)?/)) {
        m = substr(s, RSTART, RLENGTH)
        sub(/^https?:\/\/linear\.app\/[^\/]+\/issue\//, "", m)
        sub(/\/.*/, "", m)
        out = out substr(s, 1, RSTART - 1) m
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    NR == FNR { if (NF >= 2 && $1 != "" && $2 != "") { n++; d[n] = $1; r[n] = $2 } ; next }
    {
      line = $0
      if (ENVIRON["PDR_DIR"] == "to-draft") {
        line = unlink(line)
        for (k = 1; k <= n; k++) line = swap(line, r[k], d[k])
      } else {
        for (k = 1; k <= n; k++) line = swap(line, d[k], r[k])
      }
      print line
    }
  ' "$map" -
}

# planner_draft_readiness_equiv_text <map-file> <real|draft>
# stdin → the text both sides are compared on: a real body is rewritten
# to-draft first; then the Planner Context `**Generated:**` value becomes
# PLANNER_DRAFT_GENERATED_TOKEN; then body-baseline.sh's normalisation
# (CRLF → LF, trailing whitespace, trailing blank lines). Units can be fed
# through it one at a time to compare them "modulo ids" (S4).
planner_draft_readiness_equiv_text() {
  local map="$1" side="$2"
  _planner_refinement_source_baseline >/dev/null 2>&1 || {
    echo "planner-draft-readiness: body-baseline.sh not found (install ticket-auto-pipeline)" >&2
    return 1
  }
  case "$side" in
  real) tr -d '\r' | planner_draft_readiness_rewrite "$map" to-draft ;;
  draft) tr -d '\r' ;;
  *)
    echo "planner-draft-readiness: side must be real or draft" >&2
    return 1
    ;;
  esac | PDR_TOK="$PLANNER_DRAFT_GENERATED_TOKEN" awk '
    /^\*\*Generated:\*\*/ { print "**Generated:** " ENVIRON["PDR_TOK"]; next }
    { print }
  ' | _body_baseline_normalise
}

planner_draft_readiness_equiv_hash() {
  local map="$1" side="$2" f="$3" text sum
  [ -f "$f" ] || return 1
  text=$(planner_draft_readiness_equiv_text "$map" "$side" <"$f") || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$text" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
  fi
  [ -n "${sum:-}" ] || return 1
  echo "$sum"
}

# rc 0 when the real body and the draft body are the same text after the
# id/link/timestamp rewrite and normalisation; 1 when not; 2 when either
# hash cannot be computed.
planner_draft_readiness_equivalent() {
  local map="$1" real="$2" draft="$3" a b
  a=$(planner_draft_readiness_equiv_hash "$map" real "$real") || return 2
  b=$(planner_draft_readiness_equiv_hash "$map" draft "$draft") || return 2
  [ "$a" = "$b" ]
}
