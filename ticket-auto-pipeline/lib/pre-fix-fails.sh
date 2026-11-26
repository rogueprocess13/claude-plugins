#!/usr/bin/env bash
# pre-fix-fails.sh — does a bug ticket's regression test fail on the code
# before the fix? (openspec change pre-fix-fails-gate, next.md Step 24 item 1)
#
#   pre-fix-fails.sh wanted <TID> [<context.md>]
#       Prints `true` when ticket-implement runs the check: PRE_FIX_FAILS is
#       not `off` and the ticket type (ticket-type.sh) is exactly `bug`.
#   pre-fix-fails.sh check <TID> --worktree W --base-ref R --test NAME...
#                          [--claude-md F]
#       Runs the named tests on a pre-fix tree (merge base of W's HEAD and R,
#       plus only the ticket's test files) and in W, and prints
#         PRE_FIX_TEST  TAB <name> TAB <before> TAB <after>
#         PRE_FIX_VERDICT=proved|proved-weak|unproven|skipped
#         PRE_FIX_REASON=<reason>
#       and writes one META|pre-fix-fails|info|verdict=... line through
#       plog.sh. Exit 0 on any verdict, 2 usage.
#
# Increment 1 only records: no gate-stop, no verifier result, no IMPLEMENT
# step line (detect-resume would take it as a resume point).
#
# Verdicts come from JUnit XML only; a run that writes none is
# `unproven no-report`. Per named test:
#   before: failed (a <failure>) | errored (an <error>) | passes-before-fix |
#           did-not-build (no report at all, rc not 0/124/137) | not-run-before-fix
#           (absent, other reports or rc 0) | timeout (rc 124/137)
#   after:  passed (every matched case passed) | not-passing-after
# proved: every test failed before and passed after. proved-weak: every test
# failed, errored or did not build before (not all plain failures) and passed
# after. Otherwise unproven with the first test's reason, or
# ambiguous-name when a name matches only a class or more than one class.
#
# The pre-fix tree is $(dirname W)/.pre-fix-<slug>, removed on every exit.
# Test command: verify-ac-tags.sh's vat_test_cmd. Maven and pytest commands
# run only the named tests; pytest also gets --junitxml. Others run whole.
# PRE_FIX_FAILS_TIMEOUT bounds each run (seconds, default 900).
#
# Sourceable: sets no shell options.

_PFF_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f ticket_type_resolve >/dev/null 2>&1 || source "$_PFF_LIB/ticket-type.sh"
declare -f vat_test_cmd >/dev/null 2>&1 || source "$_PFF_LIB/verify-ac-tags.sh"

# pff_mode — prints warn or off; any other value warns once on stderr.
pff_mode() {
  local m="${PRE_FIX_FAILS:-warn}"
  case "$m" in
  warn | off) echo "$m" ;;
  *)
    echo "pre-fix-fails: PRE_FIX_FAILS=$m is not warn or off; using warn" >&2
    echo warn
    ;;
  esac
}

# pff_wanted <TID> [<context.md>] — prints true or false.
pff_wanted() {
  local tid="$1" ctx="${2:-}" labels="" t
  if [ "$(pff_mode)" = "off" ]; then
    echo false
    return 0
  fi
  [ -n "$ctx" ] && labels=$(ticket_type_context_labels "$ctx")
  t=$(ticket_type_resolve "$tid" "$labels")
  if [ "$t" = "bug" ]; then echo true; else echo false; fi
}

# pff_is_test_path <path> — rc 0 when the path is a test file.
pff_is_test_path() {
  local p="$1" base dir
  case "/$p/" in */src/main/*) return 1 ;; esac
  base="${p##*/}"
  dir="/${p%"$base"}"
  case "$dir" in
  */test/* | */tests/* | */__tests__/* | */__mocks__/* | */testdata/* | */testutil/* | */testutils/* | */fixtures/*)
    return 0
    ;;
  esac
  case "$base" in
  test_*.py | conftest.py | *_test.* | *.test.* | *.spec.*) return 0 ;;
  esac
  [[ "$base" =~ ^[A-Za-z0-9_]*[a-z0-9](Tests?|IT)\.[A-Za-z0-9]+$ ]]
}

# pff_copy_set <worktree> <merge-base> — "C<TAB>path" to copy, "D<TAB>path"
# to remove, for test files only.
pff_copy_set() {
  local wt="$1" mb="$2" st a b
  {
    git -C "$wt" diff --name-status -M "$mb" 2>/dev/null
    git -C "$wt" ls-files --others --exclude-standard 2>/dev/null | sed 's/^/A\t/'
  } | while IFS=$'\t' read -r st a b; do
    case "$st" in
    R*)
      pff_is_test_path "$a" && printf 'D\t%s\n' "$a"
      pff_is_test_path "$b" && printf 'C\t%s\n' "$b"
      ;;
    C*) pff_is_test_path "$b" && printf 'C\t%s\n' "$b" ;;
    D) pff_is_test_path "$a" && printf 'D\t%s\n' "$a" ;;
    A | M | T) pff_is_test_path "$a" && printf 'C\t%s\n' "$a" ;;
    esac
  done | sort -u
  return 0
}

# pff_command <base-cmd> <junit-file> <name>... — prints MODE<TAB>command.
pff_command() {
  local cmd="$1" junit="$2" first sel="" name cls meth ids="" k=""
  shift 2
  first="${cmd%% *}"
  case "$first" in
  mvn | mvnw | ./mvnw)
    for name in "$@"; do
      case "$name" in
      *#*) cls="${name%%#*}" meth="${name#*#}" ;;
      *.*) cls="${name%.*}" meth="${name##*.}" ;;
      *)
        printf 'full\t%s\n' "$cmd"
        return 0
        ;;
      esac
      cls="${cls##*.}"
      sel="${sel:+$sel,}$cls#$meth"
    done
    printf 'targeted\t%s %s %s %s\n' "$cmd" "$(printf '%q' "-Dtest=$sel")" \
      -Dsurefire.failIfNoSpecifiedTests=false -DfailIfNoTests=false
    return 0
    ;;
  esac
  case " $cmd " in
  *pytest*)
    for name in "$@"; do
      case "$name" in
      *::*) ids="$ids $(printf '%q' "$name")" ;;
      *) k="${k:+$k or }${name##*[.#]}" ;;
      esac
    done
    if [ -n "$k" ]; then ids="$ids -k $(printf '%q' "$k")"; fi
    printf 'targeted\t%s%s %s\n' "$cmd" "$ids" "$(printf '%q' "--junitxml=$junit")"
    return 0
    ;;
  esac
  printf 'full\t%s\n' "$cmd"
}

# pff_judge <reports-list> <name>... — "<name>\t<state>" per name; state is
# failed|errored|passed|skipped|absent|ambiguous.
pff_judge() {
  python3 - "$@" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

reports = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
cases = []
for path in reports:
    try:
        root = ET.parse(path).getroot()
    except Exception:
        continue
    for tc in root.iter("testcase"):
        kids = {c.tag for c in tc}
        if "failure" in kids:
            st = "failed"
        elif "error" in kids:
            st = "errored"
        elif "skipped" in kids:
            st = "skipped"
        else:
            st = "passed"
        cases.append(((tc.get("classname") or "").strip(), (tc.get("name") or "").strip(), st))


def base(s):
    return re.sub(r"\s*[\[(].*$", "", s).strip()


def cls_ok(want, have):
    if not want:
        return True
    if not have:
        return False
    return have == want or have.endswith("." + want) or have.split(".")[-1] == want


def parse(w):
    w = w.strip().strip("`")
    if "::" in w:
        parts = w.split("::")
        mod = re.sub(r"\.py$", "", parts[0]).replace("/", ".").strip(".")
        cls = ".".join([mod] + parts[1:-1]) if mod else ".".join(parts[1:-1])
        return cls, parts[-1]
    if "#" in w:
        c, _, m = w.partition("#")
        return c, m
    if "." in w:
        c, _, m = w.rpartition(".")
        return c, m
    return "", w


for w in sys.argv[2:]:
    c, m = parse(w)
    hit = [x for x in cases if base(x[1]) == base(m) and cls_ok(c, x[0])]
    if not hit:
        whole = w.strip().strip("`")
        if any(cls_ok(whole, x[0]) for x in cases):
            print("%s\tambiguous" % w)
        else:
            print("%s\tabsent" % w)
        continue
    if len({x[0] for x in hit}) > 1:
        print("%s\tambiguous" % w)
        continue
    sts = {x[2] for x in hit}
    if "failed" in sts:
        print("%s\tfailed" % w)
    elif "errored" in sts:
        print("%s\terrored" % w)
    elif "passed" in sts:
        print("%s\tpassed" % w)
    else:
        print("%s\tskipped" % w)
PY
}

# _pff_run <dir> <command> <log> <reports-out> <extra-report-dir> — runs the
# command; sets PFF_RC.
_pff_run() {
  local dir="$1" cmd="$2" log="$3" out="$4" extra="$5" marker t
  t="${PRE_FIX_FAILS_TIMEOUT:-900}"
  case "$t" in '' | *[!0-9]*) t=900 ;; esac
  marker=$(mktemp)
  sleep 1
  PFF_RC=0
  (cd "$dir" && timeout -k 10 "$t" bash -c "$cmd") >"$log" 2>&1 </dev/null || PFF_RC=$?
  {
    find "$dir" -type f -name '*.xml' -newer "$marker" -not -path '*/.git/*' \
      -not -path '*/node_modules/*' -exec grep -l '<testcase' {} + 2>/dev/null
    [ -n "$extra" ] && find "$extra" -maxdepth 1 -type f -name '*.xml' -newer "$marker" \
      -exec grep -l '<testcase' {} + 2>/dev/null
  } | sort -u >"$out" || true
  rm -f "$marker"
}

# _pff_tree <worktree> <merge-base> <tree> <copy-set-file> — builds the
# pre-fix tree. rc 1 when git refuses.
_pff_tree() {
  local wt="$1" mb="$2" tree="$3" set="$4" op p d
  git -C "$wt" worktree add --detach --quiet "$tree" "$mb" >/dev/null 2>&1 || return 1
  while IFS=$'\t' read -r op p; do
    [ -n "$p" ] || continue
    case "$op" in
    D) rm -f "$tree/$p" ;;
    C)
      [ -f "$wt/$p" ] || continue
      mkdir -p "$(dirname "$tree/$p")"
      cp "$wt/$p" "$tree/$p"
      ;;
    esac
  done <"$set"
  if declare -f _mirror_gitignored_env_files >/dev/null 2>&1 ||
    source "$_PFF_LIB/worktree.sh" 2>/dev/null; then
    _mirror_gitignored_env_files "$wt" "$tree" 2>/dev/null || true
  fi
  for d in node_modules .venv venv; do
    if [ -d "$wt/$d" ] && [ ! -e "$tree/$d" ]; then ln -s "$wt/$d" "$tree/$d"; fi
  done
  find "$tree" -type f -name '*.xml' -not -path '*/.git/*' -not -path '*/node_modules/*' \
    -exec grep -l '<testcase' {} + 2>/dev/null | while IFS= read -r p; do rm -f "$p"; done
  return 0
}

_pff_cleanup() {
  [ -n "${_PFF_TREE:-}" ] || return 0
  git -C "$_PFF_WT" worktree remove --force "$_PFF_TREE" >/dev/null 2>&1 || true
  rm -rf "$_PFF_TREE"
  git -C "$_PFF_WT" worktree prune >/dev/null 2>&1 || true
  [ -n "${_PFF_OUT:-}" ] && rm -rf "$_PFF_OUT"
  _PFF_TREE=""
  trap - EXIT INT TERM
}

_pff_emit() {
  local verdict="$1" reason="$2" fields="$3"
  printf 'PRE_FIX_VERDICT=%s\nPRE_FIX_REASON=%s\n' "$verdict" "$reason"
  bash "$_PFF_LIB/plog.sh" META pre-fix-fails info "verdict=$verdict reason=$reason $fields" >/dev/null 2>&1 || true
}

# pff_check <TID> <worktree> <base-ref> <claude-md> <name>...
pff_check() {
  local tid="$1" wt="$2" ref="$3" md="$4" slug mb n_copy mode cmd junit_dir started
  local before_list after_list rc_b rc_a name sb sa reason="" verdict all_fail=1 any_weak=0
  shift 4
  started=$(date +%s)
  slug=$(basename "$wt")
  if [ "$(pff_mode)" = "off" ]; then
    _pff_emit skipped off "repo=$slug"
    return 0
  fi
  if ! mb=$(git -C "$wt" merge-base HEAD "$ref" 2>/dev/null); then
    _pff_emit unproven no-merge-base "repo=$slug ref=$ref"
    return 0
  fi
  # shellcheck source=ticket-env.sh
  source "$_PFF_LIB/ticket-env.sh" "$tid" 2>/dev/null || true
  if ! vat_test_cmd "$slug" "$md"; then
    _pff_emit skipped no-test-command "repo=$slug base=${mb:0:12}"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    _pff_emit unproven no-python3 "repo=$slug base=${mb:0:12}"
    return 0
  fi
  if [ $# -eq 0 ]; then
    _pff_emit unproven no-named-test "repo=$slug base=${mb:0:12}"
    return 0
  fi

  _PFF_WT="$wt"
  _PFF_OUT=$(mktemp -d)
  _PFF_TREE="$(dirname "$wt")/.pre-fix-$slug"
  trap '_pff_cleanup' EXIT
  trap '_pff_cleanup; exit 130' INT
  trap '_pff_cleanup; exit 143' TERM
  if [ -e "$_PFF_TREE" ]; then
    git -C "$wt" worktree remove --force "$_PFF_TREE" >/dev/null 2>&1 || true
    rm -rf "$_PFF_TREE"
    git -C "$wt" worktree prune >/dev/null 2>&1 || true
  fi

  pff_copy_set "$wt" "$mb" >"$_PFF_OUT/set"
  n_copy=$(grep -c '^C' "$_PFF_OUT/set" || true)
  if [ "${n_copy:-0}" -eq 0 ]; then
    _pff_emit unproven no-test-files "repo=$slug base=${mb:0:12} copied=0"
    _pff_cleanup
    return 0
  fi
  if ! _pff_tree "$wt" "$mb" "$_PFF_TREE" "$_PFF_OUT/set"; then
    _pff_emit unproven no-pre-fix-tree "repo=$slug base=${mb:0:12}"
    _pff_cleanup
    return 0
  fi

  junit_dir="$_PFF_OUT/junit"
  mkdir -p "$junit_dir/b" "$junit_dir/a"
  IFS=$'\t' read -r mode cmd < <(pff_command "$VAT_CMD" "$junit_dir/b/report.xml" "$@")
  _pff_run "$_PFF_TREE" "$cmd" "$_PFF_OUT/before.log" "$_PFF_OUT/before.list" "$junit_dir/b"
  rc_b=$PFF_RC
  IFS=$'\t' read -r mode cmd < <(pff_command "$VAT_CMD" "$junit_dir/a/report.xml" "$@")
  _pff_run "$wt" "$cmd" "$_PFF_OUT/after.log" "$_PFF_OUT/after.list" "$junit_dir/a"
  rc_a=$PFF_RC

  local fields="repo=$slug mode=$mode rc_before=$rc_b rc_after=$rc_a base=${mb:0:12} copied=$n_copy"
  if [ "$rc_b" -eq 124 ] || [ "$rc_b" -eq 137 ]; then
    for name in "$@"; do printf 'PRE_FIX_TEST\t%s\ttimeout\t-\n' "$name"; done
    _pff_emit unproven timeout "$fields report=- secs=$(($(date +%s) - started)) tests=$*"
    _pff_cleanup
    return 0
  fi
  # No report: after the fix, or before it with exit 0. Before it with a
  # non-zero exit is did-not-build, judged below (every name absent).
  if { [ ! -s "$_PFF_OUT/before.list" ] && [ "$rc_b" -eq 0 ]; } || [ ! -s "$_PFF_OUT/after.list" ]; then
    for name in "$@"; do printf 'PRE_FIX_TEST\t%s\tno-report\tno-report\n' "$name"; done
    _pff_emit unproven no-report "$fields report=none secs=$(($(date +%s) - started)) tests=$*"
    _pff_cleanup
    return 0
  fi

  before_list=$(pff_judge "$_PFF_OUT/before.list" "$@")
  after_list=$(pff_judge "$_PFF_OUT/after.list" "$@")
  for name in "$@"; do
    sb=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' <<<"$before_list")
    sa=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' <<<"$after_list")
    case "$sb" in
    failed) ;;
    errored) any_weak=1 ;;
    absent)
      # did-not-build only when the run wrote no report at all: with reports,
      # a non-zero exit can come from any other failing test.
      if [ "$rc_b" -ne 0 ] && [ ! -s "$_PFF_OUT/before.list" ]; then
        sb=did-not-build any_weak=1
      else
        sb=not-run-before-fix
      fi
      ;;
    passed) sb=passes-before-fix ;;
    skipped) sb=not-run-before-fix ;;
    esac
    [ "$sa" = passed ] || sa=not-passing-after
    printf 'PRE_FIX_TEST\t%s\t%s\t%s\n' "$name" "$sb" "$sa"
    if [ -z "$reason" ]; then
      if [ "$sb" = ambiguous ] || [ "$sa" = ambiguous ]; then
        reason=ambiguous-name
      else
        case "$sb" in
        failed | errored | did-not-build) [ "$sa" = passed ] || reason=not-passing-after ;;
        *) reason="$sb" ;;
        esac
      fi
    fi
    case "$sb" in failed | errored | did-not-build) ;; *) all_fail=0 ;; esac
  done
  if [ -z "$reason" ] && [ "$all_fail" -eq 1 ]; then
    if [ "$any_weak" -eq 1 ]; then verdict=proved-weak reason=weak; else verdict=proved reason=ok; fi
  else
    verdict=unproven
  fi
  _pff_emit "$verdict" "$reason" "$fields report=junit secs=$(($(date +%s) - started)) tests=$*"
  _pff_cleanup
  return 0
}

_pff_usage() {
  sed -n '5,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  return 2
}

_pff_main() {
  local cmd="${1:-}" tid="" wt="" ref="" md="./CLAUDE.md"
  local -a tests=()
  [ $# -gt 0 ] && shift
  case "$cmd" in
  wanted)
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
      _pff_usage
      return 2
    fi
    case "$1" in '' | -* | *[!A-Za-z0-9_-]*)
      _pff_usage
      return 2
      ;;
    esac
    pff_wanted "$1" "${2:-}"
    return 0
    ;;
  check) ;;
  *)
    _pff_usage
    return 2
    ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
    --worktree | --base-ref | --test | --claude-md)
      [ $# -ge 2 ] || {
        echo "pre-fix-fails: $1 needs a value" >&2
        return 2
      }
      case "$1" in
      --worktree) wt="$2" ;;
      --base-ref) ref="$2" ;;
      --test) tests+=("$2") ;;
      --claude-md) md="$2" ;;
      esac
      shift 2
      ;;
    -*)
      echo "pre-fix-fails: unknown option $1" >&2
      return 2
      ;;
    *)
      [ -z "$tid" ] || {
        echo "pre-fix-fails: unexpected argument $1" >&2
        return 2
      }
      tid="$1"
      shift
      ;;
    esac
  done
  case "$tid" in '' | *[!A-Za-z0-9_-]*)
    _pff_usage
    return 2
    ;;
  esac
  if [ -z "$wt" ] || [ -z "$ref" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    echo "pre-fix-fails: --worktree must be a git checkout and --base-ref is required" >&2
    return 2
  fi
  pff_check "$tid" "$(cd "$wt" && pwd)" "$ref" "$md" "${tests[@]}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _pff_main "$@"
  exit $?
fi
