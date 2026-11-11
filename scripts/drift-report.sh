#!/usr/bin/env bash
# drift-report.sh — on-demand spec/doc drift report (next.md Step 18 item 3,
# borrowed from EGM's drift report). One headless, read-only `claude -p` per
# document compares the document with the code and returns a strict
# DRIFT_RESULT block. A document whose agent fails, times out or returns no
# well-formed block is NOT RUN — never counted as clean. Findings never change
# the exit code: this reports, it does not gate. Never wire it into CI.
#
# Usage: scripts/drift-report.sh [--root DIR] [--out DIR] [--only GLOB]
#                                [-j N] [--list] [--resume]
#   --root    repository root (default: git toplevel of the cwd)
#   --out     output dir (default: <root>/drift-reports/YYYY-MM-DD)
#   --only    bash glob over the repo-relative path, e.g. 'ticket-auto-pipeline/docs/*'
#   -j        parallel agents (default 4)
#   --list    print the targets and exit 0; spawns nothing
#   --resume  skip documents that already have a non-not-run result in --out
#
# Env: DRIFT_CLAUDE_BIN (default claude), DRIFT_MODEL (sonnet),
#      DRIFT_TIMEOUT seconds per document (900), DRIFT_BUDGET_USD per document (2).
#
# Exit: 0 every document ran; 1 at least one not run; 2 usage / no targets.
#
# Outputs in --out: raw/<slug>.out|.err (agent stdout/stderr), res/<slug>.tsv
# (doc<TAB>status<TAB>findings), res/<slug>.findings, results.tsv, report.md.
# Status is clean | drift | not_run:<reason>.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PROMPT_FILE="$(dirname "$SELF")/drift-report-prompt.md"
KINDS=" missing-behaviour missing-field hardcoded different-pattern dead-reference "
MAX_FINDINGS=50

_slug() { printf '%s' "${1//\//__}"; }

# ── Worker: one document. Always exits 0 and always writes res/<slug>.tsv. ──
_worker() {
  local doc="$1" slug out err rc=0 text n=0 status
  slug="$(_slug "$doc")"
  out="$DRIFT_OUT_DIR/raw/$slug.out"
  err="$DRIFT_OUT_DIR/raw/$slug.err"
  local res="$DRIFT_OUT_DIR/res/$slug.tsv" fnd="$DRIFT_OUT_DIR/res/$slug.findings"
  : >"$fnd"
  _done() {
    printf '%s\t%s\t%s\n' "$doc" "$1" "$2" >"$res"
    exit 0
  }

  cd "$DRIFT_ROOT" || _done "not_run:no-root" "-"
  local prompt
  prompt="$(cat "$PROMPT_FILE")"
  printf '%s\n' "${prompt//\{DOC\}/$doc}" |
    timeout -k 10 "${DRIFT_TIMEOUT:-900}" "${DRIFT_CLAUDE_BIN:-claude}" -p \
      --output-format json \
      --model "${DRIFT_MODEL:-sonnet}" \
      --tools Read,Grep,Glob \
      --permission-mode dontAsk \
      --no-session-persistence \
      --disable-slash-commands \
      --strict-mcp-config \
      --max-budget-usd "${DRIFT_BUDGET_USD:-2}" \
      >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && _done "not_run:timeout" "-"
  [ "$rc" -ne 0 ] && _done "not_run:exit-$rc" "-"
  [ -s "$out" ] || _done "not_run:empty" "-"

  # JSON envelope → .result; is_error → not run. Non-JSON → the raw text.
  if jq -e 'type == "object" and has("result")' "$out" >/dev/null 2>&1; then
    [ "$(jq -r '.is_error // false' "$out")" = "true" ] && _done "not_run:is-error" "-"
    text="$(jq -r '.result // ""' "$out")"
  else
    text="$(cat "$out")"
  fi

  # Take the LAST DRIFT_RESULT v1 block, so prose or a draft before it is ignored.
  local -a lines=()
  mapfile -t lines <<<"$text"
  local i start=-1
  for i in "${!lines[@]}"; do
    [ "$(_trim "${lines[$i]}")" = "DRIFT_RESULT v1" ] && start=$i
  done
  [ "$start" -lt 0 ] && _done "not_run:malformed" "-"
  [ "$(_trim "${lines[$((start + 1))]:-}")" = "DOC: $doc" ] || _done "not_run:malformed" "-"

  local ended=false l kind anchor ref summary rest verified
  for ((i = start + 2; i < ${#lines[@]}; i++)); do
    l="$(_trim "${lines[$i]}")"
    [ -z "$l" ] && continue
    [ "$l" = "END" ] && {
      ended=true
      break
    }
    case "$l" in FINDING\|*) ;; *) _done "not_run:malformed" "-" ;; esac
    rest="${l#FINDING|}"
    kind="${rest%%|*}"
    rest="${rest#*|}"
    anchor="${rest%%|*}"
    rest="${rest#*|}"
    ref="${rest%%|*}"
    summary="${rest#*|}"
    [ "$summary" = "$rest" ] && _done "not_run:malformed" "-"
    [[ "$KINDS" == *" $kind "* ]] || _done "not_run:malformed" "-"
    [ -n "$ref" ] && [ -n "$summary" ] || _done "not_run:malformed" "-"
    verified="$(_verify_ref "$ref" "$kind")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$doc" "$kind" "$anchor" "$ref" "$verified" "$summary" >>"$fnd"
    n=$((n + 1))
  done
  [ "$ended" = true ] || _done "not_run:malformed" "-"
  [ "$n" -gt "$MAX_FINDINGS" ] && {
    : >"$fnd"
    _done "not_run:malformed" "-"
  }
  status=clean
  [ "$n" -gt 0 ] && status=drift
  _done "$status" "$n"
}

_trim() {
  local s="${1%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# _verify_ref <ref> <kind> — deterministic check of a finding's code
# reference: `path` or `path:line[-line]` must exist (line within the file).
# A dead-reference finding is the reverse: the cited path must be missing.
# Prints ok | unverified. Paths are taken relative to the repo root.
_verify_ref() {
  local ref="$1" kind="$2" path line=""
  path="${ref%%:*}"
  [ "$path" != "$ref" ] && line="${ref#*:}" && line="${line%%-*}"
  if [ "$kind" = "dead-reference" ]; then
    [ -e "$path" ] && echo unverified || echo ok
    return
  fi
  [ -f "$path" ] || {
    echo unverified
    return
  }
  if [ -n "$line" ]; then
    [[ "$line" =~ ^[0-9]+$ ]] && [ "$line" -ge 1 ] && [ "$line" -le "$(wc -l <"$path")" ] || {
      echo unverified
      return
    }
  fi
  echo ok
}

if [ "${1:-}" = "--worker" ]; then
  _worker "$2"
  exit 0
fi

# ── Main ────────────────────────────────────────────────────────────────────
_usage() {
  sed -n '9,16p' "$SELF" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

ROOT="" OUT="" ONLY="" JOBS=4 LIST=false RESUME=false
while [ $# -gt 0 ]; do
  case "$1" in
  --root) ROOT="${2:-}" && shift 2 ;;
  --out) OUT="${2:-}" && shift 2 ;;
  --only) ONLY="${2:-}" && shift 2 ;;
  -j) JOBS="${2:-}" && shift 2 ;;
  --list) LIST=true && shift ;;
  --resume) RESUME=true && shift ;;
  -h | --help) _usage ;;
  *)
    echo "drift-report: unknown argument: $1" >&2
    _usage
    ;;
  esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || {
  echo "drift-report: -j needs a positive integer" >&2
  exit 2
}
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$ROOT" ] && [ -d "$ROOT" ] || {
  echo "drift-report: no repository root (use --root)" >&2
  exit 2
}
ROOT="$(cd "$ROOT" && pwd)"

TARGETS=()
while IFS= read -r t; do
  [ -z "$t" ] && continue
  if [ -n "$ONLY" ]; then
    # shellcheck disable=SC2053 # $ONLY is a glob on purpose
    [[ "$t" == $ONLY ]] || continue
  fi
  TARGETS+=("$t")
done < <(
  {
    (cd "$ROOT" && compgen -G 'openspec/specs/*/spec.md') || true
    git -C "$ROOT" ls-files -- '*/docs/*.md'
  } | LC_ALL=C sort -u
)
[ "${#TARGETS[@]}" -gt 0 ] || {
  echo "drift-report: no target matches${ONLY:+ --only '$ONLY'}" >&2
  exit 2
}

if [ "$LIST" = true ]; then
  printf '%s\n' "${TARGETS[@]}"
  exit 0
fi

[ -n "$OUT" ] || OUT="$ROOT/drift-reports/$(date +%F)"
mkdir -p "$OUT/raw" "$OUT/res" || exit 2
OUT="$(cd "$OUT" && pwd)"

TODO=()
for t in "${TARGETS[@]}"; do
  if [ "$RESUME" = true ] && [ -f "$OUT/res/$(_slug "$t").tsv" ] &&
    ! cut -f2 "$OUT/res/$(_slug "$t").tsv" | grep -q '^not_run'; then
    continue
  fi
  TODO+=("$t")
done

echo "drift-report: ${#TODO[@]} of ${#TARGETS[@]} document(s), -j $JOBS, model ${DRIFT_MODEL:-sonnet} → $OUT" >&2
if [ "${#TODO[@]}" -gt 0 ]; then
  printf '%s\0' "${TODO[@]}" |
    DRIFT_ROOT="$ROOT" DRIFT_OUT_DIR="$OUT" xargs -0 -n1 -P"$JOBS" bash "$SELF" --worker || true
fi

# ── Aggregate ───────────────────────────────────────────────────────────────
: >"$OUT/results.tsv"
for t in "${TARGETS[@]}"; do
  f="$OUT/res/$(_slug "$t").tsv"
  if [ -f "$f" ]; then cat "$f" >>"$OUT/results.tsv"; else printf '%s\tnot_run:no-result\t-\n' "$t" >>"$OUT/results.tsv"; fi
done

checked=$(wc -l <"$OUT/results.tsv")
clean=$(cut -f2 "$OUT/results.tsv" | grep -c '^clean$')
drift=$(cut -f2 "$OUT/results.tsv" | grep -c '^drift$')
notrun=$(cut -f2 "$OUT/results.tsv" | grep -c '^not_run')

{
  echo "# Spec/doc drift report — $(date +%F)"
  echo
  echo "Model: ${DRIFT_MODEL:-sonnet} · Root: \`$ROOT\`"
  echo
  echo "Checked: $checked · Clean: $clean · Drift: $drift · Not run: $notrun"
  echo
  echo "Advisory only: an LLM wrote these findings. \`openspec/specs/\` is gitignored, so spec"
  echo "results reflect this checkout only. Ref \`unverified\` means the cited code path or line"
  echo "does not exist (or, for dead-reference, the path does exist) — check those first."
  if [ "$drift" -gt 0 ]; then
    echo
    echo "## Findings"
    for t in "${TARGETS[@]}"; do
      fnd="$OUT/res/$(_slug "$t").findings"
      [ -s "$fnd" ] || continue
      echo
      echo "### \`$t\`"
      echo
      echo "| Kind | Doc section | Code | Ref | Divergence |"
      echo "| --- | --- | --- | --- | --- |"
      while IFS=$'\t' read -r _ kind anchor ref verified summary; do
        printf '| %s | %s | `%s` | %s | %s |\n' "$kind" "$anchor" "$ref" "$verified" "$summary"
      done <"$fnd"
    done
  fi
  if [ "$notrun" -gt 0 ]; then
    echo
    echo "## Not run"
    echo
    while IFS=$'\t' read -r d s _; do
      case "$s" in not_run:*) echo "- $d — ${s#not_run:}" ;; esac
    done <"$OUT/results.tsv"
  fi
} >"$OUT/report.md"

echo "drift-report: checked $checked, clean $clean, drift $drift, not run $notrun — $OUT/report.md" >&2
[ "$notrun" -eq 0 ]
