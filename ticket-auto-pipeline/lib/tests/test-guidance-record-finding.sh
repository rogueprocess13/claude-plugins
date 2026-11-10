#!/usr/bin/env bash
# test-guidance-record-finding.sh — guidance_record_finding in
# lib/guidance-store.sh (guidance-extractor Phase 2 store + CORRECTIONS
# writes, skill-deterministic-extraction 6a).
#
# Parity oracle: the pre-extraction "Guidance Store Writes" and "CORRECTIONS
# Block Integration" fences (main @ 267c17f) with their <placeholders>
# filled, run against a second store. The stored entries are compared with
# timestamps and the new `occurrences` counter removed; notes.md byte for
# byte. The old CORRECTIONS fence sourced `lib/corrections-parse.sh`
# relative to the CWD, which only worked from the plugin root; the oracle
# runs it from there. The old store fence also ran guidance-store.sh
# compute-id as an executable, but the file has no exec bit, so it got an
# empty id and guidance_upsert refused the entry; the oracle prefixes `bash`.
#
# Usage: bash test-guidance-record-finding.sh
set -eo pipefail

GR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GR_LIB_DIR="$(cd "$GR_TEST_DIR/.." && pwd)"
STORE="$GR_LIB_DIR/guidance-store.sh"

unset LOG_FILE TAP_LOG HB_LOG_FILE

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
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/home/.claude/skills" "$WS/old" "$WS/new"
ln -s "$GR_LIB_DIR" "$WS/home/.claude/skills/lib"
export HOME="$WS/home"
printf '# Notes\n\n## Session Log\n' >"$WS/old/notes.md"
cp "$WS/old/notes.md" "$WS/new/notes.md"

COMP="lib/gate-check.sh" RC="lib-script" PAT="flaky_tests" SEV="warn"
SUM="gate check retries a flaky probe" DET="3 of 5 verifier results flipped between attempts"
TID="T-4" RUN="T-4-2026-11-10T00:00:00Z-1" PH="VERIFY"
FACT="gate-check.sh retries without backoff" CORR="add a backoff between probe retries"

# Guidance Store Writes fence, main @ 267c17f, placeholders filled.
GUIDANCE_DIR="$WS/old/store" bash -c '
source "${HOME}/.claude/skills/lib/guidance-store.sh" 2>/dev/null
guidance_id=$(bash ${HOME}/.claude/skills/lib/guidance-store.sh compute-id "lib/gate-check.sh" "lib-script" "flaky_tests")
guidance_upsert "{
  \"guidance_id\": \"$guidance_id\",
  \"component\": \"lib/gate-check.sh\",
  \"root_cause\": \"lib-script\",
  \"pattern\": \"flaky_tests\",
  \"status\": \"proposed\",
  \"severity\": \"warn\",
  \"summary\": \"gate check retries a flaky probe\",
  \"detail\": \"3 of 5 verifier results flipped between attempts\",
  \"evidence_tickets\": [\"T-4\"],
  \"source\": \"phase-inspector\",
  \"run_id\": \"T-4-2026-11-10T00:00:00Z-1\",
  \"phase\": \"VERIFY\",
  \"transitions\": [
    {\"status\": \"proposed\", \"at\": \"2026-11-10T00:00:00Z\", \"run_id\": \"T-4-2026-11-10T00:00:00Z-1\"}
  ]
}"'
# CORRECTIONS Block Integration fence, main @ 267c17f, run from the plugin root.
(cd "$GR_LIB_DIR/.." && bash -c '
source lib/corrections-parse.sh
append_correction "$1" \
  "gate-check.sh retries without backoff" \
  "inspector" \
  "add a backoff between probe retries"' _ "$WS/old/notes.md")

out=$(GUIDANCE_DIR="$WS/new/store" bash "$STORE" record-finding --component "$COMP" --root-cause "$RC" \
  --pattern "$PAT" --severity "$SEV" --summary "$SUM" --detail "$DET" --ticket "$TID" --run-id "$RUN" \
  --phase "$PH" --notes "$WS/new/notes.md" --fact "$FACT" --corrected "$CORR")

_norm() { jq -cS 'del(.created_at, .updated_at, .occurrences) | .transitions |= map(del(.at))' "$1"/store/*.jsonl; }
_same "store entry matches the old upsert" "$(_norm "$WS/old")" "$(_norm "$WS/new")"
_same "file name matches" "$(cd "$WS/old/store" && ls -- *.jsonl)" "$(cd "$WS/new/store" && ls -- *.jsonl)"
_same "notes.md CORRECTIONS block matches" "$(cat "$WS/old/notes.md")" "$(cat "$WS/new/notes.md")"
id=$(bash "$STORE" compute-id "$COMP" "$RC" "$PAT")
grep -qx "GUIDANCE_ID=$id" <<<"$out" && grep -qx 'GUIDANCE_RECORDED=stored' <<<"$out" && grep -qx 'CORRECTION=appended' <<<"$out" &&
  _ok "prints id and outcomes" || _ko "output: $out"

# Repeat from another ticket: one entry, two occurrences, both tickets.
GUIDANCE_DIR="$WS/new/store" bash "$STORE" record-finding --component "$COMP" --root-cause "$RC" \
  --pattern "$PAT" --severity "$SEV" --summary "$SUM" --detail "$DET" --ticket T-5 --run-id r2 --phase "$PH" >/dev/null
f=$(ls "$WS/new/store"/*.jsonl)
_same "repeat: one entry" 1 "$(grep -c . "$f")"
_same "repeat: occurrences is two" 2 "$(jq -r .occurrences "$f")"
_same "repeat: evidence merged" '["T-4","T-5"]' "$(jq -c .evidence_tickets "$f")"
_same "repeat: transitions kept" 1 "$(jq '.transitions | length' "$f")"

# Plain upsert of an entry without `occurrences` keeps the counter as is.
GUIDANCE_DIR="$WS/new/store" bash "$STORE" upsert "$(jq -c 'del(.occurrences) | .evidence_tickets = ["T-6"]' "$f")" >/dev/null
_same "plain upsert leaves occurrences" 2 "$(jq -r .occurrences "$f")"

# Not stored: agent-prompt / network-flake.
out=$(GUIDANCE_DIR="$WS/skip" bash "$STORE" record-finding --component skills/ticket-auto/SKILL.md \
  --root-cause network-flake --pattern p --severity warn --summary s --detail d --ticket T-1 --run-id r --phase VERIFY \
  --notes "$WS/new/notes.md" --fact f --corrected c)
grep -qx 'GUIDANCE_RECORDED=skipped' <<<"$out" && [ ! -d "$WS/skip" ] && [ "$(grep -c '^<!-- CORRECTIONS -->' "$WS/new/notes.md")" = 1 ] &&
  _ok "network-flake writes nothing" || _ko "network-flake: $out"

# Fail-soft: an unwritable notes path reports failed, still exit 0.
rc=0
out=$(GUIDANCE_DIR="$WS/new/store" bash "$STORE" record-finding --component "$COMP" --root-cause skill-file \
  --pattern q --severity fail --summary s --detail d --ticket T-1 --run-id r --phase IMPLEMENT \
  --notes "$WS/missing-dir/notes.md" --fact f --corrected c) || rc=$?
[ "$rc" = 0 ] && grep -qx 'CORRECTION=failed' <<<"$out" && _ok "correction failure is soft" || _ko "soft fail rc=$rc $out"

rc=0
bash "$STORE" record-finding --component x >/dev/null 2>&1 || rc=$?
_same "usage exits 2" 2 "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
