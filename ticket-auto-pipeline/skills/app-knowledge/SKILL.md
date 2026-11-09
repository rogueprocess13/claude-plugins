---
name: app-knowledge
description: Reference knowledge base for the project app's business rules, user roles, UI behaviour, and system conventions, built up during ticket work. Use this as a lookup when browsing the site via Playwright or when reasoning about role-based behaviour. Not an interactive skill — read this file directly when you need context about how the app works. Companion: /nav-hints for click-by-click navigation paths.
---

# App Knowledge — Business & System Knowledge

This file is a living reference for one project's app. The pipeline reads and writes the host's
runtime copy (`~/.claude/skills/app-knowledge/SKILL.md`); the plugin ships only this skeleton, so
the runtime copy may be empty and must not be assumed to hold role rules. Record roles, states,
navigation patterns and quirks there as they are learned during Playwright sessions or ticket work.

---

## Environments

| Name | URL | Notes |
|---|---|---|
| Local (dev) | {LOCAL_URL} | Runs against local microservices |
| UAT | {UAT_URL} | Staging environment |

---

## Role Scope Registry

<!-- ticket-appraise-exec Step 3.7 appends one "### {TICKET-ID} — {feature area}" entry per appraisal here. -->

---

## Append new learnings below this line

<!-- Format: ### YYYY-MM-DD — {TICKET-ID or "Session"}: {one-line summary of what was learned} -->
