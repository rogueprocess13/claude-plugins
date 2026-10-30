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
- A synthetic close is not a verdict and never counts. detect-resume.sh writes one when it
  finds an open bracket with no live worker: `|fail|zombie-detected: <PHASE> <step>` (crash),
  or `|fail|operator-stopped: <PHASE> <step>` when a `META|operator-stop` line follows the
  bracket. `VERIFY_LAST` (detect-resume.sh) and `VERIFY_LATEST` (verify-retry-decide.sh) skip
  both, so an interrupted VERIFY re-runs VERIFY. It does not ask for a re-implement of code
  that no verdict judged.
- `META|verify-attempts-reset` sets the count to zero. Only attempts after the last reset
  count toward the cap.

## Operator markers

```
# Stop a worker mid-phase on purpose. detect-resume.sh closes the open bracket on the
# next run without waiting the 5-minute zombie window (a live worker still blocks it).
2026-10-30T10:00:00Z|META|operator-stop|info|<reason>

# Reset the count after fixing an environment problem that failed earlier attempts.
2026-10-30T10:05:00Z|META|verify-attempts-reset|info|<reason>
```

An operator (or an operator script) writes both markers by hand. An agent never writes them.

## Not changed

`run-summary.sh`'s `verify_attempts` evidence counter still counts fail lines in the run
window.
