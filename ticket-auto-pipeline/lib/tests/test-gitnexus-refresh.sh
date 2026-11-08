#!/usr/bin/env bash
# test-gitnexus-refresh.sh — unit tests for lib/gitnexus-refresh.sh (GitHub
# #609: a stale GitNexus index was detected but never refreshed). The
# gitnexus CLI and gh are stubbed via PATH; real git repos stand in for the
# remote and the indexed clone.
# Usage: bash test-gitnexus-refresh.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GR="$LIB_DIR/gitnexus-refresh.sh"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

_ws=""
_old=""
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/bin" "$_ws/locks"
  : >"$_ws/gitnexus.calls"
  : >"$_ws/gh.calls"
  : >"$_ws/log"
  git init -q --bare -b main "$_ws/origin.git"
  git clone -q "$_ws/origin.git" "$_ws/seed" 2>/dev/null
  (cd "$_ws/seed" && git checkout -q -b main 2>/dev/null || true)
  echo one >"$_ws/seed/a.txt"
  mkdir -p "$_ws/seed/.gitnexus"
  echo idx >"$_ws/seed/.gitnexus/meta.json"
  git -C "$_ws/seed" add -A
  git -C "$_ws/seed" commit -q -m one
  git -C "$_ws/seed" push -q origin main 2>/dev/null
  git clone -q -b main "$_ws/origin.git" "$_ws/clone" 2>/dev/null
  _old=$(git -C "$_ws/clone" rev-parse HEAD)
  _write_registry "$_old"
  _stub_gitnexus 0
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

_write_registry() {
  cat >"$_ws/registry.json" <<EOF
[
  {"name": "other", "path": "/nonexistent", "lastCommit": "x", "remoteUrl": "git@github.com:acme/other.git"},
  {"name": "widget", "path": "$_ws/clone", "lastCommit": "$1", "remoteUrl": "git@github.com:Acme/Widget.git"}
]
EOF
}

# _stub_gitnexus <rc> [sleep_secs]
_stub_gitnexus() {
  cat >"$_ws/bin/gitnexus" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$_ws/gitnexus.calls"
[ -n "$2" ] && sleep "$2"
exit $1
EOF
  chmod +x "$_ws/bin/gitnexus"
}

_stub_gh() {
  cat >"$_ws/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$_ws/gh.calls"
case "\$1 \$2" in "pr view") echo "$1" ;; esac
exit 0
EOF
  chmod +x "$_ws/bin/gh"
}

# Push one new commit to origin/main.
_advance_origin() {
  echo "$1" >>"$_ws/seed/a.txt"
  git -C "$_ws/seed" commit -q -am "$1"
  git -C "$_ws/seed" push -q origin main 2>/dev/null
}

_rc=0
_gr() {
  _rc=0
  PATH="$_ws/bin:$PATH" GITNEXUS_REGISTRY="$_ws/registry.json" \
    GITNEXUS_REFRESH_LOCK_DIR="$_ws/locks" \
    bash "$GR" --env-file "$_ws/none.sh" "$@" CRE-1 "$_ws/log" >/dev/null 2>&1 || _rc=$?
}

_analyzed() { grep -q "^analyze --skip-agents-md $_ws/clone\$" "$_ws/gitnexus.calls"; }

test_refreshes_stale_index_after_merge() {
  _setup
  _advance_origin two
  local new
  new=$(git -C "$_ws/seed" rev-parse HEAD)
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && _analyzed &&
    [ "$(git -C "$_ws/clone" rev-parse HEAD)" = "$new" ] &&
    grep -q "|META|gitnexus-refresh|done|widget ${_old:0:7}→${new:0:7}\$" "$_ws/log" &&
    [ "$(wc -l <"$_ws/log")" = 1 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_up_to_date_skips_analyze() {
  _setup
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && ! _analyzed &&
    grep -q '|META|gitnexus-refresh|skip|widget: index already at' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_other_branch_never_switched() {
  _setup
  _advance_origin two
  git -C "$_ws/clone" checkout -q -b feature/x
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && ! _analyzed &&
    [ "$(git -C "$_ws/clone" symbolic-ref --short HEAD)" = feature/x ] &&
    [ "$(git -C "$_ws/clone" rev-parse HEAD)" = "$_old" ] &&
    grep -q '|skip|widget: clone is on feature/x, not main' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_detached_head_skipped() {
  _setup
  _advance_origin two
  git -C "$_ws/clone" checkout -q --detach
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && ! _analyzed && grep -q '|skip|widget: detached HEAD' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_dirty_clone_skipped() {
  _setup
  _advance_origin two
  echo local >>"$_ws/clone/a.txt"
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && ! _analyzed && [ "$(git -C "$_ws/clone" rev-parse HEAD)" = "$_old" ] &&
    grep -q '|skip|widget: dirty clone' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_tracked_gitnexus_dir_not_dirty_and_kept() {
  _setup
  _advance_origin two
  echo reindexed >"$_ws/clone/.gitnexus/meta.json"
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && _analyzed && [ "$(cat "$_ws/clone/.gitnexus/meta.json")" = reindexed ] &&
    grep -q '|META|gitnexus-refresh|done|' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_analyze_failure_warns_and_exits_zero() {
  _setup
  _advance_origin two
  _stub_gitnexus 3
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && _analyzed &&
    grep -q "|META|gitnexus-refresh|warn|widget: analyze exited 3 — run: gitnexus analyze $_ws/clone\$" "$_ws/log" &&
    [ "$(wc -l <"$_ws/log")" = 1 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_analyze_timeout_warns() {
  command -v timeout >/dev/null 2>&1 || return 0
  _setup
  _advance_origin two
  _stub_gitnexus 0 5
  GITNEXUS_REFRESH_TIMEOUT=1 _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && grep -q '|warn|widget: analyze timed out after 1s' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_concurrent_refresh_is_locked_out() {
  command -v flock >/dev/null 2>&1 || return 0
  _setup
  _advance_origin two
  local key lock
  key="$(printf '%s' "$_ws/clone" | cksum | cut -d' ' -f1)"
  lock="$_ws/locks/gitnexus-refresh-${key}.lock"
  local ok=1
  (
    flock -n 9 || exit 1
    _gr --repo acme/widget --base main
    [ "$_rc" = 0 ] && ! _analyzed &&
      grep -q '|skip|widget: another refresh of .* is running' "$_ws/log"
  ) 9>"$lock" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_repo_and_base_from_pipeline_log() {
  _setup
  _advance_origin two
  _stub_gh main
  echo '2026-11-01T00:00:00Z|META|pr-created|info|{"pr":42,"url":"https://github.com/acme/widget/pull/42","repo":"acme/widget"}' >"$_ws/log"
  _gr
  local ok=1
  [ "$_rc" = 0 ] && _analyzed &&
    grep -q '^pr view 42 --repo acme/widget --json baseRefName' "$_ws/gh.calls" &&
    grep -q '|META|gitnexus-refresh|done|widget ' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_no_pr_recorded_skips() {
  _setup
  _gr
  local ok=1
  [ "$_rc" = 0 ] && ! _analyzed &&
    grep -q '|META|gitnexus-refresh|skip|no PR repo recorded for CRE-1' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_unindexed_repo_skips() {
  _setup
  _gr --repo acme/nothing --base main
  local ok=1
  [ "$_rc" = 0 ] && ! _analyzed &&
    grep -q '|skip|acme/nothing: not indexed by GitNexus' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_usage_error() {
  local rc=0
  bash "$GR" only-one-arg >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

_run "refreshes stale index after merge" test_refreshes_stale_index_after_merge
_run "up-to-date index skips analyze" test_up_to_date_skips_analyze
_run "clone on another branch is never switched" test_other_branch_never_switched
_run "detached HEAD is skipped" test_detached_head_skipped
_run "dirty clone is skipped" test_dirty_clone_skipped
_run "tracked .gitnexus/ is not dirt and is kept" test_tracked_gitnexus_dir_not_dirty_and_kept
_run "analyze failure warns, exits 0" test_analyze_failure_warns_and_exits_zero
_run "analyze timeout warns" test_analyze_timeout_warns
_run "concurrent refresh is locked out" test_concurrent_refresh_is_locked_out
_run "repo and base come from the pipeline log" test_repo_and_base_from_pipeline_log
_run "no PR recorded skips" test_no_pr_recorded_skips
_run "unindexed repo skips" test_unindexed_repo_skips
_run "usage error exits 2" test_usage_error

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
