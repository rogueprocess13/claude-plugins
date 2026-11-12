#!/usr/bin/env bash
# test-drift-report.sh — self-test for scripts/drift-report.sh (next.md Step 18
# item 3). A stub `claude` (DRIFT_CLAUDE_BIN) answers per document from a map
# file, so no real model is ever called. Each case builds a throwaway git repo
# as --root.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/../drift-report.sh"

PASS=0
FAIL=0
_ok() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
_ko() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}
_assert() { # desc, command...
  local desc="$1"
  shift
  if "$@"; then _ok "$desc"; else _ko "$desc"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub claude: reads the prompt on stdin, finds the document it names, looks
# up a behaviour in $STUB_MAP (doc<TAB>mode) and acts on it. Every call's
# arguments and prompt are appended to $STUB_LOG.
STUB="$WORK/claude-stub"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
prompt="$(cat)"
{
  echo "ARGS: $*"
  printf '%s\n' "$prompt"
} >>"$STUB_LOG"
doc="" mode=""
while IFS=$'\t' read -r d m; do
  case "$prompt" in *"$d"*) doc="$d" mode="$m" ;; esac
done <"$STUB_MAP"
_env() { jq -n --arg r "$1" '{type:"result",is_error:false,result:$r}'; }
case "$mode" in
clean) _env "Checked it.
DRIFT_RESULT v1
DOC: $doc
END" ;;
drift2) _env "DRIFT_RESULT v1
DOC: $doc
FINDING|missing-field|## Fields|lib/a.sh:12|doc lists field x, code has none
FINDING|hardcoded|## Retry|lib/b.sh:40|spec says configurable, code hardcodes 3
END" ;;
badkind) _env "DRIFT_RESULT v1
DOC: $doc
FINDING|style|## A|lib/a.sh:1|wording
END" ;;
docmismatch) _env "DRIFT_RESULT v1
DOC: other/doc.md
END" ;;
noend) _env "DRIFT_RESULT v1
DOC: $doc
FINDING|missing-field|## A|lib/a.sh:1|x" ;;
noblock) _env "All good, nothing to report." ;;
fail)
  echo "boom" >&2
  exit 3
  ;;
sleep) sleep 5 ;;
empty) : ;;
iserr) jq -n '{type:"result",is_error:true,subtype:"error_max_budget_usd",result:""}' ;;
twoblocks) _env "Draft:
DRIFT_RESULT v1
DOC: $doc
FINDING|missing-field|## A|lib/a.sh:1|draft finding
END
Final, in a fence:
\`\`\`
DRIFT_RESULT v1
DOC: $doc
END
\`\`\`" ;;
refs) _env "DRIFT_RESULT v1
DOC: $doc
FINDING|missing-field|## A|plug/README.md:1|real file, real line
FINDING|missing-field|## B|plug/README.md:999|line out of range
FINDING|missing-field|## C|nope/x.sh|no such file
FINDING|dead-reference|## D|docs/gone.md|cited file missing
FINDING|dead-reference|## E|plug/README.md|cited file exists
FINDING|hardcoded|## F|plug/README.md|summary with a | pipe inside
END" ;;
raw) printf 'DRIFT_RESULT v1\nDOC: %s\nFINDING|dead-reference|## See|docs/gone.md|cited file missing\nEND\n' "$doc" ;;
*) exit 9 ;;
esac
STUBEOF
chmod +x "$STUB"

# _repo <dir> <doc>... — a git repo with the given tracked docs, plus one
# untracked doc and one openspec spec.
_repo() {
  local d="$1"
  shift
  mkdir -p "$d"
  git -C "$d" init -q
  local f
  for f in "$@"; do
    mkdir -p "$d/$(dirname "$f")"
    echo "# $f" >"$d/$f"
  done
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  mkdir -p "$d/plug/docs" "$d/openspec/specs/cap-a"
  echo untracked >"$d/plug/docs/untracked.md"
  echo spec >"$d/openspec/specs/cap-a/spec.md"
}

# _run <root> <map-lines> [args...] — runs the SUT; sets RC and OUTDIR.
_run() {
  local root="$1" map="$2"
  shift 2
  export STUB_MAP="$WORK/map.$RANDOM" STUB_LOG="$WORK/log.$RANDOM"
  printf '%b' "$map" >"$STUB_MAP"
  : >"$STUB_LOG"
  OUTDIR="$WORK/out.$RANDOM"
  DRIFT_CLAUDE_BIN="$STUB" DRIFT_TIMEOUT="${DRIFT_TIMEOUT:-20}" \
    bash "$SUT" --root "$root" --out "$OUTDIR" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
  RC=$?
}

R1="$WORK/r1"
_repo "$R1" plug/docs/a.md plug/docs/b.md other/docs/c.md plug/README.md

# ── Target selection ────────────────────────────────────────────────────────
_run "$R1" "" --list
_assert "--list exits 0" [ "$RC" -eq 0 ]
_assert "--list spawns nothing" [ ! -s "$STUB_LOG" ]
_assert "--list prints sorted targets (spec, tracked docs only)" \
  [ "$(cat "$WORK/stdout")" = "$(printf '%s\n' openspec/specs/cap-a/spec.md other/docs/c.md plug/docs/a.md plug/docs/b.md)" ]

_run "$R1" "" --list --only 'plug/*'
_assert "--only narrows by glob" [ "$(cat "$WORK/stdout")" = "$(printf '%s\n' plug/docs/a.md plug/docs/b.md)" ]

_run "$R1" "" --only 'nomatch/*'
_assert "--only with no match exits 2" [ "$RC" -eq 2 ]
_assert "no-match message on stderr" grep -q "no target" "$WORK/stderr"

_run "$R1" "" --bogus
_assert "unknown flag exits 2" [ "$RC" -eq 2 ]

# ── Clean and drift ─────────────────────────────────────────────────────────
_run "$R1" "plug/docs/a.md\tclean\nplug/docs/b.md\tdrift2\n" --only 'plug/*' -j 2
_assert "all ran → exit 0 even with drift" [ "$RC" -eq 0 ]
_assert "clean doc recorded" grep -qP '^plug/docs/a\.md\tclean\t0$' "$OUTDIR/results.tsv"
_assert "drift doc recorded with 2 findings" grep -qP '^plug/docs/b\.md\tdrift\t2$' "$OUTDIR/results.tsv"
_assert "report counts" grep -q 'Checked: 2 · Clean: 1 · Drift: 1 · Not run: 0' "$OUTDIR/report.md"
_assert "report lists finding code ref" grep -q 'lib/b.sh:40' "$OUTDIR/report.md"
_assert "raw capture kept" [ -s "$OUTDIR/raw/plug__docs__b.md.out" ]
_assert "read-only tool set enforced (--tools)" grep -q -- '--tools Read,Grep,Glob' "$STUB_LOG"
_assert "no session persistence, no MCP, budget cap" grep -q -- '--no-session-persistence.*--strict-mcp-config --max-budget-usd 2' "$STUB_LOG"
_assert "prompt arrives intact on stdin" grep -q '^DRIFT_RESULT v1$' "$STUB_LOG"
_assert "prompt names the document" grep -q 'plug/docs/a.md' "$STUB_LOG"
_assert "prompt template substituted" [ "$(grep -c '{DOC}' "$STUB_LOG")" -eq 0 ]

# ── Not run, never clean ────────────────────────────────────────────────────
_nr() { # mode, reason
  _run "$R1" "plug/docs/a.md\t$1\n" --only 'plug/docs/a.md'
  _assert "$1 → exit 1" [ "$RC" -eq 1 ]
  _assert "$1 → not_run ($2)" grep -qP "^plug/docs/a\\.md\\tnot_run:$2\\t-\$" "$OUTDIR/results.tsv"
  _assert "$1 → listed under Not run" grep -q "plug/docs/a.md — $2" "$OUTDIR/report.md"
}
_nr badkind malformed
_nr docmismatch malformed
_nr noend malformed
_nr noblock malformed
_nr fail exit-3
_nr iserr is-error
_nr empty empty
DRIFT_TIMEOUT=1 _nr sleep timeout

# ── Raw (non-JSON) output is parsed directly ────────────────────────────────
_run "$R1" "plug/docs/a.md\traw\n" --only 'plug/docs/a.md'
_assert "raw text output parsed" grep -qP '^plug/docs/a\.md\tdrift\t1$' "$OUTDIR/results.tsv"

# ── Last block wins, code fences tolerated ───────────────────────────────────
_run "$R1" "plug/docs/a.md\ttwoblocks\n" --only 'plug/docs/a.md'
_assert "last block wins (draft ignored) → clean" grep -qP '^plug/docs/a\.md\tclean\t0$' "$OUTDIR/results.tsv"

# ── Deterministic code-ref verification ─────────────────────────────────────
_run "$R1" "plug/docs/a.md\trefs\n" --only 'plug/docs/a.md'
F="$OUTDIR/res/plug__docs__a.md.findings"
_ref() { awk -F'\t' -v a="$1" '$3 == a { print $5 }' "$F"; }
_assert "existing file:line → ok" [ "$(_ref '## A')" = ok ]
_assert "line out of range → unverified" [ "$(_ref '## B')" = unverified ]
_assert "missing file → unverified" [ "$(_ref '## C')" = unverified ]
_assert "dead-reference to missing path → ok" [ "$(_ref '## D')" = ok ]
_assert "dead-reference to existing path → unverified" [ "$(_ref '## E')" = unverified ]
_assert "summary keeps its pipe" grep -q 'summary with a | pipe inside' "$F"

# ── Resume skips finished documents, re-runs not-run ones ───────────────────
_run "$R1" "plug/docs/a.md\tclean\nplug/docs/b.md\tfail\n" --only 'plug/*'
_assert "first pass: one not run → exit 1" [ "$RC" -eq 1 ]
PREV="$OUTDIR"
printf 'plug/docs/a.md\tfail\nplug/docs/b.md\tclean\n' >"$STUB_MAP"
: >"$STUB_LOG"
DRIFT_CLAUDE_BIN="$STUB" bash "$SUT" --root "$R1" --out "$PREV" --only 'plug/*' --resume >/dev/null 2>&1
RC=$?
_assert "resume → exit 0" [ "$RC" -eq 0 ]
_assert "resume re-ran only the not-run doc" [ "$(grep -c '^ARGS:' "$STUB_LOG")" -eq 1 ]
_assert "resume kept the clean result" grep -qP '^plug/docs/a\.md\tclean\t0$' "$PREV/results.tsv"

# ── Over 50 findings is malformed ───────────────────────────────────────────
STUB2="$WORK/claude-many"
cat >"$STUB2" <<'EOF'
#!/usr/bin/env bash
printf 'DRIFT_RESULT v1\nDOC: plug/docs/a.md\n'
for i in $(seq 51); do echo "FINDING|missing-field|## A|x.sh:$i|n$i"; done
echo END
EOF
chmod +x "$STUB2"
OUTDIR="$WORK/out.many"
DRIFT_CLAUDE_BIN="$STUB2" bash "$SUT" --root "$R1" --out "$OUTDIR" --only 'plug/docs/a.md' >/dev/null 2>&1
RC=$?
_assert ">50 findings → not run malformed" grep -qP '\tnot_run:malformed\t' "$OUTDIR/results.tsv"

echo
echo "drift-report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
