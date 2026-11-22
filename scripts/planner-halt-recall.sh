#!/usr/bin/env bash
# planner-halt-recall.sh — measure recall for the 8 blocking prose Crosscheck
# codes on seeded defects (planner-halt-recall, M3 part c).
#
# Held-out design (delivery plan R2 O7): the operators in
# <corpus>/recall/ops.tsv + steps.tsv were derived only from findings F1–F60
# (rehearsal iterations 01–10; each row names its finding). They are applied
# to the final plans of iterations 11–15 — the `final` rows of
# <corpus>/MANIFEST.tsv (s11-final … s15-final: specs/ and consensus.md,
# scrubbed by scripts/corpus-scrub.sh) — never to the plans they came from.
#
# For every final plan the script builds a scratch REPOS_ROOT:
#   <root>/app/                              the sandbox repo at its base
#                                            (<corpus>/recall/repo/)
#   <root>/.ticket-auto/initiatives/INIT-0000000000-1000/artifacts/
#                                            specs/ and consensus.md
# runs the real check families (planner_crosscheck_citations, _propagation,
# _bypass, _contracts, _signals, _ac_coverage — the functions
# planner_crosscheck_run calls) on the unseeded plan (the control), then once
# per operator on a copy with the operator applied, counting units with the
# part (a) counter (PLANNER_CROSSCHECK_UNITS_FILE).
#
# A seeded case is:
#   caught    a finding of the operator's code that the control does not have
#   missed    none, and the code's check judged at least one unit
#   untested  the code's check judged 0 units on the seeded plan — untested
#             input, not a miss (planner-halt-recall spec)
#   n/a       the operator needs something this plan lacks (a shared
#             structure, a behaviour section, …); not counted
# A `control` operator seeds a near-defect that is NOT a defect; any new
# finding of its code is a false fire.
#
# Usage: scripts/planner-halt-recall.sh [options]
#   --corpus DIR   corpus root (default ticket-planner/lib/tests/corpus)
#   --out DIR      write cases.tsv, controls.tsv, results.tsv and table.md here
#                  (default: a temp dir, printed)
#   --check FILE   compare results.tsv with FILE (the committed
#                  <corpus>/recall/results.tsv); rc 1 and a diff on drift
#   --all          run all six families on every case and record which other
#                  codes newly fire (slower; the target family alone otherwise)
#   -j N           parallel cases (default: nproc)
#
# Recall per code: caught / (caught + missed), Wilson 95% interval. Cases are
# not independent (one operator on five plans), so the interval is optimistic.
# Ledger false fires come from ticket-planner/gates/gate-ledger.tsv.
#
# Read-only over the planner libs; writes only under its scratch dir and --out.
# Exit: 0 done (and --check matched); 1 --check drift or a run error; 2 usage.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
LIB="${REPO}/ticket-planner/lib"
LEDGER="${REPO}/ticket-planner/gates/gate-ledger.tsv"
SELF="${HERE}/$(basename "${BASH_SOURCE[0]}")"
INIT="INIT-0000000000-1000"
SIB="INIT-0000000000-9001"
SYNTH_MARKER='<!-- planner:testdata-synth v1 -->'

# code → check (units name) → family function
recall_codes() {
  cat <<'EOF'
RESOLUTION_NOT_PROPAGATED	resolution	planner_crosscheck_propagation
PRECEDENT_NOT_FOUND	precedent	planner_crosscheck_citations
FORWARD_REF_UNFULFILLED	forward-ref	planner_crosscheck_propagation
CONTRACT_MISMATCH	contract-mismatch	planner_crosscheck_contracts
CONTRACT_CONSUMERS_UNNOTIFIED	contract-consumers	planner_crosscheck_contracts
BYPASS_PATH_UNADDRESSED	bypass	planner_crosscheck_bypass
SIGNALS_UNIFORM	signals	planner_crosscheck_signals
AC_STATUS_UNCOVERED	ac-coverage	planner_crosscheck_ac_coverage
EOF
}
ALL_FAMILIES="planner_crosscheck_citations planner_crosscheck_propagation planner_crosscheck_bypass planner_crosscheck_contracts planner_crosscheck_signals planner_crosscheck_ac_coverage"

code_field() { recall_codes | awk -F'\t' -v c="$1" -v f="$2" '$1 == c { print $f }'; }

# ── one case (internal; run through xargs) ───────────────────────────────────

specs_of() { echo "$1/.ticket-auto/initiatives/${INIT}/artifacts/specs"; }

# Non-TD spec slugs, C-sorted.
plan_slugs() {
  local d f
  d=$(specs_of "$1")
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = INDEX.md ] && continue
    grep -qF -- "$SYNTH_MARKER" "$f" && continue
    basename "$f" .md
  done | LC_ALL=C sort
}

has_behaviour() { grep -qE '^## (Proposed Behaviour|Proposed Changes)[[:space:]]*$' "$1"; }

# Text of one `## <heading>` section (heading regex), fences kept.
section_text() {
  awk -v re="$2" '/^## / { on = ($0 ~ re); next } on { print }' "$1"
}

# Placeholder values for one plan, as KEY=VALUE lines (VALUE without newlines;
# SHARED_BLOCK has its newlines as \n).
plan_vars() {
  local root="$1" d slugs s
  d=$(specs_of "$root")
  mapfile -t slugs < <(plan_slugs "$root")
  echo "A=${slugs[0]:-}"
  echo "B=${slugs[1]:-}"
  echo "C=${slugs[2]:-}"
  for s in "${slugs[@]}"; do has_behaviour "$d/$s.md" && echo "BEH=$s" && break; done
  for s in "${slugs[@]}"; do
    case "$s" in *frontend* | *page* | *shell* | *editor*) has_behaviour "$d/$s.md" && echo "FE=$s" && break ;; esac
  done
  # SHARED: a code identifier that 2-3 plan specs backtick — a call
  # (`name()`) first, then camelCase, then snake/UPPER case, C order within
  # each. Chosen without the checker's own structure filter, so the filter is
  # measured, not assumed. Its owner is the spec that backticks it most (the
  # one that defines it, where a retirement would be written); the others are
  # its consumers.
  local tok n owner files
  while IFS= read -r tok; do
    mapfile -t files < <(for s in "${slugs[@]}"; do
      n=$(grep -oF "\`${tok}\`" "$d/$s.md" | wc -l)
      [ "$n" -gt 0 ] && printf '%s\t%s\n' "$n" "$s"
    done | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 | cut -f2)
    n=${#files[@]}
    if [ "$n" -ge 2 ] && [ "$n" -le 3 ]; then
      owner="${files[0]}"
      echo "SHARED=${tok}"
      echo "SHARED_BARE=${tok%()}"
      echo "SHARED_OWNER=${owner}"
      local cons=() c
      for c in "${files[@]:1}"; do cons+=("\`${c}\`"); done
      if [ "${#cons[@]}" -eq 1 ]; then echo "CONSUMERS=${cons[0]}"; else echo "CONSUMERS=${cons[0]} and ${cons[1]}"; fi
      local block
      block=$(awk 'BEGIN { RS = "" } index($0, T) { print; exit }' T="\`${tok}\`" \
        <(awk '/^[[:space:]]*(```|~~~)/ { f = !f; print ""; next } f { print ""; next } { print }' "$d/$owner.md"))
      printf 'SHARED_BLOCK=%s\n' "$(printf '%s' "$block" | awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')"
      break
    fi
  done < <(for s in "${slugs[@]}"; do
    awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } !f' "$d/$s.md" | grep -oE '`[^`]+`' | tr -d '`'
  done | grep -E '^[A-Za-z_][A-Za-z0-9_]*(\(\))?$' | grep -E '\(\)$|_|[a-z][A-Z]' | LC_ALL=C sort -u |
    awk '{ k = ($0 ~ /\(\)$/) ? 0 : (($0 ~ /[a-z][A-Z]/) ? 1 : 2); print k "\t" $0 }' | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 | cut -f2)
  # ACCODE: the first spec whose criteria and behaviour sections both name a
  # status code (any wording); CODE is the first such code in its criteria.
  local ac beh code
  for s in "${slugs[@]}"; do
    has_behaviour "$d/$s.md" || continue
    ac=$(section_text "$d/$s.md" '^## Acceptance Criteria[[:space:]]*$' | grep -oE '(^|[^0-9A-Za-z])[1-5][0-9][0-9]([^0-9A-Za-z]|$)' | grep -oE '[1-5][0-9][0-9]')
    beh=$(section_text "$d/$s.md" '^## (Proposed Behaviour|Proposed Changes|Technical Context)[[:space:]]*$')
    for code in $ac; do
      if grep -qE "(^|[^0-9A-Za-z])${code}([^0-9A-Za-z]|$)" <<<"$beh"; then
        echo "ACCODE=$s"
        echo "CODE=$code"
        break 2
      fi
    done
  done
}

var() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$VARS_FILE"; }

# Substitute {KEY} placeholders; \n → newline. rc 1 when a used key is empty.
# With --re, values are escaped for an ERE (a locus is a regex).
subst() {
  local re=0
  [ "$1" = "--re" ] && re=1 && shift
  local text="$1" key val
  for key in A B C SHARED SHARED_BARE SHARED_OWNER CONSUMERS SHARED_BLOCK CODE; do
    case "$text" in *"{${key}}"*)
      val=$(var "$key")
      [ -n "$val" ] || return 1
      [ "$re" -eq 1 ] && val=$(printf '%s' "$val" | sed -e 's/[][\\.*^$+?(){}|/]/\\&/g')
      text="${text//\{${key}\}/${val}}"
      ;;
    esac
  done
  printf '%s' "${text//\\n/$'\n'}"
}

# Insert a paragraph at the end of a section (before the next `## `).
insert_para() {
  local file="$1" re="$2" text="$3" tmp
  grep -qE "$re" "$file" || return 1
  tmp=$(mktemp)
  TEXT="$text" awk -v re="$re" '
    function flush() { if (on) { print ENVIRON["TEXT"]; print ""; on = 0; done = 1 } }
    /^## / { if (on) flush(); if (!done && $0 ~ re) on = 1; print; next }
    { print }
    END { if (on) { print ""; print ENVIRON["TEXT"] } }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

signals_json() { awk '/^## Signals/ { s = 1 } s && /^```json/ { j = 1; next } j && /^```/ { exit } j { print }' "$1"; }

signals_replace() {
  local file="$1" json="$2" tmp
  tmp=$(mktemp)
  JSON="$json" awk '/^## Signals/ { s = 1 } s && !d && /^```json/ { print; print ENVIRON["JSON"]; j = 1; next } j && /^```/ { j = 0; d = 1; print; next } j { next } { print }' "$file" >"$tmp" && mv "$tmp" "$file"
}

apply_step() {
  local root="$1" action="$2" sel="$3" arg="$4" text="$5" d file re slug src dst mode a b out
  d=$(specs_of "$root")
  text=$(subst "$text") || return 2
  case "$action" in
  insert)
    slug=$(var "$sel")
    [ -n "$slug" ] || return 2
    file="$d/$slug.md"
    case "$arg" in
    tc) re='^## Technical Context[[:space:]]*$' ;;
    beh) re='^## (Proposed Behaviour|Proposed Changes)[[:space:]]*$' ;;
    *) return 1 ;;
    esac
    insert_para "$file" "$re" "$text" || return 2
    ;;
  consensus)
    printf '\n%s\n' "$text" >>"$(dirname "$d")/consensus.md"
    ;;
  repo)
    mkdir -p "$(dirname "$root/$arg")"
    printf '%s\n' "$text" >"$root/$arg"
    ;;
  sibling)
    out="$root/.ticket-auto/initiatives/${SIB}/artifacts/specs"
    mkdir -p "$out"
    printf '# %s\n\n## Technical Context\n\n%s\n' "$arg" "$text" >"$out/$arg.md"
    ;;
  signals)
    src="$d/$(var "$sel").md"
    dst="$d/$(var "${arg%%:*}").md"
    mode="${arg#*:}"
    a=$(signals_json "$src")
    b=$(signals_json "$dst")
    { [ -n "$a" ] && [ -n "$b" ]; } || return 2
    case "$mode" in
    full) out="$a" ;;
    key) out=$(jq -n --argjson a "$a" --argjson b "$b" '$b + ($a | {services_identified, symbols_resolved, prior_art_found, TargetSymbols})') || return 2 ;;
    counts) out=$(jq -n --argjson a "$a" --argjson b "$b" '$b + ($a | {services_identified, symbols_resolved, prior_art_found})') || return 2 ;;
    rename) out=$(jq --arg s "$(echo "$a" | jq -r '.TargetSymbols // ""')" '.TargetSymbols = ($s | sub("^(?<n>[A-Za-z_][A-Za-z0-9_]*)"; "\(.n)Copy"))' <<<"$a") || return 2 ;;
    *) return 1 ;;
    esac
    signals_replace "$dst" "$out"
    ;;
  drop-ac)
    slug=$(var "$sel")
    local code
    code=$(var CODE)
    { [ -n "$slug" ] && [ -n "$code" ]; } || return 2
    file="$d/$slug.md"
    out=$(mktemp)
    awk -v c="$code" '
      /^## / { on = ($0 ~ /^## Acceptance Criteria[[:space:]]*$/); print; next }
      on && match($0, "(^|[^0-9A-Za-z])" c "([^0-9A-Za-z]|$)") { next }
      { print }
    ' "$file" >"$out" && mv "$out" "$file"
    ;;
  *) return 1 ;;
  esac
  return 0
}

# run_families <root> <units_file> <family...> — finding lines, root → ROOT.
run_families() {
  local root="$1" units="$2" fam
  shift 2
  (
    export REPOS_ROOT="$root"
    # shellcheck source=/dev/null
    source "${LIB}/planner-crosscheck.sh"
    PLANNER_CROSSCHECK_UNITS_FILE="$units"
    for fam in "$@"; do
      "$fam" "$INIT" 2>/dev/null
    done
  ) | grep -E '^planner-[a-z-]+: [A-Z_]+ ' | sed "s#${root}#ROOT#g" | LC_ALL=C sort
}

units_sum() { awk -F'\t' -v c="$2" '$1 == c { s += $2; n = 1 } END { print (n ? s : 0) }' "$1" 2>/dev/null; }

one_case() {
  local target="$1" op="$2" code check family form locus root units findings status uc ucase new hit other rc=0
  code=$(awk -F'\t' -v o="$op" 'NR > 1 && $1 == o { print $2 }' "$RECALL/ops.tsv")
  form=$(awk -F'\t' -v o="$op" 'NR > 1 && $1 == o { print $3 }' "$RECALL/ops.tsv")
  locus=$(awk -F'\t' -v o="$op" 'NR > 1 && $1 == o { print $4 }' "$RECALL/ops.tsv")
  check=$(code_field "$code" 2)
  family=$(code_field "$code" 3)
  root="$W/case/${target}.${op}"
  rm -rf "$root"
  cp -a "$W/base/$target" "$root"
  VARS_FILE="$W/base/${target}.vars"
  local action sel arg text
  while IFS=$'\t' read -r _ action sel arg text; do
    apply_step "$root" "$action" "$sel" "$arg" "$text"
    rc=$?
    [ "$rc" -eq 0 ] || break
  done < <(awk -F'\t' -v o="$op" 'NR > 1 && $1 == o' "$RECALL/steps.tsv")
  uc=$(units_sum "$W/base/${target}.units" "$check")
  if [ "$rc" -eq 2 ]; then
    printf '%s\t%s\t%s\t%s\tn/a\t%s\t%s\t-\t0\t0\t-\n' "$target" "$op" "$code" "$form" "$check" "$uc" >"$W/res/${target}.${op}"
    rm -rf "$root"
    return 0
  fi
  [ "$rc" -eq 0 ] || {
    echo "planner-halt-recall: step failed: $target $op" >&2
    return 1
  }
  units="$root.units"
  : >"$units"
  if [ -n "${RECALL_ALL:-}" ]; then
    # shellcheck disable=SC2086
    findings=$(run_families "$root" "$units" $ALL_FAMILIES)
  else
    findings=$(run_families "$root" "$units" "$family")
  fi
  ucase=$(units_sum "$units" "$check")
  # New = not in the control. A caught finding names the operator's locus;
  # any other new finding of the code is collateral (fired, but not on the
  # seeded defect).
  LC_ALL=C comm -13 "$W/base/${target}.findings" <(printf '%s\n' "$findings" | sed '/^$/d') >"$W/new/${target}.${op}"
  new=$(grep -cE "^planner-[a-z-]+: ${code} " "$W/new/${target}.${op}")
  hit=0
  if [ "$locus" != "-" ] && locus=$(subst --re "$locus"); then
    hit=$(grep -E "^planner-[a-z-]+: ${code} " "$W/new/${target}.${op}" | grep -ciE -- "$locus")
  fi
  other="-"
  if [ -n "${RECALL_ALL:-}" ]; then
    other=$(awk '{ print $2 }' "$W/new/${target}.${op}" | grep -vx "$code" | LC_ALL=C sort -u | paste -sd, -)
    [ -n "$other" ] || other="-"
  fi
  if [ "$form" = control ]; then
    if [ "$new" -gt 0 ]; then status=false-fire; elif [ "$ucase" -eq 0 ]; then status=untested; else status=clean; fi
  elif [ "$hit" -gt 0 ]; then
    status=caught
  elif [ "$ucase" -eq 0 ]; then
    status=untested
  else
    status=missed
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$target" "$op" "$code" "$form" "$status" "$check" "$uc" "$ucase" "$hit" "$((new - hit))" "$other" >"$W/res/${target}.${op}"
  rm -rf "$root"
}

if [ "${1:-}" = "--one" ]; then
  one_case "$2" "$3"
  exit $?
fi

# ── main ─────────────────────────────────────────────────────────────────────

CORPUS="${REPO}/ticket-planner/lib/tests/corpus"
OUT=""
CHECK=""
JOBS=$(nproc 2>/dev/null || echo 4)
RECALL_ALL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --corpus)
    CORPUS="$2"
    shift 2
    ;;
  --out)
    OUT="$2"
    shift 2
    ;;
  --check)
    CHECK="$2"
    shift 2
    ;;
  --all)
    RECALL_ALL=1
    shift
    ;;
  -j)
    JOBS="$2"
    shift 2
    ;;
  *)
    echo "usage: planner-halt-recall.sh [--corpus DIR] [--out DIR] [--check FILE] [--all] [-j N]" >&2
    exit 2
    ;;
  esac
done
CORPUS=$(cd "$CORPUS" && pwd) || exit 2
RECALL="${CORPUS}/recall"
[ -f "$RECALL/ops.tsv" ] && [ -f "$RECALL/steps.tsv" ] || {
  echo "planner-halt-recall: no ops.tsv/steps.tsv under $RECALL" >&2
  exit 2
}
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
[ -n "$OUT" ] || OUT=$(mktemp -d)
mkdir -p "$OUT" "$W/base" "$W/case" "$W/res" "$W/new"
export W RECALL RECALL_ALL

mapfile -t TARGETS < <(awk -F'\t' 'NR > 1 && $3 == "final" { print $1 }' "$CORPUS/MANIFEST.tsv")
[ "${#TARGETS[@]}" -gt 0 ] || {
  echo "planner-halt-recall: no final snapshot in MANIFEST.tsv" >&2
  exit 2
}

# Controls: the unseeded final plans, all six families.
: >"$OUT/controls.tsv"
for t in "${TARGETS[@]}"; do
  root="$W/base/$t"
  mkdir -p "$root/.ticket-auto/initiatives/${INIT}/artifacts"
  cp -r "$CORPUS/$t/specs" "$root/.ticket-auto/initiatives/${INIT}/artifacts/specs"
  cp "$CORPUS/$t/consensus.md" "$root/.ticket-auto/initiatives/${INIT}/artifacts/consensus.md"
  cp -r "$RECALL/repo/." "$root/"
  : >"$W/base/$t.units"
  # shellcheck disable=SC2086
  run_families "$root" "$W/base/$t.units" $ALL_FAMILIES >"$W/base/$t.findings.raw"
  # The control's own findings, with this root's path; cases compare against
  # the same text with their own root rewritten to ROOT.
  cp "$W/base/$t.findings.raw" "$W/base/$t.findings"
  VARS_FILE="$W/base/$t.vars"
  plan_vars "$root" >"$VARS_FILE"
  while IFS=$'\t' read -r code check _; do
    printf '%s\t%s\t%s\t%s\n' "$t" "$code" "$(grep -cE "^planner-[a-z-]+: ${code} " "$W/base/$t.findings")" "$(units_sum "$W/base/$t.units" "$check")" >>"$OUT/controls.tsv"
  done < <(recall_codes)
done

# Seeded cases.
ops=$(awk -F'\t' 'NR > 1 { print $1 }' "$RECALL/ops.tsv")
for t in "${TARGETS[@]}"; do
  for op in $ops; do printf '%s %s\n' "$t" "$op"; done
done | xargs -P "$JOBS" -n 2 bash "$SELF" --one || {
  echo "planner-halt-recall: a case failed" >&2
  exit 1
}

{
  printf 'target\top\tcode\tform\tstatus\tcheck\tunits_control\tunits_case\tcaught_findings\tcollateral_findings\tother_new_codes\n'
  cat "$W/res/"* | LC_ALL=C sort -t$'\t' -k3,3 -k2,2 -k1,1
} >"$OUT/cases.tsv"
# Every case's new findings and every plan's placeholder values, to read.
rm -rf "$OUT/new" "$OUT/vars"
mkdir -p "$OUT/new" "$OUT/vars"
cp "$W/new/"* "$OUT/new/" 2>/dev/null
for t in "${TARGETS[@]}"; do
  cp "$W/base/$t.vars" "$OUT/vars/$t.vars"
  cp "$W/base/$t.findings" "$OUT/vars/$t.control-findings"
done

# results.tsv — what the replay test pins: every case's status and units, and
# every control's fires and units. other_new_codes is left out (--all only).
{
  printf '# planner-halt-recall results — regenerate: scripts/planner-halt-recall.sh --out <dir>, copy results.tsv\n'
  printf 'kind\ttarget\top\tcode\tstatus\tunits\n'
  awk -F'\t' 'NR > 1 { print "case\t" $1 "\t" $2 "\t" $3 "\t" $5 "\t" $8 }' "$OUT/cases.tsv"
  awk -F'\t' '{ print "control\t" $1 "\t-\t" $2 "\t" $3 "\t" $4 }' "$OUT/controls.tsv"
} >"$OUT/results.tsv"

# table.md — one row per code.
wilson() {
  awk -v k="$1" -v n="$2" 'BEGIN {
    if (n == 0) { print "—"; exit }
    z = 1.96; p = k / n; d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    lo = c - h; hi = c + h; if (lo < 0) lo = 0; if (hi > 1) hi = 1
    printf "%.2f [%.2f, %.2f]", p, lo, hi
  }'
}
ledger_false() {
  [ -f "$LEDGER" ] || {
    echo "?"
    return
  }
  awk -F'\t' -v c="$1" '!/^#/ && $4 == c && $9 == "false" { s += $8 } END { print s + 0 }' "$LEDGER"
}
{
  printf '| Code | Seeded (applied) | Caught | Missed | Untested | n/a | Recall, judged cases [Wilson 95%%] | Recall, untested counted as missed [Wilson 95%%] | Canonical caught/applied | Natural caught/applied | Collateral fires in seeded cases | Control false fires (unseeded / seeded controls) | Ledger false fires |\n'
  printf '|---|---|---|---|---|---|---|---|---|---|---|---|---|\n'
  while IFS=$'\t' read -r code _; do
    read -r applied caught missed untested na cc cj nc nj coll < <(awk -F'\t' -v c="$code" '
      NR > 1 && $3 == c && $4 != "control" {
        if ($5 == "n/a") { na++; next }
        ap++
        co += $10
        if ($5 == "caught") ca++
        if ($5 == "missed") mi++
        if ($5 == "untested") un++
        if ($4 == "canonical") { cj++; if ($5 == "caught") cc++ }
        if ($4 == "natural") { nj++; if ($5 == "caught") nc++ }
      }
      END { print ap + 0, ca + 0, mi + 0, un + 0, na + 0, cc + 0, cj + 0, nc + 0, nj + 0, co + 0 }' "$OUT/cases.tsv")
    ctl=$(awk -F'\t' -v c="$code" '$2 == c { s += $3 } END { print s + 0 }' "$OUT/controls.tsv")
    sctl=$(awk -F'\t' -v c="$code" 'NR > 1 && $3 == c && $4 == "control" { n++; if ($5 == "false-fire") f++ } END { if (n) print f + 0 "/" n; else print "-" }' "$OUT/cases.tsv")
    printf '| `%s` | %s | %s | %s | %s | %s | %s | %s | %s/%s | %s/%s | %s | %s / %s | %s |\n' \
      "$code" "$applied" "$caught" "$missed" "$untested" "$na" "$(wilson "$caught" $((caught + missed)))" \
      "$(wilson "$caught" "$applied")" "$cc" "$cj" "$nc" "$nj" "$coll" "$ctl" "$sctl" "$(ledger_false "$code")"
  done < <(recall_codes)
} >"$OUT/table.md"

cat "$OUT/table.md"
echo "planner-halt-recall: wrote ${OUT}/{cases,controls,results}.tsv and table.md"

if [ -n "$CHECK" ]; then
  if diff <(grep -v '^#' "$CHECK") <(grep -v '^#' "$OUT/results.tsv") >"$W/drift"; then
    echo "planner-halt-recall: results match $CHECK"
  else
    echo "planner-halt-recall: results drifted from $CHECK (< committed, > now):" >&2
    cat "$W/drift" >&2
    exit 1
  fi
fi
exit 0
