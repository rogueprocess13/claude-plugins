# ticket-implement — Step 4c feedback

Read only under the condition in SKILL.md "Reference files (load condition)": in Step 4c, when a complexity mismatch or a Part 3 wiki gap exists. The outcome label, the verifier result, the mismatch definition, the Part 3 wiki check and the no-halt rule for a failed correction write stay in SKILL.md Step 4c.

## Mismatch retrospective

1. **Post a Linear comment** via the Linear access strategy (bash `save_comment` when `LINEAR_API_KEY` is set, MCP fallback otherwise):
   ```
   **Complexity mismatch** — predicted `{simple|complex}`, ran `{Smooth|Rough|Hard}`.

   **What the investigation missed:**
   {Specific gap: was the data not where the plan said? Was there an undiscovered dependency? Did a test reveal an assumption was wrong? Be concrete.}

   **What would have caught it:**
   {One sentence: the question the appraise investigation should have asked but didn't.}
   ```

2. **Save to claude-mem** — write a feedback memory capturing the pattern so future appraisals on similar tickets benefit:
   - Component or service area involved
   - What signal the complexity sweep missed
   - What to look for next time in that area

This is scoring feedback for `ticket-appraise`, not wiki knowledge: it goes to notes.md as a
`source=appraise`/`source=exec` CORRECTIONS block (Part 4), read by `ticket-retro` Step 1.6.

## Part 3 — Gap found

- **Gap found:** open the referenced wiki flow file(s) and append an errata entry using the
  canonical schema from `wiki-maintenance` Step 1 (`Gap:`/`Fix:` — no date, no outcome label,
  the ticket ID is the header):

  ```markdown
  ### {TICKET-ID}
  **Gap:** {What was missed: undiscovered Feign dependency? Entity field not in wiki? Method signature wrong?}
  **Fix:** {What to add/change in this wiki file to prevent the next ticket from hitting the same gap}
  ```

  - If the file already has an `## Errata` section, append to it. If not, create the section.
  - If multiple wiki files were loaded, append to the most specific flow file. If the gap is cross-service (e.g. credit-report → BOM interaction), append to both.
  - Also write a `source=wiki` correction to notes.md (Part 4 below) — unconditionally when a
    gap was found here, regardless of whether this ticket's outcome matched its predicted
    complexity.

## Part 4 — Source mapping and writes

The source maps to the skill whose prediction was overturned:

| Outcome vs Prediction | Source | Meaning |
|-----------------------|--------|---------|
| `Hard` (predicted `simple`) | `appraise` | Complexity sweep underestimated the ticket |
| `Rough` (predicted `simple`) | `appraise` | Complexity sweep underestimated the ticket |
| `Smooth` (predicted `complex`) | `appraise` | Complexity sweep overestimated — could have auto-approved |
| `Hard` (predicted `simple`), plan was accurate | `exec` | Plan artifact missed key details |
| `Rough` (predicted `simple`), plan was accurate | `exec` | Plan artifact missed key details |

Write each through `implement-feedback.sh correction` (`append_correction`, atomic `.tmp` → `mv`; a failed write logs `META|corrections-error|warn` and exits 0):

```bash
# Only on MISMATCH=true; --source per the mapping table above
bash ~/.claude/skills/lib/implement-feedback.sh correction --ticket-dir "{ticket-dir}" --source {appraise|exec} \
  --fact "Predicted {simple|complex} but actual outcome was {Smooth|Rough|Hard}" \
  --detail "{What the investigation missed — concrete gap description from the mismatch comment above}"
# Only when Part 3 found a wiki gap — independent of mismatch
bash ~/.claude/skills/lib/implement-feedback.sh correction --ticket-dir "{ticket-dir}" --source wiki \
  --fact "Wiki flow file {filename} missing or stale for {specific detail}" --detail "Wiki gap found: {What the wiki missed}"
```
