#!/usr/bin/env python3
"""Generate the coder sprite PNGs from coder.grid (openspec record-stitch-overlay, D8).

Usage: gen-coder-sprite.py [--grid PATH] [--out DIR]

Writes coder-work-01..08.png and coder-idle-01..04.png: RGBA 8-bit, each 32x32
grid scaled x6 nearest-neighbour to 192x192. Output bytes are deterministic
(fixed zlib level, no timestamp or text chunks), so a test can compare a fresh
run against the committed PNGs. Standard library only. Render never runs this.
"""
import argparse
import os
import re
import struct
import sys
import zlib

SIZE = 32
SCALE = 6
WANT = {"work": 8, "idle": 4}
ZLEVEL = 9


class GridError(Exception):
    pass


def parse_grid(path):
    palette = {".": (0, 0, 0, 0)}
    frames = []  # (name, rows)
    current = None
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    for num, raw in enumerate(lines, 1):
        line = raw.rstrip("\r")
        if current is not None and len(current[1]) < SIZE:
            if len(line) != SIZE:
                raise GridError(f"{path}:{num}: frame {current[0]} row has {len(line)} chars, want {SIZE}")
            bad = [c for c in line if c not in palette]
            if bad:
                raise GridError(f"{path}:{num}: frame {current[0]} uses char {bad[0]!r} not in the palette")
            current[1].append(line)
            continue
        if not line.strip() or line.startswith("#"):
            continue
        m = re.fullmatch(r"palette (\S) #([0-9a-fA-F]{6})", line)
        if m:
            ch, hexrgb = m.groups()
            if ch in palette:
                raise GridError(f"{path}:{num}: palette char {ch!r} declared twice (or reserved)")
            if frames:
                raise GridError(f"{path}:{num}: palette line after the first frame")
            palette[ch] = tuple(int(hexrgb[i:i + 2], 16) for i in (0, 2, 4)) + (255,)
            continue
        m = re.fullmatch(r"frame (work|idle)-(\d\d)", line)
        if m:
            current = (line[len("frame "):], [])
            frames.append(current)
            continue
        raise GridError(f"{path}:{num}: unexpected line: {line!r}")
    if current is not None and len(current[1]) != SIZE:
        raise GridError(f"{path}: frame {current[0]} has {len(current[1])} rows, want {SIZE}")
    for kind, count in WANT.items():
        names = [n for n, _ in frames if n.startswith(kind + "-")]
        expected = [f"{kind}-{i:02d}" for i in range(1, count + 1)]
        if names != expected:
            raise GridError(f"{path}: {kind} frames are {names}, want {expected} in order")
    if len(frames) != sum(WANT.values()):
        raise GridError(f"{path}: {len(frames)} frames, want {sum(WANT.values())}")
    return palette, frames


def png_bytes(rows, palette):
    width = height = SIZE * SCALE
    raw = bytearray()
    for row in rows:
        line = bytearray([0])  # filter type None
        for ch in row:
            line.extend(bytes(palette[ch]) * SCALE)
        raw.extend(bytes(line) * SCALE)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), ZLEVEL)) + chunk(b"IEND", b""))


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Generate coder sprite PNGs from coder.grid.")
    ap.add_argument("--grid", default=os.path.join(here, "coder.grid"))
    ap.add_argument("--out", default=here)
    args = ap.parse_args(argv)
    try:
        palette, frames = parse_grid(args.grid)
    except (OSError, GridError) as exc:
        print(f"gen-coder-sprite: {exc}", file=sys.stderr)
        return 1
    os.makedirs(args.out, exist_ok=True)
    for name, rows in frames:
        with open(os.path.join(args.out, f"coder-{name}.png"), "wb") as fh:
            fh.write(png_bytes(rows, palette))
    return 0


if __name__ == "__main__":
    sys.exit(main())
