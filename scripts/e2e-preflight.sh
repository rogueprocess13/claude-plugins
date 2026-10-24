#!/usr/bin/env bash
# e2e-preflight.sh — dispatch-rehearsal preflight for one planned initiative
# (dispatch-rehearsal-preflight). Runs every check that would block a planned
# ticket before its first agent phase, plus fleet dry-run, and writes one
# diffable TSV. Adds no gate logic of its own: every row calls the function
# the pipeline itself calls, so the preflight cannot disagree with it.
#
# Usage:
#   e2e-preflight.sh <INIT> [--out DIR] [--critique-dir DIR] [--skip-critique]
#
#   <INIT>   directory name under $REPOS_ROOT/.ticket-auto/initiatives/ that
#            holds epic/manifest.json
#   --out    output directory (default ./preflight-<INIT>)
#   --critique-dir  where `/ticket-critique <TID> --no-post --result-file
#            <dir>/<TID>.txt` results live (default <out>/critique)
#   --skip-critique  write critique rows as `skip`; verdict becomes PARTIAL
#
# Rows (<out>/preflight.tsv, TID<TAB>check<TAB>rc<TAB>codes):
#   per child: manifest, body, gate-planned, dor, critique
#   epic (TID = <INIT>): dispatch-flag, dry-run, blocked-edges
#
# Libs: every check runs this checkout's ticket-auto-pipeline/lib, never the
# copy synced into ~/.claude/skills/lib (CLAUDE_SKILLS_LIB for gate-check,
# pre-sourced declare-guarded libs for dispatch) — the rehearsal tests the
# branch under development.
#
# Side effects: none on the tracker. gate-check reads Linear (get_issue);
# fleet dry-run caches each child's `ready` verdict in its manifest and runs
# `git fetch` in repos under REPOS_ROOT, exactly as a real dry-run does.
# `dispatch` is read, never written.
#
# Exit: 0 PASS or PARTIAL, 1 FAIL (any row failed), 2 usage/environment.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_LIB="$ROOT/ticket-auto-pipeline/lib"
FC_LIB="$ROOT/fleet-controller/lib"

die() {
  echo "e2e-preflight: $1" >&2
  exit 2
}

INIT="" OUT="" CRIT_DIR="" SKIP_CRITIQUE=0
while [ $# -gt 0 ]; do
  case "$1" in
  --out)
    OUT="${2:-}"
    shift 2 || die "--out requires a value"
    ;;
  --critique-dir)
    CRIT_DIR="${2:-}"
    shift 2 || die "--critique-dir requires a value"
    ;;
  --skip-critique)
    SKIP_CRITIQUE=1
    shift
    ;;
  -*) die "unknown option: $1" ;;
  *)
    [ -z "$INIT" ] || die "unexpected argument: $1"
    INIT="$1"
    shift
    ;;
  esac
done

[ -n "$INIT" ] || die "usage: e2e-preflight.sh <INIT> [--out DIR] [--critique-dir DIR] [--skip-critique]"
[ -n "${REPOS_ROOT:-}" ] || die "REPOS_ROOT is not set"
export REPOS_ROOT
EPIC_MANIFEST="$REPOS_ROOT/.ticket-auto/initiatives/$INIT/epic/manifest.json"
[ -f "$EPIC_MANIFEST" ] || die "no epic manifest: $EPIC_MANIFEST"
jq -e . "$EPIC_MANIFEST" >/dev/null 2>&1 || die "malformed epic manifest: $EPIC_MANIFEST"
for f in "$TAP_LIB/manifest-read.sh" "$TAP_LIB/planned-ticket-body-check.sh" "$TAP_LIB/dor-check.sh" \
  "$TAP_LIB/gate-check.sh" "$FC_LIB/fleet-dispatch.sh"; do
  [ -f "$f" ] || die "missing lib: $f"
done

OUT="${OUT:-./preflight-$INIT}"
CRIT_DIR="${CRIT_DIR:-$OUT/critique}"
mkdir -p "$OUT/logs" "$CRIT_DIR" 2>/dev/null && [ -w "$OUT" ] || die "--out not writable: $OUT"
OUT="$(cd "$OUT" && pwd)"
TSV="$OUT/preflight.tsv"
printf 'TID\tcheck\trc\tcodes\n' >"$TSV"

ROWS=0 FAILED=0
# row <tid> <check> <rc|skip> <codes>
row() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$TSV"
  ROWS=$((ROWS + 1))
  case "$3" in 0 | skip) ;; *) FAILED=$((FAILED + 1)) ;; esac
}

# ── per-ticket checks (each lib sourced in its own subshell) ─────────────────

ticket_manifest_path() {
  (
    source "$TAP_LIB/manifest-read.sh" >/dev/null 2>&1
    get_ticket_manifest_path "$1" 2>/dev/null
  )
}

check_body() {
  local tid="$1" type="$2" body="$3"
  (
    source "$TAP_LIB/manifest-read.sh" >/dev/null 2>&1
    source "$TAP_LIB/planned-ticket-body-check.sh" >/dev/null 2>&1
    # A non-empty description keeps check_planned_body off the tracker; it
    # re-resolves the same planner body.md through the Planner Context block.
    check_planned_body "$tid" "$type" "$(cat "$body")" "true" >/dev/null 2>&1
    printf '%s\t%s\n' "${BODY_CHECK_EXIT_CODE:-2}" "${BODY_CHECK_MISSING:-}"
  )
}

check_dor() {
  local tid="$1" type="$2" body="$3"
  (
    source "$TAP_LIB/dor-check.sh" >/dev/null 2>&1
    rc=0
    DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true \
      check_ticket_ready "$tid" --body "$body" --type "$type" --no-fetch >/dev/null 2>&1 || rc=$?
    printf '%s\t%s\n' "$rc" "$(jq -r 'join(",")' <<<"${DOR_MISSING:-[]}" 2>/dev/null)"
  )
}

# gate-check exits 0 both on a real pass and when it checked nothing (ticket
# not planned, or the Linear fetch failed), so the log line decides.
check_gate_planned() {
  local tid="$1" log="$OUT/logs/$1-preflight.log" hb="$OUT/logs/$1-preflight-hb.log"
  rm -f "$log" "$hb"
  local rc=0
  CLAUDE_SKILLS_LIB="$TAP_LIB" bash "$TAP_LIB/gate-check.sh" "$tid" "$log" "$hb" --mode planned >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    if grep -q '|GATE|planned-precheck|done|' "$log" 2>/dev/null; then
      printf '0\t\n'
    elif grep -q '|GATE|planned-precheck|skip|' "$log" 2>/dev/null; then
      printf '1\tGATE_FETCH_DEFERRED\n'
    else
      printf '1\tGATE_NOT_PLANNED\n'
    fi
  else
    local code
    code=$(grep '|META|gate-stop|fail|' "$log" 2>/dev/null | tail -1 |
      awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' | awk '{print $1}')
    printf '%s\t%s\n' "$rc" "${code:-GATE_EXIT_$rc}"
  fi
}

check_critique() {
  local f="$CRIT_DIR/$1.txt"
  if [ ! -f "$f" ] || [ "$(head -1 "$f")" != "=== CRITIQUE_RESULT ===" ] ||
    [ "$(tail -1 "$f")" != "=== END CRITIQUE_RESULT ===" ]; then
    printf '1\tCRITIQUE_RESULT_MISSING\n'
    return
  fi
  local status reason
  status=$(sed -n 's/^STATUS: //p' "$f" | head -1)
  reason=$(sed -n 's/^BLOCK_REASON: //p' "$f" | head -1)
  case "$status" in
  CLEAR | WARNINGS) printf '0\t%s\n' "$status" ;;
  BLOCKED) printf '1\tCRITIQUE_BLOCKED:%s\n' "${reason:-unknown}" ;;
  UNAVAILABLE) printf '1\tCRITIQUE_UNAVAILABLE\n' ;;
  *) printf '1\tCRITIQUE_RESULT_MISSING\n' ;;
  esac
}

# split "<rc>\t<codes>" into a row
emit() {
  local tid="$1" check="$2" res="$3"
  row "$tid" "$check" "${res%%$'\t'*}" "${res#*$'\t'}"
}

CHILDREN=$(jq -r '.children[]? // empty' "$EPIC_MANIFEST")

for tid in $CHILDREN; do
  mpath=$(ticket_manifest_path "$tid")
  if [ -z "$mpath" ] || [ ! -f "$mpath" ]; then
    row "$tid" manifest 1 MANIFEST_MISSING
    continue
  fi
  row "$tid" manifest 0 ""
  type=$(jq -r '.type // ""' "$mpath")
  body="$(dirname "$mpath")/body.md"
  if [ -s "$body" ]; then
    emit "$tid" body "$(check_body "$tid" "$type" "$body")"
  else
    row "$tid" body 1 BODY_MD_MISSING
  fi
  emit "$tid" gate-planned "$(check_gate_planned "$tid")"
  if [ -s "$body" ]; then
    emit "$tid" dor "$(check_dor "$tid" "$type" "$body")"
  else
    row "$tid" dor 1 BODY_MD_MISSING
  fi
  if [ "$SKIP_CRITIQUE" -eq 1 ]; then
    row "$tid" critique skip ""
  else
    emit "$tid" critique "$(check_critique "$tid")"
  fi
done

# ── epic rows ────────────────────────────────────────────────────────────────

dispatch=$(jq -r 'if has("dispatch") then (.dispatch | tostring) else "absent" end' "$EPIC_MANIFEST")
if [ "$dispatch" = "true" ]; then
  row "$INIT" dispatch-flag 0 ""
else
  row "$INIT" dispatch-flag 1 "EPIC_NOT_DISPATCHABLE:$dispatch"
fi

DRY="$OUT/dispatch-dry-run.txt"
WS="${FLEET_PIPELINE_LOG_DIR:-$OUT/logs}"
(
  export FLEET_DRY_RUN=true FLEET_PIPELINE_LOG_DIR="$WS"
  # Pre-source this checkout's libs; fleet-dispatch.sh only sources a lib
  # whose functions are not already declared.
  for l in linear-api manifest-read dor-check; do source "$TAP_LIB/$l.sh" >/dev/null 2>&1; done
  set +eo pipefail
  source "$FC_LIB/fleet-dispatch.sh" >/dev/null 2>&1
  fleet_dispatch_initiative "$INIT" "$WS"
) 2>&1 | sed -E 's/"timestamp":"[^"]*"/"timestamp":"-"/g' >"$DRY"

dry_codes=()
while read -r t; do dry_codes+=("NOT_READY:$t"); done < <(sed -nE 's/^ +not-ready ([^ ]+).*/\1/p' "$DRY")
while read -r t; do dry_codes+=("SKIP:$t"); done < <(sed -nE 's/^ +skip ([^ ]+).*/\1/p' "$DRY")
grep -q 'EPIC_BRANCH_UNAVAILABLE' "$DRY" && dry_codes+=("EPIC_BRANCH_UNAVAILABLE")
grep -q 'no local epic manifest' "$DRY" && dry_codes+=("NO_EPIC_MANIFEST")
summary=$(grep -E '^\[DRY-RUN\] would resume [0-9]+ \| blocked [0-9]+ \| not_ready [0-9]+' "$DRY" | tail -1)
if [ -z "$summary" ]; then
  dry_codes+=("NO_SUMMARY")
else
  nr=$(sed -E 's/.*not_ready ([0-9]+).*/\1/' <<<"$summary")
  [ "$nr" -gt 0 ] && dry_codes+=("NOT_READY_COUNT:$nr")
fi
if [ "${#dry_codes[@]}" -eq 0 ]; then
  row "$INIT" dry-run 0 ""
else
  row "$INIT" dry-run 1 "$(
    IFS=,
    echo "${dry_codes[*]}"
  )"
fi

# Every `blocked by <B>` must name a sibling the blocked ticket's manifest
# lists. The current ticket is the last `checking <TID>` line above it.
edge_codes=()
current=""
while IFS= read -r line; do
  if [[ "$line" =~ ^\ +checking\ ([^ ]+) ]]; then
    current="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^\ +blocked\ by\ ([^ ]+) ]]; then
    blocker="${BASH_REMATCH[1]}"
    if ! grep -qx "$blocker" <<<"$CHILDREN"; then
      edge_codes+=("BLOCKER_OUTSIDE_INITIATIVE:$current<-$blocker")
      continue
    fi
    mpath=$(ticket_manifest_path "$current")
    if [ -z "$mpath" ] || ! jq -e --arg b "$blocker" '(.blocked_by // []) | index($b) != null' "$mpath" >/dev/null 2>&1; then
      edge_codes+=("BLOCKED_WITHOUT_EDGE:$current<-$blocker")
    fi
  fi
done <"$DRY"
if [ "${#edge_codes[@]}" -eq 0 ]; then
  row "$INIT" blocked-edges 0 ""
else
  row "$INIT" blocked-edges 1 "$(
    IFS=,
    echo "${edge_codes[*]}"
  )"
fi

# ── verdict ──────────────────────────────────────────────────────────────────

if [ "$FAILED" -gt 0 ]; then
  verdict=FAIL
elif [ "$SKIP_CRITIQUE" -eq 1 ]; then
  verdict=PARTIAL
else
  verdict=PASS
fi
line="PREFLIGHT $INIT $verdict rows=$ROWS failed=$FAILED"
echo "$line" >"$OUT/verdict.txt"
echo "$line"
[ "$verdict" = FAIL ] && exit 1
exit 0
