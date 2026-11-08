#!/usr/bin/env bash
# test-gitnexus-refresh.sh — unit tests for lib/gitnexus-refresh.sh (GitHub
# #609: a stale GitNexus index was detected but never refreshed). The
# gitnexus CLI and gh are stubbed via PATH; real git repos stand in for the
# remote, the user's own clone and the pipeline-owned detached index
# worktrees under .ticket-auto/worktrees/gitnexus/.
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
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/bin" "$_ws/home" "$_ws/repos"
  : >"$_ws/gitnexus.calls"
  : >"$_ws/gh.calls"
  : >"$_ws/log"
  echo '[]' >"$_ws/registry.json"
  _stub_gitnexus 0 0
  _stub_gh_fail
}
_teardown() {
  # Let any detached analyze worker finish before removing its files.
  local i
  for i in $(seq 1 50); do
    pgrep -f -- "--analyze-worker .*$_ws" >/dev/null 2>&1 || break
    sleep 0.1
  done
  rm -rf "$_ws" 2>/dev/null || true
}

# _repo <name> — a bare origin with main and epic/x, plus the user's clone at
# $_ws/repos/<name> (on main). Prints nothing.
_repo() {
  local n="$1" seed="$_ws/seed-$1"
  git init -q --bare -b main "$_ws/$n.git"
  git clone -q "$_ws/$n.git" "$seed" 2>/dev/null
  git -C "$seed" checkout -q -B main
  echo one >"$seed/a.txt"
  mkdir -p "$seed/.gitnexus"
  echo tracked >"$seed/.gitnexus/meta.json"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m one
  git -C "$seed" push -q origin main 2>/dev/null
  git -C "$seed" push -q origin main:epic/x 2>/dev/null
  git clone -q -b main "$_ws/$n.git" "$_ws/repos/$n" 2>/dev/null
}

# _owned <name> — the pipeline-owned detached index worktree for <name>.
_owned_path() { echo "$_ws/repos/.ticket-auto/worktrees/gitnexus/$1"; }
_owned() {
  local p
  p=$(_owned_path "$1")
  mkdir -p "$(dirname "$p")"
  git -C "$_ws/repos/$1" worktree add -q --detach "$p" HEAD 2>/dev/null
  echo old-db >"$p/.gitnexus/lbug"
}

# _advance <name> <branch> <msg> — push one commit to origin/<branch>.
_advance() {
  local seed="$_ws/seed-$1"
  git -C "$seed" fetch -q origin
  git -C "$seed" checkout -q -B "$2" "origin/$2"
  echo "$3" >>"$seed/a.txt"
  git -C "$seed" commit -q -am "$3"
  git -C "$seed" push -q origin "$2" 2>/dev/null
}
_tip() { git -C "$_ws/$1.git" rev-parse "$2"; }

# _register <name> <path> <slug> — add a registry entry indexed at the
# path's current HEAD.
_register() {
  local head
  head=$(git -C "$2" rev-parse HEAD)
  jq --arg n "$1" --arg p "$2" --arg c "$head" --arg u "git@github.com:$3.git" \
    '. + [{name: $n, path: $p, lastCommit: $c, remoteUrl: $u}]' \
    "$_ws/registry.json" >"$_ws/registry.tmp" && mv "$_ws/registry.tmp" "$_ws/registry.json"
}

_pr_created() {
  echo "2026-11-01T00:00:0${3:-0}Z|META|pr-created|info|{\"pr\":$2,\"url\":\"https://github.com/$1/pull/$2\",\"repo\":\"$1\"}" >>"$_ws/log"
}

# _stub_gitnexus <rc> <sleep_secs> — records its args; on failure it first
# clobbers the database, as gitnexus 1.6.4 deletes lbug* before rebuilding.
_stub_gitnexus() {
  cat >"$_ws/bin/gitnexus" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$_ws/gitnexus.calls"
p="\${!#}"
rm -f "\$p"/.gitnexus/lbug*
echo partial >"\$p/.gitnexus/lbug"
sleep $2
[ $1 = 0 ] && echo new-db >"\$p/.gitnexus/lbug"
exit $1
EOF
  chmod +x "$_ws/bin/gitnexus"
}

_stub_gh_fail() {
  printf '#!/usr/bin/env bash\necho "$*" >>"%s/gh.calls"\nexit 1\n' "$_ws" >"$_ws/bin/gh"
  chmod +x "$_ws/bin/gh"
}

# _stub_gh_bases <pr>=<base>... — `gh pr view <pr>` prints that base.
_stub_gh_bases() {
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"\$*\" >>\"$_ws/gh.calls\""
    echo 'case "$3" in'
    local kv
    for kv in "$@"; do echo "${kv%%=*}) echo ${kv#*=} ;;"; done
    echo '*) exit 1 ;;'
    echo 'esac'
  } >"$_ws/bin/gh"
  chmod +x "$_ws/bin/gh"
}

_rc=0
_gr() {
  _rc=0
  HOME="$_ws/home" PATH="$_ws/bin:$PATH" GITNEXUS_REGISTRY="$_ws/registry.json" \
    bash "$GR" "$@" CRE-1 "$_ws/log" >/dev/null 2>&1 || _rc=$?
}

_alog() { echo "$_ws/home/.gitnexus/refresh-logs/$1.log"; }
# _wait_result <name> — wait for the detached worker's result line.
_wait_result() {
  local i
  for i in $(seq 1 100); do
    grep -qE '\|gitnexus-refresh\|(done|fail)\|' "$(_alog "$1")" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}
_analyzed() { grep -q "^analyze --skip-agents-md $1\$" "$_ws/gitnexus.calls"; }

test_multi_pr_each_repo_refreshed_on_its_own_base() {
  _setup
  _repo widget
  _repo gadget
  _owned widget
  _owned gadget
  _register widget "$(_owned_path widget)" acme/widget
  _register gadget "$(_owned_path gadget)" acme/gadget
  _advance widget epic/x w2
  _advance gadget main g2
  _stub_gh_bases 11=epic/x 12=main
  _pr_created acme/widget 11 1
  _pr_created acme/gadget 12 2
  _gr
  local ok=1
  _wait_result widget && _wait_result gadget || ok=0
  [ "$_rc" = 0 ] && _analyzed "$(_owned_path widget)" && _analyzed "$(_owned_path gadget)" &&
    [ "$(git -C "$(_owned_path widget)" rev-parse HEAD)" = "$(_tip widget epic/x)" ] &&
    [ "$(git -C "$(_owned_path gadget)" rev-parse HEAD)" = "$(_tip gadget main)" ] &&
    [ "$(grep -c '|META|gitnexus-refresh|start|' "$_ws/log")" = 2 ] &&
    ! grep -q '|gitnexus-refresh|done|' "$_ws/log" &&
    grep -q '|gitnexus-refresh|done|widget ' "$(_alog widget)" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_detached_worktree_follows_epic_base_from_branch_context() {
  _setup
  _repo widget
  _owned widget
  _register widget "$(_owned_path widget)" acme/widget
  _advance widget epic/x w2
  echo '2026-11-01T00:00:00Z|META|branch-context|info|base=epic/x;integration=epic/x;source=epic-directive;ticket=feat/CRE-1;uat-policy=epic;merge-policy=manual' >>"$_ws/log"
  _pr_created acme/widget 11
  local main_before
  main_before=$(git -C "$_ws/repos/widget" rev-parse main)
  _gr
  local ok=1 p
  p=$(_owned_path widget)
  _wait_result widget || ok=0
  [ "$_rc" = 0 ] && _analyzed "$p" &&
    [ "$(git -C "$p" rev-parse HEAD)" = "$(_tip widget epic/x)" ] &&
    ! git -C "$p" symbolic-ref -q HEAD >/dev/null &&
    [ "$(git -C "$_ws/repos/widget" rev-parse main)" = "$main_before" ] &&
    [ "$(git -C "$_ws/repos/widget" symbolic-ref --short HEAD)" = main ] &&
    [ "$(cat "$p/.gitnexus/lbug")" = new-db ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_user_checkout_is_warn_only_and_untouched() {
  _setup
  _repo widget
  local u="$_ws/repos/widget" head status
  _register widget "$u" acme/widget
  _advance widget main w2
  git -C "$u" fetch -q origin
  head=$(git -C "$u" rev-parse HEAD)
  status=$(git -C "$u" status --porcelain)
  _pr_created acme/widget 11
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/gitnexus.calls" ] &&
    [ "$(git -C "$u" rev-parse HEAD)" = "$head" ] &&
    [ "$(git -C "$u" status --porcelain)" = "$status" ] &&
    grep -qF "|META|gitnexus-stale|warn|widget: index of user clone $u is not at origin/main, not refreshed automatically — run: git -C $u pull && gitnexus analyze $u" "$_ws/log" &&
    [ "$(wc -l <"$_ws/log")" = 2 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_analyze_failure_restores_previous_index() {
  _setup
  _repo widget
  _owned widget
  local p
  p=$(_owned_path widget)
  _register widget "$p" acme/widget
  _advance widget main w2
  _stub_gitnexus 3 0
  _gr --repo acme/widget --base main
  local ok=1
  _wait_result widget || ok=0
  [ "$_rc" = 0 ] && _analyzed "$p" && [ "$(cat "$p/.gitnexus/lbug")" = old-db ] &&
    [ ! -e "$p/.gitnexus/.refresh-backup" ] &&
    grep -q '|gitnexus-refresh|fail|widget: analyze exited 3; previous index restored' "$(_alog widget)" &&
    ! grep -q '|fail|' "$_ws/log" && grep -q '|META|gitnexus-refresh|start|widget ' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_router_step_returns_before_analyze_ends() {
  _setup
  _repo widget
  _owned widget
  _register widget "$(_owned_path widget)" acme/widget
  _advance widget main w2
  _stub_gitnexus 0 4
  local t0 t1 ok=1
  t0=$(date +%s)
  _gr --repo acme/widget --base main
  t1=$(date +%s)
  [ $((t1 - t0)) -lt 3 ] && grep -q '|start|widget ' "$_ws/log" || ok=0
  # While analyze runs it holds the lock: a second run is turned away.
  _gr --repo acme/widget --base main
  grep -q '|skip|widget: a refresh of .* is already running' "$_ws/log" || ok=0
  [ "$(grep -c '^analyze' "$_ws/gitnexus.calls")" = 1 ] || ok=0
  _wait_result widget || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_symlinked_lock_refused() {
  _setup
  _repo widget
  _owned widget
  local p key
  p=$(_owned_path widget)
  _register widget "$p" acme/widget
  _advance widget main w2
  mkdir -p -m 700 "$_ws/home/.gitnexus/locks"
  key=$(printf '%s' "$p" | cksum | cut -d' ' -f1)
  ln -s "$_ws/victim" "$_ws/home/.gitnexus/locks/${key}.lock"
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/gitnexus.calls" ] && [ ! -e "$_ws/victim" ] &&
    grep -q '|warn|widget: refusing lock .* (not a regular file)' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_symlinked_lock_dir_refused() {
  _setup
  _repo widget
  _owned widget
  _register widget "$(_owned_path widget)" acme/widget
  _advance widget main w2
  mkdir -p "$_ws/home/.gitnexus" "$_ws/elsewhere"
  ln -s "$_ws/elsewhere" "$_ws/home/.gitnexus/locks"
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/gitnexus.calls" ] && [ -z "$(ls -A "$_ws/elsewhere")" ] &&
    grep -q '|warn|widget: lock dir ~/.gitnexus/locks is unsafe' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_up_to_date_skips_analyze() {
  _setup
  _repo widget
  _owned widget
  _register widget "$(_owned_path widget)" acme/widget
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/gitnexus.calls" ] &&
    grep -q '|skip|widget: index already at' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_dirty_index_worktree_untouched() {
  _setup
  _repo widget
  _owned widget
  local p head
  p=$(_owned_path widget)
  _register widget "$p" acme/widget
  _advance widget main w2
  echo local >>"$p/a.txt"
  head=$(git -C "$p" rev-parse HEAD)
  _gr --repo acme/widget --base main
  local ok=1
  [ "$_rc" = 0 ] && [ ! -s "$_ws/gitnexus.calls" ] && [ "$(git -C "$p" rev-parse HEAD)" = "$head" ] &&
    grep -q '|warn|widget: index worktree .* has local changes' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_tracked_gitnexus_dir_not_dirt() {
  _setup
  _repo widget
  _owned widget
  local p
  p=$(_owned_path widget)
  _register widget "$p" acme/widget
  _advance widget main w2
  echo reindexed >"$p/.gitnexus/meta.json"
  _gr --repo acme/widget --base main
  local ok=1
  _wait_result widget || ok=0
  [ "$_rc" = 0 ] && _analyzed "$p" && [ "$(cat "$p/.gitnexus/meta.json")" = reindexed ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_hostile_tmp_env_file_ignored() {
  _setup
  _repo widget
  _owned widget
  _register widget "$(_owned_path widget)" acme/widget
  local tid="GRTEST$$" env
  env="/tmp/ticket-auto-${tid}-env.sh"
  # shellcheck disable=SC2016
  printf 'export BASE_BRANCH="$(touch %s/marker)main"\n' "$_ws" >"$env"
  _pr_created acme/widget 11
  local rc=0
  HOME="$_ws/home" PATH="$_ws/bin:$PATH" GITNEXUS_REGISTRY="$_ws/registry.json" \
    bash "$GR" "$tid" "$_ws/log" >/dev/null 2>&1 || rc=$?
  rm -f "$env"
  local ok=1
  [ "$rc" = 0 ] && [ ! -e "$_ws/marker" ] && [ ! -s "$_ws/gitnexus.calls" ] &&
    grep -q '|skip|acme/widget: base branch unknown or invalid' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_no_pr_recorded_skips() {
  _setup
  _gr
  local ok=1
  [ "$_rc" = 0 ] && grep -q '|META|gitnexus-refresh|skip|no PR repo recorded for CRE-1' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_unindexed_repo_skips() {
  _setup
  _gr --repo acme/nothing --base main
  local ok=1
  [ "$_rc" = 0 ] && grep -q '|skip|acme/nothing: not indexed by GitNexus' "$_ws/log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_usage_error() {
  local rc=0
  bash "$GR" only-one-arg >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ]
}

_run "multi-PR log: each repo refreshed on its own base" test_multi_pr_each_repo_refreshed_on_its_own_base
_run "detached index worktree follows the epic base (branch-context)" test_detached_worktree_follows_epic_base_from_branch_context
_run "user checkout: warn only, never modified" test_user_checkout_is_warn_only_and_untouched
_run "analyze failure restores the previous index" test_analyze_failure_restores_previous_index
_run "router step returns before analyze ends; lock held meanwhile" test_router_step_returns_before_analyze_ends
_run "symlinked lock file is refused" test_symlinked_lock_refused
_run "symlinked lock dir is refused" test_symlinked_lock_dir_refused
_run "up-to-date index skips analyze" test_up_to_date_skips_analyze
_run "dirty index worktree is left alone" test_dirty_index_worktree_untouched
_run "tracked .gitnexus/ is not dirt and is kept" test_tracked_gitnexus_dir_not_dirt
_run "hostile /tmp env file is never read" test_hostile_tmp_env_file_ignored
_run "no PR recorded skips" test_no_pr_recorded_skips
_run "unindexed repo skips" test_unindexed_repo_skips
_run "usage error exits 2" test_usage_error

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
