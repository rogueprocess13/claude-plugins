#!/usr/bin/env bash
# test-check-grep-q-pipe.sh — self-test for scripts/check-grep-q-pipe.sh, the
# lint gate against `echo … | grep -q` (SIGPIPE under pipefail, GitHub #640).
# Each case writes one shell file into a throwaway (non-git) root and asserts
# the gate's exit code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../check-grep-q-pipe.sh"

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

# $1 = expected rc, $2 = description, $3 = relative path, stdin = file body.
_case() {
  local want="$1" desc="$2" rel="$3" d rc out
  d="$(mktemp -d)"
  mkdir -p "$d/$(dirname "$rel")"
  cat >"$d/$rel"
  out="$(bash "$GATE" --root "$d" 2>&1)"
  rc=$?
  rm -rf "$d"
  if [ "$rc" -eq "$want" ]; then
    _ok "$desc"
  else
    _ko "$desc (rc=$rc, want $want): $out"
  fi
}

_case 1 "echo | grep -q is flagged" plug/lib/a.sh <<'EOF'
if echo "$x" | grep -q foo; then :; fi
EOF
_case 1 "printf '%s\n' | grep -qiE is flagged" plug/lib/a.sh <<'EOF'
printf '%s\n' "$x" | grep -qiE 'foo|bar' && echo hit
EOF
_case 1 "printf without newline | grep -qF -- is flagged" plug/lib/a.sh <<'EOF'
printf '%s' "$x" | grep -qF -- "$y" || exit 1
EOF
_case 1 "negated, inside \$( ), and with 2>/dev/null is flagged" plug/lib/a.sh <<'EOF'
r=$(! echo "$x" | grep -q foo 2>/dev/null && echo yes)
EOF
_case 1 "separate -q flag is flagged" plug/lib/a.sh <<'EOF'
echo "$x" | grep -E -q 'a+'
EOF
_case 1 "--quiet is flagged" plug/lib/a.sh <<'EOF'
echo "$x" | grep --quiet foo
EOF
_case 1 "pipe at end of line, grep -q on the next is flagged" plug/lib/a.sh <<'EOF'
if echo "$x" |
  grep -qx foo; then :; fi
EOF
_case 1 "hooks/ and skills/ files are scanned" plug/skills/s/run.sh <<'EOF'
echo "$x" | grep -qw foo
EOF

_case 0 "here-string form passes" plug/lib/a.sh <<'EOF'
grep -q foo <<<"$x" && grep -qiE 'a|b' <<<"$y"
EOF
_case 0 "non-quiet grep passes" plug/lib/a.sh <<'EOF'
n=$(echo "$x" | grep -c foo)
echo "$x" | grep -o foo
EOF
_case 0 "|| is not a pipe" plug/lib/a.sh <<'EOF'
echo "$x" || grep -q foo file
EOF
_case 0 "comment lines are skipped" plug/lib/a.sh <<'EOF'
# never write: echo "$x" | grep -q foo
EOF
_case 1 "test files are scanned too" plug/lib/tests/test-a.sh <<'EOF'
echo "$x" | grep -q foo
EOF
_case 0 "the gate's own self-test (its fixtures) is skipped" scripts/tests/test-check-grep-q-pipe.sh <<'EOF'
echo "$x" | grep -q foo
EOF
_case 0 "a word ending in echo is not echo" plug/lib/a.sh <<'EOF'
myecho "$x" | grep -v foo
EOF

# The gate must not flag its own source.
d="$(mktemp -d)"
mkdir -p "$d/scripts"
cp "$GATE" "$d/scripts/check-grep-q-pipe.sh"
if bash "$GATE" --root "$d" >/dev/null 2>&1; then
  _ok "the gate does not flag itself"
else
  _ko "the gate flags its own source"
fi
rm -rf "$d"

bash "$GATE" --bogus >/dev/null 2>&1
[ $? -eq 2 ] && _ok "unknown argument exits 2" || _ko "unknown argument did not exit 2"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
