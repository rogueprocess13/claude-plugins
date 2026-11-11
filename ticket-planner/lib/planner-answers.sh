#!/usr/bin/env bash
# planner-answers.sh — `resume <INIT_ID> --answers <file>` intake
# (planner-headless-questions).
#
# Validates an answers file against the round planner-stop-describe.sh
# reports as open, then turns each answer into the input the matching resume
# flag would have supplied — through the same persistence functions SKILL.md
# step 2b calls. No new gate logic: the gates already have tested semantics,
# and an answer is just another way to supply their flags.
#
#   flag:create            yes → planner_authorize_create (+ clear stop-after,
#                          exactly as --create does); no → nothing
#   flag:refresh-bodies    yes → planner_config_set refresh-bodies true (the
#                          one-shot --refresh-bodies flag, planner-refinement-
#                          convergence D6); no → nothing
#   flag:accept:DRAFT_NOT_READY
#                          planner_draft_readiness_accept <reason> — its own
#                          branch, never a Crosscheck accept
#   flag:accept:<CODE>     planner_crosscheck_accept_set <CODE> <reason>
#   flag:project           planner_config_set linear-project <value>, or
#                          no-project=true for __none__
#   waive:<TICKET>:<CODE>  waive_ticket_readiness_code — the function
#                          `dor-check.sh --waive` wraps
#   note                   recorded only
#   consensus-answer:cited:<n>
#                          planner_cited_answer_set — rewrites the Answer:
#                          field of consensus.md's nth CITED_ARTIFACT question
#                          (#515). The value must be exists:<where>,
#                          external:<who> or generate; it is checked on the
#                          raw text, before sanitising, so a `|`, CR or LF is
#                          refused rather than turned into a space. Specs are
#                          not touched: a spec need whose Source disagrees
#                          with the new answer is CITED_ARTIFACT_SOURCE_MISMATCH
#                          on the Crosscheck re-run, which names the spec and
#                          the Source it needs.
#   consensus-answer:testdata:<slug>
#                          planner_testdata_answer_set — writes or replaces
#                          the spec's TESTDATA_CONFIRM line in consensus.md
#                          (planner-test-data-derivation), keyed by the hash8
#                          the question id ends in (testdata-<slug>-<hash8>).
#                          The value must be none, generate: <description>,
#                          exists:<where> or external:<who>; empty values and
#                          an empty description are refused on the raw text,
#                          and `|`, CR and LF are stripped from free text.
#                          The hash is re-derived from the spec at intake: a
#                          criterion rewritten since the question is refused
#                          as STALE_QUESTION (the describer re-asks it under
#                          a new id), never confirmed silently.
#   specify-answer:O<n>    planner_specify_substitute (planner-specify-
#                          decisions.sh) — replaces outcome O<n>'s
#                          NEEDS_HUMAN_DECISION line in proposal.md with
#                          `**Outcome:** Human decision (verbatim, round N,
#                          <role>): "<answer>"`, or, for `__defer__`,
#                          `**Outcome:** Deferred decision: <question>`
#                          (planner-specify-waiting-on-human). The value is
#                          trimmed; it is `__defer__` or non-blank text of at
#                          most 500 characters (a longer one is INVALID_VALUE,
#                          never cut). The id's hash8 must still be the
#                          decision's current hash, so an edited or already
#                          answered decision is UNKNOWN_QUESTION_ID. Logged as
#                          META|specify-answer|step|O<n> [<hash8>]
#                          answered|deferred (round N, by <who>, <role>) — the
#                          answer text is deliberately NOT copied into
#                          state.log (it lives in proposal.md and round-N.json).
#   specify-param:<key>    planner_params_substitute (planner-specify-params.sh)
#                          — replaces the open `## Parameters` row for <key>
#                          with one rebuilt row: Name, key, Kind and Default
#                          kept, Value the neutralised answer (`|` escaped),
#                          Source `human:r<N>:<role>` (planner-specify-
#                          parameters). The value is trimmed, non-blank, at
#                          most 500 characters; `__defer__` is refused; a
#                          `duration` row takes exactly one time literal, a
#                          `limit`/`size` row one unit literal or a bare
#                          positive number (refusals give an example). To
#                          accept the suggestion, send its text — there is no
#                          sentinel. Logged as META|specify-param|step|<key>
#                          answered (round N, by <who>, <role>), without the
#                          value; round-N.json stores question, suggestion
#                          and value.
#
# Both specify- bindings go through one resolver (_planner_answers_specify_
# resolve) and one substitution pass into a single temp copy of proposal.md,
# so a round mixing them is written in one replacement.
#
# `__skip__` as the value of an accept or waive answer declines it.
#
# The whole intake runs under a per-initiative lock: `flock -x` on
# <state.log>.answers-lock, or, where flock is missing, a `mkdir` lock on
# <state.log>.answers-lock.d with a bounded wait (PLANNER_ANSWERS_LOCK_WAIT_SECS,
# default 30) and then exit 1 INTAKE_BUSY. A lock directory left by a killed
# intake is not reaped: remove it by hand. The lock serialises the idempotency
# read with the writes, so of two different files for one round exactly one
# applies and the other gets ROUND_ALREADY_ANSWERED. planner_state_write locks
# a different file (<state.log>.lock), so the two never deadlock.
#
# Order of writes, so a crash at any point is safe to replay:
#   1. artifacts/answers/round-N.json   (tmp + mv; for specify-answer the
#      rewritten proposal.md is built in a temp file before this)
#   2. META|human-hold|start|round=N sha=<sha256>
#   3. the flag/waiver writes (and the META|specify-answer lines)
#   3b. specify items only: proposal.md's sha256 is checked again (a hand
#      edit since validation is refused as UNKNOWN_QUESTION_ID, the edit is
#      kept, the round is left at start without done), then the temp file
#      is moved into place
#   4. META|human-hold|done|round=N sha=<sha256>   — always last
# The `done` line is the idempotency key: the same file again is a no-op, a
# different file for an answered round is refused. (The `start` line is also
# what lets a later round's `done` through planner_state_write's
# duplicate-done suppression.) A Specify round that crashed after 3b and
# before 4 has no open decision left to describe; replaying the same file
# finds its start line, its META|specify-answer / META|specify-param lines and
# its rendered lines and rows in proposal.md, appends the missing `done`, and
# reports
# ANSWERS_ALREADY_APPLIED.
#
# Answer text is untrusted (docs/human-hold-schema.md § Answer text is
# untrusted data): capped at 4096 bytes, stripped of control characters and
# triple-backtick fences, stored with its attribution, and passed to the
# persistence functions as one quoted argument — never evaluated.
#
# Exit codes:
#   0  applied, or this exact file was already applied (no-op)
#   1  could not run (bad usage, no state log, jq missing, write failure,
#      INTAKE_BUSY — the mkdir lock stayed held past the bounded wait)
#   2  rejected: malformed file, UNSUPPORTED_SCHEMA_VERSION, UNKNOWN_QUESTION_ID,
#      ROLE_NOT_PERMITTED, INVALID_VALUE, STALE_QUESTION — nothing written
#   3  ROUND_ALREADY_ANSWERED — a different file already answered this round
#   4  STALE_ROUND — the file's round is not the open round (or none is open)
#
# Sourceable library (planner_answers_apply, planner_answers_sanitize) and
# standalone CLI. No set -euo pipefail at file scope (repo convention).

_PLANNER_ANSWERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_stop_describe_json >/dev/null 2>&1 ||
  source "${_PLANNER_ANSWERS_DIR}/planner-stop-describe.sh"
declare -f planner_cited_answer_set >/dev/null 2>&1 ||
  source "${_PLANNER_ANSWERS_DIR}/planner-crosscheck-testdata.sh"
declare -f planner_specify_substitute >/dev/null 2>&1 ||
  source "${_PLANNER_ANSWERS_DIR}/planner-specify-decisions.sh"
declare -f planner_params_substitute >/dev/null 2>&1 ||
  source "${_PLANNER_ANSWERS_DIR}/planner-specify-params.sh"

# Answers-file format version this consumer reads (major).
PLANNER_ANSWERS_SCHEMA_MAJOR=1
PLANNER_ANSWERS_VALUE_MAX_BYTES=4096
PLANNER_ANSWERS_REASON_MAX_CHARS=500
# Seconds the mkdir-lock fallback waits before INTAKE_BUSY.
: "${PLANNER_ANSWERS_LOCK_WAIT_SECS:=30}"

_planner_answers_reject() {
  local rc="$1" code="$2" detail="$3"
  echo "${code}: ${detail}" >&2
  return "$rc"
}

# planner_answers_sanitize <value>
# Single line, no control characters, no ``` fences, at most 4096 bytes
# (truncated on a character boundary).
planner_answers_sanitize() {
  local v
  v=$(printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  while [[ "$v" == *'```'* ]]; do
    v="${v//\`\`\`/}"
  done
  v=$(printf '%s' "$v" | LC_ALL=C head -c "$PLANNER_ANSWERS_VALUE_MAX_BYTES")
  # A byte cut can split a multi-byte character; drop the partial tail.
  if command -v iconv >/dev/null 2>&1; then
    v=$(printf '%s' "$v" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null) || true
  fi
  printf '%s' "$v"
}

# _planner_answers_trim <value> — strip surrounding whitespace.
_planner_answers_trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# _planner_answers_chars <value> — length in characters, not bytes, without
# depending on a UTF-8 locale being installed: UTF-8 continuation bytes
# (0x80-0xBF) are not counted.
_planner_answers_chars() {
  printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' '
}

_planner_answers_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Value checks per binding, on the sanitized value. Echoes nothing; returns 1
# with the reason on stderr.
_planner_answers_check_value() {
  local binding="$1" value="$2" kind="${3:-}" sugg="${4:-}" LC_ALL=C
  case "$binding" in
  flag:create | flag:refresh-bodies)
    case "$value" in
    yes | no) return 0 ;;
    esac
    echo "answer to a ${binding#flag:} question must be 'yes' or 'no'" >&2
    return 1
    ;;
  flag:accept:* | waive:*)
    [ "$value" = "__skip__" ] && return 0
    if [ -z "${value//[[:space:]]/}" ]; then
      echo "a reason is required (or __skip__ to decline)" >&2
      return 1
    fi
    if [ "${#value}" -gt "$PLANNER_ANSWERS_REASON_MAX_CHARS" ]; then
      echo "a reason is at most ${PLANNER_ANSWERS_REASON_MAX_CHARS} characters" >&2
      return 1
    fi
    return 0
    ;;
  flag:project)
    [ "$value" = "__none__" ] && return 0
    if [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._\(\)\&/+#:-]{0,127}$ ]]; then
      return 0
    fi
    echo "a project is a name or id of letters, digits, spaces and ._()&/+#:- (or __none__)" >&2
    return 1
    ;;
  note) return 0 ;;
  specify-answer:O*)
    value=$(_planner_answers_trim "$value")
    [ "$value" = "__defer__" ] && return 0
    if [ -z "${value//[[:space:]]/}" ]; then
      echo "a business decision is required (or __defer__ to leave it open)" >&2
      return 1
    fi
    if [ "$(_planner_answers_chars "$value")" -gt "$PLANNER_ANSWERS_REASON_MAX_CHARS" ]; then
      echo "a business decision is at most ${PLANNER_ANSWERS_REASON_MAX_CHARS} characters, on one line (split it, or shorten it)" >&2
      return 1
    fi
    return 0
    ;;
  specify-param:*)
    _planner_answers_param_check "$kind" "$value" "$sugg"
    return
    ;;
  consensus-answer:cited:*)
    planner_cited_answer_normalize "$value" >/dev/null
    return
    ;;
  consensus-answer:testdata:*)
    planner_testdata_answer_normalize "$value" >/dev/null
    return
    ;;
  esac
  echo "binding '${binding}' is not one the planner applies" >&2
  return 1
}

# _planner_answers_param_example <kind> <suggestion> — the example a refused
# parameter answer names (the describer's format hint uses the same ones).
_planner_answers_param_example() {
  case "$1" in
  duration) printf 'e.g. 30 minutes' ;;
  limit) printf 'e.g. 50 or 500 characters' ;;
  size) printf 'e.g. 20 or 2 GB' ;;
  *)
    if [ -n "$2" ]; then
      printf 'e.g. "%s"' "$2"
    else
      printf 'e.g. "round each invoice line half-up to 2 decimal places"'
    fi
    ;;
  esac
}

# _planner_answers_param_check <kind> <value> <suggestion> — a parameter
# answer, already sanitised and trimmed (planner-specify-parameters D5).
_planner_answers_param_check() {
  local kind="$1" value="$2" ex canon
  ex=$(_planner_answers_param_example "$kind" "$3")
  if [ "$value" = "__defer__" ]; then
    echo "a parameter value cannot be deferred — answer with a value, ${ex}" >&2
    return 1
  fi
  if [ -z "${value//[[:space:]]/}" ] || [ -z "$(_planner_specify_neutralise "$value")" ]; then
    echo "a parameter value is required, ${ex}" >&2
    return 1
  fi
  if [ "$(_planner_answers_chars "$value")" -gt "$PLANNER_ANSWERS_REASON_MAX_CHARS" ]; then
    echo "a parameter value is at most ${PLANNER_ANSWERS_REASON_MAX_CHARS} characters, on one line, ${ex}" >&2
    return 1
  fi
  case "$kind" in
  duration)
    canon=$(_planner_params_canon "$value" 2>/dev/null) || canon=""
    case "$canon" in time:* | month:*) return 0 ;; esac
    echo "a ${kind} is one number with a time unit, ${ex}" >&2
    return 1
    ;;
  limit | size)
    [[ "$value" =~ ^[1-9][0-9]*$ ]] && return 0
    _planner_params_canon "$value" >/dev/null 2>&1 && return 0
    echo "a ${kind} is a number, or one number with a unit, ${ex}" >&2
    return 1
    ;;
  esac
  return 0
}

# _planner_answers_specify_resolve <INIT> <binding> <id> <value> <round> <role> [<proposal>]
# The one specify-item resolver (planner-specify-parameters D5): matches an
# answer to an open outcome decision (planner_specify_decisions_open) or an
# open parameter row (planner_params_scan) and renders its replacement line.
# Sets, in the caller's scope: _rs_lno, _rs_question, _rs_suggestion,
# _rs_kind, _rs_rendered. The scans are cached in the caller's _rs_sd_scan /
# _rs_pp_scan / _rs_pp_rows (set to "-" before the first call).
# rc 0 resolved; 2 not open (the caller rejects UNKNOWN_QUESTION_ID); 1 error.
# Values are checked by the caller after resolution (the kind comes from here),
# so _rs_rendered is empty until _planner_answers_specify_render runs.
_planner_answers_specify_resolve() {
  local init="$1" binding="$2" id="$3" line key
  _rs_lno=""
  _rs_question=""
  _rs_suggestion=""
  _rs_kind=""
  _rs_name=""
  _rs_default=""
  case "$binding" in
  specify-answer:O*)
    if [ "$_rs_sd_scan" = "-" ]; then
      _rs_sd_scan=$(planner_specify_decisions_open "$init") || return 1
    fi
    # shellcheck disable=SC2016  # awk program, not shell
    IFS=$'\t' read -r _ _ _rs_lno _rs_question < <(printf '%s\n' "$_rs_sd_scan" |
      _PA_OID="${binding#specify-answer:}" _PA_ID="$id" awk -F'\t' '
        $1 == ENVIRON["_PA_OID"] && ENVIRON["_PA_ID"] == "decision-" $1 "-" $2 { print; exit }')
    [ -n "$_rs_lno" ] || return 2
    ;;
  specify-param:*)
    key="${binding#specify-param:}"
    [ "$id" = "param-${key}" ] || return 2
    declare -f planner_params_scan >/dev/null 2>&1 || return 2
    if [ "$_rs_pp_scan" = "-" ]; then
      _rs_pp_scan=$(planner_params_scan "$init") || return 1
      _rs_pp_rows=$(planner_params_rows "$init") || return 1
    fi
    # Columns may be empty (suggestion, default): cut, never IFS-tab read.
    line=$(printf '%s\n' "$_rs_pp_scan" | _PA_KEY="$key" awk -F'\t' '$1 == ENVIRON["_PA_KEY"] { print; exit }')
    [ -n "$line" ] || return 2
    _rs_lno=$(cut -f2 <<<"$line")
    _rs_kind=$(cut -f3 <<<"$line")
    _rs_suggestion=$(cut -f5 <<<"$line")
    _rs_question=$(cut -f6- <<<"$line")
    line=$(printf '%s\n' "$_rs_pp_rows" | _PA_KEY="$key" awk -F'\t' '$2 == ENVIRON["_PA_KEY"] { print; exit }')
    [ -n "$line" ] || return 2
    _rs_name=$(cut -f4 <<<"$line")
    _rs_default=$(cut -f5 <<<"$line")
    ;;
  *) return 2 ;;
  esac
  return 0
}

# _planner_answers_specify_render <binding> <value> <round> <role> <question> <name> <kind> <default>
# The replacement line for a resolved specify item.
_planner_answers_specify_render() {
  case "$1" in
  specify-answer:O*)
    if [ "$2" = "__defer__" ]; then
      planner_specify_render_defer "$5"
    else
      planner_specify_render_answer "$2" "$3" "$4"
    fi
    ;;
  specify-param:*)
    planner_params_render_row "$6" "${1#specify-param:}" "$7" "$8" "$2" "$3" "$4"
    ;;
  *) return 1 ;;
  esac
}

# _planner_answers_testdata_current <INIT> <binding> <question_id>
# Is the hash8 the question id ends in still the hash of the spec's current
# trigger criterion? Returns 1 with the reason on stderr when the spec is gone,
# no longer implies data, or its criterion was rewritten since the question.
_planner_answers_testdata_current() {
  local init="$1" slug="${2#consensus-answer:testdata:}" qhash="${3##*-}" spec trig tier reason phrase hash crit
  spec="$(planner_initiative_dir "$init")/artifacts/specs/${slug}.md"
  if [ ! -f "$spec" ]; then
    echo "spec ${slug}.md no longer exists" >&2
    return 1
  fi
  trig=$(_planner_testdata_spec_trigger "$spec" "$(_planner_testdata_entity_names "$init")")
  IFS=$'\037' read -r tier reason phrase hash crit <<<"$trig"
  if [ -z "$hash" ] || [ "$hash" != "$qhash" ]; then
    echo "the criterion this question asked about has changed (now [${hash:-none}]) — re-describe and answer the new question" >&2
    return 1
  fi
}

# planner_answers_apply <INIT_ID> <answers_file>
# Takes the per-initiative intake lock, then runs the intake. Anything that
# stops the lock path from being resolved (bad usage, bad id, no state log)
# is left to the intake itself, which reports it with the usual message.
planner_answers_apply() {
  local init="$1" file="$2" log lock rc=0 fd waited
  if [ -z "$init" ] || [ -z "$file" ] ||
    ! planner_validate_initiative_id "$init" >/dev/null 2>&1 ||
    ! log=$(planner_state_log "$init" 2>/dev/null) || [ ! -f "$log" ]; then
    _planner_answers_apply_locked "$init" "$file"
    return
  fi
  lock="${log}.answers-lock"

  if command -v flock >/dev/null 2>&1; then
    exec {fd}>>"$lock" || {
      echo "planner-answers: cannot open the intake lock ${lock}" >&2
      return 1
    }
    flock -x "$fd" || {
      exec {fd}>&-
      echo "planner-answers: cannot take the intake lock ${lock}" >&2
      return 1
    }
    _planner_answers_apply_locked "$init" "$file" || rc=$?
    exec {fd}>&-
    return "$rc"
  fi

  # No flock: a mkdir lock with a bounded wait.
  waited=0
  until mkdir "${lock}.d" 2>/dev/null; do
    if [ "$waited" -ge "$PLANNER_ANSWERS_LOCK_WAIT_SECS" ]; then
      echo "INTAKE_BUSY: another intake holds ${lock}.d (waited ${waited}s); if none is running, remove that directory and retry" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  _planner_answers_apply_locked "$init" "$file" || rc=$?
  rmdir "${lock}.d" 2>/dev/null || true
  return "$rc"
}

# _planner_answers_specify_recover <INIT> <round> <sha> <file> <round_file> <proposal>
# A Specify round that crashed after proposal.md was replaced and before its
# `done` line: the start line for this file's sha is there, and for every
# record of the round file —
#   specify-answer:O<n>  its META|specify-answer line for round N, and its
#                        rendered line in proposal.md;
#   specify-param:<key>  its META|specify-param line for round N, and a
#                        `## Parameters` row for <key> whose Source is
#                        human:r<N>:<role> and whose Value is the neutralised
#                        answer (the row the round rebuilt).
# Returns 0 when all of that holds (the caller writes `done`), 1 otherwise —
# also for a round holding any other binding.
_planner_answers_specify_recover() {
  local init="$1" round="$2" sha="$3" file="$4" round_file="$5" proposal="$6"
  local log n i rec id binding oid h8 value role question rendered key rows
  log=$(planner_state_log "$init") || return 1
  grep -q "^[^|]*|META|human-hold|start|round=${round} sha=${sha}\$" "$log" 2>/dev/null || return 1
  [ -f "$round_file" ] && [ -f "$proposal" ] || return 1
  [ "$(jq -r '.sha256 // ""' "$round_file" 2>/dev/null)" = "$sha" ] || return 1
  n=$(jq '.answers | length' "$round_file" 2>/dev/null) || return 1
  [ "${n:-0}" -gt 0 ] || return 1
  rows="-"
  for ((i = 0; i < n; i++)); do
    rec=$(jq -c ".answers[$i]" "$round_file")
    id=$(printf '%s' "$rec" | jq -r '.id')
    binding=$(printf '%s' "$rec" | jq -r '.binding')
    value=$(printf '%s' "$rec" | jq -r '.value')
    role=$(printf '%s' "$rec" | jq -r '.role')
    case "$binding" in
    specify-answer:O*)
      oid="${binding#specify-answer:}"
      [[ "$id" =~ ^decision-${oid}-([0-9a-f]{8})$ ]] || return 1
      h8="${BASH_REMATCH[1]}"
      grep -qF "(round ${round}, " < <(grep -F "|META|specify-answer|step|${oid} [${h8}] " "$log") || return 1
      question=$(printf '%s' "$rec" | jq -r '.question // ""')
      if [ "$value" = "__defer__" ]; then
        rendered=$(planner_specify_render_defer "$question")
      else
        rendered=$(planner_specify_render_answer "$value" "$round" "$role") || return 1
      fi
      grep -qxF -- "$rendered" "$proposal" || return 1
      ;;
    specify-param:*)
      key="${binding#specify-param:}"
      [ "$id" = "param-${key}" ] || return 1
      grep -qF "|META|specify-param|step|${key} answered (round ${round}, " "$log" || return 1
      declare -f planner_params_rows >/dev/null 2>&1 || return 1
      [ "$rows" != "-" ] || rows=$(planner_params_rows "$init" "$proposal") || return 1
      # shellcheck disable=SC2016  # awk program, not shell
      printf '%s\n' "$rows" | _PA_KEY="$key" _PA_SRC="human:r${round}:${role}" \
        _PA_VAL="$(_planner_specify_neutralise "$value")" awk -F'\t' '
          BEGIN { r = 1 }
          $2 == ENVIRON["_PA_KEY"] && $7 == ENVIRON["_PA_SRC"] && $6 == ENVIRON["_PA_VAL"] { r = 0 }
          END { exit r }' || return 1
      ;;
    *) return 1 ;;
    esac
  done
  return 0
}

# _planner_answers_apply_locked <INIT_ID> <answers_file> — the intake proper.
# Called only by planner_answers_apply, under the intake lock.
_planner_answers_apply_locked() {
  local init="$1" file="$2"

  if [ -z "$init" ] || [ -z "$file" ]; then
    echo "Usage: planner-answers.sh <INIT_ID> <answers.json>" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "planner-answers: jq not available" >&2
    return 1
  }
  planner_validate_initiative_id "$init" || return 1
  local log state_dir
  log=$(planner_state_log "$init") || return 1
  state_dir=$(planner_initiative_dir "$init") || return 1
  [ -f "$log" ] || {
    echo "planner-answers: no state log for '${init}'" >&2
    return 1
  }
  [ -f "$file" ] || _planner_answers_reject 2 INVALID_FILE "answers file not found: ${file}" || return

  # ── shape ──────────────────────────────────────────────────────────────
  if ! jq -e 'type == "object" and (.answers | type == "array") and (.round | type == "number")
              and has("schema_version")' "$file" >/dev/null 2>&1; then
    _planner_answers_reject 2 INVALID_FILE "not an answers file (needs schema_version, round, answers[])"
    return
  fi

  local major
  major=$(jq -r '.schema_version | tostring | split(".")[0]' "$file")
  if [ "$major" != "$PLANNER_ANSWERS_SCHEMA_MAJOR" ]; then
    _planner_answers_reject 2 UNSUPPORTED_SCHEMA_VERSION "schema_version $(jq -c '.schema_version' "$file") (this planner reads major ${PLANNER_ANSWERS_SCHEMA_MAJOR})"
    return
  fi

  local round sha
  round=$(jq -r '.round' "$file")
  sha=$(_planner_answers_sha "$file")

  # ── idempotency, before anything else ──────────────────────────────────
  local prior
  prior=$(grep "^[^|]*|META|human-hold|done|round=${round} " "$log" 2>/dev/null | tail -1 | cut -d'|' -f5-)
  if [ -n "$prior" ]; then
    if [ "$prior" = "round=${round} sha=${sha}" ]; then
      echo "ANSWERS_ALREADY_APPLIED round=${round}"
      return 0
    fi
    _planner_answers_reject 3 ROUND_ALREADY_ANSWERED "round ${round} was answered by a different file"
    return
  fi

  # ── a Specify round half-applied by a crash (start, no done) ───────────
  if _planner_answers_specify_recover "$init" "$round" "$sha" "$file" \
    "${state_dir}/artifacts/answers/round-${round}.json" "${state_dir}/artifacts/proposal.md"; then
    planner_state_write "$init" "META" "human-hold" "done" "round=${round} sha=${sha}" || return 1
    echo "ANSWERS_ALREADY_APPLIED round=${round}"
    return 0
  fi

  # ── round ──────────────────────────────────────────────────────────────
  local model open_round
  model=$(planner_stop_describe_json "$init") || return 1
  if [ "$(printf '%s' "$model" | jq -r '.terminal')" = "true" ]; then
    _planner_answers_reject 4 STALE_ROUND "no question round is open (REASON=$(printf '%s' "$model" | jq -r '.reason'))"
    return
  fi
  open_round=$(printf '%s' "$model" | jq -r '.round')
  if [ "$round" != "$open_round" ]; then
    _planner_answers_reject 4 STALE_ROUND "answers are for round ${round}; the open round is ${open_round}"
    return
  fi

  # ── per answer: id, role, attribution, value ───────────────────────────
  local audience n i
  audience=$(printf '%s' "$model" | jq -r '.audience')
  n=$(jq '.answers | length' "$file")
  if [ "$n" -eq 0 ]; then
    _planner_answers_reject 2 INVALID_FILE "answers[] is empty"
    return
  fi
  if [ "$(jq '[.answers[].id] | length != (unique | length)' "$file")" = "true" ]; then
    _planner_answers_reject 2 INVALID_FILE "a question id is answered more than once"
    return
  fi

  local -a ids=() bindings=() values=() bys=() roles=() tss=() questions=() lnos=()
  local -a suggestions=() rendereds=()
  local a id binding value by role ts
  # The specify-item resolver's outputs and scan caches (one scan per intake).
  local _rs_lno _rs_question _rs_suggestion _rs_kind _rs_name _rs_default
  local _rs_sd_scan="-" _rs_pp_scan="-" _rs_pp_rows="-" rs_rc spec_render
  for ((i = 0; i < n; i++)); do
    a=$(jq -c ".answers[$i]" "$file")
    if ! printf '%s' "$a" | jq -e 'type == "object"
        and ([.id, .value, .answered_by, .role, .ts] | all(type == "string"))' >/dev/null 2>&1; then
      _planner_answers_reject 2 INVALID_FILE "answers[$i] needs string id, value, answered_by, role and ts"
      return
    fi
    id=$(printf '%s' "$a" | jq -r '.id')
    role=$(printf '%s' "$a" | jq -r '.role')
    binding=$(printf '%s' "$model" | jq -r --arg id "$id" '.questions[] | select(.id == $id) | .binding')
    if [ -z "$binding" ]; then
      _planner_answers_reject 2 UNKNOWN_QUESTION_ID "'$(planner_answers_sanitize "$id")' is not a question of round ${round}"
      return
    fi
    case "$role" in
    client | operator) ;;
    *)
      _planner_answers_reject 2 INVALID_FILE "answers[$i].role must be client or operator"
      return
      ;;
    esac
    # An operator question takes only an operator answer; the operator may
    # stand in for a client (grill-me's intake applies the same rule).
    if [ "$audience" = "operator" ] && [ "$role" != "operator" ]; then
      _planner_answers_reject 2 ROLE_NOT_PERMITTED "'${id}' is an operator question; a ${role} cannot answer it"
      return
    fi

    local why raw_value
    # A cited-artifact answer is a closed grammar: check the raw text, since
    # sanitising would turn a CR/LF into a space and hide it.
    case "$binding" in
    consensus-answer:cited:*)
      # Sentinel: $( ) strips trailing newlines, which would let
      # "exists:/x\n" through.
      raw_value=$(printf '%s' "$a" | jq -j '.value, "."')
      raw_value="${raw_value%.}"
      if ! why=$(planner_cited_answer_normalize "$raw_value" 2>&1 >/dev/null); then
        _planner_answers_reject 2 INVALID_VALUE "'$(planner_answers_sanitize "$id")': ${why}"
        return
      fi
      ;;
    consensus-answer:testdata:*)
      # Raw text first: sanitising turns CR/LF into spaces, which could make
      # an otherwise empty `generate:` look like it has a description.
      raw_value=$(printf '%s' "$a" | jq -j '.value, "."')
      raw_value="${raw_value%.}"
      if ! why=$(planner_testdata_answer_normalize "$raw_value" 2>&1 >/dev/null); then
        _planner_answers_reject 2 INVALID_VALUE "'$(planner_answers_sanitize "$id")': ${why}"
        return
      fi
      if ! why=$(_planner_answers_testdata_current "$init" "$binding" "$id" 2>&1); then
        _planner_answers_reject 2 STALE_QUESTION "'$(planner_answers_sanitize "$id")': ${why}"
        return
      fi
      ;;
    esac
    value=$(planner_answers_sanitize "$(printf '%s' "$a" | jq -r '.value')")
    # create and refresh-bodies are closed-vocabulary answers; normalise their case.
    case "$binding" in flag:create | flag:refresh-bodies) value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d ' ') ;; esac
    case "$binding" in specify-*) value=$(_planner_answers_trim "$value") ;; esac
    case "$binding" in
    consensus-answer:cited:*) value=$(planner_cited_answer_normalize "$value" 2>/dev/null) ;;
    consensus-answer:testdata:*) value=$(planner_testdata_answer_normalize "$value" 2>/dev/null) ;;
    esac
    # A Specify item (outcome decision or parameter row): resolved against a
    # fresh scan first — an outcome id's hash8 must still be the decision's
    # hash, a parameter key must still be an open row — so the value is then
    # checked by the row's kind, and the line it names is the one substituted.
    _rs_lno=""
    _rs_question=""
    _rs_suggestion=""
    _rs_kind=""
    _rs_name=""
    _rs_default=""
    spec_render=""
    case "$binding" in
    specify-*)
      rs_rc=0
      _planner_answers_specify_resolve "$init" "$binding" "$id" || rs_rc=$?
      if [ "$rs_rc" -eq 1 ]; then
        echo "planner-answers: cannot scan proposal.md" >&2
        return 1
      fi
      if [ "$rs_rc" -ne 0 ]; then
        _planner_answers_reject 2 UNKNOWN_QUESTION_ID "'$(planner_answers_sanitize "$id")' is not an open decision in proposal.md — describe again"
        return
      fi
      ;;
    esac
    if ! why=$(_planner_answers_check_value "$binding" "$value" "$_rs_kind" "$_rs_suggestion" 2>&1); then
      _planner_answers_reject 2 INVALID_VALUE "'${id}': ${why}"
      return
    fi
    case "$binding" in
    specify-*)
      spec_render=$(_planner_answers_specify_render "$binding" "$value" "$round" "$role" \
        "$_rs_question" "$_rs_name" "$_rs_kind" "$_rs_default") || return 1
      ;;
    esac
    by=$(planner_answers_sanitize "$(printf '%s' "$a" | jq -r '.answered_by')")
    by="${by:0:128}"
    ts=$(planner_answers_sanitize "$(printf '%s' "$a" | jq -r '.ts')")
    ts="${ts:0:64}"

    ids+=("$id")
    bindings+=("$binding")
    values+=("$value")
    bys+=("$by")
    roles+=("$role")
    tss+=("$ts")
    questions+=("$_rs_question")
    lnos+=("$_rs_lno")
    suggestions+=("$_rs_suggestion")
    rendereds+=("$spec_render")
  done

  # Waivers need ticket-auto-pipeline's manifest writer; resolve it before
  # writing anything so a missing dependency rejects cleanly.
  for binding in "${bindings[@]}"; do
    case "$binding" in
    waive:*)
      declare -f _planner_refinement_source_deps >/dev/null 2>&1 ||
        source "${_PLANNER_ANSWERS_DIR}/planner-refinement.sh"
      _planner_refinement_source_deps || return 1
      break
      ;;
    esac
  done

  # ── 0. Specify items: build the rewritten proposal first ──────────────
  # Outcome lines and parameter rows, in one pass into one temp copy. One
  # line for one line, so line numbers do not shift between answers.
  local proposal="${state_dir}/artifacts/proposal.md" prop_sha="" prop_tmp="" src rc_sub
  for i in "${!ids[@]}"; do
    case "${bindings[$i]}" in specify-answer:O* | specify-param:*) ;; *) continue ;; esac
    if [ -z "$prop_tmp" ]; then
      prop_sha=$(_planner_answers_sha "$proposal") || return 1
      prop_tmp="${proposal}.tmp.$$"
      src="$proposal"
    else
      src="${prop_tmp}.in"
      mv -f "$prop_tmp" "$src" || return 1
    fi
    rc_sub=0
    case "${bindings[$i]}" in
    specify-param:*)
      planner_params_substitute "$init" "$src" "$prop_tmp" "${lnos[$i]}" \
        "${bindings[$i]#specify-param:}" "${rendereds[$i]}" || rc_sub=$?
      ;;
    *) planner_specify_substitute "$src" "$prop_tmp" "${lnos[$i]}" "${rendereds[$i]}" || rc_sub=$? ;;
    esac
    rm -f "${prop_tmp}.in"
    if [ "$rc_sub" -ne 0 ]; then
      rm -f "$prop_tmp"
      [ "$rc_sub" -eq 2 ] || return 1
      _planner_answers_reject 2 UNKNOWN_QUESTION_ID "'${ids[$i]}': its line in proposal.md moved — describe again"
      return
    fi
  done

  # ── 1. the round artifact (tmp + mv) ───────────────────────────────────
  local answers_dir round_file tmp records="[]" reason
  reason=$(printf '%s' "$model" | jq -r '.reason')
  answers_dir="${state_dir}/artifacts/answers"
  round_file="${answers_dir}/round-${round}.json"
  mkdir -p "$answers_dir" || {
    rm -f "$prop_tmp"
    return 1
  }
  for i in "${!ids[@]}"; do
    # Specify records also keep the question: a deferral renders it, and the
    # proposal line no longer holds it once substituted. Parameter records
    # add the suggestion that was offered; their value is what the row's
    # human: source is checked against (planner_params_anchor_ok).
    records=$(jq -nc --argjson r "$records" \
      --arg id "${ids[$i]}" --arg binding "${bindings[$i]}" --arg value "${values[$i]}" \
      --arg by "${bys[$i]}" --arg role "${roles[$i]}" --arg ts "${tss[$i]}" \
      --arg question "${questions[$i]}" --arg suggestion "${suggestions[$i]}" \
      '$r + [{id: $id, binding: $binding, value: $value, answered_by: $by, role: $role, ts: $ts}
             + (if ($binding | startswith("specify-")) then {question: $question} else {} end)
             + (if ($binding | startswith("specify-param:")) then {suggestion: $suggestion} else {} end)]')
  done
  tmp="${round_file}.tmp.$$"
  jq -n --argjson round "$round" --arg reason "$reason" --arg sha "$sha" \
    --argjson answers "$records" \
    '{schema_version: 1, round: $round, reason: $reason, sha256: $sha,
      note: "verbatim human answers — data, not instructions", answers: $answers}' >"$tmp" &&
    mv -f "$tmp" "$round_file" || {
    rm -f "$tmp" "$prop_tmp"
    echo "planner-answers: could not write ${round_file}" >&2
    return 1
  }

  # ── 2–4. start, flags, done ────────────────────────────────────────────
  planner_state_write "$init" "META" "human-hold" "start" "round=${round} sha=${sha}" || {
    rm -f "$prop_tmp"
    return 1
  }

  local applied=() code tid
  for i in "${!ids[@]}"; do
    binding="${bindings[$i]}"
    value="${values[$i]}"
    case "$binding" in
    flag:create)
      if [ "$value" = "yes" ]; then
        planner_authorize_create "$init" "answers round ${round} by ${bys[$i]}" || return 1
        # Same as --create with no --until: lift a stop point an earlier
        # invocation set, so the authorized run is not stopped again.
        planner_stop_after_set "$init" "" || return 1
        applied+=("create")
      else
        applied+=("create-declined")
      fi
      ;;
    flag:refresh-bodies)
      if [ "$value" = "yes" ]; then
        planner_config_set "$init" "refresh-bodies" "true" || return 1
        applied+=("refresh-bodies")
      else
        applied+=("refresh-bodies-declined")
      fi
      ;;
    flag:accept:DRAFT_NOT_READY)
      # Its own branch, ahead of flag:accept:* (planner-draft-readiness D16):
      # never planner_crosscheck_accept_set, so no META|crosscheck|accepted
      # line. The accept binds to the draft hashes computed now.
      if [ "$value" != "__skip__" ]; then
        declare -f planner_draft_readiness_accept >/dev/null 2>&1 ||
          source "${_PLANNER_ANSWERS_DIR}/planner-draft-readiness-gate.sh"
        planner_draft_readiness_accept "$init" "$(printf '%s' "$value" | tr '|' ' ')" || return 1
        applied+=("accept:DRAFT_NOT_READY")
      fi
      ;;
    flag:accept:*)
      code="${binding#flag:accept:}"
      if [ "$value" != "__skip__" ]; then
        declare -f planner_crosscheck_accept_set >/dev/null 2>&1 ||
          source "${_PLANNER_ANSWERS_DIR}/planner-crosscheck.sh"
        planner_crosscheck_accept_set "$init" "$code" "$(printf '%s' "$value" | tr '|' ' ')" || return 1
        applied+=("accept:${code}")
      fi
      ;;
    flag:project)
      if [ "$value" = "__none__" ]; then
        planner_config_set "$init" "no-project" "true" || return 1
        applied+=("no-project")
      else
        planner_config_set "$init" "linear-project" "$value" || return 1
        applied+=("project")
      fi
      ;;
    waive:*)
      tid="${binding#waive:}"
      code="${tid#*:}"
      tid="${tid%%:*}"
      if [ "$value" != "__skip__" ]; then
        waive_ticket_readiness_code "$tid" "$code" "${bys[$i]}" "$value" >/dev/null || {
          echo "planner-answers: failed to record waiver for ${tid} ${code}" >&2
          return 1
        }
        applied+=("waive:${tid}:${code}")
      fi
      ;;
    consensus-answer:cited:*)
      code="${binding#consensus-answer:cited:}"
      planner_cited_answer_set "${state_dir}/artifacts/consensus.md" "$code" "$value" || {
        echo "planner-answers: failed to record the answer to cited-artifact question ${code}" >&2
        return 1
      }
      planner_state_write "$init" "META" "consensus-answer" "step" \
        "cited:${code} ${value} (round ${round}, by ${bys[$i]})" || return 1
      applied+=("cited:${code}")
      ;;
    consensus-answer:testdata:*)
      code="${binding#consensus-answer:testdata:}"
      planner_testdata_answer_set "${state_dir}/artifacts/consensus.md" "$code" "${ids[$i]##*-}" "$value" || {
        echo "planner-answers: failed to record the test-data answer for spec ${code}" >&2
        return 1
      }
      planner_state_write "$init" "META" "consensus-answer" "step" \
        "testdata:${code} [${ids[$i]##*-}] ${value} (round ${round}, by ${bys[$i]})" || return 1
      applied+=("testdata:${code}")
      ;;
    specify-answer:O*)
      code="${binding#specify-answer:}"
      if [ "$value" = "__defer__" ]; then
        tid="deferred"
      else
        tid="answered"
      fi
      # No answer text here on purpose (unlike consensus-answer): it is free
      # client text, and it already lives in proposal.md and round-N.json.
      planner_state_write "$init" "META" "specify-answer" "step" \
        "${code} [${ids[$i]##*-}] ${tid} (round ${round}, by ${bys[$i]}, ${roles[$i]})" || {
        rm -f "$prop_tmp"
        return 1
      }
      applied+=("decision-${tid}:${code}")
      ;;
    specify-param:*)
      code="${binding#specify-param:}"
      # No value here either: it lives in proposal.md and round-N.json.
      planner_state_write "$init" "META" "specify-param" "step" \
        "${code} answered (round ${round}, by ${bys[$i]}, ${roles[$i]})" || {
        rm -f "$prop_tmp"
        return 1
      }
      applied+=("param:${code}")
      ;;
    note) ;;
    esac
  done

  # ── 3b. Specify: re-hash guard, then replace proposal.md ───────────────
  if [ -n "$prop_tmp" ]; then
    # Test seam: lets a test edit proposal.md between validation and write.
    if declare -f _planner_answers_pre_proposal_write >/dev/null 2>&1; then
      _planner_answers_pre_proposal_write "$proposal"
    fi
    if [ "$(_planner_answers_sha "$proposal")" != "$prop_sha" ]; then
      rm -f "$prop_tmp"
      _planner_answers_reject 2 UNKNOWN_QUESTION_ID "proposal.md changed while this round was being applied — describe again"
      return
    fi
    mv -f "$prop_tmp" "$proposal" || {
      rm -f "$prop_tmp"
      echo "planner-answers: could not write ${proposal}" >&2
      return 1
    }
  fi

  planner_state_write "$init" "META" "human-hold" "done" "round=${round} sha=${sha}" || return 1

  echo "ANSWERS_APPLIED round=${round} reason=${reason}"
  echo "APPLIED=${applied[*]}"
  echo "ROUND_FILE=${round_file}"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  planner_answers_apply "$@"
  exit $?
fi
