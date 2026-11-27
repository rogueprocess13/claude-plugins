#!/bin/bash
# SessionStart hook — redact typed passwords left in Playwright MCP snapshots
# by a session that never reached its own scrub (follow-up to GitHub #819).
#
# lib/playwright-scrub.sh runs after a VERIFY agent (router-step.sh
# post-spawn), inside ticket-verify, and from fleetd's phase-dispatch reap. A
# worker killed in the middle of VERIFY reaches none of them: a fleetd KILL or
# KILL+RESTART, fleet-stop.sh, the watchdog, a crash, or a person's Ctrl-C.
# Its snapshots stay in clear text. A crash or a Ctrl-C cannot be hooked when
# it happens, so the sweep runs on the one path every later session crosses:
# session start. A restarted worker, the next fleetd phase worker and a
# person's next session all start here, in the tickets root.
#
# Why not at kill time: a kill path writes the ticket's `META|outcome` line,
# which must stay the pipeline log's last line. This hook writes nothing to
# any pipeline log. Its one line goes to stderr, and only when a file was
# rewritten (SessionStart stdout is injected into the session's context).
#
# Dirs: the scrub's own defaults, ./.playwright-mcp plus
# $REPOS_ROOT/.playwright-mcp, run from a tickets root only: the session's
# project dir (CLAUDE_PROJECT_DIR, else the hook's cwd) when it holds the
# `.ticket-auto/` marker, else $REPOS_ROOT when set. In any other dir the hook
# does nothing. When no snapshot dir exists the scrub is not started at all.
#
# The scrub is idempotent, never prints a secret, and this hook exits 0 on
# every path. PLAYWRIGHT_SCRUB_SWEEP_TIMEOUT (seconds, default 12) bounds the
# scrub below the hook's registered timeout.
#
# -u (nounset) intentionally omitted, as in tmp-sweep.sh.
set -o pipefail

_pss_scrub="${BASH_SOURCE[0]%/*}/../lib/playwright-scrub.sh"
[ -f "$_pss_scrub" ] || exit 0

# Only ever inside a tickets root, never an arbitrary project dir: the
# session's project dir when it carries the `.ticket-auto/` marker, else
# $REPOS_ROOT itself when set. Anything else is a no-op.
_pss_proj="${CLAUDE_PROJECT_DIR:-$PWD}"
_pss_root=""
if [ -d "$_pss_proj/.ticket-auto" ] && [ ! -L "$_pss_proj/.ticket-auto" ]; then
  _pss_root="$_pss_proj"
elif [ -n "${REPOS_ROOT:-}" ] && [ -d "$REPOS_ROOT" ]; then
  _pss_root="$REPOS_ROOT"
fi
[ -n "$_pss_root" ] || exit 0
cd "$_pss_root" 2>/dev/null || exit 0

# Nothing to do (and the scrub is not started) without a real snapshot dir.
# playwright-scrub.sh itself refuses a symlinked dir and any file that is not
# a regular, non-symlink file this user owns.
_pss_has() { [ -d "$1" ] && [ ! -L "$1" ]; }
if ! _pss_has ./.playwright-mcp &&
  { [ -z "${REPOS_ROOT:-}" ] || ! _pss_has "$REPOS_ROOT/.playwright-mcp"; }; then
  exit 0
fi

_pss_timeout="${PLAYWRIGHT_SCRUB_SWEEP_TIMEOUT:-12}"
case "$_pss_timeout" in
'' | *[!0-9]* | 0) _pss_timeout=12 ;;
esac

if command -v timeout >/dev/null 2>&1; then
  _pss_out=$(timeout "$_pss_timeout" bash "$_pss_scrub" </dev/null 2>/dev/null)
else
  _pss_out=$(bash "$_pss_scrub" </dev/null 2>/dev/null)
fi

# The scrub prints only `PLAYWRIGHT_SCRUB files=N redacted=M`; anything else
# (or nothing, after a timeout) is not echoed.
case "$_pss_out" in
"PLAYWRIGHT_SCRUB files="*" redacted=0" | "") ;;
"PLAYWRIGHT_SCRUB files="*" redacted="*)
  echo "ticket-auto: redacted typed passwords in Playwright snapshots (${_pss_out#PLAYWRIGHT_SCRUB })" >&2
  ;;
esac

# Best-effort housekeeping — never block session start.
exit 0
