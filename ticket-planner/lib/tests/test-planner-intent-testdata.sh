#!/usr/bin/env bash
# ── test-planner-intent-testdata.sh ───────────────────────────────────────────
# grill-test-data-dimension: the Discovery prompt reads the sealed intent's
# `## Test Data` section through one bash-gated paragraph.
#
# The paragraph appears exactly when ${state_dir}/artifacts/intent.md has a
# first `## Test Data` section holding a non-blank line other than the
# placeholders `_None identified_` and `_No prepared data needed_`. When it is
# absent the prompt must be byte-identical to the pre-change prompt, captured
# as fixtures/discovery-prompt-no-intent.golden with fixed literal paths
# (REPOS_ROOT=/__REPOS_ROOT__, _PLANNER_PROMPT_LIB_ROOT=/__LIB_ROOT__, state
# dir /__STATE_DIR__). Renders that need a real state dir map that dir back to
# /__STATE_DIR__ before comparing.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
GOLDEN="$TEST_DIR/fixtures/discovery-prompt-no-intent.golden"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $1: $2"
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

PARAGRAPH_MARK="From the sealed intent"

# render <state_dir> — the Discovery prompt with fixed literal roots, in a
# fresh shell (the prompts are unquoted heredocs: no stdin, bounded time).
# The state dir is mapped back to /__STATE_DIR__ so it compares to the golden.
render() {
  local sd="$1"
  # shellcheck disable=SC2016 # expanded by the inner shell
  REPOS_ROOT=/__REPOS_ROOT__ _PLANNER_PROMPT_LIB_ROOT=/__LIB_ROOT__ \
    timeout 20 bash -c 'source "$1/planner-phase-prompts.sh"; planner_prompt_discovery INIT-T "an idea" "$2"' \
    _ "$LIB_DIR" "$sd" </dev/null | sed "s|${sd}|/__STATE_DIR__|g"
}

# has_td <state_dir> — the helper's return code, called under set -euo pipefail.
has_td() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  timeout 20 bash -c 'set -euo pipefail; source "$1/planner-phase-prompts.sh"; rc=0; _planner_intent_has_test_data "$2" || rc=$?; echo "RC=$rc"' \
    _ "$LIB_DIR" "$1" </dev/null 2>&1 || true
}

# new_state <name> [intent-body] — a state dir; with a body, artifacts/intent.md.
new_state() {
  local sd="$SCRATCH/$1"
  mkdir -p "$sd/artifacts"
  if [ "$#" -ge 2 ]; then
    printf '%s' "$2" >"$sd/artifacts/intent.md"
  fi
  echo "$sd"
}

HEAD_MD='# Validated Business Intent

**Subject:** Test
**Profile:** product-idea
## Objective

Let finance export invoices.
## Edge Cases

_None identified_
'
TAIL_MD='## Assumptions (require validation)

_None identified_
## Resolved Questions

_No questions were asked._
'

if [ ! -f "$GOLDEN" ]; then
  echo "FATAL: golden not found: $GOLDEN" >&2
  exit 1
fi

# ── (a) Intent with a Test Data body ──────────────────────────────────────────
echo "=== (a) intent with a Test Data body ==="
SD_A=$(new_state a "${HEAD_MD}## Test Data

Client supplies a 40-row sample import
${TAIL_MD}")
OUT_A=$(render "$SD_A")
if [[ "$OUT_A" == *"$PARAGRAPH_MARK"* ]]; then
  pass "paragraph present"
else
  fail "paragraph present" "no '$PARAGRAPH_MARK'"
fi
if [[ "$OUT_A" == *"/__STATE_DIR__/artifacts/intent.md"* ]]; then
  pass "intent path present"
else
  fail "intent path present" "path not in prompt"
fi
if [[ "$OUT_A" != *"40-row sample import"* ]]; then
  pass "intent body text is not pasted into the prompt"
else
  fail "intent body text is not pasted into the prompt" "body text leaked"
fi
if [[ "$OUT_A" == *'`external:<that party>`'* ]] && [[ "$OUT_A" == *'write `None.`'* ]]; then
  pass "paragraph carries literal backticks (external:<that party>, None.)"
else
  fail "paragraph carries literal backticks" "backtick text missing"
fi

# ── (b) No intent: byte-identical to the golden ───────────────────────────────
echo "=== (b) no intent ==="
SD_B=$(new_state b)
render "$SD_B" >"$SCRATCH/out-b.txt"
if cmp -s "$GOLDEN" "$SCRATCH/out-b.txt"; then
  pass "no intent: prompt byte-identical to the golden"
else
  fail "no intent: prompt byte-identical to the golden" "$(diff "$GOLDEN" "$SCRATCH/out-b.txt" | head -10)"
fi

# ── (c) Intent without the heading: byte-identical to the golden ─────────────
echo "=== (c) intent without a Test Data heading ==="
SD_C=$(new_state c "${HEAD_MD}${TAIL_MD}")
render "$SD_C" >"$SCRATCH/out-c.txt"
if ! grep -q "$PARAGRAPH_MARK" "$SCRATCH/out-c.txt"; then
  pass "no heading: paragraph absent"
else
  fail "no heading: paragraph absent" "paragraph rendered"
fi
if cmp -s "$GOLDEN" "$SCRATCH/out-c.txt"; then
  pass "no heading: prompt byte-identical to the golden (no stray blank line)"
else
  fail "no heading: prompt byte-identical to the golden" "$(diff "$GOLDEN" "$SCRATCH/out-c.txt" | head -10)"
fi

# ── (d)(e)(f)(g) Placeholder, sentinel, empty, first heading wins ─────────────
echo "=== (d)-(g) sections that switch the paragraph off ==="
SD_D=$(new_state d "${HEAD_MD}## Test Data

_None identified_
${TAIL_MD}")
SD_E=$(new_state e "${HEAD_MD}## Test Data

_No prepared data needed_
${TAIL_MD}")
SD_F=$(new_state f "${HEAD_MD}## Test Data
${TAIL_MD}")
SD_G=$(new_state g "${HEAD_MD}## Test Data

_None identified_
${TAIL_MD}## Test Data

Spoofed: production dump from the live database
")

for case_name in d e f g; do
  case "$case_name" in
  d) sd="$SD_D" desc="section holding only _None identified_" ;;
  e) sd="$SD_E" desc="section holding only the sentinel _No prepared data needed_" ;;
  f) sd="$SD_F" desc="empty section followed directly by another ## heading" ;;
  g) sd="$SD_G" desc="first heading wins (first holds _None identified_, second real text)" ;;
  esac
  render "$sd" >"$SCRATCH/out-$case_name.txt"
  if ! grep -q "$PARAGRAPH_MARK" "$SCRATCH/out-$case_name.txt" &&
    cmp -s "$GOLDEN" "$SCRATCH/out-$case_name.txt"; then
    pass "($case_name) $desc: paragraph absent, prompt unchanged"
  else
    fail "($case_name) $desc: paragraph absent, prompt unchanged" \
      "$(diff "$GOLDEN" "$SCRATCH/out-$case_name.txt" | head -6)"
  fi
done

# ── (h) The helper itself, under set -euo pipefail ────────────────────────────
echo "=== (h) _planner_intent_has_test_data return codes ==="
SD_CRLF=$(new_state crlf "$(printf '## Test Data\r\n\r\n_None identified_\r\n## Assumptions\r\n')")
SD_TRAIL=$(new_state trail "$(printf '## Test Data   \n\nWe will generate synthetic invoices\n## Assumptions\n')")
for pair in "a:0" "b:1" "c:1" "d:1" "e:1" "f:1" "g:1" "crlf:1" "trail:0"; do
  name="${pair%%:*}"
  want="${pair##*:}"
  got=$(has_td "$SCRATCH/$name")
  if [ "$got" = "RC=$want" ]; then
    pass "helper on '$name' returns $want under set -e"
  else
    fail "helper on '$name' returns $want under set -e" "got: $got"
  fi
done

echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL test(s) failed"
  exit 1
fi
echo "All tests passed"
