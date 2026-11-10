#!/usr/bin/env bash
# test-prescan-run-repo.sh — lib/prescan-run-repo.sh and
# collect_corrections_by_source (ticket-prescan Steps 0, 1, 4.0, the
# scaffold-verify gate, 6 and the lock; skill-deterministic-extraction 6a).
#
# Parity oracle: the pre-extraction fences (main @ 267c17f) embedded below,
# run in the same workspace with a prescan-check stub. Deliberate
# differences, each asserted on its own rather than hidden: the old fences
# used `_plog`, `_derive_slug` and `$REPOS_ROOT` from other fences (each
# fence is a fresh shell), so the oracle defines them once; the old Step 4.0
# count was `echo "$summary" | wc -l` over a summary that already ends in a
# newline, one too many; the old verify gate counted violations with a
# `grep` that read stdin instead of the verifier's output.
#
# Usage: bash test-prescan-run-repo.sh
set -eo pipefail

PR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_LIB_DIR="$(cd "$PR_TEST_DIR/.." && pwd)"
PRR="$PR_LIB_DIR/prescan-run-repo.sh"

unset LOG_FILE TAP_LOG HB_LOG_FILE CLAUDE_LOG_FILE WIKI_ROOT
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

_ws_new() {
  WS=$(mktemp -d)
  WS=$(cd "$WS" && pwd -P)
  mkdir -p "$WS/home/.claude/skills" "$WS/repos/App_One" "$WS/repos/svc-two" "$WS/t"
  ln -s "$PR_LIB_DIR" "$WS/home/.claude/skills/lib"
  export HOME="$WS/home" REPOS_ROOT="$WS/repos"
  for r in App_One svc-two; do
    git -C "$WS/repos/$r" init -q
    git -C "$WS/repos/$r" commit -q --allow-empty -m init
  done
  # prescan-check stub: status from $STUB_STATUS_<slug>.
  cat >"$WS/check.sh" <<'EOF'
#!/usr/bin/env bash
s=$(basename "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'); v="STUB_STATUS_${s//-/_}"
echo "PRESCAN_STATUS=${!v:-fresh}"; echo "PRESCAN_REASON=stub"; echo "CHANGED_FILES=a.java"
EOF
  chmod +x "$WS/check.sh"
  export PRESCAN_CHECK_SH="$WS/check.sh"
}
_ws_rm() { [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true; }
_mask() { sed -e "s|$WS|\$WS|g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/TS/g'; }
_log() { { _mask <"$HOME/.claude/logs/prescan-$1.log"; } 2>/dev/null || true; }
_clear_logs() { rm -rf "$HOME/.claude/logs"; }

# Logging + Step 1 fences, main @ 267c17f, for one repo; prescan-check is
# the same stub (the fence ran lib/prescan-check.sh by its installed path).
_old_gate() { # <repo>
  bash -c '
set +eo pipefail
slug_of() { basename "${1}" | tr "[:upper:]" "[:lower:]" | sed "s/[^a-z0-9]/-/g"; }
repo="$1"; slug=$(slug_of "$repo")
mkdir -p "$HOME/.claude/logs"
PRESCAN_LOG="$HOME/.claude/logs/prescan-$slug.log"
_plog() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|${1}|${2}|${3}|${4}" >> "$PRESCAN_LOG"; }
  _plog "PRESCAN" "freshness-gate" "start" "$slug"
  eval $(bash "$PRESCAN_CHECK_SH" "$repo" --repos-root "$REPOS_ROOT")
  case "$PRESCAN_STATUS" in
  fresh)
    _plog "PRESCAN" "freshness-gate" "skip" "$slug: fresh ($PRESCAN_REASON)"
    ;;
  stale)
    _plog "PRESCAN" "freshness-gate" "done" "$slug: stale — incremental refresh"
    ;;
  decayed)
    _plog "PRESCAN" "freshness-gate" "done" "$slug: decayed — full re-dive"
    ;;
  missing)
    _plog "PRESCAN" "freshness-gate" "done" "$slug: missing — first-time scan"
    ;;
  esac
' _ "$1"
}

echo "=== list (Step 0) ==="
_ws_new
out=$(bash "$PRR" list)
_same "list: repos sorted with slugs" "REPOS_ROOT=$WS/repos
WIKI_ROOT=''
REPO=$WS/repos/App_One|app-one
REPO=$WS/repos/svc-two|svc-two" "$out"
_same "list: one repo path" "REPO=$WS/repos/svc-two|svc-two" "$(bash "$PRR" list "$WS/repos/svc-two" | grep '^REPO=')"
printf 'REPOS_ROOT = `%s`\nWIKI_ROOT = `%s/wiki`\n' "$WS/repos" "$WS" >"$WS/t/CLAUDE.md"
out=$(cd "$WS/t" && env -u REPOS_ROOT bash "$PRR" list)
grep -qx "REPOS_ROOT=$WS/repos" <<<"$out" && grep -qx "WIKI_ROOT=$WS/wiki" <<<"$out" &&
  _ok "list: roots from ./CLAUDE.md" || _ko "list: CLAUDE.md roots: $out"
rc=0
(cd "$WS" && env -u REPOS_ROOT bash "$PRR" list >/dev/null 2>&1) || rc=$?
_same "list: no REPOS_ROOT exits 1" 1 "$rc"
grep -q '|PRESCAN|env-check|fail|REPOS_ROOT not set$' "$HOME/.claude/logs/prescan.log" && _ok "list: env-check fail logged" || _ko "list: env-check log"
_ws_rm

echo "=== gate (Step 1): parity ==="
for st in fresh stale decayed missing; do
  _ws_new
  export STUB_STATUS_app_one="$st"
  _old_gate "$WS/repos/App_One"
  old=$(_log app-one)
  _clear_logs
  out=$(bash "$PRR" gate "$WS/repos/App_One")
  _same "$st: log lines" "$old" "$(_log app-one)"
  want=scan
  [ "$st" = fresh ] && want=skipped-fresh
  grep -qx "RESULT=$want" <<<"$out" && grep -qx 'SLUG=app-one' <<<"$out" && _ok "$st: RESULT=$want" || _ko "$st: $out"
  _ws_rm
done
_ws_new
export STUB_STATUS_app_one=stale
out=$(bash "$PRR" gate "$WS/repos/App_One")
grep -qx 'CADENCE=stale' <<<"$out" && grep -qx 'CHANGED_FILES=a.java' <<<"$out" && _ok "gate: cadence + changed files" || _ko "gate: $out"
out=$(bash "$PRR" gate "$WS/repos/App_One" --force)
grep -qx 'CADENCE=forced' <<<"$out" && grep -q '|PRESCAN|freshness-gate|done|app-one: forced — full re-dive$' "$HOME/.claude/logs/prescan-app-one.log" &&
  _ok "gate: --force bypasses the check" || _ko "gate --force: $out"
export STUB_STATUS_app_one=weird
out=$(bash "$PRR" gate "$WS/repos/App_One")
grep -qx 'RESULT=failed' <<<"$out" && _ok "gate: unknown status is a failure" || _ko "gate unknown: $out"

echo "=== gate: the lock ==="
export STUB_STATUS_app_one=stale
lock="$WS/repos/.ticket-auto/app-one/.lock"
mkdir -p "$(dirname "$lock")"
exec 7>"$lock"
flock -n 7
out=$(bash "$PRR" gate "$WS/repos/App_One")
grep -qx 'RESULT=skipped-locked' <<<"$out" && grep -q '|PRESCAN|lock|skip|app-one: locked by another process$' "$HOME/.claude/logs/prescan-app-one.log" &&
  _ok "lock: held elsewhere -> skipped-locked" || _ko "lock held: $out"
flock -u 7
exec 7>&-
out=$(bash "$PRR" gate "$WS/repos/App_One")
grep -qx 'RESULT=scan' <<<"$out" && _ok "lock: free -> scan" || _ko "lock free: $out"
(exec 8>"$lock" && flock -n 8) && _ok "lock: released after the probe" || _ko "lock left held"
# Killed while holding the lock: stdout is a FIFO whose 64 KiB buffer the
# test fills first, so the script blocks on its first write after the probe.
mkfifo "$WS/fifo"
exec 9<>"$WS/fifo"
head -c 65536 /dev/zero >&9
bash "$PRR" gate "$WS/repos/App_One" >&9 &
pid=$!
held=0
for _ in $(seq 1 50); do
  if ! (exec 8>"$lock" && flock -n 8); then held=1 && break; fi
  sleep 0.1
done
[ "$held" = 1 ] && _ok "lock: held mid-run" || _ko "lock: never held mid-run"
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
exec 9>&-
(exec 8>"$lock" && flock -n 8) && _ok "lock: killed run released it" || _ko "lock: killed run kept it"
_ws_rm

echo "=== corrections (Step 4.0) ==="
_ws_new
mkdir -p "$WS/t/tickets/A-1--x" "$WS/t/tickets/A-2--y" "$WS/t/tickets/A-3--z"
for n in "A-1--x:prescan:service list incomplete:add billing" "A-2--y:prescan:wrong chain:trace X->Y" "A-2--y:wiki:wiki gap:no" "A-3--z:exec:plan:no"; do
  IFS=: read -r d src f c <<<"$n"
  printf '\n<!-- CORRECTIONS -->\n- fact: %s\n- source: %s\n- corrected: %s\n<!-- /CORRECTIONS -->\n' "$f" "$src" "$c" >>"$WS/t/tickets/$d/notes.md"
done
# Step 4.0 fence, main @ 267c17f (prints the summary instead of logging).
old=$(cd "$WS/t" && bash -c '
source "$HOME/.claude/skills/lib/corrections-parse.sh"
set +eo pipefail
_corrections_summary=""
for _ticket_dir in $(find . -maxdepth 3 -type d -name "*--*" -path "*/tickets/*" 2>/dev/null | head -20); do
  _notes_file="$_ticket_dir/notes.md"
  [ -f "$_notes_file" ] || continue
  eval $(get_corrections_by_source "$_notes_file" "prescan" 2>/dev/null) || true
  if [ "${CORRECTION_COUNT:-0}" -gt 0 ]; then
    for _i in $(seq 0 $((CORRECTION_COUNT - 1))); do
      _f_var="CORRECTION_${_i}_FACT"
      _c_var="CORRECTION_${_i}_CORRECTED"
      _corrections_summary="${_corrections_summary}  - ${!_f_var}: ${!_c_var}
"
    done
  fi
done
printf "%s" "$_corrections_summary"
echo "COUNT=$(echo "$_corrections_summary" | wc -l)"' | sort)
new=$(cd "$WS/t" && bash "$PRR" corrections "$WS/repos/App_One" | sort)
_same "corrections: same entries" "$(grep -v '^COUNT=' <<<"$old")" "$new"
_same "corrections: old count was one too many" "COUNT=3" "$(grep '^COUNT=' <<<"$old")"
grep -q '|PRESCAN|corrections-collect|done|app-one: 2 prescan corrections found$' "$HOME/.claude/logs/prescan-app-one.log" &&
  _ok "corrections: logged count" || _ko "corrections: $(_log app-one)"
rm -rf "$WS/t/tickets"
_clear_logs
(cd "$WS/t" && bash "$PRR" corrections "$WS/repos/App_One" >/dev/null)
grep -q '|PRESCAN|corrections-collect|done|app-one: no prescan corrections found$' "$HOME/.claude/logs/prescan-app-one.log" &&
  _ok "corrections: none" || _ko "corrections none"
_ws_rm

echo "=== verify (scaffold gate) ==="
_ws_new
mkdir -p "$WS/repos/.ticket-auto/app-one/docs"
: >"$WS/repos/.ticket-auto/app-one/docs/overview.md"
rc=0
bash "$PRR" verify "$WS/repos/App_One" --cadence missing >/dev/null 2>&1 || rc=$?
_same "verify: no docs exits 1" 1 "$rc"
grep -qE '\|META\|gate-stop\|fail\|PRESCAN_NO_DOCS — quality violations: [1-9][0-9]*$' "$HOME/.claude/logs/prescan-app-one.log" &&
  _ok "verify: gate-stop with a real count" || _ko "verify: $(_log app-one)"
_ws_rm

echo "=== --write-meta (Step 6) ==="
_ws_new
mkdir -p "$WS/repos/.ticket-auto/app-one/docs"
printf '# Index\n' >"$WS/repos/.ticket-auto/app-one/docs/INDEX.md"
printf '# a\n' >"$WS/repos/.ticket-auto/app-one/docs/overview.md"
repo="$WS/repos/App_One"
printf '# App One\n\nHand-written.\n' >"$repo/CLAUDE.md"
# Step 6 full fan-out fence, main @ 267c17f (slug/repo/REPOS_ROOT set).
(cd "$WS" && repo="$repo" slug=app-one GITNEXUS_INDEXED=true GITNEXUS_SYMBOL_COUNT=42 bash -c '
HEAD_SHA=$(git -C "$repo" rev-parse HEAD)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$REPOS_ROOT/.ticket-auto/$slug/meta.json" <<METAEOF
{
  "schema_version": "1",
  "last_scanned_sha": "$HEAD_SHA",
  "last_scanned_at": "$NOW",
  "last_full_dive_sha": "$HEAD_SHA",
  "last_full_dive_ts": "$NOW",
  "incremental_scan_count": 0,
  "gitnexus_indexed": ${GITNEXUS_INDEXED:-false},
  "gitnexus_symbol_count": ${GITNEXUS_SYMBOL_COUNT:-0},
  "doc_count": $(find "$REPOS_ROOT/.ticket-auto/$slug/docs" -name "*.md" | wc -l)
}
METAEOF')
M="$WS/repos/.ticket-auto/app-one/meta.json"
_norm() { jq -S 'del(.last_scanned_at, .last_full_dive_ts)' "$M"; }
old=$(_norm)
out=$(bash "$PRR" "$repo" --write-meta --cadence missing --gitnexus-indexed true --symbols 42)
_same "write-meta full: same meta.json" "$old" "$(_norm)"
grep -qx "META_PATH=$M" <<<"$out" && grep -q 'ticket-auto:agent-knowledge' "$repo/CLAUDE.md" &&
  grep -q '|PRESCAN|wire|done|app-one: CLAUDE.md wired$' "$HOME/.claude/logs/prescan-app-one.log" &&
  _ok "write-meta: CLAUDE.md wired and logged" || _ko "write-meta wire: $out"
cp "$M" "$WS/meta.before"
# Step 6 incremental fence, main @ 267c17f.
(repo="$repo" slug=app-one bash -c '
HEAD_SHA=$(git -C "$repo" rev-parse HEAD)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META_PATH="$REPOS_ROOT/.ticket-auto/$slug/meta.json"
jq --arg sha "$HEAD_SHA" --arg now "$NOW" \
  ".last_scanned_sha = \$sha | .last_scanned_at = \$now | .incremental_scan_count = ((.incremental_scan_count // 0) + 1)" \
  "$META_PATH" > "${META_PATH}.tmp" && mv "${META_PATH}.tmp" "$META_PATH"')
old=$(_norm)
cp "$WS/meta.before" "$M"
bash "$PRR" "$repo" --write-meta --cadence stale >/dev/null
_same "write-meta stale: same meta.json" "$old" "$(_norm)"
_same "write-meta stale: counter" 1 "$(jq .incremental_scan_count "$M")"
rc=0
bash "$PRR" "$repo" --write-meta --cadence fresh >/dev/null 2>&1 || rc=$?
_same "write-meta: bad cadence exits 2" 2 "$rc"
_ws_rm

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
