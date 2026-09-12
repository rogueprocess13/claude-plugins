# ADR store fixture

A small, deliberately-valid ADR store (`decisions/*.md` + `decisions/index.md`)
checked into the repo rather than generated ephemerally in a test's `mktemp -d`.

Two things this pins that the ephemeral-tmpdir unit tests (`test-adr-store.sh`,
`test-adr-check.sh`) do not:

1. **A CI step (`.github/workflows/test.yml`, "ADR store fixture validation")
   runs `lib/adr-check.sh --wiki-root` against this directory directly** — a
   regression check independent of the bash test harness, so a change that
   breaks the validator's happy path on a real, committed store fails CI even
   if every ephemeral-fixture unit test still passes for some other reason.
2. **A browsable, working example of the schema** (`docs/adr-schema.md`) that
   a reader — human or agent — can open without running anything: an
   `accepted` ADR (`0003`), a `proposed` one (`0002`), and a `superseded`/
   supersedes pair (`0001` → `0003`), covering supersession reciprocity too.

`ADR-0001`'s reciprocal supersession by `ADR-0003` is why this store's ADRs are
committed with `status: accepted`/`status: superseded` from their first commit
rather than starting `proposed` — `adr-check.sh`'s `NEW_ADR_NOT_PROPOSED` check
only applies to a file with no prior commit touching it (design.md,
`_ac_check_new_is_proposed`), so once this fixture is committed the check no
longer fires. All content here is invented (component names, ticket ids,
decisions) — none of it is a real decision made about this repository.
