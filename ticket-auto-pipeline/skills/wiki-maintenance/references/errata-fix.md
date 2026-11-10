# wiki-maintenance — Step 2b: apply an errata fix

Read by Step 2b, and by Step 2.6 for a `source=wiki` or `source=prescan` correction.

Edit the flow file to incorporate the missing detail directly into the existing flow structure
— a fix is a content change, not a new changelog line. Tag the inserted content with the
source ticket as a trailing provenance marker, `(ABC-XX)`, and nothing else (no date, no
outcome label). Common patterns:

| Gap type | Where to fix | Example change |
|----------|-------------|----------------|
| Missing Feign client call in flow | Add a sub-step to the flow section listing the Feign call | "6. Call `BomFeignClient.charge(reserve=true, usage)` via `POST /body-service-resource-usages/charge` (ABC-47)" |
| Entity field not documented | Add the field to the entity table | `amount` \| `BigDecimal(21,2)` \| Recovery amount (ABC-52) |
| Method signature stale | Update class name or method name in the Key Classes table | Replace `ReportJobService.setStatus()` with correct method |
| Missing endpoint | Add to REST Endpoints table | Add row with method, path, purpose |
| Cross-service dependency undocumented | Add a "## Dependencies" section or note in the flow | "Requires BOM service for commission calculation via `BomFeignClient` (ABC-61)" |

After editing, the flow file must still read as a coherent document — the errata entry
described a fix, but you apply it as part of the regular flow structure, not as an appended note.

**If the fix requires creating a new wiki file** (e.g. a flow that has no wiki page yet):

1. Create the file with YAML frontmatter — use this schema (the freshness fields are the
   contract `lib/wiki-check.sh` lints, checked in Step 3):
   ```yaml
   ---
   services: [list of microservice names]
   entities: [list of key JPA entities or domain objects]
   flows: [list of flow names this file covers]
   keywords: [searchable terms a ticket description might contain]
   related: ["path/to/related-file.md", ...]
   verified_at: "{today, YYYY-MM-DD}"
   verified_against: {repo: "{repo-slug}", sha: "{HEAD sha of that repo right now}"}
   stale_after: 90
   verified: machine-verified
   ---
   ```
   `verified: machine-verified` is correct for content this skill itself wrote from a
   ticket-implement/appraise finding — reserve `human-reviewed` for content a person actually
   read and confirmed, and `unverified` for content copied in without independent checking.
2. Add a row to the **File Registry** table in `{WIKI_ROOT}/index.md`.
3. Add entries to the **Lookup by Topic** and **Lookup by Service** sections of `index.md`.
4. Add the new file to the `related:` frontmatter field of any existing files it is related to.

**If editing an existing file**, refresh its frontmatter the same way: set `verified_at` to
today and `verified_against` to the sha of the repo the fix was verified against. A fix applied
without updating `verified_at` leaves the file's freshness classification (`lib/wiki-check.sh`,
§5) wrong — it would still show as decayed relative to the *old* verification, undercutting the
work just done.
