#!/usr/bin/env bash
# test-body-baseline.sh — body-baseline.sh (planner-refinement-convergence
# group 4, design D6): the normalised hash, the baseline file and every
# classify case in the D6 table, plus no leak of shell state on source.
# Usage: bash test-body-baseline.sh
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

# ── No leak of shell state on source ──────────────────────────────────────
leak=$(
  set +e +u +o pipefail
  SCRIPT_DIR="/sentinel/dir"
  before=$(set +o)
  # shellcheck disable=SC1091
  source "$LIB_DIR/body-baseline.sh"
  after=$(set +o)
  [ "$before" = "$after" ] && echo -n "opts-ok "
  [ "$SCRIPT_DIR" = "/sentinel/dir" ] && echo -n "dir-ok "
  declare -f body_baseline_hash >/dev/null && echo -n "fn-ok"
)
_eq "source leaks no shell options, keeps SCRIPT_DIR, defines the API" "$leak" "opts-ok dir-ok fn-ok"

source "$LIB_DIR/body-baseline.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# ── body_baseline_hash: shape and normalisation ───────────────────────────
base=$'## Summary\nDo the thing.\n\n## Acceptance Criteria\n- [ ] it works'
h=$(body_baseline_hash "$base")
if [[ "$h" =~ ^[0-9a-f]{64}$ ]]; then _pass "hash is 64 hex"; else _fail "hash is 64 hex (got '$h')"; fi

crlf=$'## Summary\r\nDo the thing.\r\n\r\n## Acceptance Criteria\r\n- [ ] it works\r\n'
_eq "CRLF hashes as LF" "$(body_baseline_hash "$crlf")" "$h"
trail=$'## Summary  \nDo the thing.\t\n\n## Acceptance Criteria \n- [ ] it works   '
_eq "trailing whitespace per line ignored" "$(body_baseline_hash "$trail")" "$h"
blanks=$'## Summary\nDo the thing.\n\n## Acceptance Criteria\n- [ ] it works\n\n\n  \n'
_eq "trailing blank lines dropped" "$(body_baseline_hash "$blanks")" "$h"
nofinal=$(printf '%s' "$base")
withfinal=$(printf '%s\n' "$base")
_eq "final newline ignored" "$(body_baseline_hash "$withfinal")" "$(body_baseline_hash "$nofinal")"

lead=$'  ## Summary\nDo the thing.\n\n## Acceptance Criteria\n- [ ] it works'
if [ "$(body_baseline_hash "$lead")" != "$h" ]; then _pass "leading whitespace is significant"; else _fail "leading whitespace is significant"; fi
interior=$'## Summary\nDo the thing.\n\n\n## Acceptance Criteria\n- [ ] it works'
if [ "$(body_baseline_hash "$interior")" != "$h" ]; then _pass "interior blank lines are significant"; else _fail "interior blank lines are significant"; fi
edited=$'## Summary\nDo the other thing.\n\n## Acceptance Criteria\n- [ ] it works'
if [ "$(body_baseline_hash "$edited")" != "$h" ]; then _pass "a text edit changes the hash"; else _fail "a text edit changes the hash"; fi
empty_h=$(body_baseline_hash "")
_eq "blank-only text hashes as empty" "$(body_baseline_hash $'\n \n\t\n')" "$empty_h"

# ── read / write ──────────────────────────────────────────────────────────
pdir="$TMP_ROOT/rw/planner"
mkdir -p "$pdir"
rc=0
body_baseline_read "$pdir" >/dev/null 2>&1 || rc=$?
_eq "read with no baseline file → 1" "$rc" "1"
body_baseline_write "$pdir" "$crlf"
_eq "write stores the normalised hash" "$(body_baseline_read "$pdir")" "$h"
_eq "baseline file name" "$(cat "$pdir/linear-baseline.sha")" "$h"
if ls "$pdir"/*.tmp.* >/dev/null 2>&1; then _fail "write leaves no tmp file"; else _pass "write leaves no tmp file"; fi
echo "not-a-hash" >"$pdir/linear-baseline.sha"
rc=0
body_baseline_read "$pdir" >/dev/null 2>&1 || rc=$?
_eq "read of a malformed baseline → 1" "$rc" "1"
rc=0
body_baseline_write "$TMP_ROOT/missing-dir" "x" 2>/dev/null || rc=$?
_eq "write into a missing directory → 1" "$rc" "1"

# ── classify: the D6 table ────────────────────────────────────────────────
# _case <name> <linear> <baseline-text|-none-> <body>
_case() {
  local d="$TMP_ROOT/case-$1/planner"
  mkdir -p "$d"
  printf '%s' "$4" >"$d/body.md"
  if [ "$3" != "-none-" ]; then body_baseline_write "$d" "$3"; fi
  body_baseline_classify "$d" "$2"
}
A=$'## Summary\nVersion A'
B=$'## Summary\nVersion B'
C=$'## Summary\nVersion C'

_eq "L==B, M==B → clean" "$(_case clean "$A" "$A" "$A")" "clean"
_eq "L!=B, M==B → adopt" "$(_case adopt "$B" "$A" "$A")" "adopt"
_eq "L!=B, M!=B, L==M → rebaseline" "$(_case rebase "$B" "$A" "$B")" "rebaseline"
_eq "L!=B, M!=B, L!=M → conflict" "$(_case conflict "$B" "$A" "$C")" "conflict"
_eq "L==B, M!=B → local-ahead" "$(_case local "$A" "$A" "$B")" "local-ahead"
_eq "no baseline, L==M → rebaseline" "$(_case nob-eq "$A" -none- "$A")" "rebaseline"
_eq "no baseline, L!=M → conflict" "$(_case nob-ne "$A" -none- "$B")" "conflict"
_eq "classify normalises both sides (CRLF Linear, trailing-space body)" \
  "$(_case norm $'## Summary\r\nVersion A\r\n' "$A" $'## Summary   \nVersion A\n\n')" "clean"
_eq "malformed baseline reads as no baseline" \
  "$(
    d="$TMP_ROOT/case-bad/planner"
    mkdir -p "$d"
    printf '%s' "$A" >"$d/body.md"
    echo junk >"$d/linear-baseline.sha"
    body_baseline_classify "$d" "$B"
  )" "conflict"

d="$TMP_ROOT/case-nobody/planner"
mkdir -p "$d"
out=""
rc=0
out=$(body_baseline_classify "$d" "$A") || rc=$?
_eq "no body.md → exit 2" "$rc" "2"
_eq "no body.md → prints nothing" "$out" ""

# classify never writes
d="$TMP_ROOT/case-adopt/planner"
_eq "classify does not touch the baseline" "$(body_baseline_read "$d")" "$(body_baseline_hash "$A")"
_eq "classify does not touch body.md" "$(cat "$d/body.md")" "$A"

# ── Works under the strictest caller settings ─────────────────────────────
strict=$(
  set -euo pipefail
  d="$TMP_ROOT/case-strict/planner"
  mkdir -p "$d"
  printf '%s' "$A" >"$d/body.md"
  body_baseline_classify "$d" "$B"
  echo "survived"
)
_eq "set -euo pipefail caller survives a missing baseline" "$strict" $'conflict\nsurvived'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
