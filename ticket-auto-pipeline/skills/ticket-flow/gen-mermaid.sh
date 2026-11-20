#!/usr/bin/env bash
# gen-mermaid.sh — generate a stateDiagram-v2 block from workflow.json's
# `triggers` table (formerly state-machine.json — see
# tracker-event-vocabulary-and-emitter Section 4).
# Outputs only the diagram content (no markdown fence) for embedding.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM="$SCRIPT_DIR/workflow.json"

jq -r 'empty' "$SM" 2>/dev/null || {
  echo "workflow.json is not valid JSON" >&2
  exit 1
}

echo 'stateDiagram-v2'

# Hardcoded framing lines — not modelled as state-machine triggers
echo '    [*] --> Backlog : ticket created'

# Emit one line per trigger that has non-null from/to.
# When "from" is an array, emit a line for each element.
jq -r '.triggers | to_entries[]
  | select(.value.from != null and .value.to != null)
  | .value.from as $from | .value.to as $to | .key as $key
  | if ($from | type == "array") then $from[] else $from end
  | "    \(.) --> \($to) : \($key)"' "$SM"

# A trigger that changes state from any state (from: null, to set — cancel,
# GitHub #770) is drawn once, from a composite note state, not once per
# state: seven identical edges would bury the lifecycle.
jq -r '.triggers | to_entries[]
  | select(.value.from == null and .value.to != null)
  | "    AnyState --> \(.value.to) : \(.key)"' "$SM"
if jq -e '[.triggers[] | select(.from == null and .to != null)] | length > 0' "$SM" >/dev/null; then
  refused=$(jq -r '[.triggers[] | select(.from == null and .to != null) | .refuse_from[]?] | unique | join(", ")' "$SM")
  echo "    AnyState : any state${refused:+ except ${refused}}"
fi

echo '    Done --> [*]'
jq -r '(.tombstone_stages // [])[] | "    \(.) --> [*]"' "$SM"
