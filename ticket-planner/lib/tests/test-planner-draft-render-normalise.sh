#!/usr/bin/env bash
# test-planner-draft-render-normalise.sh — the draft readiness gate's
# markdown-rendering normaliser (planner_draft_render_normalise) and the two
# places that depend on it.
#
# Linear re-renders a stored description: `- ` list markers become `* `,
# `[x]` becomes `[X]`, table separator rows shrink to `| -- |`, `#` in a cell
# is escaped `\#`, a bold span is split around inline code, and a blank line
# appears after a heading that had none. Before the normaliser, a draft and
# the body Linear handed back never compared equal, so no draft verdict was
# ever imported, and the carry-over read every rendered unit as changed.
#
# Covers:
#   1. The normaliser maps a synthetic Linear rendering onto its draft.
#   2. Real content edits still compare unequal: a changed criterion, a
#      changed test-data value, a dropped list item, a changed table cell,
#      inline-code and fenced-code edits, a changed heading.
#   3. planner_draft_readiness_equivalent: rendering → equivalent; an edited
#      criterion or test-data value → not equivalent.
#   4. Carry-over unit hashing: no unit of a rendered body reads as changed;
#      an edited criterion is the only changed unit.
#
# Usage: bash ticket-planner/lib/tests/test-planner-draft-render-normalise.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="${TMP_ROOT}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${TMP_ROOT}/repos"
mkdir -p "$REPOS_ROOT"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-draft-carryover.sh"
_planner_refinement_source_deps || exit 1
_planner_refinement_source_baseline >/dev/null || exit 1

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

echo "=== planner draft render normaliser ==="

# A synthetic draft (no ticket ids or user data) and its Linear rendering.
cat >"${TMP_ROOT}/draft.md" <<'MD'
## Summary
Readers can open an article page.

**Article page (`/article/<slug>`)** — shows the title and body.

## Scope
- Add a page module:
  - render the title;
  - render the body as text.
- Add a route.

## Acceptance Criteria
- [ ] Opening `/article/a-slug` shows the title "A title".
- [ ] An unknown slug shows "Article not found".

## Environment
- [x] Local (`frontend/` on port 5173)

## Test Data Prerequisites
- 2 `article` records. Source: seeded-by:store-seed

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Expected behavior | Verifiable |
|---|-----------|-------------------|------------|
| 1 | Opening `/article/a-slug` shows the title | title "A title" | ✓ |

| Field | Value | Note |
| ----- | ------- | ---- |
| port | 5173 | dev |

## Technical Context
```js
const x = a ** b; // - not a list
```

## Planner Context
**Schema-Version:** 1
**Epic:** DRAFT
MD

cat >"${TMP_ROOT}/linear.md" <<'MD'
## Summary

Readers can open an article page.

**Article page (**`/article/<slug>`**)** — shows the title and body.

## Scope

* Add a page module:
  * render the title;
  * render the body as text.
* Add a route.

## Acceptance Criteria

- [ ] Opening `/article/a-slug` shows the title "A title".
- [ ] An unknown slug shows "Article not found".

## Environment

- [X] Local (`frontend/` on port 5173)

## Test Data Prerequisites

* 2 `article` records. Source: seeded-by:store-seed

## Verification Plan

### Per-Criterion Verification

| \# | Criterion | Expected behavior | Verifiable |
| -- | -- | -- | -- |
| 1 | Opening `/article/a-slug` shows the title | title "A title" | ✓ |

| Field | Value | Note |
| -- | -- | -- |
| port | 5173 | dev |

## Technical Context

```js
const x = a ** b; // - not a list
```

## Planner Context

**Schema-Version:** 1
**Epic:** DRAFT

MD

norm() { planner_draft_render_normalise <"$1" | _body_baseline_normalise; }

# ── 1. rendering is undone ────────────────────────────────────────────────
echo "--- 1. Linear rendering normalises onto the draft ---"
if [ "$(cat "${TMP_ROOT}/draft.md")" != "$(cat "${TMP_ROOT}/linear.md")" ] &&
  [ "$(norm "${TMP_ROOT}/draft.md")" = "$(norm "${TMP_ROOT}/linear.md")" ]; then
  pass "rendered body normalises equal to the draft"
else
  fail "rendering" "$(diff <(norm "${TMP_ROOT}/draft.md") <(norm "${TMP_ROOT}/linear.md") | head -10)"
fi
out=$(printf '%s\n' '```' '* x' '| -- |' '\# **b**' '```' | planner_draft_render_normalise)
[ "$out" = $'```\n* x\n| -- |\n\\# **b**\n```' ] && pass "fenced block untouched" || fail "fence" "$out"
out=$(printf '%s\n' 'a `x**y\#z` b **c** \#d' | planner_draft_render_normalise)
[ "$out" = 'a `x**y\#z` b c #d' ] && pass "inline code untouched, bold and escape outside it normalised" || fail "inline" "$out"
a=$(printf '%s\n' '+ 2 seats' | planner_draft_render_normalise)
b=$(printf '%s\n' '- 2 seats' | planner_draft_render_normalise)
[ "$a" != "$b" ] && pass "a leading + is not read as a list marker (it can be a sign)" || fail "plus" "$a"
out=$(printf '%s\n' '| a | b |' '|:---|---:|' 'x' | planner_draft_render_normalise)
[ "$out" = $'| a | b |\n|---|---|\nx' ] && pass "alignment separator keeps its column count" || fail "separator" "$out"
out=$(printf '%s\n' '| a | b |' '| -- | -- |' '| -- | -- |' | planner_draft_render_normalise)
[ "$out" = $'| a | b |\n|---|---|\n| -- | -- |' ] && pass "only a table's second row is a separator" || fail "second row" "$out"

# Pairs that must stay unequal (security review): _ne <label> <a> <b>.
_ne() {
  local a b
  a=$(printf '%s\n' "$2" | planner_draft_render_normalise)
  b=$(printf '%s\n' "$3" | planner_draft_render_normalise)
  [ "$a" != "$b" ] && pass "$1 stays unequal" || fail "$1" "both normalise to: $a"
}
_ne "exponent 10**3 vs 103" '- Limit is 10**3 requests' '- Limit is 103 requests'
_ne "escaped pipe in a cell" '| role | admin\|editor |' '| role | admin|editor |'
_ne "escaped backslash" 'Path C:\\tmp' 'Path C:\tmp'
_ne "escaped backtick keeps code closed" 'a \` then `x**2` end' 'a \` then `x2` end'
_ne "unpaired backtick line untouched" 'don`t do `a**b` x' 'don`t do `ab` x'
_ne "indented code untouched" '    {"pw": "x**y"}' '    {"pw": "xy"}'
f1=$(printf '%s\n' '```' '~~~' 'v = 2**8' '```' | planner_draft_render_normalise)
f2=$(printf '%s\n' '```' '~~~' 'v = 28' '```' | planner_draft_render_normalise)
[ "$f1" != "$f2" ] && pass "a ~~~ line does not close a backtick fence" || fail "fence type" "$f1"
f1=$(printf '%s\n' '````' '```' 'v = 2**8' '````' | planner_draft_render_normalise)
f2=$(printf '%s\n' '````' '```' 'v = 28' '````' | planner_draft_render_normalise)
[ "$f1" != "$f2" ] && pass "a shorter fence does not close a longer one" || fail "fence length" "$f1"
a=$(printf '%s\n' '| - | - |' | planner_draft_render_normalise)
b=$(printf '%s\n' '| - | x |' | planner_draft_render_normalise)
[ "$a" = '| - | - |' ] && [ "$a" != "$b" ] && pass "a data row of single-dash cells is content, not a separator" || fail "dash row" "$a / $b"
a=$(printf '%s\n' '- |' | planner_draft_render_normalise)
[ "$a" = '- |' ] && pass "a list item ending in a pipe is not a separator" || fail "list pipe" "$a"
out=$(printf '%s\n' '| a | b |' '| -- | -- | -- |' | planner_draft_render_normalise)
[ "$out" = $'| a | b |\n|---|---|---|' ] && pass "a separator with another column count stays different" || fail "cols" "$out"

# ── 2. real edits stay unequal ────────────────────────────────────────────
echo "--- 2. content edits still differ ---"
# _edit <label> <sed-expression>: the edit applied to the Linear rendering
# must not normalise equal to the draft.
_edit() {
  sed -e "$2" "${TMP_ROOT}/linear.md" >"${TMP_ROOT}/edit.md"
  if cmp -s "${TMP_ROOT}/edit.md" "${TMP_ROOT}/linear.md"; then
    fail "$1" "fixture edit did not apply"
  elif [ "$(norm "${TMP_ROOT}/draft.md")" != "$(norm "${TMP_ROOT}/edit.md")" ]; then
    pass "$1 compares unequal"
  else
    fail "$1" "normalised equal"
  fi
}
_edit "changed criterion" 's/shows "Article not found"/shows "Not found"/'
_edit "criterion checkbox ticked" 's/^- \[ \] An unknown/- [x] An unknown/'
_edit "changed test-data count" 's/^\* 2 `article` records/* 3 `article` records/'
_edit "changed test-data source" 's/seeded-by:store-seed/exists:store-seed/'
_edit "dropped list item" '/render the body as text/d'
_edit "changed table cell" 's/| port | 5173 | dev |/| port | 5174 | dev |/'
_edit "edit inside inline code" 's|`/article/a-slug` shows the title "A title"\.|`/article/b-slug` shows the title "A title".|'
_edit "edit inside a fenced block" 's/a \*\* b/a * b/'
_edit "changed heading" 's/^## Scope$/## Out of Scope/'
_edit "list item demoted to prose" 's/^\* Add a route\./Add a route./'

# ── 3. equivalence through the token map ──────────────────────────────────
echo "--- 3. planner_draft_readiness_equivalent ---"
MAP="${TMP_ROOT}/map.tsv"
printf 'DRAFT\tEPIC-9\n' >"$MAP"
sed 's/^\*\*Epic:\*\* DRAFT$/**Epic:** EPIC-9/' "${TMP_ROOT}/linear.md" >"${TMP_ROOT}/real.md"
if planner_draft_readiness_equivalent "$MAP" "${TMP_ROOT}/real.md" "${TMP_ROOT}/draft.md"; then
  pass "Linear-rendered real body is equivalent to its draft"
else
  fail "equivalent" "$(diff <(planner_draft_readiness_equiv_text "$MAP" real <"${TMP_ROOT}/real.md") \
    <(planner_draft_readiness_equiv_text "$MAP" draft <"${TMP_ROOT}/draft.md") | head)"
fi
sed 's/shows "Article not found"/shows "Gone"/' "${TMP_ROOT}/real.md" >"${TMP_ROOT}/real-edit.md"
rc=0
planner_draft_readiness_equivalent "$MAP" "${TMP_ROOT}/real-edit.md" "${TMP_ROOT}/draft.md" || rc=$?
[ "$rc" = 1 ] && pass "edited criterion: not equivalent" || fail "edited" "rc=$rc"
sed 's/^\* 2 `article`/* 5 `article`/' "${TMP_ROOT}/real.md" >"${TMP_ROOT}/real-td.md"
rc=0
planner_draft_readiness_equivalent "$MAP" "${TMP_ROOT}/real-td.md" "${TMP_ROOT}/draft.md" || rc=$?
[ "$rc" = 1 ] && pass "edited test data: not equivalent" || fail "test data" "rc=$rc"

# ── 4. carry-over unit hashing ────────────────────────────────────────────
echo "--- 4. carry-over remap ignores rendering ---"
# _changed <real> <mode>: real-body keys whose remapped hash is not the real
# body's own (read as changed by dor_semantic_lineage_from).
_changed() {
  local real="$1" mode="$2" r d out
  if [ "$mode" = units ]; then
    r=$(_dor_unit_hashes "$(cat "$real")")
    d=$(_dor_unit_hashes "$(cat "${TMP_ROOT}/draft.md")")
  else
    r=$(_dor_section_hashes "$(cat "$real")")
    d=$(_dor_section_hashes "$(cat "${TMP_ROOT}/draft.md")")
  fi
  out=$(_planner_draft_carryover_remap "$real" "${TMP_ROOT}/draft.md" "$MAP" "$mode" "$r" "$d") || return 1
  jq -nr --argjson r "$r" --argjson o "$out" '[$r | to_entries[] | select($o[.key] != .value) | .key] | join(",")'
}
c=$(_changed "${TMP_ROOT}/real.md" units)
[ -z "$c" ] && pass "no unit of the rendered body reads as changed" || fail "units" "$c"
c=$(_changed "${TMP_ROOT}/real.md" sections)
[ -z "$c" ] && pass "no section of the rendered body reads as changed" || fail "sections" "$c"
c=$(_changed "${TMP_ROOT}/real-edit.md" units)
if [[ "$c" == "Acceptance Criteria/ac:"* ]] && [[ "$c" != *,* ]]; then
  pass "an edited criterion is the only changed unit"
else
  fail "edited unit" "$c"
fi

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
