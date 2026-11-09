---
name: nav-hints
description: Navigation hint lookup for browser-based ticket work. Returns exact click-by-click paths to reach feature areas without direct URL navigation (which breaks Angular session state). Use when ticket-verify or ticket-reproduce needs to navigate the app, or when the user asks "how do I get to X in the app".
---

# Nav Hints

You have been given an area name as the argument (e.g. `progress`, `payments`, `correspondents`). Return the exact click-by-click navigation path to reach that area. **Never use `page.goto()` for in-app navigation** — always click through the UI because Angular loses session state on full page reload.

## Arguments

| Usage | Purpose |
|-------|---------|
| `/nav-hints <area>` | Return the click path for `<area>`. Fuzzy matches if exact not found. |
| `/nav-hints add` | Record a new hint. Prompts for area name, path, and steps. Appends to the project hints file. |
| `/nav-hints list` | Print all known areas for the current project. |

If no argument: print all known areas.

## Step 1 — Load the hints file

Read `{TICKETS_ROOT}/nav-hints.md` in the current working directory. If missing, create it with the header in § Hints file format.

`{TICKETS_ROOT}` is the current working directory (must be `tickets`).

## Step 2 — Match the area

If `<area>` provided:
- Exact match on the hint heading (case-insensitive) → return that hint.
- Partial/fuzzy match → list candidate headings, ask user to pick.
- No match → report "No hint for '{area}'. Known areas: {list}. Use `/nav-hints add` after successful navigation to record it."

If `add`:
- Ask: "What area did you just reach? (short label, e.g. 'Order Details')"
- Ask: "What is the URL path pattern? (e.g. `/orders/{id}`)"
- Ask: "What click-by-click steps got you there? Start from the nav bar."
- Ask: "Which ticket was this for? (e.g. ABC-123)"
- Append the hint to `{TICKETS_ROOT}/nav-hints.md` in the format below.
- Tell the user: "Saved. Future tickets can use `/nav-hints {area}`."

If `list` or no argument:
- Print every known area heading and a one-line summary of its path.

## Step 3 — Return the path

For the matched hint, print:

```
## {Area Name}
**URL pattern:** {path}
**How to reach:**
1. {step 1}
2. {step 2}
...
**Learned from:** {ticket IDs}
```

The calling skill (verify/reproduce) uses these steps verbatim to execute Playwright clicks.

## Hints file format

`{TICKETS_ROOT}/nav-hints.md`, one per tickets workspace. A new file starts with the header below; every hint is appended as one `##` entry carrying when and from which ticket it was learned, so stale hints can be found:

```markdown
# Navigation Hints — {PROJECT_NAME}

Hints are learned during ticket verification and reproduction sessions.
Never hand-edit — use `/nav-hints add` to append.

## {Area Name}
- **Path:** {URL pattern, e.g. `/orders/{id}`}
- **How to reach:** {numbered click-by-click steps, e.g. Click "Orders" in the nav bar, then the order row}
- **Learned from:** {TICKET-ID}
- **Date:** {YYYY-MM-DD}
```
