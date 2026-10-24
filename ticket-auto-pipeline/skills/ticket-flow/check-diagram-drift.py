#!/usr/bin/env python3
"""Drift gate: the public state diagram must show every workflow.json trigger.

docs/ticket-auto-pipeline-diagram.html carries a JSON data block,
<script type="application/json" id="workflow-triggers">, and draws every edge
and every side transition from it. This check compares that block with
skills/ticket-flow/workflow.json:

  * the trigger name sets must be equal (no missing and no extra triggers);
  * for each trigger, from / to / adds / removes / emitted event must match;
  * each trigger must carry drawing metadata: an edge `kind` when it changes
    state, a `side` description when it does not;
  * every state a trigger names, and every well_known_state, must be drawn;
  * the page must render from the block, not from a hand-kept list.

Usage:
  check-diagram-drift.py [--workflow PATH] [--diagram PATH]

Exit codes: 0 in sync, 1 drift, 2 structural (file missing, no data block,
malformed JSON).
"""

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
DEFAULT_WORKFLOW = HERE / "workflow.json"
DEFAULT_DIAGRAM = REPO_ROOT / "docs" / "ticket-auto-pipeline-diagram.html"

BLOCK_ID = "workflow-triggers"
BLOCK_RE = re.compile(
    r'<script\s+type="application/json"\s+id="' + BLOCK_ID + r'"\s*>(.*?)</script>',
    re.S,
)
EDGE_KINDS = {"auto", "human", "reject", "loopback"}


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    return list(value)


def _facts(trigger, from_workflow):
    event = (trigger.get("emits") or {}).get("event") if from_workflow else trigger.get("event")
    return {
        "from": sorted(_as_list(trigger.get("from"))),
        "to": trigger.get("to"),
        "adds": sorted(trigger.get("adds") or []),
        "removes": sorted(trigger.get("removes") or []),
        "event": event,
    }


def check(workflow, html):
    """Return a list of drift messages (empty means in sync)."""
    problems = []
    match = BLOCK_RE.search(html)
    if not match:
        raise ValueError(f'no <script type="application/json" id="{BLOCK_ID}"> block in diagram')
    try:
        block = json.loads(match.group(1))
    except json.JSONDecodeError as exc:
        raise ValueError(f"diagram data block is not valid JSON: {exc}") from exc

    wf_triggers = workflow.get("triggers") or {}
    dg_triggers = block.get("triggers") or {}

    for name in sorted(set(wf_triggers) - set(dg_triggers)):
        problems.append(f"trigger '{name}' is in workflow.json but missing from the diagram")
    for name in sorted(set(dg_triggers) - set(wf_triggers)):
        problems.append(f"trigger '{name}' is in the diagram but not in workflow.json")

    for name in sorted(set(wf_triggers) & set(dg_triggers)):
        want = _facts(wf_triggers[name], True)
        got = _facts(dg_triggers[name], False)
        for field in want:
            if want[field] != got[field]:
                problems.append(f"trigger '{name}': {field} is {got[field]!r} in the diagram, {want[field]!r} in workflow.json")
        meta = dg_triggers[name].get("diagram") or {}
        if want["to"] is None:
            if not str(meta.get("side") or "").strip():
                problems.append(f"trigger '{name}' changes no state but has no diagram.side description")
        elif meta.get("kind") not in EDGE_KINDS:
            problems.append(f"trigger '{name}' changes state but diagram.kind is {meta.get('kind')!r} (want one of {sorted(EDGE_KINDS)})")

    drawn = set(block.get("states") or [])
    side_states = set((block.get("side_states") or {}).keys())
    named = set()
    for trig in wf_triggers.values():
        named.update(_as_list(trig.get("from")))
        if trig.get("to"):
            named.add(trig["to"])
    for state in sorted(named - drawn):
        problems.append(f"state '{state}' is used by a trigger but not drawn (diagram block 'states')")
    for state in sorted(set(workflow.get("well_known_states") or []) - drawn - side_states):
        problems.append(f"well-known state '{state}' is neither drawn nor listed in 'side_states'")

    if f'getElementById("{BLOCK_ID}")' not in html:
        problems.append(f'the page never reads the data block (no getElementById("{BLOCK_ID}"))')
    if re.search(r"^\s*transitions\s*:\s*\[", html, re.M):
        problems.append("the page still carries a hand-written 'transitions: [' list; draw from the data block instead")
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workflow", type=Path, default=DEFAULT_WORKFLOW)
    parser.add_argument("--diagram", type=Path, default=DEFAULT_DIAGRAM)
    args = parser.parse_args(argv)

    try:
        workflow = json.loads(args.workflow.read_text(encoding="utf-8"))
        html = args.diagram.read_text(encoding="utf-8")
        problems = check(workflow, html)
    except (OSError, ValueError) as exc:
        print(f"check-diagram-drift: {exc}", file=sys.stderr)
        return 2

    if problems:
        print(f"check-diagram-drift: {args.diagram} has drifted from {args.workflow}:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print("Update the workflow-triggers block in the diagram (see its _note).", file=sys.stderr)
        return 1
    print(f"check-diagram-drift: in sync ({len(workflow.get('triggers') or {})} triggers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
