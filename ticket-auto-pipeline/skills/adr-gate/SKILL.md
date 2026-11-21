---
name: adr-gate
description: Reusable architectural governance primitive. Classifies whether a reported decision candidate needs an ADR and returns one of NOT_ARCHITECTURAL/GOVERNED/CREATED_PROPOSED/CONFLICT/SUPERSEDE_REQUIRED, drafting a Proposed ADR when one is warranted. Never stops the pipeline itself — the calling phase routes on the returned verdict. Invoked by any ticket-auto-pipeline phase (via the shared preamble) and by ticket-planner, as a plain skill invocation with no cross-plugin bash dependency.
---

# ADR Gate

Given a reported decision candidate, determine whether it is architectural and, if so, whether it is already governed, conflicts with something already governed, or is new territory requiring a Proposed ADR. This runs on the request text and the ADR store only — no ticket fetch, no Linear access, no code changes.

**The gate owns the classification.** A caller reports an observation — it never decides whether an ADR is required, and this skill does not defer that judgment back to the caller, however the caller framed the request.

---

## Run

```
/adr-gate --request-file <path> [--wiki-root <path>] [--log-file <path>]
```

Every run, before reading the request, read the gate's rules in `references/gate.md`: run `bash ~/.claude/skills/lib/skill-ref.sh adr-gate references/gate.md`, then Read the printed path in full and follow it with the arguments above. If `skill-ref.sh` exits non-zero, stop and report the missing reference: never classify from memory.
