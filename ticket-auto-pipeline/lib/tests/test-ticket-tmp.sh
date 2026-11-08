#!/usr/bin/env bash
# test-ticket-tmp.sh — lib/ticket-tmp.sh and lib/ticket-env.sh (GitHub #619).
#
# Covers:
#   1. ticket_tmp_dir creates the scratch dir 0700 and prints it.
#   2. It refuses a pre-existing dir that is group/other accessible, a
#      symlink, or not a directory — and prints nothing.
#   3. The uid default is /tmp/ticket-auto-$EUID (fleetd parity lives in
#      fleet-controller/fleetd/tests/test_phase_dispatch.py).
#   4. ticket_tmp_path validates the ticket id; the CLI mirrors both forms.
#   5. ticket_tmp_trusted: regular, not a symlink, ours, not g/o writable.
#   6. ticket_tmp_peek never creates the dir.
#   7. ticket-env.sh sources a trusted env file, skips an untrusted one with
#      a warning, is silent on a missing one, and returns 0 under set -e.
#   8. A hook ignores a spawn-meta LOG_FILE that is not a *-pipeline.log.
#
# Run: bash ticket-auto-pipeline/lib/tests/test-ticket-tmp.sh

set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TT="$LIB_DIR/ticket-tmp.sh"
TENV="$LIB_DIR/ticket-env.sh"
HOOK="$LIB_DIR/../hooks/agent-activity.sh"

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
expect() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

TMP="$(mktemp -d)"
cleanup() {
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
run_tt() { # $1=override, rest=args; prints "rc:stdout"
  local rc=0 out d="$1"
  shift
  out=$(TICKET_TMP_DIR="$d" bash "$TT" "$@" 2>/dev/null) || rc=$?
  printf '%s:%s' "$rc" "$out"
}

# ── 1. Creation ──────────────────────────────────────────────────────────────
expect "1a: missing dir is created and printed" "0:$TMP/s1" "$(run_tt "$TMP/s1")"
expect "1b: created 0700 (umask 002)" "700" "$(umask 002 && TICKET_TMP_DIR="$TMP/s1b" bash "$TT" >/dev/null && mode_of "$TMP/s1b")"
expect "1c: an existing 0700 dir is accepted" "0:$TMP/s1" "$(run_tt "$TMP/s1")"

# ── 2. Refusals ──────────────────────────────────────────────────────────────
mkdir -m 755 "$TMP/s2a"
chmod 755 "$TMP/s2a"
expect "2a: group/other-readable dir refused" "1:" "$(run_tt "$TMP/s2a")"
mkdir "$TMP/s2b"
chmod 777 "$TMP/s2b"
expect "2b: world-writable dir refused" "1:" "$(run_tt "$TMP/s2b")"
ln -s "$TMP/s1" "$TMP/s2c"
expect "2c: symlink to a good dir refused" "1:" "$(run_tt "$TMP/s2c")"
: >"$TMP/s2d"
expect "2d: a plain file refused" "1:" "$(run_tt "$TMP/s2d")"
err=$(TICKET_TMP_DIR="$TMP/s2b" bash "$TT" 2>&1 >/dev/null || true)
case "$err" in
*"refusing scratch dir"*) pass "2e: refusal warns on stderr" ;;
*) fail "2e: refusal warns on stderr" "stderr was '$err'" ;;
esac
# A foreign owner cannot be created without root; the -O branch is the same
# test as the symlink/file branch, and fleetd's parity test covers st_uid.

# ── 3. Default ───────────────────────────────────────────────────────────────
out=$(env -u TICKET_TMP_DIR bash -c 'source "$1"; d=$(ticket_tmp_dir 2>/dev/null) || d=REFUSED; printf %s "$d"' _ "$TT")
case "$out" in
"/tmp/ticket-auto-$EUID" | REFUSED) pass "3a: default is /tmp/ticket-auto-\$EUID ($out)" ;;
*) fail "3a: default" "got '$out'" ;;
esac
expect "3b: empty override means the default" "$(env -u TICKET_TMP_DIR bash "$TT" 2>/dev/null || true)" "$(TICKET_TMP_DIR="" bash "$TT" 2>/dev/null || true)"

# ── 4. Paths and ids ─────────────────────────────────────────────────────────
expect "4a: CLI file path" "0:$TMP/s1/ticket-auto-ABC-12-env.sh" "$(run_tt "$TMP/s1" ABC-12 env.sh)"
expect "4b: traversal id refused" "1:" "$(run_tt "$TMP/s1" "../x" env.sh)"
expect "4c: id with a slash refused" "1:" "$(run_tt "$TMP/s1" "a/b" env.sh)"
expect "4d: id with a space refused" "1:" "$(run_tt "$TMP/s1" "a b" env.sh)"
expect "4e: empty id refused" "1:" "$(run_tt "$TMP/s1" "" env.sh)"
expect "4f: path in a refused dir refused" "1:" "$(run_tt "$TMP/s2b" ABC-12 env.sh)"

# ── 5. ticket_tmp_trusted ────────────────────────────────────────────────────
(
  # shellcheck source=../ticket-tmp.sh
  source "$TT"
  f="$TMP/s1/ok"
  : >"$f"
  chmod 600 "$f"
  ticket_tmp_trusted "$f" && echo ok600
  chmod 644 "$f"
  ticket_tmp_trusted "$f" && echo ok644
  chmod 664 "$f"
  ticket_tmp_trusted "$f" || echo no664
  chmod 602 "$f"
  ticket_tmp_trusted "$f" || echo no602
  chmod 600 "$f"
  ln -s "$f" "$TMP/s1/lnk"
  ticket_tmp_trusted "$TMP/s1/lnk" || echo nolink
  ticket_tmp_trusted "$TMP/s1" || echo nodir
  ticket_tmp_trusted "$TMP/s1/missing" || echo nomissing
) >"$TMP/t5.out"
expect "5: trusted verdicts" "ok600 ok644 no664 no602 nolink nodir nomissing" "$(tr '\n' ' ' <"$TMP/t5.out" | sed 's/ $//')"

# ── 6. peek never creates ────────────────────────────────────────────────────
rc=0
TICKET_TMP_DIR="$TMP/s6" bash -c 'source "$1"; ticket_tmp_peek' _ "$TT" || rc=$?
expect "6a: peek on a missing dir fails" "1" "$rc"
if [ ! -e "$TMP/s6" ]; then pass "6b: peek did not create the dir"; else fail "6b: peek created the dir" "exists"; fi
expect "6c: peek resolves an existing dir" "$TMP/s1" "$(TICKET_TMP_DIR="$TMP/s1" bash -c 'source "$1"; ticket_tmp_peek && printf %s "$TICKET_TMP_RESOLVED"' _ "$TT")"

# ── 7. ticket-env.sh ─────────────────────────────────────────────────────────
S7="$TMP/s7"
mkdir -m 700 "$S7"
printf 'export REPOS_ROOT="/r7"\n' >"$S7/ticket-auto-T-7-env.sh"
chmod 600 "$S7/ticket-auto-T-7-env.sh"
expect "7a: trusted env file is sourced" "/r7" "$(TICKET_TMP_DIR="$S7" bash -c 'source "$1" T-7; printf %s "$REPOS_ROOT"' _ "$TENV")"
chmod 664 "$S7/ticket-auto-T-7-env.sh"
out=$(TICKET_TMP_DIR="$S7" bash -c 'source "$1" T-7; printf %s "${REPOS_ROOT:-unset}"' _ "$TENV" 2>"$TMP/t7.err")
expect "7b: group-writable env file is not sourced" "unset" "$out"
case "$(cat "$TMP/t7.err")" in
*"refusing untrusted env file"*) pass "7c: untrusted env file warns" ;;
*) fail "7c: untrusted env file warns" "stderr was '$(cat "$TMP/t7.err")'" ;;
esac
out=$(TICKET_TMP_DIR="$S7" bash -c 'set -e; source "$1" NOPE-1; echo after' _ "$TENV" 2>&1)
expect "7d: missing env file is silent and set -e survives" "after" "$out"
out=$(TICKET_TMP_DIR="$S7" bash -c 'set -e; source "$1" "../T-7"; echo "after:${REPOS_ROOT:-unset}"' _ "$TENV" 2>/dev/null)
expect "7e: bad id sources nothing, returns 0" "after:unset" "$out"
out=$(TICKET_TMP_DIR="$S7" bash -c 'set -e; f=$1; set --; source "$f"; echo after' _ "$TENV" 2>&1)
expect "7f: no id is a silent no-op" "after" "$out"

# ── 8. Hook ignores a non-pipeline-log LOG_FILE ──────────────────────────────
S8="$TMP/s8"
mkdir -m 700 "$S8" "$TMP/ws8"
cat >"$S8/ticket-auto-T-8-spawn-meta.txt" <<EOF
PHASE=IMPLEMENT
LOG_FILE=$TMP/ws8/not-a-log.txt
SESSION_ID=sess-t8
EOF
printf '{"session_id":"sess-t8","tool_name":"Bash"}\n' | TICKET_TMP_DIR="$S8" bash "$HOOK" >/dev/null 2>&1 || true
if [ -z "$(ls -A "$TMP/ws8")" ]; then pass "8a: nothing written next to a non-pipeline LOG_FILE"; else fail "8a: hook wrote" "$(ls -A "$TMP/ws8")"; fi
sed -i "s#not-a-log.txt#T-8-pipeline.log#" "$S8/ticket-auto-T-8-spawn-meta.txt"
printf '{"session_id":"sess-t8","tool_name":"Bash"}\n' | TICKET_TMP_DIR="$S8" bash "$HOOK" >/dev/null 2>&1 || true
if [ -s "$TMP/ws8/T-8-activity.log" ]; then pass "8b: a pipeline LOG_FILE is still honoured"; else fail "8b: activity log missing" "$(ls -A "$TMP/ws8")"; fi

echo ""
echo "ticket-tmp: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
