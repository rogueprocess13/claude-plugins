# Bug Report Template

> Copy everything below this line into the Linear ticket description.
> Fill in `{placeholders}`. Remove any sections that don't apply.
> Labels to set: `bug`
> Verify mode: replace `{shape}` with exactly one of `browser` (a person uses a page), `api-only` (HTTP endpoints, no page), `live-backend` (running services with no page and no single endpoint), `build-only` (the build or test command passing is the check), `diff-only` (only files to read). The pipeline reads this field first and then makes no guess of its own.

---

{Descriptive Name}

## Summary

{One sentence: what breaks, where, and under what condition.}

## Steps to Reproduce

1. Log in as `{role or email}` (password: `admin`)
2. Navigate via `{Menu > Submenu > Page}` — do NOT paste a URL
3. {Action}
4. {Observe}

## Expected Behaviour

{What should happen.}

## Actual Behaviour

{What actually happens. Paste any error message verbatim.}

## Acceptance Criteria

- [ ] {Observable fact — e.g. "Save button is enabled after the form is filled"}
- [ ] {Observable fact — e.g. "Error toast does not appear"}
- [ ] {Observable fact}

> One criterion per line. No "and". No "should work correctly".

## Scope

| Layer | Service       | Area                         |
| ----- | ------------- | ---------------------------- |
| FE    | gateway       | {component / page}           |
| BE    | {service}     | {controller / entity / repo} |

## Test User

`{email or role}` — password `admin`

## Environment

- [ ] Local (`http://localhost:9000`)
- [ ] UAT (`https://uat.credit-network.biz/`)

## Test Data Prerequisites

{What must exist before verification can run — e.g. "At least one handover in status Pending assigned to test user."}

## Verify Mode

**Verify mode:** {shape} — {one-line reason}

## Related Tickets

{Linear IDs, or None}
