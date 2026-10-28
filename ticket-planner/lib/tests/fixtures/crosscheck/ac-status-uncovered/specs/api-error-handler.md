# api-error-handler

## Description

Error handler fixture spec, shaped like a real spec whose fallback path had no acceptance criterion.

## Proposed Changes

- The error handler renders only fixed messages. A request body that is not valid JSON returns 400 `{"errors":{"body":["is invalid"]}}`. Any other unexpected error returns 500 `{"errors":{"server":["unexpected error"]}}`.

## Acceptance Criteria

- [ ] A POST with a body that is not valid JSON returns 400 `{"errors":{"body":["is invalid"]}}`

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| A POST with a body that is not valid JSON returns 400 `{"errors":{"body":["is invalid"]}}` | anonymous | none | — | as stated | yes |
