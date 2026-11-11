#!/usr/bin/env bash
# test-planner-crosscheck-ownership.sh — the Crosscheck ownership family
# (planner-crosscheck-ownership, tasks 3.1–3.4):
# planner-crosscheck-ownership.sh.
#
# One case per spec scenario:
#   - legacy silence (no spec-ownership-v1 marker);
#   - OWN_TABLE_INVALID, one per spec, including a read of a sibling's effect
#     key (decision recorded in handoff.md, slice 3);
#   - OWN_MULTI_WRITER: plain writers, create + update, update + transition,
#     transitions sharing a from-state, `*`; none for disjoint transitions,
#     appends, or an entity write beside a field write;
#   - OWN_NO_WRITER: unmatched spec read, the entity rule, verified code: and
#     framework: reads, a failed code: anchor with its reason, own-write reads;
#   - OWN_MULTI_FIRE, OWN_TRIGGER_UNOWNED, one fire plus triggers;
#   - warnings OWN_NEAR_MATCH, OWN_UNDECLARED_REF, OWN_EXTERNAL_UNANCHORED are
#     `warn`, never `fail`;
#   - findings free of `|`, CR and LF; mawk runs the family;
#   - registrations (instance, cross-file and warn codes, fix hints);
#   - per-instance and wildcard accept for the four instance codes;
#   - the family runs inside planner_crosscheck_run, after the params family;
#   - the edges step (tasks 4.1, 4.3): before the deps family, so
#     DEPENDENCY_CYCLE sees ownership edges; legacy silence; OWN_EDGES_FAILED;
#     OWN_EDGES_DIVERGED as a warning.
#
# Every case is guarded on the functions it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary, never an
# unbound-function abort.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-ownership.sh

# No errexit: planner_crosscheck_run counts finding return codes (1, 3) with
# `rc=$?`, which errexit would turn into an exit of its read loop.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck.sh"
source "${LIB_DIR}/planner-specify-params.sh"
source "${LIB_DIR}/planner-spec-ownership.sh"
if [ -f "${LIB_DIR}/planner-crosscheck-ownership.sh" ]; then
  source "${LIB_DIR}/planner-crosscheck-ownership.sh"
fi

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
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}
contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing [$3] in [$2]" ;;
  esac
}
lacks() {
  case "$2" in
  *"$3"*) fail "$1" "unexpected [$3] in [$2]" ;;
  *) pass "$1" ;;
  esac
}

N=0
# fresh [legacy] — a new initiative, a contract one unless "legacy" is given.
fresh() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((8000 + N))"
  planner_state_init "$INIT" "invoice follow-up" >/dev/null
  IDIR=$(planner_initiative_dir "$INIT")
  SPECS="${IDIR}/artifacts/specs"
  mkdir -p "$SPECS"
  [ "${1:-}" = legacy ] || planner_ownership_contract_mark "$INIT"
}

# _rows <rows> — `None.` when empty, else a table body: each `;`-separated
# row `key=val` becomes "| `key` | val |".
_rows() {
  local hdr="$1" rows="$2" r
  if [ -z "$rows" ]; then
    printf 'None.\n'
    return
  fi
  printf '%s\n' "$hdr"
  local IFS=';'
  for r in $rows; do
    printf '| `%s` | %s |\n' "${r%%=*}" "${r#*=}"
  done
}

# ospec <slug> <writes> <reads> [<technical context>] — a spec with both
# tables. Rows are `key=op;key=op`; empty gives `None.`. Line numbers: the
# Writes heading is line 7, its first row line 11; with `None.` Writes, the
# first Reads row is line 15.
ospec() {
  {
    printf '# %s\n\n## Technical Context\n\n%s\n\n' "$1" "${4:-none}"
    printf '## Writes\n\n'
    _rows $'| Key | Op |\n|-----|----|' "$2"
    printf '\n## Reads\n\n'
    _rows $'| Key | Source |\n|-----|--------|' "$3"
    printf '\n## Acceptance Criteria\n\n- [ ] It works\n'
  } >"${SPECS}/$1.md"
}

# run — the family's stdout, prefix stripped.
run() { planner_crosscheck_ownership "$INIT" 2>/dev/null | sed 's/^planner-crosscheck-ownership: //' || true; }
# codes — the codes the family printed, space-separated, in output order.
codes() { run | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//'; }
# of <CODE> — the family's lines for one code.
of() { run | grep "^$1 " || true; }

# ── Legacy ────────────────────────────────────────────────────────────────────

echo "=== legacy ==="

name="legacy initiative is silent"
if need "$name" planner_crosscheck_ownership; then
  fresh legacy
  ospec overdue-job 'invoice.status=update' 'customer.email=spec'
  ospec payment 'invoice.status=update;email.x=trigger' ''
  out=$(planner_crosscheck_ownership "$INIT" 2>&1)
  rc=$?
  check "$name" "${rc}:${out}" "0:"
fi

name="clean contract initiative is silent"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec import 'invoice=create' ''
  ospec reminder 'email.invoice_overdue=fire' 'invoice.due_date=spec;user.id=framework:auth_user'
  out=$(planner_crosscheck_ownership "$INIT" 2>&1)
  rc=$?
  check "$name" "${rc}:${out}" "0:"
fi

# ── OWN_TABLE_INVALID ─────────────────────────────────────────────────────────

echo "=== table invalid ==="

name="OWN_TABLE_INVALID once per spec"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec bad-ops 'Invoice.Status=update;invoice.total=modify' 'invoice.total=spec'
  printf '# no-tables\n\n## Acceptance Criteria\n\n- [ ] x\n' >"${SPECS}/no-tables.md"
  ospec good 'invoice.total=create' ''
  check "$name" "$(codes)" "OWN_TABLE_INVALID OWN_TABLE_INVALID"
  out=$(of OWN_TABLE_INVALID)
  contains "$name: bad-ops locus" "$out" "OWN_TABLE_INVALID specs/bad-ops.md:11 "
  contains "$name: names both bad lines" "$out" "line 12"
  contains "$name: missing sections named" "$out" "specs/no-tables.md ## Writes is missing"
  lacks "$name: no pipe in the header reason" "$out" "Key | Op"
fi

name="a read of a sibling's effect key is OWN_TABLE_INVALID, not OWN_NO_WRITER"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec overdue-job 'email.invoice_overdue=fire' ''
  ospec resend '' 'email.invoice_overdue=spec'
  check "$name" "$(codes)" "OWN_TABLE_INVALID"
  contains "$name: says trigger" "$(of OWN_TABLE_INVALID)" "trigger"
fi

# ── OWN_MULTI_WRITER ──────────────────────────────────────────────────────────

echo "=== multi writer ==="

mw() {
  fresh
  ospec overdue-job "invoice.status=$1" ''
  ospec payment "invoice.status=$2" ''
  of OWN_MULTI_WRITER | grep -c . || true
}

name="two updates conflict"
if need "$name" planner_crosscheck_ownership; then
  check "$name" "$(mw update update)" "1"
  fresh
  ospec overdue-job 'invoice.status=update' ''
  ospec payment 'invoice.status=update' ''
  out=$(of OWN_MULTI_WRITER)
  contains "$name: names the key" "$out" '`invoice.status`'
  contains "$name: names writer and op" "$out" "overdue-job (update)"
  contains "$name: names the other writer" "$out" "payment (update)"
  contains "$name: ends with its accept" "$out" "resume ${INIT} --accept OWN_MULTI_WRITER@invoice.status:\"<reason>\""
fi
name="create and update conflict"
if need "$name" planner_crosscheck_ownership; then check "$name" "$(mw create update)" "1"; fi
name="update and transition conflict"
if need "$name" planner_crosscheck_ownership; then check "$name" "$(mw update 'transition:sent->paid')" "1"; fi
name="transitions sharing a from-state conflict"
if need "$name" planner_crosscheck_ownership; then
  check "$name" "$(mw 'transition:sent->overdue' 'transition:sent,overdue->paid')" "1"
fi
name="* overlaps any transition"
if need "$name" planner_crosscheck_ownership; then
  check "$name" "$(mw 'transition:*->closed' 'transition:paid->refunded')" "1"
fi
name="disjoint transitions do not conflict"
if need "$name" planner_crosscheck_ownership; then
  check "$name" "$(mw 'transition:sent->overdue' 'transition:overdue->paid')" "0"
fi
name="append never conflicts"
if need "$name" planner_crosscheck_ownership; then
  check "$name" "$(mw append update)" "0"
  check "$name: two appends" "$(mw append append)" "0"
fi
name="create invoice and update invoice.status do not conflict"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec import 'invoice=create' ''
  ospec payment 'invoice.status=update' ''
  check "$name" "$(codes)" ""
fi
name="three writers: one finding naming all"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec a-job 'invoice.status=transition:sent->overdue' ''
  ospec b-pay 'invoice.status=transition:sent,overdue->paid' ''
  ospec c-cancel 'invoice.status=transition:sent,overdue->cancelled' ''
  out=$(of OWN_MULTI_WRITER)
  check "$name" "$(grep -c . <<<"$out")" "1"
  contains "$name: c-cancel named" "$out" "c-cancel (transition:sent,overdue->cancelled)"
fi

# ── OWN_NO_WRITER ─────────────────────────────────────────────────────────────

echo "=== no writer ==="

name="unmatched spec read gives OWN_NO_WRITER"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec reminder '' 'customer.phone=spec;customer.locale=spec'
  check "$name" "$(codes)" "OWN_NO_WRITER OWN_NO_WRITER"
  out=$(of OWN_NO_WRITER)
  contains "$name: locus and key" "$out" 'OWN_NO_WRITER specs/reminder.md:15 reads `customer.phone`'
  contains "$name: accept command" "$out" "resume ${INIT} --accept OWN_NO_WRITER@reminder/customer.phone:\"<reason>\""
fi

name="entity rule: a whole-entity write satisfies a field read and vice versa"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec import 'invoice=create;payment.amount=create' ''
  ospec reminder '' 'invoice.due_date=spec;payment=spec'
  check "$name" "$(codes)" ""
fi

name="verified code: and framework: reads pass; a failed code: reports its reason"
if need "$name" planner_crosscheck_ownership; then
  fresh
  mkdir -p "${REPOS_ROOT}/billing/.git" "${REPOS_ROOT}/billing/db"
  printf 'CREATE TABLE invoice (id int, due_date date, valid bool);\n' >"${REPOS_ROOT}/billing/db/schema.sql"
  printf 'class User { String valid; }\n' >"${REPOS_ROOT}/billing/db/User.java"
  ospec reminder '' 'invoice.due_date=code:billing/db;session.token=framework:session;user.id=code:billing/db/User.java'
  check "$name" "$(codes)" "OWN_NO_WRITER"
  contains "$name: reason" "$(of OWN_NO_WRITER)" "key not named in file"
  contains "$name: the failed key" "$(of OWN_NO_WRITER)" '`user.id`'
fi

name="a read of a key the spec writes itself is ignored"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec payment 'invoice.status=update' 'invoice.status=spec;invoice=spec'
  check "$name" "$(codes)" ""
fi

name="a failed code: anchor with a sibling writer is satisfied"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec payment 'invoice.paid_at=update' ''
  ospec receipt '' 'invoice.paid_at=code:nowhere/db'
  check "$name" "$(codes)" ""
fi

# ── Effects ───────────────────────────────────────────────────────────────────

echo "=== effects ==="

name="one fire plus triggers is clean"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec overdue-job 'email.invoice_overdue=fire' ''
  ospec resend 'email.invoice_overdue=trigger' ''
  ospec escalate 'email.invoice_overdue=trigger' ''
  check "$name" "$(codes)" ""
fi

name="two fire rows give OWN_MULTI_FIRE once"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec overdue-job 'email.invoice_overdue=fire' ''
  ospec resend 'email.invoice_overdue=fire' ''
  check "$name" "$(codes)" "OWN_MULTI_FIRE"
  out=$(of OWN_MULTI_FIRE)
  contains "$name: names both" "$out" "overdue-job, resend"
  contains "$name: accept" "$out" "--accept OWN_MULTI_FIRE@email.invoice_overdue:\"<reason>\""
fi

name="a trigger with no fire gives OWN_TRIGGER_UNOWNED"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec resend 'email.invoice_overdue=trigger' ''
  check "$name" "$(codes)" "OWN_TRIGGER_UNOWNED"
  contains "$name: locus and accept" "$(of OWN_TRIGGER_UNOWNED)" \
    "OWN_TRIGGER_UNOWNED specs/resend.md:11 triggers"
  contains "$name: accept" "$(of OWN_TRIGGER_UNOWNED)" "--accept OWN_TRIGGER_UNOWNED@resend/email.invoice_overdue:\"<reason>\""
fi

name="effect keys never match data keys"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec mailer 'email.invoice_overdue=fire' ''
  ospec logger 'email.invoice_overdue=update' ''
  check "$name" "$(codes)" ""
fi

# ── Warnings ──────────────────────────────────────────────────────────────────

echo "=== warnings ==="

name="OWN_NEAR_MATCH beside OWN_NO_WRITER"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec payment 'invoice.status=update' ''
  ospec reminder '' 'invoices.status=spec'
  check "$name" "$(codes)" "OWN_NO_WRITER OWN_NEAR_MATCH"
  out=$(of OWN_NEAR_MATCH)
  contains "$name: both keys" "$out" '`invoices.status`'
  contains "$name: writer key" "$out" '`invoice.status`'
  contains "$name: both specs" "$out" "payment"
fi

name="OWN_UNDECLARED_REF names entity.field tokens, not file names"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec payment 'invoice.status=update' '' \
    $'Sets `invoice.status` and `invoice.paid_at`; reads `config.yaml` and `Invoice.java`.\n\n```\n`invoice.fenced_out`\n```'
  check "$name" "$(codes)" "OWN_UNDECLARED_REF"
  out=$(of OWN_UNDECLARED_REF)
  contains "$name: names paid_at" "$out" "invoice.paid_at"
  lacks "$name: not config.yaml" "$out" "config.yaml"
  lacks "$name: declared key not listed" "$out" "invoice.status,"
  lacks "$name: fenced token not listed" "$out" "fenced_out"
fi

name="OWN_EXTERNAL_UNANCHORED when the name is nowhere"
if need "$name" planner_crosscheck_ownership; then
  fresh
  printf 'Uses the public holiday feed for due dates.\n' >"${IDIR}/artifacts/idea.txt"
  ospec reminder '' 'bank_holiday.date=external:Public  Holiday Feed;fx.rate=external:currency oracle'
  check "$name" "$(codes)" "OWN_EXTERNAL_UNANCHORED"
  contains "$name: the unanchored one" "$(of OWN_EXTERNAL_UNANCHORED)" "currency oracle"
fi

name="the four warnings are warn codes and the run stays clean"
if need "$name" planner_crosscheck_ownership; then
  for c in OWN_NEAR_MATCH OWN_UNDECLARED_REF OWN_EXTERNAL_UNANCHORED OWN_EDGES_DIVERGED; do
    if _planner_crosscheck_is_warn_code "$c"; then pass "$name: $c"; else fail "$name: $c" "not in PLANNER_CROSSCHECK_WARN_CODES"; fi
  done
  fresh
  ospec reminder '' 'fx.rate=external:currency oracle' 'Mentions `fx.source`.'
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  log=$(planner_state_log "$INIT")
  check "$name: warn lines" "$(grep -c '|META|crosscheck|warn|info OWN_' "$log")" "2"
  check "$name: no OWN fail" "$(grep -c '|META|crosscheck|fail|OWN_' "$log")" "0"
fi

# ── Shape ─────────────────────────────────────────────────────────────────────

echo "=== shape ==="

name="findings carry no pipe, CR or LF"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec reminder '' 'fx.rate=external:feed a\|b oracle;customer.phone=spec'
  sed -i 's/$/\r/' "${SPECS}/reminder.md"
  out=$(run)
  check "$name: two findings" "$(grep -c . <<<"$out")" "2"
  lacks "$name: no pipe" "$out" "|"
  lacks "$name: no CR" "$out" $'\r'
fi

name="mawk runs the family"
if need "$name" planner_crosscheck_ownership; then
  if command -v mawk >/dev/null 2>&1; then
    fresh
    ospec payment 'invoice.status=update' '' $'Uses `invoice.paid_at`.'
    ospec reminder 'invoice.status=transition:sent->overdue' 'invoices.status=spec'
    m=$(PLANNER_OWNERSHIP_AWK=mawk planner_crosscheck_ownership "$INIT" 2>&1 || true)
    d=$(planner_crosscheck_ownership "$INIT" 2>&1 || true)
    check "$name: codes" "$(sed 's/^planner-crosscheck-ownership: //' <<<"$m" | awk '{print $1}' | paste -sd' ' -)" \
      "OWN_UNDECLARED_REF OWN_NO_WRITER OWN_NEAR_MATCH OWN_MULTI_WRITER"
    check "$name: equals the default awk" "$m" "$d"
    if command -v gawk >/dev/null 2>&1; then
      g=$(PLANNER_OWNERSHIP_AWK=gawk planner_crosscheck_ownership "$INIT" 2>&1 || true)
      check "gawk agrees with mawk" "$g" "$m"
    else
      echo "  SKIP gawk agrees with mawk (gawk not installed)"
    fi
  else
    echo "  SKIP mawk runs the family (mawk not installed)"
  fi
fi

# ── Registrations ─────────────────────────────────────────────────────────────

echo "=== registrations ==="

name="the four instance codes are registered"
for c in OWN_MULTI_WRITER OWN_NO_WRITER OWN_MULTI_FIRE OWN_TRIGGER_UNOWNED; do
  check "$name: $c lib" "$(planner_crosscheck_instance_field "$c" lib 2>/dev/null)" "planner-crosscheck-ownership.sh"
  check "$name: $c parse" "$(planner_crosscheck_instance_field "$c" parse 2>/dev/null)" "planner_crosscheck_ownership_accept_parse"
  check "$name: $c instance" "$(planner_crosscheck_instance_field "$c" instance 2>/dev/null)" "planner_crosscheck_ownership_instance"
done
if planner_crosscheck_is_instance_code OWN_TABLE_INVALID; then
  fail "$name: OWN_TABLE_INVALID stays code-wide" "listed"
else
  pass "$name: OWN_TABLE_INVALID stays code-wide"
fi

name="cross-file codes"
for c in OWN_MULTI_WRITER OWN_MULTI_FIRE; do
  contains "$name: $c" " ${PLANNER_CROSSCHECK_CROSS_FILE_CODES} " " $c "
done

name="fix hints"
for c in OWN_TABLE_INVALID OWN_MULTI_WRITER OWN_NO_WRITER OWN_MULTI_FIRE OWN_TRIGGER_UNOWNED OWN_EDGES_FAILED; do
  h=$(planner_crosscheck_fix_hint "$c")
  case "$h" in
  "no canned hint"* | "") fail "$name: $c" "$h" ;;
  *) pass "$name: $c" ;;
  esac
done

name="PLANNER_OWNERSHIP_FILE_EXTS lists file extensions"
contains "$name" " ${PLANNER_OWNERSHIP_FILE_EXTS:-} " " yaml "

# ── Instance tokens and accept parse ──────────────────────────────────────────

echo "=== accept parse ==="

name="instance token from a message"
if need "$name" planner_crosscheck_ownership_instance; then
  check "$name: key" "$(planner_crosscheck_ownership_instance '`invoice.status` has conflicting writers — resume INIT-1 --accept OWN_MULTI_WRITER@invoice.status:"<reason>"')" \
    "OWN_MULTI_WRITER@invoice.status"
  check "$name: slug and key" "$(planner_crosscheck_ownership_instance 'specs/r.md:3 reads `a.b` — resume INIT-1 --accept OWN_NO_WRITER@r-1/a.b:"<reason>"')" \
    "OWN_NO_WRITER@r-1/a.b"
  check "$name: none" "$(planner_crosscheck_ownership_instance 'no command here')" ""
fi

# Security: the message interpolates spec-derived text (source, anchor-failure
# reason, slug). Only the trailing accept command names the instance.
name="instance token comes from the trailing accept command only"
if need "$name" planner_crosscheck_ownership_instance; then
  check "$name: spoof in the source" "$(planner_crosscheck_ownership_instance 'specs/r.md:3 reads `a.b` (source code:x --accept OWN_NO_WRITER@other/key:") but no other spec writes it — resume INIT-1 --accept OWN_NO_WRITER@r/a.b:"<reason>"')" \
    "OWN_NO_WRITER@r/a.b"
  check "$name: text after the command" "$(planner_crosscheck_ownership_instance 'x — resume INIT-1 --accept OWN_NO_WRITER@r/a.b:"<reason>" and more')" ""
  check "$name: a quoted reason other than the placeholder" "$(planner_crosscheck_ownership_instance 'x --accept OWN_NO_WRITER@other/key:"fine"')" ""
fi

name="code: paths take a conservative charset"
if need "$name" _planner_own_path_ok; then
  for good in billing/db billing/src/Invoice.java node_modules/@scope/pkg/a+b.ts; do
    rc=0
    _planner_own_path_ok "$good" || rc=$?
    check "$name: $good" "$rc" "0"
  done
  for bad in 'billing/a b' 'billing/a"b' "billing/a'b" $'billing/a\tb' 'x --accept OWN_NO_WRITER@other/key:"'; do
    rc=0
    _planner_own_path_ok "$bad" || rc=$?
    check "$name: refuses [$bad]" "$rc" "1"
  done
fi

name="spec-derived text in a finding cannot carry a quote or an accept command"
if need "$name" _planner_xco_out; then
  out=$(_planner_xco_out OWN_NO_WRITER 'specs/a.md:1 reads `k` (source x ----accept OWN_NO_WRITER@o/k:"y")' INIT-1 'OWN_NO_WRITER@a/k')
  check "$name: one accept command" "$(grep -o -- '--accept' <<<"$out" | wc -l | tr -d ' ')" "1"
  check "$name: two quotes" "$(tr -cd '"' <<<"$out" | wc -c | tr -d ' ')" "2"
  contains "$name: tail" "$out" ' — resume INIT-1 --accept OWN_NO_WRITER@a/k:"<reason>"'
  out=$(_planner_xco_out OWN_NO_WRITER 'specs/a b.md:1 reads `k`' INIT-1 'OWN_NO_WRITER@a b/k')
  lacks "$name: an unsafe token gets no accept command" "$out" "--accept"
fi

name="accept parse: the four forms"
if need "$name" planner_crosscheck_ownership_accept_parse; then
  check "$name: multi writer" "$(planner_crosscheck_ownership_accept_parse 'OWN_MULTI_WRITER@invoice.status:"two jobs, one lock"')" \
    "OWN_MULTI_WRITER@invoice.status	two jobs, one lock"
  check "$name: multi fire" "$(planner_crosscheck_ownership_accept_parse 'OWN_MULTI_FIRE@email.x:ok')" "OWN_MULTI_FIRE@email.x	ok"
  check "$name: no writer" "$(planner_crosscheck_ownership_accept_parse 'OWN_NO_WRITER@reminder/customer.phone:"supplied by the CRM sync"')" \
    "OWN_NO_WRITER@reminder/customer.phone	supplied by the CRM sync"
  check "$name: trigger unowned" "$(planner_crosscheck_ownership_accept_parse 'OWN_TRIGGER_UNOWNED@resend_1/email:"legacy mailer"')" \
    "OWN_TRIGGER_UNOWNED@resend_1/email	legacy mailer"
fi

name="accept parse refuses bad forms"
if need "$name" planner_crosscheck_ownership_accept_parse; then
  for bad in 'OWN_MULTI_WRITER@Invoice.Status:"x"' 'OWN_MULTI_WRITER@a.b.c:"x"' 'OWN_MULTI_WRITER@r/a.b:"x"' \
    'OWN_NO_WRITER@a.b:"x"' 'OWN_NO_WRITER@a.b/c.d:"x"' 'OWN_NO_WRITER@/c.d:"x"' 'OWN_NO_WRITER@r/c.d:""' \
    'OWN_NO_WRITER@r/c.d:' 'OWN_MULTI_FIRE@email.x:"  "' 'OWN_TRIGGER_UNOWNED@r/E.x:"x"'; do
    rc=0
    planner_crosscheck_ownership_accept_parse "$bad" >/dev/null 2>&1 || rc=$?
    check "$name: $bad" "$rc" "1"
  done
  rc=0
  err=$(planner_crosscheck_ownership_accept_parse 'OWN_NO_WRITER:"all fine"' 2>&1 >/dev/null) || rc=$?
  check "$name: code-wide refused" "$rc" "1"
  contains "$name: names the per-instance form" "$err" 'OWN_NO_WRITER@<slug>/<key>:"<reason>"'
  contains "$name: names the wildcard form" "$err" 'OWN_NO_WRITER@*:"<reason>"'
  rc=0
  err=$(planner_crosscheck_ownership_accept_parse 'OWN_MULTI_FIRE' 2>&1 >/dev/null) || rc=$?
  check "$name: bare code refused" "$rc" "1"
  contains "$name: bare names the key form" "$err" 'OWN_MULTI_FIRE@<key>:"<reason>"'
fi

# ── Crosscheck run and accept ─────────────────────────────────────────────────

echo "=== crosscheck run ==="

# latest — the lines of the latest Crosscheck attempt.
latest() {
  local log start
  log=$(planner_state_log "$INIT")
  start=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  tail -n "+$((start + 1))" "$log"
}

name="the family runs inside planner_crosscheck_run, after the params family"
if need "$name" planner_crosscheck_ownership; then
  fresh
  planner_params_contract_mark "$INIT"
  ospec reminder '' 'customer.phone=spec'
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: blocks" "$rc" "1"
  lines=$(latest)
  contains "$name: fail line" "$lines" "|META|crosscheck|fail|OWN_NO_WRITER specs/reminder.md:15 "
  p=$(grep -n '|fail|PARAM_TABLE_INVALID ' <<<"$lines" | head -1 | cut -d: -f1)
  o=$(grep -n '|fail|OWN_NO_WRITER ' <<<"$lines" | head -1 | cut -d: -f1)
  if [ -n "$p" ] && [ -n "$o" ] && [ "$p" -lt "$o" ]; then pass "$name: order"; else fail "$name: order" "params=$p ownership=$o"; fi
fi

name="legacy initiative adds nothing to planner_crosscheck_run"
if need "$name" planner_crosscheck_ownership; then
  fresh legacy
  ospec reminder 'invoice.status=update' 'customer.phone=spec'
  ospec payment 'invoice.status=update;email.x=trigger' ''
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  check "$name" "$(grep -c 'OWN_' "$(planner_state_log "$INIT")" || true)" "0"
fi

name="one instance accepted, another still blocks"
if need "$name" planner_crosscheck_ownership planner_crosscheck_ownership_accept_parse; then
  fresh
  ospec reminder '' 'customer.phone=spec;customer.locale=spec'
  parsed=$(planner_crosscheck_ownership_accept_parse 'OWN_NO_WRITER@reminder/customer.phone:"supplied by the CRM sync"')
  planner_crosscheck_accept_set "$INIT" "$(cut -f1 <<<"$parsed")" "$(cut -f2 <<<"$parsed")"
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  lines=$(latest)
  check "$name: still blocks" "$rc" "1"
  contains "$name: phone accepted" "$lines" '|META|crosscheck|accepted|OWN_NO_WRITER@reminder/customer.phone specs/reminder.md:'
  contains "$name: locale fails" "$lines" '|META|crosscheck|fail|OWN_NO_WRITER specs/reminder.md:16 reads `customer.locale`'
fi

name="a code-wide accept record does not silence an instance code"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec a-job 'invoice.status=update' ''
  ospec b-job 'invoice.status=update' ''
  planner_crosscheck_accept_set "$INIT" OWN_MULTI_WRITER "all fine"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  contains "$name" "$(latest)" '|META|crosscheck|fail|OWN_MULTI_WRITER `invoice.status`'
fi

name="a spoofed accept command in a source cannot borrow another instance's accept"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec reminder '' 'customer.phone=code:x --accept OWN_NO_WRITER@other/customer.locale:"'
  planner_crosscheck_accept_set "$INIT" "OWN_NO_WRITER@other/customer.locale" "accepted elsewhere"
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: blocks" "$rc" "1"
  check "$name: nothing accepted" "$(latest | grep -c '|accepted|' || true)" "0"
  contains "$name: the row is invalid" "$(latest)" '|META|crosscheck|fail|OWN_TABLE_INVALID specs/reminder.md:15 '
fi

name="a spoofed accept command in a spec file name cannot borrow another instance's accept"
if need "$name" planner_crosscheck_ownership; then
  fresh
  ospec a-job 'invoice.status=update' ''
  ospec b-job 'invoice.status=update' ''
  ospec 'x --accept OWN_MULTI_WRITER@invoice.status:"' '' 'customer.phone=spec'
  planner_crosscheck_accept_set "$INIT" "OWN_MULTI_WRITER@invoice.status" "two jobs, one row each"
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  lines=$(latest)
  check "$name: blocks" "$rc" "1"
  contains "$name: the real instance is accepted" "$lines" '|META|crosscheck|accepted|OWN_MULTI_WRITER@invoice.status `invoice.status`'
  check "$name: the spoofing spec's read still fails" "$(grep -c '|fail|OWN_NO_WRITER ' <<<"$lines" || true)" "1"
  check "$name: one accepted line" "$(grep -c '|accepted|' <<<"$lines" || true)" "1"
fi

name="OWN_TABLE_INVALID keeps its code-wide accept"
if need "$name" planner_crosscheck_ownership; then
  fresh
  printf '# no-tables\n\n## Acceptance Criteria\n\n- [ ] x\n' >"${SPECS}/no-tables.md"
  planner_crosscheck_accept_set "$INIT" OWN_TABLE_INVALID "drafted before the contract"
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  check "$name: no OWN fail" "$(latest | grep -c '|fail|OWN_' || true)" "0"
  contains "$name: accepted" "$(latest)" '|META|crosscheck|accepted|OWN_TABLE_INVALID specs/no-tables.md'
fi

name="wildcard accept expands per current instance; a new instance still fails"
if need "$name" planner_crosscheck_ownership && [ -f "${LIB_DIR}/planner-invocation.sh" ]; then
  source "${LIB_DIR}/planner-invocation.sh"
  fresh
  ospec reminder '' 'customer.phone=spec;customer.locale=spec'
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  rc=0
  { planner_flags_parse resume "$INIT" --accept 'OWN_NO_WRITER@*:"known gaps"' &&
    planner_flags_persist "$INIT"; } >/dev/null 2>&1 || rc=$?
  log=$(planner_state_log "$INIT")
  check "$name: persisted" "$rc" "0"
  check "$name: one record per instance" \
    "$(grep '|META|crosscheck|accepted|' "$log" | cut -d'|' -f5- | paste -sd';' -)" \
    "OWN_NO_WRITER@reminder/customer.phone known gaps;OWN_NO_WRITER@reminder/customer.locale known gaps"
  check "$name: no @* record" "$(grep -c 'accepted|OWN_NO_WRITER@\*' "$log" || true)" "0"
  ospec reminder '' 'customer.phone=spec;customer.locale=spec;customer.tz=spec'
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  lines=$(latest)
  check "$name: blocks on the new one" "$rc" "1"
  check "$name: only the new one fails" "$(grep '|fail|OWN_' <<<"$lines" | grep -o '`[a-z_.]*`' | paste -sd' ' -)" '`customer.tz`'
  check "$name: two accepted" "$(grep -c '|accepted|OWN_NO_WRITER@' <<<"$lines")" "2"
fi

name="the code-wide accept form is refused at parse time"
if need "$name" planner_crosscheck_ownership && declare -f planner_flags_parse >/dev/null; then
  fresh
  rc=0
  err=$(planner_flags_parse resume "$INIT" --accept 'OWN_MULTI_FIRE:"fine"' 2>&1 >/dev/null) || rc=$?
  check "$name" "$rc" "1"
  contains "$name: wildcard named" "$err" 'OWN_MULTI_FIRE@*:"<reason>"'
fi

# ── Edges step inside planner_crosscheck_run (tasks 4.1, 4.3) ─────────────────

echo "=== edges step ==="

name="edges step runs before the deps family; DEPENDENCY_CYCLE sees ownership edges"
if need "$name" planner_ownership_edges_write; then
  fresh
  ospec ledger 'ledger=create' 'invoice.total=spec'
  ospec invoicing 'invoice=create' 'ledger.balance=spec'
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: blocks" "$rc" "1"
  lines=$(latest)
  e=$(grep -n '|META|ownership-edges|done|2 edge(s)$' <<<"$lines" | head -1 | cut -d: -f1)
  c=$(grep -n '|fail|DEPENDENCY_CYCLE ' <<<"$lines" | head -1 | cut -d: -f1)
  if [ -n "$e" ] && [ -n "$c" ] && [ "$e" -lt "$c" ]; then pass "$name: order"; else fail "$name: order" "edges=$e cycle=$c"; fi
  check "$name: one per spec" "$(grep -c '|fail|DEPENDENCY_CYCLE ' <<<"$lines")" "2"
  cyc=$(grep '|fail|DEPENDENCY_CYCLE ' <<<"$lines" | head -1)
  contains "$name: keeps testdata-synth.json" "$cyc" "artifacts/testdata-synth.json"
  contains "$name: names ownership-edges.json" "$cyc" "artifacts/ownership-edges.json"
  check "$name: no ownership finding" "$(grep -c '|crosscheck|[a-z]*|.*OWN_' <<<"$lines" || true)" "0"
fi

name="legacy initiative: no ownership-edges line, no file"
if need "$name" planner_ownership_edges_write; then
  fresh legacy
  ospec ledger 'ledger=create' 'invoice.total=spec'
  ospec invoicing 'invoice=create' ''
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  check "$name" "$(grep -c '|ownership-edges|' "$(planner_state_log "$INIT")" || true):$([ -e "${IDIR}/artifacts/ownership-edges.json" ] && echo present || echo absent)" "0:absent"
fi

name="a contract initiative with no edges writes the line with 0 and no file"
if need "$name" planner_ownership_edges_write; then
  fresh
  ospec invoicing 'invoice=create' ''
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  contains "$name" "$(latest)" "|META|ownership-edges|done|0 edge(s)"
  check "$name: no file" "$([ -e "${IDIR}/artifacts/ownership-edges.json" ] && echo present || echo absent)" "absent"
fi

name="a sidecar write failure is the blocking OWN_EDGES_FAILED"
if need "$name" planner_ownership_edges_write; then
  fresh
  ospec ledger 'ledger=create' 'invoice.total=spec'
  ospec invoicing 'invoice=create' ''
  mkdir -p "${IDIR}/artifacts/ownership-edges.json"
  rc=0
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || rc=$?
  check "$name: blocks" "$rc" "1"
  lines=$(latest)
  contains "$name" "$lines" "|META|crosscheck|fail|OWN_EDGES_FAILED "
  check "$name: no done line" "$(grep -c '|ownership-edges|done|' <<<"$lines" || true)" "0"
fi

name="OWN_EDGES_DIVERGED is a warning through planner_crosscheck_run"
if need "$name" planner_ownership_edges_write; then
  fresh
  ospec ledger 'ledger=create' ''
  ospec import 'customer=create' ''
  ospec invoicing 'invoice=create' 'ledger.balance=spec'
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  mkdir -p "${IDIR}/.intents"
  printf '{}\n' >"${IDIR}/.intents/ticket-invoicing.json"
  ospec invoicing 'invoice=create' 'customer.email=spec'
  planner_crosscheck_run "$INIT" >/dev/null 2>&1 || true
  lines=$(latest)
  check "$name: never a fail line" "$(grep -c '|fail|OWN_EDGES_DIVERGED' <<<"$lines" || true)" "0"
  contains "$name" "$lines" "|META|crosscheck|warn|info OWN_EDGES_DIVERGED specs/invoicing.md "
fi

echo ""
echo "=== planner crosscheck ownership: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
