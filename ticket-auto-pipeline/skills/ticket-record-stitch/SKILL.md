---
name: ticket-record-stitch
description: Builds a video from the recordings of one or more tickets that ran with `--record` — a title card per ticket, then its board and app frames in time order. Use when the user says "/ticket-record-stitch {ID}", "stitch the recording for {ID}", "make the video for {ID}", or "build the demo video".
---

# Ticket Record Stitch

Turns the frames a recording run saved under each ticket's `artifacts/recordings/` into one MP4. A thin wrapper around `lib/record-stitch.sh`: the script picks the frames, checks them and runs `ffmpeg`. It is not a pipeline phase, so there is no pipeline preamble, no log line and no tracker write.

## Usage

```
/ticket-record-stitch <TICKET-ID>... [--out FILE] [--order given]
/ticket-record-stitch --clip <TICKET-ID>
```

## Execution

Run from the tickets root (the directory `/ticket-auto` runs from). Pass the ticket IDs exactly as the user gave them; never look for frame files yourself.

Video over one or more tickets (the default):

```bash
bash ~/.claude/skills/lib/record-stitch.sh video [--out FILE] [--order given] <TICKET-ID>...
```

One ticket's verification clip only (`--clip`):

```bash
bash ~/.claude/skills/lib/record-stitch.sh clip <TICKET-ID>
```

The script resolves each ticket's directory under `REPOS_ROOT` and prints the output path on stdout: `./recording-<ID>.mp4` (or `--out`) for `video`, `<ticket dir>/artifacts/recordings/<ID>-verify.mp4` for `clip`. Tickets are shown in the order of their first frame; `--order given` keeps the order typed. Re-running replaces only the output file.

Report the printed path. On a non-zero exit report the script's stderr and stop; do not retry and do not build a video another way:

| Exit | Meaning |
|------|---------|
| 2 | Usage, or an argument that is not a ticket ID |
| 3 | Nothing to stitch: no recording, no frame from an environment `RECORD_ALLOWED` allows now, or `RECORD_ALLOWED` unset |
| 4 | `ffmpeg` is not installed |
| 5 | `ffmpeg` failed or timed out |
