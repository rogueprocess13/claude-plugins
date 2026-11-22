#!/usr/bin/env bash
# test-planner-halt-recall.sh — replays the recall measurement for the 8
# blocking prose Crosscheck codes (planner-halt-recall, M3 part c).
#
#   - the held-out design holds: every operator in corpus/recall/ops.tsv names
#     only findings F1–F60 (iterations 01–10), every target snapshot is an
#     iteration 11–15 final plan, and every operator targets one of the 8 codes
#   - every operator has at least one step, every step an action the runner
#     knows, every code at least one non-control operator
#   - scripts/planner-halt-recall.sh, run over the corpus, reproduces
#     corpus/recall/results.tsv exactly: every seeded case's status
#     (caught/missed/untested/n/a, or clean/false-fire for a control) and the
#     units its check judged, and every unseeded control's fires and units.
#     A checker change that moves recall fails here until the pin is
#     regenerated on purpose:
#       scripts/planner-halt-recall.sh --out <dir>
#       cp <dir>/results.tsv ticket-planner/lib/tests/corpus/recall/results.tsv
#   - an untested case judged 0 units, and a caught one more than 0
#
# Read-only over the planner libs. Takes about two minutes (about 230 runs).
#
# Run: bash ticket-planner/lib/tests/test-planner-halt-recall.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CORPUS="${SCRIPT_DIR}/corpus"
RECALL="${CORPUS}/recall"
RUNNER="${REPO_ROOT}/scripts/planner-halt-recall.sh"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}
check() { # check <name> <problems-text>
  if [ -z "$2" ]; then pass "$1"; else fail "$1" "$(head -10 <<<"$2")"; fi
}

CODES="RESOLUTION_NOT_PROPAGATED PRECEDENT_NOT_FOUND FORWARD_REF_UNFULFILLED CONTRACT_MISMATCH CONTRACT_CONSUMERS_UNNOTIFIED BYPASS_PATH_UNADDRESSED SIGNALS_UNIFORM AC_STATUS_UNCOVERED"

echo "--- held-out design ---"
check "every operator names only findings F1-F60" "$(awk -F'\t' 'NR > 1 {
  n = split($5, f, " ")
  if (n == 0) print $1 " names no finding"
  for (i = 1; i <= n; i++) {
    if (f[i] !~ /^F[0-9]+$/ || substr(f[i], 2) + 0 < 1 || substr(f[i], 2) + 0 > 60) print $1 " " f[i]
  }
}' "$RECALL/ops.tsv")"
check "every target snapshot is an iteration 11-15 final plan" "$(awk -F'\t' 'NR > 1 && $3 == "final" {
  if ($2 !~ /^1[1-5]$/ || $1 != "s" $2 "-final") print $1 " iter " $2
}' "$CORPUS/MANIFEST.tsv")"
targets=$(awk -F'\t' 'NR > 1 && $3 == "final"' "$CORPUS/MANIFEST.tsv" | wc -l)
[ "$targets" -eq 5 ] && pass "five final plans" || fail "five final plans" "$targets"
check "every target has specs/ and consensus.md" "$(awk -F'\t' 'NR > 1 && $3 == "final" { print $1 }' "$CORPUS/MANIFEST.tsv" |
  while read -r t; do
    [ -d "$CORPUS/$t/specs" ] && [ -f "$CORPUS/$t/consensus.md" ] || echo "$t"
  done)"
check "every operator targets one of the 8 codes, with a known form" "$(awk -F'\t' -v codes="$CODES" 'NR > 1 {
  if ((" " codes " ") !~ (" " $2 " ")) print $1 " " $2
  if ($3 !~ /^(canonical|natural|control)$/) print $1 " form " $3
}' "$RECALL/ops.tsv")"
check "every code has a seeded operator" "$(for c in $CODES; do
  awk -F'\t' -v c="$c" 'NR > 1 && $2 == c && $3 != "control" { f = 1 } END { exit !f }' "$RECALL/ops.tsv" || echo "$c"
done)"
check "every operator has steps, every step a known action" "$(
  awk -F'\t' 'NR > 1 { print $1 }' "$RECALL/ops.tsv" | while read -r o; do
    awk -F'\t' -v o="$o" 'NR > 1 && $1 == o { f = 1 } END { exit !f }' "$RECALL/steps.tsv" || echo "$o no steps"
  done
  awk -F'\t' 'NR > 1 && $2 !~ /^(insert|consensus|repo|sibling|signals|drop-ac)$/ { print $1 " " $2 }' "$RECALL/steps.tsv"
)"

echo "--- replay ---"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
if bash "$RUNNER" -j 4 --out "$OUT" --check "$RECALL/results.tsv" >"$OUT/log" 2>&1; then
  pass "planner-halt-recall.sh reproduces corpus/recall/results.tsv"
else
  fail "planner-halt-recall.sh reproduces corpus/recall/results.tsv" "$(tail -20 "$OUT/log")"
fi
if [ -f "$OUT/cases.tsv" ]; then
  check "an untested case judged 0 units, a caught one more than 0" "$(awk -F'\t' 'NR > 1 {
    if ($5 == "untested" && $8 != 0) print $1 " " $2 " untested with " $8 " units"
    if ($5 == "caught" && $8 == 0) print $1 " " $2 " caught with 0 units"
  }' "$OUT/cases.tsv")"
  check "the table has one row per code" "$(for c in $CODES; do grep -q "\`$c\`" "$OUT/table.md" || echo "$c"; done)"
else
  fail "cases.tsv written" "no output"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
