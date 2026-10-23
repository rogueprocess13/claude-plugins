#!/usr/bin/env bash
# test-check-test-registration.sh — self-test for the test-registration drift
# gate. Each case builds a throwaway repo fixture (a few test files + a
# Makefile) and asserts the gate's exit code and message.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../check-test-registration.sh"

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

# Build a fixture repo with one bash, one pytest, and one phase runner, all
# registered; a fixtures/ test-*.sh that must be ignored; and a comment line.
_mk_repo() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/plug/lib/tests/fixtures" "$d/plug/py/tests" "$d/plug/skills/flow/tests"
  : >"$d/plug/lib/tests/test-alpha.sh"
  : >"$d/plug/py/tests/test_beta.py"
  : >"$d/plug/skills/flow/tests/phase1.sh"
  : >"$d/plug/lib/tests/fixtures/test-ignored.sh"
  : >"$d/plug/lib/tests/helper.sh"
  cat >"$d/Makefile" <<'EOF'
test:
	# a comment mentioning plug/lib/tests/test-alpha.sh does not count
	bash plug/lib/tests/test-alpha.sh
	python3 -m pytest plug/py/tests/test_beta.py -v
	CLAUDE_SKILLS_LIB="$(CURDIR)/plug/lib" bash ./plug/skills/flow/tests/phase1.sh
EOF
  echo "$d"
}

_run() { # $1=root → sets RC, OUT
  OUT="$(bash "$GATE" --root "$1" 2>&1)"
  RC=$?
}

test_clean_repo_passes() {
  local d
  d="$(_mk_repo)"
  _run "$d"
  rm -rf "$d"
  [ "$RC" -eq 0 ] && grep -q "OK — 3 test files" <<<"$OUT"
}

test_unregistered_bash_test_fails() {
  local d
  d="$(_mk_repo)"
  : >"$d/plug/lib/tests/test-gamma.sh"
  _run "$d"
  rm -rf "$d"
  [ "$RC" -eq 1 ] && grep -q "UNREGISTERED: plug/lib/tests/test-gamma.sh" <<<"$OUT"
}

test_unregistered_pytest_fails() {
  local d
  d="$(_mk_repo)"
  : >"$d/plug/py/tests/test_delta.py"
  _run "$d"
  rm -rf "$d"
  [ "$RC" -eq 1 ] && grep -q "UNREGISTERED: plug/py/tests/test_delta.py" <<<"$OUT"
}

test_unregistered_phase_runner_fails() {
  local d
  d="$(_mk_repo)"
  : >"$d/plug/skills/flow/tests/phase2.sh"
  _run "$d"
  rm -rf "$d"
  [ "$RC" -eq 1 ] && grep -q "UNREGISTERED: plug/skills/flow/tests/phase2.sh" <<<"$OUT"
}

test_comment_only_reference_is_not_registration() {
  local d
  d="$(_mk_repo)"
  : >"$d/plug/lib/tests/test-epsilon.sh"
  printf '\t# bash plug/lib/tests/test-epsilon.sh\n' >>"$d/Makefile"
  _run "$d"
  rm -rf "$d"
  [ "$RC" -eq 1 ] && grep -q "UNREGISTERED: plug/lib/tests/test-epsilon.sh" <<<"$OUT"
}

test_substring_match_is_not_registration() {
  # test-alpha.sh is registered; test-alph.sh must not ride on it.
  local d
  d="$(_mk_repo)"
  : >"$d/plug/lib/tests/test-alph.sh"
  _run "$d"
  rm -rf "$d"
  [ "$RC" -eq 1 ] && grep -q "UNREGISTERED: plug/lib/tests/test-alph.sh" <<<"$OUT"
}

test_registered_but_missing_fails() {
  local d
  d="$(_mk_repo)"
  printf '\tbash plug/lib/tests/test-gone.sh\n' >>"$d/Makefile"
  _run "$d"
  rm -rf "$d"
  [ "$RC" -eq 1 ] && grep -q "MISSING: plug/lib/tests/test-gone.sh" <<<"$OUT"
}

test_missing_makefile_is_usage_error() {
  local d
  d="$(_mk_repo)"
  rm -f "$d/Makefile"
  _run "$d"
  rm -rf "$d"
  [ "$RC" -eq 2 ]
}

test_real_repo_is_clean() {
  _run "$SCRIPT_DIR/../.."
  [ "$RC" -eq 0 ]
}

for t in \
  test_clean_repo_passes \
  test_unregistered_bash_test_fails \
  test_unregistered_pytest_fails \
  test_unregistered_phase_runner_fails \
  test_comment_only_reference_is_not_registration \
  test_substring_match_is_not_registration \
  test_registered_but_missing_fails \
  test_missing_makefile_is_usage_error \
  test_real_repo_is_clean; do
  if "$t"; then _ok "$t"; else _ko "$t (rc=${RC:-?}) ${OUT:-}"; fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
