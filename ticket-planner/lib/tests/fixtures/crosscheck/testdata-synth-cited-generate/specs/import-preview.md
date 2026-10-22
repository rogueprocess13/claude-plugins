# import-preview

## Description

Import preview fixture spec for the cited-artifact generate route.

## Acceptance Criteria

- [ ] The preview shows the sample file's row count.
- [ ] The page title reads Import.

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| The preview shows the sample file's row count. | operator | the `client sample import file` | generate | row count shown | yes |
| The page title reads Import. | operator | none | — | as stated | yes |
