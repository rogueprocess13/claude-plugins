#!/usr/bin/env bash
# verify-mode.sh — the one home of ticket-shape (verification mode) detection
# (skill-deterministic-extraction 4).
#
# One classifier, one authority (decision 3 of skill-deterministic-extraction):
#
#   verify_mode_classify <text>
#     Prints browser | build-only | live-backend. ticket-verify Step 1e runs
#     on it, and gate-check.sh Check 2.6 maps the same answer to a
#     prerequisite profile, so the gate never holds a ticket as one shape
#     while verify runs it as another.
#     live-backend: no browser signal, and either an infra/runtime keyword or
#       an explicit "Test User: N/A" (plain or bold, either colon placement)
#       together with a full-stack environment.
#     build-only:   no browser signal and a build-tool signal.
#     browser:      everything else (the default).
#     Live-backend is tested before build-only: a ticket can mention mvn or
#     pom.xml in passing while its acceptance criteria are runtime checks.
#
#   verify_mode_text <plan-file> <ticket-dir> [description-file]
#     The text verify classifies: the plan, then context.md, then the
#     description. Both callers build their input through it.
#
#   verify_mode_gate_profile <text> <has_nav_path> <has_test_user>
#     gate-check.sh Check 2.6: which prerequisites the plan must carry.
#     Prints browser | build-only | api-only.
#       live-backend -> api-only (expected behaviour + environment setup)
#       build-only   -> build-only (a build command + a success outcome)
#       browser      -> browser when the text has a browser signal or the plan
#                       names a test user or a nav path; api-only when it has
#                       no signal of any kind (verify still runs a browser
#                       there; the gate does not demand a login and a page a
#                       pure backend change cannot supply).
#
# Change a regex here, never in a caller.
#
# CLI (ticket-verify Step 1e):
#   verify-mode.sh <TICKET-ID> --ticket-dir D [--root R] [--description-file F] [--no-log]
# Plan text: the ticket's simple-fix plan (ticket-dir.sh plan --type
# simple-fix), else D/notes.md; then D/context.md; then the description file.
# Prints VERIFY_MODE=<mode> and, unless --no-log, writes
# VERIFY|load-context|done|Context loaded, mode=<mode> through plog.sh.
# Exit 0, 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_VERIFY_MODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _verify_mode_signals <text> — prints "browser build live na full" counts.
_verify_mode_signals() {
  local _signal_text="${1:-}" _b _bu _l _na _fs
  _b=$(grep -ciE '\b(navigate|click|button|dropdown|screen|browser|playwright|snapshot|login|nav[- ]?bar)\b|\bopen(s|ed|ing)? (the |a |modal|dialog|page)\b' <<<"$_signal_text" || true)
  _bu=$(grep -ciE '\b(mvn|maven|gradle|pom\.xml|build\.gradle|clean install|clean compile|clean package|mvn test|BUILD SUCCESS)\b' <<<"$_signal_text" || true)
  _l=$(grep -ciE '\b(docker compose|eureka|circuit breaker|service.to.service|downstream failure|register(s|ed)? with)\b' <<<"$_signal_text" || true)
  # "**Test User:** N/A" (bold label, colon inside) and "**Test User**: N/A"
  # both count; the stars before "Test User" stay required.
  _na=$(grep -ciE '\*\*?Test User\*{0,2}:?\*{0,2}\s*N/A' <<<"$_signal_text" || true)
  _fs=$(grep -ciE '\b(docker compose|full stack)\b' <<<"$_signal_text" || true)
  echo "${_b:-0} ${_bu:-0} ${_l:-0} ${_na:-0} ${_fs:-0}"
}

verify_mode_classify() {
  local _browser_signals _build_signals _live_backend_signals _test_user_na _env_full_stack
  read -r _browser_signals _build_signals _live_backend_signals _test_user_na _env_full_stack <<<"$(_verify_mode_signals "${1:-}")"
  if [ "${_browser_signals:-0}" -eq 0 ] && { [ "${_live_backend_signals:-0}" -gt 0 ] || { [ "${_test_user_na:-0}" -gt 0 ] && [ "${_env_full_stack:-0}" -gt 0 ]; }; }; then
    echo "live-backend"
  elif [ "${_browser_signals:-0}" -eq 0 ] && [ "${_build_signals:-0}" -gt 0 ]; then
    echo "build-only"
  else
    echo "browser"
  fi
}

verify_mode_text() {
  local plan="${1:-}" td="${2:-}" desc_file="${3:-}" description=""
  [ -n "$desc_file" ] && description=$(cat "$desc_file" 2>/dev/null)
  printf '%s\n%s' "$(cat "$plan" "$td/context.md" 2>/dev/null)" "$description"
}

_vm_found() { case "${1:-0}" in "" | 0) return 1 ;; *) return 0 ;; esac }

verify_mode_gate_profile() {
  local text="${1:-}" has_nav="${2:-0}" has_user="${3:-0}" mode browser
  mode=$(verify_mode_classify "$text")
  case "$mode" in
  live-backend) echo "api-only" ;;
  build-only) echo "build-only" ;;
  *)
    read -r browser _ <<<"$(_verify_mode_signals "$text")"
    if _vm_found "$browser" || _vm_found "$has_nav" || _vm_found "$has_user"; then
      echo "browser"
    else
      echo "api-only"
    fi
    ;;
  esac
}

_verify_mode_usage() {
  echo "usage: verify-mode.sh <TICKET-ID> --ticket-dir D [--root R] [--description-file F] [--no-log]" >&2
}

_verify_mode_main() {
  local tid="" td="" root="" desc_file="" log=1
  while [ $# -gt 0 ]; do
    case "$1" in
    --ticket-dir)
      [ $# -ge 2 ] || {
        _verify_mode_usage
        return 2
      }
      td="$2"
      shift 2
      ;;
    --root)
      [ $# -ge 2 ] || {
        _verify_mode_usage
        return 2
      }
      root="$2"
      shift 2
      ;;
    --description-file)
      [ $# -ge 2 ] || {
        _verify_mode_usage
        return 2
      }
      desc_file="$2"
      shift 2
      ;;
    --no-log)
      log=0
      shift
      ;;
    -*)
      _verify_mode_usage
      return 2
      ;;
    *)
      [ -z "$tid" ] || {
        _verify_mode_usage
        return 2
      }
      tid="$1"
      shift
      ;;
    esac
  done
  [ -n "$tid" ] && [ -n "$td" ] || {
    _verify_mode_usage
    return 2
  }

  local _plan_file mode
  _plan_file=$(bash "$_VERIFY_MODE_DIR/ticket-dir.sh" plan "$tid" --root "$root" --type simple-fix 2>/dev/null | sed -n 's/^PLAN_PATH=//p')
  [ -z "$_plan_file" ] && _plan_file="$td/notes.md"
  mode=$(verify_mode_classify "$(verify_mode_text "$_plan_file" "$td" "$desc_file")")
  echo "VERIFY_MODE=$mode"
  if [ "$log" = 1 ]; then
    bash "$_VERIFY_MODE_DIR/plog.sh" VERIFY load-context done "Context loaded, mode=${mode}"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _verify_mode_main "$@"
  exit $?
fi
