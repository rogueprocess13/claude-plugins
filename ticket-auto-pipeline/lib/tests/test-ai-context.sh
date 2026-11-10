#!/usr/bin/env bash
# test-ai-context.sh — unit tests for lib/ai-context-prep.sh and
# lib/ai-context-finalize.sh (ticket-document Steps 0-2 and 5-6,
# skill-deterministic-extraction 6a).
#
# Parity oracle: the pre-extraction fences, main @ 267c17f, embedded below
# with their placeholders filled (CI checkouts are shallow, so no `git
# show`). The Step 2 fence relied on a $WORKTREE_PATH no earlier fence of
# that shell had set; the oracle sets it, which is what an agent filling the
# value in by hand ran. The counts and the verdict were agent prose; their
# expectations follow the prose's own definitions.
#
# Usage: bash test-ai-context.sh
set -eo pipefail

AC_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_LIB_DIR="$(cd "$AC_TEST_DIR/.." && pwd)"
TID="T-9"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT FLEET_WORKER_PID FLEET_GENERATION BASE_REF BASE_BRANCH
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

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

# $WS: origin (bare), a clone at $WT on branch t-9-fix with one commit past
# develop, a ticket dir $TD with notes.md, a private scratch dir and log.
_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/home/.claude/skills" "$WS/tickets/$TID--fix"
  mkdir -m 700 "$WS/scratch"
  ln -s "$AC_LIB_DIR" "$WS/home/.claude/skills/lib"
  export HOME="$WS/home" TICKET_TMP_DIR="$WS/scratch" TAP_LOG="$WS/p.log"
  : >"$TAP_LOG"
  TD="$WS/tickets/$TID--fix"
  WT="$WS/wt"
  git init -q --bare "$WS/origin.git"
  git init -q -b develop "$WT"
  printf 'a\n' >"$WT/a.txt"
  git -C "$WT" add -A && git -C "$WT" commit -q -m init
  git -C "$WT" remote add origin "$WS/origin.git"
  git -C "$WT" push -q origin develop
  git -C "$WT" checkout -q -b t-9-fix
  printf 'b\n' >>"$WT/a.txt"
  git -C "$WT" commit -q -am "fix: the thing"
  cat >"$TD/notes.md" <<EOF
# Notes

## Session Log
### 2026-11-01 — pre-implementation checkpoint
- Repos: app | Branch: t-9-fix | Worktree: $WT | Mode: simple-fix

## Corrections
<!-- CORRECTIONS -->
- fact: sweep missed the DAO
- source: appraise
- corrected: DAO is in scope
<!-- /CORRECTIONS -->
EOF
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_mask() { sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }

# ticket-document Step 0 (two fences) and Step 2 (two fences), main @ 267c17f.
_old_prep() {
  (
    set +eo pipefail
    source "$HOME/.claude/skills/lib/corrections-parse.sh"
    eval $(get_corrections "$TD/notes.md" 2>/dev/null) || CORRECTION_COUNT=0
    echo "CORRECTION_COUNT=$CORRECTION_COUNT"
  )
  bash ~/.claude/skills/lib/plog.sh MAINTENANCE document start "Reading notes.md for context"
  (
    set +eo pipefail
    WORKTREE_PATH="$WT"
    source ~/.claude/skills/lib/ticket-env.sh "$TID"
    git -C "$WORKTREE_PATH" fetch origin "${BASE_BRANCH:-develop}" --quiet 2>/dev/null || true
    git -C "$WORKTREE_PATH" diff "${BASE_REF:-origin/${BASE_BRANCH:-develop}}"...t-9-fix
  ) >"$WS/old-diff"
  git -C "$WT" log "${BASE_REF:-origin/${BASE_BRANCH:-develop}}"..t-9-fix --oneline >"$WS/old-log"
}

echo "=== ai-context-prep: parity with Steps 0 + 2 ==="
_ws_new
_old_prep >"$WS/old-out"
OLD_LOG=$(_mask <"$TAP_LOG")
: >"$TAP_LOG"
rc=0
OUT=$(bash "$AC_LIB_DIR/ai-context-prep.sh" "$TID" --ticket-dir "$TD" --worktree "" --branch "") || rc=$?
NEW_LOG=$(_mask <"$TAP_LOG")
_same "prep: log lines" "$OLD_LOG" "$NEW_LOG"
_same "prep: exit 0" 0 "$rc"
_same "prep: correction count" "$(grep '^CORRECTION_COUNT=' "$WS/old-out")" "$(grep '^CORRECTION_COUNT=' <<<"$OUT")"
_same "prep: git diff" "$(cat "$WS/old-diff")" "$(sed -n '/^=== GIT DIFF ===$/,$p' <<<"$OUT" | sed 1d)"
_same "prep: git log" "$(cat "$WS/old-log")" "$(sed -n '/^=== GIT LOG ===$/,/^=== GIT DIFF ===$/p' <<<"$OUT" | sed '1d;$d')"
grep -qx "WORKTREE_PATH=$WT" <<<"$OUT" && grep -qx 'BRANCH=t-9-fix' <<<"$OUT" &&
  _ok "prep: worktree and branch from the notes.md checkpoint" || _ko "prep: checkpoint parse: $OUT"
grep -qx 'CORRECTION_0_SOURCE=appraise' <<<"$OUT" && _ok "prep: correction fields printed" || _ko "prep: correction fields"

# Explicit flags win over the checkpoint; branch falls back to the checkout.
OUT=$(bash "$AC_LIB_DIR/ai-context-prep.sh" "$TID" --ticket-dir "$TD" --worktree "$WT")
grep -qx 'BRANCH=t-9-fix' <<<"$OUT" && _ok "prep: --worktree alone" || _ko "prep: --worktree alone"
printf '# Notes\n' >"$TD/notes.md"
OUT=$(bash "$AC_LIB_DIR/ai-context-prep.sh" "$TID" --ticket-dir "$TD" --worktree "$WT")
grep -qx 'BRANCH=t-9-fix' <<<"$OUT" && grep -qx 'CORRECTION_COUNT=0' <<<"$OUT" &&
  _ok "prep: branch from git when notes has no checkpoint" || _ko "prep: git branch fallback: $OUT"
rc=0
bash "$AC_LIB_DIR/ai-context-prep.sh" "$TID" --ticket-dir "$TD" >/dev/null 2>&1 || rc=$?
_same "prep: unresolved worktree exits 3" 3 "$rc"
rc=0
bash "$AC_LIB_DIR/ai-context-prep.sh" "$TID" >/dev/null 2>&1 || rc=$?
_same "prep: usage exits 2" 2 "$rc"
_ws_rm

# BASE_REF from the env file wins.
_ws_new
git -C "$WT" push -q origin develop:main
printf 'BASE_BRANCH=main\nBASE_REF=origin/main\n' >"$WS/scratch/ticket-auto-$TID-env.sh"
chmod 600 "$WS/scratch/ticket-auto-$TID-env.sh"
OUT=$(bash "$AC_LIB_DIR/ai-context-prep.sh" "$TID" --ticket-dir "$TD")
grep -qx 'BASE_REF=origin/main' <<<"$OUT" && _ok "prep: BASE_REF from the ticket env file" || _ko "prep: env BASE_REF: $(grep BASE_REF <<<"$OUT")"
_ws_rm

echo "=== ai-context-finalize ==="
# Step 6 fences, main @ 267c17f, with the agent's values filled in.
_old_finalize() { # <N patterns> <N decisions> <verdict> <met> <total>
  bash ~/.claude/skills/lib/plog.sh MAINTENANCE document done "ai-context.md written ($1 patterns, $2 decisions)"
  (
    source ~/.claude/skills/lib/verifier-result.sh
    write_verifier_result \
      verifier=ticket_document verdict="$3" \
      criteria_met="$4" criteria_total="$5" \
      phase=MAINTENANCE
  )
}
_full_ctx() {
  cat >"$TD/ai-context.md" <<'EOF'
# AI Context — T-9

**Date:** 2026-11-10
**Branch:** t-9-fix
**Complexity:** simple
**Outcome:** Smooth

## What changed
- a.txt: adds b

## Patterns used
- a.txt: append-only
- a.txt: one line per value

## Key files for future agents
- a.txt: the data

## Watch out for
- b depends on a

## Decisions
- kept a: compatibility
EOF
}
for c in full sparse trivial; do
  _ws_new
  case "$c" in
  full)
    _full_ctx
    args="2 1 PASS 5 5" sig=non-trivial
    ;;
  sparse)
    _full_ctx
    awk '/^## Watch out for/{s=1;print;next} /^## /{s=0} !s' "$TD/ai-context.md" >"$WS/x" && mv "$WS/x" "$TD/ai-context.md"
    args="2 1 WARN 4 5" sig=non-trivial
    ;;
  trivial)
    printf '# AI Context — T-9\n\n**Date:** 2026-11-10\n\nTrivial change — no architectural impact.\n' >"$TD/ai-context.md"
    args="0 0 PASS 1 1" sig=trivial
    ;;
  esac
  # shellcheck disable=SC2086
  _old_finalize $args 2>/dev/null
  OLD_LOG=$(_mask <"$TAP_LOG")
  : >"$TAP_LOG"
  rc=0
  OUT=$(bash "$AC_LIB_DIR/ai-context-finalize.sh" "$TID" --ticket-dir "$TD") || rc=$?
  NEW_LOG=$(_mask <"$TAP_LOG")
  _same "finalize $c: log lines" "$OLD_LOG" "$NEW_LOG"
  _same "finalize $c: exit 0" 0 "$rc"
  set -- $args
  grep -qx "patterns=$1" <<<"$OUT" && grep -qx "decisions=$2" <<<"$OUT" && grep -qx "significance=$sig" <<<"$OUT" &&
    grep -qx "file=$TD/ai-context.md" <<<"$OUT" && _ok "finalize $c: DOCUMENT_RESULT" || _ko "finalize $c: $OUT"
  _ws_rm
done

_ws_new
_full_ctx
bash "$AC_LIB_DIR/ai-context-finalize.sh" "$TID" --ticket-dir "$TD" >/dev/null
got=$(awk '/^## Session Log/{s=1;next} /^## /{s=0} s' "$TD/notes.md" | grep -c '^- ai-context.md written (2 patterns, 1 decisions, 1 corrections)$' || true)
_same "finalize: session log line inside ## Session Log" 1 "$got"
grep -q '^## Corrections' "$TD/notes.md" && _ok "finalize: other sections kept" || _ko "finalize: notes.md damaged"
printf '# Notes\n' >"$TD/notes.md"
bash "$AC_LIB_DIR/ai-context-finalize.sh" "$TID" --ticket-dir "$TD" >/dev/null
grep -A1 '^## Session Log$' "$TD/notes.md" | grep -qx -- '- ai-context.md written (2 patterns, 1 decisions, 0 corrections)' &&
  _ok "finalize: Session Log added when missing" || _ko "finalize: Session Log added when missing"
rm "$TD/ai-context.md"
: >"$TAP_LOG"
rc=0
OUT=$(bash "$AC_LIB_DIR/ai-context-finalize.sh" "$TID" --ticket-dir "$TD" 2>/dev/null) || rc=$?
_same "finalize: missing file exits 1" 1 "$rc"
grep -q '|MAINTENANCE|document|fail|ai-context.md not written$' "$TAP_LOG" &&
  grep -q '"verifier":"ticket_document".*"verdict":"FAIL"' "$TAP_LOG" &&
  grep -qx 'file=none' <<<"$OUT" && _ok "finalize: missing file logs fail + FAIL verdict" || _ko "finalize: missing: $(cat "$TAP_LOG")"
# detect-resume routes document|fail like done (STEP_5).
grep -q "'^\[^|\]\*|MAINTENANCE|document|fail|'" "$AC_LIB_DIR/../skills/ticket-detect-resume/detect-resume.sh" &&
  _ok "finalize: detect-resume still reads document|fail" || _ko "finalize: detect-resume no longer reads document|fail"
rc=0
bash "$AC_LIB_DIR/ai-context-finalize.sh" "$TID" >/dev/null 2>&1 || rc=$?
_same "finalize: usage exits 2" 2 "$rc"
_ws_rm

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
