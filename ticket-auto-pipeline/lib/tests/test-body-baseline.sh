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

# ── unlink: Linear autolinks undone (F61, F91) ────────────────────────────
_eq "unlink: F91 bare dotted token" \
  "$(body_baseline_unlink '| sign up | email is [Mixed.Case](<http://Mixed.Case>)@Conduit.test |')" \
  '| sign up | email is Mixed.Case@Conduit.test |'
_eq "unlink: F61 bare URL" \
  "$(body_baseline_unlink 'Open [http://localhost:5173](<http://localhost:5173>) first.')" 'Open http://localhost:5173 first.'
_eq "unlink: no angle brackets, https and mailto" \
  "$(body_baseline_unlink '[a.b](https://a.b) [x@y.z](mailto:x@y.z) [c](c)')" 'a.b x@y.z c'
_eq "unlink: a link whose target differs from its text is kept" \
  "$(body_baseline_unlink 'See [the docs](<https://example.test/docs>) and [a.b](http://c.d).')" \
  'See [the docs](<https://example.test/docs>) and [a.b](http://c.d).'
_eq "unlink: code spans are never touched" \
  "$(body_baseline_unlink 'run `[a](<http://a>)` then [a](<http://a>)')" 'run `[a](<http://a>)` then a'
_eq "unlink: fenced blocks are never touched" \
  "$(body_baseline_unlink $'```\n[a](<http://a>)\n```\n[a](<http://a>)')" $'```\n[a](<http://a>)\n```\na'
_eq "unlink: text with no link is unchanged" "$(body_baseline_unlink "$base")" "$base"
_eq "hash: an autolinked rendering hashes as the composed text" \
  "$(body_baseline_hash 'email is [Mixed.Case](<http://Mixed.Case>)@Conduit.test')" \
  "$(body_baseline_hash 'email is Mixed.Case@Conduit.test')"
if [ "$(body_baseline_hash 'see [a](<http://b>)')" != "$(body_baseline_hash 'see a')" ]; then
  _pass "hash: a real link target still counts"
else _fail "hash: a real link target still counts"; fi
# A baseline stored before unlink existed, over an autolinked Linear text
# that body.md also holds: both sides now normalise alike → rebaseline,
# which only rewrites the stored hash.
d="$TMP_ROOT/case-migrate/planner"
mkdir -p "$d"
linked='email is [Mixed.Case](<http://Mixed.Case>)@Conduit.test'
printf '%s' "$linked" >"$d/body.md"
printf '%s' "$linked" | awk '{print}' | sha256sum | awk '{print $1}' >"$d/linear-baseline.sha"
_eq "migration: an old autolinked baseline classifies rebaseline" "$(body_baseline_classify "$d" "$linked")" "rebaseline"

# ── literals: code spans and fenced lines, sorted ─────────────────────────
_eq "literals: spans and fence lines" \
  "$(body_baseline_literals $'b `two` a `one`\n```\nx = 1\n```')" $'F:x = 1\nS:one\nS:two'
_eq "literals: none" "$(body_baseline_literals 'plain [a](<http://a>)')" ""
if [ "$(body_baseline_literals 'run `auth_user`')" != "$(body_baseline_literals 'run `auth\_user`')" ]; then
  _pass "literals: an escaped character inside a span is a different literal"
else _fail "literals: an escaped character inside a span is a different literal"; fi

if command -v gawk >/dev/null 2>&1; then
  g=$(
    awk() { gawk "$@"; }
    body_baseline_unlink '| x | [Mixed.Case](<http://Mixed.Case>)@C.test `[a](<http://a>)` |'
  )
  _eq "unlink under gawk matches" "$g" '| x | Mixed.Case@C.test `[a](<http://a>)` |'
fi

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
