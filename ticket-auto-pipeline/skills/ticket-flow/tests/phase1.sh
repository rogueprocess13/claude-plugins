#!/usr/bin/env bash
# phase1.sh — unit tests for harden-ticket-auto-pipeline changes.
# Requires: bash, jq, socat, flock.
# Usage: bash phase1.sh [test_name]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FLOW_SH="$SCRIPT_DIR/../flow.sh"
DETECT_RESUME_SH="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
VALIDATE_SH="$SCRIPT_DIR/../validate-linear-config.sh"
TICKET_DIR_SH="$PLUGIN_DIR/lib/ticket-dir.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  local _stderr
  _stderr=$(mktemp)
  local _exit=0
  if "$@" 2>"$_stderr"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    _exit=$?
    echo "FAIL: $name (exit $_exit)"
    if [ -s "$_stderr" ]; then
      echo "  stderr:"
      sed 's/^/    /' "$_stderr"
    fi
    ((FAIL++)) || true
  fi
  rm -f "$_stderr"
}

# ── helpers ──────────────────────────────────────────────────────────────────

_socat_stub() {
  # Start a socat HTTP stub on $1 that returns $2 (status code) for the first
  # $3 requests, then $4 for subsequent ones.
  # Returns the socat PID.
  # NOTE: socat must be detached from the subshell's job control (</dev/null,
  # >/dev/null, &) because command substitution $(...) waits for all children.
  local port="$1"
  local fail_code="$2"
  local fail_count="$3"
  local ok_body="$4"
  local count_file
  count_file=$(mktemp)
  echo 0 >"$count_file"

  socat TCP-LISTEN:"$port",reuseaddr,fork SYSTEM:"bash -c '
    n=\$(cat \"$count_file\"); n=\$((n+1)); echo \$n > \"$count_file\"
    if [ \$n -le $fail_count ]; then
      printf \"HTTP/1.1 $fail_code Service Unavailable\r\nContent-Length: 0\r\n\r\n\"
    else
      body=\$(echo $ok_body | base64 -d)
      len=\${#body}
      printf \"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \$len\r\n\r\n\$body\"
    fi
  '" </dev/null >/dev/null 2>&1 &
  echo $!
}

# ── test_validate_linear_config_dry_run ──────────────────────────────────────

test_validate_linear_config_dry_run() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local sentinel_dir="$tmpdir/state/ticket-flow"
  local sm="$SCRIPT_DIR/../workflow.json"
  [ -f "$sm" ] || {
    echo "workflow.json missing" >&2
    return 1
  }

  SENTINEL_DIR="$sentinel_dir" bash "$VALIDATE_SH" --dry-run --team TEST_TEAM_ID 2>/dev/null || true
  # sentinel should exist after first run
  ls "$sentinel_dir"/validated-* 2>/dev/null | grep -q validated

  # second run should skip (sentinel-valid in log / no re-validation output)
  local out
  out=$(SENTINEL_DIR="$sentinel_dir" bash "$VALIDATE_SH" --dry-run --team TEST_TEAM_ID 2>&1 || true)
  echo "$out" | grep -q "sentinel-valid"

  rm -rf "$tmpdir"
}

# ── test_preflight_aborts_on_unset_key ───────────────────────────────────────

test_preflight_aborts_on_unset_key() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="$tmpdir/test.log"

  unset LINEAR_API_KEY
  bash "$VALIDATE_SH" 2>/dev/null && return 1 # should fail when key missing
  [ ! -f "$log" ]                             # no log file should be created
  rm -rf "$tmpdir"
}

# ── test_flow_concurrent_lock ─────────────────────────────────────────────────

test_flow_concurrent_lock() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"

  # Hold the lock in a background process
  (
    exec 9>"$tmpdir/logs/.ticket-flow-WIL-99.lock"
    if ! flock 9 2>/dev/null; then
      echo "flock failed (flock not installed?)" >&2
      exit 1
    fi
    sleep 5
  ) &
  local holder=$!
  sleep 0.2 # let the holder acquire the lock

  # Second invocation should exit 42. Point flow.sh at the same lock
  # directory the test holder is using so the mutex conflict is detected.
  local exit_code=0
  TICKET_FLOW_LOCK_DIR="$tmpdir/logs" \
    CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" \
    bash -c "cd \"$tmpdir\" && \"$FLOW_SH\" WIL-99 appraise-start" >/dev/null 2>&1 || exit_code=$?

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 42 ]
}

# ── test_flow_dispatcher_unknown_trigger ─────────────────────────────────────

test_flow_dispatcher_unknown_trigger() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local exit_code=0
  CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" \
    bash -c "cd \"$tmpdir\" && \"$FLOW_SH\" WIL-99 not-a-real-trigger" >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 3 ]
}

# ── test_linear_api_retry_on_503 ─────────────────────────────────────────────

test_linear_api_retry_on_503() {
  if ! command -v socat &>/dev/null; then
    echo "SKIP: socat not available" >&2
    return 0
  fi

  # Use a random high port to avoid conflicts with parallel CI jobs
  local port=$((20000 + RANDOM % 10000))
  local ok_body
  ok_body=$(echo '{"data":{"viewer":{"id":"u1","name":"Test"}}}' | base64 -w0)

  local socat_pid
  socat_pid=$(_socat_stub "$port" 503 2 "$ok_body")
  sleep 0.3

  # Verify socat actually started before proceeding
  if ! kill -0 "$socat_pid" 2>/dev/null; then
    echo "SKIP: socat failed to start" >&2
    return 0
  fi

  local exit_code=0
  LINEAR_API_URL="http://127.0.0.1:$port" LINEAR_API_KEY="test" \
    timeout 15 bash -c "source $PLUGIN_DIR/lib/linear-api.sh; linear_graphql '{\"query\":\"query{viewer{id name}}\"} '" \
    >/dev/null 2>&1 || exit_code=$?

  kill "$socat_pid" 2>/dev/null || true
  wait "$socat_pid" 2>/dev/null || true
  [ "$exit_code" -eq 0 ]
}

# ── test_detect_resume_schema_mismatch ───────────────────────────────────────

test_detect_resume_schema_mismatch() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  # Write a non-empty log with NO schema header and content that fails v0-grace regex
  echo "corrupt log content without pipe format" >>"$log"

  local out
  out=$(cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  rm -rf "$tmpdir"
  echo "$out" | grep -q "SCHEMA_MISMATCH"
}

# ── test_detect_resume_maintenance_document_done ────────────────────────────

test_detect_resume_maintenance_document_done() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md (3 patterns, 2 decisions, non-trivial)" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ]
}

# ── test_detect_resume_maintenance_document_waiting ─────────────────────────

test_detect_resume_maintenance_document_waiting() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|waiting|Agent launched — generating ai-context.md" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ]
}

# ── test_detect_resume_maintenance_document_fail ────────────────────────────

test_detect_resume_maintenance_document_fail() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|fail|Agent failed — continuing" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ]
}

# ── test_detect_resume_maintenance_maintenance_done ─────────────────────────

test_detect_resume_maintenance_maintenance_done() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|maintenance|done|2 errata incorporated, 1 ai-context findings promoted to wiki" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_6" ]
}

# ── test_detect_resume_maintenance_maintenance_waiting ──────────────────────

test_detect_resume_maintenance_maintenance_waiting() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|maintenance|waiting|Agent launched — wiki maintenance" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ]
}

# ── test_detect_resume_maintenance_maintenance_fail ─────────────────────────

test_detect_resume_maintenance_maintenance_fail() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|maintenance|fail|Agent failed — continuing" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_6" ]
}

# ── test_detect_resume_maintenance_fallback_document ────────────────────────

test_detect_resume_maintenance_fallback_document() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|start|Generating ai-context.md" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  local doc_from
  doc_from=$(echo "$out" | grep 'DOCUMENT_FROM:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ] && [ -z "$doc_from" ]
}

# ── test_ticket_dir_disambiguation ───────────────────────────────────────────

test_ticket_dir_disambiguation() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/WIL-4--foo"
  mkdir -p "$tmpdir/WIL-42--bar"

  source "$TICKET_DIR_SH"

  # WIL-4 should resolve to WIL-4--foo only
  local result
  result=$(resolve_ticket_dir WIL-4 "$tmpdir")
  [[ "$result" == *"WIL-4--foo"* ]] || {
    rm -rf "$tmpdir"
    return 1
  }

  # WIL-42 should resolve to WIL-42--bar
  result=$(resolve_ticket_dir WIL-42 "$tmpdir")
  [[ "$result" == *"WIL-42--bar"* ]] || {
    rm -rf "$tmpdir"
    return 1
  }

  # Adding a second WIL-4 dir should cause multi-match error (exit 2)
  mkdir -p "$tmpdir/WIL-4--baz"
  local exit_code=0
  resolve_ticket_dir WIL-4 "$tmpdir" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 2 ]
}

# ── test_gen_mermaid_roundtrip ────────────────────────────────────────────────

test_gen_mermaid_roundtrip() {
  # Use PLUGIN_DIR (set at script startup, never overwritten) rather than
  # SCRIPT_DIR which ticket-dir.sh clobbers when sourced by earlier tests.
  local gen="$PLUGIN_DIR/skills/ticket-flow/gen-mermaid.sh"
  local sm="$PLUGIN_DIR/skills/ticket-flow/workflow.json"
  [ -f "$gen" ] || {
    echo "gen-mermaid.sh missing" >&2
    return 1
  }
  [ -f "$sm" ] || {
    echo "workflow.json missing" >&2
    return 1
  }
  local readme="$PLUGIN_DIR/README.md"
  [ -f "$readme" ] || {
    echo "README.md not found" >&2
    return 1
  }

  local generated
  generated=$(bash "$gen")
  local committed
  committed=$(sed -n '/^```mermaid$/,/^```$/p' "$readme" | grep -v '^```')
  [ "$generated" = "$committed" ]
}

# ── test_detect_resume_verify_attempts_excludes_pass ───────────────────────

test_detect_resume_verify_attempts_excludes_pass() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth" >>"$log"
  # One PASS — should NOT count toward VERIFY_ATTEMPTS
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|done|PASS" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local verify_attempts
  verify_attempts=$(echo "$out" | grep 'VERIFY_ATTEMPTS:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "${verify_attempts:-1}" -eq 0 ]
}

# ── test_detect_resume_verify_attempts_counts_fails ───────────────────────

test_detect_resume_verify_attempts_counts_fails() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth" >>"$log"
  # One FAIL — SHOULD count toward VERIFY_ATTEMPTS
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|fail|timeout" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local verify_attempts
  verify_attempts=$(echo "$out" | grep 'VERIFY_ATTEMPTS:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "${verify_attempts:-0}" -eq 1 ]
}

# ── test_detect_resume_no_step3 ───────────────────────────────────────────

test_detect_resume_no_step3() {
  # STEP_3 must never appear in detect-resume.sh output — it was deleted
  # from the dispatch table and is unreachable.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  # A log with EXEC done but no GATE — historically this could produce STEP_3
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  rm -rf "$tmpdir"
  # RESUME_STEP must not be STEP_3 (without _5 suffix)
  echo "$out" | grep -q 'RESUME_STEP:.*STEP_3$' && return 1
  return 0
}

# ── test_detect_resume_pr_number_from_checkout_only ───────────────────────

test_detect_resume_pr_number_from_checkout_only() {
  # PR number must be resolved from checkout-pr|done| line — the old
  # emoji-based fallback regex has been removed. This test verifies the
  # primary extraction still works.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|done|PASS" >>"$log"
  # checkout-pr|done|42 — the canonical PR number source
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|checkout-pr|done|42" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-review|done|PASS" >>"$log"

  # Verify detect-resume.sh runs without error and resolves to STEP_5 (past PR-REVIEW)
  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  # Should reach STEP_5 (past PR-REVIEW with PR done) since MAINTENANCE hasn't run yet.
  # Without the dead fallback, this must still work via checkout-pr extraction.
  [ "$resume_step" = "STEP_5" ]
}

# ── test_spawn_agent_post_loop_bearing_requires_verdict ───────────────────

test_spawn_agent_post_loop_bearing_requires_verdict() {
  # Source spawn-helper to get spawn_agent_post
  source "$PLUGIN_DIR/lib/spawn-helper.sh" 2>/dev/null || true

  # LOOP_BEARING=true without VERDICT or cycle# → must fail
  if spawn_agent_post TICKET_ID=TEST-1 RESULT=done MSG="done" LOOP_BEARING=true 2>/dev/null; then
    echo "FAIL: LOOP_BEARING=true with no VERDICT or cycle# should have failed"
    return 1
  fi

  # LOOP_BEARING=true with VERDICT → must succeed (log-writing may fail, that's OK)
  local rc=0
  spawn_agent_post TICKET_ID=TEST-1 RESULT=done VERDICT=PASS MSG="ok" LOOP_BEARING=true 2>/dev/null || rc=$?
  # rc may be non-zero from missing log files — that's fine, just not the VERDICT error
  [ "$rc" -ne 1 ] || {
    echo "FAIL: LOOP_BEARING=true with VERDICT should not fail on missing token"
    return 1
  }

  # LOOP_BEARING=true with cycle# in MSG → must not fail on verdict requirement
  rc=0
  spawn_agent_post TICKET_ID=TEST-1 RESULT=done MSG="cycle#3 reconciled" LOOP_BEARING=true 2>/dev/null || rc=$?
  [ "$rc" -ne 1 ] || {
    echo "FAIL: LOOP_BEARING=true with cycle# in MSG should satisfy the requirement"
    return 1
  }

  # LOOP_BEARING=false (default) without VERDICT → must succeed
  rc=0
  spawn_agent_post TICKET_ID=TEST-1 RESULT=done MSG="done" 2>/dev/null || rc=$?
  [ "$rc" -ne 1 ] || {
    echo "FAIL: non-loop phase without VERDICT should succeed"
    return 1
  }
}

# ── test_outcome_label_exact_match ─────────────────────────────────────────

test_outcome_label_exact_match() {
  # Verify that "Hard" does NOT match "Hard-blocked" via the jq exact-match
  # check (the old grep -qw falsely matched on hyphen boundaries).
  # NOTE: source of outcome-label-check.sh would overwrite SCRIPT_DIR,
  # so we inline the jq check directly.

  # "Hard" must NOT match when only "Hard-blocked" is present
  local issue_json='{"labels":{"nodes":[{"name":"Hard-blocked"},{"name":"bug"}]}}'
  if echo "$issue_json" | jq -e --arg ol "Hard" \
    '[.labels.nodes[]?.name? // empty] | index($ol) != null' >/dev/null 2>&1; then
    echo "FAIL: Hard falsely matched Hard-blocked"
    return 1
  fi

  # But "Hard" SHOULD match when actually present
  issue_json='{"labels":{"nodes":[{"name":"Hard"},{"name":"bug"}]}}'
  if ! echo "$issue_json" | jq -e --arg ol "Hard" \
    '[.labels.nodes[]?.name? // empty] | index($ol) != null' >/dev/null 2>&1; then
    echo "FAIL: Hard should match when actually present"
    return 1
  fi
}

# ── test_retry_classify_429_transient ─────────────────────────────────────

test_retry_classify_429_transient() {
  # Source linear-api.sh to get _retry_classify
  source "$PLUGIN_DIR/lib/linear-api.sh" 2>/dev/null || true
  # HTTP 429 must be classified as transient
  local result
  result=$(_retry_classify 0 429 "{}")
  [ "$result" = "transient" ] || {
    echo "expected transient for HTTP 429, got $result"
    return 1
  }
}

# ── test_retry_classify_rate_limit_regex ──────────────────────────────────

test_retry_classify_rate_limit_regex() {
  source "$PLUGIN_DIR/lib/linear-api.sh" 2>/dev/null || true
  # "rateXlimit" (with any char where dot was unescaped) must NOT match
  local result
  result=$(_retry_classify 0 200 '{"message":"rateXlimit exceeded"}')
  [ "$result" = "permanent" ] || {
    echo "expected permanent for rateXlimit (escaped dot), got $result"
    return 1
  }
  # "rate.limit" (with literal dot) must match
  result=$(_retry_classify 0 200 '{"message":"rate.limit exceeded"}')
  [ "$result" = "transient" ] || {
    echo "expected transient for rate.limit, got $result"
    return 1
  }
  # "429" in body must match
  result=$(_retry_classify 0 200 '{"errors":[{"message":"429 rate limit"}]}')
  [ "$result" = "transient" ] || {
    echo "expected transient for 429 in body, got $result"
    return 1
  }
}

# ── test_flow_from_precondition_logic ──────────────────────────────────────

test_flow_from_precondition_logic() {
  # Verify the from-precondition check: extract "from" field, compare against
  # current state. This test exercises the jq extraction and comparison logic
  # without needing a Linear API mock.
  local tmpdir
  tmpdir=$(mktemp -d)

  # Test 1: "from" present and matches → no warning
  local def='{"from":"Todo","to":"In Progress"}'
  local expected_from current_state
  expected_from=$(echo "$def" | jq -r '.from // empty')
  current_state="Todo"
  local should_warn="false"
  if [ -n "$expected_from" ] && [ "$expected_from" != "null" ]; then
    if [ "$current_state" != "$expected_from" ]; then
      should_warn="true"
    fi
  fi
  [ "$should_warn" = "false" ] || {
    rm -rf "$tmpdir"
    echo "legal transition incorrectly flagged"
    return 1
  }

  # Test 2: "from" present and mismatches → warn
  current_state="Backlog"
  should_warn="false"
  if [ -n "$expected_from" ] && [ "$expected_from" != "null" ]; then
    if [ "$current_state" != "$expected_from" ]; then
      should_warn="true"
    fi
  fi
  [ "$should_warn" = "true" ] || {
    rm -rf "$tmpdir"
    echo "illegal transition not flagged"
    return 1
  }

  # Test 3: "from" absent → skip check (no warn)
  def='{"to":"Done"}'
  expected_from=$(echo "$def" | jq -r '.from // empty')
  current_state="Backlog"
  should_warn="false"
  if [ -n "$expected_from" ] && [ "$expected_from" != "null" ]; then
    if [ "$current_state" != "$expected_from" ]; then
      should_warn="true"
    fi
  fi
  [ "$should_warn" = "false" ] || {
    rm -rf "$tmpdir"
    echo "absent from incorrectly flagged"
    return 1
  }

  # Test 4: "from": null → skip check (no warn)
  def='{"from":null,"to":"Done"}'
  expected_from=$(echo "$def" | jq -r '.from // empty')
  current_state="Backlog"
  should_warn="false"
  if [ -n "$expected_from" ] && [ "$expected_from" != "null" ]; then
    if [ "$current_state" != "$expected_from" ]; then
      should_warn="true"
    fi
  fi
  [ "$should_warn" = "false" ] || {
    rm -rf "$tmpdir"
    echo "null from incorrectly flagged"
    return 1
  }

  rm -rf "$tmpdir"
}

# ── flow.sh test helpers (tracker-flow-projection-cutover) ─────────────────
# flow.sh performs no tracker I/O, so these tests need no linear-api.sh
# stub at all — CLAUDE_SKILLS_LIB points straight at the real lib dir, and
# fixtures are plain manifest.json files under a scratch REPOS_ROOT.
# FLEET_BOARD_DRIVERS=none disables flow.sh's own exit-time outbox drain
# (task 6.1) for these tests — it would otherwise dispatch to the real
# linear driver, which needs live Linear credentials this suite must never
# depend on.

_flow_seed_manifest() {
  # _flow_seed_manifest <repos_root> <tid> [init]
  # stage defaults to "Todo" — every real ticket already has SOME stage by
  # the time a mid-pipeline trigger (implement-outcome, needs-info, ...)
  # fires, since appraise-start's "to":"Todo" is always the first-ever
  # transition. Tests that care about a different starting stage overwrite
  # it via _flow_set_manifest_field afterward.
  local repos_root="$1" tid="$2" init="${3:-INIT-1}"
  mkdir -p "$repos_root/.ticket-auto/initiatives/_index" \
    "$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner"
  echo "$init" >"$repos_root/.ticket-auto/initiatives/_index/${tid}.initiative"
  echo '{"type":"bug","initiative":"'"$init"'","blocked_by":[],"dispatch":false,"stage":"Todo"}' \
    >"$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner/manifest.json"
}

_flow_manifest_path() {
  local repos_root="$1" tid="$2" init="${3:-INIT-1}"
  echo "$repos_root/.ticket-auto/initiatives/$init/tickets/$tid/planner/manifest.json"
}

_flow_set_manifest_field() {
  # _flow_set_manifest_field <manifest_path> <jq_filter>
  local manifest="$1" filter="$2"
  jq "$filter" "$manifest" >"$manifest.tmp" && mv "$manifest.tmp" "$manifest"
}

_flow_run() {
  # _flow_run <tmpdir> <tid> <trigger> [extra flow.sh args...]
  local tmpdir="$1" tid="$2" trigger="$3"
  shift 3
  FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none \
    CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" LOG_FILE="$tmpdir/logs/${tid}-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" \
    FLEET_PIPELINE_LOG_DIR="$tmpdir/logs" \
    "$FLOW_SH" "$tid" "$trigger" "$@"
}

# ── test_flow_implement_outcome_logs_line ────────────────────────────────────
# flow.sh's implement-outcome trigger must write the dedicated
# IMPLEMENT|implement-outcome|info| line itself, so outcome-label-check.sh's
# guard can never drift from the actual mutation (issue #165) — the label
# it once guarded no longer exists (D10), but the log line is still the
# contract outcome-label-check.sh reads.

test_flow_implement_outcome_logs_line() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99

  _flow_run "$tmpdir" WIL-99 implement-outcome --data outcome=Hard >/dev/null 2>&1
  local rc=$?

  local log="$tmpdir/logs/WIL-99-pipeline.log"
  local found=1
  grep -q '^[^|]*|IMPLEMENT|implement-outcome|info|Hard$' "$log" 2>/dev/null && found=0
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$found" -eq 0 ]
}

# D3: implement-outcome always has to=null and no label delta (after the
# {outcome} placeholder strip) — a structurally nil-effect trigger every
# single time, not merely "idempotent this once". It must still emit (and
# log) on every invocation; the old idempotent-skip early-exit silently
# dropping this event is exactly the defect D3 documents.
test_flow_implement_outcome_logs_line_on_repeat() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99

  _flow_run "$tmpdir" WIL-99 implement-outcome --data outcome=Hard >/dev/null 2>&1
  _flow_run "$tmpdir" WIL-99 implement-outcome --data outcome=Hard >/dev/null 2>&1

  local log="$tmpdir/logs/WIL-99-pipeline.log"
  local count outbox_count
  count=$(grep -c '^[^|]*|IMPLEMENT|implement-outcome|info|Hard$' "$log" 2>/dev/null || echo 0)
  outbox_count=$(wc -l <"$tmpdir/logs/WIL-99-outbox.jsonl" 2>/dev/null || echo 0)
  rm -rf "$tmpdir"
  [ "$count" -eq 2 ] && [ "$outbox_count" -eq 2 ]
}

# ── crash-window cases (flow-local-transitions spec: "exactly one event
# per invocation, across every crash window") ───────────────────────────────

# A pending_event present on entry (simulating a crash between the
# transition's manifest write and emit_event returning) is emitted before
# any new transition is computed, then cleared.
test_flow_pending_event_on_entry_is_emitted_then_cleared() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" \
    '.rev = 3 | .pending_event = {"event":"appraise-started","data":{"complexity":"simple"}}'

  _flow_run "$tmpdir" WIL-99 appraise-complete >/dev/null 2>&1
  local rc=$?

  local outbox="$tmpdir/logs/WIL-99-outbox.jsonl"
  local pending_emitted=1
  grep -q '"event":"appraise-started"' "$outbox" 2>/dev/null && pending_emitted=0
  local pending_idem
  pending_idem=$(grep '"event":"appraise-started"' "$outbox" 2>/dev/null | jq -r '.idem')
  local pending_cleared
  pending_cleared=$(jq -r '.pending_event // "absent"' "$manifest" 2>/dev/null)
  local new_event_present=1
  grep -q '"event":"appraise-completed"' "$outbox" 2>/dev/null && new_event_present=0

  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$pending_emitted" -eq 0 ] && [ "$pending_idem" = "WIL-99:3" ] &&
    [ "$pending_cleared" = "absent" ] && [ "$new_event_present" -eq 0 ]
}

# A re-emission with a matching idem key (the pending_event was already
# fully emitted before the crash, only the clear step was interrupted)
# appends nothing — the outbox already has that record.
test_flow_pending_event_matching_idem_appends_nothing() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" \
    '.rev = 3 | .pending_event = {"event":"appraise-started","data":{"complexity":"simple"}}'
  local outbox="$tmpdir/logs/WIL-99-outbox.jsonl"
  mkdir -p "$tmpdir/logs"
  echo '{"seq":1,"tid":"WIL-99","ts":"2026-01-01T00:00:00Z","gen":0,"event":"appraise-started","data":{"complexity":"simple"},"from_hint":null,"idem":"WIL-99:3"}' >"$outbox"

  _flow_run "$tmpdir" WIL-99 appraise-complete >/dev/null 2>&1
  local rc=$?

  local pending_started_count
  pending_started_count=$(grep -c '"event":"appraise-started"' "$outbox" 2>/dev/null || echo 0)
  local total_count
  total_count=$(wc -l <"$outbox" 2>/dev/null || echo 0)

  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$pending_started_count" -eq 1 ] && [ "$total_count" -eq 2 ]
}

# Two distinct transitions produce two distinct outbox records with
# consecutive seqs and distinct idem keys.
test_flow_two_distinct_transitions_produce_two_records() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99

  _flow_run "$tmpdir" WIL-99 appraise-start >/dev/null 2>&1
  _flow_run "$tmpdir" WIL-99 appraise-complete >/dev/null 2>&1

  local outbox="$tmpdir/logs/WIL-99-outbox.jsonl"
  local seqs idems
  seqs=$(jq -r '.seq' "$outbox" 2>/dev/null | tr '\n' ',')
  idems=$(jq -r '.idem' "$outbox" 2>/dev/null | sort -u | wc -l)

  rm -rf "$tmpdir"
  [ "$seqs" = "1,2," ] && [ "$idems" -eq 2 ]
}

# ── human-approve/pr-iterate --provenance manifest write (tracker-inbound-
# approval Track B Phase B4; tracker-approval-by-script made this the
# authoritative decision fact, not an informational mirror) ────────────────

test_flow_human_approve_provenance_policy_writes_manifest() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" '.stage = "Approve"'

  _flow_run "$tmpdir" WIL-99 human-approve --provenance policy >/dev/null 2>&1
  local rc=$?

  local approved provenance stage
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  provenance=$(jq -r '.approval_provenance // empty' "$manifest" 2>/dev/null)
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$approved" = "true" ] && [ "$provenance" = "policy" ] && [ "$stage" = "Ready" ]
}

test_flow_human_approve_defaults_to_human_provenance() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" '.stage = "Approve"'

  _flow_run "$tmpdir" WIL-99 human-approve >/dev/null 2>&1
  local rc=$?

  local provenance
  provenance=$(jq -r '.approval_provenance // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$provenance" = "human" ]
}

test_flow_re_claim_clears_manifest_approval() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" '.stage = "Ready" | .approved = true | .approval_provenance = "human"'

  _flow_run "$tmpdir" WIL-99 re-claim >/dev/null 2>&1
  local rc=$?

  local approved provenance
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  provenance=$(jq -r '.approval_provenance // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ -z "$approved" ] && [ -z "$provenance" ]
}

test_flow_re_claim_preserves_stage() {
  # re-claim declares to:null — the manifest's stage is still written as
  # part of the one atomic transition (set_ticket_transition always runs,
  # for the always-fresh-rev/idem reasoning flow.sh documents), but its
  # VALUE must be left unchanged rather than null/cleared.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" '.stage = "Ready" | .approved = true | .approval_provenance = "human"'

  _flow_run "$tmpdir" WIL-99 re-claim >/dev/null 2>&1
  local rc=$?

  local stage
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$stage" = "Ready" ]
}

# ── stage manifest write (tracker-approval-by-script; now folded into the
# same set_ticket_transition write as flags/rev/pending_event) ─────────────

test_flow_implement_complete_writes_stage_and_clears_approval() {
  # implement-complete moving Ready -> Review is what makes uat-fail's
  # Review->Ready-without-reapproval path safe (design.md Risk: "uat-fail
  # returns a ticket to Ready without re-approval") — the approval fact
  # must be cleared in the same call that advances the stage.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" '.stage = "Ready" | .approved = true | .approval_provenance = "human"'

  _flow_run "$tmpdir" WIL-99 implement-complete >/dev/null 2>&1
  local rc=$?

  local stage approved provenance
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  provenance=$(jq -r '.approval_provenance // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$stage" = "Review" ] && [ -z "$approved" ] && [ -z "$provenance" ]
}

# tracker-approval-by-script: the load-bearing invariant itself — a ticket
# that reaches uat-fail must never observe approved:true, because nothing
# re-approves it before it loops back to Ready. Seeds a manifest exactly as
# implement-complete would have already left it (no approved field).
test_uat_fail_never_observes_approved_true() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" '.stage = "UAT" | .flags = ["reviewed"]'

  _flow_run "$tmpdir" WIL-99 uat-fail >/dev/null 2>&1
  local rc=$?

  local approved stage
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ -z "$approved" ] && [ "$stage" = "Ready" ]
}

test_flow_uat_pass_writes_stage() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  _flow_set_manifest_field "$manifest" '.stage = "UAT" | .flags = ["reviewed"]'

  _flow_run "$tmpdir" WIL-99 uat-pass >/dev/null 2>&1
  local rc=$?

  local stage
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$stage" = "Done" ]
}

test_flow_adhoc_ticket_gets_manifest_via_flow() {
  # A ticket with no pre-existing manifest and no initiative index entry —
  # ensure_ticket_manifest, called from flow.sh, must make it addressable
  # before the approval/stage writes so a hand-created ticket isn't
  # silently no-op'd.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/repos"
  # Deliberately no manifest seeded — no index entry, no manifest.

  _flow_run "$tmpdir" WIL-99 human-approve >/dev/null 2>&1
  local rc=$?

  local init
  init=$(cat "$tmpdir/repos/.ticket-auto/initiatives/_index/WIL-99.initiative" 2>/dev/null)
  local manifest="$tmpdir/repos/.ticket-auto/initiatives/_adhoc/tickets/WIL-99/planner/manifest.json"
  local approved stage
  approved=$(jq -r '.approved // empty' "$manifest" 2>/dev/null)
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$init" = "_adhoc" ] && [ "$approved" = "true" ] && [ "$stage" = "Ready" ]
}

# ── needs-info round-trip (human-hold-protocol task 7.4) ───────────────────
# human-hold-protocol reuses `needs-info` unchanged as the human-signal
# flag for a hold — set adds it to the manifest's flags, resolved removes
# it, neither touches stage.

_flow_dry_run() {
  # _flow_dry_run <tid> <trigger> <current_flags_json> [current_stage]
  # Echoes flow.sh's --dry-run JSON.
  local tid="$1" trigger="$2" flags_json="${3:-[]}" stage="${4:-Todo}"
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" "$tid"
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" "$tid")
  jq --arg s "$stage" --argjson f "$flags_json" '.stage = $s | .flags = $f' \
    "$manifest" >"$manifest.tmp" && mv "$manifest.tmp" "$manifest"
  local out
  out=$(_flow_run "$tmpdir" "$tid" "$trigger" --dry-run 2>/dev/null)
  rm -rf "$tmpdir"
  echo "$out"
}

test_needs_info_set_adds_the_flag() {
  local out
  out=$(_flow_dry_run WIL-99 needs-info '[]')
  echo "$out" | jq -e '.computed.flags | index("needs-info") != null' >/dev/null 2>&1
}

test_needs_info_resolved_removes_the_flag() {
  local out
  out=$(_flow_dry_run WIL-99 needs-info-resolved '["needs-info"]')
  ! echo "$out" | jq -e '.computed.flags | index("needs-info") != null' >/dev/null 2>&1
}

test_needs_info_does_not_change_stage() {
  local out current_stage computed_stage
  out=$(_flow_dry_run WIL-99 needs-info '[]' Todo)
  current_stage=$(echo "$out" | jq -r '.current.stage')
  computed_stage=$(echo "$out" | jq -r '.computed.stage')
  [ "$current_stage" = "$computed_stage" ] && [ "$computed_stage" = "Todo" ]
}

# ── needs-adr round-trip (adr-governance-gate task 10.12) ───────────────────
# Same shape as the needs-info round-trip above — a distinct label with its
# own trigger pair.

test_needs_adr_set_adds_the_flag() {
  local out
  out=$(_flow_dry_run WIL-99 needs-adr '[]')
  echo "$out" | jq -e '.computed.flags | index("needs-adr") != null' >/dev/null 2>&1
}

test_needs_adr_resolved_removes_the_flag() {
  local out
  out=$(_flow_dry_run WIL-99 needs-adr-resolved '["needs-adr"]')
  ! echo "$out" | jq -e '.computed.flags | index("needs-adr") != null' >/dev/null 2>&1
}

test_needs_adr_does_not_change_stage() {
  local out current_stage computed_stage
  out=$(_flow_dry_run WIL-99 needs-adr '[]' Todo)
  current_stage=$(echo "$out" | jq -r '.current.stage')
  computed_stage=$(echo "$out" | jq -r '.computed.stage')
  [ "$current_stage" = "$computed_stage" ] && [ "$computed_stage" = "Todo" ]
}

# ── test_state_machine_single_source ───────────────────────────────────────

test_state_machine_single_source() {
  # state-machine.json was renamed to workflow.json
  # (tracker-event-vocabulary-and-emitter, Section 4): no state-machine.json
  # should remain anywhere in the plugin tree, and exactly one workflow.json
  # must exist — the canonical copy at skills/ticket-flow/workflow.json.
  local stale_count
  stale_count=$(find "$PLUGIN_DIR" -name "state-machine.json" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | wc -l)
  [ "$stale_count" -eq 0 ] || {
    echo "expected 0 remaining state-machine.json files, found $stale_count"
    return 1
  }
  local count
  count=$(find "$PLUGIN_DIR" -name "workflow.json" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | wc -l)
  [ "$count" -eq 1 ] || {
    echo "expected exactly 1 workflow.json, found $count"
    return 1
  }
  # Verify the sole copy is at the expected path
  [ -f "$PLUGIN_DIR/skills/ticket-flow/workflow.json" ] || {
    echo "canonical workflow.json missing at skills/ticket-flow/"
    return 1
  }
}

# ── verdict gate (VERDICT_FAIL_NOT_ENFORCED, issue #368) ────────────────────
# A trailing FAIL/BLOCK verifier-result must block a verdict_gate-declared
# trigger (pr-review-pass-done, pr-review-pass-uat, uat-pass) from applying
# its transition, unless a later PASS/WARN for the same (verifier, phase)
# supersedes it or a human passes --override. Absence of any verifier-result
# must not block.

_flow_verdict_manifest() {
  # Seeds a manifest at stage=Review — pr-review-pass-done's "from" state.
  local repos_root="$1" tid="$2"
  _flow_seed_manifest "$repos_root" "$tid"
  local manifest
  manifest=$(_flow_manifest_path "$repos_root" "$tid")
  _flow_set_manifest_field "$manifest" '.stage = "Review"'
}

_write_fail_verdict_line() {
  # Appends one FAIL verifier-result line to $1, for verifier=$2 (default
  # live_backend) phase=$3 (default VERIFY).
  local log="$1" verifier="${2:-live_backend}" phase="${3:-VERIFY}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|verifier-result|info|{\"verifier\":\"${verifier}\",\"verdict\":\"FAIL\",\"score\":0.5,\"criteria_met\":3,\"criteria_total\":6,\"attempt\":1,\"phase\":\"${phase}\"}" >>"$log"
}

# tracker-flow-projection-cutover task 7.3: a verdict-gate refusal (exit
# 11) leaves the outbox with no pr-review-passed record — the emission now
# lives on the transition path itself (flow.sh's emits declaration), after
# the verdict gate, so a refused transition never reaches it.
test_flow_verdict_gate_blocks_trailing_fail() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_verdict_manifest "$tmpdir/repos" WIL-99
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  _write_fail_verdict_line "$log"

  local rc=0
  _flow_run "$tmpdir" WIL-99 pr-review-pass-done >/dev/null 2>&1 || rc=$?

  local blocked_logged=1
  grep -q 'META|verdict-gate|fail' "$log" && blocked_logged=0
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  local stage
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  local outbox_has_pass_event=1
  [ -f "$tmpdir/logs/WIL-99-outbox.jsonl" ] &&
    grep -q '"event":"pr-review-passed"' "$tmpdir/logs/WIL-99-outbox.jsonl" &&
    outbox_has_pass_event=0

  rm -rf "$tmpdir"
  [ "$rc" -eq 11 ] && [ "$blocked_logged" -eq 0 ] && [ "$stage" = "Review" ] && [ "$outbox_has_pass_event" -eq 1 ] || {
    echo "rc=$rc blocked_logged=$blocked_logged stage=$stage outbox_has_pass_event=$outbox_has_pass_event"
    return 1
  }
}

test_flow_verdict_gate_override_bypasses() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_verdict_manifest "$tmpdir/repos" WIL-99
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  _write_fail_verdict_line "$log"

  local rc=0
  _flow_run "$tmpdir" WIL-99 pr-review-pass-done --override "manually verified per WIL-79" >/dev/null 2>&1 || rc=$?

  local override_logged=1
  grep -q 'META|verdict-override|info|.*reason=manually verified per WIL-79' "$log" && override_logged=0
  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  local stage
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)

  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$override_logged" -eq 0 ] && [ "$stage" = "Done" ] || {
    echo "rc=$rc override_logged=$override_logged stage=$stage"
    return 1
  }
}

test_flow_verdict_gate_pass_supersedes_fail() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_verdict_manifest "$tmpdir/repos" WIL-99
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  _write_fail_verdict_line "$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|verifier-result|info|{\"verifier\":\"live_backend\",\"verdict\":\"PASS\",\"score\":1.0,\"criteria_met\":6,\"criteria_total\":6,\"attempt\":2,\"phase\":\"VERIFY\"}" >>"$log"

  local rc=0
  _flow_run "$tmpdir" WIL-99 pr-review-pass-done >/dev/null 2>&1 || rc=$?

  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  local stage
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$stage" = "Done" ]
}

test_flow_verdict_gate_no_verifier_result_passes() {
  # Backward compatibility: a ticket with zero verifier-result entries
  # (every ticket predating this gate) must transition exactly as before.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_verdict_manifest "$tmpdir/repos" WIL-99
  : >"$tmpdir/logs/WIL-99-pipeline.log"

  local rc=0
  _flow_run "$tmpdir" WIL-99 pr-review-pass-done >/dev/null 2>&1 || rc=$?

  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  local stage
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$stage" = "Done" ]
}

test_flow_verdict_gate_skipped_when_not_declared() {
  # needs-info carries no verdict_gate — a trailing FAIL must not block a
  # trigger that never opted in.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  _flow_seed_manifest "$tmpdir/repos" WIL-99
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  _write_fail_verdict_line "$log"

  local rc=0 out
  out=$(_flow_run "$tmpdir" WIL-99 needs-info 2>&1) || rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] || {
    echo "rc=$rc output=$out"
    return 1
  }
}

test_flow_verdict_gate_fails_open_without_verifier_result_lib() {
  # Version-skew guard: a runtime lib dir carrying a verifier-result.sh
  # that predates verifier_latest_verdict (e.g. mid-rollout skew) must not
  # make the gate reference an undefined function — it degrades to a no-op
  # rather than erroring the transition out. heartbeat.sh/epic-
  # precondition.sh are the only two flow.sh sources unconditionally (no
  # fallback candidate) — everything else it needs (events.sh, manifest-
  # write.sh, fence-check.sh) falls back to the real
  # $SCRIPT_DIR/../../lib/ copy, so this partial lib dir only needs to
  # shadow verifier-result.sh with an empty stub.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib"
  _flow_verdict_manifest "$tmpdir/repos" WIL-99
  cp "$PLUGIN_DIR/lib/heartbeat.sh" "$PLUGIN_DIR/lib/epic-precondition.sh" "$tmpdir/lib/"
  echo "#!/usr/bin/env bash" >"$tmpdir/lib/verifier-result.sh"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  _write_fail_verdict_line "$log"

  local rc=0
  FLEET_FENCE_ENFORCE=false FLEET_BOARD_DRIVERS=none \
    CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" REPOS_ROOT="$tmpdir/repos" \
    FLEET_PIPELINE_LOG_DIR="$tmpdir/logs" \
    "$FLOW_SH" WIL-99 pr-review-pass-done >/dev/null 2>&1 || rc=$?

  local manifest
  manifest=$(_flow_manifest_path "$tmpdir/repos" WIL-99)
  local stage
  stage=$(jq -r '.stage // empty' "$manifest" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$stage" = "Done" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_validate_linear_config_dry_run \
  test_preflight_aborts_on_unset_key \
  test_flow_concurrent_lock \
  test_flow_dispatcher_unknown_trigger \
  test_linear_api_retry_on_503 \
  test_spawn_agent_post_loop_bearing_requires_verdict \
  test_outcome_label_exact_match \
  test_retry_classify_429_transient \
  test_retry_classify_rate_limit_regex \
  test_detect_resume_schema_mismatch \
  test_detect_resume_maintenance_document_done \
  test_detect_resume_maintenance_document_waiting \
  test_detect_resume_maintenance_document_fail \
  test_detect_resume_maintenance_maintenance_done \
  test_detect_resume_maintenance_maintenance_waiting \
  test_detect_resume_maintenance_maintenance_fail \
  test_detect_resume_maintenance_fallback_document \
  test_detect_resume_verify_attempts_excludes_pass \
  test_detect_resume_verify_attempts_counts_fails \
  test_detect_resume_no_step3 \
  test_detect_resume_pr_number_from_checkout_only \
  test_flow_from_precondition_logic \
  test_flow_implement_outcome_logs_line \
  test_flow_implement_outcome_logs_line_on_repeat \
  test_flow_pending_event_on_entry_is_emitted_then_cleared \
  test_flow_pending_event_matching_idem_appends_nothing \
  test_flow_two_distinct_transitions_produce_two_records \
  test_flow_human_approve_provenance_policy_writes_manifest \
  test_flow_human_approve_defaults_to_human_provenance \
  test_flow_re_claim_clears_manifest_approval \
  test_flow_re_claim_preserves_stage \
  test_flow_implement_complete_writes_stage_and_clears_approval \
  test_uat_fail_never_observes_approved_true \
  test_flow_uat_pass_writes_stage \
  test_flow_adhoc_ticket_gets_manifest_via_flow \
  test_needs_info_set_adds_the_flag \
  test_needs_info_resolved_removes_the_flag \
  test_needs_info_does_not_change_stage \
  test_needs_adr_set_adds_the_flag \
  test_needs_adr_resolved_removes_the_flag \
  test_needs_adr_does_not_change_stage \
  test_state_machine_single_source \
  test_flow_verdict_gate_blocks_trailing_fail \
  test_flow_verdict_gate_override_bypasses \
  test_flow_verdict_gate_pass_supersedes_fail \
  test_flow_verdict_gate_no_verifier_result_passes \
  test_flow_verdict_gate_skipped_when_not_declared \
  test_flow_verdict_gate_fails_open_without_verifier_result_lib \
  test_ticket_dir_disambiguation \
  test_gen_mermaid_roundtrip; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
