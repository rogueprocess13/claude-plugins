# ticket-verify — build-only mode (Step 2 variant, Step 4c, Step 7a diagnostics)

Read only under the condition in SKILL.md Step 1f (`VERIFY_MODE=build-only`). Every other step stays in SKILL.md and runs in SKILL.md order: 1e → 1f → 1.5 → 1.7c → 2 (this variant, then 2d) → 4c → 5 → 6 or 7. The REMEDIATION_BRIEF (7c), the `write_verifier_result verifier=build_only` lines (Steps 6 and 7) and the checkpoint-resume rule (Step dispatch) are in SKILL.md.

## Contents

- Step 2 (build-only variant) — module list, build commands, plan template
- Step 4c — Execute build verification
- Step 7a — Collect diagnostics (build-only mode)

---

## Step 2 (build-only variant)

**Derive the module list and build commands.** Read the plan artifact's Completion Checklist / task list and `notes.md` for the affected repos/modules (e.g. from a "pre-implementation checkpoint" or worktree list). For each affected module, determine the appropriate build command from the project's `CLAUDE.md` `BE_TEST_CMD` and standard Maven/Gradle conventions:

- Root/parent POM changes → `mvn -N install` (or `mvn -N validate` if install would pollute the local repo unnecessarily) run first, since downstream modules resolve against it.
- Each affected service/module → `mvn clean compile` (confirms the POM resolves and the module builds against the new parent/dependency set) and, if the ticket's acceptance criteria call for it, `mvn test` (or `{BE_TEST_CMD}`).

**Expand acceptance criteria into atomic items** exactly as in 2b — each criterion should map to one build command + one pass condition (e.g. "parent POM installs cleanly" → `mvn -N install` exits 0; "bom module still builds against parent" → `mvn clean compile` in `bom/` exits 0 with no version override left unintentionally).

Construct and print the **Verification Plan**:

```
## Verification Plan — {TICKET-ID}: {title} (build-only)

**Environment:** build (no browser/API surface)
**Modules under test:** {list of affected repos/modules}

**What was broken:** {one sentence from Actual Behaviour}
**What should be true now:** {one sentence from Expected Behaviour / AC}

### Acceptance criteria (expanded — each item verified independently)
1. {atomic criterion — one observable build fact, e.g. "mvn -N install succeeds for parent"}
2. {atomic criterion}
...

### Build commands
1. `cd {repo} && mvn -N install` — {why}
2. `cd {module} && mvn clean compile` — {why}
...

### Pass criteria
- [ ] {criterion 1 — command exits 0, no unexpected version diffs}
- [ ] {criterion 2}
...
```

If `--from-auto` is NOT set: pause and ask "Does this plan look right? (yes / adjust: ...)". If `--from-auto` IS set: print the plan and proceed directly to Step 4c (skip Steps 3, 4, 4b entirely — there is no browser session to establish).

bash ~/.claude/skills/lib/plog.sh VERIFY build-plan done "{N} criteria (build-only)"

Proceed to **Step 4c** below, skipping Steps 3, 4, and 4b.

---

## Step 4c — Execute build verification (build-only mode only)

**Phase timeout:** same 30-minute wall-clock limit as Step 4b — checkpoint progress, don't crash on timeout.

Run each build command from the Step 2 (build-only variant) plan sequentially, in the worktree for its repo/module. For **every command**:

1. Run the command, capturing stdout+stderr and the exit code:
   ```bash
   L=$(bash ~/.claude/skills/lib/ticket-tmp.sh {TICKET-ID} verify-{step}.log) && cd "{worktree path}" && { {build command} ; } > "$L" 2>&1
   _rc=$?
   ```
2. Record the **observed result** — exit code, and (if relevant to the criterion) whether the expected artifact/version/output string appears in the captured log (e.g. `BUILD SUCCESS`, a specific dependency version resolved, absence of a removed property).
3. If the criterion also requires checking that something did NOT regress (e.g. "module-specific plugin pins were preserved"), diff the relevant POM/build file section against the pre-implementation state noted in `notes.md`, or `grep` for the expected value in the file directly.

**Per-criterion checkpointing:** After EACH criterion passes, write a checkpoint entry exactly as in Step 4b, so a crash resumes from the next criterion:

```bash
bash ~/.claude/skills/lib/plog.sh VERIFY checkpoint done "criterion-{N}-pass"
```

At any point, if a command exits non-zero or the expected output/state is absent, mark that criterion **FAIL** and record:
- The command that was run and its exit code
- What was expected (from the pass criterion)
- What was observed — quote the relevant lines of build output verbatim (last 20–30 lines, or the specific error block)

Continue with the remaining commands unless the failure makes them meaningless (e.g. a failed `mvn -N install` dooms every dependent module's `mvn clean compile` — note it and skip them).

bash ~/.claude/skills/lib/plog.sh VERIFY execute-steps done "{N} build commands executed"

Proceed to Step 5.

---

## Step 7a — Collect diagnostics (build-only mode)

**Build-only mode:** substitute build diagnostics for the browser ones in SKILL.md Step 7a — these map onto the same REMEDIATION_BRIEF fields (7c) so downstream skills don't need mode-specific parsing:
1. **Failed command + exit code** — maps to `CONSOLE_ERRORS` field
2. **Repo/module + branch** — maps to `CURRENT_URL` field (use `{repo}@{branch}` in place of a URL)
3. **Last 20–30 lines of the step's `$L` log** — maps to `SNAPSHOT_EXCERPT`
4. **Failed step** — step number, expected vs. observed (command + exit code)
