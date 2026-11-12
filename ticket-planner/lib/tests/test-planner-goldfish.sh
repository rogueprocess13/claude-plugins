#!/usr/bin/env bash
# test-planner-goldfish.sh — the goldfish review lens lib
# (planner-goldfish-review, tasks 1.1, 2.1–2.4): planner-goldfish.sh.
#
#   - the prompt: names only the input copy, the git repositories directly
#     under REPOS_ROOT and the result path; withholds every upstream artifact,
#     the idea and the bare REPOS_ROOT; the scope rule and the 8-finding cap;
#     the input copy is byte-identical to proposal.md;
#   - due/next: one case per rule of design D3, in order, the spawn line's
#     five fields, stdout holding only the spawn list;
#   - parse: every fixture under fixtures/goldfish/, mawk and gawk agreeing;
#   - apply: done, warn then fail NOT_RUN, contaminated, proposal-changed,
#     position and Review's fail count unaffected, two versions both kept;
#   - status: the three lines of design D8.
#
# Every case is guarded on the functions it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary, never an
# unbound-function abort.
#
# Run: bash ticket-planner/lib/tests/test-planner-goldfish.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FX="${SCRIPT_DIR}/fixtures/goldfish"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"
unset PLANNER_GOLDFISH_REVIEW PLANNER_GOLDFISH_TIMEOUT PLANNER_GOLDFISH_AWK

source "${LIB_DIR}/planner-state.sh"
[ -f "${LIB_DIR}/planner-goldfish.sh" ] && source "${LIB_DIR}/planner-goldfish.sh"

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

IDEA="Let customers pause a subscription for up to ninety days"
N=0
# new_init — a fresh initiative with every upstream artifact on disk.
new_init() {
  N=$((N + 1))
  INIT="INIT-goldfish-${N}"
  planner_state_init "$INIT" "$IDEA" >/dev/null 2>&1
  SD="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  mkdir -p "${SD}/artifacts/specs"
  for a in intent appraisal discovery architecture review consensus; do
    printf '# %s\n' "$a" >"${SD}/artifacts/${a}.md"
  done
  printf '# Spec\n' >"${SD}/artifacts/specs/pause.md"
  printf '# Proposal\n\n## Scope\nPause subscriptions.\n' >"${SD}/artifacts/proposal.md"
  LOG="${SD}/state.log"
}
gf_lines() { grep '|META|goldfish|' "$LOG" | cut -d'|' -f4-; }
# result_for <fixture> — the fixture rewritten for this initiative and sha.
result_for() {
  local sha
  sha=$(planner_goldfish_sha12 "$INIT")
  mkdir -p "${SD}/goldfish"
  sed -e "s/abcdef012345/${sha}/" -e "s#/repos/.ticket-auto/initiatives/INIT-TEST#${SD}#" \
    "${FX}/$1" >"${SD}/goldfish/review-goldfish.md"
}

# Repositories: two git repos, one plain directory, and .ticket-auto.
mkdir -p "${REPOS_ROOT}/billing/.git" "${REPOS_ROOT}/web/.git" "${REPOS_ROOT}/notes"

echo "=== planner-goldfish: prompt (1.1) ==="

name="prompt names the input copy, the repositories and the result path"
if need "$name" planner_goldfish_prompt planner_goldfish_sha12; then
  new_init
  pf=$(planner_goldfish_prompt "$INIT" 2>/dev/null)
  check "prompt file path" "$pf" "${SD}/goldfish/prompt.txt"
  p=$(cat "$pf" 2>/dev/null)
  contains "$name: input" "$p" "${SD}/goldfish/input/proposal.md"
  contains "$name: billing" "$p" "${REPOS_ROOT}/billing"
  contains "$name: web" "$p" "${REPOS_ROOT}/web"
  contains "$name: result" "$p" "${SD}/goldfish/review-goldfish.md"
  contains "$name: sha" "$p" "**Proposal:** $(planner_goldfish_sha12 "$INIT")"
  lacks "non-git directory left out" "$p" "${REPOS_ROOT}/notes"
  lacks "no bare .ticket-auto repository" "$p" "- ${REPOS_ROOT}/.ticket-auto"
  for w in "$IDEA" "artifacts/" "intent.md" "appraisal.md" "discovery.md" "architecture.md" "specs/" "review.md"; do
    lacks "prompt withholds '$w'" "$p" "$w"
  done
  bare=$(printf '%s\n' "$p" | grep -oF "$REPOS_ROOT" | wc -l)
  prefixed=$(printf '%s\n' "$p" | grep -oF "${REPOS_ROOT}/" | wc -l)
  check "no bare REPOS_ROOT" "$bare" "$prefixed"
  contains "scope rule" "$p" 'MUST pass `path` set to one of the repository'
  contains "8-finding cap" "$p" "At most 8 findings"
  contains "None. rule" "$p" '`None.`'
  if cmp -s "${SD}/artifacts/proposal.md" "${SD}/goldfish/input/proposal.md"; then
    pass "input copy is byte-identical"
  else fail "input copy is byte-identical" "differs"; fi
fi

echo "=== planner-goldfish: due and next (2.1) ==="

name="rule 3: flag unset gives skip DISABLED, once"
if need "$name" planner_goldfish_due planner_goldfish_next; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  out=$(planner_goldfish_next "$INIT")
  check "$name: next prints done 0" "$out" "done 0"
  check "$name: line" "$(gf_lines)" "skip|${sha} DISABLED"
  planner_goldfish_due "$INIT" && fail "$name: not due" "due" || pass "$name: not due"
  check "rule 1: a terminal line for this sha12 writes nothing more" "$(gf_lines | wc -l)" "1"
  PLANNER_GOLDFISH_REVIEW=true planner_goldfish_due "$INIT" &&
    fail "flag turned on later does not re-decide the version" "due" ||
    pass "flag turned on later does not re-decide the version"
fi

name="rule 5: flag true makes a run due; the spawn line"
if need "$name" planner_goldfish_due planner_goldfish_next; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  planner_goldfish_due "$INIT" && pass "$name: due" || fail "$name: due" "not due"
  check "due writes nothing when due" "$(gf_lines | wc -l)" "0"
  out=$(planner_goldfish_next "$INIT" 2>/dev/null)
  check "$name: stdout is exactly one line" "$(printf '%s\n' "$out" | wc -l)" "1"
  IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 <<<"$out"
  check "field 1 id" "$f1" "$INIT"
  check "field 2 kind" "$f2" "lens"
  check "field 3 agent" "$f3" "ticket-planner:goldfish-review-agent"
  check "field 4 prompt" "$f4" "${SD}/goldfish/prompt.txt"
  check "field 5 result" "$f5" "${SD}/goldfish/review-goldfish.md"
  check "no sixth field" "${f6:-}" ""
  [ -f "$f4" ] && pass "prompt written" || fail "prompt written" "missing"
  check "start line" "$(gf_lines)" "start|${sha} attempt=1"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="rule 2: a valid result already on disk is recorded done, no spawn"
if need "$name" planner_goldfish_next; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  planner_goldfish_next "$INIT" >/dev/null 2>&1
  result_for valid.md
  out=$(planner_goldfish_next "$INIT")
  check "$name: done 0" "$out" "done 0"
  check "$name: done line" "$(gf_lines | tail -1)" "done|${sha} findings=3 bm=G1"
  check "$name: one start only" "$(gf_lines | grep -c '^start|')" "1"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="rule 2 precedes rule 3: a valid result is recorded even with the flag off"
if need "$name" planner_goldfish_next; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  result_for none.md
  out=$(planner_goldfish_next "$INIT")
  check "$name" "$(gf_lines)" "done|${sha} findings=0 bm=-"
fi

name="rule 4: missing proposal gives fail NOT_RUN no-proposal"
if need "$name" planner_goldfish_next; then
  new_init
  rm -f "${SD}/artifacts/proposal.md"
  export PLANNER_GOLDFISH_REVIEW=true
  out=$(planner_goldfish_next "$INIT")
  check "$name: done 0" "$out" "done 0"
  check "$name: line" "$(gf_lines)" "fail|e3b0c44298fc NOT_RUN no-proposal"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="rule 4: empty proposal gives fail NOT_RUN no-proposal"
if need "$name" planner_goldfish_next; then
  new_init
  : >"${SD}/artifacts/proposal.md"
  export PLANNER_GOLDFISH_REVIEW=true
  planner_goldfish_next "$INIT" >/dev/null
  contains "$name" "$(gf_lines)" "NOT_RUN no-proposal"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="attempts exhausted by crashes gives fail NOT_RUN no-result"
if need "$name" planner_goldfish_next; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  planner_goldfish_next "$INIT" >/dev/null # crash: no apply
  planner_goldfish_next "$INIT" >/dev/null # crash again
  out=$(planner_goldfish_next "$INIT")
  check "$name: done 0" "$out" "done 0"
  check "$name: attempt numbers" "$(gf_lines | grep '^start|' | tr '\n' ' ')" "start|${sha} attempt=1 start|${sha} attempt=2 "
  check "$name: line" "$(gf_lines | tail -1)" "fail|${sha} NOT_RUN no-result"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="next errors on an unresolvable initiative"
if need "$name" planner_goldfish_next; then
  out=$(REPOS_ROOT="" planner_goldfish_next "INIT-nope" 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] && pass "$name" || fail "$name" "rc=$rc out=[$out]"
fi

echo "=== planner-goldfish: parse (2.2) ==="

declare -A WANT=(
  ["valid.md"]="ok 3 G1"
  ["none.md"]="ok 0 -"
  ["over-cap.md"]="ok 8 G1,G2 capped"
  ["gap.md"]="ok 3 G1,G3"
  ["duplicate.md"]="malformed duplicate-id"
  ["bad-sha.md"]="malformed wrong-proposal"
  ["crlf.md"]="ok 2 G1,G2"
  ["fenced.md"]="ok 1 G1"
  ["contaminated.md"]="ok 1 G1"
)
if need "parse" planner_goldfish_parse; then
  for fx in "${!WANT[@]}"; do
    check "parse ${fx}" "$(planner_goldfish_parse "${FX}/${fx}" abcdef012345)" "${WANT[$fx]}"
  done
  check "parse missing file" "$(planner_goldfish_parse "${WORK}/nope.md" abcdef012345)" "malformed empty"
  printf '# Goldfish Review\n\n**Proposal:** abcdef012345\n\n## Files Read\n- x\n' >"${WORK}/nofind.md"
  check "parse no findings section" "$(planner_goldfish_parse "${WORK}/nofind.md" abcdef012345)" "malformed no-findings-section"
  printf '# Goldfish Review\n\n**Proposal:** abcdef012345\n\n## Findings\nNone.\n' >"${WORK}/nofiles.md"
  check "parse no files read" "$(planner_goldfish_parse "${WORK}/nofiles.md" abcdef012345)" "malformed no-files-read"
  printf '# Goldfish Review\n\n## Findings\nNone.\n\n## Files Read\n- x\n' >"${WORK}/nosha.md"
  check "parse no proposal line" "$(planner_goldfish_parse "${WORK}/nosha.md" abcdef012345)" "malformed no-proposal-line"
  printf '# Goldfish Review\n\n**Proposal:** abcdef012345\n\n## Findings\n### G1 — urgent — Bad severity\n\n## Files Read\n- x\n' >"${WORK}/badsev.md"
  check "parse bad severity" "$(planner_goldfish_parse "${WORK}/badsev.md" abcdef012345)" "malformed bad-heading"
  printf '# Goldfish Review\n\n**Proposal:** abcdef012345\n\n## Findings\n### F1 — major — Wrong prefix\n\n## Files Read\n- x\n' >"${WORK}/badid.md"
  check "parse bad id" "$(planner_goldfish_parse "${WORK}/badid.md" abcdef012345)" "malformed bad-heading"
  printf '# Goldfish Review\n\n**Proposal:** abcdef012345\n\n## Findings\n\n## Files Read\n- x\n' >"${WORK}/empty.md"
  check "parse empty findings" "$(planner_goldfish_parse "${WORK}/empty.md" abcdef012345)" "malformed empty-findings"

  if command -v mawk >/dev/null 2>&1; then
    m=""
    g=""
    for fx in $(printf '%s\n' "${!WANT[@]}" | LC_ALL=C sort); do
      m="${m}$(PLANNER_GOLDFISH_AWK=mawk planner_goldfish_parse "${FX}/${fx}" abcdef012345);"
    done
    exp=""
    for fx in $(printf '%s\n' "${!WANT[@]}" | LC_ALL=C sort); do exp="${exp}${WANT[$fx]};"; done
    check "mawk parses every fixture" "$m" "$exp"
    if command -v gawk >/dev/null 2>&1; then
      for fx in $(printf '%s\n' "${!WANT[@]}" | LC_ALL=C sort); do
        g="${g}$(PLANNER_GOLDFISH_AWK=gawk planner_goldfish_parse "${FX}/${fx}" abcdef012345);"
      done
      check "gawk agrees with mawk" "$g" "$m"
    else
      echo "  SKIP gawk agrees with mawk (gawk not installed)"
    fi
  else
    echo "  SKIP mawk parses every fixture (mawk not installed)"
  fi
fi

echo "=== planner-goldfish: apply (2.3) ==="

# spawn <INIT> — NEXT as the orchestrator would call it.
spawn() { planner_goldfish_next "$INIT" >/dev/null 2>&1; }

name="apply ok gives done findings=N bm=ids"
if need "$name" planner_goldfish_next planner_goldfish_apply; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  spawn
  result_for gap.md
  out=$(planner_goldfish_apply "$INIT")
  check "$name: silent" "$out" ""
  check "$name" "$(gf_lines | tail -1)" "done|${sha} findings=3 bm=G1,G3"
  check "next after done is done 0" "$(planner_goldfish_next "$INIT")" "done 0"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="capped result records capped"
if need "$name" planner_goldfish_next planner_goldfish_apply; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  spawn
  result_for over-cap.md
  planner_goldfish_apply "$INIT"
  check "$name" "$(gf_lines | tail -1)" "done|${sha} findings=8 bm=G1,G2 capped"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="two failures: warn attempt=1, then fail NOT_RUN, never done"
if need "$name" planner_goldfish_next planner_goldfish_apply; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  spawn
  planner_goldfish_apply "$INIT" # timed out: no result
  check "$name: first" "$(gf_lines | tail -1)" "warn|${sha} attempt=1 no-result"
  out=$(planner_goldfish_next "$INIT")
  case "$out" in "${INIT}"$'\t'lens*) pass "$name: still due after one failure" ;; *) fail "$name: still due after one failure" "[$out]" ;; esac
  result_for duplicate.md
  planner_goldfish_apply "$INIT"
  check "$name: second" "$(gf_lines | tail -1)" "fail|${sha} NOT_RUN malformed:duplicate-id"
  [ -e "${SD}/goldfish/review-goldfish.md" ] && fail "$name: file deleted" "exists" || pass "$name: file deleted"
  check "$name: no done line" "$(gf_lines | grep -c "^done|${sha}")" "0"
  check "$name: next is done 0" "$(planner_goldfish_next "$INIT")" "done 0"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="a malformed first attempt deletes the file and warns"
if need "$name" planner_goldfish_next planner_goldfish_apply; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  spawn
  result_for bad-sha.md
  planner_goldfish_apply "$INIT"
  check "$name" "$(gf_lines | tail -1)" "warn|${sha} attempt=1 malformed:wrong-proposal"
  [ -e "${SD}/goldfish/review-goldfish.md" ] && fail "$name: file deleted" "exists" || pass "$name: file deleted"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="a contaminated result is a failed attempt"
if need "$name" planner_goldfish_next planner_goldfish_apply; then
  new_init
  sha=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  spawn
  result_for contaminated.md
  planner_goldfish_apply "$INIT"
  check "$name" "$(gf_lines | tail -1)" "warn|${sha} attempt=1 contaminated:${SD}/artifacts/discovery.md"
  result_for contaminated.md # a crash before APPLY, attempt 1 left on disk
  check "a contaminated result on disk is not recorded done by next" "$(planner_goldfish_next "$INIT" | cut -f2)" "lens"
  check "the respawn is attempt 2" "$(gf_lines | tail -1)" "start|${sha} attempt=2"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="a proposal changed between next and apply gives NOT_RUN proposal-changed"
if need "$name" planner_goldfish_next planner_goldfish_apply; then
  new_init
  old=$(planner_goldfish_sha12 "$INIT")
  export PLANNER_GOLDFISH_REVIEW=true
  spawn
  result_for valid.md
  printf 'more\n' >>"${SD}/artifacts/proposal.md"
  new=$(planner_goldfish_sha12 "$INIT")
  planner_goldfish_apply "$INIT"
  check "$name" "$(gf_lines | tail -1)" "fail|${old} NOT_RUN proposal-changed"
  [ -e "${SD}/goldfish/review-goldfish.md" ] && fail "$name: file deleted" "exists" || pass "$name: file deleted"
  out=$(planner_goldfish_next "$INIT")
  case "$out" in "${INIT}"$'\t'lens*) pass "the new version is due" ;; *) fail "the new version is due" "[$out]" ;; esac
  check "the new version starts at attempt 1" "$(gf_lines | tail -1)" "start|${new} attempt=1"

  # Two versions: both terminal lines kept.
  result_for none.md
  planner_goldfish_apply "$INIT"
  check "two versions: both terminal lines kept" "$(gf_lines | grep -cE '^(done|fail)\|')" "2"
  check "the second version recorded done" "$(gf_lines | tail -1)" "done|${new} findings=0 bm=-"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="two versions' done lines are both kept"
if need "$name" planner_goldfish_next planner_goldfish_apply; then
  new_init
  export PLANNER_GOLDFISH_REVIEW=true
  spawn
  result_for valid.md
  planner_goldfish_apply "$INIT"
  printf 'v2\n' >>"${SD}/artifacts/proposal.md"
  spawn
  result_for none.md
  planner_goldfish_apply "$INIT"
  check "$name" "$(gf_lines | grep -c '^done|')" "2"
  unset PLANNER_GOLDFISH_REVIEW
fi

name="apply with no start line is a no-op"
if need "$name" planner_goldfish_apply; then
  new_init
  planner_goldfish_apply "$INIT"
  check "$name" "$(gf_lines | wc -l)" "0"
fi

name="not run leaves position and Review's fail count unchanged"
if need "$name" planner_goldfish_next planner_goldfish_apply; then
  new_init
  for p in Appraisal Discovery Architecture Specify; do
    planner_state_write "$INIT" "$p" step start "x" >/dev/null 2>&1
    planner_state_write "$INIT" "$p" step done "x" >/dev/null 2>&1
  done
  pos_before=$(planner_position_derive "$INIT")
  fc_before=$(planner_phase_fail_count "$INIT" Review)
  export PLANNER_GOLDFISH_REVIEW=true
  spawn
  planner_goldfish_apply "$INIT"
  spawn
  planner_goldfish_apply "$INIT"
  contains "$name: not run recorded" "$(gf_lines | tail -1)" "NOT_RUN no-result"
  check "$name: position" "$(planner_position_derive "$INIT")" "$pos_before"
  check "$name: position is Review" "$pos_before" "Review"
  check "$name: Review fail count" "$(planner_phase_fail_count "$INIT" Review)" "$fc_before"
  unset PLANNER_GOLDFISH_REVIEW
fi

echo "=== planner-goldfish: status (2.4) ==="

if need "status" planner_goldfish_status; then
  new_init
  check "status: no record" "$(planner_goldfish_status "$INIT")" \
    "Goldfish review: NOT RUN — no record. Its findings are unknown, not zero."
  sha=$(planner_goldfish_sha12 "$INIT")
  planner_state_write "$INIT" META goldfish done "${sha} findings=3 bm=G1" >/dev/null 2>&1
  check "status: ran" "$(planner_goldfish_status "$INIT")" \
    "Goldfish review: ran — 3 finding(s), proposal ${sha}, see goldfish/review-goldfish.md"
  planner_state_write "$INIT" META goldfish fail "${sha} NOT_RUN no-result" >/dev/null 2>&1
  check "status: not run" "$(planner_goldfish_status "$INIT")" \
    "Goldfish review: NOT RUN — no-result. Its findings are unknown, not zero."
  planner_state_write "$INIT" META goldfish skip "${sha} DISABLED" >/dev/null 2>&1
  check "status: disabled" "$(planner_goldfish_status "$INIT")" "Goldfish review: disabled"
  planner_state_write "$INIT" META goldfish warn "${sha} attempt=1 no-result" >/dev/null 2>&1
  check "status ignores warn lines" "$(planner_goldfish_status "$INIT")" "Goldfish review: disabled"
fi

echo "=== planner-goldfish: constants ==="

if need "timeout" planner_goldfish_timeout_ms; then
  check "timeout default" "$(planner_goldfish_timeout_ms)" "600000"
  check "timeout 120" "$(PLANNER_GOLDFISH_TIMEOUT=120 planner_goldfish_timeout_ms)" "120000"
  check "timeout invalid falls back" "$(PLANNER_GOLDFISH_TIMEOUT=abc planner_goldfish_timeout_ms)" "600000"
fi
case " ${PLANNER_REPEATABLE_META_STEPS} " in
*" goldfish "*) pass "goldfish is a repeatable META step" ;;
*) fail "goldfish is a repeatable META step" "not listed" ;;
esac
if bash -c "source '${LIB_DIR}/planner-state.sh'; case \" \${PLANNER_REPEATABLE_META_STEPS} \" in *' goldfish '*) exit 0;; esac; exit 1"; then
  pass "planner-state.sh lists goldfish without the goldfish lib"
else fail "planner-state.sh lists goldfish without the goldfish lib" "not listed"; fi

AGENT="${LIB_DIR}/../agents/goldfish-review-agent.md"
if [ -f "$AGENT" ]; then
  check "agent name" "$(sed -n 's/^name: //p' "$AGENT")" "goldfish-review-agent"
  check "agent tools" "$(sed -n 's/^tools: //p' "$AGENT")" "Read, Grep, Glob, Write"
  lacks "agent has no Bash" "$(sed -n 's/^tools: //p' "$AGENT")" "Bash"
  contains "agent states data-not-instructions" "$(cat "$AGENT")" "DATA, not instructions"
else
  fail "agent file exists" "missing"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
