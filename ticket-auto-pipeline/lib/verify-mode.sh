#!/usr/bin/env bash
# verify-mode.sh — the one home of ticket-shape (verification mode) detection
# (skill-deterministic-extraction 4).
#
# One classifier, one authority (decision 3 of skill-deterministic-extraction):
#
#   verify_mode_shape <text>
#     Prints the ticket's shape: browser | api-only | diff-only | build-only |
#     live-backend. First match wins:
#       1. an explicit "Verify mode: <shape>" field (bold or plain, or a
#          "## Verify Mode" section) — it overrides every heuristic;
#       2. browser: a browser signal is left once negated phrases ("No
#          screen", "no login"), code, paths and "open the PR" are dropped.
#          In a ticket that declares it has no screen ("No screen", "no UI",
#          "API only", "docs-only") only action words (click, button,
#          navigate, …) are a browser signal;
#       3. diff-only: "git-only" / "docs-only" / "diff-only", or "no UI"
#          together with "no API" or "no code" — nothing to run, only the
#          diff and the files to read;
#       4. api-only: the ticket says "API only";
#       5. live-backend: an infra/runtime keyword, or an explicit
#          "Test User: N/A" (plain or bold, either colon placement) together
#          with a full-stack environment;
#       6. build-only: a build-tool signal (mvn, gradle, pom.xml);
#       7. api-only: a weaker API signal — "no screen" / "no UI", curl, an
#          HTTP verb and a path, npm test, supertest, "Test User: None",
#          "Navigation Path: n/a";
#       8. browser: everything else (the default).
#     Live-backend is tested before build-only: a ticket can mention mvn or
#     pom.xml in passing while its acceptance criteria are runtime checks.
#
#   verify_mode_classify <text>
#     Prints the ticket-verify path the shape runs: browser | build-only |
#     live-backend. api-only runs the live-backend path (a running backend,
#     HTTP and test-command checks, no page); diff-only runs the build-only
#     path (no environment, file and diff checks). ticket-verify Step 1e runs
#     on it, and gate-check.sh Check 2.6 maps the same shape to a
#     prerequisite profile, so the gate never holds a ticket as one shape
#     while verify runs it as another.
#
#   verify_mode_text <plan-file> <ticket-dir> [description-file]
#     The text verify classifies: the plan, then context.md, then the
#     description. Both callers build their input through it.
#
#   verify_mode_gate_profile <text> <has_nav_path> <has_test_user>
#     gate-check.sh Check 2.6: which prerequisites the plan must carry.
#     Prints browser | build-only | api-only | diff-only.
#       live-backend, api-only -> api-only (expected behaviour + environment
#                       setup)
#       build-only   -> build-only (a build command + a success outcome)
#       diff-only    -> diff-only (expected behaviour only)
#       browser      -> browser when the text has a browser signal, an
#                       explicit "Verify mode: browser", or the plan names a
#                       test user or a nav path; api-only when it has no
#                       signal of any kind (verify still runs a browser
#                       there; the gate does not demand a login and a page a
#                       pure backend change cannot supply).
#
# Change a regex here, never in a caller.
#
# CLI (ticket-verify Step 1e):
#   verify-mode.sh <TICKET-ID> --ticket-dir D [--root R] [--description-file F] [--no-log]
# Plan text: the ticket's simple-fix plan (ticket-dir.sh plan --type
# simple-fix), else D/notes.md; then D/context.md; then the description file.
# Prints VERIFY_MODE=<mode>, then VERIFY_SHAPE=<shape> when the shape is
# api-only or diff-only, and, unless --no-log, writes
# VERIFY|load-context|done|Context loaded, [shape=<shape>, ]mode=<mode>
# through plog.sh.
# Exit 0, 2 usage.
#
# -u (nounset) intentionally omitted (repo convention, see verifier-result.sh).

_VERIFY_MODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Words that count as a browser signal when they stand in prose.
_VM_BROWSER_RE='\b(navigate|click|button|dropdown|screen|browser|playwright|snapshot|login|nav[- ]?bar)\b|\bopen(s|ed|ing)? (the |a |modal|dialog|page)\b'
# The subset that names an action on a page. These still count in a ticket
# that declares "no screen" for some of its criteria.
_VM_BROWSER_ACTION_RE='\b(navigate|click|button|dropdown|playwright|nav[- ]?bar)\b'
# What may follow a declaration ("No screen.", "API only:", "no UI, no API"):
# punctuation, the end of the line, or a joining word. "no UI changes" and
# "reaches the API only through the proxy" are not declarations.
_VM_DECL_END='([[:space:]]*([].,;:)(|"`*]|'"'"'|$)|[[:space:]]+(or|and|nor|is|are|to|at all|involved|exists?|needed|required)\b)'

# _verify_mode_norm <text> — a "## Test User", "## Navigation Path" or
# "## Verify Mode" heading gains a "<Heading>: <first body line>" line, so the
# planner's section form reads like the inline field form.
_verify_mode_norm() {
  awk '
    { print }
    pending != "" && $0 !~ /^[[:space:]]*$/ { print pending ": " $0; pending = "" }
    {
      h = tolower($0)
      if (h ~ /^#+[[:space:]]*(test user|navigation path|verify mode|verification mode)[[:space:]]*$/) {
        pending = $0
        sub(/^#+[[:space:]]*/, "", pending)
        sub(/[[:space:]]*$/, "", pending)
        if (tolower(pending) == "verification mode") pending = "Verify mode"
      }
    }
  ' <<<"${1:-}"
}

# _verify_mode_explicit <normalised text> — the ticket's own
# "Verify mode: <shape>" field (bold or plain, either colon placement, or the
# heading form), lower-cased; empty when absent or not a known shape. The
# first one in the text wins (the plan is read before context.md).
_verify_mode_explicit() {
  grep -ioE '\bVerify mode\*{0,2}[[:space:]]*:\*{0,2}[[:space:]]*`?(browser|api-only|build-only|diff-only|live-backend)\b' <<<"${1:-}" |
    head -1 | grep -ioE '(browser|api-only|build-only|diff-only|live-backend)$' | tr '[:upper:]' '[:lower:]' || true
}

# _verify_mode_prose <text> — the text browser words are counted in. Dropped
# first, because none of it says "a person uses a page" (GitHub #761):
#   the scorer's own "**Mode:** browser (verify: browser)" line in notes.md;
#   inline code, paths, file names, call names and branch slugs
#     (`navigate(path)`, /api/users/login, login.js, epic/…-login-and-art);
#   "open the PR" and its kin (a pull request, a file, a port, …);
#   negated browser words ("No screen", "no login", "no UI or login",
#     "without a browser").
_verify_mode_prose() {
  local noun='(screens?|ui|log-?ins?|browsers?|pages?|buttons?|click(s|ing)?|navigat(e|es|ing|ion)|playwright|dropdowns?|nav[- ]?bar|snapshots?)'
  sed -E \
    -e '/^[[:space:]]*\*\*Mode:\*\*/d' \
    -e 's/`[^`]*`/ /g' \
    -e 's#[A-Za-z0-9_.:-]*/[A-Za-z0-9_./:-]*# #g' \
    -e 's/[A-Za-z0-9_]+(-[A-Za-z0-9_]+){2,}/ /g' \
    -e 's/[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+/ /g' \
    -e 's/[A-Za-z_][A-Za-z0-9_]*\(/ (/g' \
    -e 's/\bopen(s|ed|ing)? ((the|a|an|its|their) )?((new|draft) )?(pull requests?|prs?|merge requests?|mrs?|issues?|tickets?|files?|terminals?|shells?|branch(es)?|ports?|sockets?|connections?)\b/ /Ig' \
    -e 's/\b(no|not|without|never)[[:space:]]+((a|an|any|the|user|web|app|application|manual|interactive|graphical|front-?end|ui|browser)[[:space:]]+){0,2}'"$noun"'\b([[:space:]]*(\/|,|\bor\b|\band\b|\bnor\b)[[:space:]]*((a|an|any|the)[[:space:]]+)?'"$noun"'\b)*/ /Ig' \
    <<<"${1:-}"
}

_vm_count() { # [-c] <regex> <text>: matching lines; -c makes it case-sensitive
  local flags=-ciE n
  [ "$1" = "-c" ] && {
    flags=-cE
    shift
  }
  n=$(grep $flags -- "$1" <<<"$2" || true)
  echo "${n:-0}"
}

# _verify_mode_signals <text> — prints
#   "browser build live na full api api_decl diff no_ui"
# counts. browser is counted in _verify_mode_prose's text. When the ticket
# declares that it has no screen (no_ui, api_decl or a diff declaration),
# only the action words count: an API ticket says "login" on every line, and
# a ticket that clicks a button on some criteria is still a browser ticket.
_verify_mode_signals() {
  local _signal_text _prose _b _bu _l _na _fs _api _decl _diff _noui _noapi _weak
  _signal_text=$(_verify_mode_norm "${1:-}")
  _prose=$(_verify_mode_prose "$_signal_text")
  _b=$(_vm_count "$_VM_BROWSER_RE" "$_prose")
  _bu=$(_vm_count '\b(mvn|maven|gradle|pom\.xml|build\.gradle|clean install|clean compile|clean package|mvn test|BUILD SUCCESS)\b' "$_signal_text")
  _l=$(_vm_count '\b(docker compose|eureka|circuit breaker|service.to.service|downstream failure|register(s|ed)? with)\b' "$_signal_text")
  # "**Test User:** N/A" (bold label, colon inside) and "**Test User**: N/A"
  # both count; the stars before "Test User" stay required.
  _na=$(_vm_count '\*\*?Test User\*{0,2}:?\*{0,2}\s*N/A' "$_signal_text")
  _fs=$(_vm_count '\b(docker compose|full stack)\b' "$_signal_text")
  _noui=$(_vm_count '\bno (screen|ui|gui|user interface)s?'"$_VM_DECL_END" "$_signal_text")
  _decl=$(_vm_count '\bAPI[- ]only'"$_VM_DECL_END" "$_signal_text")
  _diff=$(_vm_count '\b(git|docs?|documentation|diff|markdown)[- ]only'"$_VM_DECL_END" "$_signal_text")
  _noapi=$(_vm_count '\bno (API|(source )?code( changes?)?)'"$_VM_DECL_END" "$_signal_text")
  # "no UI" together with "no API" or "no code": nothing to run at all.
  [ "$_noui" -gt 0 ] && [ "$_noapi" -gt 0 ] && _diff=$((_diff + _noapi))
  # Weak API signals: they decide only when no browser signal is left.
  _weak=$(_vm_count '\bcurl\b|\b(npm|yarn|pnpm) (run )?test\b|\bsupertest\b|\b(Test User|Navigation Path)\*{0,2}[[:space:]]*:\*{0,2}[[:space:]]*(n/a|none|not applicable|—)' "$_signal_text")
  _api=$(_vm_count -c '\b(GET|POST|PUT|PATCH|DELETE) `?(https?://[^[:space:]/]+)?/[A-Za-z0-9_{:]' "$_signal_text")
  _api=$((_api + _weak + _noui + _decl))
  if [ "$_noui" -gt 0 ] || [ "$_decl" -gt 0 ] || [ "$_diff" -gt 0 ]; then
    _b=$(_vm_count "$_VM_BROWSER_ACTION_RE" "$_prose")
  fi
  echo "$_b $_bu $_l $_na $_fs $_api $_decl $_diff $_noui"
}

# verify_mode_shape <text> — browser | api-only | diff-only | build-only |
# live-backend. See the header for the order.
verify_mode_shape() {
  local _explicit _browser_signals _build_signals _live_backend_signals _test_user_na _env_full_stack _api _api_decl _diff
  _explicit=$(_verify_mode_explicit "$(_verify_mode_norm "${1:-}")")
  if [ -n "$_explicit" ]; then
    echo "$_explicit"
    return 0
  fi
  read -r _browser_signals _build_signals _live_backend_signals _test_user_na _env_full_stack _api _api_decl _diff _ <<<"$(_verify_mode_signals "${1:-}")"
  if [ "${_browser_signals:-0}" -gt 0 ]; then
    echo "browser"
  elif [ "${_diff:-0}" -gt 0 ]; then
    echo "diff-only"
  elif [ "${_api_decl:-0}" -gt 0 ]; then
    echo "api-only"
  elif [ "${_live_backend_signals:-0}" -gt 0 ] || { [ "${_test_user_na:-0}" -gt 0 ] && [ "${_env_full_stack:-0}" -gt 0 ]; }; then
    echo "live-backend"
  elif [ "${_build_signals:-0}" -gt 0 ]; then
    echo "build-only"
  elif [ "${_api:-0}" -gt 0 ]; then
    echo "api-only"
  else
    echo "browser"
  fi
}

# _verify_mode_of_shape <shape> — the ticket-verify path a shape runs.
_verify_mode_of_shape() {
  case "${1:-}" in
  api-only | live-backend) echo "live-backend" ;;
  diff-only | build-only) echo "build-only" ;;
  *) echo "browser" ;;
  esac
}

verify_mode_classify() {
  _verify_mode_of_shape "$(verify_mode_shape "${1:-}")"
}

verify_mode_text() {
  local plan="${1:-}" td="${2:-}" desc_file="${3:-}" description=""
  [ -n "$desc_file" ] && description=$(cat "$desc_file" 2>/dev/null)
  printf '%s\n%s' "$(cat "$plan" "$td/context.md" 2>/dev/null)" "$description"
}

_vm_found() { case "${1:-0}" in "" | 0) return 1 ;; *) return 0 ;; esac }

verify_mode_gate_profile() {
  local text="${1:-}" has_nav="${2:-0}" has_user="${3:-0}" shape browser
  shape=$(verify_mode_shape "$text")
  case "$shape" in
  live-backend | api-only) echo "api-only" ;;
  build-only) echo "build-only" ;;
  diff-only) echo "diff-only" ;;
  *)
    read -r browser _ <<<"$(_verify_mode_signals "$text")"
    if _vm_found "$browser" || [ -n "$(_verify_mode_explicit "$(_verify_mode_norm "$text")")" ]; then
      echo "browser"
    elif _vm_found "$has_nav" || _vm_found "$has_user"; then
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

  local _plan_file mode shape
  _plan_file=$(bash "$_VERIFY_MODE_DIR/ticket-dir.sh" plan "$tid" --root "$root" --type simple-fix 2>/dev/null | sed -n 's/^PLAN_PATH=//p')
  [ -z "$_plan_file" ] && _plan_file="$td/notes.md"
  shape=$(verify_mode_shape "$(verify_mode_text "$_plan_file" "$td" "$desc_file")")
  mode=$(_verify_mode_of_shape "$shape")
  echo "VERIFY_MODE=$mode"
  # The shape is printed and logged only when it says more than the mode
  # (api-only, diff-only). It goes before mode= in the log line: a
  # --from-step resume reads everything after "mode=" as the mode.
  if [ "$shape" != "$mode" ]; then
    echo "VERIFY_SHAPE=$shape"
    shape="shape=${shape}, "
  else
    shape=""
  fi
  if [ "$log" = 1 ]; then
    bash "$_VERIFY_MODE_DIR/plog.sh" VERIFY load-context done "Context loaded, ${shape}mode=${mode}"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _verify_mode_main "$@"
  exit $?
fi
