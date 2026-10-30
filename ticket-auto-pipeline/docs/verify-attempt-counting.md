# VERIFY attempt counting, operator stop and reset

Issues #572 and #573. `VERIFY_ATTEMPTS` (detect-resume.sh), `verify-retry-decide.sh` and
fleetd's `resolve_loop_counters` all count failed VERIFY **attempts**, not fail lines. The
one implementation is `verify_attempt_count` in `lib/verify-checkpoint.sh`. fleetd ports it
as `_verify_attempt_count`, and a parity test runs both on the same fixtures.

## Rules

- Every `VERIFY|verify|fail|` line between two attempt boundaries counts once. A boundary is
  `VERIFY|verify|waiting|` (the bracket open) or `IMPLEMENT|implement|waiting|`/`done|` (the
  re-implement between attempts). So the agent's own terminal line plus the router's
  `spawn_agent_post` line are one attempt.
- A synthetic close is not a verdict. detect-resume.sh writes one when it finds an open
  bracket with no live worker: `|fail|zombie-detected: <PHASE> <step>` (crash), or
  `|fail|operator-stopped: <PHASE> <step>` when a `META|operator-stop` line follows the
  bracket. It is discounted, and `VERIFY_LAST`/`VERIFY_LATEST` skip it, **only when
  detect-resume.sh recorded that line number in the control file** (below).
- An operator reset zeroes the count. Only attempts after the reset point count.

## Trust boundary: the control file

Phase agents append to the pipeline log directly. So nothing written in the log can reset
the count or discount an attempt. Otherwise an agent could append a reset line, or a fake
`zombie-detected:` close, and escape the attempt cap.

Both facts live in `<pipeline log>.verify-ctl`, one entry per line:

```
reset|<log line count at reset>|<iso>|<reason>   # written by lib/verify-attempts-reset.sh
synthetic|<log line number>                      # written by detect-resume.sh
```

- A `META|verify-attempts-reset` line in the log is only an audit record. The counters
  ignore it.
- A `zombie-detected:`/`operator-stopped:` line with no `synthetic` entry for its line
  number counts as an ordinary failed attempt.
- At most `VERIFY_RESET_MAX` (default 2) `reset` entries are honoured, in file order. Any
  later entries are ignored.

This raises the bar. It is not a sandbox. An agent that writes the control file itself is
deliberately forging operator state, the same threat model as `ticket-create-guard.sh`.

## Operator actions

```
# Reset the count after fixing what failed earlier attempts. Run it from a plain terminal:
# it refuses an agent context (CLAUDE_CODE_SESSION_ID or FLEET_WORKER_PID set, exit 4)
# and refuses past VERIFY_RESET_MAX resets (exit 5).
bash ~/.claude/skills/lib/verify-attempts-reset.sh [--log-file F] <TICKET_ID> <reason>

# Stop a worker mid-phase on purpose. detect-resume.sh closes the open bracket on the
# next run without the 5-minute zombie wait (a live worker still blocks it).
<iso>|META|operator-stop|info|<reason>
```

## Not changed

`run-summary.sh`'s `verify_attempts` evidence counter still counts fail lines in the run
window.
