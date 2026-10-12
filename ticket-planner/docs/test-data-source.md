# Test-data Source field and cited artifacts — contract

Issues [#503](https://github.com/willard-pro/claude-plugins/issues/503) (test-data provenance) and
[#504](https://github.com/willard-pro/claude-plugins/issues/504) (cited external artifacts).
This file is the contract for the grammars below. The planner writes them; Crosscheck
(`lib/planner-crosscheck-testdata.sh`) parses them; ticket-auto-pipeline's readiness check
(`dor-check.sh`, follow-up issue #505) reads the same `Source:` grammar from ticket bodies.
Change any of them here first, and keep the parsers in step.

## Why

A Verification Notes line used to record what data a criterion needs, never where it comes
from. "Described" could not be told apart from "available". Every per-ticket test-data check
passed while no spec produced the data, and the gap only showed at verification time.

## 1. The `Source:` field

### Where it appears

| Location | Written by | Shape |
|---|---|---|
| Spec `## Verification Notes`, one numbered line per acceptance criterion | Specify | `<n>. Role: <role>. Test data: <what>. Source: <source>.` |
| Ticket `## Test Data Prerequisites`, one bullet per item | TicketGen (copied from the spec) | `- <what>. Source: <source>` |
| Ticket `## Verification Plan` table, `Test data needed` cell | TicketGen | `<what> (Source: <source>)` |

### Grammar

```
source      := kind [ ':' value ]
kind        := 'exists' | 'seeded-by' | 'external' | 'generate' | 'none'
value       := for exists:    <where>   free text, non-empty
               for seeded-by: <slug>    [A-Za-z0-9_-]+ — a spec slug, or an existing tracker id
               for external:  <who>     free text, non-empty
               generate, none take no value
```

- The marker is `Source:` (case-insensitive on input; the planner writes `Source:`). It is the
  **last field** on the line: everything after it, to the end of the line, is the source.
- Backticks around the source are allowed and ignored. One trailing `.` is ignored.
- The kind set is **closed**. Any other kind is an error, not an extension point.
- `Test data: none` (also `none (…)`, `n/a`, `-`) needs no Source. `Source: none` is only
  valid on such a line.
- A line may carry more than one `Test data: … Source: …` pair; each pair is checked on its own.

### Meaning — owned or unowned

| Source | Owned when | Notes |
|---|---|---|
| `exists:<where>` | `<where>` is non-empty | Data already exists (an environment's seed set, a path, a named record). Not verified on disk. |
| `seeded-by:<slug>` | `<slug>` resolves to a sibling spec (exact slug, or the unambiguous `-`-bounded prefix of exactly one — the same rule as `blocked-by:`) **and** that spec has a non-empty `## Test Data Provided` section; or `<slug>` is an existing tracker identifier (`ABC-123`), a cross-initiative pack | A spec naming itself is **self-seeded**: owned, except under the no-tests rule (below). |
| `external:<who>` | `<who>` is non-empty | Someone outside the plan supplies it. |
| `generate` | never | Has to be synthesised, and no spec does it. Always unowned. |
| missing | never (unless Test data is none) | |

The remedy for unowned data is a **test-data-pack** enabler spec (`Kind: enabler`) whose
`## Test Data Provided` section lists the generator and seed scripts it delivers. Each
affected need changes to `Source: seeded-by:<pack-slug>`, which is its verification
prerequisite.

### The no-tests rule

Some projects have a standing rule that implementation does not write tests. Then no fixture
appears as a side effect of implementation, so self-seeding does not count as ownership and
the test-data-pack spec is mandatory. Detection (`planner_testdata_no_tests_rule`):

1. `PLANNER_NO_TESTS_RULE=true|false` decides outright.
2. Otherwise, the rule is on when `${REPOS_ROOT}/CLAUDE.md` or any `${REPOS_ROOT}/*/CLAUDE.md`
   contains a negation followed by write/add/create/author … tests, e.g. "Implementation does
   not write tests", "never add unit tests", "must not create test fixtures"
   (`PLANNER_TESTDATA_NO_TESTS_RE`).

### Crosscheck code

`TEST_DATA_UNOWNED` — blocking, cross-file. One finding per initiative, listing every unowned
need as `<spec>.md#<line-number> (<reason>)`, the affected spec slugs in `[…]`, and the
test-data-pack remedy (prefixed `MANDATORY` under the no-tests rule). Override with
`resume <ID> --accept TEST_DATA_UNOWNED:"reason"` only when the data genuinely is handled
outside the plan.

### For #505 (ticket-auto-pipeline `dor-check.sh`)

A ticket body consumer should treat a `## Test Data Prerequisites` bullet as:

- **sourced** — it carries `Source: exists:<non-empty>`, `Source: seeded-by:<slug>`, or
  `Source: external:<non-empty>`;
- **unsourced** — no `Source:`, `Source: generate`, an unknown kind, or an empty value;
- **not applicable** — the bullet says the test data is `none`.

At ticket level, `seeded-by:<slug>` cannot be resolved against specs (the specs live with the
initiative, not the ticket), so its presence is enough there. Crosscheck already checked the
reference at plan time.

## 2. Cited artifacts

### discovery.md — `## Cited Artifacts`

Discovery lists every external artifact the source material cites (a sample file, a template,
an export, an attachment), after trying the source's attachments, the initiative
`artifacts/` folder, and `REPOS_ROOT`:

```
## Cited Artifacts

- `client sample import file (43 rows)` — NOT FOUND (searched: source page attachments, artifacts/, REPOS_ROOT)
- `import template v2` — FOUND: docs/import-template-v2.xlsx
```

- One bullet per artifact. The name is the first backtick-quoted string. It is the match key.
- A bullet containing `NOT FOUND` (upper case) is not retrievable. Anything else is found.
- `None.` when nothing is cited. If the section is missing (older initiatives), the check is skipped.

### consensus.md — `## Open Questions`

`planner_cited_artifacts_questions <id>` renders one line per NOT FOUND artifact, and the
Consensus agent copies it verbatim:

```
- CITED_ARTIFACT: `<name>` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING
```

The operator replaces `PENDING` with:

| Answer | Meaning | Spec Source for the data |
|---|---|---|
| `exists:<where>` | They supplied it; it is now at `<where>` | `exists:<where>` |
| `external:<who>` | `<who>` will supply it | `external:<who>` |
| `generate` | Synthesise it | `seeded-by:<pack-slug>` (a `generate` Source blocks as TEST_DATA_UNOWNED) |

Lines are matched to discovery.md by name (case-insensitive) anywhere in consensus.md. The
text after the last `Answer:` on the line is the answer.

### Crosscheck codes

- `CITED_ARTIFACT_UNRAISED` — blocking. A NOT FOUND artifact has no `CITED_ARTIFACT:` line in consensus.md.
- `CITED_ARTIFACT_UNRESOLVED` — blocking. The line exists but the answer is `PENDING`, empty,
  or not one of the three shapes above.

Both use the existing Crosscheck stop: the run halts at Crosscheck, `planner-stop-describe.sh`
reports `CROSSCHECK_BLOCKED`, and the operator either edits consensus.md (and the matching
spec Sources) and resumes, or accepts the code with `--accept` / `--answers`. There is no new gate.
