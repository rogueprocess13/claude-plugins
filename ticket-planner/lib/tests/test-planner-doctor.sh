#!/usr/bin/env bash
# test-planner-doctor.sh — Tests for planner-doctor.sh (#232: /ticket-planner
# doctor preflight command).
#
# Every gap this file guards against was a real mid-run failure first:
# REPOS_ROOT unset/wrong, LINEAR_TEAM_ID unset, the 4 board-projected labels
# silently missing, a live REPOS_ROOT checkout on the wrong branch relative
# to Discovery (#217), a missing INIT-* label (#223).
#
# Run: bash ticket-planner/lib/tests/test-planner-doctor.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-doctor.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

# Extract VALUE|STATUS-ish fields for one NAME from a doctor output blob.
# Usage: doctor_field <output> <name> <column 2|3|4|5>
doctor_row() {
  local output="$1" name="$2"
  echo "$output" | awk -F'|' -v n="$name" '$1==n{print;exit}'
}

echo "=== planner-doctor tests ==="

# ── Test 1: REPOS_ROOT states ────────────────────────────────────────────

echo "--- Test 1: REPOS_ROOT ---"

unset LINEAR_API_KEY LINEAR_TEAM_ID
unset REPOS_ROOT
OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "REPOS_ROOT")
if echo "$ROW" | grep -q '|missing|'; then
  pass "unset REPOS_ROOT is reported missing"
else
  fail "unset REPOS_ROOT reported missing" "$ROW"
fi

export REPOS_ROOT="${TMPDIR}/does-not-exist"
OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "REPOS_ROOT")
if echo "$ROW" | grep -q '|missing|'; then
  pass "REPOS_ROOT pointing at a non-directory is reported missing"
else
  fail "non-directory REPOS_ROOT reported missing" "$ROW"
fi

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"
OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "REPOS_ROOT")
if echo "$ROW" | grep -q "|ok|${REPOS_ROOT}|"; then
  pass "a real REPOS_ROOT directory resolves ok"
else
  fail "real REPOS_ROOT resolves ok" "$ROW"
fi

# ── Test 2: Linear team + label resolution (mocked) ─────────────────────

echo "--- Test 2: team + board-projected labels ---"

MOCK_TEAMS='{"data":{"teams":{"nodes":[{"id":"team-uuid-1","key":"CRE","name":"Credit"}]}}}'
MOCK_LABELS_ALL_PRESENT='{"data":{"issueLabels":{"nodes":[
  {"id":"lbl-needs-info","name":"needs-info","team":{"id":"team-uuid-1"}},
  {"id":"lbl-needs-adr","name":"needs-adr","team":{"id":"team-uuid-1"}},
  {"id":"lbl-rejected","name":"rejected","team":{"id":"team-uuid-1"}},
  {"id":"lbl-reviewed","name":"reviewed","team":{"id":"team-uuid-1"}}
]}}}'
MOCK_LABELS_ONE_MISSING='{"data":{"issueLabels":{"nodes":[
  {"id":"lbl-needs-info","name":"needs-info","team":{"id":"team-uuid-1"}},
  {"id":"lbl-needs-adr","name":"needs-adr","team":{"id":"team-uuid-1"}},
  {"id":"lbl-rejected","name":"rejected","team":{"id":"team-uuid-1"}}
]}}}'
MOCK_CREATE_LABEL='{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"lbl-new","name":"reviewed"}}}}'

_LABELS_RESPONSE="$MOCK_LABELS_ALL_PRESENT"
planner_linear_graphql() {
  local payload="$1"
  if echo "$payload" | grep -q '"query Teams'; then
    echo "$MOCK_TEAMS"
  elif echo "$payload" | grep -q '"query LabelIds'; then
    echo "$_LABELS_RESPONSE"
  elif echo "$payload" | grep -q '"mutation CreateLabel'; then
    echo "$MOCK_CREATE_LABEL"
  fi
}

export LINEAR_API_KEY="test-key"
export LINEAR_TEAM_ID="CRE"

OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "LINEAR_TEAM_ID")
if echo "$ROW" | grep -q "|ok|team-uuid-1|"; then
  pass "team resolves via mocked Linear API"
else
  fail "team resolves" "$ROW"
fi

if echo "$OUT" | grep -q '^label:needs-info|ok|' &&
  echo "$OUT" | grep -q '^label:needs-adr|ok|' &&
  echo "$OUT" | grep -q '^label:rejected|ok|' &&
  echo "$OUT" | grep -q '^label:reviewed|ok|'; then
  pass "all 4 board-projected labels report ok when present"
else
  fail "all 4 board-projected labels ok" "$OUT"
fi

# Missing LINEAR_API_KEY → team unresolved → labels skipped, not silently ok.
unset LINEAR_API_KEY
OUT=$(planner_doctor_run 2>/dev/null)
if doctor_row "$OUT" "LINEAR_TEAM_ID" | grep -q '|missing|' &&
  echo "$OUT" | grep -q '^label:needs-info|warn|'; then
  pass "missing LINEAR_API_KEY skips (not fakes) label checks"
else
  fail "missing LINEAR_API_KEY skips label checks" "$OUT"
fi
export LINEAR_API_KEY="test-key"

# One label genuinely missing — the exact defect from #223, found twice.
_LABELS_RESPONSE="$MOCK_LABELS_ONE_MISSING"
OUT=$(planner_doctor_run 2>/dev/null)
if echo "$OUT" | grep -q '^label:reviewed|missing|'; then
  pass "a genuinely missing board-projected label is reported missing"
else
  fail "missing board-projected label reported" "$OUT"
fi
EXIT_CODE=0
planner_doctor_run >/dev/null 2>&1 || EXIT_CODE=$?
if [ "$EXIT_CODE" -gt 0 ]; then
  pass "a missing label is reflected in the non-zero return code"
else
  fail "non-zero return on missing label" "exit=$EXIT_CODE"
fi

# --fix creates the missing label instead of only reporting it.
OUT=$(planner_doctor_run --fix 2>/dev/null)
if echo "$OUT" | grep -q '^label:reviewed|fixed|lbl-new|'; then
  pass "--fix creates a genuinely missing board-projected label"
else
  fail "--fix creates missing label" "$OUT"
fi

_LABELS_RESPONSE="$MOCK_LABELS_ALL_PRESENT"

# ── Test 3: resume-scoped repo-ref check (#217) ──────────────────────────

echo "--- Test 3: resume-scoped repo-ref alignment ---"

REPO_DIR="${REPOS_ROOT}/ledgerly"
mkdir -p "${REPO_DIR}"
git -C "$REPOS_ROOT" init -q ledgerly
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test"
echo "one" >"${REPO_DIR}/a.txt"
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "baseline"
git -C "$REPO_DIR" branch -M main
BASELINE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

git -C "$REPO_DIR" checkout -q -b develop
echo "two" >"${REPO_DIR}/b.txt"
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "develop work"
DEVELOP_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
git -C "$REPO_DIR" checkout -q main

source "${LIB_DIR}/planner-state.sh"
INIT_ID="INIT-doctor-test-1"
planner_state_init "$INIT_ID" "doctor test" >/dev/null 2>&1
planner_state_write "$INIT_ID" "META" "discovery" "repo-ref" "ledgerly@develop@${DEVELOP_SHA}" >/dev/null 2>&1

OUT=$(planner_doctor_run "$INIT_ID" 2>/dev/null)
ROW=$(doctor_row "$OUT" "repo-ref:ledgerly")
if echo "$ROW" | grep -q '|ok|' && echo "$ROW" | grep -q "REPOS_ROOT/ledgerly-crosscheck"; then
  pass "a diverged live checkout gets an isolated worktree, reported ok"
else
  fail "diverged checkout ensures a worktree" "$ROW"
fi

# Live checkout already at the pinned sha — no worktree needed.
git -C "$REPO_DIR" checkout -q develop 2>/dev/null || true
INIT_ID2="INIT-doctor-test-2"
planner_state_init "$INIT_ID2" "doctor test 2" >/dev/null 2>&1
planner_state_write "$INIT_ID2" "META" "discovery" "repo-ref" "ledgerly@develop@${DEVELOP_SHA}" >/dev/null 2>&1
OUT=$(planner_doctor_run "$INIT_ID2" 2>/dev/null)
ROW=$(doctor_row "$OUT" "repo-ref:ledgerly")
if echo "$ROW" | grep -q "|ok|${DEVELOP_SHA}|REPOS_ROOT/ledgerly|"; then
  pass "a live checkout already matching Discovery's ref needs no worktree"
else
  fail "matching checkout reported ok without a worktree" "$ROW"
fi
git -C "$REPO_DIR" checkout -q main

# No initiative id — repo-ref check is informational, not a failure.
OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "repo-ref")
if echo "$ROW" | grep -q '|info|'; then
  pass "omitting the initiative id reports repo-ref as informational"
else
  fail "no-initiative-id repo-ref is informational" "$ROW"
fi

# ── Test 4: cross-plugin helper scripts resolve from this checkout ──────

echo "--- Test 4: helper scripts ---"

OUT=$(planner_doctor_run 2>/dev/null)
if doctor_row "$OUT" "planned-ticket-check.sh" | grep -q '|ok|' &&
  doctor_row "$OUT" "branch-directive-check.sh" | grep -q '|ok|'; then
  pass "cross-plugin validator scripts resolve from the sibling plugin checkout"
else
  fail "cross-plugin validators resolve" "$OUT"
fi

# ── Test 5: output shape ─────────────────────────────────────────────────

echo "--- Test 5: output shape ---"

if echo "$OUT" | grep -q '^---BEGIN_VARS---$' && echo "$OUT" | grep -q '^---END_VARS---$'; then
  pass "output is wrapped in BEGIN/END markers"
else
  fail "BEGIN/END markers present" "$OUT"
fi

ROWCOUNT_LINE=$(echo "$OUT" | grep '^ROWCOUNT=')
DECLARED=${ROWCOUNT_LINE#ROWCOUNT=}
ACTUAL=$(echo "$OUT" | sed -n '/^---BEGIN_VARS---$/,/^---END_VARS---$/p' | grep -c '|')
# ACTUAL includes the header row; DECLARED counts data rows only.
if [ "$((ACTUAL - 1))" = "$DECLARED" ]; then
  pass "ROWCOUNT matches the number of emitted data rows"
else
  fail "ROWCOUNT matches emitted rows" "declared=$DECLARED actual_data_rows=$((ACTUAL - 1))"
fi

# ── Test 6: documented label list matches the code (#457) ───────────────
# SKILL.md's Doctor section once listed the retired static contract labels
# while the code checked a different set. Tie the documented list to
# _PLANNER_DOCTOR_STATIC_LABELS, and that array to the board driver's
# projected_labels in workflow.json, so neither can drift silently again.

echo "--- Test 6: documented labels match _PLANNER_DOCTOR_STATIC_LABELS ---"

SKILL_MD="${LIB_DIR}/../skills/ticket-planner/SKILL.md"
WORKFLOW_JSON="${LIB_DIR}/../../ticket-auto-pipeline/skills/ticket-flow/workflow.json"

CODE_LABELS=$(printf '%s\n' "${_PLANNER_DOCTOR_STATIC_LABELS[@]}" | sort | tr '\n' ' ')

# The user-facing Doctor section, up to the next ### heading. The checked
# labels are the backticked names inside "board-projected labels (...)".
DOC_SECTION=$(awk '/^### Doctor \(`doctor`\)/{f=1;next} f&&/^### /{exit} f' "$SKILL_MD" | tr '\n' ' ')
DOC_LABELS=$(echo "$DOC_SECTION" | grep -o 'board-projected labels ([^)]*)' | head -1 |
  grep -o '`[^`]*`' | tr -d '`' | sort | tr '\n' ' ')

if [ -n "$DOC_LABELS" ] && [ "$DOC_LABELS" = "$CODE_LABELS" ]; then
  pass "SKILL.md Doctor section lists exactly the labels doctor checks"
else
  fail "SKILL.md Doctor labels match code" "doc='$DOC_LABELS' code='$CODE_LABELS'"
fi

if command -v jq >/dev/null 2>&1 && [ -f "$WORKFLOW_JSON" ]; then
  WF_LABELS=$(jq -r '.board_drivers.linear.projected_labels[]' "$WORKFLOW_JSON" | sort | tr '\n' ' ')
  if [ "$WF_LABELS" = "$CODE_LABELS" ]; then
    pass "_PLANNER_DOCTOR_STATIC_LABELS matches workflow.json projected_labels"
  else
    fail "doctor labels match projected_labels" "workflow='$WF_LABELS' code='$CODE_LABELS'"
  fi
else
  fail "workflow.json projected_labels readable" "jq or $WORKFLOW_JSON missing"
fi

# ── Test 7: no doc describes a retired planner label as live (#469) ─────
# #457 fixed the Doctor section only; plugin-overview.md and SKILL.md kept
# describing `planned`/`epic`/`pre-approved`/`state:execution` as labels
# the planner applies and ticket-auto/fleet-controller read. A mention of a
# retired label is fine only when the same block says it is historical.
# A block is one list item, one table (all of its `|` rows, so a "Former
# label" header covers its rows), or one blank-line-separated paragraph.

# retired_label_stragglers <file> — print every block that names a retired
# label without a historical marker. Empty output means the file is clean.
retired_label_stragglers() {
  awk '
    function flush() {
      if (blk != "" && blk ~ /(`(planned|epic|pre-approved)`|state:execution)/ &&
        tolower(blk) !~ /(retired|historical|former|replaced|replacement|no longer|used to|not a label|never a label)/)
        print FILENAME ":" start ": " substr(blk, 1, 160)
      blk = ""
    }
    /^```/ { flush(); fence = !fence; next }
    fence { next }
    /^[[:space:]]*$/ { flush(); intable = 0; next }
    /^[[:space:]]*\|/ { if (!intable) { flush(); intable = 1; start = NR } blk = blk " " $0; next }
    /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]/ { flush(); intable = 0; start = NR; blk = $0; next }
    { if (blk == "") start = NR; intable = 0; blk = blk " " $0 }
    END { flush() }
  ' "$1"
}

echo "--- Test 7: ticket-planner docs never describe retired labels as live ---"

# Negative control: the passages #469 found must be caught.
cat >"$TMPDIR/old-doc.md" <<'OLD'
## Key design decisions

- **`state:execution` is set by TicketGen, not EpicGen.** The epic is created without the execution label.
- [ticket-auto-pipeline](../ticket-auto-pipeline/) — Downstream consumer. Reads Planner Context blocks, fast-paths `planned`+`pre-approved` tickets.

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_CONFIDENCE_THRESHOLD` | 0.85 | Minimum confidence for `pre-approved` label |
OLD
OLD_HITS=$(retired_label_stragglers "$TMPDIR/old-doc.md" | wc -l)
if [ "$OLD_HITS" -eq 3 ]; then
  pass "detector catches the 3 live-label passages in the old-doc fixture"
else
  fail "detector catches old passages" "expected 3 hits, got $OLD_HITS"
fi

# Positive control: a mention marked as historical is allowed.
printf '%s\n' '- The epic manifest `dispatch` flag replaced the retired `state:execution` label.' >"$TMPDIR/new-doc.md"
if [ -z "$(retired_label_stragglers "$TMPDIR/new-doc.md")" ]; then
  pass "detector allows a mention marked as historical"
else
  fail "detector allows historical mention" "$(retired_label_stragglers "$TMPDIR/new-doc.md")"
fi

PLANNER_ROOT="${LIB_DIR}/.."
STRAGGLERS=""
for doc in "$PLANNER_ROOT"/README.md "$PLANNER_ROOT"/CLAUDE.md "$PLANNER_ROOT"/plugin-overview.md \
  "$PLANNER_ROOT"/state-log-format.md "$PLANNER_ROOT"/skills/ticket-planner/SKILL.md "$PLANNER_ROOT"/docs/*.md; do
  [ -f "$doc" ] || continue
  STRAGGLERS="${STRAGGLERS}$(retired_label_stragglers "$doc")"
done
if [ -z "$STRAGGLERS" ]; then
  pass "no ticket-planner doc describes a retired label as live"
else
  fail "retired labels described as live" "$STRAGGLERS"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
