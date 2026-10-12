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

Writers must follow these rules:

- Write the marker as `Source:`, as the **last field** on the line. Everything after it, to the
  end of the line, is the source.
- A value must not contain `|`, a carriage return or a newline. The state log and the ticket's
  Verification Plan table are both `|`-delimited.
- The kind set is **closed**. Any other kind is an error, not an extension point.
- `Test data: none` needs no Source. `Source: none` is only valid on such a line.
- A line may carry more than one `Test data: … Source: …` pair. Each pair is checked on its own.

Readers must be lenient in the same, fixed ways (the Crosscheck parser does all of these;
#505 should match):

- The `Test data` and `Source` markers match case-insensitively. `Test Data:`, `Test-data:`,
  `**Test data:**` and `_Source:_` all count. Markdown `*` is removed from the line, and `_` is
  removed where it wraps a word.
- When a pair holds more than one `Source:`, the **last** one wins.
- Backticks around the source are ignored. Trailing `.`, `,`, `;`, `:` and `!` are stripped. The
  kind is lowercased.
- The section heading matches by prefix, so `## Verification Notes (per AC)` and
  `### Verification Notes` both count. The section ends at the next heading. Fenced code blocks
  are ignored.
- Numbered items (`1.`, `1)`) and bullets (`-`, `*`, `+`) are both need lines. A bullet is
  labelled `b<k>` in findings.
- These "none" phrasings mean no test data, matched case-insensitively at the start of the
  value: `none`, `none (…)`, `n/a`, `na`, `-`, `nothing`, `not applicable`,
  `no special data…`, `no special test data…`, `no test data…`, `no data required`,
  `no data needed`, `no setup`, `no special setup`.

### Meaning — owned or unowned

| Source | Owned when | Notes |
|---|---|---|
| `exists:<where>` | `<where>` is non-empty | Data already exists (an environment's seed set, a path, a named record). Not verified on disk. |
| `seeded-by:<slug>` | `<slug>` resolves to a sibling spec (exact slug, or the unambiguous `-`-bounded prefix of exactly one — the same rule as `blocked-by:`) **and** that spec has a non-empty `## Test Data Provided` section; or `<slug>` is an existing tracker identifier (`ABC-123`), a cross-initiative pack | A spec naming itself is **self-seeded**: owned, except under the no-tests rule (below). |
| `external:<who>` | `<who>` is non-empty | Someone outside the plan supplies it, and the source material says who. |
| `generate` | never | Has to be synthesised, and no spec does it. |
| missing | never (unless Test data is none) | |

The remedy for unowned data is a **test-data-pack** enabler spec (`Kind: enabler`) whose
`## Test Data Provided` section lists the generator and seed scripts it delivers. Each
affected need changes to `Source: seeded-by:<pack-slug>`, which is its verification
prerequisite.

### The no-tests rule

Some projects have a standing rule that implementation does not write tests. Then no fixture
appears as a side effect of implementation, so self-seeding does not count as ownership and
the test-data-pack spec is mandatory.

The rule is decided once, at argument parsing, and persisted as the `no-tests-rule` config key
(`META|no-tests-rule|done|true|false`). Phases read it back with `planner_config_get` and never
read the environment.

1. `--no-tests-rule` / `--no-tests-rule=false` decides it, and so does `PLANNER_NO_TESTS_RULE`,
   which is read once at parse time. The flag always overwrites the stored value.
2. Otherwise, the first `plan`/`resume` scans `${REPOS_ROOT}/CLAUDE.md` and
   `${REPOS_ROOT}/*/CLAUDE.md` once, and stores `true` or `false`. The scan looks for an
   **unscoped** rule: a negation, then write/add/create/author, then optional
   any/unit/automated/integration/e2e, then `tests` (or `test code`/`test files`/
   `test fixtures`), ending the clause (`.`, `;`, `!` or end of line).
   - Matches: "Implementation does not write tests.", "Never add unit tests."
   - No match: "Do not write tests for generated code", "Don't write tests that hit the
     network".
3. Where the rule came from is written as `META|no-tests-rule-source|info|<flag or file:line: text>`.
   The finding quotes it.

### Legacy initiatives

`planner_state_init` writes `META|contract|start|test-data-source-v1` to every initiative it
creates from ticket-planner 0.17.0 on.

- **Initiatives with the marker:** every unowned need blocks.
- **Initiatives without the marker** (created by an earlier planner):
  - A spec whose Verification Notes contain **no** `Source:` field at all is grandfathered. Its
    needs are reported as the warn-level `TEST_DATA_UNSOURCED_LEGACY`.
  - A spec that carries at least one `Source:` is held to the contract and blocks.

### Crosscheck codes

- `TEST_DATA_UNOWNED` — blocking, cross-file. One finding per initiative. It lists every unowned
  need as `<spec>.md#<label> (<reason>)` (at most 25, then `… and N more`), the affected spec
  slugs in `[…]`, and the test-data-pack remedy. Under the no-tests rule the remedy is prefixed
  `MANDATORY`. A `generate` need that names a cited artifact the operator has not answered yet
  is left to `CITED_ARTIFACT_UNRESOLVED`. Override with
  `resume <ID> --accept TEST_DATA_UNOWNED:"reason"` only when the data genuinely is handled
  outside the plan.
- `TEST_DATA_UNSOURCED_LEGACY` — warn, cross-file. Same shape, for grandfathered specs.

### For #505 (ticket-auto-pipeline `dor-check.sh`)

A ticket body consumer should treat a `## Test Data Prerequisites` bullet as one of three:

- **Sourced:** its Source is `exists:<non-empty>`, `seeded-by:<slug>` or `external:<non-empty>`.
- **Unsourced:** it has no `Source:`, `Source: generate`, an unknown kind, or an empty value.
- **Not applicable:** the bullet says the test data is none (the phrasings above).

At ticket level, `seeded-by:<slug>` cannot be resolved against specs, because the specs live
with the initiative, not the ticket. Its presence is enough there; Crosscheck already checked
the reference at plan time.

## 2. Cited artifacts

### discovery.md — `## Cited Artifacts`

Discovery lists every external artifact the source material cites (a sample file, a template,
an export, an attachment). It first tries the source's attachments, the initiative
`artifacts/` folder, and `REPOS_ROOT`:

```
## Cited Artifacts

- `client sample import file (43 rows)` — NOT FOUND (searched: source page attachments, artifacts/, REPOS_ROOT)
- `import template v2` — FOUND: docs/import-template-v2.xlsx
```

- Each artifact is one list item, bulleted or numbered. The name is the backticked string, or,
  without backticks, the text before the separator (`—`, `–` or ` - `). The name is the match
  key.
- The **status token** is the first word(s) after the separator, matched case-insensitively:
  `NOT FOUND` or `FOUND`. It is not a substring search, so `FOUND: docs/NOT FOUND list.xlsx` is
  FOUND.
- A list item with no name or no status token is reported as `CITED_ARTIFACT_MALFORMED`
  (blocking). It is not skipped.
- `None.` means nothing is cited.

### consensus.md — `## Open Questions`

`planner_cited_artifacts_questions <id>` renders one line per NOT FOUND artifact. The
Consensus agent copies it verbatim:

```
- CITED_ARTIFACT: `<name>` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING
```

The operator replaces `PENDING` with one of these. The answer sets what the Source must be in
every spec whose Test data names the artifact (its backticked name, or the whole name as a
case-insensitive substring):

| Answer | Meaning | Required spec Source |
|---|---|---|
| `PENDING` (unanswered) | — | `generate` |
| `exists:<where>` | They supplied it; it is now at `<where>` | `exists:<where>` (same value, case-insensitive) |
| `external:<who>` | `<who>` will supply it | `external:<who>` (same value, case-insensitive) |
| `generate` | Synthesise it | `generate` or `seeded-by:<pack-slug>` (a `generate` Source then blocks as TEST_DATA_UNOWNED until a pack owns it) |

- Question lines are matched to discovery.md by name, case-insensitively, anywhere in
  consensus.md.
- The answer is the text after the last `Answer:` on the line, with backticks and `*` removed.
- The Consensus agent never pre-fills a spec with `external:<who>`, because it would be
  inventing the `<who>`.

### Crosscheck codes

- `CITED_ARTIFACT_MALFORMED` — blocking. A `## Cited Artifacts` item cannot be parsed.
- `CITED_ARTIFACT_UNRAISED` — blocking. A NOT FOUND artifact has no `CITED_ARTIFACT:` line in
  consensus.md.
- `CITED_ARTIFACT_UNRESOLVED` — blocking. The line exists, but the answer is `PENDING`, empty, or
  not one of the shapes above.
- `CITED_ARTIFACT_SOURCE_MISMATCH` — blocking. A spec's Source for the artifact disagrees with the
  answer, per the table above.
- `CITED_ARTIFACTS_SECTION_MISSING` — warn. discovery.md has no `## Cited Artifacts` section in an
  initiative that carries the contract marker. Legacy initiatives are not checked.

All of these use the existing Crosscheck stop. The run halts at Crosscheck, and
`planner-stop-describe.sh` reports `CROSSCHECK_BLOCKED` with one question per code. For a
`CITED_ARTIFACT_*` code the question lists every artifact the code covers. To continue, the
operator does one of two things:

- Edits consensus.md (and the matching spec Sources), then resumes.
- Accepts the code with `--accept` / `--answers`. This is a blanket override for that code.

A per-artifact headless answer binding (`consensus-answer:<name>`) is not implemented yet.

All finding messages have `|`, CR and LF removed before they reach the state log.
