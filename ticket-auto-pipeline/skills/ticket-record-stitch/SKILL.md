---
name: ticket-record-stitch
description: Builds a video from the recordings of one or more tickets that ran with `--record` — a title card per ticket, then its board and app frames in time order. Use when the user says "/ticket-record-stitch {ID}", "stitch the recording for {ID}", "make the video for {ID}", or "build the demo video".
---

# Ticket Record Stitch

Turns the frames saved under each ticket's `artifacts/recordings/` into one MP4. A thin wrapper around `lib/record-stitch.sh`, which picks and checks the frames and runs `ffmpeg`. Not a pipeline phase: no preamble, no log line, no tracker write.

## Usage

```
/ticket-record-stitch <TICKET-ID>... [--out FILE] [--order given] [--anim] [--no-overlay]
/ticket-record-stitch --clip <TICKET-ID> [--anim] [--no-overlay]
```

## Execution

Run from the tickets root. Pass the IDs and options as given; never look for frame files yourself.

```bash
bash ~/.claude/skills/lib/record-stitch.sh video [--anim] [--no-overlay] [--out FILE] [--order given] <TICKET-ID>...
bash ~/.claude/skills/lib/record-stitch.sh clip [--anim] [--no-overlay] <TICKET-ID>   # --clip
```

It prints the output path: `./recording-<ID>.mp4` (or `--out`) for `video`, `<ticket dir>/artifacts/recordings/<ID>-verify.mp4` for `clip`. Tickets come in first-frame order unless `--order given`; re-running replaces only the output. Frames show tokens, elapsed time and active agents from the pipeline log; `--no-overlay` leaves them out, `--anim` adds a pixel-art coder.

Report the printed path. On a non-zero exit report stderr and stop; do not retry or build a video another way:

| Exit | Meaning |
|------|---------|
| 2 | Usage, or an argument that is not a ticket ID |
| 3 | Nothing to stitch: no recording, no frame from an environment `RECORD_ALLOWED` allows now, or `RECORD_ALLOWED` unset |
| 4 | `ffmpeg` is not installed |
| 5 | `ffmpeg` failed or timed out |
