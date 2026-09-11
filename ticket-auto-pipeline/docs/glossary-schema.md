# Wiki Glossary Schema

**Schema-Version: 1**
**Defined by:** `openspec/changes/adr-governance-gate/specs/wiki-glossary/spec.md`
**File:** `{WIKI_ROOT}/glossary.md`
**Scaffolded by:** `lib/wiki-bootstrap.sh` · **checked by:** `lib/wiki-verify.sh`

## Overview

The glossary keeps terminology stable across every wiki flow file and every
ADR. It carries the same freshness frontmatter as any other wiki file — no
special-casing — and is linted by the ordinary wiki freshness lint
alongside it.

## Entry shape

```
### Commission

The fee an intermediary earns on a completed transaction, computed at
settlement time.

Avoid: fee, cut, take-rate

Related: services/billing-service.md, decisions/0012-commission-model.md
```

| Part | Required | Description |
|---|---|---|
| Term heading (`### Term`) | Yes | The preferred term. |
| Definition | Yes | A short paragraph. |
| `Avoid:` | No | Comma-separated synonyms that must not be used for this concept. Feeds the term-drift check. |
| `Related:` | No | Comma-separated wiki files and/or ADR paths. |

## The `Avoid:` convention and the term-drift lint

Every synonym listed under a term's `Avoid:` is a deterministic lint target:
`wiki-verify.sh` and the reusable term-drift function scan wiki flow files
and ADRs for each avoided synonym and report one violation per occurrence,
naming the file, the avoided term, and the preferred term — no model
involvement. A violation does not block anything (see
[wiki-verify spec](../openspec/changes/adr-governance-gate/specs/wiki-verify/spec.md));
`wiki-maintenance` resolves it either by correcting the usage or, when the
"synonym" turns out to denote a genuinely different concept, by splitting it
into its own entry rather than rewriting real content to fit a bad merge.

## Glossary informs ADR drafting

The gate reads the glossary before drafting ADR prose, so a new ADR uses
settled terminology instead of quietly introducing another synonym for a
concept the glossary already names.

## Related

- [ADR schema](adr-schema.md)
- `lib/wiki-check.sh` — the freshness lint the glossary file is checked under, unmodified by this schema
