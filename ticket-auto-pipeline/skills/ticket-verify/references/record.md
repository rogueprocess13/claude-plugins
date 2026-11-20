# ticket-verify — recording (`--record`)

Read only when Step 1h's condition holds: recording is on for this ticket and `VERIFY_MODE=browser`. With recording off, or in build-only or live-backend mode, none of this applies.

Recording keeps one picture of the app per step, so a run can be stitched into a short video later. It is extra output only. It never changes what you verify, how you navigate, the report or the verdict.

## Fixed viewport (before Step 3a)

Before the first `mcp__playwright__browser_navigate` in Step 3a, call `mcp__playwright__browser_resize` with `width` 1280 and `height` 800. Do this again after every fresh browser session (a `build-plan` resume starts one).

If a responsive criterion in Step 4b resizes the viewport, take no recording frame while the size is different, and resize back to 1280×800 as soon as that criterion's assertion is done.

## One frame per settled step

Take one recording frame each time a step has settled (the Step 4 **Wait for settle** rule has returned and you have taken the snapshot):

- Step 3a: the app's first page.
- Step 3b: the page after a successful login (never the login form, see the password rule).
- Step 4: each page a navigation attempt lands on, right or wrong.
- Step 4b: after every step of the Verification Plan, and at each criterion's assertion point.

For each frame:

1. Call `mcp__playwright__browser_take_screenshot` with `filename` set to `record-{TICKET-ID}.png`. Viewport only: do not set `fullPage`, do not pass an element.
2. Hand the file the tool reports to `record.sh`, with the URL the page is on now (the page URL from the latest snapshot or tool result, copied whole):

```bash
source ~/.claude/skills/lib/ticket-env.sh {TICKET-ID}
bash ~/.claude/skills/lib/record.sh append --tid {TICKET-ID} --phase verify --step "<label>" --src "<path reported by browser_take_screenshot>" --url "<current page URL>" || true
```

`<label>` is one short line saying what the frame shows, for example `Open the invoice list` or `C2: total shows 120.00`. Never put a password, a token or another secret in it.

`record.sh` decides everything else: whether this page's environment may be recorded, the attempt number, the file name and the manifest entry. So:

- Always pass the real page URL. Never substitute `LOCAL_URL`, and never decide yourself that a page is or is not recordable.
- Never name, read, list or glob a file under `{ticket-dir}/artifacts/recordings/`, and never copy a recording frame anywhere yourself.
- Never pass a Step 4b evidence screenshot (`verify-{TICKET-ID}-c{N}-…png`) as `--src`: `record.sh` deletes the source file of a page it may not record. A recording frame is always its own `record-{TICKET-ID}.png` screenshot, taken in addition to the evidence screenshot Step 4b asks for.
- Recording frames are not evidence. Do not list them under `### Evidence`, in the REMEDIATION_BRIEF, in notes.md or in any comment.

## Password rule

Never take a recording frame while a form on the page holds a typed password: the login form in Step 3b after you typed the password, a change-password form, or any other field of type password that is filled in. Skip that step's frame. The next frame is the first settled page on which no such field is filled in. This is the same rule Step 4b applies to its own screenshots.

## Failures are ignored

`record.sh append` prints one line: `ok <file>`, `skipped <reason>` or `fail <reason>`. Whatever it prints, and whatever its exit code, continue with the next verification step.

- Do not retry a frame, and do not take a replacement.
- Do not write a pipeline log line, a heartbeat or a notes.md entry about recording.
- A missing frame, a failed screenshot or a failed `append` is never a reason for a FAIL, never a reason to stop, and is not mentioned in the report.
- If the Step 4b phase timeout is close, stop taking recording frames first.

After a context compaction, read this file again before continuing Step 3, 4 or 4b.
