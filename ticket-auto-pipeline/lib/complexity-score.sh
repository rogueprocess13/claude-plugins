#!/usr/bin/env bash
# complexity-score.sh — the deterministic half of ticket-appraise's complexity
# scoring (review finding DET-AP-5). The agent judges which axes fire; this
# script does the arithmetic, the threshold and the `## Complexity` block.
#
# Usage:
#   complexity-score.sh write <ticket-dir> --axes <list> --reason <sentence>
#   complexity-score.sh blast <ticket-dir>
#   complexity-score.sh summary <ticket-dir> [sweep|final]
#
# write: <list> is comma-separated, or `none`. Axes (SKILL.md Step 2.5 rubric):
#   multi-service (2), cross-layer (2), cross-layer:framework-migration (3),
#   reversibility[:<trigger>] (3), prior-rejection (3).
#   One auth trigger weighs less (issue #762): reversibility:auth-reuse (0)
#   only applies an unchanged check to new endpoints; the 0 is recorded, not
#   scored. Every other trigger weighs 3: auth-modify, a bare `auth`, and
#   auth-new (new auth logic nothing existing depends on), which is recorded
#   as its own kind but always reaches the human approve gate. An
#   unrecognised spelling can only over-score.
#   Any other axis or qualifier, a repeated axis, or `none` with another axis
#   exits 2 — cross-layer qualified with anything but framework-migration is
#   the double-count rule (migrations and payment paths are Reversibility).
#   Writes or replaces the section as heading + Score/Weighted score/Axes
#   fired/Reason, the shape get_complexity (notes-parse.sh) reads.
#   Prints COMPLEXITY=, WEIGHTED=, AXES= (the plog message parts).
# blast: Step 2.8 write-back. Runs get_blast_radius_override; on `complex`
#   adds blast-radius:3 and 3 to the weighted score (`n/a` counts as 0),
#   escalates a simple Score and appends the reason. A BLAST_ADDITIVE_SKIP adds
#   the `**blast-radius:** additive` line. Idempotent. No `## Blast Radius`
#   section, or BLAST_OVERRIDE=none with no skip, leaves the file untouched.
#   Prints the parser's three lines plus COMPLEXITY= and WEIGHTED=.
# summary: the one formatter of the score for a pipeline-log message (issue
#   #769). Reads the `## Complexity` block and prints one line, no pipe:
#     sweep: complex, score 3 (threshold 3, blast radius not yet applied), axes: reversibility:3 (auth-modify)
#     final: complex, score 6 = sweep 3 + blast-radius 3 (threshold 3), axes: reversibility:3 (auth-modify), blast-radius:3
#   `sweep` (default) is the Step 2.5 sum alone, for `complexity-sweep|done`;
#   `final` is that sum plus the Step 2.8 blast-radius axis, for
#   `appraise|done` (phase_terminal_write, spawn-helper.sh). 3 is the
#   threshold, never a maximum. A fast-path `n/a` score prints as `n/a`.
#   Exit 3 when the block has no Score yet (nothing printed).
# Exit codes: 0 ok, 2 usage / refused axes, 3 no score, 12 notes.md missing.
set -eo pipefail

_CS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_cs_usage() {
  sed -n '6,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
_cs_die() {
  echo "complexity-score: $2" >&2
  exit "$1"
}

# _cs_replace <notes> <block-file>: replace the first `## Complexity` section
# (up to the next `## ` heading) with the block, or append it. tmp + mv.
_cs_replace() {
  local tmp="$1.cs.$$"
  awk -v bf="$2" '
    function emit(  l) { while ((getline l < bf) > 0) print l; close(bf); done = 1 }
    /^## Complexity[ \t\r]*$/ && !done { emit(); skip = 1; next }
    skip && /^## / { skip = 0; print ""; }
    !skip { print }
    END { if (!done) { print ""; emit() } }
  ' "$1" >"$tmp" && mv "$tmp" "$1"
}

# _cs_field <section-text> <key>: value of `**<key>:** value`.
_cs_field() { sed -n "s/^\*\*$2:\*\* \{0,1\}//p" <<<"$1" | head -1 | tr -d '\r'; }

cmd="${1:-}"
td="${2:-}"
[ -n "$cmd" ] && [ -n "$td" ] || _cs_usage
shift 2
notes="$td/notes.md"
block="$notes.block.$$"
trap 'rm -f "$block"' EXIT

case "$cmd" in
write)
  axes="" reason="" have_axes=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --axes)
      [ $# -ge 2 ] || _cs_usage
      axes="$2"
      have_axes=1
      shift 2
      ;;
    --reason)
      [ $# -ge 2 ] || _cs_usage
      reason="$2"
      shift 2
      ;;
    *) _cs_usage ;;
    esac
  done
  [ "$have_axes" = 1 ] && [ -n "$reason" ] || _cs_usage
  [ -f "$notes" ] || _cs_die 12 "notes.md not found: $notes"
  total=0 rendered="" seen=" " n=0
  IFS=',' read -ra items <<<"$axes"
  for raw in "${items[@]}"; do
    item=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$raw")
    [ -n "$item" ] || continue
    n=$((n + 1))
    name="${item%%:*}" qual=""
    [ "$name" = "$item" ] || qual="${item#*:}"
    case "$name:$qual" in
    none:) w=0 r="" ;;
    multi-service:) w=2 r="multi-service:2" ;;
    cross-layer:) w=2 r="cross-layer:2" ;;
    cross-layer:framework-migration) w=3 r="cross-layer (framework-migration):3" ;;
    cross-layer:*) _cs_die 2 "cross-layer:$qual refused — migrations and payment paths fire reversibility only (no double-counting)" ;;
    reversibility:) w=3 r="reversibility:3" ;;
    reversibility:auth-reuse) w=0 r="reversibility:0 (auth-reuse)" ;;
    reversibility:*) w=3 r="reversibility:3 ($qual)" ;;
    prior-rejection:) w=3 r="prior-rejection:3" ;;
    *) _cs_die 2 "unknown axis: $item" ;;
    esac
    case "$seen" in *" $name "*) _cs_die 2 "axis listed twice: $name" ;; esac
    seen="$seen$name "
    total=$((total + w))
    [ -z "$r" ] || rendered="${rendered:+$rendered, }$r"
  done
  case "$seen" in *" none "*) [ "$n" -eq 1 ] || _cs_die 2 "none cannot be combined with another axis" ;; esac
  [ -n "$rendered" ] || rendered="none"
  score=simple
  [ "$total" -lt 3 ] || score=complex
  printf '## Complexity\n**Score:** %s\n**Weighted score:** %s (threshold 3)\n**Axes fired:** %s\n**Reason:** %s\n' \
    "$score" "$total" "$rendered" "$reason" >"$block"
  _cs_replace "$notes" "$block"
  printf 'COMPLEXITY=%s\nWEIGHTED=%s\nAXES=%q\n' "$score" "$total" "$rendered"
  ;;
blast)
  [ $# -eq 0 ] || _cs_usage
  [ -f "$notes" ] || _cs_die 12 "notes.md not found: $notes"
  BLAST_OVERRIDE=none BLAST_REASON="" BLAST_ADDITIVE_SKIP=""
  rc=0
  out=$(bash -c 'source "$1/notes-parse.sh"; get_blast_radius_override "$2"' _ "$_CS_DIR" "$td") || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || _cs_die "$rc" "get_blast_radius_override failed"
  [ "$rc" -ne 0 ] || eval "$out"
  printf 'BLAST_OVERRIDE=%s\nBLAST_REASON=%q\nBLAST_ADDITIVE_SKIP=%q\n' "$BLAST_OVERRIDE" "$BLAST_REASON" "$BLAST_ADDITIVE_SKIP"
  section=$(awk '/^## Complexity[ \t\r]*$/ && !s { s = 1; next } s && /^## / { exit } s' "$notes")
  score=$(_cs_field "$section" Score)
  weighted=$(_cs_field "$section" 'Weighted score')
  axes=$(_cs_field "$section" 'Axes fired')
  reason=$(_cs_field "$section" Reason)
  extras=$(grep -v -e '^\*\*Score:\*\*' -e '^\*\*Weighted score:\*\*' -e '^\*\*Axes fired:\*\*' \
    -e '^\*\*Reason:\*\*' -e '^[[:space:]]*$' <<<"$section" || true)
  changed=0
  if [ "$BLAST_OVERRIDE" = complex ] && ! grep -q 'blast-radius:3' <<<"$axes"; then
    n=0
    [[ "$weighted" =~ ^([0-9]+) ]] && n="${BASH_REMATCH[1]}"
    weighted="$((n + 3)) (threshold 3)"
    case "$score" in complex*) ;; *) score="complex (escalated from simple — blast radius: $BLAST_REASON)" ;; esac
    axes="${axes:+$axes, }blast-radius:3"
    reason="${reason:+$reason }Blast radius: $BLAST_REASON."
    changed=1
  fi
  if [ -n "$BLAST_ADDITIVE_SKIP" ] && ! grep -q '^\*\*blast-radius:\*\* additive' <<<"$extras"; then
    extras="${extras:+$extras$'\n'}**blast-radius:** additive — caller-count override skipped ($BLAST_ADDITIVE_SKIP)"
    changed=1
  fi
  if [ "$changed" = 1 ]; then
    {
      printf '## Complexity\n**Score:** %s\n**Weighted score:** %s\n**Axes fired:** %s\n**Reason:** %s\n' \
        "$score" "$weighted" "$axes" "$reason"
      [ -z "$extras" ] || printf '%s\n' "$extras"
    } >"$block"
    _cs_replace "$notes" "$block"
  fi
  printf 'COMPLEXITY=%s\nWEIGHTED=%s\n' "${score%% *}" "${weighted%% *}"
  ;;
summary)
  stage="${1:-sweep}"
  [ $# -le 1 ] || _cs_usage
  case "$stage" in sweep | final) ;; *) _cs_usage ;; esac
  [ -f "$notes" ] || _cs_die 12 "notes.md not found: $notes"
  section=$(awk '/^## Complexity[ \t\r]*$/ && !s { s = 1; next } s && /^## / { exit } s' "$notes")
  score=$(_cs_field "$section" Score)
  score="${score%% *}"
  case "$score" in simple | complex) ;; *) _cs_die 3 "no complexity score in $notes" ;; esac
  weighted=$(_cs_field "$section" 'Weighted score')
  axes=$(_cs_field "$section" 'Axes fired')
  blast=0
  ! grep -q 'blast-radius:3' <<<"$axes" || blast=3
  total="n/a" base="n/a"
  if [[ "$weighted" =~ ^([0-9]+) ]]; then
    total="${BASH_REMATCH[1]}"
    base=$((total - blast))
    [ "$base" -ge 0 ] || base=0
  fi
  if [ "$stage" = sweep ]; then
    # The sweep's own verdict: a blast escalation is not part of it.
    if [ "$base" != "n/a" ]; then
      score=simple
      [ "$base" -lt 3 ] || score=complex
    fi
    axes=$(sed 's/, blast-radius:3//; s/^blast-radius:3$//' <<<"$axes")
    msg="sweep: $score, score $base (threshold 3, blast radius not yet applied), axes: ${axes:-none}"
  elif [ "$total" = "n/a" ]; then
    msg="final: $score, score n/a (threshold 3), axes: ${axes:-none}"
  else
    msg="final: $score, score $total = sweep $base + blast-radius $blast (threshold 3), axes: ${axes:-none}"
  fi
  printf '%s\n' "${msg//|//}"
  ;;
*) _cs_usage ;;
esac
