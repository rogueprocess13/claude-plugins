#!/usr/bin/env bash
# test-state-root-anchor.sh — who writes and who checks the log-dir anchor
# (state-root-anchor, review ARCH-5, tasks 3.1/3.2):
#
#   * lib/ticket-preamble.sh writes $REPOS_ROOT/.ticket-auto/log-dir when it
#     is absent, and refuses (TP_USAGE) when the router's logs dir is not the
#     anchored one (design D3, D4);
#   * lib/env-check.sh --anchor-log-dir writes it, and full mode reports it;
#   * skills/ticket-flow/state-root-doctor.sh lists stray outboxes and
#     pipeline logs, read-only.
#
# Every case builds its own mktemp -d tree; REPOS_ROOT is never a real one.
#
# Usage: bash test-state-root-anchor.sh
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PLUGIN_DIR="$(cd "$LIB_DIR/.." && pwd)"
DOCTOR_SH="$PLUGIN_DIR/skills/ticket-flow/state-root-doctor.sh"
ENV_CHECK_SH="$LIB_DIR/env-check.sh"

PASS=0
FAIL=0

# env-check asks before writing the log-dir anchor when stdin is a terminal;
# a test run must never block on that prompt.
exec </dev/null
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1${2:+ — $2}"
  FAIL=$((FAIL + 1))
}

unset FLEET_PIPELINE_LOG_DIR STATE_ROOT_STRICT STATE_ROOT_LOG REPOS_ROOT \
  FLEET_GENERATION FLEET_STATE_DIR FLEET_WORKER_PID LOG_FILE HB_LOG_FILE \
  CLAUDE_LOG_FILE _TLD_LEGACY_WARNED ENV_CHECK_INTERACTIVE

TMPS=()
cleanup() {
  local d
  for d in "${TMPS[@]}"; do rm -rf "$d"; done
}
trap cleanup EXIT

# env-check hermeticity, as in test-env-check.sh: no filesystem-wide jgit walk,
# no network.
_SCR=$(mktemp -d)
TMPS+=("$_SCR")
export ENV_CHECK_JGIT_LOCK_ROOT="$_SCR/lockroot"
mkdir -p "$ENV_CHECK_JGIT_LOCK_ROOT" "$_SCR/bin"
printf '#!/bin/sh\nexit 7\n' >"$_SCR/bin/curl"
chmod +x "$_SCR/bin/curl"
export PATH="$_SCR/bin:$PATH"
export TICKET_TMP_DIR="$_SCR/tickettmp"
mkdir -p "$TICKET_TMP_DIR"
chmod 700 "$TICKET_TMP_DIR"

_new_root() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-state-root-anchor.XXXXXX")
  ROOT=$(cd "$ROOT" && pwd -P)
  TMPS+=("$ROOT")
  RR="$ROOT/repos"
  mkdir -p "$RR"
}

_anchor_file() { printf '%s/.ticket-auto/log-dir' "$1"; }

# _project -> PROJ, a project dir with a copied lib/ and a stubbed
# branch-resolve.sh, the way test-ticket-preamble.sh builds its sandbox.
_project() {
  PROJ="$ROOT/${1:-proj}"
  mkdir -p "$PROJ/lib"
  cp "$LIB_DIR"/*.sh "$PROJ/lib/"
  cat >"$PROJ/lib/branch-resolve.sh" <<'STUB'
#!/usr/bin/env bash
resolve_branch_context() {
  cat <<'BLOCK'
BRANCH_CONTEXT_RESULT:
  TICKET_BRANCH: feat/test-1
  BASE_BRANCH: develop
  INTEGRATION_BRANCH:
  BRANCH_SOURCE: default
  UAT_POLICY: per-ticket
  MERGE_POLICY: auto
BLOCK
}
STUB
}

# _preamble DIR [VAR=value ...] -> runs the preamble with cwd DIR; sets
# PRE_OUT, PRE_ERR, PRE_RC.
_preamble() {
  local dir="$1"
  shift
  PRE_RC=0
  PRE_OUT=$( (cd "$dir" && env "$@" bash "$PROJ/lib/ticket-preamble.sh" \
    TICKET_ID=TEST-SRA-1 PROJECT_DIR="$dir" SKIP_PREFLIGHT=true) 2>"$ROOT/pre.err") || PRE_RC=$?
  PRE_ERR=$(cat "$ROOT/pre.err")
}

_tree_sum() { (cd "$1" && find . -printf '%p %s %T@\n' | sort | md5sum); }

# ── preamble: writes the anchor when absent ──────────────────────────────────

_new_root
_project
_preamble "$PROJ" REPOS_ROOT="$RR"
if [ "$PRE_RC" -eq 0 ] && [ "$(cat "$(_anchor_file "$RR")" 2>/dev/null)" = "$PROJ/logs" ]; then
  pass "preamble: writes the anchor (realpath of PROJECT_DIR/logs) when absent"
else
  fail "preamble: writes the anchor when absent" "rc=$PRE_RC anchor=$(cat "$(_anchor_file "$RR")" 2>&1) err=$PRE_ERR"
fi

# second run, anchor equal: proceeds, anchor unchanged
_preamble "$PROJ" REPOS_ROOT="$RR"
if [ "$PRE_RC" -eq 0 ] && [ "$(cat "$(_anchor_file "$RR")")" = "$PROJ/logs" ]; then
  pass "preamble: re-entry with a matching anchor proceeds"
else
  fail "preamble: re-entry with a matching anchor proceeds" "rc=$PRE_RC err=$PRE_ERR"
fi

# REPOS_ROOT from the project's CLAUDE.md (env unset), the router's usual case
_new_root
_project
printf 'REPOS_ROOT = %s\n' "$RR" >"$PROJ/CLAUDE.md"
_preamble "$PROJ"
if [ "$PRE_RC" -eq 0 ] && [ "$(cat "$(_anchor_file "$RR")" 2>/dev/null)" = "$PROJ/logs" ]; then
  pass "preamble: REPOS_ROOT read from CLAUDE.md when not in the env"
else
  fail "preamble: REPOS_ROOT read from CLAUDE.md" "rc=$PRE_RC err=$PRE_ERR"
fi

# ── preamble: refuses on a mismatch ──────────────────────────────────────────

_new_root
_project
mkdir -p "$ROOT/elsewhere/logs" "$RR/.ticket-auto"
printf '%s\n' "$ROOT/elsewhere/logs" >"$(_anchor_file "$RR")"
_preamble "$PROJ" REPOS_ROOT="$RR"
want="log dir anchored at $ROOT/elsewhere/logs; run /ticket-auto from $ROOT/elsewhere"
if [ "$PRE_RC" -eq 1 ] && grep -qF -- "$want" <<<"$PRE_ERR"; then
  pass "preamble: refuses with TP_USAGE and names the anchored dir"
else
  fail "preamble: refuses on a cwd mismatch" "rc=$PRE_RC err=$PRE_ERR"
fi
if [ ! -e "$PROJ/logs" ] && [ "$(cat "$(_anchor_file "$RR")")" = "$ROOT/elsewhere/logs" ]; then
  pass "preamble: a refusal creates no logs dir and leaves the anchor alone"
else
  fail "preamble: a refusal creates nothing" "$(find "$PROJ" -maxdepth 1 | tr '\n' ' ')"
fi
if [ -z "$PRE_OUT" ]; then
  pass "preamble: a refusal prints no result block"
else
  fail "preamble: a refusal prints no result block" "$PRE_OUT"
fi

# symlinked paths: anchor written through a symlink, run from the real path
_new_root
_project
ln -s "$PROJ" "$ROOT/proj-link"
mkdir -p "$RR/.ticket-auto"
printf '%s\n' "$ROOT/proj-link/logs" >"$(_anchor_file "$RR")"
_preamble "$PROJ" REPOS_ROOT="$RR"
if [ "$PRE_RC" -eq 0 ]; then
  pass "preamble: an anchor through a symlink matches the real path"
else
  fail "preamble: symlink anchor matches" "rc=$PRE_RC err=$PRE_ERR"
fi

# absolute FLEET_PIPELINE_LOG_DIR (fleetd's env): equal via symlink proceeds
_new_root
_project
ln -s "$PROJ" "$ROOT/proj-link"
_preamble "$PROJ" REPOS_ROOT="$RR" FLEET_PIPELINE_LOG_DIR="$ROOT/proj-link/logs"
if [ "$PRE_RC" -eq 0 ] && [ "$(cat "$(_anchor_file "$RR")" 2>/dev/null)" = "$PROJ/logs" ]; then
  pass "preamble: an absolute FLEET_PIPELINE_LOG_DIR equal to the logs dir proceeds"
else
  fail "preamble: absolute env equal proceeds" "rc=$PRE_RC err=$PRE_ERR"
fi

# absolute FLEET_PIPELINE_LOG_DIR naming another dir: refused (emit_event
# would write there while the pipeline log lands here)
_new_root
_project
mkdir -p "$ROOT/other/logs"
_preamble "$PROJ" REPOS_ROOT="$RR" FLEET_PIPELINE_LOG_DIR="$ROOT/other/logs"
if [ "$PRE_RC" -eq 1 ] && grep -qF "$ROOT/other/logs" <<<"$PRE_ERR" &&
  [ ! -e "$(_anchor_file "$RR")" ]; then
  pass "preamble: an absolute FLEET_PIPELINE_LOG_DIR elsewhere is refused, no anchor written"
else
  fail "preamble: absolute env elsewhere refused" "rc=$PRE_RC err=$PRE_ERR"
fi

# a relative FLEET_PIPELINE_LOG_DIR carries no intent (config.sh's old ./logs)
_new_root
_project
_preamble "$PROJ" REPOS_ROOT="$RR" FLEET_PIPELINE_LOG_DIR=./logs
if [ "$PRE_RC" -eq 0 ]; then
  pass "preamble: a relative FLEET_PIPELINE_LOG_DIR is ignored"
else
  fail "preamble: relative env ignored" "rc=$PRE_RC err=$PRE_ERR"
fi

# REPOS_ROOT unknown (wrong cwd, no CLAUDE.md): the anchor is found by walking
# up from the cwd, and a mismatch is still refused
_new_root
_project "repos/some-repo/sub"
mkdir -p "$RR/.ticket-auto"
printf '%s\n' "$ROOT/tickets/logs" >"$(_anchor_file "$RR")"
_preamble "$PROJ"
if [ "$PRE_RC" -eq 1 ] && grep -qF "run /ticket-auto from $ROOT/tickets" <<<"$PRE_ERR"; then
  pass "preamble: no REPOS_ROOT — an ancestor anchor still refuses a wrong cwd"
else
  fail "preamble: ancestor anchor refuses" "rc=$PRE_RC err=$PRE_ERR"
fi

# no REPOS_ROOT and no anchor anywhere up: today's behaviour, nothing written
_new_root
_project
_preamble "$PROJ"
if [ "$PRE_RC" -eq 0 ] && [ ! -e "$(_anchor_file "$RR")" ] && [ ! -e "$ROOT/.ticket-auto" ] &&
  [ -f "$PROJ/logs/TEST-SRA-1-pipeline.log" ]; then
  pass "preamble: no REPOS_ROOT and no anchor — runs as before, writes no anchor"
else
  fail "preamble: no REPOS_ROOT legacy" "rc=$PRE_RC err=$PRE_ERR"
fi

# a present but unusable anchor (relative line) warns and proceeds
_new_root
_project
mkdir -p "$RR/.ticket-auto"
printf 'logs\n' >"$(_anchor_file "$RR")"
_preamble "$PROJ" REPOS_ROOT="$RR"
if [ "$PRE_RC" -eq 0 ] && grep -q 'absolute' <<<"$PRE_ERR" &&
  [ "$(cat "$(_anchor_file "$RR")")" = "logs" ]; then
  pass "preamble: an unusable anchor warns, proceeds and is not replaced"
else
  fail "preamble: unusable anchor warns" "rc=$PRE_RC err=$PRE_ERR"
fi

# ── env-check --anchor-log-dir ───────────────────────────────────────────────

_new_root
_project
printf 'REPOS_ROOT = %s\n' "$RR" >"$PROJ/CLAUDE.md"
EC_RC=0
EC_OUT=$(
  cd "$PROJ" || exit 1
  bash "$ENV_CHECK_SH" --anchor-log-dir logs 2>&1
) || EC_RC=$?
if [ "$EC_RC" -eq 0 ] && [ "$(cat "$(_anchor_file "$RR")" 2>/dev/null)" = "$PROJ/logs" ] &&
  grep -qx "LOG_DIR_ANCHOR: $PROJ/logs" <<<"$EC_OUT"; then
  pass "env-check: --anchor-log-dir writes the absolute path and prints it"
else
  fail "env-check: --anchor-log-dir writes" "rc=$EC_RC out=$EC_OUT"
fi

EC_RC=0
EC_OUT=$(
  cd "$PROJ" || exit 1
  bash "$ENV_CHECK_SH" --anchor-log-dir="$ROOT/other" 2>&1
) || EC_RC=$?
if [ "$EC_RC" -eq 1 ] && [ "$(cat "$(_anchor_file "$RR")")" = "$PROJ/logs" ] &&
  grep -qx "LOG_DIR_ANCHOR: $PROJ/logs" <<<"$EC_OUT"; then
  pass "env-check: --anchor-log-dir never replaces an anchor (rc 1, prints the current one)"
else
  fail "env-check: --anchor-log-dir write-once" "rc=$EC_RC out=$EC_OUT"
fi

EC_RC=0
EC_OUT=$(
  cd "$PROJ" || exit 1
  bash "$ENV_CHECK_SH" --anchor-log-dir "$PROJ/logs" 2>&1
) || EC_RC=$?
if [ "$EC_RC" -eq 0 ]; then
  pass "env-check: --anchor-log-dir with the anchored value is rc 0"
else
  fail "env-check: --anchor-log-dir same value" "rc=$EC_RC out=$EC_OUT"
fi

_new_root
mkdir -p "$ROOT/bare"
EC_RC=0
EC_OUT=$(cd "$ROOT/bare" && bash "$ENV_CHECK_SH" --anchor-log-dir logs 2>&1) || EC_RC=$?
if [ "$EC_RC" -eq 2 ] && grep -q 'REPOS_ROOT' <<<"$EC_OUT" && [ ! -e "$ROOT/bare/.ticket-auto" ]; then
  pass "env-check: --anchor-log-dir without REPOS_ROOT is a usage error"
else
  fail "env-check: --anchor-log-dir without REPOS_ROOT" "rc=$EC_RC out=$EC_OUT"
fi

# full mode reports the anchor; asks only when interactive
_new_root
_project
printf 'REPOS_ROOT = %s\n' "$RR" >"$PROJ/CLAUDE.md"
EC_OUT=$(
  cd "$PROJ" || exit 1
  bash "$ENV_CHECK_SH" --mode=full "$PROJ" </dev/null 2>/dev/null || true
)
if grep -q '^LOG_DIR_ANCHOR|warn|' <<<"$EC_OUT" && [ ! -e "$(_anchor_file "$RR")" ]; then
  pass "env-check: full mode reports a missing anchor as warn and writes nothing"
else
  fail "env-check: full mode missing anchor" "$(grep LOG_DIR <<<"$EC_OUT")"
fi

EC_OUT=$(
  cd "$PROJ" || exit 1
  printf 'n\n' | ENV_CHECK_INTERACTIVE=1 bash "$ENV_CHECK_SH" --mode=full "$PROJ" 2>/dev/null || true
)
if [ ! -e "$(_anchor_file "$RR")" ]; then
  pass "env-check: interactive 'n' writes no anchor"
else
  fail "env-check: interactive n" "$(cat "$(_anchor_file "$RR")")"
fi

EC_OUT=$(
  cd "$PROJ" || exit 1
  printf 'y\n' | ENV_CHECK_INTERACTIVE=1 bash "$ENV_CHECK_SH" --mode=full "$PROJ" 2>/dev/null || true
)
if [ "$(cat "$(_anchor_file "$RR")" 2>/dev/null)" = "$PROJ/logs" ] &&
  grep -q "^LOG_DIR_ANCHOR|ok|$PROJ/logs|" <<<"$EC_OUT"; then
  pass "env-check: interactive 'y' anchors PROJECT_DIR/logs and reports ok"
else
  fail "env-check: interactive y" "$(grep LOG_DIR <<<"$EC_OUT")"
fi

# ── state-root-doctor.sh ─────────────────────────────────────────────────────

_doctor() {
  DR_RC=0
  DR_OUT=$( (cd "$1" && shift && env "$@" bash "$DOCTOR_SH") 2>&1) || DR_RC=$?
}

if [ ! -f "$DOCTOR_SH" ]; then
  fail "doctor: state-root-doctor.sh missing"
else
  # anchored, with one planted stray outbox and one stray pipeline log
  _new_root
  mkdir -p "$ROOT/tickets/logs" "$RR/.ticket-auto" "$RR/repo-a/sub/logs" "$RR/.git/logs"
  printf '%s\n' "$ROOT/tickets/logs" >"$(_anchor_file "$RR")"
  echo '{}' >"$ROOT/tickets/logs/T-1-outbox.jsonl"
  echo 'x' >"$ROOT/tickets/logs/T-1-pipeline.log"
  echo '{}' >"$RR/repo-a/sub/logs/T-1-outbox.jsonl"
  echo 'x' >"$RR/repo-a/sub/logs/T-2-pipeline.log"
  echo 'x' >"$RR/.git/logs/HEAD-pipeline.log"
  before=$(_tree_sum "$ROOT")
  _doctor "$RR/repo-a" REPOS_ROOT="$RR"
  after=$(_tree_sum "$ROOT")
  if [ "$DR_RC" -eq 1 ] &&
    grep -qx "STRAY: $RR/repo-a/sub/logs/T-1-outbox.jsonl" <<<"$DR_OUT" &&
    grep -qx "STRAY: $RR/repo-a/sub/logs/T-2-pipeline.log" <<<"$DR_OUT"; then
    pass "doctor: lists a planted stray outbox and pipeline log, exits 1"
  else
    fail "doctor: planted stray" "rc=$DR_RC out=$DR_OUT"
  fi
  if grep -qx "ANCHOR: $ROOT/tickets/logs" <<<"$DR_OUT" &&
    grep -qx "RESOLVED: $ROOT/tickets/logs" <<<"$DR_OUT" &&
    ! grep -q "STRAY: $ROOT/tickets" <<<"$DR_OUT" && ! grep -q '\.git' <<<"$DR_OUT"; then
    pass "doctor: prints the anchor and the resolved dir; skips the anchored dir and .git"
  else
    fail "doctor: header lines" "$DR_OUT"
  fi
  if [ "$before" = "$after" ]; then
    pass "doctor: changes nothing"
  else
    fail "doctor: changes nothing"
  fi

  # no strays
  rm -rf "$RR/repo-a/sub/logs"
  _doctor "$RR" REPOS_ROOT="$RR"
  if [ "$DR_RC" -eq 0 ] && ! grep -q '^STRAY:' <<<"$DR_OUT"; then
    pass "doctor: no strays exits 0"
  else
    fail "doctor: no strays" "rc=$DR_RC out=$DR_OUT"
  fi

  # --repos-root flag, no env
  DR_RC=0
  DR_OUT=$(cd "$ROOT" && bash "$DOCTOR_SH" --repos-root "$RR" 2>&1) || DR_RC=$?
  if [ "$DR_RC" -eq 0 ] && grep -qx "RESOLVED: $ROOT/tickets/logs" <<<"$DR_OUT"; then
    pass "doctor: --repos-root works without the env"
  else
    fail "doctor: --repos-root" "rc=$DR_RC out=$DR_OUT"
  fi

  # unanchored (the pre-upgrade run): one state dir -> 0, two -> 1
  _new_root
  mkdir -p "$RR/tickets/logs"
  echo '{}' >"$RR/tickets/logs/T-1-outbox.jsonl"
  echo 'x' >"$RR/tickets/logs/T-1-pipeline.log"
  before=$(_tree_sum "$ROOT")
  _doctor "$RR" REPOS_ROOT="$RR"
  if [ "$DR_RC" -eq 0 ] && grep -qx 'ANCHOR: (none)' <<<"$DR_OUT" &&
    grep -qx "STATE_DIR: $RR/tickets/logs" <<<"$DR_OUT" &&
    [ "$before" = "$(_tree_sum "$ROOT")" ]; then
    pass "doctor: unanchored with one state dir exits 0, names it, writes no anchor"
  else
    fail "doctor: unanchored one dir" "rc=$DR_RC out=$DR_OUT"
  fi
  mkdir -p "$RR/repo-b/logs"
  echo '{}' >"$RR/repo-b/logs/T-9-outbox.jsonl"
  _doctor "$RR" REPOS_ROOT="$RR"
  if [ "$DR_RC" -eq 1 ] && grep -qx "STATE_DIR: $RR/repo-b/logs" <<<"$DR_OUT" &&
    grep -qx "STATE_DIR: $RR/tickets/logs" <<<"$DR_OUT"; then
    pass "doctor: unanchored with two state dirs exits 1 and lists both"
  else
    fail "doctor: unanchored two dirs" "rc=$DR_RC out=$DR_OUT"
  fi

  # no REPOS_ROOT at all
  mkdir -p "$ROOT/bare"
  DR_RC=0
  DR_OUT=$(cd "$ROOT/bare" && bash "$DOCTOR_SH" 2>&1) || DR_RC=$?
  if [ "$DR_RC" -eq 2 ] && grep -q 'REPOS_ROOT' <<<"$DR_OUT"; then
    pass "doctor: no REPOS_ROOT is a usage error (rc 2)"
  else
    fail "doctor: no REPOS_ROOT" "rc=$DR_RC out=$DR_OUT"
  fi
fi

echo ""
echo "state-root-anchor: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
