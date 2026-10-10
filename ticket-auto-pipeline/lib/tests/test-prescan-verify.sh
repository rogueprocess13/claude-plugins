#!/usr/bin/env bash
# test-prescan-verify.sh — regression tests for lib/prescan-verify.sh.
#
# GitHub #420 sweep: _check_services_dir counted services/*.md with
# `ls ... | wc -l || echo "0"`. With no matches ls fails, pipefail fails the
# pipeline after wc already printed "0", and the echo fallback appended a
# second "0" — "0\n0" never equals "0", so an empty services/ dir passed.
#
# Usage: bash test-prescan-verify.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../prescan-verify.sh
source "$LIB_DIR/prescan-verify.sh"

PASS=0
FAIL=0
_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_TEST_TMPDIRS=()
_mktemp_test_dir() {
  local d
  d=$(mktemp -d)
  _TEST_TMPDIRS+=("$d")
  echo "$d"
}
_cleanup_test_tmpdirs() {
  local d
  for d in "${_TEST_TMPDIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
}
trap _cleanup_test_tmpdirs EXIT

test_empty_services_dir_is_a_violation() {
  local tmpdir out rc=0
  tmpdir=$(_mktemp_test_dir)
  mkdir -p "$tmpdir/services"
  out=$(_check_services_dir "$tmpdir") || rc=$?
  [ "$rc" -eq 1 ] && [[ "$out" == *"no .md files found"* ]]
}

test_services_dir_with_md_passes() {
  local tmpdir rc=0
  tmpdir=$(_mktemp_test_dir)
  mkdir -p "$tmpdir/services"
  echo "# svc" >"$tmpdir/services/svc.md"
  _check_services_dir "$tmpdir" >/dev/null || rc=$?
  [ "$rc" -eq 0 ]
}

test_missing_services_dir_is_a_violation() {
  local tmpdir out rc=0
  tmpdir=$(_mktemp_test_dir)
  out=$(_check_services_dir "$tmpdir") || rc=$?
  [ "$rc" -eq 1 ] && [[ "$out" == *"directory missing"* ]]
}

FILTER="${1:-}"
for fn in \
  test_empty_services_dir_is_a_violation \
  test_services_dir_with_md_passes \
  test_missing_services_dir_is_a_violation; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
