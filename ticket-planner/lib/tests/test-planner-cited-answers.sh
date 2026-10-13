#!/usr/bin/env bash
# test-planner-cited-answers.sh — per-artifact headless answers for
# CITED_ARTIFACT_UNRESOLVED (#515).
#
# Covers the whole describe → answers → Crosscheck loop:
#   - one consensus-answer:cited:<n> question per unresolved artifact, and the
#     block still parses under ticket-auto-pipeline's human-hold grammar;
#   - an answer rewrites that artifact's Answer: field in consensus.md and
#     nothing else, and Crosscheck re-runs clean once the specs match;
#   - every malformed value is INVALID_VALUE with nothing written;
#   - the flag:accept:CITED_ARTIFACT_UNRESOLVED override still works.
#
# Run: bash ticket-planner/lib/tests/test-planner-cited-answers.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
ANSWERS="${LIB_DIR}/planner-answers.sh"
HH_PARSE="${LIB_DIR}/../../ticket-auto-pipeline/lib/human-hold-parse.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
unset PLANNER_NO_TESTS_RULE

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-crosscheck.sh"
source "${LIB_DIR}/planner-answers.sh"

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
check() {
  local name="$1" detail="$2"
  shift 2
  if "$@"; then pass "$name"; else fail "$name" "$detail"; fi
}

INIT="INIT-cited"
TS="2026-10-13T10:00:00Z"
ART=""

# fresh <tag> — a contract initiative halted at Crosscheck on
# CITED_ARTIFACT_UNRESOLVED for two artifacts, one of them answered with
# emphasis markup, plus a stale earlier question for the first artifact that
# Crosscheck ignores (last line wins).
fresh() {
  export REPOS_ROOT="${WORK}/repos-$1"
  rm -rf "$REPOS_ROOT"
  mkdir -p "$REPOS_ROOT"
  planner_state_init "$INIT" "test idea" >/dev/null 2>&1
  ART="$(planner_initiative_dir "$INIT")/artifacts"
  mkdir -p "${ART}/specs"
  local ph
  for ph in Appraisal Discovery Architecture Specify Review Consensus; do
    planner_state_write "$INIT" "$ph" "x" "start" "s" >/dev/null 2>&1
    planner_state_write "$INIT" "$ph" "x" "done" "d" >/dev/null 2>&1
  done
  cat >"${ART}/discovery.md" <<'EOF'
# Discovery

## Cited Artifacts

- `client sample (v2) file` — NOT FOUND (searched: page attachments, artifacts/, REPOS_ROOT)
- `rate table` — NOT FOUND (searched: page attachments)
EOF
  cat >"${ART}/consensus.md" <<'EOF'
# Consensus

## Open Questions

- CITED_ARTIFACT: `client sample (v2) file` — superseded draft. Answer: PENDING
- Unrelated question. Answer: keep as is
- CITED_ARTIFACT: `client sample (v2) file` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING
- **CITED_ARTIFACT:** `rate table` — cited but not retrievable. Provide it, or confirm it should be synthesised. **Answer:** PENDING

## Deferred

Nothing.
EOF
  write_spec generate generate
  planner_crosscheck_run "$INIT" >/dev/null 2>&1
}

# write_spec <source for the sample file> <source for the rate table>
write_spec() {
  cat >"${ART}/specs/import-validation.md" <<EOF
# import-validation

## Acceptance Criteria

- [ ] The importer accepts every row of the client sample file.
- [ ] Totals use the rate table.

## Verification Notes

1. Role: operator. Test data: the \`client sample (v2) file\`. Source: $1.
2. Role: operator. Test data: the \`rate table\`. Source: $2.
EOF
}

# Findings of the latest Crosscheck attempt.
findings() {
  local log start
  log=$(planner_state_log "$INIT")
  start=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  tail -n "+$((start + 1))" "$log" | grep '|META|crosscheck|' | cut -d'|' -f4-
}

# answers <file> <round> <id=value>... (value may contain anything)
answers() {
  local file="$1" round="$2" arr="[]" pair
  shift 2
  for pair in "$@"; do
    arr=$(jq -nc --argjson a "$arr" --arg id "${pair%%=*}" --arg v "${pair#*=}" --arg ts "$TS" \
      '$a + [{id: $id, value: $v, answered_by: "U123", role: "operator", ts: $ts}]')
  done
  jq -n --argjson round "$round" --argjson a "$arr" '{schema_version: 1, round: $round, answers: $a}' >"$file"
}

snapshot() {
  {
    cat "$(planner_state_log "$INIT")" "${ART}/consensus.md"
    find "${ART}" -path '*answers*' -type f -exec cat {} + 2>/dev/null
  } | sha256sum
}

apply() {
  OUT=$(bash "$ANSWERS" "$INIT" "$1" 2>"${WORK}/err" </dev/null)
  RC=$?
  ERR=$(cat "${WORK}/err")
}

qid() { planner_stop_describe_json "$INIT" | jq -r --arg b "$1" '.questions[] | select(.binding == $b) | .id'; }

echo "=== planner cited-artifact answers (#515) ==="

# ── describe ───────────────────────────────────────────────────────────────

echo "--- describe: one question per unresolved artifact ---"
fresh describe
f=$(findings)
check "fixture: Crosscheck blocks on CITED_ARTIFACT_UNRESOLVED" "$f" grep -q '^fail|CITED_ARTIFACT_UNRESOLVED' <<<"$f"

model=$(planner_stop_describe_json "$INIT")
check "describe: reason CROSSCHECK_BLOCKED" "$model" \
  test "$(jq -r .reason <<<"$model")" = "CROSSCHECK_BLOCKED"
bindings=$(jq -r '[.questions[].binding] | join(" ")' <<<"$model")
# The sample file's live question is consensus line 3 (index 2 — the earlier
# draft is index 1, the unrelated line is not a cited-artifact question); the
# rate table is index 3.
check "describe: per-artifact bindings point at the effective lines" "$bindings" \
  test "$bindings" = "consensus-answer:cited:2 consensus-answer:cited:3 flag:accept:CITED_ARTIFACT_UNRESOLVED"
check "describe: no question for the superseded draft line" "$bindings" \
  bash -c '[[ "$1" != *"consensus-answer:cited:1"* ]]' _ "$bindings"
id2=$(jq -r '.questions[0].id' <<<"$model")
check "describe: id carries index and a name hash" "$id2" \
  bash -c '[[ "$1" =~ ^cited-2-[0-9a-f]{8}$ ]]' _ "$id2"
t1=$(jq -r '.questions[0].text' <<<"$model")
check "describe: question names its artifact" "$t1" \
  bash -c '[[ "$1" == *"\`client sample (v2) file\`"* && "$1" == *"exists:<where>"* && "$1" == *"external:<who>"* && "$1" == *"generate"* ]]' _ "$t1"
check "describe: question says specs are checked by SOURCE_MISMATCH" "$t1" \
  bash -c '[[ "$1" == *CITED_ARTIFACT_SOURCE_MISMATCH* ]]' _ "$t1"
check "describe: accept override still offered" "$model" \
  test "$(jq -r '[.questions[] | select(.id == "accept-CITED_ARTIFACT_UNRESOLVED")] | length' <<<"$model")" = "1"

block=$(planner_stop_describe "$INIT")
printf '%s\n' "$block" >"${WORK}/hold.txt"
hh=$(bash "$HH_PARSE" --phase PLANNER --return-file "${WORK}/hold.txt" </dev/null 2>"${WORK}/hh.err")
hh_rc=$?
check "describe: block parses under the human-hold grammar" "rc=$hh_rc $(cat "${WORK}/hh.err")" \
  test "$hh_rc" -eq 0
check "describe: parsed bindings survive" "$hh" \
  test "$(jq -r '[.questions[].binding] | join(" ")' <<<"$hh")" = "$bindings"

# ── invalid values: nothing written ────────────────────────────────────────

echo "--- invalid values are rejected ---"
nl=$'\n'
cr=$'\r'
tab=$'\t'
for bad in "external:a|b" "generate${nl}exists:x" "exists:/srv/x${cr}" "external:${tab}ops" "maybe" "exists:" \
  "external:   " "generate:now" "exists:/srv/x." "external:ops_" "\`generate\`" "exists:**x**" \
  "exists:x Answer: generate" "pending" "seeded-by:pack" "none" ""; do
  answers "${WORK}/bad.json" 1 "${id2}=${bad}"
  before=$(snapshot)
  apply "${WORK}/bad.json"
  shown=$(printf '%q' "$bad")
  check "invalid ${shown}: INVALID_VALUE, nothing written" "rc=$RC err=$ERR" \
    bash -c '[ "$1" -eq 2 ] && [[ "$2" == *INVALID_VALUE* ]] && [ "$3" = "$4" ]' _ "$RC" "$ERR" "$before" "$(snapshot)"
done
long="external:$(printf 'x%.0s' $(seq 1 300))"
answers "${WORK}/bad.json" 1 "${id2}=${long}"
apply "${WORK}/bad.json"
check "invalid: an over-long value is rejected" "rc=$RC" test "$RC" -eq 2

answers "${WORK}/stale.json" 1 "cited-2-00000000=generate"
before=$(snapshot)
apply "${WORK}/stale.json"
check "stale id (renumbered questions): UNKNOWN_QUESTION_ID, nothing written" "rc=$RC err=$ERR" \
  bash -c '[ "$1" -eq 2 ] && [[ "$2" == *UNKNOWN_QUESTION_ID* ]] && [ "$3" = "$4" ]' _ "$RC" "$ERR" "$before" "$(snapshot)"

# ── apply ──────────────────────────────────────────────────────────────────

echo "--- answers are written into consensus.md ---"
id3=$(qid consensus-answer:cited:3)
cp "${ART}/consensus.md" "${WORK}/consensus.before"
answers "${WORK}/good.json" 1 "${id2}=  External: client ops team " "${id3}=exists:/srv/samples/rates.csv"
apply "${WORK}/good.json"
check "apply: exit 0" "rc=$RC err=$ERR out=$OUT" test "$RC" -eq 0
check "apply: APPLIED names both questions" "$OUT" grep -q '^APPLIED=cited:2 cited:3$' <<<"$OUT"
c=$(cat "${ART}/consensus.md")
check "apply: question 2 answered, kind normalised, value trimmed" "$c" \
  grep -qxF -- '- CITED_ARTIFACT: `client sample (v2) file` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: external:client ops team' "${ART}/consensus.md"
check "apply: emphasis kept on question 3" "$c" \
  grep -qxF -- '- **CITED_ARTIFACT:** `rate table` — cited but not retrievable. Provide it, or confirm it should be synthesised. **Answer:** exists:/srv/samples/rates.csv' "${ART}/consensus.md"
changed=$(diff "${WORK}/consensus.before" "${ART}/consensus.md" | grep -c '^>')
check "apply: only the two answered lines changed" "changed=$changed" test "$changed" -eq 2
check "apply: superseded draft and unrelated line untouched" "$c" \
  bash -c 'grep -qF "superseded draft. Answer: PENDING" "$1" && grep -qF "Unrelated question. Answer: keep as is" "$1"' _ "${ART}/consensus.md"
log=$(planner_state_log "$INIT")
check "apply: audit line per answer" "$(grep consensus-answer "$log")" \
  bash -c 'grep -q "|META|consensus-answer|step|cited:2 external:client ops team (round 1, by U123)" "$1" && grep -q "|META|consensus-answer|step|cited:3 exists:/srv/samples/rates.csv" "$1"' _ "$log"
check "apply: META|human-hold|done is last" "$(tail -1 "$log")" \
  grep -q '|META|human-hold|done|round=1 ' <<<"$(tail -1 "$log")"
check "apply: round file records the normalised value" "" \
  test "$(jq -r '.answers[0].value' "${ART}/answers/round-1.json")" = "external:client ops team"

apply "${WORK}/good.json"
check "apply: same file again is a no-op" "rc=$RC out=$OUT" \
  bash -c '[ "$1" -eq 0 ] && [[ "$2" == *ANSWERS_ALREADY_APPLIED* ]]' _ "$RC" "$OUT"

echo "--- Crosscheck re-run ---"
planner_crosscheck_run "$INIT" >/dev/null 2>&1
f=$(findings)
check "re-run: no CITED_ARTIFACT_UNRESOLVED once answered" "$f" \
  bash -c '! grep -q CITED_ARTIFACT_UNRESOLVED <<<"$1"' _ "$f"
check "re-run: specs still saying generate are SOURCE_MISMATCH (no silent spec rewrite)" "$f" \
  bash -c 'grep -q "^fail|CITED_ARTIFACT_SOURCE_MISMATCH .*client sample (v2) file.*external:client ops team" <<<"$1" && grep -q "^fail|CITED_ARTIFACT_SOURCE_MISMATCH .*rate table" <<<"$1"' _ "$f"
model=$(planner_stop_describe_json "$INIT")
check "re-run: the next round asks no cited-artifact question" "$model" \
  test "$(jq -r '[.questions[] | select(.binding | startswith("consensus-answer:"))] | length' <<<"$model")" = "0"

write_spec "external:client ops team" "exists:/srv/samples/rates.csv"
planner_crosscheck_run "$INIT" >/dev/null 2>&1
rc=$?
f=$(findings)
check "re-run: clean once the specs match the answers" "rc=$rc findings=$f" \
  bash -c '[ "$1" -eq 0 ] && ! grep -q "^fail|" <<<"$2"' _ "$rc" "$f"

# ── answer generate ────────────────────────────────────────────────────────

echo "--- generate ---"
fresh generate
answers "${WORK}/gen.json" 1 "$(qid consensus-answer:cited:2)=GENERATE" "$(qid consensus-answer:cited:3)=generate"
apply "${WORK}/gen.json"
check "generate: applied" "rc=$RC err=$ERR" test "$RC" -eq 0
check "generate: written lowercase" "" grep -qF '(v2) file` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: generate' "${ART}/consensus.md"
planner_crosscheck_run "$INIT" >/dev/null 2>&1
f=$(findings)
check "generate: no cited-artifact finding left (spec Source generate matches)" "$f" \
  bash -c '! grep -q "^fail|CITED_ARTIFACT" <<<"$1"' _ "$f"

# ── flag:accept still works ────────────────────────────────────────────────

echo "--- flag:accept:CITED_ARTIFACT_UNRESOLVED ---"
fresh accept
cp "${ART}/consensus.md" "${WORK}/consensus.before"
answers "${WORK}/acc.json" 1 "accept-CITED_ARTIFACT_UNRESOLVED=samples arrive after planning"
apply "${WORK}/acc.json"
check "accept: applied" "rc=$RC err=$ERR" test "$RC" -eq 0
check "accept: recorded as META|crosscheck|accepted" "" \
  grep -q '|META|crosscheck|accepted|CITED_ARTIFACT_UNRESOLVED samples arrive after planning' "$(planner_state_log "$INIT")"
check "accept: consensus.md untouched" "" cmp -s "${WORK}/consensus.before" "${ART}/consensus.md"
planner_crosscheck_run "$INIT" >/dev/null 2>&1
rc=$?
f=$(findings)
check "accept: Crosscheck no longer blocks on the code" "rc=$rc findings=$f" \
  bash -c '[ "$1" -eq 0 ] && ! grep -q "^fail|CITED_ARTIFACT_UNRESOLVED" <<<"$2"' _ "$rc" "$f"

echo "--- mixed: one per-artifact answer plus the other declined ---"
fresh mixed
answers "${WORK}/mix.json" 1 "$(qid consensus-answer:cited:3)=generate" "accept-CITED_ARTIFACT_UNRESOLVED=__skip__"
apply "${WORK}/mix.json"
check "mixed: applied, __skip__ declines the accept" "rc=$RC out=$OUT" \
  bash -c '[ "$1" -eq 0 ] && [[ "$2" == *"APPLIED=cited:3"* ]] && ! grep -q "crosscheck|accepted" "$3"' _ "$RC" "$OUT" "$(planner_state_log "$INIT")"
planner_crosscheck_run "$INIT" >/dev/null 2>&1
f=$(findings)
model=$(planner_stop_describe_json "$INIT")
check "mixed: round 2 asks only about the still-unresolved artifact" "$model" \
  test "$(jq -r '.round, ([.questions[] | select(.binding | startswith("consensus-answer:")) | .binding] | join(" "))' <<<"$model" | paste -sd' ')" = "2 consensus-answer:cited:2"

# ── planner_cited_answer_set unit cases ────────────────────────────────────

echo "--- planner_cited_answer_set ---"
U="${WORK}/unit.md"
printf '# C\r\n- CITED_ARTIFACT: `a` — x. Answer: PENDING\r\n- CITED_ARTIFACT: `b` — no answer field yet\r\n' >"$U"
planner_cited_answer_set "$U" 1 "external:ops" 2>/dev/null
rc=$?
crlf_lines=$(grep -c $'\r$' "$U")
rewritten=$(grep -c $'Answer: external:ops\r$' "$U")
check "unit: CRLF kept on the rewritten line" "rc=$rc crlf=$crlf_lines rewritten=$rewritten" \
  test "$rc" -eq 0 -a "$crlf_lines" -eq 3 -a "$rewritten" -eq 1
planner_cited_answer_set "$U" 2 "generate" 2>/dev/null
check "unit: a line with no Answer: field gets one" "$(cat "$U")" \
  grep -q 'no answer field yet Answer: generate' "$U"
planner_cited_answer_set "$U" 3 "generate" 2>/dev/null
check "unit: no such question is exit 3" "" test "$?" -eq 3
planner_cited_answer_set "$U" 0 "generate" 2>/dev/null
check "unit: index 0 is exit 2" "" test "$?" -eq 2
planner_cited_answer_set "$U" 1 "external:a|b" 2>/dev/null
check "unit: invalid value is exit 2" "" test "$?" -eq 2
cp "$U" "${WORK}/unit.before"
planner_cited_answer_set "$U" 1 "external:ops" 2>/dev/null
check "unit: the same value again is idempotent" "" cmp -s "${WORK}/unit.before" "$U"
parsed=$(_planner_cited_answers "$U" | tr '\037' ' ')
check "unit: the Crosscheck reader sees both answers" "$parsed" \
  test "$parsed" = "a external ops external:ops
b generate  generate"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
