#!/usr/bin/env bash
# test-planner-linear-transport.sh — transport tests for planner_linear_graphql:
# curl timeouts, API key kept out of argv, no blind retry of create
# mutations, and Linear rate-limit detection. Mirrors
# ticket-auto-pipeline/lib/tests/test-linear-api-transport.sh.
#
# curl is a PATH shim recording argv/stdin and replaying a per-call plan.
# No network, no token.
#
# Run: bash ticket-planner/lib/tests/test-planner-linear-transport.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${PLANNER_LINEAR_LIB_UNDER_TEST:-${SCRIPT_DIR}/../planner-linear-api.sh}"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1${2:+: $2}"
  FAIL=$((FAIL + 1))
}
check() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then pass "$name"; else fail "$name"; fi
}

_shim_setup() {
  local d
  d=$(mktemp -d "$TMP_ROOT/shim.XXXXXX")
  mkdir -p "$d/bin"
  cat >"$d/bin/curl" <<'SHIM'
#!/usr/bin/env bash
d="$SHIM_DIR"
n=$(($(cat "$d/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/count"
printf '%s\n' "$@" >"$d/argv.$n"
cat >"$d/stdin.$n"
plan="$d/plan.$n"
[ -f "$plan" ] || plan="$d/plan.default"
rc=$(sed -n 1p "$plan")
code=$(sed -n 2p "$plan")
body=$(sed -n '3,$p' "$plan")
if [ "$rc" -ne 0 ]; then
  printf '\n000'
  exit "$rc"
fi
printf '%s\n%s' "$body" "$code"
SHIM
  chmod +x "$d/bin/curl"
  echo "$d"
}
_plan() { printf '%s\n%s\n%s\n' "$3" "$4" "${5:-}" >"$1/plan.$2"; }
_calls() { cat "$1/count" 2>/dev/null || echo 0; }

# _gql <shimdir> <payload> — run planner_linear_graphql under the shim.
_gql() {
  SHIM_DIR="$1" PATH="$1/bin:$PATH" LINEAR_API_KEY="lin_api_SECRET123" \
    LINEAR_API_URL="http://127.0.0.1:9/graphql" LINEAR_RETRY_DELAYS="0 0 0" \
    bash -c "source '$LIB'; planner_linear_graphql \"\$1\"" _ "$2" </dev/null
}

READ='{"query":"query { viewer { id } }"}'
CREATE='{"query":"mutation CreateIssue($input: IssueCreateInput!) { issueCreate(input: $input) { success } }","variables":{"input":{}}}'
OK_READ='{"data":{"viewer":{"id":"u1"}}}'
OK_CREATE='{"data":{"issueCreate":{"success":true}}}'
RATELIMITED='{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}'

echo "=== planner-linear-api.sh transport tests ==="

t_timeouts() {
  local d
  d=$(_shim_setup)
  _plan "$d" default 0 200 "$OK_READ"
  _gql "$d" "$READ" >/dev/null
  grep -A1 -x -- '--connect-timeout' "$d/argv.1" | tail -1 | grep -qx 10 &&
    grep -A1 -x -- '--max-time' "$d/argv.1" | tail -1 | grep -qx 30
}
check "curl carries default connect/max-time timeouts" t_timeouts

t_key_not_in_argv() {
  local d
  d=$(_shim_setup)
  _plan "$d" default 0 200 "$OK_READ"
  _gql "$d" "$READ" >/dev/null
  ! grep -q 'lin_api_SECRET123' "$d/argv.1" &&
    grep -qx 'Authorization: lin_api_SECRET123' "$d/stdin.1"
}
check "API key travels on stdin, never argv" t_key_not_in_argv

t_create_timeout_not_retried() {
  local d rc=0
  d=$(_shim_setup)
  _plan "$d" 1 28 0
  _plan "$d" default 0 200 "$OK_CREATE"
  _gql "$d" "$CREATE" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && [ "$(_calls "$d")" -eq 1 ]
}
check "issueCreate is not resent after a timeout" t_create_timeout_not_retried

t_create_5xx_not_retried() {
  local d rc=0
  d=$(_shim_setup)
  _plan "$d" 1 0 503 'unavailable'
  _plan "$d" default 0 200 "$OK_CREATE"
  _gql "$d" "$CREATE" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && [ "$(_calls "$d")" -eq 1 ]
}
check "issueCreate is not resent after a 5xx" t_create_5xx_not_retried

t_create_connect_fail_retried() {
  local d
  d=$(_shim_setup)
  _plan "$d" 1 7 0
  _plan "$d" default 0 200 "$OK_CREATE"
  _gql "$d" "$CREATE" >/dev/null 2>&1 && [ "$(_calls "$d")" -eq 2 ]
}
check "issueCreate is retried when the connection was refused" t_create_connect_fail_retried

t_create_ratelimited_retried() {
  local d
  d=$(_shim_setup)
  _plan "$d" 1 0 400 "$RATELIMITED"
  _plan "$d" default 0 200 "$OK_CREATE"
  _gql "$d" "$CREATE" >/dev/null 2>&1 && [ "$(_calls "$d")" -eq 2 ]
}
check "issueCreate is retried after a RATELIMITED rejection" t_create_ratelimited_retried

t_read_ratelimited_retried() {
  local d
  d=$(_shim_setup)
  _plan "$d" 1 0 400 "$RATELIMITED"
  _plan "$d" default 0 200 "$OK_READ"
  _gql "$d" "$READ" >/dev/null 2>&1 && [ "$(_calls "$d")" -eq 2 ]
}
check "a read is retried after a RATELIMITED rejection" t_read_ratelimited_retried

t_classify_message() {
  local r
  r=$(bash -c "source '$LIB'; _planner_retry_classify 0 200 '{\"errors\":[{\"message\":\"Rate limit exceeded\"}]}'")
  [ "$r" = "transient" ]
}
check "\"Rate limit exceeded\" classifies transient" t_classify_message

echo ""
echo "=== planner-linear-api.sh transport: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
