#!/usr/bin/env bash
# test-planner-specify-params.sh — Tests for planner-specify-params.sh
# (planner-specify-parameters, tasks 2.1–2.4, 8.2).
#
# Pinned here:
#   1. The registry parse: a well-formed table, `None.`, an empty section,
#      fence-awareness, `\|` in a cell, and every invalid-row reason.
#   2. Anchors: artifact quotes (re-wrapped, missing, without the Value's
#      number, too short), code quotes, and `human:` against the round file.
#   3. Which rows are open: kinds, the keyword table, question, suggestion,
#      id, and silence for a legacy (non-contract) initiative.
#   4. The literal tokenizer and canonical forms.
#   5. Row rendering and substitution (rc 2 on a stale target, injection).
#   6. mawk runs every awk program, and gawk (when installed) agrees.
#   7. The Specify and Consensus prompt wording (task 8.2), and the
#      planner-crosscheck-ownership insertions (Specify, Consensus, TicketGen;
#      that change's task 6.2) and the planner-ac-code-precondition
#      insertions (Specify, Consensus; that change's task 5.4): no residue
#      once stripped.
#
# Every case is guarded on the functions it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary, never an
# unbound-function abort.
#
# Run: bash ticket-planner/lib/tests/test-planner-specify-params.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SP_LIB="${LIB_DIR}/planner-specify-params.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-specify-decisions.sh"
if [ -f "$SP_LIB" ]; then
  source "$SP_LIB"
fi
# The ownership prompt wording (planner-crosscheck-ownership, task 6.2).
source "${LIB_DIR}/planner-spec-ownership.sh"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}
need() {
  local name="$1" fn
  shift
  for fn in "$@"; do
    if ! declare -f "$fn" >/dev/null; then
      fail "$name" "$fn missing"
      return 1
    fi
  done
  return 0
}
# check <name> <got> <want>
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}

N=0
# fresh [legacy] — a new initiative; a contract one unless "legacy" is given.
fresh() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((5000 + N))"
  planner_state_init "$INIT" "billing export" >/dev/null
  IDIR=$(planner_initiative_dir "$INIT")
  PROP="${IDIR}/artifacts/proposal.md"
  mkdir -p "${IDIR}/artifacts"
  if [ "${1:-}" != legacy ] && declare -f planner_params_contract_mark >/dev/null; then
    planner_params_contract_mark "$INIT"
  fi
}
prop() { cat >"$PROP"; }

HDR='| Name | Key | Kind | Default | Value | Source |
|------|-----|------|---------|-------|--------|'

# ── 1. Parse ──────────────────────────────────────────────────────────────────

echo "=== parse ==="

name="well-formed table: valid rows listed, nothing invalid"
if need "$name" planner_params_rows planner_params_invalid; then
  fresh
  prop <<EOF
# Proposal

## Business Outcomes

### O1
**Outcome:** Accountants export invoices.

## Parameters

${HDR}
| Idle session timeout | \`auth.session_idle_minutes\` | duration | 30 minutes | 30 minutes | default |
| Provider API timeout | \`payments.provider_timeout\` | fixed | — | 10 seconds | discovery:"the provider closes the connection after 10 seconds" |

## Risks
EOF
  rows=$(planner_params_rows "$INIT")
  want=$(printf '12\tauth.session_idle_minutes\tduration\tIdle session timeout\t30 minutes\t30 minutes\tdefault\n13\tpayments.provider_timeout\tfixed\tProvider API timeout\t—\t10 seconds\tdiscovery:"the provider closes the connection after 10 seconds"')
  check "$name" "$rows|$(planner_params_invalid "$INIT")" "$want|"
fi

name="None. is a valid empty registry"
if need "$name" planner_params_rows planner_params_invalid; then
  fresh
  prop <<'EOF'
## Parameters

None.

## Risks
EOF
  check "$name" "$(planner_params_rows "$INIT")|$(planner_params_invalid "$INIT")" "|"
fi

name="empty section is invalid (empty)"
if need "$name" planner_params_invalid; then
  fresh
  prop <<'EOF'
## Parameters

## Risks
EOF
  check "$name" "$(planner_params_invalid "$INIT")" "$(printf '1\tempty')"
fi

name="missing section is invalid (missing, line 0)"
if need "$name" planner_params_invalid; then
  fresh
  printf '## Business Outcomes\n' | prop
  check "$name" "$(planner_params_invalid "$INIT")" "$(printf '0\tmissing')"
fi

name="prose before the table is invalid (no-table)"
if need "$name" planner_params_invalid planner_params_rows; then
  fresh
  prop <<EOF
## Parameters
These are the values.
${HDR}
| A | \`a.b\` | duration | 1 day | 1 day | default |
EOF
  check "$name" "$(planner_params_invalid "$INIT")|$(planner_params_rows "$INIT")" "$(printf '2\tno-table')|"
fi

name="fenced heading and fenced table are ignored"
if need "$name" planner_params_rows planner_params_invalid; then
  fresh
  prop <<EOF
\`\`\`
## Parameters
${HDR}
| A | \`fenced.key\` | duration | 1 day | 1 day | default |
\`\`\`
## Parameters

${HDR}
| B | \`real.key\` | limit | 50 | 50 | default |
EOF
  check "$name" "$(planner_params_rows "$INIT" | cut -f1,2)|$(planner_params_invalid "$INIT")" "$(printf '11\treal.key')|"
fi

name="escaped pipe stays inside its cell"
if need "$name" planner_params_rows; then
  fresh
  prop <<EOF
## Parameters

${HDR}
| Separator | \`export.sep\` | policy | a \\| b | a \\| b | default |
EOF
  check "$name" "$(planner_params_rows "$INIT" | cut -f5,6)" "$(printf 'a | b\ta | b')"
fi

name="bad header makes every row invalid (header)"
if need "$name" planner_params_invalid; then
  fresh
  prop <<'EOF'
## Parameters

| Name | Key | Kind | Value | Source |
|---|---|---|---|---|
| A | `a.b` | duration | 1 day | default |
EOF
  check "$name" "$(planner_params_invalid "$INIT")" "$(printf '3\theader\n5\theader')"
fi

name="invalid rows listed with their reasons"
if need "$name" planner_params_invalid planner_params_rows; then
  fresh
  k65="a$(printf 'b%.0s' $(seq 1 64))"
  k64="a$(printf 'b%.0s' $(seq 1 63))"
  prop <<EOF
## Parameters

${HDR}
| Rounding | \`billing.total_rounding\` | rounding | half-up | half-up | default |
| Rounding again | \`billing.total_rounding\` | rounding | x | x | default |
| Other | \`misc.other\` | other | x | x | default |
| Long | \`${k65}\` | limit | 5 | 5 | default |
| Long ok | \`${k64}\` | limit | 5 | 5 | default |
| Intent | \`a.intent\` | policy | x | x | intent |
| Code up | \`a.code\` | fixed | x | x | code:../etc/passwd:"some quote here" |
| Code abs | \`a.abs\` | fixed | x | x | code:/etc/passwd:"some quote here" |
| Dash | \`a.dash\` | policy | x | x | — |
| Bare key | a.bare | policy | x | x | default |
| Short | \`a.short\` | policy | x | x |
| Human bad | \`a.human\` | policy | x | x | human:r0:client |
| Human role | \`a.role\` | policy | x | x | human:r1:boss |
| Empty value | \`a.empty\` | policy | x |  | default |
EOF
  want=$(printf '6\tduplicate-key\n7\tkind\n8\tkey\n10\tsource\n11\tsource\n12\tsource\n13\tsource\n14\tkey\n15\tshape\n16\tsource\n17\tsource\n18\tvalue')
  got=$(planner_params_invalid "$INIT")
  if [ "$got" = "$want" ] && [ "$(planner_params_rows "$INIT" | cut -f1 | tr '\n' ' ')" = "5 9 " ]; then
    pass "$name"
  else
    fail "$name" "invalid [$got] rows [$(planner_params_rows "$INIT" | cut -f1 | tr '\n' ' ')]"
  fi
fi

name="a second ## Parameters heading is invalid (duplicate-section)"
if need "$name" planner_params_invalid; then
  fresh
  prop <<'EOF'
## Parameters

None.

## Parameters

None.
EOF
  check "$name" "$(planner_params_invalid "$INIT")" "$(printf '5\tduplicate-section')"
fi

# ── 2. Anchors ────────────────────────────────────────────────────────────────

echo "=== anchors ==="

anchor() { planner_params_anchor_ok "$INIT" "$@"; }

name="artifact quote found across different line wrapping"
if need "$name" planner_params_anchor_ok; then
  fresh
  printf 'Notes. Because\nthe provider closes the\n   connection after 10 seconds, always.\n' >"${IDIR}/artifacts/discovery.md"
  if anchor payments.provider_timeout "10 seconds" 'discovery:"the provider closes the connection after 10 seconds"'; then
    pass "$name"
  else fail "$name" "rc 1"; fi
fi

name="quote not in the file does not verify"
if need "$name" planner_params_anchor_ok; then
  if ! anchor payments.provider_timeout "10 seconds" 'discovery:"the provider never closes anything at all"'; then
    pass "$name"
  else fail "$name" "rc 0"; fi
fi

name="quote is case-sensitive"
if need "$name" planner_params_anchor_ok; then
  if ! anchor payments.provider_timeout "10 seconds" 'discovery:"The Provider closes the connection after 10 seconds"'; then
    pass "$name"
  else fail "$name" "rc 0"; fi
fi

name="quote without the Value's number does not verify"
if need "$name" planner_params_anchor_ok; then
  if ! anchor payments.provider_timeout "10 seconds" 'discovery:"the provider closes the connection"'; then
    pass "$name"
  else fail "$name" "rc 0"; fi
fi

name="quote with the Value's number in another unit verifies (canonical)"
if need "$name" planner_params_anchor_ok; then
  if anchor payments.provider_timeout "10000 ms" 'discovery:"connection after 10 seconds"'; then
    pass "$name"
  else fail "$name" "rc 1"; fi
fi

name="quote shorter than 8 characters does not verify"
if need "$name" planner_params_anchor_ok; then
  printf 'provider\n' >>"${IDIR}/artifacts/discovery.md"
  if ! anchor a.b "fast" 'discovery:"closes"'; then pass "$name"; else fail "$name" "rc 0"; fi
fi

name="free-text Value needs only the quote"
if need "$name" planner_params_anchor_ok; then
  printf 'Totals are rounded half-up per invoice.\n' >"${IDIR}/artifacts/idea.txt"
  if anchor billing.total_rounding "half-up" 'idea:"rounded half-up per invoice"'; then pass "$name"; else fail "$name" "rc 1"; fi
fi

name="code quote resolves under REPOS_ROOT"
if need "$name" planner_params_anchor_ok; then
  mkdir -p "${REPOS_ROOT}/svc/src"
  printf 'const TIMEOUT = 10; // 10 seconds per the provider contract\n' >"${REPOS_ROOT}/svc/src/client.ts"
  if anchor p.t "10 seconds" 'code:svc/src/client.ts:"10 seconds per the provider contract"' &&
    ! anchor p.t "10 seconds" 'code:svc/src/missing.ts:"10 seconds per the provider contract"'; then
    pass "$name"
  else fail "$name" "wrong rc"; fi
fi

name="human source verifies only with a matching round-file record"
if need "$name" planner_params_anchor_ok; then
  mkdir -p "${IDIR}/artifacts/answers"
  cat >"${IDIR}/artifacts/answers/round-1.json" <<'EOF'
{"round": 1, "answers": [
 {"id": "param-billing.total_rounding", "binding": "specify-param:billing.total_rounding", "value": "round only the invoice total", "role": "client"},
 {"id": "decision-O1-aaaaaaaa", "binding": "specify-answer:O1", "value": "x", "role": "client"}
]}
EOF
  ok=1
  anchor billing.total_rounding "round only the invoice total" "human:r1:client" || ok=0
  ! anchor billing.total_rounding "round only the invoice total" "human:r1:operator" || ok=0
  ! anchor billing.total_rounding "round each line" "human:r1:client" || ok=0
  ! anchor billing.other "round only the invoice total" "human:r1:client" || ok=0
  ! anchor billing.total_rounding "round only the invoice total" "human:r2:client" || ok=0
  if [ "$ok" -eq 1 ]; then pass "$name"; else fail "$name" "a case had the wrong rc"; fi
fi

# ── 3. Open rows ──────────────────────────────────────────────────────────────

echo "=== open rows ==="

name="keyword table promotes 'Payment retry delay' (duration) to failure"
if need "$name" planner_params_keyword_kind; then
  check "$name" "$(planner_params_keyword_kind "Payment retry delay" "payments.retry_delay")" "failure"
fi
name="keyword table: key split on ._- and prefixes"
if need "$name" planner_params_keyword_kind; then
  got="$(planner_params_keyword_kind "Trip time" "net.round_trip_ms")/$(planner_params_keyword_kind "Worker pool" "jobs.worker_pool_size")/$(planner_params_keyword_kind "Dead-letter queue" "q.dlq")/$(planner_params_keyword_kind "Refunds window" "x")"
  check "$name" "$got" "rounding//failure/policy"
fi
name="PLANNER_PARAMS_KIND_KEYWORDS names the four implied kinds"
if [ -n "${PLANNER_PARAMS_KIND_KEYWORDS:-}" ]; then
  check "$name" "$(printf '%s\n' "$PLANNER_PARAMS_KIND_KEYWORDS" | cut -d' ' -f1 | tr '\n' ' ')" "rounding failure transaction policy "
else fail "$name" "PLANNER_PARAMS_KIND_KEYWORDS missing"; fi

registry() {
  prop <<EOF
## Parameters

${HDR}
| Idle session timeout | \`auth.session_idle_minutes\` | duration | 30 minutes | 30 minutes | default |
| Invoice rounding | \`billing.total_rounding\` | rounding | half-up, 2 decimal places | NEEDS_HUMAN_DECISION — round each line, or only the invoice total? | — |
| Line rounding | \`billing.line_rounding\` | rounding | half-up, 2 decimal places | half-up, 2 decimal places | default |
| Payment retry delay | \`payments.retry_delay\` | duration | — | 5 minutes | default |
| Worker pool | \`jobs.worker_pool_size\` | size | 4 | 4 | default |
| Provider API timeout | \`payments.provider_timeout\` | fixed | — | 10 seconds | discovery:"the provider closes the connection after 10 seconds" |
| Export cap | \`export.max_rows\` | limit | — | NEEDS_HUMAN_DECISION | — |
| Bad | \`bad.kind\` | other | x | NEEDS_HUMAN_DECISION — never asked | — |
EOF
}

name="scan lists open rows in table order with question and suggestion"
if need "$name" planner_params_scan; then
  fresh
  printf 'Because the provider closes the connection after 10 seconds.\n' >"${IDIR}/artifacts/discovery.md"
  registry
  want=$(printf '%s\n' \
    "$(printf 'billing.total_rounding\t6\trounding\tInvoice rounding\thalf-up, 2 decimal places\tround each line, or only the invoice total?')" \
    "$(printf 'billing.line_rounding\t7\trounding\tLine rounding\thalf-up, 2 decimal places\tSpecify assumed "half-up, 2 decimal places" — is that right?')" \
    "$(printf 'payments.retry_delay\t8\tduration\tPayment retry delay\t5 minutes\tSpecify assumed "5 minutes" — is that right?')" \
    "$(printf 'export.max_rows\t11\tlimit\tExport cap\t\t(no question was written — what should Export cap be?)')")
  check "$name" "$(planner_params_scan "$INIT")" "$want"
fi

name="an unanchored fixed row is asked"
if need "$name" planner_params_scan; then
  rm -f "${IDIR}/artifacts/discovery.md"
  got=$(planner_params_scan "$INIT" | awk -F'\t' '$1 == "payments.provider_timeout" { print $2 "|" $6 }')
  check "$name" "$got" '10|Specify assumed "10 seconds" — is that right?'
fi

name="id is param-<key>: a reworded question keeps the key"
if need "$name" planner_params_scan; then
  sed -i 's/round each line, or only the invoice total?/per line or per invoice total?/' "$PROP"
  got=$(planner_params_scan "$INIT" | awk -F'\t' '$2 == 6 { print "param-" $1 "|" $6 }')
  check "$name" "$got" "param-billing.total_rounding|per line or per invoice total?"
fi

name="legacy initiative: scan prints nothing"
if need "$name" planner_params_scan; then
  fresh legacy
  registry
  check "$name" "$(planner_params_scan "$INIT")" ""
fi

name="contract marker written once, never by planner_state_init"
if need "$name" planner_params_contract_mark planner_params_contract_initiative; then
  fresh legacy
  ok=1
  ! planner_params_contract_initiative "$INIT" || ok=0
  planner_params_contract_mark "$INIT"
  planner_params_contract_mark "$INIT"
  planner_params_contract_initiative "$INIT" || ok=0
  c=$(grep -c '|META|contract|start|specify-parameters-v1$' "$(planner_state_log "$INIT")")
  if [ "$ok" -eq 1 ] && [ "$c" -eq 1 ]; then pass "$name"; else fail "$name" "ok=$ok count=$c"; fi
fi

name="no proposal: scan rc 0, silent"
if need "$name" planner_params_scan; then
  fresh
  rc=0
  out=$(planner_params_scan "$INIT") || rc=$?
  check "$name" "$rc|$out" "0|"
fi

# ── 4. Literals ───────────────────────────────────────────────────────────────

echo "=== literals ==="

lit() { printf '%s\n' "$1" | planner_params_literals - | cut -f2,3 | tr '\t\n' '= ' | sed 's/ $//'; }

name="unit list, spaced forms"
if need "$name" planner_params_literals; then
  got=$(lit "after 500 ms, 2 milliseconds, 3 s, 4 sec, 5 seconds, 6 min, 7 minutes, 8 h, 9 hr, 10 hours, 11 d, 12 days, 13 business days, 2 weeks, 3 months, 2 years")
  want="time:500=500 ms time:2=2 milliseconds time:3000=3 s time:4000=4 sec time:5000=5 seconds time:360000=6 min time:420000=7 minutes time:28800000=8 h time:32400000=9 hr time:36000000=10 hours time:950400000=11 d time:1036800000=12 days time:1123200000=13 business days time:1209600000=2 weeks month:3=3 months month:24=2 years"
  check "$name" "$got" "$want"
fi
name="unit list: sizes, percent, attempts, chars, decimal places"
if need "$name" planner_params_literals; then
  got=$(lit "1 byte 2 KB 3 mb 1 GB 1 TB 5 percent 7% 3 attempts 1 retry 4 retries 64 characters 8 chars 2 decimal places")
  want="size:1=1 byte size:2048=2 KB size:3145728=3 mb size:1073741824=1 GB size:1099511627776=1 TB pct:500=5 percent pct:700=7% attempt:3=3 attempts attempt:1=1 retry attempt:4=4 retries char:64=64 characters char:8=8 chars dp:2=2 decimal places"
  check "$name" "$got" "$want"
fi
name="glued and hyphenated forms"
if need "$name" planner_params_literals; then
  check "$name" "$(lit "a 30-day window, retries after 10s, kept for 30d, 24h, 500ms, 2GB, 5min, a 5-minute wait")" \
    "time:2592000000=30-day time:10000=10s time:2592000000=30d time:86400000=24h time:500=500ms size:2147483648=2GB time:300000=5min time:300000=5-minute"
fi
name="decimals and thousands"
if need "$name" planner_params_literals; then
  check "$name" "$(lit "1.5 seconds and 2,000 ms and 1,5 hours")" "time:1500=1.5 seconds time:2000=2,000 ms"
fi
name="exclusions: 0, 100%, decades, code spans, URLs, link targets"
if need "$name" planner_params_literals; then
  # shellcheck disable=SC2016  # literal backticks
  check "$name" "$(lit 'wait 0 seconds, reach 100%, the 1990s, `30 minutes`, https://x.io/5min, [docs](http://a.b/10s), www.x.io/7d')" ""
fi
name="exclusions: leading criterion labels"
if need "$name" planner_params_literals; then
  got=$(printf '%s\n' "- [ ] 10h. Shows 3 connections" "- [ ] 4d) Returns 404 for an unknown id" "- [x] 3: Progress reaches 100%" \
    "- [ ] The file is named invoices-2026-09-30.csv" "- [ ] 3.5 seconds is not a label" | planner_params_literals - | cut -f1,3 | tr '\t\n' '= ')
  check "$name" "$got" "5=3.5 seconds "
fi
name="fenced lines are never literals"
if need "$name" planner_params_literals; then
  got=$(printf '%s\n' '```' '15 minutes' '```' '~~~' '20 minutes' '~~~' '25 minutes' | planner_params_literals - | cut -f1,3 | tr '\t' '=')
  check "$name" "$got" "7=25 minutes"
fi
name="accepted misses stay misses (calendar days, spelled out, units outside the list)"
if need "$name" planner_params_literals; then
  check "$name" "$(lit "30 calendar days, thirty minutes, 3 sprints, 5 connections, 2 px, 3rd")" ""
fi

name="canonical equality: 86400 seconds = 24 hours = 1 day; 30 min = 30 minutes"
if need "$name" _planner_params_canon; then
  a=$(_planner_params_canon "86400 seconds")
  b=$(_planner_params_canon "24 hours")
  c=$(_planner_params_canon "1 day")
  d=$(_planner_params_canon "30 min")
  e=$(_planner_params_canon "30 minutes")
  if [ "$a" = "$b" ] && [ "$b" = "$c" ] && [ "$d" = "$e" ] && [ -n "$a" ] && [ -n "$d" ]; then pass "$name"; else fail "$name" "$a $b $c $d $e"; fi
fi
name="months are kept apart from days"
if need "$name" _planner_params_canon; then
  a=$(_planner_params_canon "1 month")
  b=$(_planner_params_canon "30 days")
  c=$(_planner_params_canon "12 months")
  d=$(_planner_params_canon "1 year")
  if [ "$a" != "$b" ] && [ "${a%%:*}" = month ] && [ "$c" = "$d" ]; then pass "$name"; else fail "$name" "$a $b $c $d"; fi
fi
name="canon refuses free text and two literals"
if need "$name" _planner_params_canon; then
  ok=1
  ! _planner_params_canon "about half an hour" >/dev/null || ok=0
  ! _planner_params_canon "5 minutes or 10 minutes" >/dev/null || ok=0
  if [ "$ok" -eq 1 ]; then pass "$name"; else fail "$name" "accepted"; fi
fi

# ── 5. Render and substitute ──────────────────────────────────────────────────

echo "=== render and substitute ==="

name="render_row builds a valid human row"
if need "$name" planner_params_render_row; then
  got=$(planner_params_render_row "Invoice rounding" billing.total_rounding rounding "half-up" "round only the invoice total" 2 client)
  # shellcheck disable=SC2016  # literal backticks
  check "$name" "$got" '| Invoice rounding | `billing.total_rounding` | rounding | half-up | round only the invoice total | human:r2:client |'
fi
name="render_row refuses a bad round, role or key"
if need "$name" planner_params_render_row; then
  ok=1
  ! planner_params_render_row a b.c policy x y 0 client 2>/dev/null || ok=0
  ! planner_params_render_row a b.c policy x y 1 boss 2>/dev/null || ok=0
  ! planner_params_render_row a "1bc" policy x y 1 client 2>/dev/null || ok=0
  if [ "$ok" -eq 1 ]; then pass "$name"; else fail "$name" "accepted"; fi
fi

name="substitute rewrites the open row; the result is closed and anchors as human"
if need "$name" planner_params_substitute planner_params_render_row planner_params_scan planner_params_rows; then
  fresh
  printf 'Because the provider closes the connection after 10 seconds.\n' >"${IDIR}/artifacts/discovery.md"
  registry
  r=$(planner_params_render_row "Invoice rounding" billing.total_rounding rounding "half-up, 2 decimal places" "round only the invoice total" 1 client)
  mkdir -p "${IDIR}/artifacts/answers"
  printf '{"round":1,"answers":[{"id":"param-billing.total_rounding","binding":"specify-param:billing.total_rounding","value":"round only the invoice total","role":"client"}]}\n' >"${IDIR}/artifacts/answers/round-1.json"
  rc=0
  planner_params_substitute "$INIT" "$PROP" "${WORK}/out.md" 6 billing.total_rounding "$r" || rc=$?
  changed=$(diff "$PROP" "${WORK}/out.md" | grep -c '^[<>]' || true)
  open=$(planner_params_scan "$INIT" "${WORK}/out.md" | cut -f1 | tr '\n' ' ')
  if [ "$rc" -eq 0 ] && [ "$changed" -eq 2 ] && [ "$open" = "billing.line_rounding payments.retry_delay export.max_rows " ]; then
    pass "$name"
  else fail "$name" "rc=$rc changed=$changed open=[$open]"; fi
fi

name="substitute returns 2 when the line is not the open row for the key"
if need "$name" planner_params_substitute; then
  ok=1
  rc=0
  planner_params_substitute "$INIT" "$PROP" "${WORK}/o2.md" 7 billing.total_rounding "x" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || ok=0
  rc=0
  planner_params_substitute "$INIT" "${WORK}/out.md" "${WORK}/o3.md" 6 billing.total_rounding "x" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || ok=0
  rc=0
  planner_params_substitute "$INIT" "$PROP" "${WORK}/o4.md" 5 auth.session_idle_minutes "x" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || ok=0
  if [ "$ok" -eq 1 ]; then pass "$name"; else fail "$name" "rc=$rc"; fi
fi

name="injection: the answer stays one inert cell"
if need "$name" planner_params_render_row planner_params_substitute planner_params_rows planner_params_invalid; then
  evil=$'a | b `x` ```fence``` <!-- c --> NEEDS_HUMAN_DECISION — q? $(touch '"${WORK}"$'/pwned)\nline2'
  r=$(planner_params_render_row "Invoice rounding" billing.total_rounding rounding "half-up, 2 decimal places" "$evil" 1 client)
  rc=0
  planner_params_substitute "$INIT" "$PROP" "${WORK}/inj.md" 6 billing.total_rounding "$r" || rc=$?
  val=$(planner_params_rows "$INIT" "${WORK}/inj.md" | awk -F'\t' '$1 == 6 { print $6 }')
  lines_before=$(wc -l <"$PROP")
  lines_after=$(wc -l <"${WORK}/inj.md")
  if [ "$rc" -eq 0 ] && [ ! -e "${WORK}/pwned" ] && [ "$lines_before" -eq "$lines_after" ] &&
    [ "$(planner_params_invalid "$INIT" "${WORK}/inj.md")" = "$(planner_params_invalid "$INIT")" ] &&
    [ "$val" = "$(_planner_specify_neutralise "$evil")" ] && [[ "$val" != *NEEDS_HUMAN_DECISION* ]] && [[ "$val" == *"a | b"* ]]; then
    pass "$name"
  else fail "$name" "rc=$rc val=[$val] lines $lines_before/$lines_after invalid=[$(planner_params_invalid "$INIT" "${WORK}/inj.md")]"; fi
fi

# ── 6. mawk / gawk ────────────────────────────────────────────────────────────

# run_all — every awk program over the fixtures, one output.
run_all() {
  fresh
  printf 'Because the provider closes the connection after 10 seconds.\n' >"${IDIR}/artifacts/discovery.md"
  registry
  {
    planner_params_rows "$INIT"
    planner_params_invalid "$INIT"
    planner_params_scan "$INIT"
    planner_params_literals "${SCRIPT_DIR}/test-planner-specify-params.sh"
    planner_params_anchor_ok "$INIT" p.t "10 seconds" 'discovery:"connection after 10 seconds"' && echo anchored
    planner_params_substitute "$INIT" "$PROP" "${WORK}/aw.md" 6 billing.total_rounding "X" && cat "${WORK}/aw.md"
  } 2>&1
}

echo "=== prompt rules ==="

# ── 7. Prompt rules (task 8.2) ───────────────────────────────────────────────
#
# The wording lives in two lib functions, each pulled into its prompt by one
# `$(…)` line (design D10). Pinned: the content D10 lists, the size budget,
# and that each prompt is byte-identical to its pre-change capture once the
# inserted lines are removed.

name="Specify prompt rules carry the D10 content"
if need "$name" planner_params_prompt_rules; then
  r=$(planner_params_prompt_rules)
  missing=""
  for want in '## Parameters' '| Name | Key | Kind | Default | Value | Source |' 'None.' \
    'policy' 'rounding' 'transaction' 'failure' 'fixed' 'duration' 'limit' 'size' \
    'NEEDS_HUMAN_DECISION —' 'plain' '<artifact>:"<quote>"' 'code:<path>:"<quote>"' \
    'verbatim' '## Technical Context' 'Crosscheck' 'Expected' 'human:'; do
    grep -qF -- "$want" <<<"$r" || missing="${missing} [${want}]"
  done
  if [ -z "$missing" ]; then pass "$name"; else fail "$name" "missing:${missing}"; fi
  words=$(wc -w <<<"$r")
  if [ "$words" -le 380 ]; then pass "Specify prompt rules stay near 300 words (${words})"; else
    fail "Specify prompt rules stay near 300 words" "${words} words"
  fi
fi

name="Consensus rule carries the D10 content"
if need "$name" planner_params_consensus_rule; then
  r=$(planner_params_consensus_rule)
  missing=""
  for want in '## Parameters' 'human:' 'NEEDS_HUMAN_DECISION' 'new row' 'spec'; do
    grep -qF -- "$want" <<<"$r" || missing="${missing} [${want}]"
  done
  if [ -z "$missing" ]; then pass "$name"; else fail "$name" "missing:${missing}"; fi
  words=$(wc -w <<<"$r")
  if [ "$words" -le 90 ]; then pass "Consensus rule stays near 60 words (${words})"; else
    fail "Consensus rule stays near 60 words" "${words} words"
  fi
fi

# Pre-change captures, scratch REPOS_ROOT normalised (the same normalisation
# test-planner-business-framing.sh uses for SPECIFY_PROMPT_SHA). Still the
# captures from before planner-specify-parameters: the strip below also removes
# what planner-crosscheck-ownership and planner-ac-code-precondition inserted,
# so the three changes together leave no residue, and re-capturing with
# planner-ac-code-precondition gave these same values. Each later prompt
# change adds its blocks to the strip lists.
SPECIFY_PRE_SHA="4b9ab2f059255bb3c2b6c79edd3b66e43a999d78823a593e3ea26126537b3bd9"
CONSENSUS_PRE_SHA="11161f4ce2736099fcaddbed6fd92cbc247050f69ec351183f1bd0016535c9d9"
SPECIFY_BULLET='- **Parameters** — a `## Parameters` section directly after Business Outcomes (rules below)'

# The prompts as they were before planner-crosscheck-ownership (main @ 3e6016e),
# and the lines that change inserted (design D15, task 6.2).
OWN_SPECIFY_PRE_SHA="7cfd5cf7c9b36538867befaf774ca8895f638039aa46e425f1cec505d3f29e89"
OWN_CONSENSUS_PRE_SHA="565edca03c6edaf7b791e4de973a75345875350631c3aab67b52a3c89df0b703"
OWN_TICKETGEN_PRE_SHA="b7815809eac92d3aed028292c3f38ea19d1a7263345f843d74f1f6fa63197f0b"
OWN_SPECIFY_BULLET='7. **## Writes** and **## Reads** — the data the ticket writes and reads, and the side effects it owns or causes (rules below)'
OWN_SPECIFY_HEADINGS=', `## Writes`, `## Reads`'
# The prompts as they were before planner-ac-code-precondition, i.e. as
# planner-crosscheck-ownership PR B left them (intermediate pins, design D12),
# and the lines that change inserted (task 5.4).
SPECIFY_PRE_ACPRE_SHA="93bbc0bb60710543ba7928ade772f06a57e6f82574e997f41d9bfd4a59fee06a"
CONSENSUS_PRE_ACPRE_SHA="5273988daab593aa79d78e700c9ac45ca52467ccd1f25fc908be24f9b9abf570"
ACPRE_SPECIFY_BULLET='8. **## Preconditions** — the stored starting state each acceptance criterion needs (rules below)'
ACPRE_SPECIFY_HEADINGS=', `## Preconditions`'
# The Consensus prompt as it was before planner-goldfish-review (main after
# planner-ac-code-precondition PR 2, f3b6adb; re-captured on PR B's base and
# equal to PR A's provisional capture), and that change's one inserted block,
# `$(planner_goldfish_consensus_rule)` after the Readiness bullet. Every
# Consensus strip below also strips it, so the earlier pins keep their values.
CONSENSUS_PRE_GOLDFISH_SHA="432de2ef9564bbcba7381cb8ad88b57066b2ee0a9255953f6d2885ac7564f6d0"
OWN_TICKETGEN_LINE='  Then the ownership edges in `artifacts/ownership-edges.json`: a spec blocked by the sibling that writes what it reads, or by the `fire` owner of an effect it triggers.'

# _strip_once <prompt> <text> — the prompt with the one occurrence of <text>
# removed; empty when <text> occurs other than once.
_strip_once() {
  local p="$1" b="$2" rest
  [[ "$p" == *"$b"* ]] || return 0
  rest="${p#*"$b"}"
  [[ "$rest" != *"$b"* ]] || return 0
  printf '%s%s' "${p%%"$b"*}" "$rest"
}

# _strip_block <prompt> <block> — _strip_once of <block> with the newline
# before it (an inserted line or `$(…)` block).
_strip_block() {
  _strip_once "$1" $'\n'"$2"
}

# _strip_inserted_blocks <prompt> <block>... — strip each inserted block in
# turn (_strip_block); a block starting with `inline:` is stripped with
# _strip_once instead. Empty when any block is not found exactly once. Every
# strip-and-hash test below uses it, with the blocks of each change it strips.
_strip_inserted_blocks() {
  local p="$1" b
  shift
  for b in "$@"; do
    case "$b" in
    inline:*) p=$(_strip_once "$p" "${b#inline:}") ;;
    *) p=$(_strip_block "$p" "$b") ;;
    esac
    [ -n "$p" ] || return 0
  done
  printf '%s' "$p"
}

_sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# The ownership blocks of each prompt, in strip order.
own_specify_blocks() {
  OWN_BLOCKS=("$(planner_ownership_prompt_rules)" "$OWN_SPECIFY_BULLET" "inline:${OWN_SPECIFY_HEADINGS}")
}
# The planner-ac-code-precondition blocks, stripped before the ownership ones
# (they sit next to them).
acpre_specify_blocks() {
  ACPRE_BLOCKS=("$(planner_acpre_prompt_rules)" "$ACPRE_SPECIFY_BULLET" "inline:${ACPRE_SPECIFY_HEADINGS}")
}

[ -f "${LIB_DIR}/planner-ac-precondition.sh" ] && source "${LIB_DIR}/planner-ac-precondition.sh"
[ -f "${LIB_DIR}/planner-goldfish.sh" ] && source "${LIB_DIR}/planner-goldfish.sh"

name="Specify prompt is the pre-change prompt plus the rules blocks and bullets"
if need "$name" planner_params_prompt_rules planner_ownership_prompt_rules planner_acpre_prompt_rules && [ -f "${LIB_DIR}/planner-phase-prompts.sh" ]; then
  source "${LIB_DIR}/planner-phase-prompts.sh"
  sp=$(planner_prompt_specify "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
  sp="${sp//$REPOS_ROOT/<REPOS_ROOT>}"
  own_specify_blocks
  acpre_specify_blocks
  st=$(_strip_inserted_blocks "$sp" "$(planner_params_prompt_rules)" "$SPECIFY_BULLET" "${ACPRE_BLOCKS[@]}" "${OWN_BLOCKS[@]}")
  got=$(_sha "$st")
  if [ -n "$st" ] && [ "$got" = "$SPECIFY_PRE_SHA" ]; then pass "$name"; else
    fail "$name" "a block or bullet not found once, or sha ${got}"
  fi
  if [[ "$sp" == *"$(planner_params_prompt_rules)"$'\n\n### Part 2: Write per-ticket spec files'* ]]; then
    pass "Specify rules sit directly before Part 2"
  else fail "Specify rules sit directly before Part 2" "not adjacent"; fi

  name="Specify prompt without the precondition lines is the pre-precondition prompt (no residue)"
  st=$(_strip_inserted_blocks "$sp" "${ACPRE_BLOCKS[@]}")
  got=$(_sha "$st")
  if [ -n "$st" ] && [ "$got" = "$SPECIFY_PRE_ACPRE_SHA" ]; then pass "$name"; else
    fail "$name" "a block not found once, or sha ${got}"
  fi

  name="Specify prompt without the ownership and precondition lines is the pre-ownership prompt (no residue)"
  st=$(_strip_inserted_blocks "$sp" "${ACPRE_BLOCKS[@]}" "${OWN_BLOCKS[@]}")
  got=$(_sha "$st")
  if [ -n "$st" ] && [ "$got" = "$OWN_SPECIFY_PRE_SHA" ]; then pass "$name"; else
    fail "$name" "a block not found once, or sha ${got}"
  fi
  if [[ "$sp" == *$'\n```\n'"$(planner_ownership_prompt_rules)"$'\n'"$(planner_acpre_prompt_rules)"$'\n\n### Confidence signals'* ]]; then
    pass "Specify ownership rules sit after the Verification Notes rules; the precondition rules follow, before Confidence signals"
  else fail "Specify ownership and precondition rules sit after the Verification Notes rules" "not adjacent"; fi
  if [ "$(grep -A1 -F -- "$OWN_SPECIFY_BULLET" <<<"$sp" | tail -1)" = "$ACPRE_SPECIFY_BULLET" ]; then
    pass "Specify precondition bullet follows the Writes/Reads bullet"
  else fail "Specify precondition bullet follows the Writes/Reads bullet" "not adjacent"; fi
  if grep -qF -- '`## Writes`, `## Reads`, `## Preconditions` — TicketGen reads' <<<"$sp"; then
    pass "Specify heading list ends with Preconditions"
  else fail "Specify heading list ends with Preconditions" "not found"; fi
  if grep -qF -- '6. **## Test Data Provided**' <<<"$sp" &&
    [ "$(grep -A2 -F -- '6. **## Test Data Provided**' <<<"$sp" | tail -1)" = "$OWN_SPECIFY_BULLET" ]; then
    pass "Specify ownership bullet follows the Test Data Provided bullet"
  else fail "Specify ownership bullet follows the Test Data Provided bullet" "not adjacent"; fi
fi

name="Consensus prompt is the pre-change prompt plus the rule blocks"
if need "$name" planner_params_consensus_rule planner_ownership_consensus_rule planner_acpre_consensus_rule planner_goldfish_consensus_rule planner_prompt_consensus; then
  cp=$(planner_prompt_consensus "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
  cp="${cp//$REPOS_ROOT/<REPOS_ROOT>}"
  GOLDFISH_BLOCKS=("$(planner_goldfish_consensus_rule)")
  ct=$(_strip_inserted_blocks "$cp" "${GOLDFISH_BLOCKS[@]}" "$(planner_params_consensus_rule)" "$(planner_acpre_consensus_rule)" "$(planner_ownership_consensus_rule)")
  got=$(_sha "$ct")
  if [ -n "$ct" ] && [ "$got" = "$CONSENSUS_PRE_SHA" ]; then pass "$name"; else
    fail "$name" "block not found once, or sha ${got}"
  fi
  if grep -A1 -F '(planner-business-framing).' <<<"$cp" | grep -qF '## Parameters'; then
    pass "Consensus rule follows the Business Outcomes carry-over sentence"
  else fail "Consensus rule follows the Business Outcomes carry-over sentence" "not adjacent"; fi

  name="Consensus prompt without the precondition rule is the pre-precondition prompt (no residue)"
  ct=$(_strip_inserted_blocks "$cp" "${GOLDFISH_BLOCKS[@]}" "$(planner_acpre_consensus_rule)")
  got=$(_sha "$ct")
  if [ -n "$ct" ] && [ "$got" = "$CONSENSUS_PRE_ACPRE_SHA" ]; then pass "$name"; else
    fail "$name" "block not found once, or sha ${got}"
  fi

  name="Consensus prompt without the ownership and precondition rules is the pre-ownership prompt (no residue)"
  ct=$(_strip_inserted_blocks "$cp" "${GOLDFISH_BLOCKS[@]}" "$(planner_acpre_consensus_rule)" "$(planner_ownership_consensus_rule)")
  got=$(_sha "$ct")
  if [ -n "$ct" ] && [ "$got" = "$OWN_CONSENSUS_PRE_SHA" ]; then pass "$name"; else
    fail "$name" "block not found once, or sha ${got}"
  fi
  if [[ "$cp" == *"$(planner_params_consensus_rule)"$'\n'"$(planner_ownership_consensus_rule)"$'\n'"$(planner_acpre_consensus_rule)"$'\n4. Write a consensus digest'* ]]; then
    pass "Consensus ownership rule follows the parameters rule; the precondition rule follows it"
  else fail "Consensus ownership and precondition rules follow the parameters rule" "not adjacent"; fi

  name="Consensus prompt without the goldfish block is the pre-goldfish prompt (no residue)"
  ct=$(_strip_inserted_blocks "$cp" "${GOLDFISH_BLOCKS[@]}")
  got=$(_sha "$ct")
  if [ -n "$ct" ] && [ "$got" = "$CONSENSUS_PRE_GOLDFISH_SHA" ]; then pass "$name"; else
    fail "$name" "block not found once, or sha ${got}"
  fi
  if [[ "$cp" == *$'   - **Readiness** — ready-for-spec / needs-further-discovery / blocked\n'"$(planner_goldfish_consensus_rule)"$'\n'* ]]; then
    pass "Consensus goldfish block follows the Readiness bullet"
  else fail "Consensus goldfish block follows the Readiness bullet" "not adjacent"; fi
fi

name="TicketGen prompt without the ownership-edges line is the pre-ownership prompt (no residue)"
declare -f planner_prompt_ticketgen >/dev/null || source "${LIB_DIR}/planner-phase-prompts.sh"
if need "$name" planner_prompt_ticketgen; then
  tp=$(planner_prompt_ticketgen "INIT-TEST" "an idea" "/repos/.ticket-auto/initiatives/INIT-TEST")
  tp="${tp//$REPOS_ROOT/<REPOS_ROOT>}"
  tt=$(_strip_inserted_blocks "$tp" "$OWN_TICKETGEN_LINE")
  got=$(_sha "$tt")
  if [ -n "$tt" ] && [ "$got" = "$OWN_TICKETGEN_PRE_SHA" ]; then pass "$name"; else
    fail "$name" "line not found once, or sha ${got}"
  fi
  if grep -B1 -F -- "$OWN_TICKETGEN_LINE" <<<"$tp" | head -1 | grep -qF 'testdata-synth.json'; then
    pass "TicketGen ownership-edges line follows the test-data edges"
  else fail "TicketGen ownership-edges line follows the test-data edges" "not adjacent"; fi
fi

echo "=== awk portability ==="

name="mawk runs every awk program"
if need "$name" planner_params_rows planner_params_scan planner_params_literals; then
  if command -v mawk >/dev/null 2>&1; then
    m=$(PLANNER_PARAMS_AWK=mawk run_all)
    if [ -n "$m" ] && ! grep -qi 'syntax error\|mawk:' <<<"$m"; then pass "$name"; else fail "$name" "$(head -3 <<<"$m")"; fi
    if command -v gawk >/dev/null 2>&1; then
      g=$(PLANNER_PARAMS_AWK=gawk run_all)
      # INIT differs per run; compare with the ids blanked.
      if [ "$(sed 's/INIT-[0-9-]*//g' <<<"$m")" = "$(sed 's/INIT-[0-9-]*//g' <<<"$g")" ]; then
        pass "mawk output equals gawk output"
      else fail "mawk output equals gawk output" "$(diff <(echo "$m") <(echo "$g") | head -5)"; fi
    else
      echo "  SKIP mawk output equals gawk output (gawk not installed)"
    fi
  else
    echo "  SKIP mawk runs every awk program (mawk not installed)"
  fi
fi

echo ""
echo "=== planner specify params: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
