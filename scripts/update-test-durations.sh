#!/usr/bin/env bash
# update-test-durations.sh — rewrite scripts/test-durations.tsv from the
# results.tsv of one or more scripts/run-tests.sh runs.
#
# Usage: update-test-durations.sh [--out FILE] RESULTS.tsv...
#   --out FILE  write here instead of scripts/test-durations.tsv
#
# results.tsv lines are "secs<TAB>rc<TAB>index<TAB>command". Pass all four
# shard results of one CI run, or the one results.tsv of a full run. The repo
# root inside a command is written as {ROOT}, so the file is the same on every
# checkout. A timed-out command (rc 124/137) is left out: its time is the
# timeout, not the test. A command run more than once keeps its largest time.
# Lines are sorted slowest first, then by command, so a refresh diffs cleanly.
#
# `make test-durations` runs the full suite and then this script.
#
# Exit codes: 0 written, 2 usage or no usable result line.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$ROOT/scripts/test-durations.tsv"
FILES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
  --out)
    [ "$#" -ge 2 ] || {
      echo "usage: update-test-durations.sh [--out FILE] RESULTS.tsv..." >&2
      exit 2
    }
    OUT="$2"
    shift 2
    ;;
  -*)
    echo "usage: update-test-durations.sh [--out FILE] RESULTS.tsv..." >&2
    exit 2
    ;;
  *)
    FILES+=("$1")
    shift
    ;;
  esac
done
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "usage: update-test-durations.sh [--out FILE] RESULTS.tsv..." >&2
  exit 2
fi

python3 - "$ROOT" "$OUT" "${FILES[@]}" <<'PY'
import os, sys, tempfile
root, out, files = sys.argv[1], sys.argv[2], sys.argv[3:]
best = {}
for f in files:
    for line in open(f):
        parts = line.rstrip("\n").split("\t", 3)
        if len(parts) != 4 or parts[1] in ("124", "137"):
            continue
        try:
            secs = float(parts[0])
        except ValueError:
            continue
        key = parts[3].replace(root, "{ROOT}")
        best[key] = max(secs, best.get(key, 0.0))
if not best:
    print("update-test-durations.sh: no usable result lines in " + " ".join(files), file=sys.stderr)
    sys.exit(2)
rows = sorted(best.items(), key=lambda kv: (-kv[1], kv[0]))
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(out)))
with os.fdopen(fd, "w") as fh:
    fh.write("# Measured seconds per test command, slowest first. Read by scripts/run-tests.sh\n")
    fh.write("# for start order and --shard balancing. Refresh: make test-durations.\n")
    for key, secs in rows:
        fh.write(f"{key}\t{secs:.1f}\n")
os.chmod(tmp, 0o644)
os.replace(tmp, out)
print(f"update-test-durations.sh: {len(rows)} commands -> {out}")
PY
