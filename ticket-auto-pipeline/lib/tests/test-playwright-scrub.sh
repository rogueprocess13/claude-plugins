#!/usr/bin/env bash
# test-playwright-scrub.sh — lib/playwright-scrub.sh (GitHub #819): typed
# passwords in Playwright MCP snapshots are redacted, the router's VERIFY
# post-spawn runs the scrub, and ticket-verify tells the agent to run it.
# Fake credentials only.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
SCRUB="$LIB_DIR/playwright-scrub.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unset UAT_TEST_PASSWORD REPOS_ROOT

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

FAKE_PW='Fake-Pw-1234!'
_snapshot() {
  cat <<EOF
- generic [ref=e1]:
  - textbox "Email" [ref=e5]: tester@example.test
  - textbox "Password" [ref=f6e26]: $FAKE_PW
  - textbox "Confirm password" [active] [ref=e7]: $FAKE_PW
  - textbox "PASSCODE" [ref=e8]: 9911
  - textbox "Search" [ref=e9]: password reset help
  - textbox "Password" [ref=e10]
  - paragraph [ref=e11]: Your password was $FAKE_PW
EOF
}

# 1. Password-named textboxes are redacted; other values survive.
t_label_redaction() {
  local d="$WORK/t1" out
  mkdir -p "$d/.playwright-mcp"
  _snapshot >"$d/.playwright-mcp/page-1.yml"
  out=$(cd "$d" && bash "$SCRUB") || return 1
  [ "$out" = "PLAYWRIGHT_SCRUB files=1 redacted=1" ] || {
    echo "  out: $out"
    return 1
  }
  local f="$d/.playwright-mcp/page-1.yml"
  grep -qF 'textbox "Password" [ref=f6e26]: [REDACTED]' "$f" &&
    grep -qF 'textbox "Confirm password" [active] [ref=e7]: [REDACTED]' "$f" &&
    grep -qF 'textbox "PASSCODE" [ref=e8]: [REDACTED]' "$f" &&
    grep -qF 'textbox "Email" [ref=e5]: tester@example.test' "$f" &&
    grep -qF 'textbox "Search" [ref=e9]: password reset help' "$f" &&
    grep -qxF '  - textbox "Password" [ref=e10]' "$f" &&
    ! grep -q 'textbox "[^"]*[Pp]ass[^"]*".*Fake-Pw' "$f"
}

# 2. The configured password is redacted anywhere, from env or CLAUDE.md,
#    and never printed.
t_literal_redaction() {
  local d="$WORK/t2" out
  mkdir -p "$d/.playwright-mcp"
  _snapshot >"$d/.playwright-mcp/page-2.yml"
  printf 'UAT_TEST_PASSWORD: `%s`\n' "$FAKE_PW" >"$d/CLAUDE.md"
  out=$(cd "$d" && bash "$SCRUB" 2>&1) || return 1
  case "$out" in *"$FAKE_PW"*) return 1 ;; esac
  ! grep -qF "$FAKE_PW" "$d/.playwright-mcp/page-2.yml" &&
    grep -qF 'Your password was [REDACTED]' "$d/.playwright-mcp/page-2.yml" || return 1
  local e="$WORK/t2b"
  mkdir -p "$e/snaps"
  _snapshot >"$e/snaps/page.md"
  (cd "$e" && UAT_TEST_PASSWORD="$FAKE_PW" bash "$SCRUB" snaps >/dev/null) &&
    ! grep -qF "$FAKE_PW" "$e/snaps/page.md"
}

# 3. Idempotent, missing dir is fine, mode is kept, usage error exits 2.
t_edges() {
  local d="$WORK/t3" out mode rc=0
  mkdir -p "$d/.playwright-mcp"
  _snapshot >"$d/.playwright-mcp/a.yml"
  chmod 640 "$d/.playwright-mcp/a.yml"
  (cd "$d" && bash "$SCRUB" >/dev/null) || return 1
  mode=$(stat -c %a "$d/.playwright-mcp/a.yml")
  [ "$mode" = 640 ] || return 1
  out=$(cd "$d" && bash "$SCRUB") || return 1
  [ "$out" = "PLAYWRIGHT_SCRUB files=1 redacted=0" ] || return 1
  out=$(cd "$WORK" && bash "$SCRUB" nowhere) || return 1
  [ "$out" = "PLAYWRIGHT_SCRUB files=0 redacted=0" ] || return 1
  bash "$SCRUB" --bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && [ -z "$(find "$d/.playwright-mcp" -name '*.scrub.*')" ]
}

# 4. REPOS_ROOT's snapshot dir is scrubbed too when run elsewhere.
t_repos_root() {
  local r="$WORK/t4root" c="$WORK/t4cwd"
  mkdir -p "$r/.playwright-mcp" "$c"
  _snapshot >"$r/.playwright-mcp/p.yml"
  (cd "$c" && REPOS_ROOT="$r" bash "$SCRUB" >/dev/null) &&
    grep -qF 'textbox "Password" [ref=f6e26]: [REDACTED]' "$r/.playwright-mcp/p.yml"
}

# 5. Wiring: router post-spawn VERIFY and the verify skill call the scrub.
t_wiring() {
  grep -q 'playwright-scrub.sh' "$LIB_DIR/router-step.sh" &&
    [ "$(grep -c 'lib/playwright-scrub.sh' "$PLUGIN_DIR/skills/ticket-verify/SKILL.md")" -ge 2 ]
}

# 6. router-step.sh post-spawn VERIFY scrubs ./.playwright-mcp.
t_router_post_spawn() {
  local d="$WORK/t6"
  mkdir -p "$d/logs" "$d/.playwright-mcp"
  _snapshot >"$d/.playwright-mcp/page.yml"
  printf 'RESULT=PASS\n' >"$d/logs/T-1-agent-return.txt"
  : >"$d/logs/T-1-pipeline.log"
  (cd "$d" && TICKET_TMP_DIR="$WORK/tmp6" bash "$LIB_DIR/router-step.sh" post-spawn VERIFY T-1 \
    --log-file "$d/logs/T-1-pipeline.log" >/dev/null 2>&1) || true
  grep -qF 'textbox "Password" [ref=f6e26]: [REDACTED]' "$d/.playwright-mcp/page.yml"
}

# 7-10. SessionStart sweep (hooks/playwright-scrub-sweep.sh): a session killed
#    mid-VERIFY never reaches post-spawn or ticket-verify Step 5, so the next
#    session's start scrubs what it left. No pipeline-log line, stdout empty.
SWEEP="$PLUGIN_DIR/hooks/playwright-scrub-sweep.sh"

t_sweep_registered() {
  [ -x "$SWEEP" ] &&
    jq -e '[.hooks.SessionStart[].hooks[].command] | any(endswith("/hooks/playwright-scrub-sweep.sh"))' \
      "$PLUGIN_DIR/.claude-plugin/plugin.json" >/dev/null
}

t_sweep_project_dir() {
  local d="$WORK/t8" o="$WORK/t8.out" e="$WORK/t8.err"
  mkdir -p "$d/.playwright-mcp" "$d/logs" "$d/.ticket-auto"
  _snapshot >"$d/.playwright-mcp/killed.yml"
  printf '2026-01-01T00:00:00Z|META|outcome|info|stopped: killed\n' >"$d/logs/T-9-pipeline.log"
  printf 'UAT_TEST_PASSWORD: `%s`\n' "$FAKE_PW" >"$d/CLAUDE.md"
  (cd "$WORK" && CLAUDE_PROJECT_DIR="$d" bash "$SWEEP" </dev/null >"$o" 2>"$e") || return 1
  [ ! -s "$o" ] || return 1
  ! grep -qF "$FAKE_PW" "$e" "$d/.playwright-mcp/killed.yml" || return 1
  grep -q 'redacted=1' "$e" &&
    grep -qF 'textbox "Password" [ref=f6e26]: [REDACTED]' "$d/.playwright-mcp/killed.yml" &&
    [ "$(tail -n1 "$d/logs/T-9-pipeline.log")" = '2026-01-01T00:00:00Z|META|outcome|info|stopped: killed' ] &&
    [ -z "$(find "$d" -name '*.scrub.*')" ] || return 1
  # Idempotent: a second session start rewrites nothing and says nothing.
  (cd "$d" && env -u CLAUDE_PROJECT_DIR bash "$SWEEP" </dev/null >"$o" 2>"$e") || return 1
  [ ! -s "$o" ] && [ ! -s "$e" ]
}

t_sweep_repos_root() {
  local r="$WORK/t9root" c="$WORK/t9cwd" o
  mkdir -p "$r/.playwright-mcp" "$c"
  _snapshot >"$r/.playwright-mcp/p.yml"
  o=$(cd "$c" && env -u CLAUDE_PROJECT_DIR REPOS_ROOT="$r" bash "$SWEEP" </dev/null 2>/dev/null) || return 1
  [ -z "$o" ] && grep -qF 'textbox "Password" [ref=f6e26]: [REDACTED]' "$r/.playwright-mcp/p.yml"
}

t_sweep_noop_paths() {
  local d="$WORK/t10" o rc=0
  mkdir -p "$d"
  o=$(cd "$d" && env -u CLAUDE_PROJECT_DIR bash "$SWEEP" </dev/null 2>&1) || rc=$?
  [ "$rc" = 0 ] && [ -z "$o" ] || return 1
  # The scrub missing (a partial install) is a silent exit 0, too.
  local h="$WORK/t10hook/hooks"
  mkdir -p "$h" "$d/.playwright-mcp" "$d/.ticket-auto"
  cp "$SWEEP" "$h/"
  _snapshot >"$d/.playwright-mcp/x.yml"
  o=$(cd "$d" && env -u CLAUDE_PROJECT_DIR bash "$h/playwright-scrub-sweep.sh" </dev/null 2>&1) || rc=$?
  [ "$rc" = 0 ] && [ -z "$o" ]
}

# 11. A symlinked snapshot file is never followed: the link stays a link and
#     the file it points to (outside the dir) is unchanged.
t_symlink_file() {
  local d="$WORK/t11" out before
  mkdir -p "$d/.playwright-mcp" "$d/outside"
  _snapshot >"$d/outside/victim.yml"
  before=$(sha256sum <"$d/outside/victim.yml")
  ln -s "$d/outside/victim.yml" "$d/.playwright-mcp/link.yml"
  _snapshot >"$d/.playwright-mcp/real.yml"
  out=$(cd "$d" && UAT_TEST_PASSWORD="$FAKE_PW" bash "$SCRUB") || return 1
  [ "$out" = "PLAYWRIGHT_SCRUB files=1 redacted=1" ] &&
    [ -L "$d/.playwright-mcp/link.yml" ] &&
    [ "$(sha256sum <"$d/outside/victim.yml")" = "$before" ] &&
    ! grep -qF "$FAKE_PW" "$d/.playwright-mcp/real.yml" &&
    [ -z "$(find "$d" -name '*.scrub.*')" ]
}

# 12. A .playwright-mcp dir that is itself a symlink is refused, both as the
#     default dir and when named; its target's files are unchanged.
t_symlink_dir() {
  local d="$WORK/t12" out before
  mkdir -p "$d/elsewhere"
  _snapshot >"$d/elsewhere/s.yml"
  before=$(sha256sum <"$d/elsewhere/s.yml")
  ln -s "$d/elsewhere" "$d/.playwright-mcp"
  out=$(cd "$d" && bash "$SCRUB") || return 1
  [ "$out" = "PLAYWRIGHT_SCRUB files=0 redacted=0" ] || return 1
  out=$(cd "$d" && bash "$SCRUB" .playwright-mcp/) || return 1
  [ "$out" = "PLAYWRIGHT_SCRUB files=0 redacted=0" ] &&
    [ "$(sha256sum <"$d/elsewhere/s.yml")" = "$before" ]
}

# 13. The hook does nothing outside a tickets root (no .ticket-auto/ marker,
#     no REPOS_ROOT), even with a snapshot dir present.
t_sweep_needs_tickets_root() {
  local d="$WORK/t13" o before
  mkdir -p "$d/.playwright-mcp"
  _snapshot >"$d/.playwright-mcp/p.yml"
  before=$(sha256sum <"$d/.playwright-mcp/p.yml")
  o=$(cd "$WORK" && CLAUDE_PROJECT_DIR="$d" bash "$SWEEP" </dev/null 2>&1) || return 1
  [ -z "$o" ] || return 1
  o=$(cd "$d" && env -u CLAUDE_PROJECT_DIR bash "$SWEEP" </dev/null 2>&1) || return 1
  [ -z "$o" ] && [ "$(sha256sum <"$d/.playwright-mcp/p.yml")" = "$before" ]
}

_run "password-named textbox values are redacted" t_label_redaction
_run "configured password is redacted anywhere, never printed" t_literal_redaction
_run "idempotent, missing dir, mode kept, usage exit 2" t_edges
_run "REPOS_ROOT snapshot dir is scrubbed" t_repos_root
_run "router and ticket-verify call the scrub" t_wiring
_run "router post-spawn VERIFY scrubs ./.playwright-mcp" t_router_post_spawn
_run "SessionStart sweep hook is registered and executable" t_sweep_registered
_run "sweep scrubs the project dir, stdout empty, log untouched, idempotent" t_sweep_project_dir
_run "sweep scrubs REPOS_ROOT's snapshot dir" t_sweep_repos_root
_run "sweep is silent with no snapshot dir or no scrub script" t_sweep_noop_paths
_run "symlinked snapshot file is not followed, target unchanged" t_symlink_file
_run "symlinked .playwright-mcp dir is refused" t_symlink_dir
_run "sweep is a no-op outside a tickets root" t_sweep_needs_tickets_root

echo "test-playwright-scrub: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
