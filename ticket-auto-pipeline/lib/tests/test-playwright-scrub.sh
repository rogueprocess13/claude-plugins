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

_run "password-named textbox values are redacted" t_label_redaction
_run "configured password is redacted anywhere, never printed" t_literal_redaction
_run "idempotent, missing dir, mode kept, usage exit 2" t_edges
_run "REPOS_ROOT snapshot dir is scrubbed" t_repos_root
_run "router and ticket-verify call the scrub" t_wiring
_run "router post-spawn VERIFY scrubs ./.playwright-mcp" t_router_post_spawn

echo "test-playwright-scrub: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
