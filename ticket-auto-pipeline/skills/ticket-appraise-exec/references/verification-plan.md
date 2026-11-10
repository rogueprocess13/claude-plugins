# ticket-appraise-exec — verification plan derivation

Read only under the condition in SKILL.md Step 3 ("Reference files (load condition)"), when `{COMPLEXITY}` = complex, before Step 3.7 derives the verification plan. The notes.md `## Verification Plan` schema, the Role Scope Registry write, the heartbeats and the `verify-plan-derived` log lines stay in SKILL.md Step 3.7.

## Contents

- Inputs to read
- Derivation steps (A. criteria, B. role scope, C. navigation path, D. expected behavior, E. test data)
- Push-back triggers

### Inputs to read

1. **Ticket description and acceptance criteria** — from `context.md` or the Linear issue
2. **Plan artifact** — `simple-fix.md` or `openspec/changes/{change-name}/design.md` + `tasks.md` + spec files
3. **`app-knowledge/SKILL.md`** — role constraints and navigation patterns, if recorded (it may be empty)
4. **`test-users.json`** — project-local catalog (not bundled; copy `config/test-users.example.json` to your `TICKETS_ROOT` and populate). Provides available roles and emails. If absent, role scope must be inferred from the ticket and app-knowledge.
5. **`notes.md`** — for investigation findings (`## Initial Investigation`, `## Blast Radius`), adversarial review results, and prior art context

### Derivation steps

#### A. Extract acceptance criteria

Identify every acceptance criterion in the ticket. Each criterion is one row in the per-criterion table. Criteria sources, in order of preference:
1. Numbered AC lines in the ticket description (e.g., "AC-1: ...", "1. ...")
2. Bullet points under an "Acceptance Criteria" or "## Expected Behavior" heading
3. Behavioral descriptions in the plan artifact (implementation tasks that describe user-visible outcomes)
4. If no criteria are identifiable anywhere → the ticket is underspecified. Trigger `VERIFY_PLAN_NO_ROLE_SCOPE` (no criteria to derive roles from).

#### B. Determine role scope per criterion

For each criterion, determine which roles are affected. Use the following hierarchy:

1. **Explicit role mention** (confidence: high): If the criterion text says "as an attorney", "admin only", "for debtors", etc. → role scope is the explicitly mentioned role(s). Scope type is "role-specific".

2. **Code path role gating** (confidence: high): If the plan artifact references auth guards, role-based UI components (`*ngIf="role..."`, `hasRole(...)`), or role-specific service methods → role scope is the roles enumerated in the code. Scope type is "role-specific".

3. **App-knowledge role-based UI rules** (confidence: medium): Cross-reference the feature area against `app-knowledge/SKILL.md`. If it documents a role constraint for that feature area (e.g., "only admins can access user-permission page") → derive role scope from the known rule. Scope type is "role-specific".

4. **Default heuristic** (confidence: low):
   - **Infrastructure changes** (authentication, routing, database schema, shared utilities, logging, error handling) → "global" (all roles). Scope type is "global".
   - **Feature changes** with no role information → "unknown". This triggers a push-back.

5. **Role scope classification:**
   - **global**: Change affects all roles identically. Affected roles = all roles from `test-users.json`.
   - **role-specific**: Change affects only certain roles. Affected roles = only the roles that can verify the behavior.

#### C. Derive navigation path per criterion

For each criterion, determine how to reach the feature in the browser:

1. **URL in ticket**: Extract any URL path from the ticket description (`/handover/`, `/admin/`, `/user-permission/`, `/organisation/`).
2. **nav-hints match**: Check `nav-hints.md` (or the nav-hints SKILL.md) for the feature area keyword. If a navigation path exists for that area, use it.
3. **Infer from feature area**: Map feature area keywords to known URL patterns:
   - "handover" / "matter handover" → `/handover/`
   - "admin" / "user permission" → `/admin/user-permission`
   - "organisation" / "entity" → `/organisation/`
   - "correspondence" / "portfolio" → `/portfolio/`
4. **Unknown**: If no nav path can be determined → trigger `VERIFY_PLAN_NO_NAV_PATH`.

#### D. Extract expected behavior per criterion

For each criterion, extract what "working correctly" looks like:

1. **Acceptance criteria wording**: The criterion itself describes the expected outcome (e.g., "AC-1: Attorney clicks Send and the handover is created" → expected behavior: "Handover created after attorney clicks Send").
2. **"Expected Behaviour" section**: If the ticket has a dedicated expected behavior section, use it.
3. **Plan artifact behavioral descriptions**: Implementation tasks or design.md may describe user-visible outcomes.
4. **Vague language detection**: If the only description is vague ("works correctly", "is fixed", "should be improved", "functions properly") with no observable outcome → trigger `VERIFY_PLAN_VAGUE_BEHAVIOR`.

#### E. Detect test data requirements per criterion

For each criterion, determine whether pre-existing data is needed:

1. **Pre-existing state assumptions**: Does the criterion assume data exists (e.g., "an existing handover", "a debtor with overdue invoices", "a pending correspondence")?
2. **Seed data references**: Does the plan mention `seed-db`, `data.sql`, fixtures, or setup scripts?
3. **Setup steps**: Are there documented steps to create the required data (e.g., "Create a handover first via ...")?
4. If data is required but no setup mechanism is documented → trigger `VERIFY_PLAN_NO_TEST_DATA`.

### Push-back triggers

If any single criterion cannot be fully derived, halt the pipeline. The following gate-stop codes apply:

| Condition | Gate-stop code |
|-----------|---------------|
| Role scope unknown for any criterion | `VERIFY_PLAN_NO_ROLE_SCOPE` |
| Navigation path unknown for any criterion | `VERIFY_PLAN_NO_NAV_PATH` |
| Expected behavior vague for any criterion | `VERIFY_PLAN_VAGUE_BEHAVIOR` |
| Test data required but no setup documented | `VERIFY_PLAN_NO_TEST_DATA` |

**In `--from-auto` mode:** Push-back halts the pipeline immediately:
```bash
bash ~/.claude/skills/lib/plog.sh META gate-stop fail "{GATE-STOP-CODE} — {reason}"
```
Stop with non-zero exit so `ticket-auto` halts.

**In interactive mode (no `--from-auto`):** Warn the user but allow override:
```
⚠️  VERIFICATION PLAN — {GATE-STOP-CODE}

The verification plan for {TICKET-ID} could not be fully derived:

{list of criteria and what's missing}

The pipeline cannot verify this ticket reliably. Options:
1. Update the ticket with the missing information and re-run
2. Override and proceed anyway (verification may be incomplete)

Re-run: /ticket-appraise-exec {TICKET-ID} --from-step verify-plan-derived
```

If the user chooses to override, proceed to Step 3.8 with the partial plan. **Write the partial verification plan to notes.md first** — use the same schema as SKILL.md Step 3.7 (Write verification plan to notes.md), marking unverifiable criteria with `✗` in the Verifiable column and noting the missing dimension in the relevant column (e.g., "unknown" for role scope, "not specified" for nav path).
