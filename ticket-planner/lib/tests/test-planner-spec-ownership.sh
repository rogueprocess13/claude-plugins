#!/usr/bin/env bash
# test-planner-spec-ownership.sh — Tests for planner-spec-ownership.sh
# (planner-crosscheck-ownership, tasks 2.1–2.2).
#
# Pinned here:
#   1. The `## Writes` / `## Reads` parse: well-formed tables, `None.`, empty
#      and missing sections, fences, `\|` in a cell, CRLF.
#   2. Ops, keys and sources: every valid and invalid form the design names.
#   3. Anchors: `code:` through the pinned worktree, directories, the file
#      limit, word boundaries, a missing segment; `external:` found and not.
#   4. Synth-marked specs and INDEX.md are skipped; the contract marker.
#   5. mawk runs every awk program, and gawk (when installed) agrees.
#
# Every case is guarded on the functions it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary, never an
# unbound-function abort.
#
# Run: bash ticket-planner/lib/tests/test-planner-spec-ownership.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SO_LIB="${LIB_DIR}/planner-spec-ownership.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

source "${LIB_DIR}/planner-state.sh"
if [ -f "$SO_LIB" ]; then
  source "$SO_LIB"
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
# check <name> <got> <want>
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}

N=0
fresh() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((6000 + N))"
  planner_state_init "$INIT" "invoice reminders" >/dev/null
  IDIR=$(planner_initiative_dir "$INIT")
  SPECS="${IDIR}/artifacts/specs"
  mkdir -p "$SPECS"
}
# spec <slug> — write stdin to the spec file, print its path.
spec() {
  cat >"${SPECS}/$1.md"
  printf '%s\n' "${SPECS}/$1.md"
}

TAB=$'\t'
WH='| Key | Op |
|-----|----|'
RH='| Key | Source |
|-----|--------|'

# ── 1. Parse ──────────────────────────────────────────────────────────────────

echo "=== parse ==="

fresh
WELL=$(
  spec payment <<EOF
## Title

Record a payment

## Writes

${WH}
| \`invoice.status\` | transition:sent,overdue->paid |
| \`invoice_history\` | append |
| \`payment\` | create |
| \`email.payment_receipt\` | fire |
| \`email.invoice_overdue\` | trigger |

## Reads

${RH}
| \`invoice.amount_due\` | spec |
| \`invoice.due_date\` | code:billing/src |
| \`user.id\` | framework:auth_user |
| \`bank_holiday.date\` | external:public holiday feed |

## Labels

feature
EOF
)

name="well-formed Writes rows, with their lines"
if need "$name" planner_ownership_writes; then
  want="9${TAB}invoice.status${TAB}transition:sent,overdue->paid
10${TAB}invoice_history${TAB}append
11${TAB}payment${TAB}create
12${TAB}email.payment_receipt${TAB}fire
13${TAB}email.invoice_overdue${TAB}trigger"
  check "$name" "$(planner_ownership_writes "$WELL")" "$want"
fi

name="well-formed Reads rows, with their lines"
if need "$name" planner_ownership_reads; then
  want="19${TAB}invoice.amount_due${TAB}spec
20${TAB}invoice.due_date${TAB}code:billing/src
21${TAB}user.id${TAB}framework:auth_user
22${TAB}bank_holiday.date${TAB}external:public holiday feed"
  check "$name" "$(planner_ownership_reads "$WELL")" "$want"
fi

name="well-formed spec: nothing invalid"
if need "$name" planner_ownership_invalid; then
  check "$name" "$(planner_ownership_invalid "$WELL")" ""
fi

NONE=$(
  spec none <<'EOF'
## Writes

None.

## Reads

None.
EOF
)
name="None. in both sections: valid, no rows"
if need "$name" planner_ownership_writes planner_ownership_reads planner_ownership_invalid; then
  check "$name" "$(planner_ownership_writes "$NONE")|$(planner_ownership_reads "$NONE")|$(planner_ownership_invalid "$NONE")" "||"
fi

MISSING=$(
  spec missing <<'EOF'
## Title

No tables
EOF
)
name="missing sections: one missing finding each"
if need "$name" planner_ownership_invalid; then
  check "$name" "$(planner_ownership_invalid "$MISSING")" "0${TAB}writes${TAB}missing
0${TAB}reads${TAB}missing"
fi

EMPTY=$(
  spec empty <<'EOF'
## Writes

## Reads

Some prose instead of a table.
EOF
)
name="empty section and prose section"
if need "$name" planner_ownership_invalid; then
  check "$name" "$(planner_ownership_invalid "$EMPTY")" "1${TAB}writes${TAB}empty
5${TAB}reads${TAB}no-table"
fi

FENCE=$(
  spec fence <<EOF
## Writes

${WH}
| \`invoice.status\` | update |

\`\`\`
## Reads

${RH}
| \`ghost.key\` | spec |
\`\`\`

## Reads

${RH}
| \`payment.amount\` | spec |
EOF
)
name="fenced heading and rows are ignored"
if need "$name" planner_ownership_reads planner_ownership_invalid; then
  check "$name" "$(planner_ownership_reads "$FENCE")|$(planner_ownership_invalid "$FENCE")" "19${TAB}payment.amount${TAB}spec|"
fi

ESC=$(
  spec escaped <<EOF
## Writes

None.

## Reads

${RH}
| \`rate.value\` | external:FX feed A\\|B |
EOF
)
name="escaped pipe stays in the cell"
if need "$name" planner_ownership_reads; then
  check "$name" "$(planner_ownership_reads "$ESC")" "9${TAB}rate.value${TAB}external:FX feed A|B"
fi

CRLF="${SPECS}/crlf.md"
printf '## Writes\r\n\r\n| Key | Op |\r\n|-----|----|\r\n| `invoice.status` | update |\r\n\r\n## Reads\r\n\r\nNone.\r\n' >"$CRLF"
name="CRLF tolerated"
if need "$name" planner_ownership_writes planner_ownership_invalid; then
  check "$name" "$(planner_ownership_writes "$CRLF")|$(planner_ownership_invalid "$CRLF")" "5${TAB}invoice.status${TAB}update|"
fi

DUPSEC=$(
  spec dupsec <<'EOF'
## Writes

None.

## Writes

None.

## Reads

None.
EOF
)
name="a second Writes section is reported"
if need "$name" planner_ownership_invalid; then
  check "$name" "$(planner_ownership_invalid "$DUPSEC")" "5${TAB}writes${TAB}duplicate-section"
fi

BADHDR=$(
  spec badhdr <<'EOF'
## Writes

| Key | Operation |
|-----|-----------|
| `invoice.status` | update |

## Reads

None.
EOF
)
name="bad header: header row and its rows reported, no rows parsed"
if need "$name" planner_ownership_invalid planner_ownership_writes; then
  check "$name" "$(planner_ownership_invalid "$BADHDR")|$(planner_ownership_writes "$BADHDR")" "3${TAB}writes${TAB}header
5${TAB}writes${TAB}header|"
fi

# ── 2. Ops, keys, sources ─────────────────────────────────────────────────────

echo "=== ops, keys, sources ==="

OPS=$(
  spec ops <<EOF
## Writes

${WH}
| \`invoice.status\` | transition:sent,overdue->paid |
| \`ticket.status\` | transition:*->closed |
| \`a.b\` | transition:->paid |
| \`c.d\` | transition:Sent->paid |
| \`e.f\` | transition:sent>paid |
| \`g.h\` | modify |
| \`i.j\` | transition:sent,->paid |
| \`k.l\` | transition:sent->*  |
| \`m.n\` | update | extra |

## Reads

None.
EOF
)
name="valid transition ops parse"
if need "$name" planner_ownership_writes; then
  check "$name" "$(planner_ownership_writes "$OPS")" "5${TAB}invoice.status${TAB}transition:sent,overdue->paid
6${TAB}ticket.status${TAB}transition:*->closed"
fi
name="invalid ops reported with their lines"
if need "$name" planner_ownership_invalid; then
  check "$name" "$(planner_ownership_invalid "$OPS")" "7${TAB}writes${TAB}op
8${TAB}writes${TAB}op
9${TAB}writes${TAB}op
10${TAB}writes${TAB}op
11${TAB}writes${TAB}op
12${TAB}writes${TAB}op
13${TAB}writes${TAB}shape"
fi

K65="a$(printf 'b%.0s' $(seq 1 64))"
KEYS=$(
  spec keys <<EOF
## Writes

${WH}
| \`Invoice.Status\` | update |
| \`invoice.status.code\` | update |
| \`${K65}\` | update |
| invoice.total | update |
| \`invoice.total\` | update |
| \`invoice.total\` | delete |
| \`1abc\` | update |
| \`email.sent\` | fire |

## Reads

${RH}
| \`email.sent\` | spec |
| \`invoice.total\` | spec |
EOF
)
name="key grammar: upper case, three segments, 65 chars, unquoted, duplicate, digit start"
if need "$name" planner_ownership_invalid; then
  check "$name" "$(planner_ownership_invalid "$KEYS")" "5${TAB}writes${TAB}key
6${TAB}writes${TAB}key
7${TAB}writes${TAB}key
8${TAB}writes${TAB}key
10${TAB}writes${TAB}duplicate-key
11${TAB}writes${TAB}key
18${TAB}reads${TAB}effect-key"
fi
name="key grammar: the valid rows survive"
if need "$name" planner_ownership_writes planner_ownership_reads; then
  check "$name" "$(planner_ownership_writes "$KEYS")|$(planner_ownership_reads "$KEYS")" "9${TAB}invoice.total${TAB}update
12${TAB}email.sent${TAB}fire|19${TAB}invoice.total${TAB}spec"
fi

K64="a$(printf 'b%.0s' $(seq 1 63))"
K64S=$(
  spec k64 <<EOF
## Writes

${WH}
| \`${K64}\` | update |

## Reads

None.
EOF
)
name="a 64-character key is valid"
if need "$name" planner_ownership_invalid; then
  check "$name" "$(planner_ownership_invalid "$K64S")" ""
fi

SRCS=$(
  spec sources <<EOF
## Writes

None.

## Reads

${RH}
| \`a.b\` | code:../billing/src |
| \`c.d\` | code:/etc/passwd |
| \`e.f\` | code:billing/../../x |
| \`g.h\` | framework:magic |
| \`i.j\` | external:ab |
| \`k.l\` | code: |
| \`m.n\` | Spec |
| \`o.p\` | framework:clock |
| \`q.r\` | external:abc |
| \`s.t\` | code:billing |
EOF
)
name="source grammar: dot-dot, leading slash, unknown framework, short external, empty code"
if need "$name" planner_ownership_invalid; then
  check "$name" "$(planner_ownership_invalid "$SRCS")" "9${TAB}reads${TAB}source
10${TAB}reads${TAB}source
11${TAB}reads${TAB}source
12${TAB}reads${TAB}source
13${TAB}reads${TAB}source
14${TAB}reads${TAB}source
15${TAB}reads${TAB}source"
fi
name="source grammar: valid sources survive"
if need "$name" planner_ownership_reads; then
  check "$name" "$(planner_ownership_reads "$SRCS" | cut -f2,3 | tr '\n' ' ')" "o.p${TAB}framework:clock q.r${TAB}external:abc s.t${TAB}code:billing "
fi

name="framework allowlist constant"
check "$name" "${PLANNER_OWNERSHIP_FRAMEWORK_SOURCES:-}" "auth_user session clock timestamps row_id tenant"
name="code file limit constant"
check "$name" "${PLANNER_OWNERSHIP_CODE_MAX_FILES:-}" "200"

# ── 3. Anchors ────────────────────────────────────────────────────────────────

echo "=== anchors ==="

# A billing repo whose pinned sha has the column and whose live HEAD does not.
BR="${REPOS_ROOT}/billing"
mkdir -p "${BR}/src/main/resources/db"
git -C "$BR" init -q -b main
printf 'create table invoice (\n  id bigint,\n  due_date date\n);\n' >"${BR}/src/main/resources/db/changelog.sql"
git -C "$BR" add -A
git -C "$BR" commit -qm pinned
PINNED=$(git -C "$BR" rev-parse HEAD)
printf 'create table invoice (\n  id bigint\n);\n' >"${BR}/src/main/resources/db/changelog.sql"
mkdir -p "${BR}/src/model"
cat >"${BR}/src/model/Invoice.java" <<'EOF'
public class Invoice {
  private boolean valid;
  private String userName;
}
EOF
cat >"${BR}/src/model/Reminder.kt" <<'EOF'
data class Reminder(val dueDate: LocalDate, val SEND_AT: Instant)
EOF
git -C "$BR" add -A
git -C "$BR" commit -qm live

# eff <INIT> <source> <key> — the effective-source line.
eff() { planner_ownership_read_effective "$@" 2>/dev/null; }

fresh
name="code: anchor through the pinned worktree (live checkout lacks the column)"
if need "$name" planner_ownership_read_effective; then
  planner_state_write "$INIT" META discovery repo-ref "billing@main@${PINNED}" >/dev/null
  check "$name" "$(eff "$INIT" code:billing/src/main/resources/db invoice.due_date)" "code"
fi
name="code: same anchor without a pin reads the live checkout and fails"
if need "$name" planner_ownership_read_effective; then
  INIT_PIN="$INIT"
  fresh
  got=$(eff "$INIT" code:billing/src/main/resources/db invoice.due_date)
  check "$name" "${got%%"$TAB"*}" "spec"
fi
name="code: failed anchor carries the reason"
if need "$name" planner_ownership_read_effective; then
  got=$(eff "$INIT" code:billing/src/main/resources/db/changelog.sql invoice.due_date)
  check "$name" "$got" "spec${TAB}key not named in file"
fi
name="code: directory target searched recursively"
if need "$name" planner_ownership_read_effective; then
  check "$name" "$(eff "$INIT" code:billing/src reminder.due_date)" "code"
fi
name="code: dueDate and DUE_DATE match due_date style keys"
if need "$name" planner_ownership_read_effective; then
  check "$name" "$(eff "$INIT" code:billing/src/model/Reminder.kt reminder.send_at)" "code"
fi
name="code: id does not match valid"
if need "$name" planner_ownership_read_effective; then
  got=$(eff "$INIT" code:billing/src/model/Invoice.java invoice.id)
  check "$name" "$got" "spec${TAB}key not named in file"
fi
name="code: userName matches user (lower-to-upper boundary)"
if need "$name" planner_ownership_read_effective; then
  check "$name" "$(eff "$INIT" code:billing/src/model/Invoice.java user.name)" "code"
fi
name="code: a missing segment fails"
if need "$name" planner_ownership_read_effective; then
  got=$(eff "$INIT" code:billing/src/model/Invoice.java invoice.paid_at)
  check "$name" "${got%%"$TAB"*}" "spec"
fi
name="code: nonexistent path fails with its reason"
if need "$name" planner_ownership_read_effective; then
  check "$name" "$(eff "$INIT" code:billing/nope invoice)" "spec${TAB}path not found"
fi
name="code: unknown repository fails with its reason"
if need "$name" planner_ownership_read_effective; then
  check "$name" "$(eff "$INIT" code:nosuchrepo/src invoice)" "spec${TAB}repository not found"
fi
name="code: dot-dot path is refused"
if need "$name" planner_ownership_read_effective; then
  check "$name" "$(eff "$INIT" code:billing/../billing/src invoice)" "spec${TAB}invalid path"
fi
name="code: nested repository path (repo recorded as a relative path)"
if need "$name" planner_ownership_read_effective; then
  NR="${REPOS_ROOT}/microservices/ledger"
  mkdir -p "${NR}/db"
  git -C "$NR" init -q -b main
  printf 'CREATE TABLE ledger_entry (amount numeric);\n' >"${NR}/db/schema.sql"
  git -C "$NR" add -A
  git -C "$NR" commit -qm one
  check "$name" "$(eff "$INIT" code:microservices/ledger/db ledger_entry.amount)" "code"
fi

name="code: directory search stops at the file limit"
if need "$name" planner_ownership_read_effective; then
  LR="${REPOS_ROOT}/many"
  mkdir -p "${LR}/d"
  git -C "$LR" init -q -b main
  for i in $(seq 1 6); do printf 'nothing here\n' >"${LR}/d/f${i}.txt"; done
  printf 'widget colour\n' >"${LR}/d/f9.txt"
  git -C "$LR" add -A
  git -C "$LR" commit -qm many
  a=$(PLANNER_OWNERSHIP_CODE_MAX_FILES=3 eff "$INIT" code:many/d widget.colour)
  b=$(eff "$INIT" code:many/d widget.colour)
  check "$name" "${a%%"$TAB"*} ${b}" "spec code"
fi

name="spec and framework sources need no anchor"
if need "$name" planner_ownership_read_effective; then
  check "$name" "$(eff "$INIT" spec invoice.status)|$(eff "$INIT" framework:clock clock.now)" "spec|framework"
fi

name="external: found with different case and wrapping"
if need "$name" planner_ownership_read_effective; then
  printf 'Holidays come from the\n  Public   HOLIDAY\nfeed every night.\n' >"${IDIR}/artifacts/architecture.md"
  check "$name" "$(eff "$INIT" "external:public holiday feed" bank_holiday.date)" "external"
fi
name="external: found in idea.txt"
if need "$name" planner_ownership_read_effective; then
  printf 'Pull rates from the FX gateway.\n' >"${IDIR}/artifacts/idea.txt"
  check "$name" "$(eff "$INIT" "external:fx gateway" rate.value)" "external"
fi
name="external: not found carries a reason"
if need "$name" planner_ownership_read_effective; then
  got=$(eff "$INIT" "external:crm sync" customer.phone)
  case "$got" in "external${TAB}"?*) pass "$name" ;; *) fail "$name" "got [$got]" ;; esac
fi

# ── 4. Skips and contract ─────────────────────────────────────────────────────

echo "=== skips and contract ==="

name="synth marker matches the test-data lib's"
if [ -f "${LIB_DIR}/planner-crosscheck-testdata.sh" ]; then
  td=$(bash -c 'source "$1/planner-crosscheck-testdata.sh" >/dev/null 2>&1; printf %s "$PLANNER_TESTDATA_SYNTH_MARKER"' _ "$LIB_DIR")
  check "$name" "${PLANNER_OWNERSHIP_SYNTH_MARKER:-}" "$td"
fi

fresh
SYN=$(
  spec invoice-test-data <<'EOF'
<!-- planner:testdata-synth v1 -->
## Title

Seed invoices
EOF
)
IDX=$(
  spec INDEX <<'EOF'
# Index
EOF
)
name="synth-marked spec and INDEX.md are skipped"
if need "$name" planner_ownership_spec_checked planner_ownership_invalid planner_ownership_writes; then
  r=""
  planner_ownership_spec_checked "$SYN" && r="${r}syn "
  planner_ownership_spec_checked "$IDX" && r="${r}idx "
  planner_ownership_spec_checked "$MISSING" && r="${r}missing "
  check "$name" "${r}|$(planner_ownership_invalid "$SYN")|$(planner_ownership_invalid "$IDX")|$(planner_ownership_writes "$SYN")" "missing |||"
fi

name="contract marker written once, initiative recognised"
if need "$name" planner_ownership_contract_mark planner_ownership_contract_initiative; then
  r=""
  planner_ownership_contract_initiative "$INIT" && r="before "
  planner_ownership_contract_mark "$INIT"
  planner_ownership_contract_mark "$INIT"
  planner_ownership_contract_initiative "$INIT" && r="${r}after"
  n=$(grep -c '|META|contract|start|spec-ownership-v1$' "$(planner_state_log "$INIT")" || true)
  check "$name" "${r} ${n}" "after 1"
fi

# ── 5. mawk / gawk ────────────────────────────────────────────────────────────

echo "=== awk portability ==="

run_all() {
  local f
  for f in "$SPECS"/../../../*/artifacts/specs/*.md; do
    [ -f "$f" ] || continue
    printf '%s\n' "${f##*/}"
    planner_ownership_writes "$f"
    planner_ownership_reads "$f"
    planner_ownership_invalid "$f"
  done
  eff "$INIT_PIN" code:billing/src/main/resources/db invoice.due_date
  eff "$INIT_PIN" code:billing/src/model/Invoice.java invoice.id
  eff "$INIT_PIN" code:billing/src/model/Reminder.kt reminder.send_at
  eff "$INIT_PIN" code:billing/src/model/Invoice.java user.name
}

name="mawk runs every awk program"
if need "$name" planner_ownership_writes planner_ownership_read_effective; then
  if command -v mawk >/dev/null 2>&1; then
    m=$(PLANNER_OWNERSHIP_AWK=mawk run_all 2>&1)
    if [ -n "$m" ] && ! grep -qi 'syntax error\|mawk:' <<<"$m"; then pass "$name"; else fail "$name" "$(head -3 <<<"$m")"; fi
    if command -v gawk >/dev/null 2>&1; then
      g=$(PLANNER_OWNERSHIP_AWK=gawk run_all 2>&1)
      if [ "$m" = "$g" ]; then
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
echo "=== planner spec ownership: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
