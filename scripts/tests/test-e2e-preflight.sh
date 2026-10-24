#!/usr/bin/env bash
# test-e2e-preflight.sh — scripts/e2e-preflight.sh (dispatch-rehearsal-preflight).
# Builds a throwaway REPOS_ROOT with one initiative (two children, edge
# WIL-2 → WIL-1), fakes Linear with a curl shim on PATH, and checks every
# spec scenario: clean pass, PARTIAL, DoR / gate / critique / dispatch-flag /
# dry-run / blocked-edge failures, and the exit-2 paths.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../.." && pwd)"
PF="$ROOT/scripts/e2e-preflight.sh"
TAP_LIB="$ROOT/ticket-auto-pipeline/lib"
FIX="$TAP_LIB/tests/fixtures/dor"
CS="$TAP_LIB/critique-status.sh"

PASS=0
FAIL=0
ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
nok() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Fake curl: answers get_issue from $FAKE_LINEAR_DIR/<id>.md (description),
# or fails at the transport level when FAKE_LINEAR_FAIL=1.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/curl" <<'SHIM'
#!/usr/bin/env bash
cat >/dev/null
if [ "${FAKE_LINEAR_FAIL:-0}" = 1 ]; then printf '\n000'; exit 7; fi
payload=""
while [ $# -gt 0 ]; do [ "$1" = "-d" ] && payload="$2"; shift; done
id=$(jq -r '.variables.id // .variables.issueId // empty' <<<"$payload" 2>/dev/null)
desc=""
[ -n "$id" ] && [ -f "$FAKE_LINEAR_DIR/$id.md" ] && desc=$(cat "$FAKE_LINEAR_DIR/$id.md")
jq -nc --arg id "${id:-X}" --arg d "$desc" \
  '{data:{issue:{id:$id,identifier:$id,title:"t",description:$d,priority:3,
    state:{id:"s",name:"Backlog",type:"backlog"},labels:{nodes:[]},team:{id:"t",name:"T"}}}}'
printf '\n200'
SHIM
chmod +x "$TMP_ROOT/bin/curl"

# fixture <name> — fresh REPOS_ROOT with INIT-9 (WIL-1, WIL-2 ← WIL-1); prints its path.
fixture() {
  local rr="$TMP_ROOT/$1"
  mkdir -p "$rr/linear"
  (
    export REPOS_ROOT="$rr"
    source "$TAP_LIB/manifest-write.sh" >/dev/null 2>&1
    write_epic_manifest INIT-9 "" "per-ticket" "manual" '["WIL-1","WIL-2"]' >/dev/null
    stamp_epic_dispatch INIT-9 >/dev/null
    write_ticket_manifest WIL-1 INIT-9 feature '[]' >/dev/null
    write_ticket_manifest WIL-2 INIT-9 feature '["WIL-1"]' >/dev/null
    for t in WIL-1 WIL-2; do
      p=$(get_ticket_manifest_path "$t")
      cp "$FIX/22-sourced-contract.md" "$(dirname "$p")/body.md"
      cp "$FIX/22-sourced-contract.md" "$rr/linear/$t.md"
    done
  )
  echo "$rr"
}

# critique <out> <tid> <score> <blockers> — a --no-post result file
critique() {
  bash "$CS" --score "$3" --blockers "$4" --warnings 0 --ticket "$2" --result-file "$1/critique/$2.txt" >/dev/null
}

# run <repos_root> <out> [args...] — prints stdout, sets RC
run() {
  local rr="$1" out="$2"
  shift 2
  OUTPUT=$(cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" REPOS_ROOT="$rr" FAKE_LINEAR_DIR="$rr/linear" \
    LINEAR_API_KEY=lin_test LINEAR_RETRY_DELAYS="0 0 0" HOME="$TMP_ROOT/home" \
    FLEET_INSTANCE_ID=pftest \
    bash "$PF" INIT-9 --out "$out" "$@" </dev/null 2>"$out.err")
  RC=$?
}

# cell <out> <tid> <check> <col: 3=rc 4=codes>
cell() { awk -F'\t' -v t="$2" -v c="$3" -v k="$4" '$1==t && $2==c {print $k}' "$1/preflight.tsv"; }

# ── 1. all pass ──────────────────────────────────────────────────────────────
rr=$(fixture pass)
out="$TMP_ROOT/out-pass"
mkdir -p "$out/critique"
critique "$out" WIL-1 85 0
critique "$out" WIL-2 85 0
run "$rr" "$out"
if [ "$RC" -eq 0 ] && grep -q '^PREFLIGHT INIT-9 PASS ' <<<"$OUTPUT"; then
  ok "clean initiative → PASS, exit 0"
else
  nok "clean initiative: rc=$RC out=$OUTPUT"
  cat "$out/preflight.tsv" 2>/dev/null
  head -40 "$out/dispatch-dry-run.txt" 2>/dev/null
fi
[ "$(cell "$out" WIL-1 gate-planned 3)" = 0 ] && ok "gate-planned passes with planned-precheck|done" ||
  nok "gate-planned: $(cell "$out" WIL-1 gate-planned 4)"
[ "$(cell "$out" INIT-9 blocked-edges 3)" = 0 ] && ok "sibling edge WIL-2 ← WIL-1 accepted" ||
  nok "blocked-edges: $(cell "$out" INIT-9 blocked-edges 4)"
grep -q 'blocked by WIL-1' "$out/dispatch-dry-run.txt" && ok "dry-run reports WIL-2 blocked by WIL-1" ||
  nok "dry-run did not report the sibling block"
! grep -q '"timestamp":"[^-]' "$out/dispatch-dry-run.txt" && ok "timestamps stripped" || nok "timestamp left in dry-run output"
[ "$(cat "$out/verdict.txt")" = "$(tail -1 <<<"$OUTPUT")" ] && ok "verdict.txt = last stdout line" || nok "verdict.txt mismatch"
compgen -G "$out/logs/*-pipeline.log" >/dev/null && nok "a *-pipeline.log was written" || ok "no *-pipeline.log written"

# ── 2. --skip-critique → PARTIAL ─────────────────────────────────────────────
out="$TMP_ROOT/out-partial"
run "$(fixture partial)" "$out" --skip-critique
[ "$RC" -eq 0 ] && grep -q '^PREFLIGHT INIT-9 PARTIAL ' <<<"$OUTPUT" && [ "$(cell "$out" WIL-1 critique 3)" = skip ] &&
  ok "--skip-critique → PARTIAL, exit 0" || nok "--skip-critique: rc=$RC out=$OUTPUT"

# ── 3. critique missing / blocked ────────────────────────────────────────────
out="$TMP_ROOT/out-crit"
mkdir -p "$out/critique"
critique "$out" WIL-2 20 2
run "$(fixture crit)" "$out"
[ "$RC" -eq 1 ] && [ "$(cell "$out" WIL-1 critique 4)" = CRITIQUE_RESULT_MISSING ] &&
  ok "missing critique result → CRITIQUE_RESULT_MISSING" || nok "missing critique: rc=$RC $(cell "$out" WIL-1 critique 4)"
[ "$(cell "$out" WIL-2 critique 4)" = CRITIQUE_BLOCKED:blocker ] && ok "blocked critique → CRITIQUE_BLOCKED:blocker" ||
  nok "blocked critique: $(cell "$out" WIL-2 critique 4)"

# ── 4. DoR failure (unsourced test data on a contract body) ──────────────────
rr=$(fixture dor)
p=$(REPOS_ROOT="$rr" bash -c "source '$TAP_LIB/manifest-read.sh'; get_ticket_manifest_path WIL-1")
cp "$FIX/23-planned-contract-unsourced.md" "$(dirname "$p")/body.md"
out="$TMP_ROOT/out-dor"
run "$rr" "$out" --skip-critique
[ "$RC" -eq 1 ] && grep -q TEST_DATA_UNSOURCED <<<"$(cell "$out" WIL-1 dor 4)" &&
  ok "unsourced test data → dor row TEST_DATA_UNSOURCED, exit 1" || nok "dor failure: rc=$RC $(cell "$out" WIL-1 dor 4)"
grep -q 'not-ready WIL-1' "$out/dispatch-dry-run.txt" && grep -q 'NOT_READY:WIL-1' <<<"$(cell "$out" INIT-9 dry-run 4)" &&
  ok "dry-run not-ready line → dry-run row NOT_READY:WIL-1" || nok "dry-run row: $(cell "$out" INIT-9 dry-run 4)"

# ── 5. gate vacuous passes ───────────────────────────────────────────────────
out="$TMP_ROOT/out-fetch"
OUTPUT=$(cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" REPOS_ROOT="$(fixture fetch)" FAKE_LINEAR_FAIL=1 \
LINEAR_API_KEY=lin_test LINEAR_RETRY_DELAYS="0 0 0" HOME="$TMP_ROOT/home" \
  bash "$PF" INIT-9 --out "$out" --skip-critique </dev/null 2>/dev/null)
[ "$(cell "$out" WIL-1 gate-planned 4)" = GATE_FETCH_DEFERRED ] && ok "fetch failure → GATE_FETCH_DEFERRED (not a pass)" ||
  nok "fetch failure: $(cell "$out" WIL-1 gate-planned 3)/$(cell "$out" WIL-1 gate-planned 4)"

rr=$(fixture adhoc)
p=$(REPOS_ROOT="$rr" bash -c "source '$TAP_LIB/manifest-read.sh'; get_ticket_manifest_path WIL-1")
jq '.initiative = "_adhoc"' "$p" >"$p.tmp" && mv "$p.tmp" "$p"
out="$TMP_ROOT/out-adhoc"
run "$rr" "$out" --skip-critique
[ "$(cell "$out" WIL-1 gate-planned 4)" = GATE_NOT_PLANNED ] && ok "_adhoc ticket → GATE_NOT_PLANNED (not a pass)" ||
  nok "_adhoc: $(cell "$out" WIL-1 gate-planned 3)/$(cell "$out" WIL-1 gate-planned 4)"

# ── 6. epic not dispatchable: row fails, manifest untouched ──────────────────
rr=$(fixture nodispatch)
em="$rr/.ticket-auto/initiatives/INIT-9/epic/manifest.json"
jq '.dispatch = false' "$em" >"$em.tmp" && mv "$em.tmp" "$em"
before=$(sha256sum "$em")
out="$TMP_ROOT/out-nodispatch"
run "$rr" "$out" --skip-critique
[ "$RC" -eq 1 ] && [ "$(cell "$out" INIT-9 dispatch-flag 4)" = EPIC_NOT_DISPATCHABLE:false ] &&
  ok "dispatch=false → EPIC_NOT_DISPATCHABLE" || nok "dispatch-flag: rc=$RC $(cell "$out" INIT-9 dispatch-flag 4)"
[ "$before" = "$(sha256sum "$em")" ] && ok "epic manifest byte-identical" || nok "epic manifest changed"

# ── 7. blocked edges: outside initiative, no manifest edge ───────────────────
rr=$(fixture edges)
out="$TMP_ROOT/out-edges"
mkdir -p "$out"
cat >"$TMP_ROOT/fake-dry.txt" <<'EOF'
fleet_dispatch: enumerating child tickets (manifest)...
  checking WIL-1 (manifest dispatch=false)...
    blocked by CRE-77 (not yet Done) — skipping
  blocked WIL-1
  checking WIL-2 (manifest dispatch=false)...
    blocked by WIL-1 (not yet Done) — skipping
  blocked WIL-2
EOF
# Exercise the edge parser on a canned dry-run: a sourced fleet-dispatch.sh
# whose fleet_dispatch_initiative is replaced by `cat` of the fixture.
mkdir -p "$TMP_ROOT/fc-stub"
printf 'fleet_dispatch_initiative() { cat "%s"; }\n' "$TMP_ROOT/fake-dry.txt" >"$TMP_ROOT/fc-stub/fleet-dispatch.sh"
stub_root="$TMP_ROOT/stubroot"
mkdir -p "$stub_root/scripts" "$stub_root/fleet-controller"
cp "$PF" "$stub_root/scripts/"
ln -s "$ROOT/ticket-auto-pipeline" "$stub_root/ticket-auto-pipeline"
ln -s "$TMP_ROOT/fc-stub" "$stub_root/fleet-controller/lib"
p=$(REPOS_ROOT="$rr" bash -c "source '$TAP_LIB/manifest-read.sh'; get_ticket_manifest_path WIL-2")
jq '.blocked_by = []' "$p" >"$p.tmp" && mv "$p.tmp" "$p"
OUTPUT=$(cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" REPOS_ROOT="$rr" FAKE_LINEAR_DIR="$rr/linear" \
  LINEAR_API_KEY=lin_test LINEAR_RETRY_DELAYS="0 0 0" HOME="$TMP_ROOT/home" \
  bash "$stub_root/scripts/e2e-preflight.sh" INIT-9 --out "$out" --skip-critique </dev/null 2>/dev/null)
codes=$(cell "$out" INIT-9 blocked-edges 4)
grep -q 'BLOCKER_OUTSIDE_INITIATIVE:WIL-1<-CRE-77' <<<"$codes" && ok "blocker outside initiative flagged" ||
  nok "outside-initiative: $codes"
grep -q 'BLOCKED_WITHOUT_EDGE:WIL-2<-WIL-1' <<<"$codes" && ok "block without manifest edge flagged" ||
  nok "no-edge: $codes"
grep -q 'NO_SUMMARY' <<<"$(cell "$out" INIT-9 dry-run 4)" && ok "missing summary line → NO_SUMMARY" ||
  nok "summary: $(cell "$out" INIT-9 dry-run 4)"

# ── 8. usage / environment → exit 2 ──────────────────────────────────────────
REPOS_ROOT="$(fixture usage)" bash "$PF" INIT-404 --out "$TMP_ROOT/out-404" >/dev/null 2>"$TMP_ROOT/err404"
rc=$?
[ "$rc" -eq 2 ] && grep -q 'INIT-404/epic/manifest.json' "$TMP_ROOT/err404" && ok "unknown INIT → exit 2 naming the path" ||
  nok "unknown INIT: rc=$rc"
env -u REPOS_ROOT bash "$PF" INIT-9 >/dev/null 2>&1
[ $? -eq 2 ] && ok "REPOS_ROOT unset → exit 2" || nok "REPOS_ROOT unset accepted"
bash "$PF" >/dev/null 2>&1
[ $? -eq 2 ] && ok "no INIT → exit 2" || nok "no INIT accepted"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
