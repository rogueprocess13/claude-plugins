#!/usr/bin/env bash
# conflict-marker-scan.sh — find real merge-conflict markers added by a diff
# (review finding DET-IP-5).
#
# Usage: conflict-marker-scan.sh [<DIFF-FILE>]      (reads stdin without one)
#   e.g. git -C "$WT" diff origin/<base>...origin/<head> | conflict-marker-scan.sh
#
# ticket-pr-review's merge gate used
#   grep -n "^[+].*\(<<<<<<<\|=======\|>>>>>>>\)"
# which blocks the merge on ANY added line merely containing `=======` — a
# markdown setext heading underline, an ASCII rule, a `==========` banner.
#
# A conflict is reported only for the full combination git writes, as ADDED
# lines (`+` prefix, diff headers excluded), in order, within one file:
#   ^<<<<<<<( .*)?$   then   ^=======$   then   ^>>>>>>>( .*)?$
# Other lines (added, context, or a diff3 `|||||||` base section) may sit
# between them. A lone `=======` line, a `foo ======= bar` line, or an
# unmatched start/end marker never blocks on its own. CR line endings are
# tolerated.
#
# Output: one line per conflict block, `<path>:<start-line-text>` (the
# new-file path, then the opening marker line as added).
# Exit codes: 0 no conflict blocks; 1 at least one found; 2 unreadable input.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

conflict_marker_scan() {
  local src="${1:--}"
  if [ "$src" != "-" ] && [ ! -r "$src" ]; then
    echo "conflict-marker-scan: cannot read $src" >&2
    return 2
  fi
  awk '
    function reset() { state = 0; start = "" }
    BEGIN { file = ""; header = 0; found = 0; reset() }
    { sub(/\r$/, "") }
    /^diff --git / { header = 1; file = ""; reset(); next }
    header && /^\+\+\+ / {
      file = substr($0, 5); sub(/^b\//, "", file); next
    }
    header && /^@@/ { header = 0 }
    header { next }
    /^@@/ { next }
    /^\+/ {
      line = substr($0, 2)
      if (line ~ /^<<<<<<<( .*)?$/) { state = 1; start = line; next }
      if (state == 1 && line ~ /^=======$/) { state = 2; next }
      if (state == 2 && line ~ /^>>>>>>>( .*)?$/) {
        print file ":" start; found = 1; reset(); next
      }
    }
    END { exit found ? 1 : 0 }
  ' "$src"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rc=0
  conflict_marker_scan "$@" || rc=$?
  exit "$rc"
fi
