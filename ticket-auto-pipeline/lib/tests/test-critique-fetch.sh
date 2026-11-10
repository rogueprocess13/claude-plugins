#!/usr/bin/env bash
# test-critique-fetch.sh — lib/critique-fetch.sh (ticket-critique Input,
# skill-deterministic-extraction 6a).
#
# Parity oracle: the pre-extraction `--from-audit` fences (main @ 267c17f)
# embedded below, run in one shell against the same lib copy, whose
# linear-api.sh wraps the real file and fakes get_issue/get_comments. The
# fields the old fences left in shell variables are echoed so both sides can
# be compared. The scripts print the values shell-quoted; the oracle's are
# quoted the same way. Two old-fence bugs are not reproduced: linear-api.sh
# sets errexit at file scope, and `[.labels[]?.name]` fails on the real
# `.labels.nodes` payload, so the old fence died at LABELS. The oracle runs
# with `set +eo pipefail` after the sources and LABELS is checked on its own.
#
# Usage: bash test-critique-fetch.sh
set -eo pipefail

CF_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_LIB_DIR="$(cd "$CF_TEST_DIR/.." && pwd)"

unset LOG_FILE TAP_LOG HB_LOG_FILE LINEAR_API_KEY

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

WS=$(mktemp -d)
WS=$(cd "$WS" && pwd -P)
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/home/.claude/skills" "$WS/t"
cp -r "$CF_LIB_DIR" "$WS/lib"
mv "$WS/lib/linear-api.sh" "$WS/lib/linear-api-real.sh"
cat >"$WS/lib/linear-api.sh" <<'EOF'
source "$(dirname "${BASH_SOURCE[0]}")/linear-api-real.sh"
get_issue() {
  case "$FAKE_ISSUE" in
  fail) return 1 ;;
  null) echo 'null' ;;
  *) printf '%s\n' "$FAKE_ISSUE" ;;
  esac
}
get_comments() { printf '%s\n' "${FAKE_COMMENTS:-[]}"; }
EOF
ln -s "$WS/lib" "$WS/home/.claude/skills/lib"
export HOME="$WS/home" LINEAR_API_KEY=lin_test_key
printf '# Project\n\ntest users: alice / bob\nUAT_URL = https://uat.example\n' >"$WS/t/CLAUDE.md"

ISSUE='{"identifier":"T-1","title":"Add $(touch PWNED) export","description":"Do it.\n\n## Acceptance Criteria\n1. a\n2. b","labels":{"nodes":[{"name":"bug"},{"name":"ui"}]},"state":{"name":"Todo"}}'
COMMENTS='[{"body":"c1"},{"body":"c2"},{"body":"c3"},{"body":"c4"},{"body":"c5"},{"body":"c6"}]'

# ticket-critique `--from-audit` fences 1-3 and 5, main @ 267c17f
# ({TICKET_ID}=T-1), one shell, then the variables they left behind.
_old() {
  (cd "$WS/t" && bash -c '
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && cd ../../lib && pwd || echo "$HOME/.claude/skills/lib")"
source "$SCRIPT_DIR/linear-api.sh"
source "$SCRIPT_DIR/config.sh"
set +eo pipefail
ISSUE_JSON=$(get_issue "T-1") || {
  echo "ticket-critique: get_issue failed for T-1 — stopping" >&2
  exit 1
}
require_issue_payload "$ISSUE_JSON" || {
  echo "ticket-critique: get_issue returned an unreadable payload for T-1 — stopping" >&2
  exit 1
}
TITLE=$(echo "$ISSUE_JSON" | jq -r ".title")
DESCRIPTION=$(echo "$ISSUE_JSON" | jq -r ".description // \"\"")
LABELS=$(echo "$ISSUE_JSON" | jq -r "[.labels[]?.name] | join(\", \")")
STATE=$(echo "$ISSUE_JSON" | jq -r ".state.name")
COMMENTS_JSON=$(get_comments "T-1")
COMMENT_BODIES=$(echo "$COMMENTS_JSON" | jq -r ".[]?.body // \"\"" | head -5)
printf "TITLE=%q\nLABELS=%q\nSTATE=%q\n" "$TITLE" "$LABELS" "$STATE"
echo "=== DESCRIPTION ==="
echo "$DESCRIPTION"
echo "=== COMMENTS ==="
echo "$COMMENT_BODIES"
echo "=== CLAUDE.md ==="
grep -A5 "test users\|UAT_URL\|LOCAL_URL" CLAUDE.md 2>/dev/null || true
')
}
_new() { (cd "$WS/t" && bash "$WS/lib/critique-fetch.sh" T-1 --from-audit "$@"); }

echo "=== --from-audit: parity ==="
export FAKE_ISSUE="$ISSUE" FAKE_COMMENTS="$COMMENTS"
orc=0 nrc=0
old=$(_old 2>/dev/null) || orc=$?
new=$(_new 2>/dev/null) || nrc=$?
_same "issue: output (LABELS aside)" "$(grep -v '^LABELS=' <<<"$old")" "$(grep -v '^LABELS=' <<<"$new")"
grep -qxF 'LABELS=bug\,\ ui' <<<"$new" && _ok "LABELS read from .labels.nodes" || _ko "LABELS: $(grep LABELS <<<"$new")"
_same "issue: exit" "$orc" "$nrc"
[ ! -e "$WS/t/PWNED" ] && _ok "hostile title is data, never run" || _ko "title was executed"
eval "$(grep '^TITLE=' <<<"$new")"
_same "TITLE evals back verbatim" 'Add $(touch PWNED) export' "$TITLE"
for c in fail null; do
  export FAKE_ISSUE="$c"
  orc=0 nrc=0
  old=$(_old 2>&1 | grep -v '^bash: line 2: cd: ') || orc=${PIPESTATUS[0]}
  new=$(_new 2>&1) || nrc=$?
  _same "$c fetch: stderr" "$old" "$new"
  _same "$c fetch: exit 1" "1 1" "$orc $nrc"
done

export FAKE_ISSUE="$ISSUE"
out=$(_new --source-marker "AUD-1:T-1:needs-info")
grep -qx 'SOURCE_MARKER=AUD-1:T-1:needs-info' <<<"$out" && _ok "--source-marker is carried" || _ko "marker: $out"

echo "=== workspace modes ==="
mkdir -p "$WS/t/tickets/T-1--x"
out=$(cd "$WS/t" && bash "$WS/lib/critique-fetch.sh" T-1 --workspace)
_same "workspace: found" "TICKET_DIR=./tickets/T-1--x" "$out"
rc=0
(cd "$WS/t" && bash "$WS/lib/critique-fetch.sh" T-9 --workspace >/dev/null 2>&1) || rc=$?
_same "workspace: missing exits 3" 3 "$rc"
rc=0
bash "$WS/lib/critique-fetch.sh" T-1 >/dev/null 2>&1 || rc=$?
_same "usage exits 2" 2 "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
