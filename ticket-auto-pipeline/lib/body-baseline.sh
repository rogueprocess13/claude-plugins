#!/usr/bin/env bash
# body-baseline.sh — the one normalised body hash and the Linear-vs-body.md
# drift classifier (planner-refinement-convergence design D6).
#
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling), does not change SCRIPT_DIR and sources nothing. ticket-planner
# resolves this file through its three-level resolver and ticket-auto sources
# it directly — there is no second copy of the hash anywhere. Performs no
# tracker I/O: the caller passes the Linear description it already fetched.
#
# Public API:
#   body_baseline_hash <text>
#     Prints the 64-hex sha256 of <text> after normalisation: CRLF → LF,
#     trailing whitespace stripped per line, trailing blank lines dropped.
#     Leading whitespace and interior blank lines are significant. Exit 1
#     when no sha256 tool exists.
#
#   body_baseline_read <pdir>
#     Prints the hash stored in <pdir>/linear-baseline.sha. Exit 1 when the
#     file is absent or does not hold a 64-hex hash.
#
#   body_baseline_write <pdir> <text>
#     Stores body_baseline_hash <text> in <pdir>/linear-baseline.sha (tmp +
#     mv). <text> is the Linear description the baseline describes. Exit 1 on
#     failure.
#
#   body_baseline_classify <pdir> <linear-desc>
#     Prints one of clean | adopt | rebaseline | conflict | local-ahead.
#     L = Linear hash, B = baseline, M = <pdir>/body.md hash:
#       L == B, M == B              clean
#       L != B, M == B              adopt       (Linear changed, body.md not)
#       L != B, M != B, L == M      rebaseline  (both made the same change)
#       L != B, M != B, L != M      conflict
#       L == B, M != B              local-ahead (body.md edited, Linear not)
#       no baseline, L == M         rebaseline
#       no baseline, L != M         conflict
#     Exit 2 (nothing printed) when <pdir>/body.md does not exist; exit 1
#     when no hash can be computed. Never writes anything.

BODY_BASELINE_FILE="linear-baseline.sha"

# _body_baseline_normalise — stdin → stdout, the D6 normalisation.
_body_baseline_normalise() {
  awk '
    { sub(/\r$/, ""); sub(/[ \t\r\f\v]+$/, ""); line[NR] = $0 }
    END {
      n = NR
      while (n > 0 && line[n] == "") n--
      for (i = 1; i <= n; i++) print line[i]
    }'
}

body_baseline_hash() {
  local text="${1-}" sum=""
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$text" | _body_baseline_normalise | sha256sum | awk '{print $1}') || sum=""
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s' "$text" | _body_baseline_normalise | shasum -a 256 | awk '{print $1}') || sum=""
  fi
  [ -n "$sum" ] || return 1
  printf '%s\n' "$sum"
}

body_baseline_read() {
  local pdir="${1-}" h=""
  [ -n "$pdir" ] && [ -f "$pdir/$BODY_BASELINE_FILE" ] || return 1
  h=$(head -1 "$pdir/$BODY_BASELINE_FILE" 2>/dev/null | tr -d '[:space:]') || h=""
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$h"
}

body_baseline_write() {
  local pdir="${1-}" text="${2-}" h=""
  [ -n "$pdir" ] && [ -d "$pdir" ] || {
    echo "body-baseline: no planner directory '${pdir}'" >&2
    return 1
  }
  h=$(body_baseline_hash "$text") || return 1
  local tmp="$pdir/$BODY_BASELINE_FILE.tmp.$$"
  printf '%s\n' "$h" >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv -f "$tmp" "$pdir/$BODY_BASELINE_FILE" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

body_baseline_classify() {
  local pdir="${1-}" desc="${2-}"
  [ -n "$pdir" ] && [ -f "$pdir/body.md" ] || return 2

  local l="" m="" b=""
  l=$(body_baseline_hash "$desc") || return 1
  m=$(body_baseline_hash "$(cat "$pdir/body.md" 2>/dev/null)") || return 1
  b=$(body_baseline_read "$pdir" 2>/dev/null) || b=""

  if [ -z "$b" ]; then
    if [ "$l" = "$m" ]; then echo "rebaseline"; else echo "conflict"; fi
    return 0
  fi

  if [ "$l" = "$b" ]; then
    if [ "$m" = "$b" ]; then echo "clean"; else echo "local-ahead"; fi
  elif [ "$m" = "$b" ]; then
    echo "adopt"
  elif [ "$l" = "$m" ]; then
    echo "rebaseline"
  else
    echo "conflict"
  fi
  return 0
}
