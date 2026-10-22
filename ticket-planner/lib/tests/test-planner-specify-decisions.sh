#!/usr/bin/env bash
# test-planner-specify-decisions.sh — Tests for planner-specify-decisions.sh
# (planner-specify-waiting-on-human).
#
# Pinned here:
#   1. The decision scan: line-anchored, fence-aware, `## Business Outcomes`
#      only, `### O<n>` ids matching the `specify-answer:O<n>` binding, one
#      decision per subsection, a stable hash8 keyed on the outcome id.
#   2. The tripwire: every non-fenced NEEDS_HUMAN_DECISION line the scan did
#      not take is listed with a reason, and warned about once per proposal.
#   3. The gate's return codes (0 clear, 3 open, 1 cannot scan), that it
#      writes no phase line, and that a `set -euo pipefail` caller survives rc 3.
#   4. Rendering and substitution: answer/defer lines never match the scan,
#      injection text stays literal, and only the target line changes.
#
# Every case is guarded on the function it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary, never an
# unbound-function abort.
#
# Run: bash ticket-planner/lib/tests/test-planner-specify-decisions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SD_LIB="${LIB_DIR}/planner-specify-decisions.sh"

WORK=$(mktemp -d)
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"

source "${LIB_DIR}/planner-state.sh"
if [ -f "$SD_LIB" ]; then
  source "$SD_LIB"
fi

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

# need <case> <fn>... — fail the case (not the file) when a function is missing.
need() {
  local name="$1" fn
  shift
  for fn in "$@"; do
    if ! declare -f "$fn" >/dev/null; then
      fail "$name" "$fn missing"
      return 1
    fi
  done
  return 0
}

INIT="INIT-1700000000-4242"
N=0

# fresh — a new initiative with an empty state log; sets IDIR and PROP.
fresh() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((4000 + N))"
  planner_state_init "$INIT" "classify client documents" >/dev/null
  IDIR=$(planner_initiative_dir "$INIT")
  PROP="${IDIR}/artifacts/proposal.md"
  LOG="${IDIR}/state.log"
}

# prop — write stdin as the proposal.
prop() { cat >"$PROP"; }

sha8_of() {
  printf '%s' "$1" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } |
    cut -c1-8
}

scan() { planner_specify_decisions_scan "$INIT"; }
stray() { planner_specify_decisions_stray "$INIT"; }

# ── 2.2 Scan: positive ─────────────────────────────────────────────────────────

echo "=== scan: positive ==="

for sep in "—" "–" "--" "-" ":"; do
  name="scan accepts separator '${sep}'"
  need "$name" planner_specify_decisions_scan || continue
  fresh
  prop <<EOF
# Doc classification

## Business Outcomes

### O1
**Who:** Not specified.
**Outcome:** NEEDS_HUMAN_DECISION ${sep} which role consumes the classified documents?
EOF
  out=$(scan)
  want=$(printf 'O1\t%s\t7\twhich role consumes the classified documents?' \
    "$(sha8_of "$(printf 'O1\nwhich role consumes the classified documents?')")")
  if [ "$out" = "$want" ]; then pass "$name"; else fail "$name" "got [$out] want [$want]"; fi
done

name="scan accepts '### O1 — title' heading"
if need "$name" planner_specify_decisions_scan; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O1 — Accountants
**Outcome:** NEEDS_HUMAN_DECISION — which role?
EOF
  out=$(scan)
  if [ "$(printf '%s' "$out" | cut -f1,3,4)" = "$(printf 'O1\t3\twhich role?')" ]; then pass "$name"; else fail "$name" "got [$out]"; fi
fi

name="scan reports two decisions in file order"
if need "$name" planner_specify_decisions_scan; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O3
**Outcome:** NEEDS_HUMAN_DECISION — third?
### O2
**Outcome:** Accountants see ready documents.
### O1
**Outcome:** NEEDS_HUMAN_DECISION — first?
EOF
  ids=$(scan | cut -f1 | tr '\n' ' ')
  if [ "$ids" = "O3 O1 " ]; then pass "$name"; else fail "$name" "got [$ids]"; fi
fi

name="scan hash is stable across runs"
if need "$name" planner_specify_decisions_scan; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O1
**Outcome:** NEEDS_HUMAN_DECISION —   which   role?
EOF
  a=$(scan)
  b=$(scan)
  want=$(sha8_of "$(printf 'O1\nwhich role?')")
  if [ "$a" = "$b" ] && [ "$(printf '%s' "$a" | cut -f2)" = "$want" ] &&
    [ "$(printf '%s' "$a" | cut -f4)" = "which role?" ]; then
    pass "$name"
  else fail "$name" "a=[$a] b=[$b] want hash $want"; fi
fi

name="scan gives the same question at O1 and O2 different hashes"
if need "$name" planner_specify_decisions_scan; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O1
**Outcome:** NEEDS_HUMAN_DECISION — which role?
### O2
**Outcome:** NEEDS_HUMAN_DECISION — which role?
EOF
  h1=$(scan | sed -n 1p | cut -f2)
  h2=$(scan | sed -n 2p | cut -f2)
  if [ -n "$h1" ] && [ -n "$h2" ] && [ "$h1" != "$h2" ]; then pass "$name"; else fail "$name" "h1=$h1 h2=$h2"; fi
fi

name="scan strips | and backticks from the question"
if need "$name" planner_specify_decisions_scan; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O1
**Outcome:** NEEDS_HUMAN_DECISION — which `role` | team?
EOF
  q=$(scan | cut -f4)
  if [ "$q" = "which role team?" ]; then pass "$name"; else fail "$name" "got [$q]"; fi
fi

# ── 2.2 Scan: negative (+ tripwire reason) ─────────────────────────────────────

echo "=== scan: negative and tripwire ==="

# neg <name> <expected stray "line<TAB>reason" lines, or ""> — proposal on stdin.
neg() {
  local name="$1" want_stray="$2" out st
  need "$name" planner_specify_decisions_scan planner_specify_decisions_stray || return 0
  fresh
  prop
  out=$(scan)
  st=$(stray)
  if [ -n "$out" ]; then
    fail "$name" "scan reported [$out]"
  elif [ "$st" != "$want_stray" ]; then
    fail "$name" "stray [$st] want [$want_stray]"
  else
    pass "$name"
  fi
}

neg "backtick fence is not a marker" "" <<'EOF'
## Business Outcomes
### O1
```
**Outcome:** NEEDS_HUMAN_DECISION — fenced?
```
EOF

neg "tilde fence is not a marker" "" <<'EOF'
## Business Outcomes
### O1
~~~markdown
**Outcome:** NEEDS_HUMAN_DECISION — fenced?
~~~
EOF

neg "blockquote is not a marker" "$(printf '3\tvariant')" <<'EOF'
## Business Outcomes
### O1
> **Outcome:** NEEDS_HUMAN_DECISION — quoted?
EOF

neg "list item is not a marker" "$(printf '3\tvariant')" <<'EOF'
## Business Outcomes
### O1
- **Outcome:** NEEDS_HUMAN_DECISION — listed?
EOF

neg "inline code span is not a marker" "$(printf '3\tvariant')" <<'EOF'
## Business Outcomes
### O1
`**Outcome:** NEEDS_HUMAN_DECISION — inline?`
EOF

neg "prose mention is not a marker" "$(printf '3\tprose')" <<'EOF'
## Business Outcomes
### O1
**Outcome:** resolve NEEDS_HUMAN_DECISION markers
EOF

neg "**Outcome**: variant is not a marker" "$(printf '3\tvariant')" <<'EOF'
## Business Outcomes
### O1
**Outcome**: NEEDS_HUMAN_DECISION — variant?
EOF

neg "marker without separator is not a marker" "$(printf '3\tvariant')" <<'EOF'
## Business Outcomes
### O1
**Outcome:** NEEDS_HUMAN_DECISION which role?
EOF

neg "marker under ## Risk Register is outside" "$(printf '5\toutside')" <<'EOF'
## Business Outcomes
### O1
**Outcome:** Accountants see ready documents.
## Risk Register
**Outcome:** NEEDS_HUMAN_DECISION — misplaced?
EOF

neg "marker under another ## section is outside" "$(printf '3\toutside')" <<'EOF'
## Overview
### O1
**Outcome:** NEEDS_HUMAN_DECISION — misplaced?
## Business Outcomes
EOF

neg "marker before any ### O<n> is a heading problem" "$(printf '2\theading')" <<'EOF'
## Business Outcomes
**Outcome:** NEEDS_HUMAN_DECISION — no subsection?
EOF

for bad in "O0" "O01" "O1000" "Outcome 1" "O1:"; do
  neg "marker under '### ${bad}' is not asked" "$(printf '3\theading')" <<EOF
## Business Outcomes
### ${bad}
**Outcome:** NEEDS_HUMAN_DECISION — bad id?
EOF
done

name="second marker in one subsection is a duplicate"
if need "$name" planner_specify_decisions_scan planner_specify_decisions_stray; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O1
**Outcome:** NEEDS_HUMAN_DECISION — first?
**Outcome:** NEEDS_HUMAN_DECISION — second?
EOF
  out=$(scan | cut -f1,3,4)
  st=$(stray)
  if [ "$out" = "$(printf 'O1\t3\tfirst?')" ] && [ "$st" = "$(printf '4\tduplicate')" ]; then
    pass "$name"
  else fail "$name" "scan [$out] stray [$st]"; fi
fi

name="duplicate ### O1 heading is a duplicate"
if need "$name" planner_specify_decisions_scan planner_specify_decisions_stray; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O1
**Outcome:** NEEDS_HUMAN_DECISION — first?
### O1
**Outcome:** NEEDS_HUMAN_DECISION — again?
EOF
  out=$(scan | cut -f1,3)
  st=$(stray)
  if [ "$out" = "$(printf 'O1\t3')" ] && [ "$st" = "$(printf '5\tduplicate')" ]; then
    pass "$name"
  else fail "$name" "scan [$out] stray [$st]"; fi
fi

name="section ends at a level-1 heading"
if need "$name" planner_specify_decisions_scan planner_specify_decisions_stray; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O1
**Outcome:** Fine.
# Appendix
### O2
**Outcome:** NEEDS_HUMAN_DECISION — appendix?
EOF
  out=$(scan)
  st=$(stray)
  if [ -z "$out" ] && [ "$st" = "$(printf '6\toutside')" ]; then pass "$name"; else fail "$name" "scan [$out] stray [$st]"; fi
fi

name="CRLF proposal still scans"
if need "$name" planner_specify_decisions_scan; then
  fresh
  printf '## Business Outcomes\r\n### O1\r\n**Outcome:** NEEDS_HUMAN_DECISION — crlf?\r\n' >"$PROP"
  out=$(scan | cut -f1,4)
  if [ "$out" = "$(printf 'O1\tcrlf?')" ]; then pass "$name"; else fail "$name" "got [$out]"; fi
fi

# ── 2.2 Placeholder ────────────────────────────────────────────────────────────

echo "=== placeholder ==="

for tail in "" " —" " :  "; do
  name="bare marker '${tail}' gets the placeholder question"
  need "$name" planner_specify_decisions_scan planner_specify_gate || continue
  fresh
  printf '## Business Outcomes\n### O2\n**Outcome:** NEEDS_HUMAN_DECISION%s\n' "$tail" >"$PROP"
  before=$(wc -l <"$LOG")
  q=$(scan | cut -f4)
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  after=$(wc -l <"$LOG")
  if [ "$q" = "(no question was written — state the business outcome for O2)" ] &&
    [ "$rc" -eq 3 ] && [ "$before" = "$after" ] && ! grep -q '|fail|' "$LOG"; then
    pass "$name"
  else fail "$name" "q=[$q] rc=$rc lines $before->$after"; fi
done

# ── 2.2 Tripwire: the gate warns once per proposal ─────────────────────────────

echo "=== tripwire ==="

name="gate warns once about a marker outside the section"
if need "$name" planner_specify_gate; then
  fresh
  prop <<'EOF'
## Business Outcomes
### O1
**Outcome:** Fine.
## Risk Register
**Outcome:** NEEDS_HUMAN_DECISION — misplaced?
EOF
  rc1=0
  planner_specify_gate "$INIT" || rc1=$?
  rc2=0
  planner_specify_gate "$INIT" || rc2=$?
  n=$(grep -c '|META|specify-gate|warn|' "$LOG" || true)
  line=$(grep '|META|specify-gate|warn|' "$LOG" | head -1 | cut -d'|' -f5)
  sha=$(sha256sum "$PROP" 2>/dev/null | cut -c1-8 || shasum -a 256 "$PROP" | cut -c1-8)
  if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$n" -eq 1 ] &&
    [ "$line" = "1 NEEDS_HUMAN_DECISION line(s) not asked: L5 outside [proposal ${sha}]" ]; then
    pass "$name"
  else fail "$name" "rc=$rc1/$rc2 warn lines=$n line=[$line]"; fi
fi

name="gate warns again after the proposal changes"
if need "$name" planner_specify_gate; then
  printf '%s\n' "**Outcome:** NEEDS_HUMAN_DECISION — also misplaced?" >>"$PROP"
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  n=$(grep -c '|META|specify-gate|warn|' "$LOG" || true)
  if [ "$rc" -eq 0 ] && [ "$n" -eq 2 ] && grep -q 'L5 outside, L6 outside' "$LOG"; then pass "$name"; else fail "$name" "rc=$rc warn lines=$n"; fi
fi

name="fenced token never trips the tripwire"
if need "$name" planner_specify_gate; then
  fresh
  prop <<'EOF'
## Notes
```
**Outcome:** NEEDS_HUMAN_DECISION — example
```
EOF
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q 'specify-gate' "$LOG"; then pass "$name"; else fail "$name" "rc=$rc"; fi
fi

# ── 2.3 Gate ───────────────────────────────────────────────────────────────────

echo "=== gate ==="

OPEN_PROP='# Doc classification

## Business Outcomes

### O1
**Who:** Not specified.
**Need:** Not specified.
**Outcome:** NEEDS_HUMAN_DECISION — which role consumes the classified documents?
**Measure:** Not specified.
'

name="gate rc 0 with no proposal.md"
if need "$name" planner_specify_gate; then
  fresh
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name" "rc=$rc"; fi
fi

name="gate rc 0 with no markers"
if need "$name" planner_specify_gate; then
  fresh
  printf '## Business Outcomes\n### O1\n**Outcome:** Accountants see ready documents.\n' >"$PROP"
  before=$(cat "$LOG")
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$before" = "$(cat "$LOG")" ]; then pass "$name"; else fail "$name" "rc=$rc or log changed"; fi
fi

name="gate rc 3 with one open decision, and the halt report lists it"
if need "$name" planner_specify_gate planner_specify_halt_report; then
  fresh
  printf '%s' "$OPEN_PROP" >"$PROP"
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  report=$(planner_specify_halt_report "$INIT" "$IDIR")
  if [ "$rc" -eq 3 ] &&
    printf '%s\n' "$report" | grep -qF "Specify is waiting on 1 business decision(s)" &&
    printf '%s\n' "$report" | grep -qF "  O1  which role consumes the classified documents?" &&
    printf '%s\n' "$report" | grep -qF "bash lib/planner-stop-describe.sh ${INIT}, then /ticket-planner resume ${INIT} --answers <file>" &&
    printf '%s\n' "$report" | grep -qF "Proposal:   ${IDIR}/artifacts/proposal.md"; then
    pass "$name"
  else fail "$name" "rc=$rc report=[$report]"; fi
fi

name="gate writes no phase line"
if need "$name" planner_specify_gate; then
  # Same initiative as above: a Specify start/done on record, then gate twice.
  planner_state_write "$INIT" Specify synthesize start "x"
  planner_state_write "$INIT" Specify synthesize "done" "x"
  before=$(grep -c '|Specify|\||Review|' "$LOG" || true)
  planner_specify_gate "$INIT" || true
  planner_specify_gate "$INIT" || true
  after=$(grep -c '|Specify|\||Review|' "$LOG" || true)
  pos=$(planner_position_derive "$INIT")
  if [ "$before" = "$after" ] && [ "$pos" = "Review" ]; then pass "$name"; else fail "$name" "$before -> $after, pos=$pos"; fi
fi

name="gate rc 0 after a hand edit"
if need "$name" planner_specify_gate; then
  sed -i 's/^\*\*Outcome:\*\* NEEDS_HUMAN_DECISION.*/**Outcome:** Accountants can see which documents are ready/' "$PROP"
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name" "rc=$rc"; fi
fi

name="gate rc 0 after an answered line"
if need "$name" planner_specify_gate planner_specify_render_answer planner_specify_substitute; then
  fresh
  printf '%s' "$OPEN_PROP" >"$PROP"
  line=$(planner_specify_render_answer "Tax accountants preparing returns" 2 client)
  planner_specify_substitute "$PROP" "${PROP}.tmp" 8 "$line" && mv "${PROP}.tmp" "$PROP"
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name" "rc=$rc"; fi
fi

name="gate rc 0 after a deferred line"
if need "$name" planner_specify_gate planner_specify_render_defer planner_specify_substitute; then
  fresh
  printf '%s' "$OPEN_PROP" >"$PROP"
  line=$(planner_specify_render_defer "which role consumes the classified documents?")
  planner_specify_substitute "$PROP" "${PROP}.tmp" 8 "$line" && mv "${PROP}.tmp" "$PROP"
  rc=0
  planner_specify_gate "$INIT" || rc=$?
  if [ "$rc" -eq 0 ] && grep -qxF "**Outcome:** Deferred decision: which role consumes the classified documents?" "$PROP"; then
    pass "$name"
  else fail "$name" "rc=$rc"; fi
fi

name="gate rc 1 with an unreadable proposal"
if need "$name" planner_specify_gate; then
  if [ "$(id -u)" = "0" ]; then
    pass "$name (skipped: root can read anything)"
  else
    fresh
    printf '%s' "$OPEN_PROP" >"$PROP"
    chmod 000 "$PROP"
    rc=0
    planner_specify_gate "$INIT" 2>/dev/null || rc=$?
    chmod 644 "$PROP"
    if [ "$rc" -eq 1 ]; then pass "$name"; else fail "$name" "rc=$rc"; fi
  fi
fi

name="a set -euo pipefail caller survives rc 3"
if need "$name" planner_specify_gate; then
  fresh
  printf '%s' "$OPEN_PROP" >"$PROP"
  out=$(INIT="$INIT" SD_LIB="$SD_LIB" bash -c '
    set -euo pipefail
    source "$SD_LIB"
    _sd_rc=0; planner_specify_gate "$INIT" || _sd_rc=$?
    case "$_sd_rc" in
    0) echo "clear" ;;
    3) echo "halt rc=$_sd_rc" ;;
    *) echo "error rc=$_sd_rc" ;;
    esac
    echo "still alive"
  ' 2>&1) || true
  if [ "$out" = "$(printf 'halt rc=3\nstill alive')" ]; then pass "$name"; else fail "$name" "got [$out]"; fi
fi

name="sourcing the lib does not set errexit or nounset in the caller"
if [ -f "$SD_LIB" ]; then
  flags=$(SD_LIB="$SD_LIB" bash -c 'source "$SD_LIB"; echo "$-"')
  case "$flags" in
  *e* | *u*) fail "$name" "flags=$flags" ;;
  *) pass "$name" ;;
  esac
else
  fail "$name" "lib missing"
fi

# ── 2.5 Rendering and substitution ─────────────────────────────────────────────

echo "=== rendering and substitution ==="

name="answer line has the exact format"
if need "$name" planner_specify_render_answer; then
  got=$(planner_specify_render_answer "Tax accountants preparing returns" 2 client)
  if [ "$got" = '**Outcome:** Human decision (verbatim, round 2, client): "Tax accountants preparing returns"' ]; then
    pass "$name"
  else fail "$name" "got [$got]"; fi
fi

name="double quotes become single quotes"
if need "$name" planner_specify_render_answer; then
  got=$(planner_specify_render_answer 'the "senior" accountant' 1 operator)
  if [ "$got" = "**Outcome:** Human decision (verbatim, round 1, operator): \"the 'senior' accountant\"" ]; then
    pass "$name"
  else fail "$name" "got [$got]"; fi
fi

name="comments, tilde runs and the marker token are neutralised"
if need "$name" planner_specify_render_answer; then
  got=$(planner_specify_render_answer 'a <!-- hidden --> b ~~~~ c <!-- open d --> e NEEDS_HUMAN_DECISION f NEEDS_HUMAN<!-- x -->_DECISION' 1 client)
  case "$got" in
  *'<!--'* | *'-->'* | *'~~~'* | *NEEDS_HUMAN_DECISION*) fail "$name" "got [$got]" ;;
  *NEEDS-HUMAN-DECISION*) pass "$name" ;;
  *) fail "$name" "token not rewritten: [$got]" ;;
  esac
fi

name="defer line has the exact format"
if need "$name" planner_specify_render_defer; then
  got=$(planner_specify_render_defer "which role?")
  if [ "$got" = "**Outcome:** Deferred decision: which role?" ]; then pass "$name"; else fail "$name" "got [$got]"; fi
fi

name="render rejects a bad round or role"
if need "$name" planner_specify_render_answer; then
  r1=0
  planner_specify_render_answer "x" 0 client >/dev/null 2>&1 || r1=$?
  r2=0
  planner_specify_render_answer "x" 1 admin >/dev/null 2>&1 || r2=$?
  if [ "$r1" -ne 0 ] && [ "$r2" -ne 0 ]; then pass "$name"; else fail "$name" "r1=$r1 r2=$r2"; fi
fi

INJ='$(touch '"$WORK"'/pwned) `id` <!-- x --> NEEDS_HUMAN_DECISION — again'

name="injection text stays literal through render and substitute"
if need "$name" planner_specify_render_answer planner_specify_substitute planner_specify_decisions_scan planner_specify_decisions_stray; then
  fresh
  printf '%s' "$OPEN_PROP" >"$PROP"
  line=$(planner_specify_render_answer "$INJ" 1 client)
  planner_specify_substitute "$PROP" "${PROP}.tmp" 8 "$line" && mv "${PROP}.tmp" "$PROP"
  got=$(sed -n 8p "$PROP")
  if [ ! -e "$WORK/pwned" ] &&
    [ "$got" = "**Outcome:** Human decision (verbatim, round 1, client): \"\$(touch ${WORK}/pwned) \`id\` NEEDS-HUMAN-DECISION — again\"" ] &&
    [ -z "$(scan)" ] && [ -z "$(stray)" ]; then
    pass "$name"
  else fail "$name" "got [$got] pwned=$([ -e "$WORK/pwned" ] && echo yes || echo no)"; fi
fi

name="rendered and deferred lines never match the scan or the tripwire"
if need "$name" planner_specify_render_answer planner_specify_render_defer planner_specify_substitute planner_specify_decisions_scan planner_specify_decisions_stray; then
  fresh
  printf '## Business Outcomes\n### O1\n**Outcome:** NEEDS_HUMAN_DECISION — a?\n### O2\n**Outcome:** NEEDS_HUMAN_DECISION — NEEDS_HUMAN_DECISION b?\n' >"$PROP"
  a=$(planner_specify_render_answer "NEEDS_HUMAN_DECISION — yes" 1 client)
  d=$(planner_specify_render_defer "$(scan | sed -n 2p | cut -f4)")
  planner_specify_substitute "$PROP" "${PROP}.tmp" 3 "$a" && mv "${PROP}.tmp" "$PROP"
  planner_specify_substitute "$PROP" "${PROP}.tmp" 5 "$d" && mv "${PROP}.tmp" "$PROP"
  if [ -z "$(scan)" ] && [ -z "$(stray)" ]; then pass "$name"; else fail "$name" "scan [$(scan)] stray [$(stray)]"; fi
fi

name="substitute changes only the target line"
if need "$name" planner_specify_render_answer planner_specify_substitute; then
  fresh
  printf '%s' "$OPEN_PROP" >"$PROP"
  cp "$PROP" "${WORK}/orig.md"
  line=$(planner_specify_render_answer "Tax accountants" 1 client)
  planner_specify_substitute "$PROP" "${WORK}/new.md" 8 "$line"
  if [ "$(sed 8d "${WORK}/orig.md")" = "$(sed 8d "${WORK}/new.md")" ] &&
    [ "$(sed -n 8p "${WORK}/new.md")" = "$line" ] &&
    [ "$(wc -l <"${WORK}/orig.md")" = "$(wc -l <"${WORK}/new.md")" ] &&
    cmp -s "$PROP" "${WORK}/orig.md"; then
    pass "$name"
  else fail "$name" "diff: $(diff "${WORK}/orig.md" "${WORK}/new.md" | head -5)"; fi
fi

name="substitute refuses a line that is not a marker"
if need "$name" planner_specify_substitute; then
  fresh
  printf '%s' "$OPEN_PROP" >"$PROP"
  rc=0
  planner_specify_substitute "$PROP" "${WORK}/x.md" 6 "**Outcome:** x" 2>/dev/null || rc=$?
  rc2=0
  planner_specify_substitute "$PROP" "${WORK}/y.md" 99 "**Outcome:** x" 2>/dev/null || rc2=$?
  if [ "$rc" -eq 2 ] && [ "$rc2" -eq 2 ]; then pass "$name"; else fail "$name" "rc=$rc rc2=$rc2"; fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
