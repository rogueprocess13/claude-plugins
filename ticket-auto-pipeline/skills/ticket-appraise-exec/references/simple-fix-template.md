# ticket-appraise-exec — simple-fix.md template

Read only under the condition in SKILL.md Step 3 ("Reference files (load condition)"), when `{COMPLEXITY}` = simple, before Step 3-Simple writes `simple-fix.md`. The rest of Step 3-Simple, the file-exists check and Steps 3.4 onward stay in SKILL.md.

**Completion Checklist requirement:** The `## Completion Checklist` section is
machine-validated by the return-completeness gate after implementation. Every
`- [ ]` item must map to a ticket acceptance criterion. The implement agent must
check these off as work is completed. If the ticket description has no explicit
ACs, derive checklist items from the ticket's core behavioral requirements —
one independently verifiable outcome per item.

```markdown
# Simple Fix — {ISSUE-ID}

## Summary
{one sentence: what the ticket asks for}

## Affected files
{For each file that needs to change:}
- `{repo-relative-path}:{line or range}` — {what needs to change and why}

## How to implement
{Concrete step-by-step instructions derived from the investigation. Be specific enough
that an implementer can follow without re-reading the ticket. Include method names,
field names, enum values, config keys, etc. where known.}

## Completion Checklist
{For each acceptance criterion in the ticket description:
- Start the line with `- [ ]` followed by the criterion in plain language
- If no explicit ACs exist, derive checklist items from the ticket's core requirements
- Each item must be independently verifiable — one concrete outcome per line
Examples:
- [ ] AC-1: User can initiate a handover from the matter detail page
- [ ] AC-2: Error message displayed when handover fails due to missing attorney assignment}

## Constraints and gotchas
{Anything that could go wrong: ordering dependencies, side effects, things NOT to change.
Omit this section if there are none.}

{If BLAST_RADIUS is not "none":}
## Blast Radius (from GitNexus)
{Insert the blast radius table from notes.md verbatim.}

{If any target has d=1 callers listed:}
**⚠️  High-risk targets:** {list targets with HIGH/CRITICAL risk or 3+ d=1 callers}. These break if the change is wrong — verify each one is intentionally modified or confirmed unaffected.
```
