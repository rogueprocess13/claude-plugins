#!/usr/bin/env bash
# seed-apply.sh — load the seeds of merged test-data blockers before VERIFY
# runs acceptance testing (planner-test-data-derivation, design.md
# Decision 9; spec test-data-seed-apply). Sourceable bash library. Does NOT
# set -euo pipefail at file scope (caller controls error handling) —
# ticket-verify sources it from a SKILL.md bash block, and gate-style callers
# must not have errexit/pipefail perturbed by doing so.
#
# Public API:
#   seed_apply <TID> <worktree>
#     For each blocker in the ticket's manifest `blocked_by` whose local
#     body has a `Seed command:` line and whose PR is merged, runs that
#     `make <target>` and then its `Verify command:` (when present) in
#     <worktree>. Logs to $LOG_FILE
#     (when set) in the pipeline-log format:
#       ISO|VERIFY|seed-apply|start|<n> blockers
#       ISO|VERIFY|seed-apply|done|<n> seeds applied (...)
#       ISO|VERIFY|seed-apply|skip|no test-data blockers with a Seed command (...)
#       ISO|VERIFY|seed-apply|fail|<blocker> <seed|verify> command exited <rc>
#       ISO|VERIFY|seed-apply|fail|<blocker> rejected <Seed|Verify> command: not 'make <target>'
#     Also sets SEED_APPLY_STATUS (done|skip|fail), SEED_APPLY_COUNT and
#     SEED_APPLY_MSG (the log message, `|`/CR/LF-free) for the caller.
#     Exit 0 done or skip, 1 fail, 2 usage error (no TID, worktree missing,
#     or the ticket's manifest is unreadable — a manifest that exists but
#     cannot be parsed is never treated as "no blockers").
#
# Decisions:
#   - Merged only. A blocker counts only when ticket_pipeline_merge_state
#     (manifest-read.sh) says `merged`. `no-pr` does not count: a test-data
#     ticket ships its seed target as code, so a completed run with no PR
#     has nothing on the base branch for the seed command to run. Such a
#     blocker, and any other non-merged one with a Seed command, is named
#     in the done/skip message (`not merged: <tid>=<state>`) so a reader can
#     see why it was not applied.
#   - Body source: the blocker's LOCAL planner body.md only
#     (resolve_planner_dir, planner-artifacts.sh) — the file ticket-planner
#     wrote into the blocker's ticket workspace. There is deliberately no
#     live tracker fallback (no get_issue): a tracker description is
#     editable by anyone with board access, and its text is what would be
#     executed. A blocker with no local body.md is treated as having no seed
#     and is named in the done/skip message (`no local body: <tid>`). It is
#     not failed closed: the ticket manifest carries no test-data marker (a
#     TD ticket is type `chore` like any other chore), so "this blocker is a
#     TD ticket" cannot be decided without the body itself, and failing
#     every body-less blocker would hold every consumer of an ad-hoc blocker.
#   - Command shape: a `Seed command:` / `Verify command:` value must be
#     exactly `make <target>` or `make -C <relpath> <target>` (backticks
#     tolerated). <target> matches ^[a-z0-9][a-z0-9_.-]*$; <relpath> matches
#     ^[A-Za-z0-9_./-]+$, is not absolute and has no `..` segment. Any other
#     value is rejected before anything runs: `fail|<tid> rejected <Seed|
#     Verify> command: not 'make <target>'`, rc 1 (the caller holds).
#   - The worktree is the consumer's verify worktree. Commands run in a
#     subshell `cd`'d there, so the caller's working directory never moves.
#
# Trust model: the seed and verify command text comes from a ticket body,
# so it is never handed to a shell. It is parsed against the strict
# `make <target>` shape above and executed as an argv list —
# `make [-C <dir>] -- <target>` — with no `bash -c`, no eval and no word
# splitting of untrusted text. What runs is therefore only a make target
# defined by the worktree's own Makefile, i.e. code that went through the
# test-data ticket's reviewed, merged PR (`merged` is the only state this
# file acts on). The body itself is read only from the local planner
# workspace, never from the tracker.
#
# Env:
#   LOG_FILE                 pipeline log to append to (optional)
#   FLEET_PIPELINE_LOG_DIR   where blocker pipeline logs live, when LOG_FILE
#                            is unset (LOG_FILE's directory wins)
#   SEED_APPLY_TIMEOUT_SECS  per-command timeout (default 900; 0 disables;
#                            needs coreutils `timeout`)
#
# Usage:
#   source lib/seed-apply.sh
#   seed_apply "CRE-12" "$REPOS_ROOT/.verify-worktrees/api/CRE-12"
#   bash lib/seed-apply.sh CRE-12 /path/to/worktree   # CLI

_SEED_APPLY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f get_ticket_manifest_field >/dev/null 2>&1; then
  # shellcheck source=manifest-read.sh
  source "$_SEED_APPLY_DIR/manifest-read.sh"
fi
if ! declare -f resolve_planner_dir >/dev/null 2>&1; then
  # shellcheck source=planner-artifacts.sh
  source "$_SEED_APPLY_DIR/planner-artifacts.sh"
fi

# _seed_apply_log <status> <msg> — one pipeline-log line, log-safe message.
_seed_apply_log() {
  local _sa_log="${LOG_FILE:-${TAP_LOG:-}}"
  [ -n "$_sa_log" ] || return 0
  local msg
  msg=$(printf '%s' "$2" | tr '|\r\n' '/  ')
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|seed-apply|$1|$msg" >>"$_sa_log" 2>/dev/null || true
}

# _seed_apply_body <TID> — echoes the blocker's local planner body.md.
# Returns 1 (empty output) when there is no local body. Never consults the
# tracker — see "Body source" above.
_seed_apply_body() {
  local tid="$1" pdir
  pdir=$(resolve_planner_dir "$tid" 2>/dev/null) || pdir=""
  [ -n "$pdir" ] && [ -f "$pdir/body.md" ] || return 1
  cat "$pdir/body.md" 2>/dev/null || return 1
}

# seed_apply_field <body> <label> — echoes the value of the first
# `<label>:` line outside a fenced code block. Tolerates a list marker,
# `**bold**`/`__bold__` around the label, and backticks around the value.
# Matching is case-insensitive on the label. Empty output = absent.
seed_apply_field() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v want="$2" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      sub(/^[ \t]*([-*+][ \t]+)?/, "", line)
      gsub(/\*\*|__/, "", line)
      n = length(want) + 1
      if (tolower(substr(line, 1, n)) != tolower(want) ":") next
      v = trim(substr(line, n + 1))
      while (v ~ /^`/) v = substr(v, 2)
      while (v ~ /`$/) v = substr(v, 1, length(v) - 1)
      v = trim(v)
      if (v != "") { print v; exit }
    }
  '
}

# seed_apply_parse_make <value> — validates a command value against the
# strict `make [-C <relpath>] <target>` shape. On success prints two lines,
# <dir> (empty when no -C) then <target>, and returns 0; otherwise prints
# nothing and returns 1. Backticks around the value are tolerated.
seed_apply_parse_make() {
  local v="$1"
  while [ "${v#\`}" != "$v" ]; do v="${v#\`}"; done
  while [ "${v%\`}" != "$v" ]; do v="${v%\`}"; done
  case "$v" in *$'\n'* | *$'\r'*) return 1 ;; esac
  local -a w=()
  read -r -a w <<<"$v" || true
  local dir="" target=""
  if [ "${#w[@]}" -eq 2 ] && [ "${w[0]}" = "make" ]; then
    target="${w[1]}"
  elif [ "${#w[@]}" -eq 4 ] && [ "${w[0]}" = "make" ] && [ "${w[1]}" = "-C" ]; then
    dir="${w[2]}"
    target="${w[3]}"
    [[ "$dir" =~ ^[A-Za-z0-9_./-]+$ ]] || return 1
    case "$dir" in /* | -*) return 1 ;; esac
    case "/$dir/" in */../*) return 1 ;; esac
  else
    return 1
  fi
  [[ "$target" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || return 1
  printf '%s\n%s\n' "$dir" "$target"
}

# _seed_apply_run <worktree> <dir> <target> — runs `make [-C dir] -- target`
# as an argv list in the worktree; returns make's rc.
_seed_apply_run() {
  local wt="$1" dir="$2" target="$3" secs="${SEED_APPLY_TIMEOUT_SECS:-900}"
  local -a cmd=(make)
  [ -n "$dir" ] && cmd+=(-C "$dir")
  cmd+=(-- "$target")
  if [ "$secs" != "0" ] && command -v timeout >/dev/null 2>&1; then
    (cd "$wt" && timeout "$secs" "${cmd[@]}") >&2
  else
    (cd "$wt" && "${cmd[@]}") >&2
  fi
}

# _seed_apply_reject <tid> <Seed|Verify> — the rejection fail line; rc 1.
_seed_apply_reject() {
  SEED_APPLY_MSG="$1 rejected $2 command: not 'make <target>'"
  _seed_apply_log fail "$SEED_APPLY_MSG"
  SEED_APPLY_MSG=$(printf '%s' "$SEED_APPLY_MSG" | tr '|\r\n' '/  ')
  return 1
}

seed_apply() {
  local tid="${1:-}" wt="${2:-}"
  SEED_APPLY_STATUS="fail"
  SEED_APPLY_COUNT=0
  SEED_APPLY_MSG=""

  if [ -z "$tid" ] || [ -z "$wt" ]; then
    echo "Usage: seed_apply <TID> <worktree>" >&2
    return 2
  fi
  if [ ! -d "$wt" ]; then
    SEED_APPLY_MSG="worktree not found: $wt"
    _seed_apply_log fail "$SEED_APPLY_MSG"
    return 2
  fi

  local workspace="${FLEET_PIPELINE_LOG_DIR:-./logs}"
  local _sa_lf="${LOG_FILE:-${TAP_LOG:-}}"
  [ -n "$_sa_lf" ] && workspace=$(dirname "$_sa_lf")

  local blocked_json rc=0
  blocked_json=$(get_ticket_manifest_field "$tid" blocked_by 2>/dev/null) || rc=$?
  case "$rc" in
  0) ;;
  1) blocked_json="[]" ;; # no manifest: an ad-hoc ticket has no blockers
  *)
    SEED_APPLY_MSG="cannot read the manifest of $tid (rc $rc)"
    _seed_apply_log fail "$SEED_APPLY_MSG"
    return 2
    ;;
  esac
  [ -n "$blocked_json" ] && [ "$blocked_json" != "null" ] || blocked_json="[]"

  local -a blockers=()
  local b
  while IFS= read -r b; do
    [ -n "$b" ] && blockers+=("$b")
  done < <(printf '%s' "$blocked_json" | jq -r 'if type == "array" then .[] | strings else empty end' 2>/dev/null)

  _seed_apply_log start "${#blockers[@]} blockers"

  local applied=0 body seed verify state src_rc parsed
  local seed_dir seed_target verify_dir verify_target
  local -a applied_ids=() unmerged=() nobody=()
  for b in "${blockers[@]}"; do
    if ! body=$(_seed_apply_body "$b") || [ -z "$body" ]; then
      nobody+=("$b")
      continue
    fi
    seed=$(seed_apply_field "$body" "Seed command")
    [ -n "$seed" ] || continue

    state=$(ticket_pipeline_merge_state "$b" "$workspace" 2>/dev/null) || true
    if [ "$state" != "merged" ]; then
      unmerged+=("$b=${state:-unknown}")
      continue
    fi

    # Validate both commands before running either.
    parsed=$(seed_apply_parse_make "$seed") || {
      _seed_apply_reject "$b" Seed
      return 1
    }
    seed_dir=$(printf '%s\n' "$parsed" | sed -n 1p)
    seed_target=$(printf '%s\n' "$parsed" | sed -n 2p)
    verify=$(seed_apply_field "$body" "Verify command")
    verify_dir=""
    verify_target=""
    if [ -n "$verify" ]; then
      parsed=$(seed_apply_parse_make "$verify") || {
        _seed_apply_reject "$b" Verify
        return 1
      }
      verify_dir=$(printf '%s\n' "$parsed" | sed -n 1p)
      verify_target=$(printf '%s\n' "$parsed" | sed -n 2p)
    fi

    src_rc=0
    _seed_apply_run "$wt" "$seed_dir" "$seed_target" || src_rc=$?
    if [ "$src_rc" -ne 0 ]; then
      SEED_APPLY_MSG="$b seed command exited $src_rc: $seed"
      _seed_apply_log fail "$SEED_APPLY_MSG"
      SEED_APPLY_MSG=$(printf '%s' "$SEED_APPLY_MSG" | tr '|\r\n' '/  ')
      return 1
    fi
    if [ -n "$verify_target" ]; then
      src_rc=0
      _seed_apply_run "$wt" "$verify_dir" "$verify_target" || src_rc=$?
      if [ "$src_rc" -ne 0 ]; then
        SEED_APPLY_MSG="$b verify command exited $src_rc: $verify"
        _seed_apply_log fail "$SEED_APPLY_MSG"
        SEED_APPLY_MSG=$(printf '%s' "$SEED_APPLY_MSG" | tr '|\r\n' '/  ')
        return 1
      fi
    fi
    applied=$((applied + 1))
    applied_ids+=("$b")
  done

  local note=""
  [ "${#unmerged[@]}" -gt 0 ] && note=" (not merged: ${unmerged[*]})"
  [ "${#nobody[@]}" -gt 0 ] && note="${note} (no local body: ${nobody[*]})"

  SEED_APPLY_COUNT=$applied
  if [ "$applied" -gt 0 ]; then
    SEED_APPLY_STATUS="done"
    SEED_APPLY_MSG="$applied seeds applied: ${applied_ids[*]}${note}"
    _seed_apply_log "done" "$SEED_APPLY_MSG"
  else
    SEED_APPLY_STATUS="skip"
    SEED_APPLY_MSG="no test-data blockers with a Seed command${note}"
    _seed_apply_log skip "$SEED_APPLY_MSG"
  fi
  SEED_APPLY_MSG=$(printf '%s' "$SEED_APPLY_MSG" | tr '|\r\n' '/  ')
  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────────
# Usage: seed-apply.sh <TID> <worktree>

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ $# -lt 2 ]; then
    echo "Usage: seed-apply.sh <TID> <worktree>" >&2
    exit 2
  fi
  _sa_rc=0
  seed_apply "$1" "$2" || _sa_rc=$?
  echo "SEED_APPLY_STATUS=$SEED_APPLY_STATUS"
  echo "SEED_APPLY_COUNT=$SEED_APPLY_COUNT"
  echo "SEED_APPLY_MSG=$SEED_APPLY_MSG"
  exit "$_sa_rc"
fi
