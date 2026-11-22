#!/usr/bin/env bash
# test-planner-gate-ledger.sh — checks ticket-planner/gates/gate-ledger.tsv, the
# labelled record of every gate fire in dispatch rehearsal iterations 01–16
# (change seam-gate-safety, slice G3), and its read-only summary script.
#
#   - every row has the 15 columns, closed values and a consistent label/cause/
#     fixed/live set (a false row says whether its cause is still live on main)
#   - deep-dive D's corrections hold (F25 false, F43 debatable) and fires from
#     checker bugs already fixed (F12/F24, F22, F33, F52, F67) are never live
#   - each evidence pointer has the <file>:<line> shape; with
#     GATE_LEDGER_EVIDENCE_DIR set to the rehearsal folder (local only, never in
#     CI) the line exists and names the row's f_id, else its code
#   - gate-ledger-summary.sh counts what the ledger holds, lists the G4 demotion
#     candidates (pinned below: a ledger change that moves the list fails here
#     until the pin is updated), never lists a warn code or DEPENDENCY_CYCLE,
#     fails closed when it cannot read the class lists, writes nothing
#   - the corpus privacy scan passes over the gates directory
#
# Run: bash ticket-planner/lib/tests/test-planner-gate-ledger.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANNER_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GATES="${PLANNER_DIR}/gates"
LEDGER="${GATES}/gate-ledger.tsv"
SUMMARY="${GATES}/gate-ledger-summary.sh"

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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "=== gate ledger (seam-gate-safety G3) ==="

if [ ! -f "$LEDGER" ]; then
  fail "ledger exists" "no file at $LEDGER"
  echo "=== $PASS passed, $FAIL failed ==="
  exit 1
fi
grep -v '^#' "$LEDGER" | grep -v '^[[:space:]]*$' >"$WORK/rows"

echo "--- shape ---"
HEADER=$'iter\tgate\tround\tcode\tclass\toutcome\tunit\tcount\tlabel\tcause\tfixed\tlive\tf_id\tevidence\tnote'
if [ "$(head -1 "$WORK/rows")" = "$HEADER" ]; then
  pass "header row"
else
  fail "header row" "$(head -1 "$WORK/rows")"
fi
tail -n +2 "$WORK/rows" >"$WORK/data"
n=$(wc -l <"$WORK/data")
if [ "$n" -ge 100 ]; then pass "ledger holds the seed (${n} rows)"; else fail "ledger holds the seed" "${n} rows"; fi

problems=$(awk -F'\t' '
  function bad(m) { printf "row %d (%s %s %s): %s\n", NR, $1, $4, $7, m }
  NF != 15 { bad("has " NF " fields"); next }
  $1 !~ /^(0[1-9]|1[0-7]|05b)$/ { bad("iter " $1) }
  $2 !~ /^(crosscheck|draft|draft-crosscheck|draft-guard|refinement|dor-check)$/ { bad("gate " $2) }
  $3 !~ /^(-|[0-9]|[0-9]-[0-9])$/ { bad("round " $3) }
  $4 !~ /^[A-Z][A-Z0-9_]+$/ { bad("code " $4) }
  $5 !~ /^(block|warn|revert)$/ { bad("class " $5) }
  $6 !~ /^(halted|revised|rebutted|demoted|reverted|accepted|hand-fixed|logged|expected)$/ { bad("outcome " $6) }
  $7 == "" || $7 ~ /[\/ ]/ && $7 !~ /^\(/ { bad("unit " $7) }
  $8 !~ /^[1-9][0-9]*$/ { bad("count " $8) }
  $9 !~ /^(true|false|debatable)$/ { bad("label " $9) }
  $10 !~ /^(plan-gap|live-logic|checker-bug|upstream-bug|format|env|negative-control|unlabelled)$/ { bad("cause " $10) }
  $11 !~ /^(yes|partial|no|-)$/ { bad("fixed " $11) }
  $12 !~ /^(yes|no|-)$/ { bad("live " $12) }
  $13 !~ /^(-|F[0-9]+( F[0-9]+)*)$/ { bad("f_id " $13) }
  $14 !~ /^(findings\.md|iter-(0[1-9]|1[0-7]|05b)\/run-record\.md):[1-9][0-9]*$/ { bad("evidence " $14) }
  $15 == "" { bad("empty note") }
  ($5 == "warn") != ($6 == "logged") { bad("warn class and logged outcome go together") }
  ($5 == "revert") != ($2 == "draft-guard") { bad("revert class is a draft-guard fire") }
' "$WORK/data")
check "every row has 15 closed-value columns" "$problems"

problems=$(awk -F'\t' '
  function bad(m) { printf "row %d (%s %s %s): %s\n", NR, $1, $4, $7, m }
  $9 == "false" && $12 !~ /^(yes|no)$/ { bad("a false row must say live yes or no") }
  $9 != "false" && $12 != "-" { bad("only a false row carries live") }
  $9 == "false" && $10 ~ /^(plan-gap|negative-control|unlabelled)$/ { bad("false with cause " $10) }
  $9 == "true" && $10 !~ /^(plan-gap|negative-control)$/ { bad("true with cause " $10) }
  $10 == "unlabelled" && ($9 != "debatable" || $13 != "-") { bad("unlabelled is debatable with no f_id") }
  $10 ~ /^(checker-bug|upstream-bug|format|env)$/ && ($13 == "-" || $11 !~ /^(yes|partial|no)$/) { bad($10 " needs an f_id and fixed yes/partial/no") }
  $9 == "true" && $11 != "-" { bad("a true row has no fixed value") }
  $9 == "false" && $11 == "yes" && $12 != "no" { bad("fixed yes but live yes") }
  $9 == "false" && $11 == "no" && $12 != "yes" { bad("fixed no but live no") }
  $10 == "negative-control" && $7 != "negative-control" { bad("negative-control unit") }
' "$WORK/data")
check "label, cause, fixed and live agree" "$problems"

echo "--- corrections and the G4 rule ---"
problems=$(awk -F'\t' '
  $13 ~ /(^| )F25( |$)/ && $9 != "false" { print "F25 row labelled " $9 }
  $13 ~ /(^| )F43( |$)/ && $9 != "debatable" { print "F43 row labelled " $9 }
' "$WORK/data")
check "deep-dive D corrections: F25 false, F43 debatable" "$problems"
[ "$(awk -F'\t' '$13 ~ /F25|F43/' "$WORK/data" | wc -l)" -ge 2 ] && pass "F25 and F43 rows present" || fail "F25 and F43 rows present" "missing"
problems=$(awk -F'\t' '$13 ~ /(^| )F(12|22|24|33|52|67|80)( |$)/ && $12 != "no" { print $1 " " $4 " " $13 " live=" $12 }' "$WORK/data")
check "fires from fixed checker bugs (F12/F24, F22, F33, F52, F67, F80) are not live" "$problems"
problems=$(awk -F'\t' '$4 == "DEPENDENCY_CYCLE" && $12 == "yes" { print $1 " live=yes" }' "$WORK/data")
check "no live DEPENDENCY_CYCLE false fire" "$problems"

echo "--- evidence pointers ---"
EVID="${GATE_LEDGER_EVIDENCE_DIR:-}"
if [ -n "$EVID" ] && [ -d "$EVID" ]; then
  problems=""
  while IFS=$'\t' read -r iter _gate _round code _class _out _unit _cnt _label cause _fixed _live fid ev _note; do
    file="${ev%:*}" line="${ev##*:}"
    if [ ! -f "${EVID}/${file}" ]; then
      problems+="${iter} ${code}: no ${file}"$'\n'
      continue
    fi
    text=$(sed -n "${line}p" "${EVID}/${file}")
    if [ -z "$text" ]; then
      problems+="${iter} ${code}: ${ev} is empty or past the end"$'\n'
    elif [ "$fid" != "-" ]; then
      for f in $fid; do
        /usr/bin/grep -qE "(^|[^0-9A-Za-z])${f}([^0-9]|$)" <<<"$text" || problems+="${iter} ${code}: ${ev} does not name ${f}"$'\n'
      done
    elif [ "$cause" != "unlabelled" ]; then
      /usr/bin/grep -qF "$code" <<<"$text" || problems+="${iter} ${code}: ${ev} does not name the code"$'\n'
    fi
  done <"$WORK/data"
  check "every pointer resolves in ${EVID} and names its f_id or code" "$problems"
else
  echo "  (GATE_LEDGER_EVIDENCE_DIR not set: pointer resolution skipped; the rehearsal folder is local)"
fi

echo "--- summary script ---"
sum_before=$(sha256sum "$LEDGER")
out=$(bash "$SUMMARY" 2>"$WORK/err")
rc=$?
if [ "$rc" -eq 0 ]; then pass "summary runs (rc 0)"; else fail "summary runs" "rc ${rc}: $(cat "$WORK/err")"; fi
[ "$sum_before" = "$(sha256sum "$LEDGER")" ] && pass "summary leaves the ledger untouched" || fail "summary leaves the ledger untouched" "changed"

want_fires=$(awk -F'\t' '{ s += $8 } END { print s }' "$WORK/data")
got_fires=$(awk -F'\t' '$1 == "fires" { print $2 }' <<<"$out")
[ "$got_fires" = "$want_fires" ] && pass "fires total = sum of count (${want_fires})" || fail "fires total" "got ${got_fires}, want ${want_fires}"
for l in true false debatable; do
  want=$(awk -F'\t' -v l="$l" '$9 == l { s += $8 } END { print s + 0 }' "$WORK/data")
  got=$(awk -F'\t' -v l="$l" '/^== fires by label/ { on = 1; next } on && /^$/ { on = 0 } on && $1 == l { print $2 }' <<<"$out")
  [ "$got" = "$want" ] && pass "label ${l} = ${want}" || fail "label ${l}" "got ${got}, want ${want}"
done

cands=$(awk -F'\t' '/^== G4 demotion candidates/ { on = 1; getline; next } on && NF { print $1 " " $2 }' <<<"$out")
# Pinned on purpose: a ledger change that adds or drops a candidate shows here.
# G4 fixed F58 (draft-guard ASSUMPTION_INVALID) in the guard; its row is no
# longer live, so it left the list. Iter 16 added crosscheck
# RESOLUTION_NOT_PROPAGATED (F94); planner 0.60.0 fixed it (a native
# `### F<n>` section is one block), so its row is fixed=yes live=no and it
# left the list too.
want_cands=$'refinement MISSING_CORE_AC\ndraft EDGE_CASE_GAP\ndraft INTENT_AC_MISMATCH'
[ "$cands" = "$want_cands" ] && pass "G4 candidates are the pinned three" || fail "G4 candidates" "got: ${cands}"
problems=$(awk -F'\t' '$13 ~ /(^| )F58( |$)/ && !($11 == "yes" && $12 == "no") { print $1 " " $4 " fixed=" $11 " live=" $12 }' "$WORK/data")
check "F58 (ASSUMPTION_INVALID reuse) is fixed and not live" "$problems"

# Planted rows: a live false fire on a warn code, and on DEPENDENCY_CYCLE, are never
# candidates; a live false fire on a blocking code is.
cp "$LEDGER" "$WORK/planted.tsv"
printf '%s\n' \
  $'10\tcrosscheck\t-\tOWN_UNDECLARED_REF\twarn\tlogged\tx\t1\tfalse\tlive-logic\tno\tyes\t-\tfindings.md:1\tplanted' \
  $'10\tcrosscheck\t-\tDEPENDENCY_CYCLE\tblock\thalted\tx\t1\tfalse\tlive-logic\tno\tyes\t-\tfindings.md:1\tplanted' \
  $'10\tcrosscheck\t-\tSIGNALS_UNIFORM\tblock\thalted\tx\t2\tfalse\tlive-logic\tno\tyes\t-\tfindings.md:1\tplanted' >>"$WORK/planted.tsv"
pc=$(bash "$SUMMARY" --ledger "$WORK/planted.tsv" --section candidates | awk -F'\t' 'NR > 2 { print $1 " " $2 " " $8 }')
grep -q '^crosscheck SIGNALS_UNIFORM 2$' <<<"$pc" && pass "a live false fire on a blocking code is a candidate (window count 2)" || fail "planted blocking candidate" "$pc"
grep -qE 'OWN_UNDECLARED_REF|DEPENDENCY_CYCLE' <<<"$pc" && fail "warn codes and DEPENDENCY_CYCLE are never candidates" "$pc" || pass "warn codes and DEPENDENCY_CYCLE are never candidates"

mkdir -p "$WORK/emptylib"
GATE_LEDGER_PLANNER_LIB="$WORK/emptylib" bash "$SUMMARY" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && pass "unreadable class lists fail closed (rc 2)" || fail "unreadable class lists fail closed" "rc ${rc}"
printf '01\tcrosscheck\tonly-three-fields\n' >>"$WORK/planted.tsv"
bash "$SUMMARY" --ledger "$WORK/planted.tsv" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && pass "a malformed row fails (rc 1)" || fail "a malformed row fails" "rc ${rc}"
bash "$SUMMARY" --section nope >/dev/null 2>&1
[ $? -eq 2 ] && pass "unknown section is usage (rc 2)" || fail "unknown section is usage" "rc $?"

echo "--- demotions registry (seam-gate-safety G4) ---"
DEMOTIONS="${GATES}/gate-demotions.tsv"
REPO_ROOT="$(cd "${PLANNER_DIR}/.." && pwd -P)"
# Never demoted (design D3): the cycle and human-decision codes, and the DoR
# presence codes. dor/20-28 pin the test-data family; the other presence
# codes of dor-check.sh (hard and advisory) are listed with them.
PROTECTED_CODES="DEPENDENCY_CYCLE NEEDS_HUMAN_DECISION TEST_DATA_UNSOURCED TEST_DATA_MISSING TEST_DATA_UNSEEDED SCOPE_MISSING NAV_PATH_MISSING TEST_USER_MISSING TEST_USER_UNRESOLVED AC_MISSING REPRO_MISSING REPRO_NO_EXPECTED_ACTUAL INTENT_MISSING VPLAN_MISSING CATALOG_ABSENT"
DOR_CHECK="${REPO_ROOT}/ticket-auto-pipeline/lib/dor-check.sh"
problems=""
for c in $PROTECTED_CODES; do
  case "$c" in DEPENDENCY_CYCLE | NEEDS_HUMAN_DECISION) continue ;; esac
  grep -q "$c" "$DOR_CHECK" || problems+="${c} is not a dor-check.sh code"$'\n'
done
check "every protected DoR code exists in dor-check.sh" "$problems"

# _ledger_maxiter <ledger.tsv> — the highest iteration number (05b counts as 5).
_ledger_maxiter() {
  grep -v '^#' "$1" | grep -v '^[[:space:]]*$' | tail -n +2 | cut -f1 | sed 's/b$//; s/^0*//' | grep -E '^[0-9]+$' | sort -n | tail -1
}

# _demotion_problems <demotions.tsv> <ledger.tsv> — one line per broken rule,
# naming the row; nothing when every row holds.
_demotion_problems() {
  local dfile="$1" lfile="$2" rows ldata maxiter window wrc line nf code gate scope lrows fixture sunset reviewer r iter unit n hits live id fpath
  local -A seen=()
  rows=$(grep -v '^#' "$dfile" | grep -v '^[[:space:]]*$')
  if [ "$(head -1 <<<"$rows")" != $'code\tgate\tscope\tledger_rows\tfixture\tsunset\treviewer' ]; then
    echo "header row: $(head -1 <<<"$rows")"
    return 0
  fi
  ldata=$(grep -v '^#' "$lfile" | grep -v '^[[:space:]]*$' | tail -n +2)
  maxiter=$(_ledger_maxiter "$lfile")
  window=$(bash "$SUMMARY" --ledger "$lfile" --section candidates 2>/dev/null)
  wrc=$?
  window=$(awk -F'\t' 'NR > 2 { print $1 "\t" $2 "\t" $8 }' <<<"$window")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nf=$(awk -F'\t' '{ e = 0; for (i = 1; i <= NF; i++) if ($i == "") e = 1; print (e ? "empty" : NF) }' <<<"$line")
    if [ "$nf" != 7 ]; then
      echo "row '${line//$'\t'/ | }': needs exactly 7 non-empty columns"
      continue
    fi
    IFS=$'\037' read -r code gate scope lrows fixture sunset reviewer <<<"${line//$'\t'/$'\037'}"
    id="${code} (${gate} ${scope})"
    if [ -n "${seen["$code|$gate|$scope"]:-}" ]; then
      echo "${id}: duplicate row"
    fi
    seen["$code|$gate|$scope"]=1
    if [[ " $PROTECTED_CODES " == *" $code "* ]]; then echo "${id}: ${code} is never demoted"; fi
    [[ "$gate" =~ ^(crosscheck|draft|draft-crosscheck|draft-guard|refinement|dor-check)$ ]] || echo "${id}: gate ${gate}"
    [[ "$scope" =~ ^(code|variant:[A-Z][A-Z0-9_]*)$ ]] || echo "${id}: scope ${scope}"
    if [ "$reviewer" = "-" ]; then echo "${id}: no reviewer"; fi
    fpath=""
    if [[ "$fixture" != /* ]]; then fpath=$(realpath -e -- "${REPO_ROOT}/${fixture}" 2>/dev/null); fi
    if [ -z "$fpath" ] || [[ "$fpath" != "${REPO_ROOT}/"* ]] || [ ! -f "$fpath" ]; then
      echo "${id}: fixture ${fixture} is not a file in the repository"
    fi
    if [[ ! "$sunset" =~ ^[0-9][0-9]$ ]]; then
      echo "${id}: sunset ${sunset} is not a two-digit iteration"
    elif [ -z "$maxiter" ]; then
      echo "${id}: the ledger has no iteration to judge the sunset against"
    elif [ "$maxiter" -ge "$((10#$sunset))" ]; then
      echo "${id}: sunset ${sunset} has passed (ledger holds iteration ${maxiter}); remove or renew the row"
    fi
    live=0
    IFS=',' read -ra rs <<<"$lrows"
    for r in "${rs[@]}"; do
      r="${r// /}"
      iter="${r%%:*}" unit="${r#*:}"
      if [ -z "$r" ] || [ "$iter" = "$r" ]; then
        echo "${id}: ledger row '${r}' is not <iter>:<unit>"
        continue
      fi
      n=$(awk -F'\t' -v i="$iter" -v u="$unit" -v c="$code" -v g="$gate" '$1 == i && $7 == u && $4 == c && $2 == g' <<<"$ldata" | wc -l)
      hits=$(awk -F'\t' -v i="$iter" -v u="$unit" -v c="$code" -v g="$gate" '$1 == i && $7 == u && $4 == c && $2 == g && $9 == "false" && $12 == "yes"' <<<"$ldata" | wc -l)
      [ "$n" -gt 0 ] || echo "${id}: ledger row ${r} names no ${gate} ${code} fire"
      live=$((live + hits))
    done
    [ "$live" -gt 0 ] || echo "${id}: no listed ledger fire is false with live=yes"
    if [ "$scope" = code ]; then
      if [ "$wrc" -ne 0 ]; then
        echo "${id}: gate-ledger-summary.sh failed (rc ${wrc}); the 2-in-10 window cannot be judged"
      else
        n=$(awk -F'\t' -v c="$code" -v g="$gate" '$1 == g && $2 == c { print $3 }' <<<"$window")
        [ "${n:-0}" -ge 2 ] || echo "${id}: a whole-code demotion needs 2 live false fires in 10 (window max ${n:-0})"
      fi
    fi
  done < <(tail -n +2 <<<"$rows")
}

if [ -f "$DEMOTIONS" ]; then
  pass "gate-demotions.tsv exists"
else
  fail "gate-demotions.tsv exists" "no file at $DEMOTIONS"
fi
check "every demotion row holds (live false fire, fixture, sunset, reviewer, not protected)" "$(_demotion_problems "$DEMOTIONS" "$LEDGER")"
n=$(grep -v '^#' "$DEMOTIONS" | grep -v '^[[:space:]]*$' | tail -n +2 | wc -l)
# The ledger shows no code at the threshold today (G4 is mechanism only); a
# demotion row must change this pin in the same review.
[ "$n" -eq 0 ] && pass "no demotion today (zero rows)" || fail "no demotion today" "${n} rows"

# Planted rows, against a ledger copy with planted fires at the ledger's own
# latest iteration, so the cases depend neither on real rows nor on when the
# next iteration lands.
MAXI=$(_ledger_maxiter "$LEDGER")
PI=$(printf '%02d' "$MAXI")
SUN=$(printf '%02d' $((MAXI + 2)))
F58_FIX="ticket-planner/lib/tests/fixtures/draft-revise/f58-assumption-reuse/before.md"
_prow() { # _prow <code> <gate> <unit> <label> <cause> <fixed> <live>
  printf '%s\t%s\t-\t%s\tblock\thalted\t%s\t1\t%s\t%s\t%s\t%s\t-\tfindings.md:1\tplanted\n' "$PI" "$2" "$1" "$3" "$4" "$5" "$6" "$7"
}
{
  cat "$LEDGER"
  _prow SIGNALS_UNIFORM crosscheck planted-live false live-logic no yes
  _prow EDGE_CASE_GAP draft planted-true true plan-gap - -
  _prow SIGNALS_UNIFORM crosscheck planted-fixed false checker-bug yes no
} >"$WORK/dem-ledger.tsv"
{
  cat "$WORK/dem-ledger.tsv"
  _prow SIGNALS_UNIFORM crosscheck planted-live2 false live-logic no yes
} >"$WORK/dem-ledger-2.tsv"
_plant() { # _plant <name> <row> — a demotions copy with one row
  {
    cat "$DEMOTIONS"
    printf '%s\n' "$2"
  } >"$WORK/dem-$1.tsv"
}
_row() { # _row <code> <gate> <scope> <ledger_rows> [<fixture> [<sunset> [<reviewer>]]]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "${5-$F58_FIX}" "${6-$SUN}" "${7-reviewer-agent}"
}
GOOD=$(_row SIGNALS_UNIFORM crosscheck variant:PLANTED "${PI}:planted-live")
_plant good "$GOOD"
out=$(_demotion_problems "$WORK/dem-good.tsv" "$WORK/dem-ledger.tsv")
[ -z "$out" ] && pass "a variant row with a live false fire, fixture, open sunset and reviewer holds" || fail "planted good row" "$out"
_plant whole2 "$(_row SIGNALS_UNIFORM crosscheck code "${PI}:planted-live,${PI}:planted-live2")"
out=$(_demotion_problems "$WORK/dem-whole2.tsv" "$WORK/dem-ledger-2.tsv")
[ -z "$out" ] && pass "a whole-code row holds with 2 live false fires in 10" || fail "planted whole-code row" "$out"
_must_fail() { # _must_fail <name> <row> <expected-substring> [<ledger>]
  _plant "$1" "$2"
  out=$(_demotion_problems "$WORK/dem-$1.tsv" "${4:-$WORK/dem-ledger.tsv}")
  grep -qF -- "$3" <<<"$out" && pass "must fail: $1" || fail "must fail: $1" "${out:-no problem reported}"
}
_must_fail protected "$(_row DEPENDENCY_CYCLE crosscheck code "${PI}:planted-live")" "DEPENDENCY_CYCLE is never demoted"
_must_fail protected-dor "$(_row TEST_DATA_UNSOURCED dor-check code "${PI}:planted-live")" "TEST_DATA_UNSOURCED is never demoted"
_must_fail human "$(_row NEEDS_HUMAN_DECISION draft code "${PI}:planted-live")" "NEEDS_HUMAN_DECISION is never demoted"
_must_fail no-live "$(_row EDGE_CASE_GAP draft variant:X "${PI}:planted-true")" "no listed ledger fire is false with live=yes"
_must_fail fixed-bug "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:planted-fixed")" "no listed ledger fire is false with live=yes"
_must_fail no-row "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:nowhere")" "names no crosscheck SIGNALS_UNIFORM fire"
_must_fail wrong-gate "$(_row SIGNALS_UNIFORM draft variant:X "${PI}:planted-live")" "names no draft SIGNALS_UNIFORM fire"
_must_fail no-fixture "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:planted-live" ticket-planner/no-such-fixture.md)" "is not a file in the repository"
_must_fail escaping-fixture "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:planted-live" ../README.md)" "is not a file in the repository"
_must_fail absolute-fixture "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:planted-live" "${REPO_ROOT}/${F58_FIX}")" "is not a file in the repository"
_must_fail sunset-passed "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:planted-live" "$F58_FIX" "$PI")" "sunset ${PI} has passed"
_must_fail sunset-shape "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:planted-live" "$F58_FIX" iter-13)" "is not a two-digit iteration"
_must_fail no-reviewer "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:planted-live" "$F58_FIX" "$SUN" -)" "no reviewer"
_must_fail six-columns "$(_row SIGNALS_UNIFORM crosscheck variant:X "${PI}:planted-live" | cut -f1-6)" "needs exactly 7 non-empty columns"
_must_fail empty-cell "$(_row SIGNALS_UNIFORM crosscheck "" "${PI}:planted-live")" "needs exactly 7 non-empty columns"
_must_fail scope "$(_row SIGNALS_UNIFORM crosscheck everything "${PI}:planted-live")" "scope everything"
_must_fail whole-code-one "$(_row SIGNALS_UNIFORM crosscheck code "${PI}:planted-live")" "needs 2 live false fires in 10 (window max 1)"
_plant dup "$GOOD"
printf '%s\n' "$GOOD" >>"$WORK/dem-dup.tsv"
out=$(_demotion_problems "$WORK/dem-dup.tsv" "$WORK/dem-ledger.tsv")
grep -qF "duplicate row" <<<"$out" && pass "must fail: duplicate row" || fail "must fail: duplicate row" "${out:-no problem reported}"
# A fire from the sunset iteration expires a row that was open.
awk -F'\t' -v s="$SUN" 'BEGIN { OFS = "\t" } { print } !/^#/ && $7 == "planted-live" { $1 = s; $7 = "planted-later"; print }' "$WORK/dem-ledger.tsv" >"$WORK/dem-ledger-sun.tsv"
_must_fail expired "$GOOD" "sunset ${SUN} has passed (ledger holds iteration $((10#$SUN)))" "$WORK/dem-ledger-sun.tsv"
# A failed summary is reported for a whole-code row, never read as window 0.
SUMMARY_KEEP="$SUMMARY"
SUMMARY="$WORK/no-such-summary.sh"
_must_fail summary-failed "$(_row SIGNALS_UNIFORM crosscheck code "${PI}:planted-live")" "gate-ledger-summary.sh failed"
SUMMARY="$SUMMARY_KEEP"
printf '# empty\n%s\n' "$(grep -v '^#' "$LEDGER" | head -1)" >"$WORK/dem-ledger-empty.tsv"
_must_fail empty-ledger "$GOOD" "the ledger has no iteration" "$WORK/dem-ledger-empty.tsv"

echo "--- privacy ---"
if out=$(CORPUS_PRIVACY_DIRS="$GATES" bash "${SCRIPT_DIR}/test-corpus-privacy.sh" 2>&1); then
  pass "corpus privacy scan passes over gates/"
else
  fail "corpus privacy scan passes over gates/" "$(grep FAIL <<<"$out" | head -5)"
fi
if grep -q 'gates' "${SCRIPT_DIR}/test-corpus-privacy.sh"; then
  pass "test-corpus-privacy.sh scans */gates by default"
else
  fail "test-corpus-privacy.sh scans */gates by default" "no gates directory in its default list"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
