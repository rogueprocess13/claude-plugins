# Improvement Template

> Copy everything below this line into the Linear ticket description.
> Fill in `{placeholders}`. Remove any sections that don't apply.
> Labels to set: `improvement`
> Verify mode: replace `{shape}` with exactly one of `browser` (a person uses a page), `api-only` (HTTP endpoints, no page), `live-backend` (running services with no page and no single endpoint), `build-only` (the build or test command passing is the check), `diff-only` (only files to read). The pipeline reads this field first and then makes no guess of its own.

---

{Descriptive Name}

## Summary

{One sentence: which existing feature is being improved and how.}

## Current Behaviour

{What it does now — be specific enough that someone unfamiliar can reproduce the starting state.}

## Desired Behaviour

{What it should do instead. Delta only — describe the change, not the full feature.}

## Motivation

{Why the current behaviour is insufficient — user friction, data accuracy, performance, or business rule change.}

## Errors and Edge Cases

- **Failure:** {what the user or caller sees on a network failure or a 5xx response}
- **Check order:** {when more than one of 401, 403, 404 and 422 could apply, which is returned first}
- **Empty or malformed input:** {empty body, missing or wrong-typed field}
- **Late or concurrent responses:** {an action taken while an earlier request is still running}
- **Unauthorised viewer:** {what someone without the right sees on an edit page; a request with no or an expired token}

> Answer each line with the behaviour, or `Not applicable — {why}`. Every behaviour stated here needs its own acceptance criterion.

## Acceptance Criteria

- [ ] {Observable fact — e.g. "Pagination controls appear below the user list when results exceed 20 rows"}
- [ ] {Observable fact — e.g. "Navigating to page 2 preserves the active filter"}
- [ ] {Observable fact}

> One criterion per line. No "and". No vague phrases.

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

{What must exist before verification can run — e.g. "More than 20 users registered in the org."}

## Verify Mode

**Verify mode:** {shape} — {one-line reason}

## Related Tickets

{Linear IDs, or None}
