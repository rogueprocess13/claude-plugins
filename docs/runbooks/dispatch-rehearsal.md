# Dispatch rehearsal runbook

Take one idea through grill-me → ticket-planner → `--create` → fleet dry-run, and repeat until dispatch has **zero blockers**. Each blocker is fixed at its source, never by hand-editing the generated tickets. The runbook is reusable: copy the checklist for every new idea. The first idea was Conduit-lite (next.md Step 16).

**Contents**
1. Setup (once per idea)
2. Freeze rules
3. Iteration checklist
4. Blocker classes
5. Exit criteria
6. Cleanup

## 1. Setup (once per idea)

- [ ] **Work root.** Pick a dedicated work root and export it:
  - `export WORK=<dir> REPOS_ROOT=<dir>`, where both are the same directory.
  - Only the target repo clone may live under it, because fleet dry-run enumerates every git repo under `REPOS_ROOT` and runs `git fetch` in each.
- [ ] **Target repo.** The clone needs an `origin` remote, because the epic branch step fetches it. Record the clean starting commit in `rehearsal/base.sha`; section 6 resets to it before every full run. Its `CLAUDE.md` carries `REPOS_ROOT`, `LOCAL_URL`/`UAT_URL` and the test users.
- [ ] **Environment checks.** Run `/fleet-controller:fleet-env-check` and `/ticket-auto-pipeline:ticket-env-check`. Fix every problem before iteration 1, so environment issues never count as findings.
- [ ] **Rehearsal folder.** Create `$WORK/rehearsal/`, then:
  - Write the brief to `idea.md`.
  - Record `sha256sum idea.md` in `rehearsal/brief.sha`.
- [ ] **Tracker target.** Decide the team, the project and a tracker label (e.g. `rehearsal`). Every created issue gets that label and an `[R<n>]` title prefix.
- [ ] **Holdout.** Choose a second, unseen idea now. It runs once after the main idea converges.

## 2. Freeze rules

Without these rules, the loop converges by making the input easier or the gates weaker.

- **The brief is frozen after iteration 1.** You may edit it only for a class A finding. That finding must name the grill-me dimension or question that should have caught the gap, and it must ship with a grill-me fix. Log the brief size each iteration; growth needs a stated reason.
- **Grill answers come from the brief and its reference spec only.** Flag any answer drawn from outside them in `findings.md`.
- **Gate changes (class C)** must do three things:
  - add a fixture for the false positive;
  - keep `ticket-auto-pipeline/lib/tests/fixtures/dor/20-28` failing with the same codes;
  - be reviewed by a separate reviewer agent before commit.
- **Negative control, every iteration.** Copy a passing child body and remove one `Source:` line or the Test User credentials. Then confirm `check_ticket_ready` or `check_planned_body` fails on the copy.
- **The clean counter resets to 0** on any code or gate commit.
- **Never** hand-edit a generated ticket, `body.md` or manifest. Never waive a code to get a pass.

## 3. Iteration checklist

Put each iteration's output in `$WORK/rehearsal/iter-NN/`.

- [ ] **grill-me** (full runs only). Run `/grill-me --file idea.md --emit-questions <dir>`. Answer each round with an `--answers` file as the product owner, and archive the round files. Target: verdict `ready`, score ≥ 80.
- [ ] **Plan.** Run `/ticket-planner plan <intent.md>`, then `/ticket-planner resume <INIT> --create --team <T> --project "<P>"`. Any halt is a finding.
- [ ] **Collect.** Copy the following into the iteration folder:
  - `state.log`;
  - the Crosscheck output and `testdata-synth.json`;
  - each child's `body.md` and `manifest.json`, into `tickets/<TID>/`.
- [ ] **Critique each child, read-only:**
  `/ticket-critique <TID> --no-post --result-file iter-NN/preflight/critique/<TID>.txt`
- [ ] **Run the preflight:**
  `scripts/e2e-preflight.sh <INIT> --out iter-NN/preflight`
- [ ] **Run the negative control** (section 2).
- [ ] **Classify** every non-zero row of `preflight.tsv` and every planner halt into `findings.md`, one class each (section 4).
- [ ] **Fix.** Make one commit per fix, each with a regression test. A new `lib/tests` file also needs its Makefile line.
- [ ] **Re-run from the cheapest step** the fix affects (section 4).

## 4. Blocker classes

| Class | Meaning | Fix in | Next run |
|---|---|---|---|
| **A** | The idea really was under-specified | the brief, **and** grill-me (profile or questions) | new full run |
| **B** | The planner emitted a wrong or missing section, Source, credential or Verification Plan row | `ticket-planner/lib/*` or the phase prompts. Use openspec if the change alters what the planner emits | `/ticket-planner replan <INIT>` on the same intent |
| **C** | A gate rejected a correct body | `dor-check.sh`, `gate-check.sh` or critique, following the freeze rules | preflight only, on the same tickets |
| **D** | Environment or harness | setup, or `scripts/e2e-preflight.sh` | the step that failed |

## 5. Exit criteria

The idea passes after **two fresh full runs in a row**, after the last code change, that both satisfy all of the following:

- no planner halt;
- the epic manifest has `dispatch=true`;
- `PREFLIGHT <INIT> PASS`, which means:
  - every per-ticket row has rc 0 (no vacuous gate passes);
  - critique is never BLOCKED;
  - dry-run shows `not_ready 0`, with no `skip` and no `EPIC_BRANCH_UNAVAILABLE`;
  - `blocked-edges` is clean;
- the negative control failed as expected.

Then run the holdout idea once. A class B or C failure there means the fixes overfit to the main idea. Report it; don't loop on it.

**Cap:** 4 full runs per idea. Preflight-only and `replan` reruns don't count toward the cap. At the cap, stop and report what remains.

## 6. Cleanup

- Before each new full run, list the previous run's issues by the rehearsal label and cancel them, but only after a human confirms the list.
- Then mark the previous run's initiative abandoned, so the next run's cross-initiative contract check does not compare against it (iter 02 halted on 5 `CONTRACT_MISMATCH` findings against its own cancelled predecessor):
  `REPOS_ROOT=$WORK bash -c 'source ticket-planner/lib/planner-state.sh; planner_initiative_abandon <INIT> "rehearsal iter NN issues cancelled"'`
- Reset the target repo to its clean starting state before the next full run: `origin`'s default branch at the setup commit, no other branches left by earlier pipeline runs, and the local checkout matching it. Code left on diverged remote branches makes Discovery cite files that are not on the ref it pins, and Crosscheck then reports them all as `CITATION_UNRESOLVED` (iter 02: 31 findings). A reset rewrites the remote, so a human runs it.
- Keep every `iter-NN/` folder so iterations can be diffed (`diff -r`).
- Record the outcome in next.md Step 16. The PR body gets one table row per run: findings by class, preflight failures, brief size and gate fixture results.
