"""Keep fleetd tests off the developer's installed ticket-auto-pipeline.

fleetd resolves `flow.sh` and the ticket-auto lib dir with a fallback to
`$HOME/.claude/skills/...`, so a test that passes a scratch lib dir (or none)
used to run whatever copy happened to be installed on the machine, and leave
`flow.sh` lock files in the real skills dir (GitHub #648). `isolate()` points
everything at this checkout and a scratch dir instead:

- `HOME` -> an empty scratch dir, so no `$HOME/.claude/...` fallback can
  resolve to an installed copy.
- `FLEET_TICKET_FLOW_SH` -> this checkout's `flow.sh` (the resolver seam in
  `phase_dispatch.ticket_flow_script`).
- `CLAUDE_SKILLS_LIB` -> this checkout's lib, so `flow.sh` and every script
  it sources come from the same tree.
- `TICKET_FLOW_LOCK_DIR`, `REPOS_ROOT`, `FLEET_PIPELINE_LOG_DIR` -> scratch,
  so a real `flow.sh` run writes its lock, manifest and log nowhere real.
- `LINEAR_API_KEY` removed, so no test can reach the real tracker.

Call `isolate()` from `setUpModule` and the returned function from
`tearDownModule`. A test that needs its own value still sets it as before.
"""

import os
import shutil
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
CHECKOUT_LIB = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
CHECKOUT_FLOW_SH = (REPO_ROOT / 'ticket-auto-pipeline' / 'skills'
                    / 'ticket-flow' / 'flow.sh')

# Captured at import, before any isolate() call, for stamp checks.
REAL_HOME = Path.home()

_KEYS = ('HOME', 'FLEET_TICKET_FLOW_SH', 'CLAUDE_SKILLS_LIB',
         'TICKET_FLOW_LOCK_DIR', 'REPOS_ROOT', 'FLEET_PIPELINE_LOG_DIR',
         'LINEAR_API_KEY')


def isolate():
    """Apply the isolation to `os.environ`; return a function undoing it."""
    saved = {k: os.environ.get(k) for k in _KEYS}
    root = Path(tempfile.mkdtemp(prefix='fleetd-test-hermetic-'))
    for sub in ('home', 'flow-locks', 'repos', 'logs'):
        (root / sub).mkdir()
    os.environ.update({
        'HOME': str(root / 'home'),
        'FLEET_TICKET_FLOW_SH': str(CHECKOUT_FLOW_SH),
        'CLAUDE_SKILLS_LIB': str(CHECKOUT_LIB),
        'TICKET_FLOW_LOCK_DIR': str(root / 'flow-locks'),
        'REPOS_ROOT': str(root / 'repos'),
        'FLEET_PIPELINE_LOG_DIR': str(root / 'logs'),
    })
    os.environ.pop('LINEAR_API_KEY', None)

    def restore():
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(root, ignore_errors=True)

    return restore
