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
| Spec `## Verification Notes` table, one row per acceptance criterion (current form, #499) | Specify | `\| <criterion> \| <role> \| <what> \| <source> \| … \|` — a `Source` column right after `Test data` |
| Spec `## Verification Notes`, one numbered line per acceptance criterion (earlier form, still parsed) | Specify | `<n>. Role: <role>. Test data: <what>. Source: <source>.` |
| Ticket `## Test Data Prerequisites`, one bullet per item | TicketGen (`planner_ticketgen_testdata_prereqs`, generated from the table) | `- <what>. Source: <source>` |
| Ticket `## Verification Plan` table, `Test data needed` cell | TicketGen (`planner_ticketgen_vplan`) | `<what> (Source: <source>)` |

The table form looks like this:

```
## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Export downloads a file named invoices-{date}.csv | finance user | 5 seeded invoices with distinct dates | seeded-by:inv-0-test-data-pack | Billing > Invoices | invoices-2026-09-30.csv downloaded | yes |
| The invoice list looks uncluttered | any authenticated user | none | — | Billing > Invoices | needs human judgement | no |
```

Both TicketGen outputs are generated in bash from the table, so the ticket body carries
exactly what the spec recorded. `## Test Data Prerequisites` lists the need of **every** data
row (deduplicated, table order) — the same needs Crosscheck checked, including a row whose
criterion repeats another row's or no longer matches an AC. A `## Test Data Prerequisites`
section hand-written in the spec is replaced by the generated one, so every item in it must
be a need some table row records; an item the table lacks is refused (by Crosscheck and by
TicketGen), never dropped. A spec with no table (an earlier, numbered-line spec) keeps its own
section, copied as written. When no criterion needs test data, the generated section is the
single bullet `- None — no acceptance criterion needs test data.`

### One reader, and the shapes it refuses

Crosscheck (`planner-crosscheck-testdata.sh`) and the TicketGen composer
(`planner-ticket-body.sh`) read Verification Notes with the **same code**:
`_planner_testdata_section` (the section), `_planner_testdata_notes_table` (the table) and
`_planner_testdata_cell_need` (one row's need). The composer renders the Source that parser
returned, in canonical `kind[:value]` form, so the ticket carries exactly what Crosscheck
checked.

Both also refuse, through `_planner_testdata_notes_problems`, every shape on which two
Markdown readers could still disagree. Crosscheck reports each as a blocking
`TEST_DATA_UNOWNED` item `<spec>.md#notes (<reason>)` — in legacy initiatives too — and
TicketGen refuses the spec:

- more than one heading that reads as Verification Notes, at any level, fenced or not, after
  folding Unicode whitespace look-alikes (NBSP, zero-width spaces);
- such a heading the reader would not see: fenced, `#` or `####`, no space after the hashes,
  or a Unicode space inside;
- a code fence or a sub-heading inside the section (up to the next heading of the same or a
  higher level) — a fenced table, or one after a `###`, would otherwise be invisible to one
  reader;
- a second table, or a table split by a blank or other line;
- a table without both a `Criterion` and a `Test data` column, or a row whose cell count
  differs from the header's (a missing or extra cell shifts the Source column);
- a table mixed with numbered/bullet `Test data:` lines;
- a hand-written `## Test Data Prerequisites` item no table row records.

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

- In the table form, write the source in the row's `Source` cell, bare (`seeded-by:pack`).
  Write `—` there when the test data is `none`.
- In the numbered-line form, write the marker as `Source:`, as the **last field** on the
  line. Everything after it, to the end of the line, is the source.
- A value must not contain `|` (not even escaped as `\|`), a carriage return or a newline.
  Crosscheck blocks a Source value containing `|`. The state log and the ticket's
  Verification Plan table are both `|`-delimited.
- The kind set is **closed**. Any other kind is an error, not an extension point.
- `Test data: none` needs no Source. `Source: none` is only valid on such a line.
- A numbered line may carry more than one `Test data: … Source: …` pair. Each pair is checked
  on its own. A table row carries one need.

Readers must be lenient in the same, fixed ways (the Crosscheck parser does all of these;
#505 should match):

- The `Test data` and `Source` markers match case-insensitively. `Test Data:`, `Test-data:`,
  `**Test data:**` and `_Source:_` all count. A marker must not follow a letter:
  `Resource:` and `Latest data:` are prose. Markdown `*` is removed from the line, and `_` is
  removed where it wraps a word.
- When a pair holds more than one `Source:`, the **last** one wins.
- Backticks around the source are ignored. Trailing `.`, `,`, `;`, `:` and `!` are stripped. The
  kind is lowercased.
- The section heading matches by prefix (`*`/`_` ignored), so `## Verification Notes (per AC)`
  and `### Verification Notes` both count. The section ends at the next heading. Fenced code
  blocks (``` or ~~~) are ignored — and refused inside the section (above).
- Numbered items (`1.`, `1)`) and bullets (`-`, `*`, `+`) are both need lines. A bullet is
  labelled `b<k>` in findings.
- Table rows are need lines too. The header row locates the columns by name (lowercased,
  `*`/`_`/backticks removed, prefix match): `Test data` and the optional `Source`. A table
  with no `Test data` column is ignored. Each data row is one need, labelled by its 1-based
  row number. The Source cell may be bare (`generate`) or carry the marker
  (`Source: generate`). A Test data cell may also carry the Source inline
  (`the price list. Source: external:pricing team`); a non-empty Source cell wins over it.
  A Source cell of `-`, `—`, `–` or `n/a` is an empty cell. `\|` in a cell is a literal pipe.
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
| `generate` | when Crosscheck's synthesis owns it (§3.4) | Has to be synthesised. Synthesis writes a TD spec for it and records an override `seeded-by:<td-slug>` in the sidecar; it stays unowned only when synthesis cannot take it (a cited artifact still waiting on its answer). |
| missing | never (unless Test data is none) | |

Specify never hand-writes a test-data-pack spec. An unowned need is written as
`Source: generate`, and Crosscheck's synthesis sub-step (§3.4) writes the test-data (TD) spec
that owns it.

### The no-tests rule

Some projects have a standing rule that implementation does not write tests. Then no fixture
appears as a side effect of implementation, so self-seeding does not count as ownership and
a synthesized TD spec (or an `exists:`/`external:` Source) is mandatory.

The rule is decided once, at argument parsing, and persisted as the `no-tests-rule` config key
(`META|no-tests-rule|done|true|false`). Phases read it back with `planner_config_get` and never
read the environment.

1. `--no-tests-rule` / `--no-tests-rule=false` decides it, and so does `PLANNER_NO_TESTS_RULE`,
   which is read once at parse time. The flag always overwrites the stored value.
2. Otherwise, the first `plan`/`resume` scans `${REPOS_ROOT}/CLAUDE.md` and
   `${REPOS_ROOT}/*/CLAUDE.md` once, and stores `true` or `false`. The scan looks for an
   **unscoped** rule. It is built from these parts, in order:
   - a negation (`do not`, `don't`, `never`, `must not`, …);
   - write/add/create/author, optionally followed by `or` write/add/create/modify;
   - optionally any/unit/automated/integration/e2e;
   - `tests` (or `test code`/`test files`/`test fixtures`);
   - the end of the clause: `.`, `;`, `:`, `,`, `!`, the end of the line, or
     `when implementing`/`when implementation`.

   Examples:
   - Matches: "Implementation does not write tests.", "Do not write or add tests when
     implementing tickets.", "Implementation agents must not write tests: QA owns them.",
     "Never write tests, QA owns them."
   - No match: "Do not write tests for generated code", "Don't write tests that hit the
     network".

   The scan is a convenience heuristic and can miss unusual wording. **`--no-tests-rule` is the
   reliable route**: pass it on the first `plan` when the project has the rule.
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
  slugs in `[…]`, and the remedy (a valid Source — `generate` lets synthesis own it; never a
  hand-written pack). Under the no-tests rule the remedy is prefixed
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
- `None.` means nothing is cited. A bullet that starts with `none` or `no ` and talks about
  artifacts, external items or files (for example "None — no external artifacts are cited.")
  is also a none-statement and is skipped, unless it carries a FOUND / NOT FOUND status.

### consensus.md — `## Open Questions`

`planner_cited_artifacts_questions <id>` renders one line per NOT FOUND artifact. The
Consensus agent copies it verbatim:

```
- CITED_ARTIFACT: `<name>` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING
```

The operator replaces `PENDING` with one of these. The answer sets what the Source must be in
every need that **cites** the artifact. A need cites an artifact only through a backticked span
in its Test data that equals the artifact's name. Both sides are normalised before comparing:
lowercased, en and em dashes treated as `-`, whitespace runs collapsed, and trailing `.,;:!`
stripped. Only a real need counts as a citation, meaning one with a Source whose test data is
not `none`. Prose mentions are
never matched. With substring or word matching, "a seeded email template record" would cite an
artifact called `template`, and `sample` would match inside `sample file v2`.

| Answer | Meaning | Required spec Source |
|---|---|---|
| `PENDING` (unanswered) | — | `generate` |
| `exists:<where>` | They supplied it; it is now at `<where>` | `exists:<where>` (same value, case-insensitive) |
| `external:<who>` | `<who>` will supply it | `external:<who>` (same value, case-insensitive) |
| `generate` | Synthesise it | `generate` or `seeded-by:<pack-slug>` (a `generate` Source is then owned by synthesis, §3.4) |

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
- `CITED_ARTIFACT_SOURCE_MISMATCH` — blocking. A need that cites the artifact has a Source that
  disagrees with the answer, per the table above.
- `CITED_ARTIFACT_UNREFERENCED` — blocking, only in initiatives that carry the contract marker
  and have at least one spec. No Verification Notes need in any spec cites a NOT FOUND artifact
  by its backticked name. A paraphrase ("the client sample file") would otherwise slip past
  `CITED_ARTIFACT_SOURCE_MISMATCH`. If no spec genuinely needs the artifact, `--accept` the code.
- `CITED_ARTIFACTS_SECTION_MISSING` — warn. discovery.md has no `## Cited Artifacts` section in an
  initiative that carries the contract marker. Legacy initiatives are not checked.

All of these use the existing Crosscheck stop. The run halts at Crosscheck, and
`planner-stop-describe.sh` reports `CROSSCHECK_BLOCKED` with one question per code. For a
`CITED_ARTIFACT_*` code the question lists every artifact the code covers. To continue, the
operator does one of three things:

- Edits consensus.md (and the matching spec Sources), then resumes.
- For `CITED_ARTIFACT_UNRESOLVED`, answers each artifact's own headless question (#515). There
  is one per unanswered artifact, bound `consensus-answer:cited:<n>`, where `n` is the 1-based
  position of the artifact's `CITED_ARTIFACT:` line in consensus.md (the last line for that
  name, the one Crosscheck reads). The index stands in for the name, which can contain spaces
  and parentheses. The answer must be `exists:<where>`, `external:<who>` or `generate`;
  anything else, or a value with `|`, CR, LF, another control character, a backtick, `*`, a
  second `Answer:` or trailing punctuation, is rejected with nothing written.
  `resume --answers` rewrites only that line's `Answer:` field.
- Accepts the code with `--accept` / `--answers`. This is a blanket override for that code.

**Spec Sources are not rewritten by an answer.** A spec need that cites the artifact and still
says `Source: generate` after an `exists:`/`external:` answer is reported as
`CITED_ARTIFACT_SOURCE_MISMATCH` on the re-run. That finding names the spec, the need and the
Source it needs. The planner relies on this check instead of editing the spec for three
reasons. Specify writes Sources in two layouts (numbered lines and a table column). One need
can cite more than one artifact. And a silent bash rewrite of a spec would hide a real
disagreement between the spec and the answer. An answer of `generate` matches a spec that
already says `generate`, so it re-runs without a mismatch. Synthesis then owns it, as for any other
`generate` need.

All finding messages have `|`, CR and LF removed before they reach the state log.

## 3. Test-data derivation and synthesis (planner-test-data-derivation)

Sections 1–2 catch data that is described but unsourced. This section covers data nobody
described, and data nobody produces.

### 3.1 discovery.md — `## Test Data Inventory`

Discovery writes one epic-wide table of everything the acceptance tests need to exist beforehand:

```
| Entity | States/variants | Roles | Volume | Source | Load via | Privacy |
|--------|-----------------|-------|--------|--------|----------|---------|
| invoice | draft, overdue, paid | finance user | 5 per state | exists:staging seed set | sql | synthetic |
```

- `Entity` is one short lowercase singular noun. It is the shared vocabulary: Specify names it
  in backticks, and Crosscheck matches criteria against it (`planner_testdata_inventory_entities`).
- `Source` uses the closed kinds of §1. `Load via` is one of `sql`, `api`, `ui-forms`, `files`,
  `factories`. `Privacy` is `synthetic` or `masked` — never production personal data.
- `TEST_DATA_INVENTORY_MISSING` (warn) — the section is absent in a contract initiative. Silent
  when discovery.md itself is absent, and for legacy initiatives.

Specify derives each Verification Notes row from the criterion's Given/precondition and When
inputs, names inventory entities in backticks, writes `none` only when nothing must exist
beforehand, and writes `Source: generate` for data no one produces yet.

### 3.2 Tripwires

- `VERIFICATION_NOTES_MISSING` — blocking. A spec with ≥1 `## Acceptance Criteria` item has no
  Verification Notes table rows. Enabler and synth-marked specs are exempt. Legacy initiatives
  get the warn variant `VERIFICATION_NOTES_MISSING_LEGACY`.
- `TEST_DATA_IMPLIED` / `TEST_DATA_IMPLIED_WEAK` — every row of a spec says `none`, yet a
  criterion implies data. One finding per spec, on the first strong criterion (else the first weak):
  - **strong** (blocks): an inventory or backticked entity; existing/seeded/pre-existing state;
    "given a/an/the … with"; "when there are"; a count followed by an entity noun; list, filter,
    search or export over an entity.
  - **weak** (warns): a count followed by a non-entity noun, or a state word
    (`PLANNER_TESTDATA_STATE_WORDS`: overdue, archived, pending, …) with no entity.
  - **never**: a count followed by a unit on `PLANNER_TESTDATA_UNIT_DENYLIST` (minutes, seconds,
    ms, hours, days, attempts, requests, retries, times, bytes/kb/mb/gb, characters, px, percent,
    `%`), or a 1xx–5xx count next to http/status/returns. "exists" before
    behaviour/code/tests/api is not data.
  - In legacy initiatives a strong match is reported as `TEST_DATA_IMPLIED_WEAK`.

  Message shape: `<slug>.md [<hash8>] match="<phrase>" (<tier>: <reason>) — …`.

### 3.3 consensus.md — `TESTDATA_CONFIRM`

An implied-data question is answered with one persisted line (any `##` section; appended under
`## Test Data Confirmations` when none exists):

```
- TESTDATA_CONFIRM: `<slug>` [<hash8>] — Answer: <value>
```

- `hash8` = first 8 hex of sha256(`<slug>` LF `<trigger criterion, trimmed, CR stripped>`)
  (`planner_testdata_confirm_hash`). A rewritten trigger criterion changes the hash, so the old
  answer is ignored and the question is asked again.
- `value` is `none`, `generate: <description>`, `exists:<where>` or `external:<who>`
  (`planner_testdata_answer_normalize`: strips `|`, CR, LF, backticks; rejects empty, bare
  `generate` or an empty description; capped at 256 chars).
- Any well-formed answer with the current hash suppresses `TEST_DATA_IMPLIED`. `generate:`
  becomes a synthesis need; `exists:`/`external:` becomes the Source of the trigger
  criterion's row (`planner_testdata_spec_effective_needs`); `none` changes nothing else.
- Headless: `planner-stop-describe.sh` asks one question per blocking `TEST_DATA_IMPLIED` spec,
  id `testdata-<slug>-<hash8>`, binding `consensus-answer:testdata:<slug>`, default
  `generate: <match phrase>`. `planner-answers.sh` re-derives the hash at intake (a mismatch is
  `STALE_QUESTION`, exit 2) and writes the line with `planner_testdata_answer_set`.

### 3.4 Synthesis — the `testdata-synth` sub-step

`planner_testdata_synthesize` (`lib/planner-testdata-synth.sh`) runs at the start of every
Crosscheck, bracketed `Crosscheck|testdata-synth|start` / `done|<N> TD spec(s), <M> need(s)`,
before every check family. It is a full, idempotent recompute in bash:

- **Needs**: `generate` rows (not waiting on an unanswered cited artifact) plus `generate:`
  answers. `exists:`/`external:`/`seeded-by:` rows are never synthesized.
- **Grouping**: key = the inventory entity the data names, else its normalised text. A key two
  or more consumers share → one `<prefix>-test-data-pack`; a key one consumer uses →
  `<consumer>-test-data`. Record keys are `td-<init>-<n>`, stable across runs.
- **Recompute**: marked TD specs with no ticket manifest (`.intents/ticket-<slug>.json`) are
  deleted and regenerated; a dispatched TD spec is never rewritten and keeps the needs its
  `## Test Data Provided` lists. An unmarked file at a TD slug fails the run as
  `TEST_DATA_SYNTH_FAILED <slug>.md already exists…` (blocking); families still run.
- **Sidecar** `artifacts/testdata-synth.json`:
  `{version, td_specs[{slug,kind,keys,consumers,dispatched}], overrides[{consumer,criterion,data,record,source}], edges[{consumer,blocked_by}]}`.
  Consumer specs are never edited. The testdata walker and TicketGen's composer apply the
  overrides (`generate` → `seeded-by:<td-slug>`); `planner_ticketgen_spec_deps` unions the edges
  with Labels refs. `DEPENDENCY_CYCLE` (blocking) checks the combined graph. TD specs are listed
  in `INDEX.md`.

**TD spec template** (marker `<!-- planner:testdata-synth v1 -->`): Labels `planned, INIT-<id>,
chore`; Signals Kind `enabler`, `Priority: High` (TicketGen sends Linear priority 2), Strategy
`Conservative`, confidence signals that derive `Pre-approved: true`; a `## Seed Commands` section:

```
Seed command: make seed-<slug>
Verify command: make verify-seed-<slug>
Seed channel: <sql|api|factories|files|ui-forms, from the needs' Load via; default factories>
```

plus `## Test Data Provided` (one bullet per need: record key, data, consumer criterion), ACs for
an idempotent seed (exit 0 twice), a passing verify, referential integrity, synthetic/masked data,
`make reset-seed-<slug>` and a README key map, and Verification Notes rows all `none`. Seed and
Verify commands **must** be `make <target>` (or `make -C <relpath> <target>`) — the only shape
seed-apply runs. The test-data-engineer persona implements the ticket through the seed channel.

**Epic UAT**: when the sidecar lists a TD spec and the epic uses a shared branch, EpicGen stamps
`**UAT Policy:** epic` unless the `uat-policy` config key (`PLANNER_UAT_POLICY`, `per-ticket|epic`,
persisted at parse time) says otherwise.

### 3.5 ticket-auto — seed-apply and enforcement

- **VERIFY Step 1.6c** (`ticket-auto-pipeline/lib/seed-apply.sh`): before acceptance testing,
  for each *merged* `blocked_by` parent whose local planner `body.md` carries `Seed command:`,
  run the seed then verify `make` target in the verify worktree (no shell, no tracker read).
  Logs `VERIFY|seed-apply|start|done|skip|fail`; a failure writes
  `META|gate-stop|fail|VERIFY_SEED_FAILED — <msg>` and holds the ticket.
- **dor-check**: on a contract body (a known-kind Source anywhere), `TEST_DATA_MISSING` and
  `TEST_DATA_UNSEEDED` are hard; chore and security are exempt; `DOR_STRICT_TEST_DATA=false`
  demotes them, and legacy bodies stay advisory unless it is `true`. The planner's Refinement
  scan runs with `DOR_STRICT_TEST_DATA=true DOR_STRICT_VPLAN=true`.
- **body-check**: planned feature and improvement bodies need a non-empty `## Test Data…`
  section (not `Provided`). TicketGen always writes it — `- None — no acceptance criterion needs
  test data.` when nothing does.
- **Semantic backstop (advisory)** (dor-semantic-test-data-gap): the §3.2 heuristic only sees
  criteria whose wording names data. A criterion that implies data without naming it ("Duplicating
  a handover from the list creates a draft copy with the same line items") slips through, and an
  all-`none` body carries no `Source:`, so dor-check treats it as legacy and stays quiet too. The
  Refinement phase's semantic evaluator (`dor-semantic-v2`) catches that case with
  `TEST_DATA_GAP`: the finding quotes the criterion and names the missing data. It is advisory
  only — fixed in code, never blocking — and Refinement reports it as a
  `META|refinement-testdata|warn` line and an `Advisory (does not block)` summary line. A
  `TESTDATA_CONFIRM: none` answer does not suppress it yet; that, and promotion to blocking, wait on
  a live golden sweep.
