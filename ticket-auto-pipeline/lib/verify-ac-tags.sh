#!/usr/bin/env bash
# verify-ac-tags.sh — the deterministic half of ticket-verify's `[unit]` /
# `[live]` criterion tags (GitHub #773, flag VERIFY_AC_TAGS, default false).
#
# A ticket-body-v2 criterion starts with `[unit]` (only an automated test can
# prove it) or `[live]` (proved on the running system). With the flag on,
# verify proves a `[unit]` criterion by running the project's own test command
# itself, in its own verify worktree, and seeing a NAMED test pass in that
# run. This file owns everything about that which must not be an agent's
# judgement: which criteria are `[unit]`, which command runs, where it runs,
# and whether a named test passed. The agent only names the test.
#
# One rule for a `[unit]` criterion that cannot be proved this way (no named
# test, no test command, no worktree, the test not in this run's results):
# it FAILS. It is never proved live instead and never passed on a claim.
#
# Usage:
#   verify-ac-tags.sh gate <ticket-dir> [--env local|uat] [--body FILE]
#       Prints AC_TAGS=on|off and AC_TAGS_REASON=<why>. Always exit 0.
#       `on` only when VERIFY_AC_TAGS=true, the environment is not uat, and
#       the body has at least one `[unit]` criterion.
#   verify-ac-tags.sh list <ticket-dir> [--body FILE]
#       One line per criterion: <n> TAB <unit|live> TAB <text without tag>.
#       An untagged criterion is `live`.
#   verify-ac-tags.sh test-cmd <TID> --repo <slug> [--claude-md FILE]
#       Prints TEST_CMD_SOURCE=<field> and TEST_CMD=<command>; exit 1 with
#       TEST_CMD_NONE=<reason> when no command can be learned.
#   verify-ac-tags.sh run <TID> --repo-path <repo> --branch <branch>
#                     --out <dir> [--claude-md FILE] --test <name>...
#       Runs the test command once in the repo's verify worktree and prints
#         UNIT_RUN  TAB status=<ran|no-command|no-worktree> TAB rc=<n> TAB
#                   source=<field> TAB dir=<worktree> TAB log=<file> TAB reports=<n>
#         UNIT_TEST TAB <name> TAB <pass|fail> TAB <reason>
#       Exit 0 when every named test passed, 1 when any did not, 2 usage.
#
# The body is <ticket-dir>/context.md unless --body names a file. Criteria are
# read with _dor_v2_ac_items (lib/dor-body-v2.sh), the one criterion reader.
#
# Test command, first match wins (the rule ticket-implement runs tests by):
#   the repo is a backend repo (its directory name is listed in BE_SERVICES)
#     -> BE_TEST_RUNNER, else BE_TEST_CMD
#   BE_SERVICES names other repos only -> FE_TEST_CMD
#   BE_SERVICES is empty -> the one configured side (BE_TEST_RUNNER or
#     BE_TEST_CMD, else FE_TEST_CMD); none when both sides are configured,
#     because nothing says which one this repo uses.
# Each field comes from the environment, then the ticket's env file, then the
# project CLAUDE.md (--claude-md, default ./CLAUDE.md). Nothing is guessed
# from build files.
#
# Worktree: $REPOS_ROOT/.verify-worktrees/<slug>/<TID>. An existing one is
# used as it is (Step 1.6 made it under the verify lock, and the stack may be
# serving from it, so it is never resynced here); a missing one (build-only
# mode) is created with ensure_verify_worktree at the pushed branch tip.
#
# A named test passed when:
#   1. a JUnit XML report written during this run (any *.xml under the
#      worktree, newer than the run's start, holding <testcase>) has a
#      testcase that matches the name, none of the matches failed or errored,
#      and at least one was not skipped; or
#   2. the run wrote no such report at all, the command exited 0, and the
#      name is on a line of the run's output that carries no skip or failure
#      word.
# A name matches a testcase by method name, class name (full or last part),
# or `Class.method` / `Class#method` / `file::method`; a parameter suffix
# (`[..]`, `(..)`) on the reported name is ignored.
#
# VERIFY_AC_TAGS_TIMEOUT bounds the run (seconds, default 900).
# Never writes the pipeline log.

_VAT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f _dor_v2_ac_items >/dev/null 2>&1; then
  # shellcheck source=dor-body-v2.sh
  source "$_VAT_LIB/dor-body-v2.sh"
fi
if ! declare -f claude_md_field >/dev/null 2>&1; then
  # shellcheck source=claude-md-field.sh
  source "$_VAT_LIB/claude-md-field.sh"
fi

# vat_enabled — rc 0 when the flag is on.
vat_enabled() { [ "${VERIFY_AC_TAGS:-false}" = "true" ]; }

# _vat_body <ticket-dir> <body-file-or-empty> — print the body text. rc 1
# when there is no readable file.
_vat_body() {
  local f="${2:-}"
  [ -n "$f" ] || f="$1/context.md"
  [ -f "$f" ] && [ -r "$f" ] || return 1
  cat "$f"
}

# vat_list <body text> — "<n>\t<unit|live>\t<text>" per criterion.
vat_list() {
  _dor_v2_ac_items "$1" | awk '
    {
      tag = "live"; text = $0
      if (text ~ /^\[unit\]([[:space:]]|$)/) { tag = "unit"; sub(/^\[unit\][[:space:]]*/, "", text) }
      else if (text ~ /^\[live\]([[:space:]]|$)/) { sub(/^\[live\][[:space:]]*/, "", text) }
      printf "%d\t%s\t%s\n", NR, tag, text
    }
  '
}

# vat_gate <ticket-dir> <env> <body-file-or-empty>
vat_gate() {
  local body n
  if ! vat_enabled; then
    printf 'AC_TAGS=off\nAC_TAGS_REASON=flag-off\n'
    return 0
  fi
  if [ "$2" = "uat" ]; then
    printf 'AC_TAGS=off\nAC_TAGS_REASON=uat\n'
    return 0
  fi
  if ! body=$(_vat_body "$1" "$3"); then
    printf 'AC_TAGS=off\nAC_TAGS_REASON=no-body\n'
    return 0
  fi
  n=$(vat_list "$body" | awk -F'\t' '$2 == "unit"' | grep -c . || true)
  if [ "${n:-0}" -gt 0 ]; then
    printf 'AC_TAGS=on\nAC_TAGS_REASON=unit:%s\n' "$n"
  else
    printf 'AC_TAGS=off\nAC_TAGS_REASON=no-unit\n'
  fi
  return 0
}

# _vat_field <KEY> <claude-md> — environment first, then the CLAUDE.md field.
_vat_field() {
  local v="${!1:-}"
  if [ -z "$v" ]; then
    v=$(claude_md_field "$2" "$1" 2>/dev/null) || v=""
  fi
  printf '%s' "$v"
}

# vat_test_cmd <slug> <claude-md> — sets VAT_CMD and VAT_CMD_SOURCE; rc 1
# with VAT_CMD_NONE set when no command can be learned.
vat_test_cmd() {
  local slug="$1" md="$2" be_services runner be fe item in_be=0 n_be=0
  VAT_CMD=""
  VAT_CMD_SOURCE=""
  VAT_CMD_NONE=""
  be_services=$(_vat_field BE_SERVICES "$md")
  runner=$(_vat_field BE_TEST_RUNNER "$md")
  be=$(_vat_field BE_TEST_CMD "$md")
  fe=$(_vat_field FE_TEST_CMD "$md")
  for item in ${be_services//,/ }; do
    n_be=$((n_be + 1))
    [ "$(basename "$item")" = "$slug" ] && in_be=1
  done
  if [ "$in_be" -eq 1 ]; then
    if [ -n "$runner" ]; then
      VAT_CMD="$runner" VAT_CMD_SOURCE=BE_TEST_RUNNER
    elif [ -n "$be" ]; then
      VAT_CMD="$be" VAT_CMD_SOURCE=BE_TEST_CMD
    else
      VAT_CMD_NONE="backend repo, no BE_TEST_RUNNER or BE_TEST_CMD"
    fi
  elif [ "$n_be" -gt 0 ]; then
    if [ -n "$fe" ]; then
      VAT_CMD="$fe" VAT_CMD_SOURCE=FE_TEST_CMD
    else
      VAT_CMD_NONE="not a BE_SERVICES repo, no FE_TEST_CMD"
    fi
  elif [ -n "${runner}${be}" ] && [ -n "$fe" ]; then
    VAT_CMD_NONE="BE_SERVICES is empty and both a backend and FE_TEST_CMD command are set"
  elif [ -n "$runner" ]; then
    VAT_CMD="$runner" VAT_CMD_SOURCE=BE_TEST_RUNNER
  elif [ -n "$be" ]; then
    VAT_CMD="$be" VAT_CMD_SOURCE=BE_TEST_CMD
  elif [ -n "$fe" ]; then
    VAT_CMD="$fe" VAT_CMD_SOURCE=FE_TEST_CMD
  else
    VAT_CMD_NONE="no BE_TEST_RUNNER, BE_TEST_CMD or FE_TEST_CMD"
  fi
  [ -n "$VAT_CMD" ]
}

# _vat_junit <reports-list-file> <name>... — "<name>\t<pass|fail>\t<reason>"
# per name, judged from the listed JUnit XML files.
_vat_junit() {
  python3 - "$@" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

reports = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
names = sys.argv[2:]
cases = []  # (classname, name, state)
for path in reports:
    try:
        root = ET.parse(path).getroot()
    except Exception:
        continue
    for tc in root.iter("testcase"):
        kids = {child.tag for child in tc}
        if kids & {"failure", "error"}:
            state = "failed"
        elif "skipped" in kids:
            state = "skipped"
        else:
            state = "passed"
        cases.append((tc.get("classname") or "", tc.get("name") or "", state))


def base(s):
    return re.sub(r"\s*[\[(].*$", "", s).strip()


def keys(classname, name):
    cls = classname.strip()
    simple = re.split(r"[./]", cls)[-1] if cls else ""
    out = set()
    for n in {name.strip(), base(name)}:
        if not n:
            continue
        out.add(n)
        for c in {cls, simple}:
            if c:
                out.update({c + "." + n, c + "#" + n, c + "::" + n})
    out.update({c for c in (cls, simple) if c})
    return out


def norm(wanted):
    w = wanted.strip().strip("`")
    forms = {w}
    if "::" in w:
        head, _, tail = w.partition("::")
        tail = tail.replace("::", ".")
        mod = re.sub(r"\.[A-Za-z0-9]+$", "", head).replace("/", ".")
        forms.update({mod + "." + tail, mod + "::" + tail, mod.split(".")[-1] + "." + tail, tail})
    return {f for f in forms if f}


for wanted in names:
    forms = norm(wanted)
    hit = [c for c in cases if keys(c[0], c[1]) & forms]
    if not hit:
        print("%s\tfail\tnot in this run's test reports" % wanted)
    elif any(c[2] == "failed" for c in hit):
        print("%s\tfail\ttest failed in this run" % wanted)
    elif all(c[2] == "skipped" for c in hit):
        print("%s\tfail\ttest was skipped in this run" % wanted)
    else:
        n = sum(1 for c in hit if c[2] == "passed")
        print("%s\tpass\tjunit: %d passed" % (wanted, n))
PY
}

# _vat_output <log> <rc> <name>... — the fallback for a run that wrote no
# JUnit report: the name on an output line with no skip or failure word.
_vat_output() {
  local log="$1" rc="$2" name lines rest
  shift 2
  for name in "$@"; do
    if [ "$rc" -ne 0 ]; then
      printf '%s\tfail\tno test report and the command exited %s\n' "$name" "$rc"
      continue
    fi
    lines=$(grep -F -- "$name" "$log" 2>/dev/null || true)
    if [ -z "$lines" ]; then
      printf '%s\tfail\tno test report and the name is not in the output\n' "$name"
      continue
    fi
    rest=$(VAT_NAME="$name" awk '{ s = $0; while ((i = index(s, ENVIRON["VAT_NAME"])) > 0) s = substr(s, 1, i - 1) substr(s, i + length(ENVIRON["VAT_NAME"])); print tolower(s) }' <<<"$lines")
    if grep -qE 'skip|pending|todo|ignored|disabled|fail|error|not ok|✗|✕|✘' <<<"$rest"; then
      printf '%s\tfail\toutput line reports a skip or failure\n' "$name"
    else
      printf '%s\tpass\toutput: named in a passing run\n' "$name"
    fi
  done
}

# vat_run <TID> <repo-path> <branch> <out-dir> <claude-md> <name>...
vat_run() {
  local tid="$1" repo_path="$2" branch="$3" out="$4" md="$5" slug wt log marker reports rc n_reports name timeout_s
  shift 5
  slug=$(basename "$repo_path")

  # shellcheck source=ticket-env.sh
  source "$_VAT_LIB/ticket-env.sh" "$tid"
  if ! declare -f verify_env_init >/dev/null 2>&1; then
    # shellcheck source=verify-worktree.sh
    source "$_VAT_LIB/verify-worktree.sh"
  fi

  _vat_all_fail() {
    local reason="$1" t
    shift
    for t in "$@"; do printf 'UNIT_TEST\t%s\tfail\t%s\n' "$t" "$reason"; done
  }

  if ! vat_test_cmd "$slug" "$md"; then
    printf 'UNIT_RUN\tstatus=no-command\trc=-\tsource=-\tdir=-\tlog=-\treports=0\n'
    _vat_all_fail "no test command: $VAT_CMD_NONE" "$@"
    return 1
  fi

  wt=""
  if verify_env_init "$tid" "$md" 2>/dev/null; then
    wt=$(verify_worktree_path "$slug" "$tid")
    if [ ! -d "$wt" ]; then
      wt=$(ensure_verify_worktree "$tid" "$repo_path" "$branch" 2>/dev/null) || wt=""
    fi
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'UNIT_RUN\tstatus=no-worktree\trc=-\tsource=%s\tdir=-\tlog=-\treports=0\n' "$VAT_CMD_SOURCE"
    _vat_all_fail "no verify worktree for $slug" "$@"
    return 1
  fi

  mkdir -p "$out" || return 2
  log="$out/verify-unit-$slug.log"
  marker=$(mktemp)
  reports=$(mktemp)
  timeout_s="${VERIFY_AC_TAGS_TIMEOUT:-900}"
  case "$timeout_s" in '' | *[!0-9]*) timeout_s=900 ;; esac
  # A report must be newer than the marker; give coarse mtimes room.
  sleep 1
  rc=0
  (cd "$wt" && timeout -k 10 "$timeout_s" bash -c "$VAT_CMD") >"$log" 2>&1 </dev/null || rc=$?

  find "$wt" -type f -name '*.xml' -newer "$marker" -not -path '*/.git/*' -not -path '*/node_modules/*' \
    -exec grep -l '<testcase' {} + 2>/dev/null >"$reports" || true
  n_reports=$(grep -c . "$reports" || true)

  printf 'UNIT_RUN\tstatus=ran\trc=%s\tsource=%s\tdir=%s\tlog=%s\treports=%s\n' \
    "$rc" "$VAT_CMD_SOURCE" "$wt" "$log" "$n_reports"
  local results
  if [ "${n_reports:-0}" -gt 0 ] && command -v python3 >/dev/null 2>&1; then
    results=$(_vat_junit "$reports" "$@")
  elif [ "${n_reports:-0}" -gt 0 ]; then
    results=$(for name in "$@"; do printf '%s\tfail\ttest reports found but python3 is missing\n' "$name"; done)
  else
    results=$(_vat_output "$log" "$rc" "$@")
  fi
  rm -f "$marker" "$reports"
  [ -n "$results" ] || return 1
  sed 's/^/UNIT_TEST\t/' <<<"$results"
  ! grep -q $'\tfail\t' <<<"$results"
}

_vat_usage() {
  sed -n '17,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

_vat_main() {
  local cmd="${1:-}" pos="" env="local" body="" repo="" md="./CLAUDE.md" repo_path="" branch="" out=""
  local -a tests=()
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
    --env | --body | --repo | --claude-md | --repo-path | --branch | --out | --test)
      if [ $# -lt 2 ]; then
        echo "verify-ac-tags: $1 needs a value" >&2
        return 2
      fi
      case "$1" in
      --env) env="$2" ;;
      --body) body="$2" ;;
      --repo) repo="$2" ;;
      --claude-md) md="$2" ;;
      --repo-path) repo_path="$2" ;;
      --branch) branch="$2" ;;
      --out) out="$2" ;;
      --test) tests+=("$2") ;;
      esac
      shift 2
      ;;
    -*)
      echo "verify-ac-tags: unknown option $1" >&2
      return 2
      ;;
    *)
      if [ -n "$pos" ]; then
        echo "verify-ac-tags: unexpected argument $1" >&2
        return 2
      fi
      pos="$1"
      shift
      ;;
    esac
  done

  case "$cmd" in
  gate)
    [ -n "$pos" ] || { _vat_usage && return 2; }
    vat_gate "$pos" "$env" "$body"
    ;;
  list)
    [ -n "$pos" ] || { _vat_usage && return 2; }
    local text
    text=$(_vat_body "$pos" "$body") || {
      echo "verify-ac-tags: no readable body (${body:-$pos/context.md})" >&2
      return 1
    }
    vat_list "$text"
    ;;
  test-cmd)
    [ -n "$pos" ] && [ -n "$repo" ] || { _vat_usage && return 2; }
    # shellcheck source=ticket-env.sh
    source "$_VAT_LIB/ticket-env.sh" "$pos"
    if vat_test_cmd "$repo" "$md"; then
      printf 'TEST_CMD_SOURCE=%s\nTEST_CMD=%s\n' "$VAT_CMD_SOURCE" "$VAT_CMD"
    else
      printf 'TEST_CMD_NONE=%s\n' "$VAT_CMD_NONE"
      return 1
    fi
    ;;
  run)
    if [ -z "$pos" ] || [ -z "$repo_path" ] || [ -z "$branch" ] || [ -z "$out" ] || [ "${#tests[@]}" -eq 0 ]; then
      _vat_usage
      return 2
    fi
    case "$pos" in *[!A-Za-z0-9_-]*)
      echo "verify-ac-tags: not a ticket id: $pos" >&2
      return 2
      ;;
    esac
    vat_run "$pos" "$repo_path" "$branch" "$out" "$md" "${tests[@]}"
    ;;
  *)
    _vat_usage
    return 2
    ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _vat_main "$@"
  exit $?
fi
