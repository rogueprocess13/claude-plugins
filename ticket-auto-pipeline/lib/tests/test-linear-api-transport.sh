#!/usr/bin/env bash
# test-linear-api-transport.sh — transport-level tests for lib/linear-api.sh:
# failure propagation from the getters (BE-3), curl timeouts (BE-8), API key
# kept out of argv (BE-9), no blind retry of create mutations (BE-10), and
# Linear rate-limit detection (BE-11).
#
# curl is replaced by a PATH shim (not a bash function) so the tests see the
# real argv and stdin linear-api.sh hands to the process — which is what an
# argv leak or a missing timeout flag is about. One test also runs the real
# curl against a local socket that accepts and never answers.
#
# Requires: bash, jq, curl, python3. No network.
# Usage: bash test-linear-api-transport.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="${LINEAR_API_LIB_UNDER_TEST:-$LIB_DIR/linear-api.sh}"

PASS=0
FAIL=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# _shim_setup — fresh shim dir; prints its path. The shim reads its
# per-call behaviour from plan.<n> (falling back to plan.default):
#   line 1: curl exit code, line 2: HTTP status, rest: body.
# It records argv (one arg per line) in argv.<n> and stdin in stdin.<n>.
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

# _plan <dir> <n|default> <curl_exit> <http_code> [body]
_plan() {
  printf '%s\n%s\n%s\n' "$3" "$4" "${5:-}" >"$1/plan.$2"
}

_calls() { cat "$1/count" 2>/dev/null || echo 0; }

# _lin <shimdir> <bash snippet> — run a snippet with linear-api.sh sourced,
# the shim first on PATH, zero retry delays, stdin closed.
_lin() {
  local d="$1"
  shift
  SHIM_DIR="$d" PATH="$d/bin:$PATH" LINEAR_API_KEY="lin_api_SECRET123" \
    LINEAR_API_URL="http://127.0.0.1:9/graphql" LINEAR_RETRY_DELAYS="0 0 0" \
    bash -c "source '$LIB'; $1" </dev/null
}

ISSUE_OK='{"data":{"issue":{"id":"i1","identifier":"T-1","title":"t","labels":{"nodes":[]}}}}'
COMMENT_OK='{"data":{"commentCreate":{"success":true,"comment":{"id":"c1","body":"hi"}}}}'
RATELIMITED='{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}'

# ── BE-3: getters propagate failure ──────────────────────────────────────────

test_get_comments_outage_fails_through_tracker_read() {
  local d out rc=0
  d=$(_shim_setup)
  _plan "$d" default 7 0
  out=$(_lin "$d" 'rc=0; out=$(tracker_read informational "" -- get_comments T-1) || rc=$?; echo "rc=$rc out=$out"') || true
  [ "$out" = "rc=1 out=" ]
}

test_get_comments_outage_direct_nonzero() {
  local d rc=0
  d=$(_shim_setup)
  _plan "$d" default 7 0
  _lin "$d" 'get_comments T-1' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
}

test_get_comments_null_issue_fails() {
  local d rc=0 out
  d=$(_shim_setup)
  _plan "$d" default 0 200 '{"data":{"issue":null}}'
  out=$(_lin "$d" 'get_comments T-1' 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ]
}

test_get_comments_empty_nodes_is_empty_array() {
  local d out
  d=$(_shim_setup)
  _plan "$d" default 0 200 '{"data":{"issue":{"comments":{"nodes":[]}}}}'
  out=$(_lin "$d" 'get_comments T-1')
  [ "$(echo "$out" | jq -c .)" = "[]" ]
}

test_get_issue_history_outage_fails_through_tracker_read() {
  local d out
  d=$(_shim_setup)
  _plan "$d" default 7 0
  out=$(_lin "$d" 'rc=0; out=$(tracker_read informational "" -- get_issue_history T-1) || rc=$?; echo "rc=$rc out=$out"') || true
  [ "$out" = "rc=1 out=" ]
}

# ── BE-8: timeouts ───────────────────────────────────────────────────────────

test_curl_gets_default_timeouts() {
  local d
  d=$(_shim_setup)
  _plan "$d" default 0 200 "$ISSUE_OK"
  _lin "$d" 'get_issue T-1' >/dev/null
  grep -qx -- '--connect-timeout' "$d/argv.1" &&
    grep -A1 -x -- '--connect-timeout' "$d/argv.1" | tail -1 | grep -qx 10 &&
    grep -A1 -x -- '--max-time' "$d/argv.1" | tail -1 | grep -qx 30
}

test_curl_timeouts_configurable() {
  local d
  d=$(_shim_setup)
  _plan "$d" default 0 200 "$ISSUE_OK"
  LINEAR_CONNECT_TIMEOUT=3 LINEAR_MAX_TIME=7 _lin "$d" 'get_issue T-1' >/dev/null
  grep -A1 -x -- '--connect-timeout' "$d/argv.1" | tail -1 | grep -qx 3 &&
    grep -A1 -x -- '--max-time' "$d/argv.1" | tail -1 | grep -qx 7
}

# Real curl against a socket that accepts but never answers: must give up
# within LINEAR_MAX_TIME per attempt instead of hanging forever.
test_black_hole_times_out() {
  command -v python3 >/dev/null || return 0
  local portfile="$TMP_ROOT/bh.port" pid rc=0 start end
  python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(16)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(60)
' "$portfile" &
  pid=$!
  for _ in $(seq 1 50); do
    [ -s "$portfile" ] && break
    sleep 0.1
  done
  start=$(date +%s)
  LINEAR_API_KEY=k LINEAR_API_URL="http://127.0.0.1:$(cat "$portfile")/graphql" \
  LINEAR_MAX_TIME=1 LINEAR_MAX_RETRIES=1 LINEAR_RETRY_DELAYS=0 \
    timeout 20 bash -c "source '$LIB'; get_issue T-1" </dev/null >/dev/null 2>&1 || rc=$?
  end=$(date +%s)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # 10 = linear_api failure; 124 would mean the outer timeout fired (hang).
  [ "$rc" -eq 10 ] && [ $((end - start)) -lt 15 ]
}

# ── BE-9: API key never in argv ──────────────────────────────────────────────

test_api_key_not_in_argv() {
  local d
  d=$(_shim_setup)
  _plan "$d" default 0 200 "$ISSUE_OK"
  _lin "$d" 'get_issue T-1' >/dev/null
  ! grep -q 'lin_api_SECRET123' "$d/argv.1" &&
    grep -qx 'Authorization: lin_api_SECRET123' "$d/stdin.1" &&
    grep -qx -- '@-' "$d/argv.1"
}

# ── BE-10: create mutations are not blindly retried ──────────────────────────

test_create_not_retried_after_timeout() {
  local d rc=0
  d=$(_shim_setup)
  _plan "$d" 1 28 0
  _plan "$d" default 0 200 "$COMMENT_OK"
  _lin "$d" 'save_comment i1 hi' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && [ "$(_calls "$d")" -eq 1 ]
}

test_create_not_retried_after_5xx() {
  local d rc=0
  d=$(_shim_setup)
  _plan "$d" 1 0 502 'bad gateway'
  _plan "$d" default 0 200 "$COMMENT_OK"
  _lin "$d" 'save_comment i1 hi' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && [ "$(_calls "$d")" -eq 1 ]
}

test_create_not_retried_after_connection_reset() {
  local d rc=0
  d=$(_shim_setup)
  _plan "$d" 1 56 0
  _plan "$d" default 0 200 "$COMMENT_OK"
  _lin "$d" 'save_comment i1 hi' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && [ "$(_calls "$d")" -eq 1 ]
}

test_create_retried_when_never_sent() {
  local d out
  d=$(_shim_setup)
  _plan "$d" 1 7 0
  _plan "$d" default 0 200 "$COMMENT_OK"
  out=$(_lin "$d" 'save_comment i1 hi')
  [ "$(echo "$out" | jq -r .id)" = "c1" ] && [ "$(_calls "$d")" -eq 2 ]
}

test_create_retried_when_rate_limited() {
  local d out
  d=$(_shim_setup)
  _plan "$d" 1 0 400 "$RATELIMITED"
  _plan "$d" default 0 200 "$COMMENT_OK"
  out=$(_lin "$d" 'save_comment i1 hi')
  [ "$(echo "$out" | jq -r .id)" = "c1" ] && [ "$(_calls "$d")" -eq 2 ]
}

test_read_still_retried_after_timeout() {
  local d out
  d=$(_shim_setup)
  _plan "$d" 1 28 0
  _plan "$d" default 0 200 "$ISSUE_OK"
  out=$(_lin "$d" 'get_issue T-1')
  [ "$(echo "$out" | jq -r .id)" = "i1" ] && [ "$(_calls "$d")" -eq 2 ]
}

test_non_idempotent_detection() {
  _lin "$TMP_ROOT" '
    _linear_payload_non_idempotent "{\"query\":\"mutation(\$input: CommentCreateInput!) { commentCreate(input: \$input) { success } }\"}" &&
    ! _linear_payload_non_idempotent "{\"query\":\"mutation(\$id: String!) { issueUpdate(id: \$id, input: {}) { success } }\"}" &&
    ! _linear_payload_non_idempotent "{\"query\":\"query { issueCreateable { id } }\"}" &&
    LINEAR_NON_IDEMPOTENT=1 _linear_payload_non_idempotent "{\"query\":\"query { viewer { id } }\"}"
  '
}

# ── BE-11: rate-limit detection ──────────────────────────────────────────────

test_classify_ratelimited_extension_code_on_400() {
  local r
  r=$(_lin "$TMP_ROOT" "_retry_classify 0 400 '$RATELIMITED'")
  [ "$r" = "transient" ]
}

test_classify_rate_limit_message_without_code() {
  local r
  r=$(_lin "$TMP_ROOT" "_retry_classify 0 200 '{\"errors\":[{\"message\":\"Rate limit exceeded\"}]}'")
  [ "$r" = "transient" ]
}

test_classify_other_graphql_error_still_permanent() {
  local r
  r=$(_lin "$TMP_ROOT" "_retry_classify 0 400 '{\"errors\":[{\"message\":\"Entity not found\",\"extensions\":{\"code\":\"INVALID_INPUT\"}}]}'")
  [ "$r" = "permanent" ]
}

test_read_retried_after_ratelimited() {
  local d out
  d=$(_shim_setup)
  _plan "$d" 1 0 400 "$RATELIMITED"
  _plan "$d" default 0 200 "$ISSUE_OK"
  out=$(_lin "$d" 'get_issue T-1')
  [ "$(echo "$out" | jq -r .id)" = "i1" ] && [ "$(_calls "$d")" -eq 2 ]
}

FILTER="${1:-}"
for fn in \
  test_get_comments_outage_fails_through_tracker_read \
  test_get_comments_outage_direct_nonzero \
  test_get_comments_null_issue_fails \
  test_get_comments_empty_nodes_is_empty_array \
  test_get_issue_history_outage_fails_through_tracker_read \
  test_curl_gets_default_timeouts \
  test_curl_timeouts_configurable \
  test_black_hole_times_out \
  test_api_key_not_in_argv \
  test_create_not_retried_after_timeout \
  test_create_not_retried_after_5xx \
  test_create_not_retried_after_connection_reset \
  test_create_retried_when_never_sent \
  test_create_retried_when_rate_limited \
  test_read_still_retried_after_timeout \
  test_non_idempotent_detection \
  test_classify_ratelimited_extension_code_on_400 \
  test_classify_rate_limit_message_without_code \
  test_classify_other_graphql_error_still_permanent \
  test_read_retried_after_ratelimited; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
