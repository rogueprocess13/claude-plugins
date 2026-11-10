#!/usr/bin/env bash
# verify-mode.sh — the one home of ticket-shape (verification mode) detection
# (skill-deterministic-extraction 4).
#
# Two classifiers live here, side by side, so neither is a second copy hidden
# in another file:
#
#   verify_mode_classify <text>
#     ticket-verify Step 1e. Prints browser | build-only | live-backend.
#     live-backend: no browser signal, and either an infra/runtime keyword or
#       an explicit "Test User: N/A" together with a full-stack environment.
#     build-only:   no browser signal and a build-tool signal.
#     browser:      everything else (the default).
#     Live-backend is tested before build-only: a ticket can mention mvn or
#     pom.xml in passing while its acceptance criteria are runtime checks.
#
#   verify_mode_gate_class <artifact> <has_nav_path> <has_test_user>
#     gate-check.sh Check 2.6. Prints browser | build-only | api-only |
#     infra-only: which verification prerequisites the plan artifact must
#     carry. Reads the artifact only, and only reclassifies away from browser
#     when the artifact has no nav path (and, for build/api, no test user).
#
# The two answer different questions over different inputs (the verify phase
# reads the plan, context.md and the description; the gate reads only the
# plan artifact) and use different signal vocabularies. They are kept
# byte-identical to the blocks they replaced; making them agree is a separate,
# behaviour-changing decision (see the change's handoff.md). Change either one
# here, never in a caller.
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

verify_mode_classify() {
  local _signal_text="${1:-}"
  local _browser_signals _build_signals _live_backend_signals _test_user_na _env_full_stack
  _browser_signals=$(echo "$_signal_text" | grep -ciE '\b(navigate|click|button|dropdown|screen|browser|playwright|snapshot|login|nav[- ]?bar)\b|\bopen(s|ed|ing)? (the |a |modal|dialog|page)\b' || true)
  _build_signals=$(echo "$_signal_text" | grep -ciE '\b(mvn|maven|gradle|pom\.xml|build\.gradle|clean install|clean compile|clean package|mvn test|BUILD SUCCESS)\b' || true)
  _live_backend_signals=$(echo "$_signal_text" | grep -ciE '\b(docker compose|eureka|circuit breaker|service.to.service|downstream failure|register(s|ed)? with)\b' || true)
  _test_user_na=$(echo "$_signal_text" | grep -ciE '\*\*?Test User\*?\*?:?\s*N/A' || true)
  _env_full_stack=$(echo "$_signal_text" | grep -ciE '\b(docker compose|full stack)\b' || true)

  if [ "${_browser_signals:-0}" -eq 0 ] && { [ "${_live_backend_signals:-0}" -gt 0 ] || { [ "${_test_user_na:-0}" -gt 0 ] && [ "${_env_full_stack:-0}" -gt 0 ]; }; }; then
    echo "live-backend"
  elif [ "${_browser_signals:-0}" -eq 0 ] && [ "${_build_signals:-0}" -gt 0 ]; then
    echo "build-only"
  else
    echo "browser"
  fi
}

# Moved verbatim from gate-check.sh Check 2.6 (detection precedence: browser
# signals present → browser; else build-tool signals → build-only; else
# api-only; plus the infra-only reclassification for a test-user ticket whose
# only navigation targets are infra dashboards). "open" alone is too weak
# (matches "open question", "open a PR"), so it is scoped to a UI object. A
# bare localhost:PORT mention never signals infra on its own — LOCAL_URL is
# almost always one — so a named infra keyword must be present.
verify_mode_gate_class() {
  local artifact_path="$1" has_nav_path="${2:-0}" has_test_user="${3:-0}"
  local _ticket_mode="browser"
  if [ "${has_nav_path:-0}" = "0" ] && [ "${has_test_user:-0}" = "0" ]; then
    local _browser_signals _build_signals
    _browser_signals=$(grep -ciP '(navigate|go to|open(s|ed|ing)?\s+(the\s+)?(page|browser|url|dialog|modal|menu|tab|app)\b|visit|click|browser|playwright|page\.|selector|screenshot|viewport)' "$artifact_path" 2>/dev/null || true)
    if [ "${_browser_signals//[^0-9]/}" = "0" ] 2>/dev/null; then
      _build_signals=$(grep -ciP '(\bmvn\b|\bgradle\b|\bnpm run\b|\bmake\b|pom\.xml|build\.gradle|clean compile|clean install|clean package|BUILD SUCCESS)' "$artifact_path" 2>/dev/null || true)
      if [ "${_build_signals//[^0-9]/}" != "0" ] 2>/dev/null; then
        _ticket_mode="build-only"
      else
        _ticket_mode="api-only"
      fi
    fi
  elif [ "${has_nav_path:-0}" = "0" ]; then
    local _feature_path_signals _infra_named_signals
    _feature_path_signals=$(grep -ciP '/(handover|admin|user-permission|organisation|portfolio)/' "$artifact_path" 2>/dev/null || true)
    _infra_named_signals=$(grep -ciP '(eureka|zipkin|actuator|config[- ]server|service registry|discovery server)' "$artifact_path" 2>/dev/null || true)
    if [ "${_feature_path_signals//[^0-9]/}" = "0" ] 2>/dev/null && [ "${_infra_named_signals//[^0-9]/}" != "0" ] 2>/dev/null; then
      _ticket_mode="infra-only"
    fi
  fi
  echo "$_ticket_mode"
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

  local _plan_file _description="" _signal_text mode
  _plan_file=$(bash "$_VERIFY_MODE_DIR/ticket-dir.sh" plan "$tid" --root "$root" --type simple-fix 2>/dev/null | sed -n 's/^PLAN_PATH=//p')
  [ -z "$_plan_file" ] && _plan_file="$td/notes.md"
  [ -n "$desc_file" ] && _description=$(cat "$desc_file" 2>/dev/null)
  _signal_text="$(cat "$_plan_file" "$td/context.md" 2>/dev/null)"$'\n'"${_description}"
  mode=$(verify_mode_classify "$_signal_text")
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
