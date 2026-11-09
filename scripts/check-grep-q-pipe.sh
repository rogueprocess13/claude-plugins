#!/usr/bin/env bash
# check-grep-q-pipe.sh — lint gate: no `echo … | grep -q` in non-test shell.
#
# `echo "$x" | grep -q PATTERN` is a two-process pipeline. grep -q exits on
# its first match; if echo/printf is still writing, it gets SIGPIPE, and under
# `set -o pipefail` the pipeline returns 141 — a real match reads as a miss.
# Deterministic for a large input, a timing race for a small one (GitHub #640).
# Write `grep -q PATTERN <<<"$x"` (or a `[[ … ]]` match) instead.
#
# Flags an echo/printf line piped into a quiet grep (`-q`, combined short
# flags such as `-qiE`, `--quiet`, `--silent`), on one line or with the pipe
# ending a line and the grep on the next. Comment lines are skipped. Test
# files are scanned too: under parallel `make test` the same race fails them.
# The one file skipped is this gate's own self-test
# (scripts/tests/test-check-grep-q-pipe.sh), whose fixtures are the pattern.
#
# Usage:
#   check-grep-q-pipe.sh [--root DIR]
#
# Files: `git ls-files '*.sh'` under DIR when it is a git checkout, else every
# *.sh found under DIR (skipping .git, .claude and node_modules).
#
# Exit codes:
#   0  clean
#   1  one or more offending lines (printed as path:line: text)
#   2  usage error
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
  --root)
    [ $# -ge 2 ] || {
      echo "check-grep-q-pipe: --root needs a value" >&2
      exit 2
    }
    ROOT="$2"
    shift 2
    ;;
  *)
    echo "check-grep-q-pipe: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

[ -d "$ROOT" ] || {
  echo "check-grep-q-pipe: root not found: $ROOT" >&2
  exit 2
}

files=()
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r f; do
    files+=("$f")
  done < <(git -C "$ROOT" ls-files '*.sh')
else
  while IFS= read -r f; do
    files+=("${f#./}")
  done < <(cd "$ROOT" && find . \( -name .git -o -name .claude -o -name node_modules \) -prune -o -name '*.sh' -type f -print | sort)
fi

scan=()
for f in "${files[@]}"; do
  [ "$f" = "scripts/tests/test-check-grep-q-pipe.sh" ] && continue
  [ -f "$ROOT/$f" ] && scan+=("$f")
done
[ "${#scan[@]}" -gt 0 ] || {
  echo "check-grep-q-pipe: OK (no shell files)"
  exit 0
}

# The regexes are assembled from pieces so this file's own text never matches
# them.
w='(ec''ho|pri''ntf)'
quiet='grep([[:space:]]+-[[:alnum:]]+)*[[:space:]]+(-[[:alnum:]]*q[[:alnum:]]*|--quiet|--silent)([[:space:]]|$)'

found=$(cd "$ROOT" && awk -v w="$w" -v q="$quiet" '
  FNR == 1 { prev = "" }
  {
    line = $0
    if (line ~ /^[[:space:]]*#/) { prev = ""; next }
    one = "(^|[^[:alnum:]_])" w "([[:space:]][^|]*)?[|][[:space:]]*" q
    tail = "(^|[^[:alnum:]_])" w "([[:space:]][^|]*)?[|][[:space:]]*\\\\?[[:space:]]*$"
    if (line ~ one) {
      print FILENAME ":" FNR ": " line
    } else if (prev != "" && line ~ ("^[[:space:]]*" q)) {
      print FILENAME ":" FNR ": " line
    }
    prev = (line ~ tail) ? line : ""
  }
' "${scan[@]}")

if [ -n "$found" ]; then
  printf '%s\n' "$found"
  n=$(printf '%s\n' "$found" | wc -l)
  echo "check-grep-q-pipe: FAIL — $n line(s) pipe echo/printf into a quiet grep." >&2
  echo "  Under pipefail the writer's SIGPIPE (141) turns a match into a miss (GitHub #640)." >&2
  echo "  Use: grep -q PATTERN <<<\"\$x\"" >&2
  exit 1
fi
echo "check-grep-q-pipe: OK (${#scan[@]} files)"
