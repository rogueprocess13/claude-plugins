#!/usr/bin/env bash
# test-record-assets.sh — lib/record-assets/: the committed coder sprite PNGs
# must be exactly what gen-coder-sprite.py makes from coder.grid (openspec
# change record-stitch-overlay, D8), and malformed grids must be refused.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$(cd "$SCRIPT_DIR/../record-assets" && pwd)"
GEN="$ASSETS/gen-coder-sprite.py"
GRID="$ASSETS/coder.grid"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: test-record-assets.sh needs python3"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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

test_generator_reproduces_committed_pngs() {
  local out="$WORK/gen" f n
  python3 "$GEN" --grid "$GRID" --out "$out" || return 1
  n=$(find "$out" -maxdepth 1 -name '*.png' | wc -l)
  [ "$n" -eq 12 ] || {
    echo "  want 12 PNGs, got $n"
    return 1
  }
  n=$(find "$ASSETS" -maxdepth 1 -name 'coder-*.png' | wc -l)
  [ "$n" -eq 12 ] || {
    echo "  want 12 committed PNGs, got $n"
    return 1
  }
  for f in coder-work-0{1..8}.png coder-idle-0{1..4}.png; do
    cmp -s "$out/$f" "$ASSETS/$f" || {
      echo "  $f differs from the committed copy (regenerate with gen-coder-sprite.py)"
      return 1
    }
  done
}

test_png_header_is_192_rgba() {
  # IHDR: width/height 192 (0x000000c0), bit depth 8, colour type 6 (RGBA).
  local hdr
  hdr=$(od -An -tx1 -j16 -N10 "$ASSETS/coder-work-01.png" | tr -d ' \n')
  [ "$hdr" = "000000c0000000c00806" ]
}

# Run the generator on a corrupted copy of the grid; it must exit non-zero,
# say why on stderr, and write no PNG.
_refuses() {
  local sedexpr="$1" bad="$WORK/bad-$RANDOM.grid" out="$WORK/bad-out-$RANDOM" err
  sed "$sedexpr" "$GRID" >"$bad"
  if err=$(python3 "$GEN" --grid "$bad" --out "$out" 2>&1); then
    echo "  generator accepted a malformed grid"
    return 1
  fi
  [ -n "$err" ] || return 1
  [ -z "$(find "$out" -name '*.png' 2>/dev/null)" ]
}

test_short_row_refused() {
  # First row of work-01 loses a character (31 chars).
  _refuses '/^frame work-01$/{n;s/^.//;}'
}

test_unknown_char_refused() {
  _refuses '/^frame work-01$/{n;s/^./Z/;}'
}

test_missing_frame_refused() {
  # shellcheck disable=SC2016 # a sed address, not a shell expansion
  _refuses '/^frame idle-04$/,$d'
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  _run "$t" "$t"
done

echo ""
echo "test-record-assets.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
