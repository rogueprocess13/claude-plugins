# New Feature Template

> Copy everything below this line into the Linear ticket description.
> Fill in `{placeholders}`. Remove any sections that don't apply.
> Labels to set: `feature`
> Verify mode: replace `{shape}` with exactly one of `browser` (a person uses a page), `api-only` (HTTP endpoints, no page), `live-backend` (running services with no page and no single endpoint), `build-only` (the build or test command passing is the check), `diff-only` (only files to read). The pipeline reads this field first and then makes no guess of its own.

---

{Descriptive Name}

## Summary

{One sentence: what the feature does and who benefits.}

## Background / Motivation

{Why this is needed — business context, user pain point, or gap in the current system.}

## Proposed Behaviour

{How it should work, screen by screen or step by step. Be specific about UI elements, labels, and states.}

## Errors and Edge Cases

- **Failure:** {what the user or caller sees on a network failure or a 5xx response}
- **Check order:** {when more than one of 401, 403, 404 and 422 could apply, which is returned first}
- **Empty or malformed input:** {empty body, missing or wrong-typed field}
- **Late or concurrent responses:** {an action taken while an earlier request is still running}
- **Unauthorised viewer:** {what someone without the right sees on an edit page; a request with no or an expired token}

> Answer each line with the behaviour, or `Not applicable — {why}`. Every behaviour stated here needs its own acceptance criterion.

## Acceptance Criteria

- [ ] {Observable fact — e.g. "A 'Payment Reminder' option appears in the document type dropdown"}
- [ ] {Observable fact — e.g. "Submitting the form with a blank agent message shows a validation error"}
- [ ] {Observable fact}

> One criterion per line. No "and". No vague phrases like "feature works" or "is displayed correctly".

## Out of Scope

{What this ticket explicitly does NOT cover. Helps prevent scope creep during appraisal.}

## Scope

| Layer | Service       | Area                         |
| ----- | ------------- | ---------------------------- |
| FE    | gateway       | {component / page}           |
| BE    | {service}     | {controller / entity / repo} |

## Test User

`{email or role}` — password `admin`

## Navigation Path

`{Menu > Submenu > Page}` — click-by-click; do NOT paste a URL.

## Test Data Prerequisites

{What must exist before verification can run — e.g. "Org with at least one active handover."}

## Verify Mode

**Verify mode:** {shape} — {one-line reason}

## Related Tickets

{Linear IDs, or None}
