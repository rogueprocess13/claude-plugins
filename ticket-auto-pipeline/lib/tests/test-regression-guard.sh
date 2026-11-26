#!/usr/bin/env bash
# test-regression-guard.sh — lib/regression-guard.sh (GitHub #823): overlap
# from the prior ticket's real changed files (ai-context.md), and which
# verdicts need a person (CONFLICT always; SUPERSEDES unless the prior
# ticket is a dependency; ADJACENT never).
# Usage: bash test-regression-guard.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD_SH="$LIB_DIR/regression-guard.sh"
RISK_SH="$LIB_DIR/regression-risk.sh"

PASS=0
FAIL=0
_ok() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_no() {
  echo "FAIL: $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/    /'
  ((FAIL++)) || true
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── fixtures ─────────────────────────────────────────────────────────────────
# A tickets root with: EPIC-1 holding WIL-1 and WIL-2, WIL-9 in no epic, and
# WIL-3 (no epic) whose blocked_by names WIL-9.
_mk() {
  local t
  t=$(mktemp -d -p "$WORK")
  local ta="$t/repos/.ticket-auto/initiatives"
  mkdir -p "$t/logs" "$ta/_index" "$ta/EPIC-1/epic"
  echo '{"children":["WIL-1","WIL-2"]}' >"$ta/EPIC-1/epic/manifest.json"
  local tid init bb
  for tid in WIL-1 WIL-2 WIL-3 WIL-9; do
    case "$tid" in WIL-1 | WIL-2) init=INIT-1 ;; *) init=INIT-2 ;; esac
    bb='[]'
    [ "$tid" = WIL-3 ] && bb='["WIL-9"]'
    mkdir -p "$ta/$init/tickets/$tid/planner" "$t/tickets/${tid}--sample"
    echo "$init" >"$ta/_index/${tid}.initiative"
    echo "{\"type\":\"feature\",\"initiative\":\"$init\",\"blocked_by\":$bb}" >"$ta/$init/tickets/$tid/planner/manifest.json"
    : >"$t/logs/${tid}-pipeline.log"
    printf '# Notes\n\n## Prior Art\n- prior\n\n## Session Log\n- started\n' >"$t/tickets/${tid}--sample/notes.md"
  done
  echo "$t"
}

_env() {
  local t="$1"
  shift
  env -u CLAUDE_CODE_SESSION_ID -u FLEET_WORKER_PID -u FLEET_GENERATION -u TAP_LOG -u TICKET_ID \
    FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none REPOS_ROOT="$t/repos" \
    FLEET_PIPELINE_LOG_DIR="$t/logs" HB_LOG_FILE= "$@"
}

T=$(_mk)

# ── changed-files / overlap ──────────────────────────────────────────────────
PRIOR="$T/tickets/WIL-9--sample"
cat >"$PRIOR/ai-context.md" <<'EOF'
# AI Context

## What changed
- `src/router.js`: added the cart route
- src/main.js: wires the router
- **web/session.ts**: session cache

## Key files for future agents
- src/unrelated.js: not a change
EOF
got=$(bash "$GUARD_SH" changed-files "$PRIOR")
want=$'src/router.js\nsrc/main.js\nweb/session.ts'
[ "$got" = "$want" ] && _ok "changed-files reads only ## What changed" || _no "changed-files reads only ## What changed" "$got"

printf 'app/src/router.js\nsrc/other.js\n./web/session.ts\nsrc/unrelated.js\n' >"$WORK/plan.txt"
got=$(bash "$GUARD_SH" overlap "$WORK/plan.txt" "$PRIOR")
want=$'app/src/router.js\nweb/session.ts'
[ "$got" = "$want" ] && _ok "overlap matches by path suffix, ignores prose-only files" || _no "overlap matches by path suffix" "$got"

rc=0
bash "$GUARD_SH" overlap "$WORK/plan.txt" "$T/tickets/WIL-1--sample" >/dev/null || rc=$?
[ "$rc" -eq 1 ] && _ok "overlap exits 1 when the prior ticket has no ai-context.md" || _no "overlap no ai-context rc=$rc"

# ── relation ─────────────────────────────────────────────────────────────────
got=$(_env "$T" bash "$GUARD_SH" relation WIL-2 WIL-1)
[ "$got" = "dependency same-epic:EPIC-1" ] && _ok "same epic is a dependency" || _no "same epic is a dependency" "$got"
got=$(_env "$T" bash "$GUARD_SH" relation WIL-3 WIL-9)
[ "$got" = "dependency blocked-by" ] && _ok "blocked_by edge is a dependency" || _no "blocked_by edge is a dependency" "$got"
got=$(_env "$T" bash "$GUARD_SH" relation WIL-2 WIL-9)
[ "$got" = "unrelated" ] && _ok "other epic is unrelated" || _no "other epic is unrelated" "$got"
got=$(env -u REPOS_ROOT bash "$GUARD_SH" relation WIL-2 WIL-1)
[ "$got" = "unrelated" ] && _ok "no REPOS_ROOT reads as unrelated (stays gated)" || _no "no REPOS_ROOT" "$got"

# ── write + check: the gate decision ─────────────────────────────────────────
_rows() { printf '%s\n' "$@" >"$WORK/rows.tsv"; }
_write() { _env "$T" LOG_FILE="$T/logs/$1-pipeline.log" bash "$GUARD_SH" write "$1" "$T/tickets/$1--sample/notes.md" "$WORK/rows.tsv"; }
_check() { _env "$T" LOG_FILE="$T/logs/$1-pipeline.log" bash "$RISK_SH" check "$1" "$T/tickets/$1--sample/notes.md"; }

# Same-epic SUPERSEDES and ADJACENT: noted, no hold (the X1b case).
_rows "src/router.js	WIL-1	[local-ticket]	SUPERSEDES	replaces the stub route" \
  "src/main.js	WIL-1	[local-ticket]	ADJACENT	different section"
out=$(_write WIL-2)
notes="$T/tickets/WIL-2--sample/notes.md"
grep -q '^REGRESSION_GUARD_GATED=0$' <<<"$out" && grep -q '^REGRESSION_GUARD_WORST=SUPERSEDES$' <<<"$out" &&
  _ok "same-epic SUPERSEDES + ADJACENT gate nothing" || _no "same-epic SUPERSEDES + ADJACENT gate nothing" "$out"
grep -q '^## Regression Notes$' "$notes" && ! grep -qi 'regression risk' "$notes" &&
  grep -q 'same-epic:EPIC-1' "$notes" && _ok "rows land in ## Regression Notes" || _no "rows land in ## Regression Notes" "$(cat "$notes")"
rc=0
cout=$(_check WIL-2) || rc=$?
[ "$rc" -eq 0 ] && grep -q 'REGRESSION_RISK_GATE=clear' <<<"$cout" && _ok "implement gate is clear" || _no "implement gate is clear (rc=$rc)" "$cout"

# Cross-epic ADJACENT: still no hold.
_rows "src/router.js	WIL-9	[local-ticket]	ADJACENT	other method"
out=$(_write WIL-1)
rc=0
cout=$(_check WIL-1) || rc=$?
grep -q '^REGRESSION_GUARD_GATED=0$' <<<"$out" && [ "$rc" -eq 0 ] && _ok "ADJACENT never holds" || _no "ADJACENT never holds (rc=$rc)" "$out $cout"

# Cross-epic SUPERSEDES: holds.
T2=$(_mk)
T_SAVE="$T"
T="$T2"
_rows "src/router.js	WIL-9	[local-ticket]	SUPERSEDES	replaces the prior guard"
out=$(_write WIL-2)
notes="$T/tickets/WIL-2--sample/notes.md"
rc=0
cout=$(_check WIL-2) || rc=$?
grep -q '^REGRESSION_GUARD_GATED=1$' <<<"$out" && grep -q '^REGRESSION_RISK_RECORDED=[0-9a-f]\{12\}$' <<<"$out" &&
  [ "$rc" -eq 1 ] && grep -q 'REGRESSION_RISK_GATE=hold' <<<"$cout" &&
  _ok "unrelated SUPERSEDES is recorded and holds" || _no "unrelated SUPERSEDES holds (rc=$rc)" "$out $cout"
grep -q '^## ⚠️ Regression Risk$' "$notes" && grep -q 'regression-ack.sh WIL-2' "$notes" &&
  _ok "gated row written as ## ⚠️ Regression Risk" || _no "gated section" "$(cat "$notes")"

# Same-epic CONFLICT: holds (a dependency can still be undone).
T3=$(_mk)
T="$T3"
_rows "src/router.js	WIL-1	[local-ticket]	CONFLICT	reverts the cart route"
out=$(_write WIL-2)
rc=0
cout=$(_check WIL-2) || rc=$?
grep -q '^REGRESSION_GUARD_GATED=1$' <<<"$out" && [ "$rc" -eq 1 ] && _ok "same-epic CONFLICT still holds" || _no "same-epic CONFLICT holds (rc=$rc)" "$out $cout"

# An unknown verdict is read as CONFLICT.
T4=$(_mk)
T="$T4"
_rows "src/router.js	WIL-1	[local-ticket]	maybe	unclear"
out=$(_write WIL-2)
grep -q '^REGRESSION_GUARD_GATED=1$' <<<"$out" && grep -q '| CONFLICT |' "$T/tickets/WIL-2--sample/notes.md" &&
  _ok "unknown verdict is gated as CONFLICT" || _no "unknown verdict" "$out"

# A re-run replaces the sections instead of appending a second copy.
T="$T_SAVE"
_rows "src/main.js	WIL-1	[local-ticket]	ADJACENT	again"
_write WIL-2 >/dev/null
n=$(grep -c '^## Regression Notes$' "$T/tickets/WIL-2--sample/notes.md")
[ "$n" -eq 1 ] && grep -q '^## Session Log$' "$T/tickets/WIL-2--sample/notes.md" &&
  _ok "re-run replaces its own sections, keeps the rest" || _no "re-run replaces (n=$n)" "$(cat "$T/tickets/WIL-2--sample/notes.md")"

# Bad arguments.
rc=0
bash "$GUARD_SH" write bad-id "$WORK/none" "$WORK/rows.tsv" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && _ok "write refuses a bad ticket id (exit 2)" || _no "bad id rc=$rc"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
