#!/usr/bin/env bash
# test-verify-record-verdict.sh — verify_record_verdict (lib/verifier-result.sh),
# the one call behind ticket-verify's six verdict write sites
# (skill-deterministic-extraction 4).
#
# fixtures/verify-verdict/<verifier>-<VERDICT>.out were produced by running
# the six pre-extraction `write_verifier_result verifier=<id> ...` lines of
# ticket-verify SKILL.md (main @ eacacbf) with <N>/<M>/<A> = 3/3/1 (PASS) and
# 2/3/2 (FAIL) — never by the wrapper. Timestamps are masked to TS.
set -eo pipefail

VV_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VV_LIB_DIR="$(cd "$VV_TEST_DIR/.." && pwd)"
VV_FX="$VV_TEST_DIR/fixtures/verify-verdict"
unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE

PASS=0 FAIL=0
_ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_ko() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

WS=$(mktemp -d)
trap 'rm -rf "$WS"' EXIT
_mask() { sed 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }

# Runs in a fresh bash, as a SKILL.md fence does.
_rec() { # log mode verdict met total attempt
  local log="$1"
  shift
  TAP_LOG="$log" bash -c 'source "$0/verifier-result.sh" && verify_record_verdict "$@"' "$VV_LIB_DIR" "$@"
}

echo "=== parity with the six inline write sites ==="
for pair in browser:playwright_uat build-only:build_only live-backend:live_backend; do
  mode=${pair%%:*} id=${pair##*:}
  for v in PASS FAIL; do
    log="$WS/$id-$v.log"
    : >"$log"
    if [ "$v" = PASS ]; then _rec "$log" "$mode" PASS 3 3 1; else _rec "$log" "$mode" FAIL 2 3 2; fi
    got=$(_mask <"$log")
    want=$(cat "$VV_FX/$id-$v.out")
    [ "$got" = "$want" ] && _ok "$mode $v -> $id" || _ko "$mode $v: want $want got $got"
  done
done

echo "=== refusals ==="
log="$WS/refuse.log"
: >"$log"
rc=0
_rec "$log" "{VERIFY_MODE}" PASS 3 3 1 2>/dev/null || rc=$?
[ "$rc" = 2 ] && [ ! -s "$log" ] && _ok "unfilled mode placeholder -> exit 2, nothing written" || _ko "unknown mode rc=$rc"
rc=0
_rec "$log" browser WARN 3 3 1 2>/dev/null || rc=$?
[ "$rc" = 2 ] && [ ! -s "$log" ] && _ok "verdict other than PASS/FAIL -> exit 2, nothing written" || _ko "bad verdict rc=$rc"

echo "=== the verdict gate reads what the wrapper writes ==="
log="$WS/gate.log"
: >"$log"
_rec "$log" build-only FAIL 1 2 1
latest=$(bash -c 'source "$0/verifier-result.sh" && verifier_latest_verdict "$1"' "$VV_LIB_DIR" "$log")
[ "$latest" = "build_only|VERIFY|FAIL" ] && _ok "a recorded FAIL is a trailing FAIL for the gate" || _ko "gate saw '$latest'"
_rec "$log" build-only PASS 2 2 2
latest=$(bash -c 'source "$0/verifier-result.sh" && verifier_latest_verdict "$1"' "$VV_LIB_DIR" "$log")
[ -z "$latest" ] && _ok "a later PASS clears it" || _ko "gate still saw '$latest'"

echo ""
echo "verify-record-verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
