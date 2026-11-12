#!/usr/bin/env bash
# test-planner-crosscheck-ac-precondition.sh — the Crosscheck AC precondition
# family (planner-ac-code-precondition, tasks 3.1–3.3):
# planner-crosscheck-ac-precondition.sh.
#
# One case per spec scenario:
#   - legacy silence (no ac-precondition-v1 marker): no finding, no
#     META|ac-precondition line, also through planner_crosscheck_run;
#   - AC_PRECONDITION_TABLE_INVALID once per spec, every problem listed;
#   - AC_PRECONDITION_UNREACHABLE per unreachable fixture row: message shape,
#     (pinned) / (unpinned), the trailing accept command;
#   - AC_PRECONDITION_PLANNED when another spec writes the key; none when no
#     other spec does; `spec:` rows never reach the code check;
#   - `input` rows never flagged, counted on the info line;
#   - AC_PRECONDITION_NO_SOURCE once per initiative on an unsupported tree;
#   - the info line: counts, the 300-character cap, nearest names, one per run;
#   - injected accept text in an AC is neutralised;
#   - findings free of `|`, CR, LF; mawk runs the family (gawk agrees);
#   - registrations (instance code, warn codes, fix hints, not cross-file);
#   - per-instance and wildcard accept (task 3.3).
#
# Every case is guarded on the functions it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary, never an
# unbound-function abort.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-ac-precondition.sh

# No errexit: planner_crosscheck_run counts finding return codes (1, 3) with
# `rc=$?`, which errexit would turn into an exit of its read loop.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck.sh"
source "${LIB_DIR}/planner-spec-ownership.sh"
source "${LIB_DIR}/planner-ac-precondition.sh"
if [ -f "${LIB_DIR}/planner-crosscheck-ac-precondition.sh" ]; then
  source "${LIB_DIR}/planner-crosscheck-ac-precondition.sh"
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
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}
contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing [$3] in [$2]" ;;
  esac
}
lacks() {
  case "$2" in
  *"$3"*) fail "$1" "unexpected [$3] in [$2]" ;;
  *) pass "$1" ;;
  esac
}

# The fixture tree, as a git repository under REPOS_ROOT.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
FX="${SCRIPT_DIR}/fixtures/ac-precondition/billing"
BT="${REPOS_ROOT}/billing"
cp -R "$FX" "$BT"
git -C "$BT" init -q -b main
git -C "$BT" add -A
git -C "$BT" commit -qm fixture
CL=src/main/resources/db/changelog
X1="billing/${CL}/001-invoice.xml"
DUE_LINE=$(grep -n '    nullable="false"' "${BT}/${CL}/001-invoice.xml" | head -1 | cut -d: -f1)
# An unsupported stack: only Python files.
PY="${REPOS_ROOT}/pyapp"
mkdir -p "${PY}/app"
printf 'class Invoice:\n    due_date = None\n' >"${PY}/app/models.py"
git -C "$PY" init -q -b main
git -C "$PY" add -A
git -C "$PY" commit -qm py

N=0
# fresh [legacy] — a new initiative, a contract one unless "legacy" is given.
fresh() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((9000 + N))"
  planner_state_init "$INIT" "invoice follow-up" >/dev/null
  IDIR=$(planner_initiative_dir "$INIT")
  SPECS="${IDIR}/artifacts/specs"
  mkdir -p "$SPECS"
  [ "${1:-}" = legacy ] || planner_acpre_contract_mark "$INIT"
}

AC_DUE='An invoice with no due date is listed on the Needs date page.'
AC_BADGE='A disputed invoice shows a Disputed badge on the invoice list.'
AC_BIG='Invoices numbered above 3,000,000,000 show their number with separators.'
AC_CUST='Saving the invoice form without a customer shows "Customer is required".'
PH='| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|'
DUE_BASIS="code:billing/${CL}"

# row <criterion> <key> <mode> <requires> <basis>
row() { printf '| %s | `%s` | %s | %s | %s |' "$@"; }

# aspec <slug> <ac-lines> <preconditions-body> [<writes-rows>] [<labels>]
aspec() {
  local slug="$1" acs="$2" pre="$3" writes="${4:-}" labels="${5:-type:feature}" a
  {
    printf '# %s\n\n## Labels\n\n%s\n\n## Acceptance Criteria\n\n' "$slug" "$labels"
    while IFS= read -r a; do
      [ -n "$a" ] && printf -- '- [ ] %s\n' "$a"
    done <<<"$acs"
    printf '\n'
    if [ -n "$writes" ]; then printf '## Writes\n\n| Key | Op |\n|-----|----|\n%s\n\n' "$writes"; fi
    if [ "$pre" != __NONE__ ]; then printf '## Preconditions\n\n%s\n' "$pre"; fi
  } >"${SPECS}/${slug}.md"
}

run() { planner_crosscheck_ac_precondition "$INIT" 2>/dev/null | sed 's/^planner-crosscheck-ac-precondition: //' || true; }
codes() { run | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//'; }
of() { run | grep "^$1 " || true; }
infos() { grep '|META|ac-precondition|' "$(planner_state_log "$INIT")" || true; }
info_last() { infos | tail -1 | cut -d'|' -f5-; }
lineof() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
# latest — the lines of the latest Crosscheck attempt.
latest() {
  local log start
  log=$(planner_state_log "$INIT")
  start=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  tail -n "+$((start + 1))" "$log"
}

# ── Legacy ────────────────────────────────────────────────────────────────────

echo "=== legacy ==="

name="legacy initiative is silent"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh legacy
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")"
  aspec broken "$AC_DUE" __NONE__
  rc=0
  out=$(planner_crosscheck_ac_precondition "$INIT" 2>&1) || rc=$?
  check "$name: rc" "$rc" "0"
  check "$name: no output" "$out" ""
  check "$name: no META line" "$(infos)" ""
fi

name="legacy initiative adds nothing to planner_crosscheck_run"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh legacy
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  check "$name" "$(grep -c 'AC_PRECONDITION_\||ac-precondition|' "$(planner_state_log "$INIT")" || true)" "0"
fi

# ── TABLE_INVALID ─────────────────────────────────────────────────────────────

echo "=== table invalid ==="

name="AC_PRECONDITION_TABLE_INVALID once per spec, every problem listed"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec bad-rows "$AC_DUE
$AC_BADGE" "${PH}
$(row "$AC_DUE" invoice.due_date given null "$DUE_BASIS")
$(row "$AC_BADGE" invoice.status state value:Disputed "$DUE_BASIS")
$(row "$AC_DUE" invoice state null "$DUE_BASIS")
$(row "No such criterion." invoice.due_date state null "$DUE_BASIS")"
  aspec no-section "$AC_DUE" __NONE__
  aspec fine "$AC_DUE" "None."
  F="${SPECS}/bad-rows.md"
  out=$(of AC_PRECONDITION_TABLE_INVALID)
  check "$name: one per bad spec" "$(grep -c . <<<"$out")" "2"
  b=$(grep 'specs/bad-rows.md' <<<"$out")
  l1=$(lineof "$F" '| given |')
  contains "$name: locus is the first bad line" "$b" "AC_PRECONDITION_TABLE_INVALID specs/bad-rows.md:${l1} "
  contains "$name: mode" "$b" "line ${l1} mode"
  contains "$name: requires" "$b" "line $(lineof "$F" 'value:Disputed') requires"
  contains "$name: key" "$b" "line $(lineof "$F" '`invoice` |') key"
  contains "$name: criterion" "$b" "line $(lineof "$F" 'No such criterion.') criterion not found"
  contains "$name: missing section" "$(grep 'specs/no-section.md' <<<"$out")" "specs/no-section.md ## Preconditions is missing"
  lacks "$name: None. is valid" "$out" "specs/fine.md"
  rc=0
  planner_crosscheck_ac_precondition "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: blocks" "$rc" "1"
fi

name="Basis rules reach TABLE_INVALID with their hint"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec invoice-dates "$AC_DUE" "None." '| `invoice.due_date` | update |'
  aspec self-basis "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null spec:self-basis)"
  aspec not-dep "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null spec:invoice-dates)"
  out=$(of AC_PRECONDITION_TABLE_INVALID)
  contains "$name: self without a write" "$(grep 'self-basis' <<<"$out")" "basis-spec-no-write"
  contains "$name: not a dependency" "$(grep 'not-dep' <<<"$out")" "basis-not-a-dependency — add blocked-by:invoice-dates to ## Labels"
fi

# ── UNREACHABLE ───────────────────────────────────────────────────────────────

echo "=== unreachable ==="

name="AC_PRECONDITION_UNREACHABLE for each unreachable fixture row"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec needs-date "$AC_DUE
$AC_BADGE
$AC_BIG" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")
$(row "$AC_BADGE" invoice.status state value:overdue code:billing/src)
$(row "$AC_BIG" invoice.number state number:3000000000 "$DUE_BASIS")"
  F="${SPECS}/needs-date.md"
  out=$(of AC_PRECONDITION_UNREACHABLE)
  check "$name: three" "$(grep -c . <<<"$out")" "3"
  check "$name: null message" "$(grep 'invoice.due_date' <<<"$out")" \
    "AC_PRECONDITION_UNREACHABLE specs/needs-date.md:$(lineof "$F" '`invoice.due_date`') '${AC_DUE}' needs invoice.due_date null, but ${X1}:${DUE_LINE} declares it NOT NULL (unpinned). Fix: change the criterion, mark it Mode input if the test submits the value, or set Basis spec:<slug> for a spec that changes the schema. Accept: --accept AC_PRECONDITION_UNREACHABLE@needs-date/invoice.due_date/null:\"<reason>\""
  contains "$name: enum" "$(grep 'invoice.status' <<<"$out")" "needs invoice.status value:overdue, but billing/src/main/java/com/example/billing/Invoice.java:"
  contains "$name: enum constants" "$(grep 'invoice.status' <<<"$out")" "allows only DRAFT,SENT,PAID (unpinned)"
  contains "$name: enum token" "$(grep 'invoice.status' <<<"$out")" '--accept AC_PRECONDITION_UNREACHABLE@needs-date/invoice.status/value=overdue:"<reason>"'
  contains "$name: number" "$(grep 'invoice.number' <<<"$out")" "is an integer column with max 2147483647 (unpinned)"
  contains "$name: number token" "$(grep 'invoice.number' <<<"$out")" '@needs-date/invoice.number/number=3000000000:"<reason>"'
  check "$name: info counts" "$(info_last)" "3 checked, 0 unchecked, 0 planned, 0 input"
fi

name="a pinned tree says (pinned)"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  planner_state_write "$INIT" META discovery repo-ref "billing@main@$(git -C "$BT" rev-parse HEAD)" >/dev/null
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")"
  contains "$name" "$(of AC_PRECONDITION_UNREACHABLE)" "declares it NOT NULL (pinned)."
fi

name="a reachable row gives no finding"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec paid "$AC_BADGE" "${PH}
$(row "$AC_BADGE" invoice.status state value:paid code:billing/src)"
  check "$name" "$(run)" ""
  check "$name: counted" "$(info_last)" "1 checked, 0 unchecked, 0 planned, 0 input"
fi

# ── PLANNED and spec: rows ────────────────────────────────────────────────────

echo "=== planned ==="

name="AC_PRECONDITION_PLANNED when another spec writes the key (any op)"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec invoice-dates "$AC_DUE" "None." '| `invoice.due_date` | append |'
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")"
  check "$name: codes" "$(codes)" "AC_PRECONDITION_PLANNED"
  out=$(of AC_PRECONDITION_PLANNED)
  contains "$name: names the writer" "$out" "but invoice-dates write invoice.due_date — set Basis spec:invoice-dates if that spec changes the schema"
  lacks "$name: no accept command" "$out" "--accept"
  rc=0
  planner_crosscheck_ac_precondition "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: never blocks" "$rc" "0"
  check "$name: counted planned" "$(info_last)" "0 checked, 0 unchecked, 1 planned, 0 input"
fi

name="an entity write in another spec downgrades too; the spec's own write does not"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec invoice-import "$AC_DUE" "None." '| `invoice` | create |'
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")" '| `invoice.due_date` | update |'
  check "$name: entity" "$(codes)" "AC_PRECONDITION_PLANNED"
  fresh
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")" '| `invoice.due_date` | update |'
  aspec other "$AC_BADGE" "None." '| `customer.name` | update |'
  check "$name: own write" "$(codes)" "AC_PRECONDITION_UNREACHABLE"
fi

name="a valid spec: row never reaches the code check"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec invoice-dates "$AC_DUE" "None." '| `invoice.due_date` | update |'
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null spec:invoice-dates)" "" "type:feature, blocked-by:invoice-dates"
  check "$name: no finding" "$(run)" ""
  check "$name: counted planned" "$(info_last)" "0 checked, 0 unchecked, 1 planned, 0 input"
fi

# ── input rows ────────────────────────────────────────────────────────────────

echo "=== input ==="

name="input rows are never flagged, counted on the info line"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec invoice-form "$AC_CUST
$AC_DUE" "${PH}
$(row "$AC_CUST" invoice.customer_id input null '—')
$(row "$AC_DUE" invoice.due_date input null '—')"
  check "$name: no finding" "$(run)" ""
  check "$name: info" "$(info_last)" "0 checked, 0 unchecked, 0 planned, 2 input"
fi

# ── NO_SOURCE ─────────────────────────────────────────────────────────────────

echo "=== no source ==="

name="AC_PRECONDITION_NO_SOURCE once per initiative on an unsupported tree"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec py-a "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null code:pyapp/app)"
  aspec py-b "$AC_BADGE" "${PH}
$(row "$AC_BADGE" invoice.status state value:x code:pyapp/app)"
  out=$(run)
  check "$name: once" "$(grep -c '^AC_PRECONDITION_NO_SOURCE ' <<<"$out")" "1"
  contains "$name: lists rows" "$out" "py-a/invoice.due_date, py-b/invoice.status"
  rc=0
  planner_crosscheck_ac_precondition "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: never blocks" "$rc" "0"
  check "$name: unchecked count" "$(info_last | cut -d: -f1)" "0 checked, 2 unchecked, 0 planned, 0 input"
fi

name="no NO_SOURCE when one row found a source"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec py-a "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null code:pyapp/app)"
  aspec paid "$AC_BADGE" "${PH}
$(row "$AC_BADGE" invoice.status state value:paid code:billing/src)"
  check "$name" "$(codes)" ""
fi

name="no NO_SOURCE when no row was scanned"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec gone "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null code:nosuchrepo/src)"
  check "$name" "$(codes)" ""
  check "$name: reason on the info line" "$(info_last)" "0 checked, 1 unchecked, 0 planned, 0 input: gone/invoice.due_date (repository not found)"
fi

# ── Info line ─────────────────────────────────────────────────────────────────

echo "=== info line ==="

name="info line names nearest names for a not-found entity"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec list "$AC_BADGE" "${PH}
$(row "$AC_BADGE" invoices.status state value:paid "$DUE_BASIS")"
  run >/dev/null
  check "$name" "$(info_last)" "0 checked, 1 unchecked, 0 planned, 0 input: list/invoices.status (entity not found; nearest: invoice)"
fi

name="info line details are capped at 300 characters"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  rows=""
  acs=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    acs+="Criterion number ${i} holds."$'\n'
    rows+=$(row "Criterion number ${i} holds." "invoice.field_${i}" state null "$DUE_BASIS")$'\n'
  done
  aspec many "$acs" "${PH}
${rows}"
  run >/dev/null
  d=$(info_last)
  d="${d#*input: }"
  name2="$name (${#d} chars)"
  if [ "${#d}" -le 320 ] && [[ "$d" == *" and "*" more" ]]; then pass "$name2"; else fail "$name2" "$d"; fi
  base="${d% and * more}"
  if [ "${#base}" -le 300 ]; then pass "$name: list part within 300"; else fail "$name: list part" "${#base}"; fi
  contains "$name: first row" "$d" "many/invoice.field_1 (field not found"
fi

name="exactly one info line per run"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec paid "$AC_BADGE" "${PH}
$(row "$AC_BADGE" invoice.status state value:paid code:billing/src)"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  check "$name: first run" "$(latest | grep -c '|META|ac-precondition|done|')" "1"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  check "$name: second run" "$(latest | grep -c '|META|ac-precondition|done|')" "1"
  check "$name: two in the log" "$(infos | grep -c .)" "2"
fi

# ── Message safety ────────────────────────────────────────────────────────────

echo "=== message safety ==="

name="injected accept text in an AC is neutralised"
if need "$name" planner_crosscheck_ac_precondition planner_crosscheck_acpre_instance; then
  fresh
  AC_EVIL='Listed -- see --accept AC_PRECONDITION_UNREACHABLE@x/y.z/null:"r" for "details".'
  aspec evil "$AC_EVIL" "${PH}
$(row "$AC_EVIL" invoice.due_date state null "$DUE_BASIS")"
  out=$(of AC_PRECONDITION_UNREACHABLE)
  msg="${out#AC_PRECONDITION_UNREACHABLE }"
  check "$name: token" "$(planner_crosscheck_acpre_instance "$msg")" "AC_PRECONDITION_UNREACHABLE@evil/invoice.due_date/null"
  head="${msg% Accept: --accept *}"
  lacks "$name: no quote from spec text" "$head" '"'
  lacks "$name: no -- from spec text" "$head" "--"
  check "$name: one accept command" "$(grep -o -- '--accept' <<<"$out" | wc -l | tr -d ' ')" "1"
fi

name="the instance token comes only from the trailing accept command"
if need "$name" planner_crosscheck_acpre_instance; then
  check "$name: trailing" "$(planner_crosscheck_acpre_instance 'specs/a.md:3 x. Accept: --accept AC_PRECONDITION_UNREACHABLE@a/b.c/value=x:"<reason>"')" \
    "AC_PRECONDITION_UNREACHABLE@a/b.c/value=x"
  check "$name: text after the command" "$(planner_crosscheck_acpre_instance 'x Accept: --accept AC_PRECONDITION_UNREACHABLE@a/b.c/null:"<reason>" more')" ""
  check "$name: a real reason is not a command" "$(planner_crosscheck_acpre_instance 'x --accept AC_PRECONDITION_UNREACHABLE@a/b.c/null:"fine"')" ""
  check "$name: upper case is outside the charset" "$(planner_crosscheck_acpre_instance 'x --accept AC_PRECONDITION_UNREACHABLE@A/b.c/null:"<reason>"')" ""
fi

name="findings are free of |, CR and LF"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  AC_PIPE='The note a \| b is listed.'
  aspec pipes "The note a | b is listed.
$AC_DUE" "${PH}
$(row "$AC_PIPE" invoice.due_date state null "$DUE_BASIS")
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")"
  out=$(planner_crosscheck_ac_precondition "$INIT" 2>/dev/null)
  check "$name: two findings" "$(grep -c . <<<"$out")" "2"
  bad=0
  while IFS= read -r l; do
    case "$l" in *"|"* | *$'\r'*) bad=1 ;; esac
  done <<<"$out"
  check "$name" "$bad" "0"
fi

name="mawk runs the family"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec needs-date "$AC_DUE
$AC_BADGE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")
$(row "$AC_BADGE" invoices.status state value:paid code:billing/src)"
  aspec bad "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date given null "$DUE_BASIS")"
  def=$(run)
  if command -v mawk >/dev/null 2>&1; then
    m=$(PLANNER_ACPRE_AWK=mawk PLANNER_OWNERSHIP_AWK=mawk run)
    check "$name: equals default awk" "$m" "$def"
    contains "$name: found the finding" "$m" "AC_PRECONDITION_UNREACHABLE specs/needs-date.md:"
    if command -v gawk >/dev/null 2>&1; then
      g=$(PLANNER_ACPRE_AWK=gawk PLANNER_OWNERSHIP_AWK=gawk run)
      check "$name: gawk agrees with mawk" "$g" "$m"
    else
      echo "  SKIP gawk agrees with mawk (gawk not installed)"
    fi
  else
    echo "  SKIP mawk runs the family (mawk not installed)"
  fi
fi

# ── Registrations ─────────────────────────────────────────────────────────────

echo "=== registrations ==="

name="AC_PRECONDITION_UNREACHABLE is an instance code"
check "$name: lib" "$(planner_crosscheck_instance_field AC_PRECONDITION_UNREACHABLE lib 2>/dev/null)" "planner-crosscheck-ac-precondition.sh"
check "$name: parse" "$(planner_crosscheck_instance_field AC_PRECONDITION_UNREACHABLE parse 2>/dev/null)" "planner_crosscheck_acpre_accept_parse"
check "$name: instance" "$(planner_crosscheck_instance_field AC_PRECONDITION_UNREACHABLE instance 2>/dev/null)" "planner_crosscheck_acpre_instance"
check "$name: note" "$(planner_crosscheck_instance_field AC_PRECONDITION_UNREACHABLE note 2>/dev/null)" "_planner_stop_acpre_question"
if planner_crosscheck_is_instance_code AC_PRECONDITION_TABLE_INVALID; then
  fail "$name: TABLE_INVALID stays code-wide" "listed"
else
  pass "$name: TABLE_INVALID stays code-wide"
fi

name="the two warnings are warn codes"
for c in AC_PRECONDITION_PLANNED AC_PRECONDITION_NO_SOURCE; do
  contains "$name: $c" " ${PLANNER_CROSSCHECK_WARN_CODES} " " $c "
done

name="no AC precondition code is cross-file"
lacks "$name" " ${PLANNER_CROSSCHECK_CROSS_FILE_CODES} " "AC_PRECONDITION"

name="fix hints"
for c in AC_PRECONDITION_TABLE_INVALID AC_PRECONDITION_UNREACHABLE AC_PRECONDITION_UNREACHABLE@x/y.z/null; do
  h=$(planner_crosscheck_fix_hint "$c")
  case "$h" in
  "no canned hint"* | "") fail "$name: $c" "$h" ;;
  *) pass "$name: $c" ;;
  esac
done

# ── Crosscheck run ────────────────────────────────────────────────────────────

echo "=== crosscheck run ==="

name="the family runs inside planner_crosscheck_run, after the ownership family"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  planner_ownership_contract_mark "$INIT"
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")"
  aspec invoice-dates "$AC_BADGE" "None."
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: blocks" "$rc" "1"
  lines=$(latest)
  contains "$name: fail line" "$lines" "|META|crosscheck|fail|AC_PRECONDITION_UNREACHABLE specs/needs-date.md:"
  o=$(grep -n '|fail|OWN_TABLE_INVALID ' <<<"$lines" | tail -1 | cut -d: -f1)
  a=$(grep -n '|META|ac-precondition|done|' <<<"$lines" | head -1 | cut -d: -f1)
  u=$(grep -n '|fail|AC_PRECONDITION_UNREACHABLE ' <<<"$lines" | head -1 | cut -d: -f1)
  if [ -n "$o" ] && [ -n "$a" ] && [ -n "$u" ] && [ "$o" -lt "$a" ] && [ "$a" -lt "$u" ]; then pass "$name: order"; else fail "$name: order" "ownership=$o info=$a finding=$u"; fi
fi

name="PLANNED and NO_SOURCE are warn lines through planner_crosscheck_run"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec invoice-dates "$AC_BADGE" "None." '| `invoice.due_date` | update |'
  aspec needs-date "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null "$DUE_BASIS")"
  aspec py-a "$AC_DUE" "${PH}
$(row "$AC_DUE" invoice.due_date state null code:pyapp/app)"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  lines=$(latest)
  contains "$name: planned" "$lines" "|META|crosscheck|warn|info AC_PRECONDITION_PLANNED specs/needs-date.md:"
  check "$name: no NO_SOURCE (one row found a source)" "$(grep -c 'AC_PRECONDITION_NO_SOURCE' <<<"$lines" || true)" "0"
  check "$name: no fail" "$(grep -c '|fail|AC_PRECONDITION_' <<<"$lines" || true)" "0"
fi

# ── Accept (task 3.3) ─────────────────────────────────────────────────────────

echo "=== accept ==="

TOK1="AC_PRECONDITION_UNREACHABLE@needs-date/invoice.due_date/null"
TOK2="AC_PRECONDITION_UNREACHABLE@badge/invoice.status/value=disputed"

name="accept parse: the per-instance forms"
if need "$name" planner_crosscheck_acpre_accept_parse; then
  check "$name: null" "$(planner_crosscheck_acpre_accept_parse "${TOK1}:\"backfill runs first\"")" "${TOK1}	backfill runs first"
  check "$name: value" "$(planner_crosscheck_acpre_accept_parse "${TOK2}:ok")" "${TOK2}	ok"
  check "$name: number" "$(planner_crosscheck_acpre_accept_parse 'AC_PRECONDITION_UNREACHABLE@big/invoice.number/number=-2147483649:"x"')" \
    "AC_PRECONDITION_UNREACHABLE@big/invoice.number/number=-2147483649	x"
  check "$name: decimal" "$(planner_crosscheck_acpre_accept_parse 'AC_PRECONDITION_UNREACHABLE@big/invoice.amount/number=250000.50:"x"')" \
    "AC_PRECONDITION_UNREACHABLE@big/invoice.amount/number=250000.50	x"
fi

name="accept parse refuses bad forms"
if need "$name" planner_crosscheck_acpre_accept_parse; then
  for bad in \
    'AC_PRECONDITION_UNREACHABLE@a/invoice/null:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a/Invoice.x/null:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a/invoice.x/value=Disputed:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a/invoice.x/value:x:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a/invoice.x/length=5:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a/invoice.x/number=1e5:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a b/invoice.x/null:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a/invoice.x:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a/x/invoice.x/null:"r"' \
    'AC_PRECONDITION_UNREACHABLE@-a/invoice.x/null:"r"' \
    'AC_PRECONDITION_UNREACHABLE@a/invoice.x/null:""' \
    'AC_PRECONDITION_UNREACHABLE@a/invoice.x/null:"  "'; do
    rc=0
    planner_crosscheck_acpre_accept_parse "$bad" >/dev/null 2>&1 || rc=$?
    check "$name: $bad" "$rc" "1"
  done
  rc=0
  err=$(planner_crosscheck_acpre_accept_parse 'AC_PRECONDITION_UNREACHABLE:"all fine"' 2>&1 >/dev/null) || rc=$?
  check "$name: code-wide" "$rc" "1"
  contains "$name: names the per-instance form" "$err" 'AC_PRECONDITION_UNREACHABLE@<slug>/<key>/<requires>:"<reason>"'
  contains "$name: names the wildcard form" "$err" 'AC_PRECONDITION_UNREACHABLE@*:"<reason>"'
  rc=0
  planner_crosscheck_acpre_accept_parse 'AC_PRECONDITION_UNREACHABLE' >/dev/null 2>&1 || rc=$?
  check "$name: bare code" "$rc" "1"
fi

# two_unreachable — needs-date (null on due_date) and badge (disputed status).
two_unreachable() {
  aspec needs-date "${1:-$AC_DUE}" "${PH}
$(row "${1:-$AC_DUE}" invoice.due_date state null "$DUE_BASIS")"
  aspec badge "$AC_BADGE" "${PH}
$(row "$AC_BADGE" invoice.status state value:disputed code:billing/src)"
}

name="one instance accepted, another still blocks"
if need "$name" planner_crosscheck_ac_precondition planner_crosscheck_acpre_accept_parse; then
  fresh
  two_unreachable
  parsed=$(planner_crosscheck_acpre_accept_parse "${TOK1}:\"backfill sets due dates first\"")
  planner_crosscheck_accept_set "$INIT" "$(cut -f1 <<<"$parsed")" "$(cut -f2 <<<"$parsed")"
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  lines=$(latest)
  check "$name: still blocks" "$rc" "1"
  contains "$name: first accepted" "$lines" "|META|crosscheck|accepted|${TOK1} specs/needs-date.md:"
  contains "$name: second fails" "$lines" "|META|crosscheck|fail|AC_PRECONDITION_UNREACHABLE specs/badge.md:"
  check "$name: one fail" "$(grep -c '|fail|AC_PRECONDITION_UNREACHABLE ' <<<"$lines")" "1"
fi

name="a code-wide accept record does not silence the instance code"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  two_unreachable
  planner_crosscheck_accept_set "$INIT" AC_PRECONDITION_UNREACHABLE "all fine"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  check "$name" "$(latest | grep -c '|fail|AC_PRECONDITION_UNREACHABLE ')" "2"
fi

name="an instance accept survives an AC extension"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  two_unreachable
  planner_crosscheck_accept_set "$INIT" "$TOK1" "backfill first"
  two_unreachable "${AC_DUE} The page sorts by invoice number."
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  contains "$name" "$(latest)" "|META|crosscheck|accepted|${TOK1} specs/needs-date.md:"
fi

name="AC_PRECONDITION_TABLE_INVALID keeps its code-wide accept"
if need "$name" planner_crosscheck_ac_precondition; then
  fresh
  aspec no-section "$AC_DUE" __NONE__
  planner_crosscheck_accept_set "$INIT" AC_PRECONDITION_TABLE_INVALID "drafted by hand"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  contains "$name" "$(latest)" "|META|crosscheck|accepted|AC_PRECONDITION_TABLE_INVALID specs/no-section.md"
fi

name="wildcard accept expands per current instance; a new instance still fails"
if need "$name" planner_crosscheck_ac_precondition && [ -f "${LIB_DIR}/planner-invocation.sh" ]; then
  source "${LIB_DIR}/planner-invocation.sh"
  fresh
  two_unreachable
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  rc=0
  { planner_flags_parse resume "$INIT" --accept 'AC_PRECONDITION_UNREACHABLE@*:"known gaps"' &&
    planner_flags_persist "$INIT"; } >/dev/null 2>&1 || rc=$?
  log=$(planner_state_log "$INIT")
  check "$name: persisted" "$rc" "0"
  check "$name: one record per instance" \
    "$(grep '|META|crosscheck|accepted|' "$log" | cut -d'|' -f5- | LC_ALL=C sort | paste -sd';' -)" \
    "${TOK2} known gaps;${TOK1} known gaps"
  check "$name: no @* record" "$(grep -c 'accepted|AC_PRECONDITION_UNREACHABLE@\*' "$log" || true)" "0"
  aspec big "$AC_BIG" "${PH}
$(row "$AC_BIG" invoice.number state number:3000000000 "$DUE_BASIS")"
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  lines=$(latest)
  check "$name: blocks on the new one" "$rc" "1"
  check "$name: only the new one fails" "$(grep '|fail|AC_PRECONDITION_UNREACHABLE ' <<<"$lines" | grep -c 'specs/big.md')" "1"
  check "$name: two accepted" "$(grep -c '|accepted|AC_PRECONDITION_UNREACHABLE@' <<<"$lines")" "2"
fi

name="per-instance accept through --accept"
if need "$name" planner_crosscheck_ac_precondition && declare -f planner_flags_parse >/dev/null; then
  fresh
  two_unreachable
  rc=0
  { planner_flags_parse resume "$INIT" --accept "${TOK2}:\"dispute ships in this epic\"" &&
    planner_flags_persist "$INIT"; } >/dev/null 2>&1 || rc=$?
  check "$name: persisted" "$rc" "0"
  contains "$name: record" "$(grep '|accepted|' "$(planner_state_log "$INIT")")" "|META|crosscheck|accepted|${TOK2} dispute ships in this epic"
fi

name="the code-wide accept form is refused at parse time"
if need "$name" planner_crosscheck_ac_precondition && declare -f planner_flags_parse >/dev/null; then
  fresh
  rc=0
  err=$(planner_flags_parse resume "$INIT" --accept 'AC_PRECONDITION_UNREACHABLE:"fine"' 2>&1 >/dev/null) || rc=$?
  check "$name" "$rc" "1"
  contains "$name: wildcard named" "$err" 'AC_PRECONDITION_UNREACHABLE@*:"<reason>"'
fi

echo ""
echo "=== planner crosscheck ac-precondition: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
