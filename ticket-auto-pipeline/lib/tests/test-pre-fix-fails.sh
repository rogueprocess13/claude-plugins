#!/usr/bin/env bash
# test-pre-fix-fails.sh — lib/pre-fix-fails.sh (openspec change
# pre-fix-fails-gate): the pre-fix tree, the verdict rules, the flag.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PFF="$LIB_DIR/pre-fix-fails.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unset PRE_FIX_FAILS PRE_FIX_FAILS_TIMEOUT REPOS_ROOT LOG_FILE TAP_LOG CLAUDE_LOG_FILE TICKET_ID
unset BE_SERVICES BE_TEST_RUNNER FE_TEST_CMD
export BE_TEST_CMD="bash runtests.sh"
export TICKET_TMP_DIR="$WORK/tmp"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0
FAIL=0
_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# The stub runner. VALUE comes from src/calc.txt; every tests/*.cases line is
# "<Class> <method> <expect> [error|needs:<file>|sleep]"; expect `any` always
# passes. tests/NOREPORT means exit 0 with no report. A missing needs: file
# exits 2 with no report (a build failure).
_runner() {
  cat <<'SH'
#!/usr/bin/env bash
v=$(cat src/calc.txt)
[ -f tests/NOREPORT ] && exit 0
mkdir -p target/reports
out=target/reports/TEST-cases.xml
rc=0
body=""
for f in tests/*.cases; do
  [ -f "$f" ] || continue
  while read -r cls m exp kind; do
    [ -n "$cls" ] || continue
    case "$kind" in
    needs:*) [ -f "${kind#needs:}" ] || exit 2 ;;
    sleep) [ "$v" = 1 ] && sleep 20 ;;
    esac
    if [ "$exp" = any ] || [ "$exp" = "$v" ]; then
      body="$body<testcase classname=\"com.x.$cls\" name=\"$m\"/>"
    elif [ "$kind" = error ]; then
      body="$body<testcase classname=\"com.x.$cls\" name=\"$m\"><error message=\"boom\"/></testcase>"
      rc=1
    else
      body="$body<testcase classname=\"com.x.$cls\" name=\"$m\"><failure message=\"want $exp got $v\"/></testcase>"
      rc=1
    fi
  done <"$f"
done
printf '<testsuite>%s</testsuite>\n' "$body" >"$out"
exit $rc
SH
}

# _repo <case> — a repo at main (calc=1, one passing case) checked out on
# branch fix with the fix (calc=2) uncommitted. Prints the repo path.
_repo() {
  local r="$WORK/$1/repo"
  mkdir -p "$r/src" "$r/tests"
  git -C "$r" init -q -b main
  _runner >"$r/runtests.sh"
  echo 1 >"$r/src/calc.txt"
  echo "CalcTest existing any" >"$r/tests/Calc.cases"
  printf 'target/\n' >"$r/.gitignore"
  git -C "$r" add -A
  git -C "$r" commit -qm base
  git -C "$r" checkout -qb fix
  echo 2 >"$r/src/calc.txt"
  echo "$r"
}

# _check <repo> <name>... — the CLI's stdout.
_check() {
  local r="$1" args=() n
  shift
  for n in "$@"; do args+=(--test "$n"); done
  bash "$PFF" check CRE-1 --worktree "$r" --base-ref main --claude-md /nonexistent "${args[@]}" 2>/dev/null
}

_verdict() { sed -n 's/^PRE_FIX_VERDICT=//p' <<<"$1"; }
_reason() { sed -n 's/^PRE_FIX_REASON=//p' <<<"$1"; }

_clean_after() {
  local r="$1"
  [ ! -e "$(dirname "$r")/.pre-fix-repo" ] &&
    [ "$(git -C "$r" worktree list | wc -l)" -eq 1 ]
}

test_proved_untracked_test_file() {
  local r out st_before
  r=$(_repo proved)
  echo "CalcTest fixed 2" >"$r/tests/Fix.cases" # untracked
  st_before=$(git -C "$r" status --porcelain)
  out=$(_check "$r" CalcTest.fixed)
  [ "$(_verdict "$out")" = proved ] && [ "$(_reason "$out")" = ok ] &&
    grep -q $'^PRE_FIX_TEST\tCalcTest.fixed\tfailed\tpassed$' <<<"$out" &&
    [ "$(git -C "$r" status --porcelain)" = "$st_before" ] &&
    [ "$(cat "$r/src/calc.txt")" = 2 ] && _clean_after "$r"
}

test_passes_before_fix() {
  local r out
  r=$(_repo passes)
  echo "CalcTest fixed any" >>"$r/tests/Calc.cases"
  out=$(_check "$r" 'CalcTest#fixed')
  [ "$(_verdict "$out")" = unproven ] && [ "$(_reason "$out")" = passes-before-fix ] && _clean_after "$r"
}

test_error_is_weak() {
  local r out
  r=$(_repo errored)
  echo "CalcTest fixed 2 error" >>"$r/tests/Calc.cases"
  out=$(_check "$r" CalcTest.fixed)
  [ "$(_verdict "$out")" = proved-weak ] &&
    grep -q $'^PRE_FIX_TEST\tCalcTest.fixed\terrored\tpassed$' <<<"$out"
}

test_did_not_build_is_weak() {
  local r out
  r=$(_repo nobuild)
  echo helper >"$r/src/helper.txt" # production file: never copied
  echo "CalcTest fixed 2 needs:src/helper.txt" >>"$r/tests/Calc.cases"
  out=$(_check "$r" CalcTest.fixed)
  [ "$(_verdict "$out")" = proved-weak ] &&
    grep -q $'^PRE_FIX_TEST\tCalcTest.fixed\tdid-not-build\tpassed$' <<<"$out"
}

test_no_report() {
  local r out
  r=$(_repo noreport)
  : >"$r/tests/NOREPORT"
  out=$(_check "$r" CalcTest.fixed)
  [ "$(_verdict "$out")" = unproven ] && [ "$(_reason "$out")" = no-report ] && _clean_after "$r"
}

test_ambiguous_names() {
  local r out
  r=$(_repo ambiguous)
  printf 'CalcTest fixed 2\nOtherTest fixed 2\n' >>"$r/tests/Calc.cases"
  out=$(_check "$r" CalcTest)
  [ "$(_reason "$out")" = ambiguous-name ] || return 1
  out=$(_check "$r" fixed)
  [ "$(_reason "$out")" = ambiguous-name ] || return 1
  out=$(_check "$r" OtherTest.fixed)
  [ "$(_verdict "$out")" = proved ]
}

test_not_passing_after() {
  local r out
  r=$(_repo notafter)
  echo "CalcTest fixed 3" >>"$r/tests/Calc.cases"
  out=$(_check "$r" CalcTest.fixed)
  [ "$(_verdict "$out")" = unproven ] && [ "$(_reason "$out")" = not-passing-after ]
}

test_not_run_before_fix() {
  local r out
  r=$(_repo notrun)
  echo "CalcTest fixed 2" >>"$r/tests/Calc.cases"
  out=$(_check "$r" CalcTest.missing)
  [ "$(_reason "$out")" = not-run-before-fix ]
}

test_no_test_files() {
  local r out
  r=$(_repo notests)
  out=$(_check "$r" CalcTest.fixed)
  [ "$(_verdict "$out")" = unproven ] && [ "$(_reason "$out")" = no-test-files ] && _clean_after "$r"
}

test_no_named_test() {
  local r out
  r=$(_repo noname)
  echo "CalcTest fixed 2" >>"$r/tests/Calc.cases"
  out=$(_check "$r")
  [ "$(_reason "$out")" = no-named-test ]
}

test_timeout_cleans_up() {
  local r out
  r=$(_repo timeout)
  echo "CalcTest fixed 2 sleep" >>"$r/tests/Calc.cases"
  out=$(PRE_FIX_FAILS_TIMEOUT=1 _check "$r" CalcTest.fixed)
  [ "$(_reason "$out")" = timeout ] && _clean_after "$r"
}

test_off_and_unknown_values() {
  local r out err
  r=$(_repo off)
  echo "CalcTest fixed 2" >>"$r/tests/Calc.cases"
  out=$(PRE_FIX_FAILS=off _check "$r" CalcTest.fixed)
  [ "$(_verdict "$out")" = skipped ] && [ "$(_reason "$out")" = off ] || return 1
  err=$(PRE_FIX_FAILS=enforce bash "$PFF" check CRE-1 --worktree "$r" --base-ref main \
    --claude-md /nonexistent --test CalcTest.fixed 2>&1 >/dev/null)
  grep -q 'PRE_FIX_FAILS=enforce is not warn or off' <<<"$err"
}

test_no_test_command() {
  local r out
  r=$(_repo nocmd)
  echo "CalcTest fixed 2" >>"$r/tests/Calc.cases"
  out=$(BE_TEST_CMD="" _check "$r" CalcTest.fixed)
  [ "$(_verdict "$out")" = skipped ] && [ "$(_reason "$out")" = no-test-command ]
}

test_meta_line() {
  local r log
  r=$(_repo meta)
  echo "CalcTest fixed 2" >>"$r/tests/Calc.cases"
  log="$WORK/meta/CRE-1-pipeline.log"
  : >"$log"
  LOG_FILE="$log" _check "$r" CalcTest.fixed >/dev/null
  grep -q '|META|pre-fix-fails|info|verdict=proved reason=ok repo=repo mode=full rc_before=1 rc_after=0 base=' "$log" &&
    grep -q 'copied=1 report=junit' "$log" &&
    [ "$(grep -c '|IMPLEMENT|' "$log")" -eq 0 ] &&
    [ "$(grep -c 'verifier-result\|gate-stop' "$log")" -eq 0 ]
}

test_copy_set_renames_and_deletes() {
  local r set
  r=$(_repo renames)
  git -C "$r" mv tests/Calc.cases tests/Calc2.cases
  echo "x" >"$r/tests/Gone.cases"
  git -C "$r" add tests/Gone.cases
  git -C "$r" commit -qm wip
  git -C "$r" rm -q tests/Gone.cases
  mkdir -p "$r/src/main/test"
  echo "y" >"$r/src/main/test/AppTest.java" # under src/main: production
  set=$(bash -c 'source "$1"; pff_copy_set "$2" "$(git -C "$2" merge-base HEAD main)"' _ "$PFF" "$r")
  [ "$set" = $'C\ttests/Calc2.cases\nD\ttests/Calc.cases' ]
}

test_test_path_rule() {
  local p bad=0
  for p in tests/a.cases src/test/java/x/A.java app/__tests__/a.js a/__mocks__/b.js test_x.py \
    pkg/conftest.py x_test.go a.test.ts a.spec.ts src/x/FooTest.java FooTests.cs BarIT.java \
    a/testdata/in.json a/fixtures/f.json a/testutil/h.go; do
    bash -c 'source "$1"; pff_is_test_path "$2"' _ "$PFF" "$p" || {
      echo "  should be a test: $p" >&2
      bad=1
    }
  done
  for p in src/main/java/x/FooTest.java src/x/Latest.java LIMIT.java Submit.js Contest.java \
    src/spec/Dsl.kt lib/runtests.sh README.md; do
    if bash -c 'source "$1"; pff_is_test_path "$2"' _ "$PFF" "$p"; then
      echo "  should not be a test: $p" >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

test_command_forms() {
  local got
  got=$(bash -c 'source "$1"; pff_command "mvn -q test" /j/r.xml com.x.FooTest.bar "BazTest#qux"' _ "$PFF")
  [ "$got" = $'targeted\tmvn -q test -Dtest=FooTest#bar\\,BazTest#qux -Dsurefire.failIfNoSpecifiedTests=false -DfailIfNoTests=false' ] || {
    echo "  mvn: $got" >&2
    return 1
  }
  got=$(bash -c 'source "$1"; pff_command "./mvnw test" /j/r.xml bare' _ "$PFF")
  [ "$got" = $'full\t./mvnw test' ] || return 1
  got=$(bash -c 'source "$1"; pff_command "python -m pytest" /j/r.xml tests/test_a.py::test_b TestC.test_d' _ "$PFF")
  [ "$got" = $'targeted\tpython -m pytest tests/test_a.py::test_b -k test_d --junitxml=/j/r.xml' ] || {
    echo "  pytest: $got" >&2
    return 1
  }
  got=$(bash -c 'source "$1"; pff_command "npm test" /j/r.xml a.b' _ "$PFF")
  [ "$got" = $'full\tnpm test' ]
}

test_wanted() {
  local root="$WORK/wanted" d bad=0
  d="$root/.ticket-auto/initiatives/INIT-1/tickets/CRE-7/planner"
  mkdir -p "$d" "$root/.ticket-auto/initiatives/_index"
  echo INIT-1 >"$root/.ticket-auto/initiatives/_index/CRE-7.initiative"
  echo '{"type":"bug"}' >"$d/manifest.json"
  printf '# CRE-8\n\n**Labels:** Bug\n' >"$WORK/bug.md"
  [ "$(REPOS_ROOT="$root" bash "$PFF" wanted CRE-7)" = true ] || bad=1
  [ "$(REPOS_ROOT="$root" PRE_FIX_FAILS=off bash "$PFF" wanted CRE-7)" = false ] || bad=1
  [ "$(REPOS_ROOT="$root" bash "$PFF" wanted CRE-9)" = false ] || bad=1
  [ "$(bash "$PFF" wanted CRE-8 "$WORK/bug.md")" = true ] || bad=1
  [ "$(PRE_FIX_FAILS=bogus bash "$PFF" wanted CRE-8 "$WORK/bug.md" 2>/dev/null)" = true ] || bad=1
  [ "$bad" -eq 0 ]
}

test_usage() {
  local rc
  for args in "" "nope" "wanted" "wanted -x" "check" "check CRE-1" "check CRE-1 --worktree /nonexistent --base-ref main" "check CRE-1 --bogus x"; do
    rc=0
    # shellcheck disable=SC2086
    bash "$PFF" $args >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || {
      echo "  '$args' gave $rc" >&2
      return 1
    }
  done
}

test_sourcing_sets_no_options() {
  local before after
  before=$(set +o)
  # shellcheck disable=SC1090
  source "$PFF"
  after=$(set +o)
  [ "$before" = "$after" ] && declare -f pff_check >/dev/null
}

for t in \
  test_proved_untracked_test_file \
  test_passes_before_fix \
  test_error_is_weak \
  test_did_not_build_is_weak \
  test_no_report \
  test_ambiguous_names \
  test_not_passing_after \
  test_not_run_before_fix \
  test_no_test_files \
  test_no_named_test \
  test_timeout_cleans_up \
  test_off_and_unknown_values \
  test_no_test_command \
  test_meta_line \
  test_copy_set_renames_and_deletes \
  test_test_path_rule \
  test_command_forms \
  test_wanted \
  test_usage \
  test_sourcing_sets_no_options; do
  _run "$t" "$t"
done

echo ""
echo "test-pre-fix-fails.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
