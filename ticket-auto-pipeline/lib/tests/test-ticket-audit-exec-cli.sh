#!/usr/bin/env bash
# test-ticket-audit-exec-cli.sh — the CLI of lib/ticket-audit-exec.sh
# (ticket-audit-exec Steps 0-2 and the per-item calls, skill-deterministic-
# extraction 6a).
#
# Parity oracle: the pre-extraction fences (main @ 267c17f) embedded below,
# run in one shell with the functions sourced as Step 0 did (each real fence
# was a fresh shell, so the prose only worked when the agent re-sourced).
# The dedup guard is a stub in a lib copy (it calls Linear).
#
# Usage: bash test-ticket-audit-exec-cli.sh
set -eo pipefail

TA_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TA_LIB_DIR="$(cd "$TA_TEST_DIR/.." && pwd)"

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

WS=$(mktemp -d)
WS=$(cd "$WS" && pwd -P)
trap 'rm -rf "$WS"' EXIT
cp -r "$TA_LIB_DIR" "$WS/lib"
# Guard stub: "found" for tickets listed in $GUARD_FOUND.
printf '#!/usr/bin/env bash\ncase " $GUARD_FOUND " in *" $1 "*) exit 0 ;; esac\nexit 1\n' >"$WS/lib/audit-comment-guard.sh"
TAE="$WS/lib/ticket-audit-exec.sh"
export AUDIT_DIR="$WS/audit"

_rec() {
  rm -rf "$AUDIT_DIR"
  mkdir -p "$AUDIT_DIR/recommendations" "$AUDIT_DIR/archive"
  cat >"$AUDIT_DIR/recommendations/m-1.md" <<'EOF'
# Audit Recommendations: m (2026-06-07)
Source: milestone-abc
Generated: 2026-06-07T12:00:00Z
Phase: needs-info

## Needs Info (run 1 — delegate to ticket-critique)
- [ ] WIL-100 — needs-info: missing repro steps
- [>] WIL-101 — needs-info: scope unclear
- [x] WIL-102 — needs-info: already critiqued

## Structural (run 2 — post comments only)
- [ ] WIL-200 — merge candidate: duplicate of WIL-201
- [!] WIL-204 — drift: comment failed
EOF
  REC="$AUDIT_DIR/recommendations/m-1.md"
}

# Steps 0-2 and the 4c extraction fence, main @ 267c17f, one shell.
_old_run() {
  bash -c '
source "$1/config.sh"
source "$1/ticket-audit-exec.sh"
set +eo pipefail
RESOLVED_FILE="$2"
eval "$(resolve_file "$RESOLVED_FILE")" || exit 1
echo "TARGET_FILE=$TARGET_FILE"
CHECKLIST=$(parse_checklist "$TARGET_FILE")
CURRENT_PHASE=$(echo "$CHECKLIST" | jq -r ".phase")
SOURCE_ID=$(echo "$CHECKLIST" | jq -r ".source_id")
PENDING_NEEDS_INFO=$(echo "$CHECKLIST" | jq -r ".pending_needs_info")
PENDING_STRUCTURAL=$(echo "$CHECKLIST" | jq -r ".pending_structural")
echo "PHASE=$CURRENT_PHASE"
echo "SOURCE_ID=$SOURCE_ID"
echo "PENDING_NEEDS_INFO=$PENDING_NEEDS_INFO"
echo "PENDING_STRUCTURAL=$PENDING_STRUCTURAL"
echo "$CHECKLIST" | jq -r ".needs_info_items[] | select(.state == \"pending\" or .state == \"resumed\") | \"needs-info|\(.state)|\(.ticket_id)|\(.detail)|\(.detail_clean)|\(.all_ticket_ids)\""
echo "$CHECKLIST" | jq -r ".structural_items[] | select(.state == \"pending\" or .state == \"resumed\") | \"structural|\(.state)|\(.ticket_id)|\(.detail)|\(.detail_clean)|\(.all_ticket_ids)\""
' _ "$WS/lib" "${1:-}"
}

echo "=== run: parity with Steps 0-2 ==="
_rec
old=$(_old_run)
new=$(bash "$TAE" run)
_same "run: values and items" "$old" "$(grep -v '^DRY_RUN=\|^AUDIT_DIR=' <<<"$new" | sed 's/^ITEM=//')"
grep -qx 'DRY_RUN=false' <<<"$new" && grep -qx "AUDIT_DIR=$AUDIT_DIR" <<<"$new" && _ok "run: flags echoed" || _ko "run: $new"
new=$(bash "$TAE" run --file "$REC" --dry-run)
grep -qx 'DRY_RUN=true' <<<"$new" && grep -qx "TARGET_FILE=$REC" <<<"$new" && _ok "run: --file --dry-run" || _ko "run: $new"
[ "$(grep -c '^- \[>\]' "$REC")" = 1 ] && _ok "run: writes nothing" || _ko "run: mutated the file"
rc=0
bash "$TAE" run --file "$WS/none.md" >/dev/null 2>&1 || rc=$?
_same "run: missing file exits 1" 1 "$rc"

echo "=== start / done / failed / advance / archive ==="
out=$(bash "$TAE" start "$REC" WIL-100 milestone-abc needs-info | tail -1)
_same "start: proceed" PROCEED "$out"
grep -q '^- \[>\] WIL-100 ' "$REC" && _ok "start: write-ahead [>]" || _ko "start: no [>]"
bash "$TAE" done "$REC" WIL-100 >/dev/null
grep -q '^- \[x\] WIL-100 ' "$REC" && _ok "done: [x]" || _ko "done"
out=$(GUARD_FOUND=WIL-101 bash "$TAE" start "$REC" WIL-101 milestone-abc needs-info | tail -1)
_same "start: dedup" DEDUP "$out"
grep -q '^- \[x\] WIL-101 ' "$REC" && _ok "start: dedup marks done" || _ko "dedup mark"
bash "$TAE" start "$REC" WIL-200 milestone-abc structural >/dev/null
bash "$TAE" failed "$REC" WIL-200 >/dev/null
grep -q '^- \[!\] WIL-200 ' "$REC" && _ok "failed: [!]" || _ko "failed"
bash "$TAE" advance "$REC" needs-info-done >/dev/null
grep -qx 'Phase: needs-info-done' "$REC" && _ok "advance" || _ko "advance"
out=$(bash "$TAE" archive "$REC")
grep -q '^ARCHIVE_PATH=' <<<"$out" && [ -f "$AUDIT_DIR/archive/m-1.md" ] && _ok "archive: no pending items" || _ko "archive: $out"
_same "archive: already archived" "Already archived: $AUDIT_DIR/archive/m-1.md" "$(bash "$TAE" archive "$REC")"
_rec
_same "archive: pending skips" "PENDING — skipping archive" "$(bash "$TAE" archive "$REC")"
rc=0
bash "$TAE" start "$REC" WIL-100 x bogus >/dev/null 2>&1 || rc=$?
_same "usage exits 2" 2 "$rc"
out=$(bash -c 'source "$1"; declare -F parse_checklist >/dev/null && echo SOURCED' _ "$TAE")
_same "sourcing still defines the functions" SOURCED "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
