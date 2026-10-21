---
name: UI Forms Test Data Specialist
extends: test-data-engineer
detect:
  - Ticket text has a `Seed channel:` line naming ui-forms
  - Ticket text says the data is entered through a form, screen, or the UI
  - Fallback only when UAT_URL is set and no other channel matched
version: 1
last-reviewed: 2026-10-21
---

# UI Forms Test Data

## Stack Idioms & Conventions

- **Last resort.** Use the UI to load data only when there is no database or API access. It is the slowest and least reliable channel; say so in the README.
- **Playwright scripts, checked in.** One script per entity, driven by a data file. Use `getByRole`/`getByLabel` selectors, never CSS paths or generated ids.
- **Wait for persistence.** After submit, wait for the success state or the record to appear in its list view before the next record. Never fixed sleeps.
- **Idempotent.** Search for the record by its namespaced key first; create only when it is missing.

## Common Pitfalls

- **Session state** — log in once per run and reuse the storage state; navigating by URL can break single-page-app sessions (see nav-hints).
- **Validation and uniqueness rules** — the form rejects values a database seed would accept. Generate values that satisfy the form's rules.
- **Partial runs** — a failure halfway leaves some records created. The script must be safe to re-run from the start.
- **Captcha, MFA or email steps** — cannot be automated safely. Raise a needs-info question instead of working around them.

## What "Done Right" Looks Like

- `Seed command:` runs the Playwright script twice against the target environment with exit 0 and no duplicates.
- `Verify command:` opens each record's view as the role the criteria use and checks the key fields.
- Login credentials come from environment variables, never from the script.
