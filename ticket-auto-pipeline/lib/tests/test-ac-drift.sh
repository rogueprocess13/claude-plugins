#!/usr/bin/env bash
# test-ac-drift.sh — lib/ac-drift.sh (GitHub #604): ACs added in the tracker
# during the gate hold must be detected and carried into context.md.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS="$LIB_DIR/../skills"
DRIFT="$LIB_DIR/ac-drift.sh"

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

_ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
_ko() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}
_expect() { if [ "$2" = "$3" ]; then _ok "$1"; else _ko "$1 — want [$2] got [$3]"; fi; }

# A context.md shaped like ticket-setup's, with two ACs.
_mk_ticket() {
  local d="$TMP/$1"
  mkdir -p "$d"
  cat >"$d/context.md" <<'EOF'
# T-1: Title

**Linear:** https://example.invalid/T-1

---

## Description

Some intro.

## Acceptance Criteria

- [ ] Upload is accepted
- [ ] Batch reaches COMPLETE

## Scope

In: upload.

---

## Links & Attachments

None
EOF
  cat >"$d/notes.md" <<'EOF'
## Verification Plan

### Per-Criterion Verification

| # | Criterion | Method | Verifiable |
|---|-----------|--------|------------|
| 1 | Upload is accepted | UI | ✓ |
| 2 | Batch reaches COMPLETE | API | ✓ |
EOF
  echo "$d"
}

cat >"$TMP/desc-same.md" <<'EOF'
Some intro.

## Acceptance Criteria

- [ ] Upload is accepted
- [x] Batch   reaches complete

## Scope

In: upload.
EOF

cat >"$TMP/desc-added.md" <<'EOF'
Some intro.

## Acceptance Criteria

- [ ] Upload is accepted
- [ ] Batch reaches COMPLETE
- [ ] A lease expires after 5 minutes and another worker takes over
- [ ] No row lock is held during the upload

## Scope

In: upload.

## Planner Context

**Initiative:** INIT-1
EOF

d=$(_mk_ticket same)
out=$(bash "$DRIFT" "$d" --description-file "$TMP/desc-same.md")
rc=$?
_expect "same ACs (case/whitespace/checkbox state ignored) -> exit 0" 0 "$rc"
_expect "same ACs -> AC_DRIFT=false" "AC_DRIFT=false" "$(grep '^AC_DRIFT=' <<<"$out")"

d=$(_mk_ticket added)
cp "$d/context.md" "$TMP/ctx-before.md"
out=$(bash "$DRIFT" "$d" --description-file "$TMP/desc-added.md" --refresh --tag GATE --log-file "$d/pipeline.log")
rc=$?
_expect "two ACs added in the tracker -> exit 1" 1 "$rc"
_expect "AC_LINEAR=4" "AC_LINEAR=4" "$(grep '^AC_LINEAR=' <<<"$out")"
_expect "AC_CONTEXT=2" "AC_CONTEXT=2" "$(grep '^AC_CONTEXT=' <<<"$out")"
_expect "AC_VPLAN=2" "AC_VPLAN=2" "$(grep '^AC_VPLAN=' <<<"$out")"
_expect "AC_ADDED_COUNT=2" "AC_ADDED_COUNT=2" "$(grep '^AC_ADDED_COUNT=' <<<"$out")"
eval "$(grep '^AC_ADDED_1=' <<<"$out")"
_expect "AC_ADDED_1 carries the tracker text" "A lease expires after 5 minutes and another worker takes over" "${AC_ADDED_1:-}"
_expect "context.md refreshed" "AC_REFRESHED=true" "$(grep '^AC_REFRESHED=' <<<"$out")"
_expect "refreshed context.md has 4 AC items" 4 "$(grep -c '^- \[ \]' "$d/context.md")"
if grep -q '^## Scope' "$d/context.md" && grep -q '^## Links & Attachments' "$d/context.md" &&
  ! grep -q 'Planner Context' "$d/context.md"; then
  _ok "refresh keeps the rest of context.md and copies only the AC section"
else
  _ko "refresh keeps the rest of context.md and copies only the AC section"
fi
# notes-parse.sh's get_ac_count (VERIFY's AC count) now sees all four.
# shellcheck source=../notes-parse.sh
_expect "get_ac_count after refresh" 4 "$(source "$LIB_DIR/notes-parse.sh" && get_ac_count "$d")"
if grep -q '|META|gate-warn|info|AC_DRIFT_AT_GATE' "$d/pipeline.log"; then
  _ok "drift logged as META|gate-warn AC_DRIFT_AT_GATE"
else
  _ko "drift logged as META|gate-warn AC_DRIFT_AT_GATE"
fi
out=$(bash "$DRIFT" "$d" --description-file "$TMP/desc-added.md")
_expect "after refresh, only the short Verification Plan is drift" "AC_ADDED_COUNT=0" "$(grep '^AC_ADDED_COUNT=' <<<"$out")"
_expect "short Verification Plan still flags drift" "AC_DRIFT=true" "$(grep '^AC_DRIFT=' <<<"$out")"

d=$(_mk_ticket noac)
out=$(printf 'Just prose, no criteria.\n' | bash "$DRIFT" "$d")
_expect "description without ACs -> unknown, exit 0" "AC_DRIFT=unknown" "$(grep '^AC_DRIFT=' <<<"$out")"

bash "$DRIFT" "$TMP/missing" </dev/null >/dev/null 2>&1
_expect "missing ticket dir -> exit 2" 2 "$?"

# The gate reconcile clean pass and VERIFY Step 1c must run the check.
if grep -q 'ac-drift.sh.*--refresh --tag GATE' "$SKILLS/ticket-gate-reconcile/SKILL.md"; then
  _ok "ticket-gate-reconcile runs ac-drift.sh --refresh"
else
  _ko "ticket-gate-reconcile runs ac-drift.sh --refresh"
fi
if grep -q 'ac-drift.sh.*--tag VERIFY' "$SKILLS/ticket-verify/SKILL.md" &&
  ! grep -q 'The Description section contains the authoritative body' "$SKILLS/ticket-verify/SKILL.md"; then
  _ok "ticket-verify checks AC drift instead of trusting context.md"
else
  _ko "ticket-verify checks AC drift instead of trusting context.md"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
