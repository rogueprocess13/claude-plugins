#!/bin/bash
# SessionStart hook — age-based sweep of the pipeline's /tmp scratch files.
#
# spawn_agent_pre writes three per-ticket scratch files (ctx, spawn-meta, env)
# and token-tracker-start.sh writes one start-timestamp file per subagent
# spawn. None of them can be deleted at spawn_agent_post time:
#   - env.sh is sourced by every later phase of the same ticket,
#   - spawn-meta is re-read by duplicate spawn_agent_post calls (idempotency
#     tail-check) and by tool-error-capture.sh,
#   - ctx.txt is read by tool-error-capture.sh for the whole run.
# So their lifetime is bounded by age instead: a ticket's whole file group is
# removed once *none* of its files has been touched for TTL minutes. Grouping
# by ticket rather than pruning file-by-file is what keeps a long-running
# ticket's env.sh alive — its mtime is from run start, while spawn_agent_pre
# keeps rewriting ctx/spawn-meta on every phase.
#
# Only the four file types this pipeline writes per spawn are considered.
# Progress files, stop files and flow locks share the ticket-auto-* namespace
# and are deliberately left alone.
#
# Where (GitHub #619): the files live in the private per-user scratch dir
# resolved by lib/ticket-tmp.sh (TICKET_TMP_DIR, else /tmp/ticket-auto-$EUID).
# Files that earlier versions left under predictable names in shared /tmp
# (TICKET_TMP_LEGACY_DIR, default /tmp) get the same age sweep, but only those
# this user owns and never through a symlink.
#
# Overrides (used by the unit tests, and TTL by operators):
#   TICKET_TMP_DIR         — the scratch dir to sweep (see lib/ticket-tmp.sh)
#   TICKET_TMP_LEGACY_DIR  — the pre-#619 location to clean up (default /tmp)
#   TICKET_TMP_TTL_MIN     — TTL in minutes (default 1440 = 24h)
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

LEGACY_DIR="${TICKET_TMP_LEGACY_DIR:-/tmp}"
SCRATCH_DIR=""
_TT_LIB="${BASH_SOURCE[0]%/*}/../lib/ticket-tmp.sh"
if [ -f "$_TT_LIB" ]; then
  # shellcheck source=../lib/ticket-tmp.sh
  source "$_TT_LIB"
  # ticket_tmp_peek, not ticket_tmp_dir: a sweep never creates the dir, and
  # the mode check below judges it before anything in it is touched.
  if ticket_tmp_peek; then
    SCRATCH_DIR="$TICKET_TMP_RESOLVED"
    # A loose scratch dir is not swept: its contents are not ours to judge.
    ticket_tmp_dir >/dev/null 2>&1 || SCRATCH_DIR=""
  fi
fi
TTL_MIN="${TICKET_TMP_TTL_MIN:-1440}"
# Non-numeric or empty TTL falls back to the default rather than producing a
# garbage cutoff that would sweep live files.
case "$TTL_MIN" in
'' | *[!0-9]*) TTL_MIN=1440 ;;
esac

# Map a scratch-file basename to the ticket it belongs to. Returns 1 for any
# name that is not one of the four managed types, so unrelated
# ticket-auto-* files are never touched.
_sweep_ticket_id() {
  local b="${1#ticket-auto-}"
  case "$b" in
  *-ctx.txt) b="${b%-ctx.txt}" ;;
  *-spawn-meta.txt) b="${b%-spawn-meta.txt}" ;;
  *-env.sh) b="${b%-env.sh}" ;;
  *-start-*.ts) b="${b%-start-*}" ;;
  *) return 1 ;;
  esac
  [ -n "$b" ] || return 1
  printf '%s' "$b"
}

_sweep_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

CUTOFF=$(($(date +%s) - TTL_MIN * 60))

# One pass over one directory. Every file must be a regular file this user
# owns, never a symlink - the legacy dir is shared /tmp.
_sweep_dir() {
  local TMP_DIR="$1" f id mtime i _scrub_id _scrub_tmp
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] || return 0
  local -A NEWEST=()
  local -a FILES=() IDS=()

  shopt -s nullglob
  for f in "$TMP_DIR"/ticket-auto-*; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || continue
    id=$(_sweep_ticket_id "$(basename "$f")") || continue
    mtime=$(_sweep_mtime "$f")
    FILES+=("$f")
    IDS+=("$id")
    if [ -z "${NEWEST[$id]}" ] || [ "$mtime" -gt "${NEWEST[$id]}" ]; then
      NEWEST["$id"]=$mtime
    fi
  done

  i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do
    id="${IDS[$i]}"
    if [ "${NEWEST[$id]}" -lt "$CUTOFF" ]; then
      rm -f -- "${FILES[$i]}" 2>/dev/null && removed=$((removed + 1)) || true
    fi
    i=$((i + 1))
  done

  # GitHub #578: env files written before 0.84.0 carried an
  # `export LINEAR_API_KEY="..."` line. A surviving (still-live) one is scrubbed
  # in place rather than left on disk for the rest of its TTL. Only files this
  # user owns, never through a symlink; the rewrite keeps mode 0600 and replaces
  # the file by rename, the same way spawn_write_env writes it.
  for f in "$TMP_DIR"/ticket-auto-*-env.sh; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || continue
    grep -q '^export LINEAR_API_KEY=' "$f" 2>/dev/null || continue
    _scrub_id=$(stat -c '%i:%Y' "$f" 2>/dev/null) || continue
    _scrub_tmp=$(mktemp "$TMP_DIR/.ticket-auto-scrub.XXXXXX" 2>/dev/null) || continue
    # grep -v exits 1 when nothing is left, which is still a correct result.
    grep -v '^export LINEAR_API_KEY=' "$f" >"$_scrub_tmp" 2>/dev/null || true
    touch -r "$f" "$_scrub_tmp" 2>/dev/null || true
    # A run that rewrote the file meanwhile (new inode or mtime) already wrote
    # a key-free copy; never replace it with this older one.
    if [ "$(stat -c '%i:%Y' "$f" 2>/dev/null)" = "$_scrub_id" ] &&
      mv -f "$_scrub_tmp" "$f" 2>/dev/null; then
      scrubbed=$((scrubbed + 1))
    else
      rm -f "$_scrub_tmp" 2>/dev/null || true
    fi
  done

  # A pre-0.84.0 spawn_write_env killed between its mktemp and its rename left
  # `.ticket-auto-<TID>-env.XXXXXX` holding the key, a name no glob above
  # matches. A finished write renames within milliseconds, so one older than a
  # minute is a crash leftover. Same ownership/symlink rules as above.
  for f in "$TMP_DIR"/.ticket-auto-*-env.*; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || continue
    [ "$(_sweep_mtime "$f")" -lt "$(($(date +%s) - 60))" ] || continue
    rm -f -- "$f" 2>/dev/null || true
  done
}

removed=0
scrubbed=0
_sweep_dir "$SCRATCH_DIR"
if [ "$LEGACY_DIR" != "$SCRATCH_DIR" ]; then
  _sweep_dir "$LEGACY_DIR"
fi

# stderr only — SessionStart hook stdout is injected into the session context.
[ "$scrubbed" -gt 0 ] && echo "ticket-auto: removed a stored Linear API key from $scrubbed legacy env file(s)" >&2
[ "$removed" -gt 0 ] && echo "ticket-auto: swept $removed stale scratch file(s)" >&2

# Best-effort housekeeping — never block session start.
exit 0
