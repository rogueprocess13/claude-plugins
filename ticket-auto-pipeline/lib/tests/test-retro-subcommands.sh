#!/usr/bin/env bash
# test-retro-subcommands.sh — ticket-retro's retro.sh subcommands
# (skill-deterministic-extraction 6a): --claude-scan, --render-sections,
# --github-post and retro_calibration_notes.
#
# Oracles: the pre-extraction Step 1.5 and Step 1.6 fences (main @ 267c17f,
# embedded below; CI checkouts are shallow) run in the same workspace, and
# fixtures/retro-render/example.md, the Step 4 section examples lifted from
# that SKILL.md. The examples' table padding was hand-aligned, so table rows
# are compared with runs of spaces squeezed.
#
# Usage: bash test-retro-subcommands.sh
set -eo pipefail

RS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS_LIB_DIR="$(cd "$RS_TEST_DIR/.." && pwd)"
RS_SKILL_DIR="$(cd "$RS_LIB_DIR/../skills/ticket-retro" && pwd)"
RETRO_SH="$RS_SKILL_DIR/retro.sh"
FIX="$RS_TEST_DIR/fixtures/retro-render"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}
_same() {
  if [ "$2" = "$3" ]; then _ok "$1"; else
    _ko "$1"
    diff <(echo "$2") <(echo "$3") | sed 's/^/    /' || true
  fi
}

_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/home/.claude/skills" "$WS/tickets"
  mkdir -m 700 "$WS/scratch"
  ln -s "$RS_LIB_DIR" "$WS/home/.claude/skills/lib"
  ln -s "$RS_SKILL_DIR" "$WS/home/.claude/skills/ticket-retro"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch"
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_corr() { # <notes> <source> <fact> <corrected>
  printf '\n<!-- CORRECTIONS -->\n- fact: %s\n- source: %s\n- corrected: %s\n<!-- /CORRECTIONS -->\n' "$3" "$2" "$4" >>"$1"
}

# ticket-retro Step 1.5 fence, main @ 267c17f (output files go to $RETRO_TMP).
_old_scan() {
  bash -c '
RETRO_TMP=$(bash ~/.claude/skills/lib/ticket-tmp.sh) || exit 1; echo "RETRO_TMP=$RETRO_TMP"
CLAUDE_FAILURES="$RETRO_TMP/claude-log-failures.txt"
CLAUDE_INSIGHTS="$RETRO_TMP/claude-log-insights.txt"
CLAUDE_HINTS="$RETRO_TMP/claude-log-hints.txt"
CLAUDE_CORRELATED="$RETRO_TMP/claude-log-correlated.txt"

if [ -n "${CLAUDE_LOG_FILE:-}" ] && [ -f "$CLAUDE_LOG_FILE" ]; then
  RETRO_SH="$HOME/.claude/skills/ticket-retro/retro.sh"
  source "$RETRO_SH"
  scan_claude_log_failures "$CLAUDE_LOG_FILE" "$CLAUDE_FAILURES" || true
  grep -n -A5 "★ Insight" "$CLAUDE_LOG_FILE" 2>/dev/null | head -100 > "$CLAUDE_INSIGHTS" || true
  grep -n "RETRO|hint" "$CLAUDE_LOG_FILE" 2>/dev/null | head -50 > "$CLAUDE_HINTS" || true
  if [ -s "$CLAUDE_FAILURES" ]; then
    correlate_failures_with_phase "$CLAUDE_LOG_FILE" "$CLAUDE_FAILURES" "$CLAUDE_CORRELATED" || true
  fi
  echo "claude-log-scan: done"
else
  echo "claude-log-scan: skipped (CLAUDE_LOG_FILE not set or file missing)"
fi
'
}
_snapshot() { # contents of the four scan files, in a fixed order
  local f
  for f in failures insights hints correlated; do
    echo "--- $f"
    cat "$WS/scratch/claude-log-$f.txt" 2>/dev/null || echo "(absent)"
  done
}

echo "=== --claude-scan: parity with Step 1.5 ==="
for c in full failures_only empty unset; do
  _ws_new
  cl="$WS/claude.log"
  case "$c" in
  full)
    printf '2026-11-01|IMPLEMENT|implement|start|go\nfatal: could not read from remote\n★ Insight ─────\nuse the cache\nmore\n2026-11-01|VERIFY|verify|start|go\npermission denied\nRETRO|hint|check perms first\n' >"$cl"
    ;;
  failures_only) printf 'timeout talking to API\n' >"$cl" ;;
  empty) : >"$cl" ;;
  unset) cl="" ;;
  esac
  OLD_OUT=$(CLAUDE_LOG_FILE="$cl" _old_scan)
  OLD_FILES=$(_snapshot)
  rm -f "$WS"/scratch/claude-log-*
  NEW_OUT=$(CLAUDE_LOG_FILE="$cl" bash "$RETRO_SH" --claude-scan)
  NEW_FILES=$(_snapshot)
  _same "$c: printed lines" "$OLD_OUT" "$NEW_OUT"
  _same "$c: scan files" "$OLD_FILES" "$NEW_FILES"
  want=done
  [ "$c" = unset ] && want=skipped
  _same "$c: status file" "$want" "$(cat "$WS/scratch/claude-log-scan.status")"
  _ws_rm
done

echo "=== retro_calibration_notes: parity with Step 1.6 ==="
_ws_new
mkdir -p "$WS/tickets/ABC-47--x" "$WS/tickets/ABC-48--y"
n="$WS/tickets/ABC-47--x/notes.md"
printf '# Notes\n' >"$n"
_corr "$n" appraise "sweep missed Feign" "Feign is in scope"
_corr "$n" exec "plan missed migration" "add V12"
_corr "$n" wiki "wiki gap" "ignored"
_corr "$n" appraise "second appraise gap" "fixed it"
# Step 1.6 fence, main @ 267c17f ({ticket}=ABC-47), plus the agent's read of
# CORRECTION_{N}_FACT/_CORRECTED after each eval.
old=$(cd "$WS/tickets" && bash -c '
source "$HOME/.claude/skills/lib/ticket-dir.sh"
source "$HOME/.claude/skills/lib/corrections-parse.sh"
set +eo pipefail
_dump() { for ((k = 0; k < ${CORRECTION_COUNT:-0}; k++)); do f="CORRECTION_${k}_FACT"; c="CORRECTION_${k}_CORRECTED"; printf "ABC-47\t%s\t%s\t%s\n" "$1" "${!f}" "${!c}"; done; }
_tdir=$(resolve_ticket_dir "ABC-47" "." 2>/dev/null) || _tdir=""
if [ -n "$_tdir" ] && [ -f "$_tdir/notes.md" ]; then
  eval "$(get_corrections_by_source "$_tdir/notes.md" appraise)"
  _appraise_count="${CORRECTION_COUNT:-0}"
  _dump appraise
  eval "$(get_corrections_by_source "$_tdir/notes.md" exec)"
  _dump exec
fi')
new=$(cd "$WS/tickets" && bash -c 'source "$1"; retro_calibration_notes ABC-47' _ "$RETRO_SH")
_same "notes: same appraise then exec entries" "$old" "$new"
[ "$(wc -l <<<"$new")" = 3 ] && _ok "notes: wiki entries excluded" || _ko "notes: $new"
new=$(bash -c 'source "$1"; retro_calibration_notes ABC-48 "$2"; retro_calibration_notes ZZZ-1 "$2"' _ "$RETRO_SH" "$WS/tickets")
_same "notes: no CORRECTIONS / unresolvable ticket prints nothing" "" "$new"
_ws_rm

echo "=== --render-sections ==="
_ws_new
mkdir -p "$WS/tickets/ABC-47--x" "$WS/tickets/ABC-48--y"
printf '# Notes\n' >"$WS/tickets/ABC-47--x/notes.md"
_corr "$WS/tickets/ABC-47--x/notes.md" appraise "Complexity sweep underestimated — undiscovered Feign dependency" "Feign client to billing is in scope"
printf '# Notes\n' >"$WS/tickets/ABC-48--y/notes.md"
_corr "$WS/tickets/ABC-48--y/notes.md" exec "Plan artifact missed a required DB migration" "Add V12 migration"
sed -i 's/Add V12 migration/Add the V12 migration/' "$WS/tickets/ABC-48--y/notes.md"
got=$(bash "$RETRO_SH" --render-sections "$FIX/example.json" --tickets-root "$WS/tickets")
_same "render: matches the SKILL.md examples" "$(tr -s ' ' <"$FIX/example.md")" "$(tr -s ' ' <<<"$got")"

# Suppressed rate, no planner logs, no notes, empty unscoreable, no histogram.
jq '.logs_by_source.planner = {scanned: 0, skipped: 0} | .failure_histogram = {} |
  .complexity_calibration.suppressed = true | .complexity_calibration.false_simple_rate = null |
  .complexity_calibration.simple_row_n = 2 | .complexity_calibration.false_simple_tickets = [] |
  .complexity_calibration.unscoreable = {missing_declared: 0, missing_outcome: 0} |
  .complexity_predictions = []' "$FIX/example.json" >"$WS/s.json"
got=$(bash "$RETRO_SH" --render-sections "$WS/s.json" --tickets-root "$WS/tickets")
grep -qx '\*\*False-simple rate:\*\* suppressed — only 2 simple ticket(s) this window (floor: 3)' <<<"$got" &&
  _ok "render: suppressed rate line" || _ko "render: suppressed line: $got"
! grep -q 'Sources scanned\|False-simples:\|Unscoreable\|Calibration Notes\|Claude Log' <<<"$got" &&
  _ok "render: omitted lines and sections" || _ko "render: omissions: $got"
grep -qx 'No failures in this window.' <<<"$got" && _ok "render: clean window" || _ko "render: clean window"

# Claude log sections follow the scan.
printf '2026-11-01|IMPLEMENT|implement|start|go\nfatal: x\n' >"$WS/claude.log"
CLAUDE_LOG_FILE="$WS/claude.log" bash "$RETRO_SH" --claude-scan >/dev/null
got=$(bash "$RETRO_SH" --render-sections "$WS/s.json" --scan-dir "$WS/scratch")
grep -q '^## Claude Log Failures$' <<<"$got" && grep -q '^### Unknown phase — 1 failure(s)$' <<<"$got" &&
  grep -qx 'No agent improvement hints found.' <<<"$got" && _ok "render: Claude log sections from the scan" ||
  _ko "render: Claude log sections: $got"
printf '★ Insight x\n' >"$WS/claude.log"
CLAUDE_LOG_FILE="$WS/claude.log" bash "$RETRO_SH" --claude-scan >/dev/null
got=$(bash "$RETRO_SH" --render-sections "$WS/s.json" --scan-dir "$WS/scratch")
grep -qx 'No failure signals detected in Claude log.' <<<"$got" && grep -qx 'No explicit RETRO|hint entries found.' <<<"$got" &&
  grep -q '^1:★ Insight x$' <<<"$got" && _ok "render: insight only" || _ko "render: insight only: $got"
CLAUDE_LOG_FILE="" bash "$RETRO_SH" --claude-scan >/dev/null
got=$(bash "$RETRO_SH" --render-sections "$WS/s.json" --scan-dir "$WS/scratch")
! grep -q 'Claude Log\|Agent Improvement' <<<"$got" && _ok "render: skipped scan omits both sections" || _ko "render: skipped scan"
rc=0
bash "$RETRO_SH" --render-sections "$WS/missing.json" >/dev/null 2>&1 || rc=$?
_same "render: unreadable JSON exits 2" 2 "$rc"
_ws_rm

echo "=== --github-post ==="
_ws_new
mkdir -p "$WS/bin"
cat >"$WS/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
case "$1 $2" in
"auth status") exit "${GH_AUTH_RC:-0}" ;;
"issue create") echo "https://github.com/o/r/issues/99" ;;
esac
EOF
chmod +x "$WS/bin/gh"
export GH_CALLS="$WS/gh-calls"
_input() {
  printf 'body\n' >"$WS/scratch/issue-body-EXEC_NO_ARTIFACT.md"
  printf 'more\n' >"$WS/scratch/evidence-EXEC_NO_ARTIFACT.md"
  jq -n --arg d "$WS/scratch" '{codes: {
    EXEC_NO_ARTIFACT: {count: 4, title: "Fix EXEC_NO_ARTIFACT — x", body_file: ($d + "/issue-body-EXEC_NO_ARTIFACT.md"), comment_file: ($d + "/evidence-EXEC_NO_ARTIFACT.md")},
    RETURN_INCOMPLETE: {count: 1, title: "t", body_file: "", comment_file: ""}}}' >"$WS/scratch/retro-input.json"
}
_input
out=$(PATH="$WS/bin:$PATH" bash "$RETRO_SH" --github-post "$WS/scratch")
grep -qx 'GITHUB_STATUS=posted' <<<"$out" && grep -qx 'GITHUB_CREATED=1' <<<"$out" && grep -qx 'GITHUB_UPDATED=0' <<<"$out" &&
  _ok "github: created count" || _ko "github: $out"
want=$(bash -c 'source "$1/github-issues.sh"; source "$1/github-issue-retro.sh"; github_retro_map_severity EXEC_NO_ARTIFACT' _ "$RS_LIB_DIR")
grep -q "issue create .*--label $want" "$GH_CALLS" && _ok "github: labels from github_retro_map_severity ($want)" ||
  _ko "github: labels: $(cat "$GH_CALLS")"
[ ! -e "$WS/scratch/retro-input.json" ] && [ ! -e "$WS/scratch/issue-body-EXEC_NO_ARTIFACT.md" ] &&
  _ok "github: scratch files removed" || _ko "github: scratch files left"
_input
out=$(GH_AUTH_RC=1 PATH="$WS/bin:$PATH" bash "$RETRO_SH" --github-post "$WS/scratch" 2>/dev/null)
grep -qx 'GITHUB_STATUS=skipped-auth' <<<"$out" && ! grep -q 'issue create' <(tail -1 "$GH_CALLS") &&
  _ok "github: unauthenticated skips the post" || _ko "github: auth fail: $out"
rc=0
bash "$RETRO_SH" --github-post >/dev/null 2>&1 || rc=$?
_same "github: usage exits 2" 2 "$rc"
_ws_rm

echo "=== sourcing still defines helpers only ==="
out=$(bash -c 'set +e; source "$1" --claude-scan; declare -F retro_render_sections >/dev/null && [[ $- != *e* ]] && echo OK' _ "$RETRO_SH" 2>/dev/null)
_same "source with a subcommand argument runs nothing" OK "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
