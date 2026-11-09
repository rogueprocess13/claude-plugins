#!/usr/bin/env bash
# draft-readiness-compose-memo.sh — test-only memo for
# planner_draft_readiness_compose, shared by the draft readiness gate suites
# (draft-readiness-gate-harness.sh) and loop suites
# (draft-readiness-loop-harness.sh).
#
# Sourced, never run, after planner-draft-readiness.sh is loaded and with
# TMP_ROOT and REPOS_ROOT set.
#
# compose is re-run on every refresh (begin, each next, apply, gate) for every
# spec and is most of a gate run's time. The memo keys it on everything it
# reads — its arguments, the PLANNER_*/DOR_* environment, the first
# Crosscheck|check|done line, and the bytes of every file under artifacts/
# except draft-readiness/ — and replays the stored stdout, stderr and exit
# code, so a hit is byte-identical to a fresh compose. A failed compose is
# never stored. LOOP_TEST_COMPOSE_MEMO=0 turns the memo off.

if [ "${LOOP_TEST_COMPOSE_MEMO:-1}" != 0 ]; then
  COMPOSE_MEMO="${TMP_ROOT}/compose-memo"
  mkdir -p "$COMPOSE_MEMO"
  eval "$(declare -f planner_draft_readiness_compose | sed '1s/^planner_draft_readiness_compose /_loop_compose_uncached /')"
  planner_draft_readiness_compose() {
    local idir="${REPOS_ROOT}/.ticket-auto/initiatives/$1" key f rc=0
    key=$({
      printf '%s\0' "$@"
      env | grep -E '^(PLANNER|DOR)_' | sort
      grep -E '^[^|]*\|Crosscheck\|check\|done\|' "${idir}/state.log" 2>/dev/null | head -1
      if [ -d "${idir}/artifacts" ]; then
        find "${idir}/artifacts" -path "${idir}/artifacts/draft-readiness" -prune -o -type f -print0 |
          sort -z | xargs -0 -r sha256sum
      fi
    } | sha256sum | cut -c1-64)
    f="${COMPOSE_MEMO}/${key}"
    if [ ! -f "${f}.out" ]; then
      _loop_compose_uncached "$@" >"${f}.out.tmp" 2>"${f}.err" || rc=$?
      if [ "$rc" -ne 0 ]; then
        cat "${f}.out.tmp"
        cat "${f}.err" >&2
        rm -f "${f}.out.tmp" "${f}.err"
        return "$rc"
      fi
      mv -f "${f}.out.tmp" "${f}.out"
    fi
    cat "${f}.err" >&2
    cat "${f}.out"
  }
fi
