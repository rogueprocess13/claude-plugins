#!/usr/bin/env bash
# test-ticket-audit-drift.sh — unit tests for audit-drift-check.sh
# Tests changed ticket detection, new ticket detection, and no-change fast path.
# Requires: bash, jq
# Usage: bash test-ticket-audit-drift.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the helper to get the audit_drift_check function
source "$LIB_DIR/audit-drift-check.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# ── Drift detection ───────────────────────────────────────────────────────────

test_changed_ticket_triggers_drift() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' >"$snapshot"
  echo '[{"id":"i1","updatedAt":"2026-06-07T00:00:00Z"}]' >"$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -n "${CHANGED_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_new_ticket_triggers_drift() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' >"$snapshot"
  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"},{"id":"i2","updatedAt":"2026-06-07T00:00:00Z"}]' >"$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -n "${NEW_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_no_change_no_drift() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' >"$snapshot"
  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' >"$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -z "${CHANGED_IDS:-}" ] && [ -z "${NEW_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_older_timestamp_not_changed() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"i1","updatedAt":"2026-06-07T00:00:00Z"}]' >"$snapshot"
  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' >"$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -z "${CHANGED_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_identifier_keyed_snapshot_vs_linear_uuid() {
  # Inventory snapshot holds identifiers; Linear returns UUID .id plus
  # .identifier. An unchanged ticket must not read as NEW.
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"WIL-78","updatedAt":"2026-06-01T10:00:00Z"}]' >"$snapshot"
  echo '[{"id":"5f1c9a2e-uuid","identifier":"WIL-78","updatedAt":"2026-06-01T10:00:00Z"}]' >"$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -z "${CHANGED_IDS:-}" ] && [ -z "${NEW_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_identifier_keyed_change_reports_identifier() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"WIL-78","updatedAt":"2026-06-01T10:00:00Z"}]' >"$snapshot"
  echo '[{"id":"5f1c9a2e-uuid","identifier":"WIL-78","updatedAt":"2026-06-03T10:00:00Z"}]' >"$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ "${CHANGED_IDS:-}" = "WIL-78" ] && [ -z "${NEW_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_legacy_date_only_snapshot_same_day_not_changed() {
  # Legacy inventories store Last Updated as a bare date; a full ISO
  # timestamp on that same day must not read as CHANGED.
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"WIL-78","updatedAt":"2026-05-01"}]' >"$snapshot"
  echo '[{"id":"uuid-1","identifier":"WIL-78","updatedAt":"2026-05-01T14:22:00.000Z"}]' >"$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -z "${CHANGED_IDS:-}" ] && [ -z "${NEW_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_legacy_date_only_snapshot_later_day_changed() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"WIL-78","updatedAt":"2026-05-01"}]' >"$snapshot"
  echo '[{"id":"uuid-1","identifier":"WIL-78","updatedAt":"2026-05-02T09:00:00.000Z"}]' >"$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ "${CHANGED_IDS:-}" = "WIL-78" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_changed_ticket_triggers_drift \
  test_new_ticket_triggers_drift \
  test_no_change_no_drift \
  test_older_timestamp_not_changed \
  test_identifier_keyed_snapshot_vs_linear_uuid \
  test_identifier_keyed_change_reports_identifier \
  test_legacy_date_only_snapshot_same_day_not_changed \
  test_legacy_date_only_snapshot_later_day_changed; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
