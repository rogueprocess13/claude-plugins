**Date:** 2026-11-10
**Environment:** local
**Failed at step:** 2 — Click Save
**Test user:** qa@example.com

### Expected
The record saves.

### Observed
Save stays disabled.

### Suggested Fix
The form validator ignores the new field.

### Diagnostics
**URL at failure:** http://localhost:4200/x
**Console errors:** none
**Snapshot excerpt:**
- button "Save" [disabled]

### Context Files
- context.md
