#!/usr/bin/env bash
# test-appraise-knowledge-load.sh — unit tests for lib/appraise-knowledge-load.sh
# (ticket-appraise references/full-investigation.md Step 3a.0/3a.0b/3a.1,
# skill-deterministic-extraction 5).
#
# Parity oracle: the pre-extraction fences from main @ 20b4113, copied
# verbatim into _old_fences below with their placeholders filled from the same
# context.md, run against the same lib copy (prescan-check.sh stubbed; the old
# fences reach it through $HOME/.claude/skills/lib, the script through its own
# directory, which is the same copy). The script's PRESCAN_REPO/PRESCAN_DOC
# lines and WIKI_* block must carry exactly what the old fences produced.
#
# Usage: bash test-appraise-knowledge-load.sh
set -eo pipefail

AKL_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AKL_LIB_DIR="$(cd "$AKL_TEST_DIR/.." && pwd)"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE REPOS_ROOT WIKI_ROOT PRESCAN_CHECK_SH FLEET_WORKER_PID FLEET_GENERATION

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

_mkrepo() { # name status [index-topic]
  mkdir -p "$RR/$1"
  git -C "$RR/$1" init -q
  echo "$2" >"$RR/$1/.stub-status"
  if [ -n "${3:-}" ]; then
    mkdir -p "$RR/.ticket-auto/$1/docs/services"
    printf '# Prescan Index — %s\n\n## Lookup by Topic\n\n| Topic | File |\n|-------|------|\n| %s | services/%s.md |\n| unrelatedthing | overview.md |\n' \
      "$1" "$3" "$1" >"$RR/.ticket-auto/$1/docs/INDEX.md"
    printf '# %s\n' "$1" >"$RR/.ticket-auto/$1/docs/services/$1.md"
  fi
}

_ws_new() { # with-wiki
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/home/.claude/skills" "$WS/tickets/T-8--fix-it"
  cp -r "$AKL_LIB_DIR" "$WS/home/.claude/skills/lib"
  rm -rf "$WS/home/.claude/skills/lib/tests"
  printf '#!/usr/bin/env bash\nst=$(cat "$1/.stub-status" 2>/dev/null || echo missing)\nprintf "PRESCAN_STATUS=%%s\\nPRESCAN_REASON=stub\\n" "$st"\n[ "$st" = fresh ]\n' \
    >"$WS/home/.claude/skills/lib/prescan-check.sh"
  export HOME="$WS/home"
  LIB="$WS/home/.claude/skills/lib"
  RR="$WS/repos"
  WR=""
  [ "$1" = 1 ] && WR="$WS/wiki"
  _mkrepo billing fresh invoice
  _mkrepo gateway stale routing
  _mkrepo web missing
  TD="$WS/tickets/T-8--fix-it"
  cat >"$TD/context.md" <<'EOF'
# T-8: Invoice total wrong in billing

**Linear:** https://example.invalid/T-8
**Labels:** bug, backend
**Status:** Todo

---

## Description

The invoice total is wrong after the gateway forwards the request.
It "doubles" the tax line.

---

## Comments

None
EOF
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }

# The pre-extraction fences (main @ 20b4113), placeholders filled from
# context.md. Prints the values the agent would have read off them.
_old_fences() (
  set +eo pipefail
  REPOS_ROOT="$RR" WIKI_ROOT="$WR"
  TICKET_TITLE="Invoice total wrong in billing" TICKET_LABELS="bug, backend"
  TICKET_DESC='The invoice total is wrong after the gateway forwards the request.
It "doubles" the tax line.'
  # 3a.0
  REPOS=$(bash "$HOME/.claude/skills/lib/prescan-route.sh" --mode repos --repos-root "$REPOS_ROOT")
  for repo in $REPOS; do
    case "$repo" in PRESCAN_ROUTE_COUNT=*) continue ;; esac
    _derive_slug() { basename "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }
    slug=$(_derive_slug)
    eval $(bash "$HOME/.claude/skills/lib/prescan-check.sh" "$repo" --repos-root "$REPOS_ROOT")
    # 3a.1
    if [ "$PRESCAN_STATUS" != missing ] && [ -f "$REPOS_ROOT/.ticket-auto/$slug/docs/INDEX.md" ]; then
      MATCHED=$(bash "$HOME/.claude/skills/lib/prescan-route.sh" --mode index \
        --index "$REPOS_ROOT/.ticket-auto/$slug/docs/INDEX.md" \
        --ticket-title "$TICKET_TITLE" \
        --ticket-labels "$TICKET_LABELS" \
        --ticket-desc "${TICKET_DESC:0:500}")
      n=$(sed -n 's/^PRESCAN_ROUTE_COUNT=//p' <<<"$MATCHED")
      echo "PRESCAN_REPO=$slug|$PRESCAN_STATUS|$n|$repo"
      grep -v '^PRESCAN_ROUTE_COUNT=' <<<"$MATCHED" | sed "/^\$/d; s/^/PRESCAN_DOC=$slug|/"
    else
      echo "PRESCAN_REPO=$slug|$PRESCAN_STATUS|-|$repo"
    fi
  done
  # 3a.0b
  if [ -n "$WIKI_ROOT" ]; then
    source "$HOME/.claude/skills/lib/wiki-bootstrap.sh"
    wiki_bootstrap "$WIKI_ROOT"
  fi
  bash "$HOME/.claude/skills/lib/wiki-route.sh" \
    --wiki-root "$WIKI_ROOT" --repos-root "$REPOS_ROOT" \
    --ticket-title "$TICKET_TITLE" --ticket-labels "$TICKET_LABELS" --ticket-desc "$TICKET_DESC" \
    --affected-services ""
)

echo "=== parity with Step 3a fences ==="
for w in 0 1; do
  _ws_new "$w"
  want=$(_old_fences)
  rm -rf "$WS/wiki"
  got=$(bash "$LIB/appraise-knowledge-load.sh" --ticket-dir "$TD" --repos-root "$RR" ${WR:+--wiki-root "$WR"})
  _same "wiki=$w: same routing as the old fences" "$want" "$got"
  grep -q '^PRESCAN_REPO=billing|fresh|1|' <<<"$got" && grep -q "^PRESCAN_DOC=billing|$RR/.ticket-auto/billing/docs/services/billing.md$" <<<"$got" &&
    _ok "wiki=$w: billing routed to its service doc" || _ko "wiki=$w: billing: $got"
  grep -q '^PRESCAN_REPO=gateway|stale|0|' <<<"$got" && _ok "wiki=$w: gateway stale, no match" || _ko "wiki=$w: gateway"
  grep -q '^PRESCAN_REPO=web|missing|-|' <<<"$got" && _ok "wiki=$w: web missing, not routed" || _ko "wiki=$w: web"
  if [ "$w" = 1 ]; then
    [ -f "$WR/index.md" ] && _ok "wiki=1: bootstrap scaffolded index.md" || _ko "wiki=1: no index.md"
    (eval "$(grep '^WIKI_' <<<"$got" | grep -v '^WIKI_BOOTSTRAP')" && [ "$WIKI_ROUTE" = true ]) &&
      _ok "wiki=1: WIKI_* block is eval-safe, multi-repo routes" || _ko "wiki=1: WIKI block"
  fi
  _ws_rm
done

echo "=== unreadable prescan-check → missing ==="
_ws_new 0
printf '#!/usr/bin/env bash\nexit 2\n' >"$LIB/prescan-check.sh"
got=$(bash "$LIB/appraise-knowledge-load.sh" --ticket-dir "$TD" --repos-root "$RR")
[ "$(grep -c '|missing|-|' <<<"$got")" = 3 ] && _ok "every repo reports missing" || _ko "$got"
_ws_rm

echo "=== usage ==="
for args in "" "--ticket-dir /nonexistent --repos-root /tmp" "--repos-root /tmp" "--bogus x"; do
  rc=0
  bash "$AKL_LIB_DIR/appraise-knowledge-load.sh" $args >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && _ok "usage: '$args' → 2" || _ko "usage: '$args' rc=$rc"
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
