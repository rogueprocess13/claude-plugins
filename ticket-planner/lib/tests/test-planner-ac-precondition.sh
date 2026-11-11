#!/usr/bin/env bash
# test-planner-ac-precondition.sh — Tests for planner-ac-precondition.sh
# (planner-ac-code-precondition, tasks 1.2–1.3).
#
# Pinned here:
#   1. The `## Preconditions` table parse: well-formed table, `None.`,
#      missing and empty sections, a second table, fences, `\|` in a cell,
#      CRLF, header and shape.
#   2. Criterion, Key, Mode, Requires and Basis grammar; duplicate tuples.
#   3. Basis rules: `code:` path grammar; `spec:<slug>` unknown, synth-marked,
#      self with and without a Writes row, another spec that is or is not a
#      dependency, one with no Writes row.
#   4. Synth-marked specs and INDEX.md are skipped; the contract marker.
#   5. mawk runs every awk program, and gawk (when installed) agrees.
#
# Every case is guarded on the functions it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary, never an
# unbound-function abort.
#
# Run: bash ticket-planner/lib/tests/test-planner-ac-precondition.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ACP_LIB="${LIB_DIR}/planner-ac-precondition.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"

source "${LIB_DIR}/planner-state.sh"
if [ -f "$ACP_LIB" ]; then
  source "$ACP_LIB"
fi

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
need() {
  local name="$1" fn
  shift
  for fn in "$@"; do
    if ! declare -f "$fn" >/dev/null; then
      fail "$name" "$fn missing"
      return 1
    fi
  done
  return 0
}
# check <name> <got> <want>
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}

TAB=$'\t'
N=0
fresh() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((7000 + N))"
  planner_state_init "$INIT" "invoice follow-up" >/dev/null
  IDIR=$(planner_initiative_dir "$INIT")
  SPECS="${IDIR}/artifacts/specs"
  mkdir -p "$SPECS"
}

AC1='An invoice with no due date is listed on the Needs date page.'
AC2='Saving the invoice form without a customer shows "Customer is required".'
AC3='A disputed invoice shows a Disputed badge on the list.'
AC4='The note a | b renders as text.'
PH='| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|'

# mkspec <slug> <preconditions-body|__NONE__> [<writes-body>] [<labels>] —
# write a spec, print its path. The AC list holds AC1..AC4 (AC3 with a
# doubled space, AC4 with a raw pipe).
mkspec() {
  local slug="$1" pre="$2" writes="${3:-}" labels="${4:-type:feature}" f
  f="${SPECS}/${slug}.md"
  {
    printf '# %s\n\n## Title\n\nT\n\n## Labels\n\n%s\n\n' "$slug" "$labels"
    printf '## Acceptance Criteria\n\n'
    printf -- '- [ ] %s\n' "$AC1" "$AC2" "A disputed invoice shows a  Disputed badge on the list." "$AC4"
    printf '\n'
    if [ -n "$writes" ]; then printf '## Writes\n\n| Key | Op |\n|-----|----|\n%s\n\n' "$writes"; fi
    if [ "$pre" != __NONE__ ]; then printf '## Preconditions\n\n%s\n\n' "$pre"; fi
    printf '## Signals\n\n```json\n{}\n```\n'
  } >"$f"
  printf '%s\n' "$f"
}
# lineof <file> <fixed text> — first line number holding the text.
lineof() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
rows() { planner_acpre_rows "$1" 2>/dev/null || true; }
inv() { planner_acpre_invalid "$INIT" "$1" 2>/dev/null || true; }
# reasons <file> — the invalid reasons, one line, space-separated.
reasons() { inv "$1" | cut -f2 | tr '\n' ',' | sed 's/,$//'; }
row() { printf '| %s | %s | %s | %s | %s |' "$@"; }

# ── 1. Parse ──────────────────────────────────────────────────────────────────

echo "=== parse ==="

fresh
R1=$(row "$AC1" '`invoice.due_date`' state null code:billing/src/main/resources/db/changelog)
R2=$(row "$AC2" '`invoice.customer_id`' input null '—')
F=$(mkspec well "${PH}
${R1}
${R2}")
name="well-formed table: two valid rows"
if need "$name" planner_acpre_rows planner_acpre_invalid; then
  l1=$(lineof "$F" "invoice.due_date")
  l2=$(lineof "$F" "invoice.customer_id")
  want="${l1}${TAB}${AC1}${TAB}invoice.due_date${TAB}state${TAB}null${TAB}code:billing/src/main/resources/db/changelog
${l2}${TAB}${AC2}${TAB}invoice.customer_id${TAB}input${TAB}null${TAB}—"
  check "$name: rows" "$(rows "$F")" "$want"
  check "$name: no invalid" "$(inv "$F")" ""
fi

name="None. is valid with no rows"
if need "$name" planner_acpre_rows planner_acpre_invalid; then
  F=$(mkspec none "None.")
  check "$name" "$(rows "$F")|$(inv "$F")" "|"
fi

name="missing section is reported at line 0"
if need "$name" planner_acpre_invalid; then
  F=$(mkspec missing __NONE__)
  check "$name" "$(inv "$F")" "0${TAB}missing"
fi

name="empty section is reported at its heading"
if need "$name" planner_acpre_invalid; then
  F=$(mkspec empty "")
  check "$name" "$(inv "$F")" "$(lineof "$F" '## Preconditions')${TAB}empty"
fi

name="a second table in the section is invalid"
if need "$name" planner_acpre_invalid planner_acpre_rows; then
  R3=$(row "$AC3" '`invoice.status`' state value:disputed code:billing/src)
  F=$(mkspec second "${PH}
${R1}

${PH}
${R3}")
  check "$name" "$(reasons "$F")" "second-table"
  check "$name: first table rows kept" "$(rows "$F" | cut -f3)" "invoice.due_date"
fi

name="prose where the table should start is invalid"
if need "$name" planner_acpre_invalid; then
  F=$(mkspec prose "Nothing to declare here.")
  check "$name" "$(reasons "$F")" "no-table"
fi

name="a heading inside a fence does not count"
if need "$name" planner_acpre_invalid; then
  F=$(mkspec fenced __NONE__)
  printf '\n```\n## Preconditions\n\nNone.\n```\n' >>"$F"
  check "$name" "$(inv "$F")" "0${TAB}missing"
fi

name="fenced lines inside the section are ignored"
if need "$name" planner_acpre_rows planner_acpre_invalid; then
  F=$(mkspec fencein "${PH}
${R1}")
  # A fence after the table, holding a bogus row.
  sed -i "s/^## Signals$/\`\`\`\n| x | y | z | w | v |\n\`\`\`\n\n## Signals/" "$F"
  check "$name" "$(rows "$F" | cut -f3)|$(inv "$F")" "invoice.due_date|"
fi

name="\\| in a cell is a literal pipe (criterion with a pipe)"
if need "$name" planner_acpre_rows planner_acpre_invalid; then
  F=$(mkspec pipe "${PH}
$(row 'The note a \| b renders as text.' '`note.body`' state null code:billing/src)")
  check "$name" "$(rows "$F" | cut -f2)|$(inv "$F")" "${AC4}|"
fi

name="CRLF is tolerated"
if need "$name" planner_acpre_rows planner_acpre_invalid; then
  F=$(mkspec crlf "${PH}
${R1}
${R2}")
  sed -i 's/$/\r/' "$F"
  check "$name" "$(rows "$F" | cut -f2-6)|$(inv "$F")" "$(rows "${SPECS}/well.md" | cut -f2-6)|"
fi

name="bad header makes every row invalid"
if need "$name" planner_acpre_invalid planner_acpre_rows; then
  F=$(mkspec header "| Criterion | Key | Mode | Requires |
|---|---|---|---|
${R1}")
  check "$name" "$(reasons "$F")|$(rows "$F")" "header,header|"
fi

name="a row with the wrong cell count is invalid"
if need "$name" planner_acpre_invalid; then
  F=$(mkspec shape "${PH}
| ${AC1} | \`invoice.due_date\` | state | null |")
  check "$name" "$(reasons "$F")" "shape"
fi

# ── 2. Grammar ────────────────────────────────────────────────────────────────

echo "=== grammar ==="

# one <slug> <criterion> <key> <mode> <requires> <basis> — reasons of a
# spec holding that one row.
one() {
  local slug="$1" f
  shift
  f=$(mkspec "$slug" "${PH}
$(row "$@")")
  reasons "$f"
}

if need "criterion rules" planner_acpre_invalid planner_acpre_rows; then
  check "criterion: verbatim match" "$(one c1 "$AC1" '`invoice.due_date`' state null code:billing)" ""
  check "criterion: whitespace-collapsed match (AC has a double space)" \
    "$(one c2 "$AC3" '`invoice.status`' state value:paid code:billing)" ""
  check "criterion: cell with extra spaces matches" \
    "$(one c3 "An invoice  with no due date   is listed on the Needs date page." '`invoice.due_date`' state null code:billing)" ""
  check "criterion: no match" "$(one c4 "An invoice is listed." '`invoice.due_date`' state null code:billing)" "criterion not found"
  F=$(mkspec c5 "${PH}
${R1}
$(row "$AC1" '`invoice.status`' state value:sent code:billing)")
  check "criterion: two rows on one criterion are both valid" "$(rows "$F" | wc -l | tr -d ' ')|$(inv "$F")" "2|"
fi

if need "key rules" planner_acpre_invalid; then
  check "key: one segment" "$(one k1 "$AC1" '`invoice`' state null code:billing)" "key"
  check "key: upper case" "$(one k2 "$AC1" '`Invoice.dueDate`' state null code:billing)" "key"
  long="a$(printf 'b%.0s' $(seq 1 55)).due_date"
  check "key: 65 characters (${#long})" "$(one k3 "$AC1" "\`${long}\`" state null code:billing)" "key"
  check "key: not backticked" "$(one k4 "$AC1" 'invoice.due_date' state null code:billing)" "key"
fi

if need "mode rules" planner_acpre_invalid; then
  check "mode: state" "$(one m1 "$AC1" '`invoice.due_date`' state null code:billing)" ""
  check "mode: input with — basis" "$(one m2 "$AC2" '`invoice.customer_id`' input null '—')" ""
  check "mode: given is invalid" "$(one m3 "$AC1" '`invoice.due_date`' given null code:billing)" "mode"
  check "mode: input with a code: basis is invalid" "$(one m4 "$AC2" '`invoice.customer_id`' input null code:billing)" "basis"
  check "mode: state with — is invalid" "$(one m5 "$AC1" '`invoice.due_date`' state null '—')" "basis"
fi

if need "requires rules" planner_acpre_invalid; then
  check "requires: null" "$(one q1 "$AC1" '`invoice.due_date`' state null code:billing)" ""
  check "requires: value:disputed" "$(one q2 "$AC1" '`invoice.status`' state value:disputed code:billing)" ""
  check "requires: number:-5" "$(one q3 "$AC1" '`invoice.number`' state number:-5 code:billing)" ""
  check "requires: number:250000.50" "$(one q4 "$AC1" '`invoice.amount`' state number:250000.50 code:billing)" ""
  check "requires: value:Disputed" "$(one q5 "$AC1" '`invoice.status`' state value:Disputed code:billing)" "requires"
  check "requires: number:1e5" "$(one q6 "$AC1" '`invoice.number`' state number:1e5 code:billing)" "requires"
  n31="1$(printf '0%.0s' $(seq 1 30))"
  check "requires: number of ${#n31} characters" "$(one q7 "$AC1" '`invoice.number`' state "number:${n31}" code:billing)" "requires"
  n30="1$(printf '0%.0s' $(seq 1 29))"
  check "requires: number of ${#n30} characters" "$(one q7b "$AC1" '`invoice.number`' state "number:${n30}" code:billing)" ""
  check "requires: length:600 (cut kind)" "$(one q8 "$AC1" '`invoice.note`' state length:600 code:billing)" "requires"
  check "requires: unknown kind" "$(one q9 "$AC1" '`invoice.note`' state empty code:billing)" "requires"
  check "requires: number:5. (no fraction digits)" "$(one q10 "$AC1" '`invoice.number`' state number:5. code:billing)" "requires"
fi

if need "duplicate tuple" planner_acpre_invalid planner_acpre_rows; then
  F=$(mkspec dup "${PH}
${R1}
$(row "$AC1" '`invoice.due_date`' state null code:billing/src)")
  check "duplicate (Criterion, Key, Mode, Requires) tuple" \
    "$(inv "$F")|$(rows "$F" | wc -l | tr -d ' ')" "$(lineof "$F" 'code:billing/src |')${TAB}duplicate|1"
fi

# ── 3. Basis ──────────────────────────────────────────────────────────────────

echo "=== basis ==="

if need "basis rules" planner_acpre_invalid; then
  check "basis: code: with .." "$(one b1 "$AC1" '`invoice.due_date`' state null code:billing/../x)" "basis"
  check "basis: code: with a leading /" "$(one b2 "$AC1" '`invoice.due_date`' state null code:/billing)" "basis"
  check "basis: unknown kind" "$(one b3 "$AC1" '`invoice.due_date`' state null idea:billing)" "basis"

  fresh
  mkspec invoice-dispute "None." '| `invoice.status` | transition:sent->disputed |' >/dev/null
  mkspec invoice-create "None." '| `invoice` | create |' >/dev/null
  mkspec invoice-reader "None." >/dev/null
  SYN="${SPECS}/invoice-test-data.md"
  printf '<!-- planner:testdata-synth v1 -->\n## Title\n\nSeed\n\n## Writes\n\n| Key | Op |\n|-----|----|\n| `invoice.status` | update |\n' >"$SYN"

  # bspec <slug> <basis> [<writes>] [<labels>] — reasons of a spec whose one
  # row needs invoice.status value:disputed with that basis.
  bspec() {
    local f
    f=$(mkspec "$1" "${PH}
$(row "$AC3" '`invoice.status`' state value:disputed "$2")" "${3:-}" "${4:-type:feature}")
    reasons "$f"
  }
  check "basis: spec: unknown slug" "$(bspec s1 spec:no-such-spec)" "basis-spec-unknown"
  check "basis: spec: synth-marked slug" "$(bspec s2 spec:invoice-test-data '' 'type:feature blocked-by:invoice-test-data')" "basis-spec-unknown"
  check "basis: spec: own slug without an own Writes row" "$(bspec s3 spec:s3)" "basis-spec-no-write"
  check "basis: spec: own slug with an exact Writes row" "$(bspec s4 spec:s4 '| `invoice.status` | update |')" ""
  check "basis: spec: own slug with an entity Writes row" "$(bspec s5 spec:s5 '| `invoice` | create |')" ""
  check "basis: spec: own slug writing another field only" "$(bspec s6 spec:s6 '| `invoice.note` | update |')" "basis-spec-no-write"
  check "basis: spec: another spec with a Writes row that is a dependency" \
    "$(bspec s7 spec:invoice-dispute '' 'type:feature blocked-by:invoice-dispute')" ""
  check "basis: spec: dependency through a backticked prefix ref" \
    "$(bspec s7b spec:invoice-dispute '' 'type:feature blocked-by:`invoice-dispute`')" ""
  check "basis: spec: entity Writes row of a dependency" \
    "$(bspec s8 spec:invoice-create '' 'type:feature blocked-by:invoice-create')" ""
  check "basis: spec: a writer that is not a dependency" "$(bspec s9 spec:invoice-dispute)" "basis-not-a-dependency"
  check "basis: spec: a dependency with no Writes row" \
    "$(bspec s10 spec:invoice-reader '' 'type:feature blocked-by:invoice-reader')" "basis-spec-no-write"
  check "basis: spec: no Writes row and not a dependency lists both" \
    "$(bspec s11 spec:invoice-reader)" "basis-spec-no-write,basis-not-a-dependency"
  F="${SPECS}/s9.md"
  check "basis: the semantic reason names the row's line" \
    "$(inv "$F" | cut -f1)" "$(lineof "$F" 'spec:invoice-dispute')"
  check "basis: rows still prints a grammar-valid spec: row" "$(rows "$F" | cut -f6)" "spec:invoice-dispute"
fi

name="every problem of a spec is listed, sorted by line"
if need "$name" planner_acpre_invalid; then
  fresh
  F=$(mkspec many "${PH}
$(row "$AC1" '`invoice`' state null code:billing)
$(row "$AC1" '`invoice.due_date`' given null code:billing)
$(row "$AC3" '`invoice.status`' state value:Disputed code:billing)
$(row "$AC3" '`invoice.status`' state value:sent spec:many)")
  got=$(inv "$F")
  want="$(lineof "$F" '`invoice` |')${TAB}key
$(lineof "$F" 'given')${TAB}mode
$(lineof "$F" 'value:Disputed')${TAB}requires
$(lineof "$F" 'spec:many')${TAB}basis-spec-no-write"
  check "$name" "$got" "$want"
fi

# ── 4. Skips and contract ─────────────────────────────────────────────────────

echo "=== skips and contract ==="

name="synth-marked spec and INDEX.md are skipped"
if need "$name" planner_acpre_rows planner_acpre_invalid; then
  fresh
  printf '<!-- planner:testdata-synth v1 -->\n## Title\n\nSeed\n' >"${SPECS}/x-test-data.md"
  printf '# Index\n' >"${SPECS}/INDEX.md"
  check "$name" "$(rows "${SPECS}/x-test-data.md")|$(inv "${SPECS}/x-test-data.md")|$(inv "${SPECS}/INDEX.md")" "||"
fi

name="an unreadable spec is rc 1"
if need "$name" planner_acpre_rows planner_acpre_invalid; then
  rc1=0
  rc2=0
  planner_acpre_rows "${SPECS}/nope.md" >/dev/null 2>&1 || rc1=$?
  planner_acpre_invalid "$INIT" "${SPECS}/nope.md" >/dev/null 2>&1 || rc2=$?
  check "$name" "${rc1} ${rc2}" "1 1"
fi

name="contract marker written once, initiative recognised"
if need "$name" planner_acpre_contract_mark planner_acpre_contract_initiative; then
  fresh
  r=""
  planner_acpre_contract_initiative "$INIT" && r="before "
  planner_acpre_contract_mark "$INIT"
  planner_acpre_contract_mark "$INIT"
  planner_acpre_contract_initiative "$INIT" && r="${r}after"
  n=$(grep -c '|META|contract|start|ac-precondition-v1$' "$(planner_state_log "$INIT")" || true)
  check "$name" "${r} ${n}" "after 1"
fi

name="constants"
if need "$name" planner_acpre_rows; then
  check "$name" "${PLANNER_ACPRE_CONTRACT:-}|${PLANNER_ACPRE_NUMBER_MAX:-}" "ac-precondition-v1|30"
fi

# ── 5. mawk / gawk ────────────────────────────────────────────────────────────

echo "=== awk portability ==="

run_all() {
  local f d
  for d in "$REPOS_ROOT"/.ticket-auto/initiatives/*/artifacts/specs; do
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      printf '%s\n' "${f##*/}"
      planner_acpre_rows "$f" 2>&1 || true
    done
  done
}

name="mawk runs every awk program"
if need "$name" planner_acpre_rows; then
  if command -v mawk >/dev/null 2>&1; then
    m=$(PLANNER_ACPRE_AWK=mawk run_all 2>&1)
    a=$(run_all 2>&1)
    if [ -n "$m" ] && ! grep -qi 'syntax error\|mawk:' <<<"$m"; then pass "$name"; else fail "$name" "$(head -3 <<<"$m")"; fi
    check "mawk output equals the default awk output" "$m" "$a"
    if command -v gawk >/dev/null 2>&1; then
      g=$(PLANNER_ACPRE_AWK=gawk run_all 2>&1)
      if [ "$m" = "$g" ]; then
        pass "mawk output equals gawk output"
      else fail "mawk output equals gawk output" "$(diff <(echo "$m") <(echo "$g") | head -5)"; fi
    else
      echo "  SKIP mawk output equals gawk output (gawk not installed)"
    fi
  else
    echo "  SKIP mawk runs every awk program (mawk not installed)"
  fi
fi

echo ""
echo "=== planner ac precondition: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
