# Crosscheck golden fixture corpus

Regression corpus for the Crosscheck checkers (`ticket-planner/lib/planner-crosscheck*.sh`),
run by `../test-planner-crosscheck-fixtures.sh` against the real
`planner_crosscheck_run` — not a mock. See issue
[#231](https://github.com/willard-pro/claude-plugins/issues/231).

## Status: synthetic placeholders, not yet real captured data

**Every fixture in this directory today is synthetic-but-pattern-derived.**
None of them is a genuine initiative's `proposal.md` / `specs/*.md` output.

Issue #231 asked for real (sanitized) artifacts from the 7 initiatives
referenced in CHANGELOG.md (VS-1 through VS-4, the Evidence-Based
initiative, etc.) — those artifacts do exist on disk in the environment this
fix was built in (`${REPOS_ROOT}/.ticket-auto/initiatives/*/artifacts/`).
They were not copied in here. They are unreleased business planning content
for a real product; copying and "sanitizing" that into a public marketplace
repo — deciding what counts as sanitized, and accepting the risk of getting
that wrong in a public repo — is a call the automated pipeline run that
built this fixture set did not have standing to make unilaterally. That
decision is left to a human maintainer with the actual artifacts in front of
them (see "Adding a real fixture" below).

What's here instead is the infrastructure issue #231 was really asking for:
a data-driven harness that runs the real checkers against on-disk fixtures,
plus 2-4 fixtures built from the *specific* false-positive shapes
CHANGELOG.md documents as having actually occurred on real initiatives and
been fixed — grounded in real prior bugs, not invented from nothing, but
hand-authored text, not extracted LLM output.

## Fixture format

Each subdirectory of `fixtures/crosscheck/` is one fixture. The test harness
discovers every subdirectory containing an `expected.json` — dropping in a
new fixture directory is the only step needed to add a regression case, no
test-file editing required.

```
fixtures/crosscheck/<fixture-name>/
  proposal.md       # optional — copied to artifacts/proposal.md
  discovery.md       # optional — copied to artifacts/discovery.md
  consensus.md        # optional — copied to artifacts/consensus.md
  specs/*.md          # optional — copied to artifacts/specs/
  intents/*.json       # optional — copied to the initiative's .intents/
                        # (TicketGen's ticket-<slug>.json records): a TD spec
                        # whose slug has one counts as dispatched
  repo-stub/           # optional — copied verbatim into REPOS_ROOT, so
                        # citation/precedent checks that need a real file
                        # (e.g. `worker/main.py:12`) resolve against it
                        # instead of always finding nothing
  expected.json        # required — the fixture is skipped by the harness
                        # without one
```

Any artifact file the fixture omits simply isn't copied — every checker in
`planner-crosscheck*.sh` degrades to "no findings" when its input file is
absent, so a fixture only needs to provide the files its scenario actually
exercises.

`expected.json`:

```json
{
  "blocking": 0,
  "warn": 1,
  "accepted": 0,
  "notes": "One sentence: what shape this exercises and why the counts above are correct."
}
```

- `blocking` — number of `META|crosscheck|fail|<CODE>` lines the run must
  produce. `planner_crosscheck_run` returns nonzero iff this is nonzero —
  the harness asserts both the count and the return code.
- `warn` — number of `META|crosscheck|warn|` lines (non-blocking codes —
  see `PLANNER_CROSSCHECK_WARN_CODES` in `planner-crosscheck.sh`).
- `accepted` — number of `META|crosscheck|accepted|` lines (an
  operator-`--accept`-ed code — see `planner_crosscheck_accept_set`). None
  of today's fixtures pre-seed an accepted code; the field exists so a
  future fixture demonstrating the `--accept` override doesn't need a
  harness change.
- `codes` — optional. The exact multiset of blocking codes the run must
  produce (order-insensitive).
- `message_contains` — optional. Substrings the blocking finding messages,
  taken together, must contain — counts alone cannot tell the right finding
  from a different one.
- `files_present` / `files_absent` — optional. Paths relative to the
  initiative's `artifacts/` that must / must not exist after the run (test-data
  synthesis: TD specs, `testdata-synth.json`, `specs/INDEX.md`).
- `file_contains` — optional. `{ "<artifacts-relative path>": ["substring", …] }`.
- `sidecar_jq` — optional. jq expressions that must be true against
  `artifacts/testdata-synth.json`.
- `log_contains` — optional. Substrings the state log must contain.
- `idempotent` — optional, `true`: run `planner_crosscheck_run` a second time
  and assert no file under `artifacts/` changed (content, size or mtime).
- `notes` — free text. Say what real false-positive class this is modeled
  on (cite the CHANGELOG entry/issue number if there is one) and why the
  expected counts are what they are.

The harness runs each fixture in its own throwaway `REPOS_ROOT`
(`planner-crosscheck-contracts.sh` scans sibling initiatives under
`REPOS_ROOT/.ticket-auto/initiatives/*`, so fixtures sharing a root could
cross-contaminate each other's contract findings) and counts
`META|crosscheck|{fail,warn,accepted}` lines straight from the state log the
real `planner_crosscheck_run` wrote — the same log
`planner_crosscheck_findings_summary` reads for `status` mode. It never
re-implements or mocks a checker. For every fixture it also asserts that each
spec file without the synthesis marker is byte-identical after the run —
Crosscheck never edits a consumer spec.

## Today's fixtures

| Fixture | Shape | Grounded in |
|---|---|---|
| `citation-compound-two-line-symbols` | Compound `A()/B():path:line1,line2` citation where each symbol resolves near its own line | [#224](https://github.com/willard-pro/claude-plugins/issues/224) (CHANGELOG `ticket-planner 0.8.13`) — the checker used to pair both symbols against the first line number only, false-flagging `CITATION_SYMBOL_MISMATCH` on the Evidence-Based initiative's `ebc-e` spec |
| `dangling-blocked-by-external-ref` | `blocked-by:WIL-83` naming an existing Linear issue, not a sibling spec slug | [#227](https://github.com/willard-pro/claude-plugins/issues/227) — `planner_deps_is_external_ref` exempts this shape from `DANGLING_BLOCKED_BY` |
| `signals-legit-trivial-defaults` | Two trivial specs sharing the same all-zero/false `services_identified`/`symbols_resolved`/`prior_art_found` combination | [#220](https://github.com/willard-pro/claude-plugins/issues/220) (CHANGELOG `ticket-planner`, VS-2 / `INIT-1788079196-3438`) — that combination is documented as the legitimate default for trivial tickets and excluded from the near-identical `SIGNALS_UNIFORM` pass |
| `testdata-generate-unowned` | Two specs whose Verification Notes need `Source: generate` data, no owner | [#503](https://github.com/willard-pro/claude-plugins/issues/503) — was one blocking `TEST_DATA_UNOWNED`; since planner-test-data-derivation 4.7 Crosscheck synthesizes one `<consumer>-test-data` spec per need (different keys) and stays clean |
| `testdata-generate-unowned-table` | The same two specs with Verification Notes as the #499 Criterion table (a `Source` column) | [#499](https://github.com/willard-pro/claude-plugins/issues/499) + [#503](https://github.com/willard-pro/claude-plugins/issues/503) — table rows are needs; synthesized and clean, as above |
| `testdata-seeded-by-owned` | The same needs owned by a third enabler spec via `seeded-by:` | [#503](https://github.com/willard-pro/claude-plugins/issues/503) — must stay clean |
| `testdata-self-seeded-no-tests-rule` | A self-seeded need while REPOS_ROOT `CLAUDE.md` says implementation does not write tests | [#503](https://github.com/willard-pro/claude-plugins/issues/503) point 4 — `TEST_DATA_UNOWNED`, remedy `MANDATORY` |
| `cited-artifact-unraised` | discovery.md lists a sample file NOT FOUND; consensus.md never asks | [#504](https://github.com/willard-pro/claude-plugins/issues/504) — `CITED_ARTIFACT_UNRAISED` |
| `cited-artifact-answered` | Same, with the open question answered `external:<who>` | [#504](https://github.com/willard-pro/claude-plugins/issues/504) — must stay clean |
| `cited-artifact-source-mismatch` | Operator answered `generate`, spec still says `external:<invented who>` | [#504](https://github.com/willard-pro/claude-plugins/issues/504) AC4 — `CITED_ARTIFACT_SOURCE_MISMATCH` |
| `cited-artifact-list-variants` | Numbered items, bare names, case-insensitive status, `FOUND: …NOT FOUND…` location, one unparseable item | [#504](https://github.com/willard-pro/claude-plugins/issues/504) — only the unparseable item, as `CITED_ARTIFACT_MALFORMED` |
| `cited-artifact-overlapping-names` | Artifacts `sample` and `sample file v2` with different answers | review case A — exact backticked matching; must stay clean |
| `cited-artifact-prose-not-matched` | Artifact `template`; an unrelated need mentions "email template" in prose | review case A2 — prose is never a citation; must stay clean |
| `cited-artifact-paraphrased` | Spec paraphrases a NOT FOUND artifact and invents an owner | review case B — `CITED_ARTIFACT_UNREFERENCED` |
| `testdata-notes-missing` | A feature spec with acceptance criteria and no Verification Notes, beside an enabler spec and a synth-marked spec without them | planner-test-data-derivation 2.1 — one blocking `VERIFICATION_NOTES_MISSING`; enabler and synth-marked specs exempt |
| `testdata-inventory-missing` | Contract initiative whose discovery.md has no `## Test Data Inventory` | planner-test-data-derivation 1.3 — warn-only `TEST_DATA_INVENTORY_MISSING` |
| `testdata-implied-strong` | All rows `none`; "Given 5 overdue \`invoice\` records" | planner-test-data-derivation 2.3 — blocking `TEST_DATA_IMPLIED` with `[hash8]` and `match="…"` |
| `testdata-implied-weak-warn` | All rows `none`; "shows 3 badges", no badge entity | planner-test-data-derivation 2.3 — warn-only `TEST_DATA_IMPLIED_WEAK` |
| `testdata-threshold-clean` | All rows `none`; "expires after 15 minutes", "lock after 5 attempts" | design Decision 3 unit denylist — must stay clean |
| `testdata-implied-confirmed-none` | The strong case answered `TESTDATA_CONFIRM … none` with the matching hash | planner-test-data-derivation 2.4 — suppressed, clean |
| `testdata-confirm-hash-stale` | The same answer with a hash that no longer matches the criterion | planner-test-data-derivation 2.4 — answer void, `TEST_DATA_IMPLIED` again |
| `testdata-external-no-synth` | The strong case answered `external:billing team` | planner-test-data-derivation 2.5 — effective Source in memory, clean; synthesis must not create a test-data spec or a sidecar |
| `testdata-synth-single` | One consumer needs an `audit-event` record, `Source: generate` | planner-test-data-derivation 4.5-4.7 — `audit-log-test-data` written, sidecar edge + override, INDEX.md block; clean |
| `testdata-synth-shared` | Two consumers need `invoice` records | 4.3/4.6 — one `<prefix>-test-data-pack` serving both; clean |
| `testdata-synth-1to2` | The shared case plus a stale synth-marked single from an earlier run, no ticket intent | spec scenario "Grouping change leaves no orphan" — single deleted, pack written |
| `testdata-synth-2to1` | Only one consumer still needs `invoice`; a stale pack, no ticket intent | 4.5 — pack deleted, single written |
| `testdata-synth-idempotent` | The shared case run twice | spec scenario "Idempotent" — the second run changes no artifact file (content or mtime) |
| `testdata-synth-slug-collision` | A hand-written, unmarked `audit-log-test-data.md` holds the TD slug | spec scenario "Slug collision" — blocking `TEST_DATA_SYNTH_FAILED` naming the file, nothing written; the need is still `TEST_DATA_UNOWNED` |
| `testdata-synth-dispatched-keep` | A synth-marked TD spec with `intents/ticket-<slug>.json` | 4.5 — kept byte-for-byte, the need whose key it owns re-attached to it |
| `testdata-synth-cited-generate` | A NOT FOUND cited artifact answered `generate`, need cites it with `Source: generate` | 4.7 — the cited-artifact remedy routes through synthesis; clean |
| `testdata-synth-cycle-guard` | A dispatched TD spec whose Labels say `blocked-by:audit-log`; `audit-log` needs the key it owns | 4.9 — the TD↔consumer cycle exists only in Labels ∪ sidecar edges; blocking `DEPENDENCY_CYCLE` on both specs |
| `contract-undefined-warn-only` | A structure that "gains new fields for ..." in prose with no backtick-quoted field names | [#175](https://github.com/willard-pro/claude-plugins/issues/175) — `CONTRACT_UNDEFINED` is deliberately warn-level, not blocking |

## Adding a real fixture

When real (sanitized) initiative artifacts become available for archiving —
an operator explicitly decides to donate a completed initiative's output —
add them as a new subdirectory following the format above:

1. Copy `artifacts/proposal.md` and `artifacts/specs/*.md` (and
   `discovery.md`/`consensus.md` if the fixture needs them) from
   `${REPOS_ROOT}/.ticket-auto/initiatives/{INITIATIVE_ID}/artifacts/` into
   a new `fixtures/crosscheck/<descriptive-name>/` directory. Use a
   descriptive name, not the raw `INIT-*` id or the real ticket-slug
   prefixes (`vs-1`, `vs-2`, ...) if those prefixes are themselves
   identifying — rename spec files if needed.
2. **Sanitize before committing** — this is a public repo (see root
   `CLAUDE.md`, "No ticket IDs or user data in any field"):
   - No real Linear/Jira ticket IDs, customer names, company names, or
     internal hostnames/URLs. Replace with placeholders (`ACME Corp`,
     `example-service`).
   - No credentials, API keys, tokens, or connection strings — check
     citation snippets and prose quotes especially closely, not just
     obvious fields.
   - No content whose business value depends on staying private (pricing,
     unreleased-feature names, proprietary algorithms) unless the operator
     donating it has explicitly signed off on public disclosure.
   - Prefer generalizing over redacting: "the accountant document upload
     flow" reads better than "[REDACTED] flow" and is usually enough to
     preserve the false-positive shape without the specifics.
3. Run the initiative's real Crosscheck output (or a fresh
   `planner_crosscheck_run` against the sanitized copy) to derive the true
   `expected.json` counts — don't guess them.
4. Update the table above and this status section once real fixtures exist
   alongside the synthetic ones, so a future reader doesn't have to
   re-derive which is which from the directory listing.
