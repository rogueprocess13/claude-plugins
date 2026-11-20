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

unset LOG_FILE TAP_LOG HB_LOG_FILE LINEAR_API_KEY REPOS_ROOT

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
_same "issue: output (LABELS, TICKET_TYPE aside)" "$(grep -v '^LABELS=' <<<"$old")" "$(grep -v '^LABELS=\|^TICKET_TYPE=' <<<"$new")"
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
_same "workspace: found" "TICKET_DIR=./tickets/T-1--x" "$(grep '^TICKET_DIR=' <<<"$out")"
rc=0
(cd "$WS/t" && bash "$WS/lib/critique-fetch.sh" T-9 --workspace >/dev/null 2>&1) || rc=$?
_same "workspace: missing exits 3" 3 "$rc"
rc=0
bash "$WS/lib/critique-fetch.sh" T-1 >/dev/null 2>&1 || rc=$?
_same "usage exits 2" 2 "$rc"

echo "=== TICKET_TYPE: manifest type, else a whole bug label (#677) ==="
RR="$WS/repos"
_manifest() { # <TID> <manifest json>
  mkdir -p "$RR/.ticket-auto/initiatives/_index" "$RR/.ticket-auto/initiatives/INIT-7/tickets/$1/planner"
  echo "INIT-7" >"$RR/.ticket-auto/initiatives/_index/$1.initiative"
  echo "$2" >"$RR/.ticket-auto/initiatives/INIT-7/tickets/$1/planner/manifest.json"
}
_issue() { # <TID> <labels json array>
  printf '{"identifier":"%s","title":"t","description":"d","labels":{"nodes":%s},"state":{"name":"Todo"}}' "$1" "$2"
}
_type() { # <TID> <labels json array> → the TICKET_TYPE line of --from-audit
  (cd "$WS/t" && FAKE_ISSUE="$(_issue "$1" "$2")" REPOS_ROOT="$RR" bash "$WS/lib/critique-fetch.sh" "$1" --from-audit 2>/dev/null) |
    grep '^TICKET_TYPE=' || true
}
_manifest P-1 '{"type":"bug"}'
_manifest P-2 '{"type":"feature"}'
_manifest P-3 '{"type":null}'
_manifest P-4 '{"type":"hotfix"}'
_same "planned bug, no label → bug checks" "TICKET_TYPE=bug" "$(_type P-1 '[]')"
_same "planned feature, no label → feature checks" "TICKET_TYPE=feature" "$(_type P-2 '[]')"
_same "labelled ad-hoc bug, no manifest → bug checks" "TICKET_TYPE=bug" "$(_type A-1 '[{"name":"ui"},{"name":"Bug"}]')"
_same "ad-hoc, no bug label → feature checks" "TICKET_TYPE=feature" "$(_type A-2 '[{"name":"debugging"},{"name":"bugfix"}]')"
_same "manifest type wins over a bug label" "TICKET_TYPE=feature" "$(_type P-2 '[{"name":"bug"}]')"
_same "null manifest type falls back to the label" "TICKET_TYPE=bug" "$(_type P-3 '[{"name":"bug"}]')"
_same "unknown manifest type is dropped" "TICKET_TYPE=feature" "$(_type P-4 '[]')"
_same "no REPOS_ROOT: label only" "TICKET_TYPE=feature" \
  "$(cd "$WS/t" && FAKE_ISSUE="$(_issue P-1 '[]')" bash "$WS/lib/critique-fetch.sh" P-1 --from-audit 2>/dev/null | grep '^TICKET_TYPE=')"
mkdir -p "$WS/t2"
printf 'REPOS_ROOT = `%s`\n' "$RR" >"$WS/t2/CLAUDE.md"
_same "REPOS_ROOT read from ./CLAUDE.md" "TICKET_TYPE=bug" \
  "$(cd "$WS/t2" && FAKE_ISSUE="$(_issue P-1 '[]')" bash "$WS/lib/critique-fetch.sh" P-1 --from-audit 2>/dev/null | grep '^TICKET_TYPE=')"

mkdir -p "$WS/t/tickets/P-1--planned-bug" "$WS/t/tickets/A-3--labelled" "$WS/t/tickets/A-4--plain"
printf '# P-1\n\n**Labels:** \n' >"$WS/t/tickets/P-1--planned-bug/context.md"
printf '# A-3\n\n**Labels:** backend, bug\n' >"$WS/t/tickets/A-3--labelled/context.md"
printf '# A-4\n\n**Labels:** backend\n\nThe bug label is absent.\n' >"$WS/t/tickets/A-4--plain/context.md"
_ws_type() { (cd "$WS/t" && REPOS_ROOT="$RR" bash "$WS/lib/critique-fetch.sh" "$1" "$2" 2>/dev/null) | grep '^TICKET_TYPE=' || true; }
_same "workspace: planned bug, no label" "TICKET_TYPE=bug" "$(_ws_type P-1 --workspace)"
_same "from-appraise: planned bug, no label" "TICKET_TYPE=bug" "$(_ws_type P-1 --from-appraise)"
_same "workspace: context.md bug label" "TICKET_TYPE=bug" "$(_ws_type A-3 --workspace)"
_same "workspace: no manifest, no bug label" "TICKET_TYPE=feature" "$(_ws_type A-4 --workspace)"

echo "=== SKILL.md branches Checks 5/6 on TICKET_TYPE ==="
SKILL="$CF_LIB_DIR/../skills/ticket-critique/SKILL.md"
_c5=$(awk '/^### Check 5 /{f=1;next} f&&/^### /{exit} f' "$SKILL")
_c6=$(awk '/^### Check 6 /{f=1;next} f&&/^\*\*6a\./{exit} f' "$SKILL")
grep -q '^If `TICKET_TYPE=bug`' <<<"$_c5" && _ok "Check 5 runs on TICKET_TYPE=bug" || _ko "Check 5 does not branch on TICKET_TYPE"
grep -q '`TICKET_TYPE` is not `bug`' <<<"$_c6" && _ok "Check 6 runs when TICKET_TYPE is not bug" || _ko "Check 6 does not branch on TICKET_TYPE"
grep -q '`bug` label' <<<"$_c5$_c6" && _ko "Checks 5/6 still read the bug label" || _ok "Checks 5/6 do not read the bug label"
_n=$(grep -c 'critique-fetch.sh {TICKET-ID} --\(from-audit\|workspace\)' "$SKILL")
[ "$_n" -ge 2 ] && grep -q 'prints `TICKET_DIR`, `TICKET_TYPE`' "$SKILL" && grep -q '`STATE`, `TICKET_TYPE`' "$SKILL" &&
  _ok "every input mode gets TICKET_TYPE from critique-fetch.sh" || _ko "an input mode does not load TICKET_TYPE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
