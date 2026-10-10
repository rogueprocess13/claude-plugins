#!/usr/bin/env bash
# test-wiki-lock.sh — unit tests for lib/wiki-lock.sh and its wiring into
# skills/wiki-maintenance/SKILL.md (concurrent wiki-maintenance runs must not
# collide, and a commit must never sweep in another ticket's WIKI_ROOT edits).
# Usage: bash test-wiki-lock.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
LOCK="$LIB_DIR/wiki-lock.sh"
SKILL="$LIB_DIR/../skills/wiki-maintenance/SKILL.md"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export WIKI_LOCK_POLL_SECS=0

PASS=0
FAIL=0

_run() {
  local name="${1}"
  shift
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

_ws=""
_wiki=""
_log=""
_setup() {
  _ws=$(mktemp -d)
  _wiki="$_ws/wiki"
  _log="$_ws/pipeline.log"
  mkdir -p "$_wiki"
  git -C "$_wiki" init -q
  printf 'a\n' >"$_wiki/a.md"
  printf 'b\n' >"$_wiki/b.md"
  printf 'g\n' >"$_wiki/gone.md"
  git -C "$_wiki" add -A
  git -C "$_wiki" commit -q -m init
}
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

_OUT=""
_RC=0
_lock() {
  _RC=0
  _OUT=$(bash "$LOCK" "$@" 2>&1) || _RC=$?
}

_committed_files() { git -C "$_wiki" show --name-only --format= HEAD | sort | tr '\n' ' '; }

# ── acquire / contention / release ──────────────────────────────────────────

test_acquire_fresh() {
  _setup
  local ok=1
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '^WIKI_LOCK_STATUS=acquired$' || ok=0
  grep -q '^T-1 [0-9]*$' "$_wiki/.git/wiki-maintenance.lock.d/owner" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_second_ticket_waits_and_logs_once() {
  _setup
  local ok=1
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  WIKI_LOCK_WAIT_SECS=0 _lock acquire --wiki-root "$_wiki" --ticket T-2 --log-file "$_log"
  [ "$_RC" -eq 3 ] || ok=0
  echo "$_OUT" | grep -q '^WIKI_LOCK_HOLDER=T-1$' || ok=0
  WIKI_LOCK_WAIT_SECS=0 _lock acquire --wiki-root "$_wiki" --ticket T-2 --log-file "$_log"
  [ "$_RC" -eq 3 ] || ok=0
  [ "$(grep -c 'META|wiki-contention|warn|' "$_log")" -eq 1 ] || ok=0
  # The first holder is untouched.
  grep -q '^T-1 ' "$_wiki/.git/wiki-maintenance.lock.d/owner" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_gives_up_after_max_wait() {
  _setup
  local ok=1
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  WIKI_LOCK_WAIT_SECS=0 WIKI_LOCK_MAX_WAIT_SECS=0 _lock acquire --wiki-root "$_wiki" --ticket T-2 --log-file "$_log"
  [ "$_RC" -eq 4 ] || ok=0
  grep -q 'META|wiki-contention|fail|' "$_log" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_waiter_acquires_after_release() {
  _setup
  local ok=1
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  WIKI_LOCK_WAIT_SECS=0 _lock acquire --wiki-root "$_wiki" --ticket T-2
  [ "$_RC" -eq 3 ] || ok=0
  _lock release --wiki-root "$_wiki" --ticket T-1
  [ "$_RC" -eq 0 ] || ok=0
  _lock acquire --wiki-root "$_wiki" --ticket T-2
  [ "$_RC" -eq 0 ] || ok=0
  grep -q '^T-2 ' "$_wiki/.git/wiki-maintenance.lock.d/owner" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_same_ticket_reacquires() {
  _setup
  local ok=1
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '^WIKI_LOCK_STATUS=reacquired$' || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_stale_lock_broken() {
  _setup
  local ok=1
  mkdir "$_wiki/.git/wiki-maintenance.lock.d"
  echo "T-DEAD 1000" >"$_wiki/.git/wiki-maintenance.lock.d/owner"
  _lock acquire --wiki-root "$_wiki" --ticket T-2 --log-file "$_log"
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '^WIKI_LOCK_PREVIOUS_HOLDER=T-DEAD$' || ok=0
  grep -q 'META|wiki-lock|warn|broke stale WIKI_ROOT lock held by T-DEAD' "$_log" || ok=0
  grep -q '^T-2 ' "$_wiki/.git/wiki-maintenance.lock.d/owner" || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_release_is_identity_safe() {
  _setup
  local ok=1
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  _lock release --wiki-root "$_wiki" --ticket T-2
  [ "$_RC" -eq 5 ] || ok=0
  [ -d "$_wiki/.git/wiki-maintenance.lock.d" ] || ok=0
  _lock release --wiki-root "$_wiki" --ticket T-1
  [ "$_RC" -eq 0 ] || ok=0
  [ ! -d "$_wiki/.git/wiki-maintenance.lock.d" ] || ok=0
  _lock release --wiki-root "$_wiki" --ticket T-1
  [ "$_RC" -eq 0 ] || ok=0
  echo "$_OUT" | grep -q '^WIKI_LOCK_STATUS=not-held$' || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_concurrent_acquire_single_winner() {
  _setup
  local ok=1 i
  # A stale lock makes every racer take the break-and-retake path at once.
  mkdir "$_wiki/.git/wiki-maintenance.lock.d"
  echo "T-DEAD 1000" >"$_wiki/.git/wiki-maintenance.lock.d/owner"
  for i in 1 2 3 4 5 6; do
    (
      rc=0
      WIKI_LOCK_WAIT_SECS=0 bash "$LOCK" acquire --wiki-root "$_wiki" --ticket "T-$i" >/dev/null 2>&1 || rc=$?
      echo "$rc" >"$_ws/rc.$i"
    ) &
  done
  wait
  [ "$(cat "$_ws"/rc.* | grep -c '^0$')" -eq 1 ] || ok=0
  [ "$(cat "$_ws"/rc.* | grep -c '^3$')" -eq 5 ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# ── lock artifact placement (no shared /tmp) ────────────────────────────────

# Every lock artifact for a git wiki — lock dir, guard, waiter file — lives
# under .git, and nothing is created in TMPDIR.
test_git_root_artifacts_stay_under_git() {
  _setup
  local ok=1
  mkdir -p "$_ws/tmp"
  TMPDIR="$_ws/tmp" _lock acquire --wiki-root "$_wiki" --ticket T-1
  TMPDIR="$_ws/tmp" WIKI_LOCK_WAIT_SECS=0 _lock acquire --wiki-root "$_wiki" --ticket T-2
  [ "$_RC" -eq 3 ] || ok=0
  [ -e "$_wiki/.git/wiki-maintenance.lock.d.guard" ] || ok=0
  [ -e "$_wiki/.git/wiki-maintenance.lock.d.wait.T-2" ] || ok=0
  [ -z "$(ls -A "$_ws/tmp")" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# A non-git wiki root keeps every lock artifact in a private per-user base
# (mode 700), never in a shared, predictable TMPDIR path.
test_nongit_root_uses_private_base() {
  _setup
  local ok=1 plain="$_ws/plain-wiki" base mode
  mkdir -p "$plain" "$_ws/tmp" "$_ws/home"
  HOME="$_ws/home" XDG_RUNTIME_DIR="" TMPDIR="$_ws/tmp" _lock acquire --wiki-root "$plain" --ticket T-1
  [ "$_RC" -eq 0 ] || ok=0
  HOME="$_ws/home" XDG_RUNTIME_DIR="" TMPDIR="$_ws/tmp" WIKI_LOCK_WAIT_SECS=0 _lock acquire --wiki-root "$plain" --ticket T-2
  [ "$_RC" -eq 3 ] || ok=0
  base="$_ws/home/.cache/ticket-auto/wiki-lock"
  [ -d "$base" ] && [ ! -L "$base" ] || ok=0
  mode=$(stat -c %a "$base" 2>/dev/null || stat -f %Lp "$base")
  [ "$mode" = 700 ] || ok=0
  ls "$base"/*.lock.d/owner >/dev/null 2>&1 || ok=0
  ls "$base"/*.lock.d.guard >/dev/null 2>&1 || ok=0
  ls "$base"/*.lock.d.wait.T-2 >/dev/null 2>&1 || ok=0
  [ -z "$(ls -A "$_ws/tmp")" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# Symlinks another local user pre-planted at the old shared-TMPDIR names are
# never written through.
test_nongit_preplanted_tmp_symlinks_not_followed() {
  _setup
  local ok=1 plain="$_ws/plain-wiki" key old
  mkdir -p "$plain" "$_ws/tmp" "$_ws/home"
  printf 'precious\n' >"$_ws/victim"
  key=$(printf '%s' "$plain" | cksum | cut -d' ' -f1)
  old="$_ws/tmp/wiki-maintenance-${key}.lock.d"
  ln -s "$_ws/victim" "${old}.guard"
  ln -s "$_ws/victim" "${old}.wait.T-1"
  mkdir "$old"
  ln -s "$_ws/victim" "$old/owner.tmp"
  HOME="$_ws/home" XDG_RUNTIME_DIR="" TMPDIR="$_ws/tmp" WIKI_LOCK_WAIT_SECS=0 \
    _lock acquire --wiki-root "$plain" --ticket T-1
  [ "$_RC" -eq 0 ] || ok=0
  [ "$(cat "$_ws/victim")" = precious ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_nongit_symlinked_base_refused() {
  _setup
  local ok=1 plain="$_ws/plain-wiki"
  mkdir -p "$plain" "$_ws/xdg/ticket-auto" "$_ws/elsewhere"
  ln -s "$_ws/elsewhere" "$_ws/xdg/ticket-auto/wiki-lock"
  XDG_RUNTIME_DIR="$_ws/xdg" _lock acquire --wiki-root "$plain" --ticket T-1
  [ "$_RC" -eq 7 ] || ok=0
  echo "$_OUT" | grep -q 'symlink' || ok=0
  [ -z "$(ls -A "$_ws/elsewhere")" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_nongit_foreign_owned_base_refused() {
  # "/" is owned by root; as any other user it stands in for a base dir
  # someone else created. Skipped when the suite itself runs as root.
  [ "$(id -u)" != 0 ] || return 0
  _setup
  local ok=1 plain="$_ws/plain-wiki"
  mkdir -p "$plain"
  WIKI_LOCK_BASE_DIR=/ _lock acquire --wiki-root "$plain" --ticket T-1
  [ "$_RC" -eq 7 ] || ok=0
  echo "$_OUT" | grep -q 'not owned' || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# ── scoped commit ───────────────────────────────────────────────────────────

# The issue's core scenario: another ticket left uncommitted edits in
# WIKI_ROOT. This run's commit must contain only what this run changed.
test_commit_excludes_preexisting_foreign_edits() {
  _setup
  local ok=1
  printf 'b foreign\n' >>"$_wiki/b.md" # foreign modification
  printf 'c foreign\n' >"$_wiki/c.md"  # foreign untracked file
  printf 'e foreign\n' >"$_wiki/e.md"  # foreign, already staged
  git -C "$_wiki" add e.md
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  printf 'a mine\n' >>"$_wiki/a.md" # this run's edit
  printf 'd mine\n' >"$_wiki/d.md"  # this run's new file
  rm "$_wiki/gone.md"               # this run's deletion
  _lock commit --wiki-root "$_wiki" --ticket T-1 --message "docs(wiki): T-1 test"
  [ "$_RC" -eq 0 ] || ok=0
  [ "$(_committed_files)" = "a.md d.md gone.md " ] || ok=0
  [ "$(git -C "$_wiki" log -1 --format=%s)" = "docs(wiki): T-1 test" ] || ok=0
  # Foreign edits are still there, still uncommitted.
  git -C "$_wiki" status --porcelain | grep -q '^ M b.md$' || ok=0
  git -C "$_wiki" status --porcelain | grep -q '^?? c.md$' || ok=0
  git -C "$_wiki" status --porcelain | grep -q '^A  e.md$' || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_commit_includes_predirty_file_changed_further() {
  _setup
  local ok=1
  printf 'b foreign\n' >>"$_wiki/b.md"
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  printf 'b mine\n' >>"$_wiki/b.md"
  _lock commit --wiki-root "$_wiki" --ticket T-1 --message "docs(wiki): T-1 b"
  [ "$_RC" -eq 0 ] || ok=0
  [ "$(_committed_files)" = "b.md " ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_commit_refused_without_lock() {
  _setup
  local ok=1 head
  head=$(git -C "$_wiki" rev-parse HEAD)
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  printf 'a\n' >>"$_wiki/a.md"
  _lock commit --wiki-root "$_wiki" --ticket T-2 --message "docs(wiki): T-2 steal"
  [ "$_RC" -eq 5 ] || ok=0
  [ "$(git -C "$_wiki" rev-parse HEAD)" = "$head" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_commit_nothing_of_this_runs() {
  _setup
  local ok=1 head
  printf 'b foreign\n' >>"$_wiki/b.md"
  head=$(git -C "$_wiki" rev-parse HEAD)
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  _lock commit --wiki-root "$_wiki" --ticket T-1 --message "docs(wiki): T-1 none"
  [ "$_RC" -eq 6 ] || ok=0
  [ "$(git -C "$_wiki" rev-parse HEAD)" = "$head" ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

test_commit_handles_spaces_and_glob_chars() {
  _setup
  local ok=1
  printf 'x\n' >"$_wiki/[ab].md" # foreign; a glob pathspec would also match a.md/b.md
  _lock acquire --wiki-root "$_wiki" --ticket T-1
  mkdir -p "$_wiki/flows"
  printf 'mine\n' >"$_wiki/flows/my flow.md"
  _lock commit --wiki-root "$_wiki" --ticket T-1 --message "docs(wiki): T-1 spaces"
  [ "$_RC" -eq 0 ] || ok=0
  [ "$(_committed_files)" = "flows/my flow.md " ] || ok=0
  _teardown
  [ "$ok" = 1 ]
}

# ── SKILL.md wiring ─────────────────────────────────────────────────────────

test_skill_has_no_unscoped_add() {
  ! grep -qE 'git -C "\$WIKI_ROOT" add -A' "$SKILL"
}

test_skill_acquires_before_bootstrap_and_commits_scoped() {
  local acq boot commit
  acq=$(grep -n 'wiki-lock.sh" acquire' "$SKILL" | head -1 | cut -d: -f1)
  boot=$(grep -n '^wiki_bootstrap "\$WIKI_ROOT"' "$SKILL" | head -1 | cut -d: -f1)
  commit=$(grep -n '"\$_wlock" commit' "$SKILL" | head -1 | cut -d: -f1)
  [ -n "$acq" ] && [ -n "$boot" ] && [ -n "$commit" ] || return 1
  [ "$acq" -lt "$boot" ] || return 1
  grep -q '"\$_wlock" release' "$SKILL"
}

# ── run ──────────────────────────────────────────────────────────────────────

FILTER="${1:-}"
for t in test_acquire_fresh test_second_ticket_waits_and_logs_once \
  test_gives_up_after_max_wait test_waiter_acquires_after_release \
  test_same_ticket_reacquires test_stale_lock_broken test_release_is_identity_safe \
  test_concurrent_acquire_single_winner test_git_root_artifacts_stay_under_git \
  test_nongit_root_uses_private_base test_nongit_preplanted_tmp_symlinks_not_followed \
  test_nongit_symlinked_base_refused test_nongit_foreign_owned_base_refused \
  test_commit_excludes_preexisting_foreign_edits \
  test_commit_includes_predirty_file_changed_further \
  test_commit_refused_without_lock test_commit_nothing_of_this_runs \
  test_commit_handles_spaces_and_glob_chars \
  test_skill_has_no_unscoped_add test_skill_acquires_before_bootstrap_and_commits_scoped; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then continue; fi
  _run "$t" "$t"
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
