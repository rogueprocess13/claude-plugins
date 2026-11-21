#!/usr/bin/env bash
# test-fast-path-threshold.sh — the per-project appraise fast-path confidence
# threshold (GitHub #774): lib/fast-path-threshold.sh, its one consumer
# check_fast_path_eligible (lib/appraise-fast-path.sh), and the
# /ticket-env-check row.
# Usage: bash test-fast-path-threshold.sh
# -u intentionally omitted (see test-appraise-fast-path.sh).
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

exec </dev/null

if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() { echo '{"description":"","labels":{"nodes":[]}}'; }
fi

# The field under test must come only from what each case sets.
unset FAST_PATH_CONFIDENCE_THRESHOLD REPOS_ROOT LOG_FILE TAP_LOG TICKET_ID
export PLANNED_TICKET_MIN_CONFIDENCE="0.50"

source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/appraise-fast-path.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
_ok() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_ko() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}
_eq() {
  if [ "$2" = "$3" ]; then _ok "$1"; else _ko "$1 (expected '$2', got '$3')"; fi
}

# _project <name> [threshold line] — a project dir whose CLAUDE.md optionally
# declares the field. Prints the dir.
_project() {
  local d="$T/$1"
  mkdir -p "$d"
  printf 'REPOS_ROOT = %s\nLOCAL_URL = http://localhost:3000\n' "$d" >"$d/CLAUDE.md"
  [ -z "${2:-}" ] || printf '%s\n' "$2" >>"$d/CLAUDE.md"
  printf '%s\n' "$d"
}

# A planned, not pre-approved ticket body at the given confidence.
_desc() {
  cat <<BLOCK
Some ticket body.

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-1
**Epic:** TEST-100
**Confidence:** $1
**Strategy:** Conservative
**Decision:** Add one endpoint
**Affected Services:** svc-a
**Target Symbols:** Thing.run:src/thing.ts:10
**Pre-approved:** ${2:-false}
**Generated:** 2026-01-01T00:00:00Z
**Regenerate:** false
BLOCK
}

# _decide <confidence> — runs the real check; prints eligible|reason|threshold|source
_decide() {
  check_fast_path_eligible "TEST-1" "$(_desc "$1" "${2:-false}")" "true" 2>/dev/null || true
  printf '%s|%s|%s|%s\n' "$FAST_PATH_ELIGIBLE" "$FAST_PATH_REASON" \
    "${FAST_PATH_THRESHOLD:-}" "${FAST_PATH_THRESHOLD_SOURCE:-}"
}

echo "=== validation ==="
for v in 0.60 0.6 0.75 0.85 0.999 1 1.0 1.00; do
  if fast_path_threshold_valid "$v"; then _ok "valid: $v"; else _ko "valid: $v"; fi
done
for v in 0 0.0 0.5 0.59 0.599 1.01 2 -0.8 .8 80 80% 0,8 abc "" "0.8 " "0.8;id" 1e-1 0x1 +0.8; do
  if fast_path_threshold_valid "$v"; then _ko "invalid: '$v' was accepted"; else _ok "invalid: '$v'"; fi
done

echo "=== unset = default ==="
(
  P=$(_project unset)
  export REPOS_ROOT="$P"
  _eq "unset: 0.84 refused at the default" "false|confidence_below_threshold|0.85|default" "$(_decide 0.84)"
  _eq "unset: 0.80 refused at the default" "false|confidence_below_threshold|0.85|default" "$(_decide 0.80)"
  _eq "unset: 0.85 takes the fast path" "true|confidence_met|0.85|default" "$(_decide 0.85)"
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== no REPOS_ROOT, no env = default ==="
_eq "nothing resolvable: default" "false|confidence_below_threshold|0.85|default" "$(_decide 0.80)"

echo "=== CLAUDE.md lowers the bar ==="
(
  P=$(_project lowered 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.75')
  export REPOS_ROOT="$P"
  _eq "CLAUDE.md 0.75: a 0.80 ticket takes the fast path" "true|confidence_met|0.75|CLAUDE.md" "$(_decide 0.80)"
  _eq "CLAUDE.md 0.75: 0.75 is at the threshold" "true|confidence_met|0.75|CLAUDE.md" "$(_decide 0.75)"
  _eq "CLAUDE.md 0.75: 0.74 is still refused" "false|confidence_below_threshold|0.75|CLAUDE.md" "$(_decide 0.74)"
  # The validator's own floor is untouched by this field.
  check_fast_path_eligible "TEST-1" "$(_desc 0.40)" "true" 2>/dev/null || true
  _eq "CLAUDE.md 0.75: 0.40 still stops at the validator floor" "low_confidence_not_preapproved" "$FAST_PATH_REASON"
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== backticked CLAUDE.md form ==="
(
  P=$(_project backtick '`FAST_PATH_CONFIDENCE_THRESHOLD`: `0.7`')
  export REPOS_ROOT="$P"
  _eq "backticked 0.7: a 0.71 ticket takes the fast path" "true|confidence_met|0.7|CLAUDE.md" "$(_decide 0.71)"
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== env beats CLAUDE.md ==="
(
  P=$(_project envwins 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.70')
  export REPOS_ROOT="$P"
  export FAST_PATH_CONFIDENCE_THRESHOLD=0.90
  _eq "env 0.90 over CLAUDE.md 0.70: 0.85 refused" "false|confidence_below_threshold|0.90|env" "$(_decide 0.85)"
  export FAST_PATH_CONFIDENCE_THRESHOLD=0.65
  _eq "env 0.65 over CLAUDE.md 0.70: 0.66 passes" "true|confidence_met|0.65|env" "$(_decide 0.66)"
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== invalid value warns and keeps the default ==="
for bad in 0 0.3 0.59 1.5 abc 80%; do
  (
    P=$(_project "bad-md" "FAST_PATH_CONFIDENCE_THRESHOLD = $bad")
    export REPOS_ROOT="$P"
    _eq "CLAUDE.md '$bad': 0.80 refused at the default" "false|confidence_below_threshold|0.85|default" "$(_decide 0.80)"
    err=$(fast_path_threshold_resolve 2>&1 >/dev/null)
    case "$err" in
    *"'$bad' (CLAUDE.md)"*"ignored"*"0.85"*) _ok "CLAUDE.md '$bad': warning names the value and the default" ;;
    *) _ko "CLAUDE.md '$bad': no warning ($err)" ;;
    esac
    echo "$PASS $FAIL" >"$T/counts"
  )
  read -r PASS FAIL <"$T/counts"
  rm -rf "$T/bad-md"
done
(
  # An invalid env value must not fall through to a lower CLAUDE.md value.
  P=$(_project bad-env 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.70')
  export REPOS_ROOT="$P"
  export FAST_PATH_CONFIDENCE_THRESHOLD=0.2
  _eq "invalid env does not fall through to CLAUDE.md" "false|confidence_below_threshold|0.85|default" "$(_decide 0.80)"
  fast_path_threshold_resolve 2>/dev/null
  _eq "invalid env: rejected value recorded" "0.2|env" "$FAST_PATH_THRESHOLD_REJECTED|$FAST_PATH_THRESHOLD_REJECTED_SOURCE"
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== pre-approved is unaffected ==="
(
  P=$(_project preapproved 'FAST_PATH_CONFIDENCE_THRESHOLD = 1.0')
  export REPOS_ROOT="$P"
  check_fast_path_eligible "TEST-1" "$(_desc 0.90 true)" "true" 2>/dev/null || true
  _eq "threshold 1.0: a pre-approved ticket still takes the fast path" "true|pre_approved" "$FAST_PATH_ELIGIBLE|$FAST_PATH_REASON"
  _eq "threshold 1.0: 0.95 not pre-approved is refused" "false|confidence_below_threshold|1.0|CLAUDE.md" "$(_decide 0.95)"
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== sourcing assigns nothing ==="
(
  unset FAST_PATH_CONFIDENCE_THRESHOLD
  source "$LIB_DIR/appraise-fast-path.sh"
  if [ -z "${FAST_PATH_CONFIDENCE_THRESHOLD+set}" ]; then
    _ok "sourcing leaves FAST_PATH_CONFIDENCE_THRESHOLD unset"
  else
    _ko "sourcing set FAST_PATH_CONFIDENCE_THRESHOLD"
  fi
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== the decision is logged with its threshold ==="
(
  P=$(_project logged 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.75')
  export REPOS_ROOT="$P"
  export LOG_FILE="$T/TEST-1-pipeline.log"
  : >"$LOG_FILE"
  _decide 0.80 >/dev/null
  line=$(grep '|META|fast-path-threshold|' "$LOG_FILE" | tail -1)
  case "$line" in
  *"|META|fast-path-threshold|warn|threshold=0.75 source=CLAUDE.md default=0.85 confidence=0.80 result=confidence_met") _ok "lowered: warn line with threshold, source, default, confidence, result" ;;
  *) _ko "lowered: log line ($line)" ;;
  esac
  _decide 0.70 >/dev/null
  line=$(grep '|META|fast-path-threshold|' "$LOG_FILE" | tail -1)
  case "$line" in
  *"|warn|threshold=0.75 source=CLAUDE.md default=0.85 confidence=0.70 result=confidence_below_threshold") _ok "lowered: a refusal is logged too" ;;
  *) _ko "lowered: refusal log line ($line)" ;;
  esac

  : >"$LOG_FILE"
  export REPOS_ROOT="$(_project logged-default)"
  _decide 0.80 >/dev/null
  line=$(grep '|META|fast-path-threshold|' "$LOG_FILE" | tail -1)
  case "$line" in
  *"|META|fast-path-threshold|info|threshold=0.85 source=default default=0.85 confidence=0.80 result=confidence_below_threshold") _ok "default: info line" ;;
  *) _ko "default: log line ($line)" ;;
  esac

  : >"$LOG_FILE"
  export FAST_PATH_CONFIDENCE_THRESHOLD=0.1
  _decide 0.80 >/dev/null
  line=$(grep '|META|fast-path-threshold|' "$LOG_FILE" | tail -1)
  case "$line" in
  *"|warn|threshold=0.85 source=default default=0.85 rejected=0.1(env) confidence=0.80 result=confidence_below_threshold") _ok "invalid: warn line names the rejected value" ;;
  *) _ko "invalid: log line ($line)" ;;
  esac
  unset FAST_PATH_CONFIDENCE_THRESHOLD

  : >"$LOG_FILE"
  check_fast_path_eligible "TEST-1" "$(_desc 0.90 true)" "true" 2>/dev/null || true
  _eq "pre-approved: no threshold line (nothing was compared)" "0" "$(grep -c 'fast-path-threshold' "$LOG_FILE" || true)"
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== notes.md names a threshold that let a ticket through ==="
(
  P=$(_project notes 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.75')
  export REPOS_ROOT="$P"
  mkdir -p "$T/td"
  check_fast_path_eligible "TEST-1" "$(_desc 0.80)" "true" 2>/dev/null || true
  generate_fast_path_notes "$T/td" "TEST-1"
  if grep -qxF -- '- Fast-path confidence threshold: 0.75 (source: CLAUDE.md; default 0.85).' "$T/td/notes.md"; then
    _ok "notes.md Session Log carries the threshold line"
  else
    _ko "notes.md has no threshold line"
  fi
  check_fast_path_eligible "TEST-1" "$(_desc 0.90 true)" "true" 2>/dev/null || true
  generate_fast_path_notes "$T/td" "TEST-1"
  _eq "pre-approved notes.md has no threshold line" "0" "$(grep -c 'confidence threshold' "$T/td/notes.md" || true)"
  echo "$PASS $FAIL" >"$T/counts"
)
read -r PASS FAIL <"$T/counts"

echo "=== env-check row ==="
_row() { fast_path_threshold_env_check_row "$1"; }
P=$(_project row-unset)
_eq "row: unset prints nothing" "" "$(_row "$P")"
P=$(_project row-low 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.75')
r=$(_row "$P")
_eq "row: lowered is a warn from CLAUDE.md" "FAST_PATH_CONFIDENCE_THRESHOLD|warn|0.75|CLAUDE.md" "$(printf '%s' "$r" | cut -d'|' -f1-4)"
case "$r" in *"below the default 0.85"*) _ok "row: lowered note names the default" ;; *) _ko "row: lowered note ($r)" ;; esac
P=$(_project row-same 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.85')
_eq "row: equal to the default is ok" "FAST_PATH_CONFIDENCE_THRESHOLD|ok|0.85|CLAUDE.md" "$(_row "$P" | cut -d'|' -f1-4)"
P=$(_project row-high 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.9')
_eq "row: raised is info" "FAST_PATH_CONFIDENCE_THRESHOLD|info|0.9|CLAUDE.md" "$(_row "$P" | cut -d'|' -f1-4)"
P=$(_project row-bad 'FAST_PATH_CONFIDENCE_THRESHOLD = 0')
r=$(_row "$P")
_eq "row: invalid is a warn" "FAST_PATH_CONFIDENCE_THRESHOLD|warn|0|CLAUDE.md" "$(printf '%s' "$r" | cut -d'|' -f1-4)"
case "$r" in *"ignored"*"0.85"*) _ok "row: invalid note says the default applies" ;; *) _ko "row: invalid note ($r)" ;; esac
P=$(_project row-env 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.9')
_eq "row: env beats CLAUDE.md" "FAST_PATH_CONFIDENCE_THRESHOLD|warn|0.7|env" \
  "$(FAST_PATH_CONFIDENCE_THRESHOLD=0.7 fast_path_threshold_env_check_row "$P" | cut -d'|' -f1-4)"

echo "=== env-check.sh prints the row in both modes ==="
# Hermetic env-check run, as test-env-check.sh does it.
export ENV_CHECK_JGIT_LOCK_ROOT="$T/lockroot"
export ENV_CHECK_SKIP_LINEAR=1
export ENV_CHECK_USER_SKILLS_DIR="$T/userskills"
mkdir -p "$ENV_CHECK_JGIT_LOCK_ROOT" "$ENV_CHECK_USER_SKILLS_DIR" "$T/bin"
printf '#!/bin/sh\nexit 7\n' >"$T/bin/curl"
chmod +x "$T/bin/curl"
_ec() {
  (
    export PATH="$T/bin:$PATH"
    unset FAST_PATH_CONFIDENCE_THRESHOLD
    bash "$LIB_DIR/env-check.sh" --mode="$1" "$2" 2>/dev/null || true
  )
}
P=$(_project ec-low 'FAST_PATH_CONFIDENCE_THRESHOLD = 0.75')
out=$(_ec full "$P")
if printf '%s\n' "$out" | grep -q '^FAST_PATH_CONFIDENCE_THRESHOLD|warn|0.75|CLAUDE.md|below the default 0.85'; then
  _ok "full mode: warn row when lowered"
else
  _ko "full mode: no warn row"
fi
out=$(_ec validate "$P")
if printf '%s\n' "$out" | grep 'FAST_PATH_CONFIDENCE_THRESHOLD (0.75 via CLAUDE.md)' | grep -q 'warn'; then
  _ok "validate mode: warn line when lowered"
else
  _ko "validate mode: no warn line"
fi
P=$(_project ec-unset)
out=$(_ec full "$P")
_eq "full mode: silent when unset" "0" "$(printf '%s\n' "$out" | grep -c 'FAST_PATH_CONFIDENCE_THRESHOLD' || true)"
out=$(_ec validate "$P")
_eq "validate mode: silent when unset" "0" "$(printf '%s\n' "$out" | grep -c 'FAST_PATH_CONFIDENCE_THRESHOLD' || true)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
