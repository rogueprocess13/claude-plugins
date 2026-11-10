# ticket-verify — live-backend mode (Step 2 variant, Step 4c-live, Step 7a diagnostics)

Read only under the condition in SKILL.md Step 1f (`VERIFY_MODE=live-backend`). Every other step stays in SKILL.md and runs in SKILL.md order: 1e → 1f → 1.5 → 1.6 → 1.7c → 2 (this variant, then 2d) → 4c-live → 5 → 6 or 7. The REMEDIATION_BRIEF (7c), the `write_verifier_result verifier=live_backend` lines (Steps 6 and 7) and the checkpoint-resume rule (Step dispatch) are in SKILL.md.

## Contents

- Step 2 (live-backend variant) — running-system checks, plan template
- Step 4c-live — Execute live-backend verification
- Step 7a — Collect diagnostics (live-backend mode)

---

## Step 2 (live-backend variant)

**Derive the running-system checks.** Read the plan artifact and `notes.md`/`context.md` for the affected services and the specific runtime behaviour the acceptance criteria describe (e.g. "all services register with Eureka", "circuit breaker opens after N downstream failures", "service-to-service call succeeds"). Unlike build-only, there is no build command that can confirm these — the check has to run against the live services `env-start.sh` (Step 1.6b) brought up. Determine, per criterion, the concrete check:

- **Registration/discovery claims** (e.g. "registers with Eureka") → an `env-status.sh` read and/or a `curl` against the discovery service's registry endpoint (e.g. `/eureka/apps`), confirming the expected service names appear.
- **Service-to-service call claims** → a `curl` (or the project's documented API-check invocation) that exercises the call path directly and inspects the response status/body.
- **Failure/resilience claims** (e.g. circuit breaker) → simulate the stated downstream failure (stop/block the dependency `env-start.sh` manages, or use the project's documented fault-injection method) and confirm the expected behaviour (breaker opens, fallback response, recovery on restore).

**Expand acceptance criteria into atomic items** exactly as in 2b — each criterion maps to one live check + one pass condition.

Construct and print the **Verification Plan**:

```
## Verification Plan — {TICKET-ID}: {title} (live-backend)

**Environment:** {env} (live backend, no UI)
**Services under test:** {list of affected services}

**What was broken:** {one sentence from Actual Behaviour}
**What should be true now:** {one sentence from Expected Behaviour / AC}

### Acceptance criteria (expanded — each item verified independently)
1. {atomic criterion — one observable runtime fact, e.g. "gateway registers with Eureka"}
2. {atomic criterion}
...

### Live checks
1. `{env-status.sh invocation or curl command}` — {why, what it confirms}
2. `{env-status.sh invocation or curl command}` — {why, what it confirms}
...

### Pass criteria
- [ ] {criterion 1 — expected response/state observed}
- [ ] {criterion 2}
...
```

If `--from-auto` is NOT set: pause and ask "Does this plan look right? (yes / adjust: ...)". If `--from-auto` IS set: print the plan and proceed directly to Step 4c-live (skip Steps 3, 4, 4b entirely — there is no browser session to establish).

bash ~/.claude/skills/lib/plog.sh VERIFY build-plan done "{N} criteria (live-backend)"

Proceed to **Step 4c-live** below, skipping Steps 3, 4, and 4b.

---

## Step 4c-live — Execute live-backend verification (live-backend mode only)

**Phase timeout:** same 30-minute wall-clock limit as Step 4b — checkpoint progress, don't crash on timeout.

The environment is already up (Step 1.6b ran `env-start.sh` for `live-backend` mode same as browser mode — see Step 1.6). Run each live check from the Step 2 (live-backend variant) plan sequentially. For **every check**:

1. Run the check, capturing output:
   ```bash
   L=$(bash ~/.claude/skills/lib/ticket-tmp.sh {TICKET-ID} verify-{step}.log) && { {env-status.sh invocation or curl command} ; } > "$L" 2>&1
   _rc=$?
   ```
   Use `bash {TICKETS_ROOT}/env-status.sh` for service-health/registration reads. Use `curl -sS -w '\n%{http_code}\n'` (or the project's documented API-check invocation) for direct service-to-service or endpoint checks. For failure-simulation criteria (e.g. circuit breaker), use the project's documented fault-injection method — typically stopping a dependency via `env-start.sh`/`env-stop.sh` — then re-run the check to confirm the expected degraded/recovered behaviour.
2. Record the **observed result** — exit code / HTTP status, and whether the expected state appears in the captured output (e.g. the service name present in `/eureka/apps`, the expected HTTP status and body shape, the breaker's fallback response).
3. If the criterion requires checking a state transition (e.g. breaker opens then recovers), run the check at each stage explicitly — before the fault, during, and after clearing it — and record all three observations, not just the final one.

**Per-criterion checkpointing:** After EACH criterion passes, write a checkpoint entry exactly as in Step 4b, so a crash resumes from the next criterion:

```bash
bash ~/.claude/skills/lib/plog.sh VERIFY checkpoint done "criterion-{N}-pass"
```

At any point, if a check's exit code/HTTP status is unexpected or the expected state is absent, mark that criterion **FAIL** and record:
- The check that was run and its result (exit code / HTTP status)
- What was expected (from the pass criterion)
- What was observed — quote the relevant lines of captured output verbatim

Continue executing remaining checks unless the failure makes downstream checks meaningless (e.g. a service failing to start means every check against it will fail for the same reason — note this and skip re-running them individually).

**Leave the environment as found:** if a fault-injection step stopped a dependency, restore it (`env-start.sh`) before finishing this step, even on FAIL — a left-down dependency would cause spurious failures in the next verification run.

bash ~/.claude/skills/lib/plog.sh VERIFY execute-steps done "{N} live checks executed"

Proceed to Step 5.

---

## Step 7a — Collect diagnostics (live-backend mode)

**Live-backend mode:** substitute live-check diagnostics for the browser ones in SKILL.md Step 7a — these map onto the same REMEDIATION_BRIEF fields (7c) so downstream skills don't need mode-specific parsing:
1. **Failed check + exit code/HTTP status** — maps to `CONSOLE_ERRORS` field
2. **Service/environment + endpoint checked** — maps to `CURRENT_URL` field (use `{service}@{env}` or the endpoint URL)
3. **Last 20–30 lines of the step's `$L` log**, plus `env-status.sh` output at the failure — maps to `SNAPSHOT_EXCERPT`
4. **Failed step** — step number, expected vs. observed (check + result)
