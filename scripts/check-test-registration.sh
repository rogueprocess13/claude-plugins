#!/usr/bin/env bash
# check-test-registration.sh — CI drift gate: every test file on disk must be
# run by the Makefile, and every test file the Makefile runs must exist.
#
# Test files are not auto-discovered: each one needs a line in a make target
# by hand. A file that is never registered passes review, never runs in CI,
# and gives false confidence. This gate turns that silent gap into a red build.
#
# What counts as a test file (relative to the repo root):
#   - any  test-*.sh            (bash test suites — lib/tests, plugin test dirs)
#   - any  test_*.py            (pytest modules — fleetd, ticket-auto)
#   - any  */tests/phase*.sh    (ticket-flow phase runners)
# Skipped: anything under a fixtures/ directory, .git, .claude, node_modules.
#
# What counts as "registered": the file's repo-relative path appears as a
# whitespace-separated word on a non-comment Makefile line (a leading "./" or
# "$(CURDIR)/" is ignored). A path that appears only in a "# ..." comment does
# not count.
#
# Usage:
#   check-test-registration.sh [--root DIR] [--makefile FILE]
#
# Exit codes:
#   0  every test file is registered and every registered test file exists
#   1  drift: unregistered test file(s) and/or registered file(s) missing
#   2  usage error (bad flag, missing root or Makefile)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
  --root)
    [ $# -ge 2 ] || {
      echo "check-test-registration: --root needs a value" >&2
      exit 2
    }
    ROOT="$2"
    shift 2
    ;;
  --makefile)
    [ $# -ge 2 ] || {
      echo "check-test-registration: --makefile needs a value" >&2
      exit 2
    }
    MAKEFILE="$2"
    shift 2
    ;;
  *)
    echo "check-test-registration: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

[ -d "$ROOT" ] || {
  echo "check-test-registration: root not found: $ROOT" >&2
  exit 2
}
[ -n "$MAKEFILE" ] || MAKEFILE="$ROOT/Makefile"
[ -f "$MAKEFILE" ] || {
  echo "check-test-registration: Makefile not found: $MAKEFILE" >&2
  exit 2
}

# Test-file shape, shared by the disk scan and the stale-registration check.
_is_test_path() {
  case "$1" in
  */fixtures/*) return 1 ;;
  test-*.sh | */test-*.sh | test_*.py | */test_*.py | */tests/phase*.sh) return 0 ;;
  *) return 1 ;;
  esac
}

# Disk side: every test file under ROOT, as a sorted repo-relative path list.
on_disk="$(
  cd "$ROOT" &&
    find . \( -name .git -o -name .claude -o -name node_modules -o -name fixtures \) -prune -o \
      -type f \( -name 'test-*.sh' -o -name 'test_*.py' -o -path '*/tests/phase*.sh' \) -print |
    sed 's|^\./||' | LC_ALL=C sort -u
)"

# Makefile side: every word on a non-comment line, normalised.
registered="$(
  awk '!/^[[:space:]]*#/ { for (i = 1; i <= NF; i++) print $i }' "$MAKEFILE" |
    sed -e 's|^\$(CURDIR)/||' -e 's|^\./||' | LC_ALL=C sort -u
)"

drift=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! grep -qxF -- "$f" <<<"$registered"; then
    echo "UNREGISTERED: $f — add it to a test target in $(basename "$MAKEFILE")" >&2
    drift=1
  fi
done <<<"$on_disk"

while IFS= read -r w; do
  [ -n "$w" ] || continue
  _is_test_path "$w" || continue
  if [ ! -f "$ROOT/$w" ]; then
    echo "MISSING: $w is registered in $(basename "$MAKEFILE") but does not exist" >&2
    drift=1
  fi
done <<<"$registered"

if [ "$drift" -ne 0 ]; then
  echo "check-test-registration: FAIL — Makefile and on-disk test files disagree" >&2
  exit 1
fi

count="$(grep -c . <<<"$on_disk" || true)"
echo "check-test-registration: OK — $count test files, all registered"
