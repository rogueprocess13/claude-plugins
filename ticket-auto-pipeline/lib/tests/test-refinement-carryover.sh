#!/usr/bin/env bash
# test-refinement-carryover.sh — refinement-carryover.sh (planner-refinement-
# convergence group 4, design D7 and the appraisal half of D6): item tags per
# code, test candidates, demotions, unverified excluded, the empty case,
# idempotent append, the Open Questions mirror and the appraisal drift hold.
# Usage: bash test-refinement-carryover.sh
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}
_eq() {
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1 (expected '$3', got '$2')"; fi
}
_has() {
  if printf '%s' "$2" | grep -qF -- "$3"; then _pass "$1"; else _fail "$1 (missing '$3')"; fi
}
_lacks() {
  if printf '%s' "$2" | grep -qF -- "$3"; then _fail "$1 (unexpected '$3')"; else _pass "$1"; fi
}
_count() { printf '%s\n' "$1" | grep -cF -- "$2" || true; }

# ── No leak of shell state on source ──────────────────────────────────────
leak=$(
  set +e +u +o pipefail
  SCRIPT_DIR="/sentinel/dir"
  before=$(set +o)
  # shellcheck disable=SC1091
  source "$LIB_DIR/refinement-carryover.sh"
  after=$(set +o)
  [ "$before" = "$after" ] && echo -n "opts-ok "
  [ "$SCRIPT_DIR" = "/sentinel/dir" ] && echo -n "dir-ok "
  declare -f refinement_carryover_append >/dev/null && declare -f body_baseline_classify >/dev/null && echo -n "fn-ok"
)
_eq "source leaks no shell options, keeps SCRIPT_DIR, pulls in body-baseline" "$leak" "opts-ok dir-ok fn-ok"

source "$LIB_DIR/manifest-write.sh"
source "$LIB_DIR/refinement-carryover.sh"

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
unset LOG_FILE

# _seed <TID> <ready-json> — planned manifest under INIT-1 with <ready-json>.
_seed() {
  local tid="$1" ready="$2" path
  write_ticket_manifest "$tid" "INIT-1" "feature" '[]' >/dev/null
  path=$(get_ticket_manifest_path "$tid")
  jq --argjson r "$ready" '.ready = $r' "$path" >"$path.tmp" && mv "$path.tmp" "$path"
}
_f() { # _f <code> <severity> <verified> [<demoted>] [<id>]
  jq -nc --arg c "$1" --arg s "$2" --argjson v "$3" --arg d "${4:-}" --arg i "${5:-}" \
    '{code: $c, severity: $s, verified: $v, quote: ("quote for " + $c), detail: ("detail for " + $c)}
     + (if $d != "" then {demoted: $d} else {} end) + (if $i != "" then {id: $i} else {} end)'
}
_ready() { # _ready <findings-array> [<demoted-object>] [<semantic-extra>]
  jq -nc --argjson f "$1" --argjson d "${2:-{\}}" --argjson x "${3:-{\}}" \
    '{status: "ready", missing: [], advisory: [], body_hash: "sha256:x",
      semantic: ({evaluator: "dor-semantic-v3", findings: $f} + $x)}
     + (if ($d | length) > 0 then {demoted: $d} else {} end)'
}
_notes() { # _notes <file> — a minimal appraisal notes.md
  printf '%s\n' "# Working Notes — T" "" "## Open Questions" "" "- [agent-resolvable] Verify target symbols." "" "## Next Steps" "" "- Do it." >"$1"
}

# ── Item tags per code ────────────────────────────────────────────────────
F=$(printf '%s\n' \
  "$(_f EDGE_CASE_GAP advisory true round-limit f-edge00000001)" \
  "$(_f AC_NOT_TESTABLE advisory true drift)" \
  "$(_f TEST_DATA_GAP advisory true)" \
  "$(_f SCOPE_AMBIGUOUS advisory true round-limit f-scope0000001)" \
  "$(_f MISSING_CORE_AC advisory true round-limit f-core00000001)" \
  "$(_f INTENT_AC_MISMATCH blocking true)" \
  "$(_f EDGE_CASE_GAP advisory false)" | jq -sc .)
D='{"VPLAN_ROW_GAP":{"by":"dor-semantic-audit","reason":"row 2 covers both","quote":"| 2 | toast |","body_hash":"sha256:x"}}'
_seed PRO-1 "$(_ready "$F" "$D")"
sec=$(refinement_carryover_section PRO-1)

_has "heading" "$sec" "## Refinement Carry-over"
_has "EDGE_CASE_GAP is agent-resolvable, names the demotion" "$sec" '- [agent-resolvable] `EDGE_CASE_GAP` (demoted: round-limit, does not block): detail for EDGE_CASE_GAP — quote: "quote for EDGE_CASE_GAP" (carry-over f-edge00000001)'
_has "AC_NOT_TESTABLE is agent-resolvable" "$sec" '- [agent-resolvable] `AC_NOT_TESTABLE`'
_has "TEST_DATA_GAP is agent-resolvable" "$sec" '- [agent-resolvable] `TEST_DATA_GAP`'
_has "SCOPE_AMBIGUOUS is needs-human" "$sec" '- [needs-human] `SCOPE_AMBIGUOUS`'
_has "demotion is agent-resolvable with its reason and quote" "$sec" '- [agent-resolvable] `VPLAN_ROW_GAP` demoted by audit dispute (does not block): row 2 covers both — quote: "| 2 | toast |" (carry-over demoted:VPLAN_ROW_GAP)'
_has "test candidates sub-section" "$sec" "### Test candidates"
_has "MISSING_CORE_AC is a test candidate" "$sec" '- `MISSING_CORE_AC`: detail for MISSING_CORE_AC — quote: "quote for MISSING_CORE_AC" (candidate f-core00000001)'
_lacks "MISSING_CORE_AC is not a tagged item" "$sec" '] `MISSING_CORE_AC`'
_lacks "a blocking finding is not carried" "$sec" "INTENT_AC_MISMATCH"
_eq "an unverified finding is not carried" "$(_count "$sec" '`EDGE_CASE_GAP`')" "1"
cand_line=$(printf '%s\n' "$sec" | grep -n '### Test candidates' | cut -d: -f1)
scope_line=$(printf '%s\n' "$sec" | grep -n 'SCOPE_AMBIGUOUS' | cut -d: -f1)
if [ "$scope_line" -lt "$cand_line" ]; then _pass "tagged items precede test candidates"; else _fail "tagged items precede test candidates"; fi

# ── Append, Open Questions mirror, idempotency ────────────────────────────
N="$TMP_ROOT/notes-1.md"
_notes "$N"
refinement_carryover_append "$N" PRO-1
c1=$(cat "$N")
_eq "one carry-over heading" "$(_count "$c1" '## Refinement Carry-over')" "1"
oq=$(sed -n '/^## Open Questions/,/^## Next Steps/p' "$N")
_has "needs-human item mirrored into Open Questions" "$oq" '- [needs-human] `SCOPE_AMBIGUOUS`'
_has "existing Open Questions bullet kept" "$oq" "- [agent-resolvable] Verify target symbols."
_lacks "agent-resolvable carry-over items stay out of Open Questions" "$oq" "EDGE_CASE_GAP"
_lacks "test candidates stay out of Open Questions" "$oq" "MISSING_CORE_AC"
_has "Next Steps kept" "$c1" "- Do it."
refinement_carryover_append "$N" PRO-1
c2=$(cat "$N")
_eq "append twice is byte-identical" "$c2" "$c1"
_eq "after two appends the item is in the section and Open Questions only" "$(_count "$c2" '- [needs-human] `SCOPE_AMBIGUOUS`')" "2"

# a struck-through (answered) mirror is never re-added
sed -i 's/^- \[needs-human\] `SCOPE_AMBIGUOUS`\(.*\)$/- ~~[needs-human] `SCOPE_AMBIGUOUS`\1~~/' "$N"
sed -i '/^## Refinement Carry-over/,$ s/^- ~~\(\[needs-human\].*\)~~$/- \1/' "$N"
refinement_carryover_append "$N" PRO-1
oq=$(sed -n '/^## Open Questions/,/^## Next Steps/p' "$N")
_eq "answered mirror not re-added" "$(_count "$oq" 'SCOPE_AMBIGUOUS')" "1"
_has "answered mirror stays struck" "$oq" '- ~~[needs-human] `SCOPE_AMBIGUOUS`'

# replace in place: a later section stays after the carry-over
N2="$TMP_ROOT/notes-2.md"
_notes "$N2"
refinement_carryover_append "$N2" PRO-1
printf '\n## Session Log\n\n- later entry\n' >>"$N2"
refinement_carryover_append "$N2" PRO-1
tail_heading=$(grep '^## ' "$N2" | tail -1)
_eq "replace keeps the section in place" "$tail_heading" "## Session Log"
_eq "still one carry-over heading" "$(_count "$(cat "$N2")" '## Refinement Carry-over')" "1"

# ── Nothing to carry ──────────────────────────────────────────────────────
_seed PRO-2 "$(_ready '[]')"
_eq "no findings → empty section" "$(refinement_carryover_section PRO-2)" ""
N3="$TMP_ROOT/notes-3.md"
_notes "$N3"
before=$(cat "$N3")
refinement_carryover_append "$N3" PRO-2
_eq "no findings → notes.md unchanged" "$(cat "$N3")" "$before"

_seed PRO-3 "$(_ready "$(jq -nc --argjson a "$(_f EDGE_CASE_GAP advisory false)" '[$a]')")"
_eq "only unverified findings → empty section" "$(refinement_carryover_section PRO-3)" ""

_seed PRO-4 "$(_ready "$(jq -nc --argjson a "$(_f EDGE_CASE_GAP advisory true)" '[$a]')" '{}' '{"stale":true}')"
_eq "stale verdict → empty section" "$(refinement_carryover_section PRO-4)" ""

_seed PRO-5 '{"status":"ready","missing":[],"advisory":[]}'
_eq "no semantic verdict → empty section" "$(refinement_carryover_section PRO-5)" ""

# a section that was carried earlier is removed once nothing is left
N4="$TMP_ROOT/notes-4.md"
_notes "$N4"
refinement_carryover_append "$N4" PRO-1
cp "$(get_ticket_manifest_path PRO-2)" "$(get_ticket_manifest_path PRO-1)"
refinement_carryover_append "$N4" PRO-1
_eq "emptied carry-over removes the section" "$(_count "$(cat "$N4")" '## Refinement Carry-over')" "0"

# only test candidates: no tagged bullets, no mirror
_seed PRO-6 "$(_ready "$(jq -nc --argjson a "$(_f MISSING_CORE_AC advisory true)" '[$a]')")"
N5="$TMP_ROOT/notes-5.md"
_notes "$N5"
refinement_carryover_append "$N5" PRO-6
c5=$(cat "$N5")
_has "candidate-only section has the sub-section" "$c5" "### Test candidates"
_lacks "candidate-only section adds no Open Question" "$(sed -n '/^## Open Questions/,/^## Next Steps/p' "$N5")" "MISSING_CORE_AC"

# ── Errors ────────────────────────────────────────────────────────────────
rc=0
refinement_carryover_append "$TMP_ROOT/absent.md" PRO-1 2>/dev/null || rc=$?
_eq "missing notes file → 1" "$rc" "1"
rc=0
refinement_carryover_section NOPE-1 >/dev/null 2>&1 || rc=$?
_eq "no manifest → 1" "$rc" "1"

# ── Appraisal drift hold (D6) ─────────────────────────────────────────────
BODY=$'## Summary\nVersion A'
_drift_seed() { # _drift_seed <TID> <status> <body> <baseline-text|-none->
  _seed "$1" "$(jq -nc --arg s "$2" '{status: $s, missing: [], advisory: []}')"
  local pdir
  pdir=$(dirname "$(get_ticket_manifest_path "$1")")
  printf '%s' "$3" >"$pdir/body.md"
  if [ "$4" != "-none-" ]; then body_baseline_write "$pdir" "$4"; fi
}

export LOG_FILE="$TMP_ROOT/pipeline.log"
: >"$LOG_FILE"
_drift_seed PRO-10 ready "$BODY" "$BODY"
N6="$TMP_ROOT/notes-6.md"
_notes "$N6"
out=$(refinement_carryover_drift_check PRO-10 "$N6" $'## Summary\nVersion B')
_eq "ready + adopt → prints adopt" "$out" "adopt"
oq=$(sed -n '/^## Open Questions/,/^## Next Steps/p' "$N6")
_has "drift question names --refresh-bodies with the initiative" "$oq" '- [needs-human] Linear description differs from the body Refinement evaluated (adopt) — run `/ticket-planner resume INIT-1 --refresh-bodies` or confirm the Linear text.'
_has "drift logged" "$(cat "$LOG_FILE")" "|META|body-drift|info|adopt"
_eq "body.md never written" "$(cat "$(dirname "$(get_ticket_manifest_path PRO-10)")/body.md")" "$BODY"
refinement_carryover_drift_check PRO-10 "$N6" $'## Summary\nVersion B' >/dev/null
_eq "drift question added once" "$(_count "$(cat "$N6")" '(carry-over body-drift:')" "1"
# The key names the drifted text: a question answered for one Linear edit must
# not swallow the next one (fail-open), while the same text stays answered.
sed -i 's/^- \(\[needs-human\] Linear description differs.*\)$/- ~~\1~~/' "$N6"
refinement_carryover_drift_check PRO-10 "$N6" $'## Summary\nVersion B' >/dev/null
_eq "answered drift question for the same text not re-added" "$(_count "$(cat "$N6")" '(carry-over body-drift:')" "1"
refinement_carryover_drift_check PRO-10 "$N6" $'## Summary\nVersion D' >/dev/null
_eq "a new Linear edit after an answered drift question adds a new one" "$(_count "$(cat "$N6")" '(carry-over body-drift:')" "2"
_eq "the new drift question is open" "$(grep -c '^- \[needs-human\] Linear description differs' "$N6")" "1"
# A key quoted mid-line in some other bullet does not count as already asked.
N6b="$TMP_ROOT/notes-6b.md"
_notes "$N6b"
key=$(sed -n 's/.*\((carry-over body-drift:[^)]*)\)~~$/\1/p' "$N6" | head -1)
sed -i "/^## Open Questions/a - [agent-resolvable] Earlier note mentioned ${key} in passing." "$N6b"
refinement_carryover_drift_check PRO-10 "$N6b" $'## Summary\nVersion B' >/dev/null
_eq "a key mentioned mid-line is not a dedup match" "$(grep -c '^- \[needs-human\] Linear description differs' "$N6b")" "1"

_drift_seed PRO-11 ready "$BODY" $'## Summary\nOld'
N7="$TMP_ROOT/notes-7.md"
_notes "$N7"
_eq "ready + conflict → held" "$(refinement_carryover_drift_check PRO-11 "$N7" $'## Summary\nVersion C')" "conflict"
_has "conflict question" "$(cat "$N7")" "(conflict)"

_drift_seed PRO-12 ready $'## Summary\nLocal edit' "$BODY"
N8="$TMP_ROOT/notes-8.md"
_notes "$N8"
_eq "ready + local-ahead → held" "$(refinement_carryover_drift_check PRO-12 "$N8" "$BODY")" "local-ahead"
_has "local-ahead question" "$(cat "$N8")" "(local-ahead)"

_drift_seed PRO-13 ready "$BODY" "$BODY"
N9="$TMP_ROOT/notes-9.md"
_notes "$N9"
before=$(cat "$N9")
_eq "clean → no hold" "$(refinement_carryover_drift_check PRO-13 "$N9" $'## Summary\r\nVersion A\r\n')" "clean"
_eq "clean → notes unchanged" "$(cat "$N9")" "$before"

_drift_seed PRO-14 ready "$BODY" -none-
_eq "no baseline, same text → rebaseline, no hold" "$(refinement_carryover_drift_check PRO-14 "$N9" "$BODY")" "rebaseline"
_eq "rebaseline → notes unchanged" "$(cat "$N9")" "$before"

_drift_seed PRO-15 not-ready "$BODY" "$BODY"
_eq "not-ready ticket is skipped" "$(refinement_carryover_drift_check PRO-15 "$N9" "changed")" "skip:not-ready"
_eq "not-ready → notes unchanged" "$(cat "$N9")" "$before"

_eq "ticket with no planner directory is skipped" "$(refinement_carryover_drift_check ADHOC-1 "$N9" "changed")" "skip:not-planned"
_eq "no planner dir → notes unchanged" "$(cat "$N9")" "$before"

_seed PRO-16 '{"status":"ready","missing":[],"advisory":[]}'
_eq "ready ticket with no body.md is skipped" "$(refinement_carryover_drift_check PRO-16 "$N9" "x")" "skip:no-body"

# description fetched through get_issue when not passed
get_issue() { jq -nc --arg d $'## Summary\nVersion B' '{description: $d}'; }
_drift_seed PRO-17 ready "$BODY" "$BODY"
N10="$TMP_ROOT/notes-10.md"
_notes "$N10"
_eq "description fetched via get_issue" "$(refinement_carryover_drift_check PRO-17 "$N10")" "adopt"
get_issue() { return 1; }
_eq "failed fetch is skipped" "$(refinement_carryover_drift_check PRO-17 "$N10")" "skip:read-failed"
unset -f get_issue

strict=$(
  set -euo pipefail
  refinement_carryover_drift_check PRO-13 "$N9" "$BODY"
  refinement_carryover_append "$N9" PRO-2
  echo survived
)
_eq "set -euo pipefail caller survives clean/empty paths" "$strict" $'clean\nsurvived'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
