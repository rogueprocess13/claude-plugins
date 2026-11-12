#!/usr/bin/env bash
# test-planner-ac-precondition.sh — Tests for planner-ac-precondition.sh
# (planner-ac-code-precondition, tasks 1.2–1.3, 2.2, 5.1).
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
#   6. Schema facts (JPA, Liquibase XML), the decision per row, decimal
#      comparison, nearest names, the file cap, the cache (task 2.2), over the
#      fixture tree fixtures/ac-precondition/billing/.
#   7. The prompt wording (task 5.1): Specify rules, Consensus rule, revise
#      rule; the Specify example parses.
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

# ── 4b. Prompt wording (task 5.1) ─────────────────────────────────────────────

echo "=== prompt wording ==="

# The Specify rules (design D12): the two-row D1 example (one state row, one
# input row), the key grammar by reference to Writes/Reads, the three Requires
# forms, both Basis forms, None., and that Crosscheck blocks.
name="Specify rules carry the D12 content"
if need "$name" planner_acpre_prompt_rules; then
  r=$(planner_acpre_prompt_rules)
  missing=""
  for want in '## Preconditions' '| Criterion | Key | Mode | Requires | Basis |' \
    '| state | null | code:' '| input | null | — |' '## Writes' '## Reads' \
    'state' 'input' 'rejected' 'null' 'value:<v>' 'number:<n>' 'code:<path>' \
    'spec:<slug>' 'depends on' 'None.' 'Crosscheck' 'verbatim'; do
    grep -qF -- "$want" <<<"$r" || missing="${missing} [${want}]"
  done
  if [ -z "$missing" ]; then pass "$name"; else fail "$name" "missing:${missing}"; fi
  words=$(wc -w <<<"$r")
  if [ "$words" -le 220 ]; then pass "Specify rules stay near 150 words (${words})"; else
    fail "Specify rules stay near 150 words" "${words} words"
  fi
  case "$r" in $'\n'*) pass "$name: starts with a blank line" ;; *) fail "$name: starts with a blank line" "no" ;; esac
  # The key grammar is referenced, not restated (item 6 owns it).
  if ! grep -qF -- '64 characters' <<<"$r"; then pass "$name: key grammar by reference"; else
    fail "$name: key grammar by reference" "restates the 64-character rule"
  fi
  # Stripping relies on these texts occurring once in the Specify prompt.
  if ! grep -qF -- ', `## Preconditions`' <<<"$r"; then pass "$name: no heading-list fragment inside"; else
    fail "$name: no heading-list fragment inside" "contains it"
  fi
fi

name="the Specify rules' own example parses as one state and one input row"
if need "$name" planner_acpre_prompt_rules planner_acpre_rows planner_acpre_invalid; then
  fresh
  ex=$(planner_acpre_prompt_rules | awk '/^```/{f=!f; next} f && /^## Preconditions$/{on=1} f && on')
  acs=$(printf '%s\n' "$ex" | awk -F'|' 'NR > 4 && NF > 5 { c = $2; sub(/^ +/, "", c); sub(/ +$/, "", c); print "- [ ] " c }')
  printf '# Example\n\n## Title\n\nExample\n\n## Acceptance Criteria\n\n%s\n\n%s\n' "$acs" "$ex" >"${SPECS}/example.md"
  check "$name: no invalid row" "$(inv "${SPECS}/example.md")" ""
  check "$name: modes" "$(rows "${SPECS}/example.md" | cut -f4 | tr '\n' ' ')" "state input "
fi

name="Consensus rule carries the D12 content"
if need "$name" planner_acpre_consensus_rule; then
  r=$(planner_acpre_consensus_rule)
  missing=""
  for want in '## Preconditions' 'acceptance criterion' 'key' 'schema' 'same edit' 'Never delete a' 'row alone'; do
    grep -qF -- "$want" <<<"$r" || missing="${missing} [${want}]"
  done
  if [ -z "$missing" ]; then pass "$name"; else fail "$name" "missing:${missing}"; fi
  words=$(wc -w <<<"$r")
  if [ "$words" -le 60 ]; then pass "Consensus rule stays near 40 words (${words})"; else
    fail "Consensus rule stays near 40 words" "${words} words"
  fi
  case "$r" in "   "[!\ ]*) pass "$name: indented as a step-3 rule" ;; *) fail "$name: indented as a step-3 rule" "no" ;; esac
fi

name="revise rule is one sentence about Criterion cells"
if need "$name" planner_acpre_revise_rule; then
  r=$(planner_acpre_revise_rule)
  missing=""
  for want in '## Preconditions' 'extend' 'Criterion cell' 'nothing else'; do
    grep -qF -- "$want" <<<"$r" || missing="${missing} [${want}]"
  done
  if [ -z "$missing" ]; then pass "$name"; else fail "$name" "missing:${missing}"; fi
  check "$name: one sentence" "$(tr -cd '.' <<<"${r%.}" | wc -c | tr -d ' ')" "0"
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

# ── 6. Schema facts and the decision (task 2.2) ───────────────────────────────

echo "=== schema facts ==="

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
FX="${SCRIPT_DIR}/fixtures/ac-precondition/billing"
BT="${REPOS_ROOT}/billing"
cp -R "$FX" "$BT"
git -C "$BT" init -q -b main
git -C "$BT" add -A
git -C "$BT" commit -qm fixture
fresh
INIT_LIVE="$INIT"
CL=src/main/resources/db/changelog
JV=src/main/java/com/example/billing
X1="billing/${CL}/001-invoice.xml"
X2="billing/${CL}/002-customer.xml"
X3="billing/${CL}/003-relax.xml"
JI="billing/${JV}/Invoice.java"
JC="billing/${JV}/Customer.java"
FACT_RE='^(nullable|primitive|enum|enum-unchecked|min|max|transient|unparsed)'"$TAB"

# facts <sub> <key> — every facts line; kinds <sub> <key> — the fact lines only.
facts() { planner_acpre_facts "$BT" "$1" "$2" billing 2>/dev/null || true; }
kinds() { facts "$@" | grep -E "$FACT_RE" || true; }
# dec <key> <requires> — the decision for a `code:billing/<changelog>` row.
dec() { planner_acpre_check_row "$INIT_LIVE" "billing/${CL}" "$1" "$2" 2>/dev/null | cut -f3- || true; }
fl() { lineof "${BT}/${1#billing/}" "$2"; }
# starts <name> <got> <prefix>
starts() {
  case "$2" in "$3"*) pass "$1" ;; *) fail "$1" "got [$2] want prefix [$3]" ;; esac
}

name="constants"
if need "$name" planner_acpre_facts; then
  check "$name" "${PLANNER_ACPRE_ENTITY_MAX_FILES:-}|${PLANNER_ACPRE_EXTRACTORS:-}" \
    "2000|_planner_acpre_facts_liquibase_xml _planner_acpre_facts_jpa"
fi

name="facts: multi-line Liquibase column and constraints give nullable no at the attribute line"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" invoice.due_date)" "nullable${TAB}no${TAB}${X1}:$(fl "$X1" '    nullable="false"')"
fi

name="facts: primaryKey and @Id both give nullable no; bigint gives min and max"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" invoice.id)" "nullable${TAB}no${TAB}${X1}:$(fl "$X1" 'primaryKey="true"')
min${TAB}-9223372036854775808${TAB}${X1}:$(fl "$X1" '<column name="id"')
max${TAB}9223372036854775807${TAB}${X1}:$(fl "$X1" '<column name="id"')
nullable${TAB}no${TAB}${JI}:$(fl "$JI" 'private Long id;')"
fi

name="facts: dropNotNullConstraint gives nullable yes next to the createTable no"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" invoice.paid_at)" "nullable${TAB}no${TAB}${X1}:19
nullable${TAB}yes${TAB}${X3}:$(fl "$X3" 'dropNotNullConstraint')"
fi

name="facts: addNotNullConstraint gives nullable no"
if need "$name" planner_acpre_facts; then
  starts "$name" "$(kinds "$CL" invoice.priority)" "nullable${TAB}no${TAB}${X3}:$(fl "$X3" 'addNotNullConstraint')"
fi

name="facts: every column of the multi-column addColumn is found"
if need "$name" planner_acpre_facts; then
  got=""
  for k in reference note priority; do
    grep -q "^found${TAB}field${TAB}${X1}:" <<<"$(facts "$CL" "invoice.$k")" && got="${got}${k} "
  done
  check "$name" "$got" "reference note priority "
fi

name="facts: comments and rollback blocks give nothing (reference none, note only nullable yes)"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" invoice.reference)|$(kinds "$CL" invoice.note)" \
    "|nullable${TAB}yes${TAB}${X1}:$(fl "$X1" 'nullable="true"')"
fi

name="facts: int column and primitive int field"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" invoice.number)" "min${TAB}-2147483648${TAB}${X1}:$(fl "$X1" '<column name="number"')
max${TAB}2147483647${TAB}${X1}:$(fl "$X1" '<column name="number"')
primitive${TAB}int${TAB}${JI}:$(fl "$JI" 'private int number;')"
fi

name="facts: smallint column"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" customer.visits | grep -E "^(min|max)")" "min${TAB}-32768${TAB}${X2}:13
max${TAB}32767${TAB}${X2}:13"
fi

name="facts: modifyDataType adds a second type"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" invoice.reminder_count | cut -f1,2 | tr '\n' ' ')" \
    "min	-2147483648 max	2147483647 min	-9223372036854775808 max	9223372036854775807 primitive	int "
fi

name="facts: due_date matches the dueDate field"
if need "$name" planner_acpre_facts; then
  if grep -q "^found${TAB}field${TAB}${JI}:$(fl "$JI" 'private LocalDate dueDate;')\$" <<<"$(facts "$CL" invoice.due_date)"; then
    pass "$name"
  else fail "$name" "$(facts "$CL" invoice.due_date)"; fi
fi

name="facts: STRING enum lists its constants; a multi-line @Enumerated is read"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" invoice.status)" "enum${TAB}DRAFT,SENT,PAID${TAB}${JI}:$(fl "$JI" 'private InvoiceStatus status;')"
fi

name="facts: unannotated, @Convert, constructor-valued and ambiguous enums are enum-unchecked"
if need "$name" planner_acpre_facts; then
  got="$(kinds "$CL" invoice.priority | grep '^enum' | cut -f1,2)|$(kinds "$CL" invoice.channel | cut -f1,2)|$(kinds "$CL" invoice.reply_channel | cut -f1,2)|$(kinds "$CL" invoice.urgency | cut -f1,2)"
  check "$name" "$got" "enum-unchecked${TAB}no @Enumerated (ordinal by default)|enum-unchecked${TAB}@Convert|enum-unchecked${TAB}enum Channel has constructor arguments|enum-unchecked${TAB}ambiguous enum Priority (2 declarations)"
fi

name="facts: @Transient and @Formula give transient"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$CL" invoice.label | cut -f1)|$(kinds "$CL" invoice.line_count | cut -f1 | head -1)" "transient|transient"
fi

name="facts: an unparsed change on the table (renameColumn)"
if need "$name" planner_acpre_facts; then
  if grep -q "^unparsed${TAB}renameColumn${TAB}${X2}:$(fl "$X2" '<renameColumn')\$" <<<"$(kinds "$CL" customer.name)"; then
    pass "$name"
  else fail "$name" "$(kinds "$CL" customer.name)"; fi
fi

name="facts: @Table name and class name both match"
if need "$name" planner_acpre_facts; then
  w="nullable${TAB}no${TAB}${JC}:$(fl "$JC" 'private Long id;')"
  got="$(kinds "$CL" customer_account.id | grep -F "$JC")|$(kinds "$CL" customer.id | grep -F "$JC")"
  check "$name" "$got" "${w}|${w}"
fi

name="facts: invoices does not match invoice"
if need "$name" planner_acpre_facts; then
  check "$name" "$(facts "$CL" invoices.status | grep -c "^found${TAB}" || true)" "0"
fi

name="facts: pruned directories are ignored"
if need "$name" planner_acpre_facts; then
  got=$(for k in invoice.reminder_count invoice.status invoice.note; do facts "" "$k"; done | grep -c 'target/\|build/' || true)
  check "$name" "$got" "0"
fi

name="facts: a constant annotation argument gives no fact"
if need "$name" planner_acpre_facts; then
  check "$name" "$(kinds "$JV/Invoice.java" invoice.reference)" ""
fi

name="facts: whole-repository entity fallback from the changelog directory"
if need "$name" planner_acpre_facts; then
  if grep -q "^nullable${TAB}no${TAB}${JI}:" <<<"$(facts "$CL" invoice.id)"; then pass "$name"; else fail "$name" "$(facts "$CL" invoice.id)"; fi
fi

name="facts: an entity-file anchor still finds the changelog"
if need "$name" planner_acpre_facts; then
  starts "$name" "$(kinds "$JV/Invoice.java" invoice.due_date)" "nullable${TAB}no${TAB}${X1}:"
fi

name="facts: the cap counts only .java/.xml files; a cap hit is unchecked with its reason"
if need "$name" planner_acpre_facts planner_acpre_check_row; then
  CT="${REPOS_ROOT}/capped"
  mkdir -p "${CT}/src/notes"
  for i in 1 2 3 4 5 6 7 8 9; do printf 'n\n' >"${CT}/src/notes/n${i}.txt"; done
  printf '@Entity\nclass Invoice {\n  @Id\n  Long id;\n}\n' >"${CT}/src/Invoice.java"
  printf '<databaseChangeLog/>\n' >"${CT}/src/a.xml"
  git -C "$CT" init -q -b main
  git -C "$CT" add -A
  git -C "$CT" commit -qm c
  old="$PLANNER_OWNERSHIP_CODE_MAX_FILES"
  PLANNER_OWNERSHIP_CODE_MAX_FILES=2
  r1=$(planner_acpre_facts "$CT" src invoice.id capped | grep -c "^unchecked" || true)
  printf 'class A {}\n' >"${CT}/src/A.java"
  r2=$(planner_acpre_facts "$CT" src invoice.id capped | grep "^unchecked" || true)
  r3=$(planner_acpre_check_row "$INIT_LIVE" capped/src invoice.id null 2>/dev/null || true)
  PLANNER_OWNERSHIP_CODE_MAX_FILES="$old"
  check "$name: under the cap" "$r1" "0"
  check "$name: over the cap" "$r2" "unchecked${TAB}more than 2 candidate files under capped/src${TAB}-"
  check "$name: decision" "$r3" "live${TAB}-${TAB}unchecked${TAB}more than 2 candidate files under capped/src"
fi

name="facts: the entity fallback has its own cap"
if need "$name" planner_acpre_facts; then
  old="$PLANNER_ACPRE_ENTITY_MAX_FILES"
  PLANNER_ACPRE_ENTITY_MAX_FILES=1
  got=$(facts "$CL" invoice.id | grep "^unchecked" || true)
  PLANNER_ACPRE_ENTITY_MAX_FILES="$old"
  check "$name" "$got" "unchecked${TAB}more than 1 entity files in the repository${TAB}-"
fi

name="facts: an unsupported tree (only .py files) gives no facts and no source"
if need "$name" planner_acpre_facts planner_acpre_check_row; then
  PT="${REPOS_ROOT}/pyapp"
  mkdir -p "${PT}/app"
  printf 'class Invoice:\n    due_date = None\n' >"${PT}/app/models.py"
  git -C "$PT" init -q -b main
  git -C "$PT" add -A
  git -C "$PT" commit -qm p
  check "$name" "$(planner_acpre_facts "$PT" app invoice.due_date pyapp | grep -cE "$FACT_RE|^source" || true)" "0"
  check "$name: decision" "$(planner_acpre_check_row "$INIT_LIVE" pyapp/app invoice.due_date null 2>/dev/null)" \
    "live${TAB}none${TAB}unchecked${TAB}entity not found"
fi

name="facts: placeholders and constant arguments give no fact, never 0"
if need "$name" planner_acpre_facts; then
  HT="${REPOS_ROOT}/holders"
  mkdir -p "${HT}/src/db"
  cat >"${HT}/src/Ledger.java" <<'EOF'
@Entity
@Table(name = "${ledger.table}")
public class Ledger {
    @Enumerated(MODE)
    private Kind kind;
    @Column(name = PREFIX + "x")
    private Long amount;
}
EOF
  printf 'public enum Kind { A, B }\n' >"${HT}/src/Kind.java"
  cat >"${HT}/src/db/changelog.xml" <<'EOF'
<databaseChangeLog>
  <changeSet id="1" author="t">
    <createTable tableName="ledger">
      <column name="total" type="${int.type}">
        <constraints nullable="${total.nullable}"/>
      </column>
      <column name="amount" type="int"/>
    </createTable>
    <modifyDataType tableName="ledger" columnName="amount" newDataType="${big}"/>
  </changeSet>
</databaseChangeLog>
EOF
  got="$(planner_acpre_facts "$HT" src ledger.total holders | grep -E "$FACT_RE" || true)|$(planner_acpre_facts "$HT" src ledger.amount holders | grep -E "$FACT_RE" || true)|$(planner_acpre_facts "$HT" src ledger.kind holders | grep -E "$FACT_RE" | cut -f1,2 || true)|$(planner_acpre_facts "$HT" src ledger_table.kind holders | grep -c "^found" || true)"
  check "$name" "$got" "||enum-unchecked${TAB}unreadable @Enumerated argument|0"
fi

echo "=== decision ==="

name="decide: null on a NOT NULL column is unreachable"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(planner_acpre_check_row "$INIT_LIVE" "billing/${CL}" invoice.due_date null 2>/dev/null)" \
    "live${TAB}jpa,liquibase${TAB}unreachable${TAB}nullable${TAB}no${TAB}${X1}:$(fl "$X1" '    nullable="false"')"
fi
name="decide: null on a primitive-only field is unchecked"
if need "$name" planner_acpre_check_row; then
  starts "$name" "$(dec invoice.reminder_count null)" "unchecked${TAB}only a primitive type (int) at ${JI}:"
fi
name="decide: null on an @Id / primary key is unreachable"
if need "$name" planner_acpre_check_row; then
  starts "$name" "$(dec invoice.id null)" "unreachable${TAB}nullable${TAB}no${TAB}"
fi
name="decide: contradictory nullable facts are unchecked"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(dec invoice.paid_at null)" "unchecked${TAB}nullable facts disagree (${X1}:19, ${X3}:$(fl "$X3" 'dropNotNullConstraint'))"
fi
name="decide: any row on a renamed table's column is unchecked"
if need "$name" planner_acpre_check_row; then
  w="unchecked${TAB}changelog has an unparsed change (renameColumn) at ${X2}:$(fl "$X2" '<renameColumn')"
  check "$name" "$(dec customer.name null)|$(dec customer.visits number:5)" "${w}|${w}"
fi
name="decide: a value the STRING enum lacks is unreachable, one it has is reachable"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(dec invoice.status value:overdue)|$(dec invoice.status value:paid)" \
    "unreachable${TAB}enum${TAB}DRAFT,SENT,PAID${TAB}${JI}:$(fl "$JI" 'private InvoiceStatus status;')|reachable"
fi
name="decide: unannotated, @Convert, constructor and ambiguous enums are unchecked"
if need "$name" planner_acpre_check_row; then
  got="$(dec invoice.priority value:x | cut -f1,2)|$(dec invoice.channel value:x | cut -f1,2)|$(dec invoice.reply_channel value:x | cut -f1,2)|$(dec invoice.urgency value:x | cut -f1,2)"
  check "$name" "$got" "unchecked${TAB}no @Enumerated (ordinal by default) at ${JI}:$(fl "$JI" 'private InvoicePriority priority;')|unchecked${TAB}@Convert at ${JI}:$(fl "$JI" 'private Channel channel;')|unchecked${TAB}enum Channel has constructor arguments at ${JI}:$(fl "$JI" 'private Channel replyChannel;')|unchecked${TAB}ambiguous enum Priority (2 declarations) at ${JI}:$(fl "$JI" 'private Priority urgency;')"
fi
name="decide: @Transient and @Formula fields are unchecked"
if need "$name" planner_acpre_check_row; then
  got="$(dec invoice.label null | cut -f1)|$(dec invoice.line_count number:5 | cut -f1)"
  check "$name" "$got" "unchecked|unchecked"
  starts "$name: reason" "$(dec invoice.label null)" "unchecked${TAB}transient or computed field at ${JI}:"
fi
name="decide: a number above the int range is unreachable, -5 is reachable"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(dec invoice.number number:3000000000)|$(dec invoice.number number:-5)|$(dec invoice.number number:-2147483649 | cut -f1-3)" \
    "unreachable${TAB}max${TAB}2147483647${TAB}${X1}:$(fl "$X1" '<column name="number"')|reachable|unreachable${TAB}min${TAB}-2147483648"
fi
name="decide: two integer types are unchecked; a non-integer column is unchecked"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(dec invoice.reminder_count number:5)|$(dec invoice.status number:5)" \
    "unchecked${TAB}integer types disagree|unchecked${TAB}no integer column type"
fi
name="decide: a null row with no nullable fact is reachable"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(dec invoice.reference null)" "reachable"
fi
name="decide: a pin-failed tree is unchecked"
if need "$name" planner_acpre_check_row; then
  fresh
  planner_state_write "$INIT" META discovery repo-ref "billing@main@0000000000000000000000000000000000000001" >/dev/null
  check "$name" "$(planner_acpre_check_row "$INIT" "billing/${CL}" invoice.due_date null 2>/dev/null)" \
    "pin-failed${TAB}-${TAB}unchecked${TAB}the pinned worktree could not be created"
fi
name="decide: an invalid path or unknown repository is unchecked with the reason"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(planner_acpre_check_row "$INIT_LIVE" nosuchrepo/src invoice.due_date null 2>/dev/null)" \
    "-${TAB}-${TAB}unchecked${TAB}repository not found"
fi
name="decide: a missing path is unchecked"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(planner_acpre_check_row "$INIT_LIVE" billing/src/nope invoice.due_date null 2>/dev/null)" \
    "live${TAB}-${TAB}unchecked${TAB}path not found: billing/src/nope"
fi
name="decide: the pinned tree is read when the live checkout has moved"
if need "$name" planner_acpre_check_row; then
  B2="${REPOS_ROOT}/billing2"
  cp -R "$FX" "$B2"
  git -C "$B2" init -q -b main
  git -C "$B2" add -A
  git -C "$B2" commit -qm pinned
  sha=$(git -C "$B2" rev-parse HEAD)
  sed -i 's/nullable="false"/nullable="true"/' "${B2}/${CL}/001-invoice.xml"
  git -C "$B2" commit -qam relaxed
  fresh
  planner_state_write "$INIT" META discovery repo-ref "billing2@main@${sha}" >/dev/null
  got=$(planner_acpre_check_row "$INIT" "billing2/${CL}" invoice.due_date null 2>/dev/null | cut -f1,3)
  live=$(planner_acpre_check_row "$INIT_LIVE" "billing2/${CL}" invoice.due_date null 2>/dev/null | cut -f1,3)
  check "$name" "${got}|${live}" "pinned${TAB}unreachable|live${TAB}reachable"
fi

echo "=== decide (direct) ==="

name="decide: primitive alone never blocks; Liquibase agreeing does"
if need "$name" planner_acpre_decide; then
  base="found${TAB}entity${TAB}f:1
found${TAB}field${TAB}f:2"
  a=$(planner_acpre_decide null "${base}
primitive${TAB}int${TAB}f:2" | cut -f1)
  b=$(planner_acpre_decide null "${base}
primitive${TAB}int${TAB}f:2
nullable${TAB}no${TAB}x:3" | cut -f1)
  c=$(planner_acpre_decide null "${base}
nullable${TAB}yes${TAB}x:3
primitive${TAB}int${TAB}f:2" | cut -f1)
  check "$name" "$a $b $c" "unchecked unreachable unchecked"
fi
name="decide: an unparsed fact never blocks a null row; a value row ignores it"
if need "$name" planner_acpre_decide; then
  base="found${TAB}entity${TAB}f:1
found${TAB}field${TAB}f:2
nullable${TAB}no${TAB}x:3
enum${TAB}A,B_C${TAB}f:2
unparsed${TAB}sql${TAB}x:9"
  check "$name" "$(planner_acpre_decide null "$base" | cut -f1)|$(planner_acpre_decide value:bc "$base")|$(planner_acpre_decide value:d "$base" | cut -f1)" \
    "unchecked|reachable|unreachable"
fi
name="decide: an enum-unchecked fact wins over an enum fact"
if need "$name" planner_acpre_decide; then
  check "$name" "$(planner_acpre_decide value:z "found${TAB}entity${TAB}f:1
found${TAB}field${TAB}f:2
enum${TAB}A${TAB}f:2
enum-unchecked${TAB}@Convert${TAB}f:2")" "unchecked${TAB}@Convert at f:2"
fi

echo "=== decimal comparison ==="

# cmpall — every pair, one result per line.
cmpall() {
  local p
  for p in "-0 0" "007 7" "0.50 .5" "2147483647 2147483648" "2147483648 2147483647" \
    "-9223372036854775808 -9223372036854775809" "-9223372036854775809 -9223372036854775808" \
    "0.5 0" "-0.5 0" "-1 1" "1.10 1.1" "1.01 1.1" "12 9" "-12 -9" "3000000000 2147483647"; do
    # shellcheck disable=SC2086  # the pair splits on purpose
    printf '%s=%s\n' "$p" "$(_planner_acpre_num_cmp $p)"
  done
}
CMP_WANT="-0 0=0
007 7=0
0.50 .5=0
2147483647 2147483648=-1
2147483648 2147483647=1
-9223372036854775808 -9223372036854775809=1
-9223372036854775809 -9223372036854775808=-1
0.5 0=1
-0.5 0=-1
-1 1=-1
1.10 1.1=0
1.01 1.1=-1
12 9=1
-12 -9=-1
3000000000 2147483647=1"
name="decimal comparison under the default awk"
if need "$name" _planner_acpre_num_cmp; then
  check "$name" "$(cmpall)" "$CMP_WANT"
fi
name="decimal comparison under mawk"
if need "$name" _planner_acpre_num_cmp; then
  if command -v mawk >/dev/null 2>&1; then
    check "$name" "$(PLANNER_ACPRE_AWK=mawk cmpall)" "$CMP_WANT"
  else echo "  SKIP $name (mawk not installed)"; fi
fi
name="decimal comparison under gawk"
if need "$name" _planner_acpre_num_cmp; then
  if command -v gawk >/dev/null 2>&1; then
    check "$name" "$(PLANNER_ACPRE_AWK=gawk cmpall)" "$CMP_WANT"
  else echo "  SKIP $name (gawk not installed)"; fi
fi

echo "=== nearest names ==="

name="nearest: invoices.status lists invoice"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(dec invoices.status value:x)" "unchecked${TAB}entity not found; nearest: invoice"
fi
name="nearest: invoice.duedate_at lists due_date"
if need "$name" planner_acpre_check_row; then
  check "$name" "$(dec invoice.duedate_at null)" "unchecked${TAB}field not found; nearest: due_date"
fi
name="nearest: at most three, plural rule first"
if need "$name" _planner_acpre_nearest; then
  check "$name" "$(printf 'statuses\nstatus_code\nStatus\nstatement\nstat\nother\n' | _planner_acpre_nearest statu)" "Status, statuses, status_code"
  check "$name (plural first)" "$(printf 'invoice_line\nInvoice\ninvoice\nother\n' | _planner_acpre_nearest invoices)" "Invoice, invoice_line"
  check "$name (none)" "$(printf 'other\nabc\n' | _planner_acpre_nearest invoices)" ""
fi

echo "=== performance and cache ==="

name="performance: every fixture decision under 5 seconds"
if need "$name" planner_acpre_check_row; then
  t0=$(date +%s%N)
  for kr in "invoice.due_date null" "invoice.reminder_count null" "invoice.id null" "invoice.paid_at null" \
    "customer.name null" "invoice.status value:overdue" "invoice.status value:paid" "invoice.priority value:x" \
    "invoice.channel value:x" "invoice.reply_channel value:x" "invoice.urgency value:x" "invoice.label null" \
    "invoice.line_count number:5" "invoice.number number:3000000000" "invoice.number number:-5"; do
    # shellcheck disable=SC2086  # key and requires split on purpose
    dec $kr >/dev/null
  done
  ms=$((($(date +%s%N) - t0) / 1000000))
  if [ "$ms" -lt 5000 ]; then pass "$name (${ms} ms)"; else fail "$name" "${ms} ms"; fi
fi

name="cache: facts for one (tree, entity) are computed once per run"
if need "$name" planner_acpre_facts; then
  B3="${REPOS_ROOT}/billing3"
  cp -R "$FX" "$B3"
  export PLANNER_ACPRE_CACHE_DIR="${WORK}/acp-cache"
  mkdir -p "$PLANNER_ACPRE_CACHE_DIR"
  planner_acpre_facts "$B3" "$CL" invoice.due_date billing3 >/dev/null
  sed -i 's/name="number" type="int"/name="number" type="bigint"/' "${B3}/${CL}/001-invoice.xml"
  cached=$(planner_acpre_facts "$B3" "$CL" invoice.number billing3 | grep '^max' | cut -f2)
  unset PLANNER_ACPRE_CACHE_DIR
  fresh_out=$(planner_acpre_facts "$B3" "$CL" invoice.number billing3 | grep '^max' | cut -f2)
  check "$name" "${cached}|${fresh_out}" "2147483647|9223372036854775807"
fi

echo "=== facts awk portability ==="

facts_all() {
  local k
  for k in invoice.due_date invoice.id invoice.paid_at invoice.status invoice.priority invoice.channel \
    invoice.reply_channel invoice.urgency invoice.number invoice.note invoice.reference customer.name \
    invoices.status invoice.duedate_at; do
    printf '%s\n' "$k"
    facts "$CL" "$k"
    dec "$k" value:x
  done
}
name="mawk runs the facts programs"
if need "$name" planner_acpre_facts; then
  if command -v mawk >/dev/null 2>&1; then
    m=$(PLANNER_ACPRE_AWK=mawk facts_all 2>&1)
    if [ -n "$m" ] && ! grep -qi 'syntax error\|mawk:' <<<"$m"; then pass "$name"; else fail "$name" "$(head -3 <<<"$m")"; fi
    check "facts: mawk output equals the default awk output" "$m" "$(facts_all 2>&1)"
    if command -v gawk >/dev/null 2>&1; then
      g=$(PLANNER_ACPRE_AWK=gawk facts_all 2>&1)
      if [ "$m" = "$g" ]; then pass "facts: mawk output equals gawk output"; else fail "facts: mawk output equals gawk output" "$(diff <(echo "$m") <(echo "$g") | head -5)"; fi
    else
      echo "  SKIP facts: mawk output equals gawk output (gawk not installed)"
    fi
  else
    echo "  SKIP $name (mawk not installed)"
  fi
fi

echo ""
echo "=== planner ac precondition: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
