#!/usr/bin/env python3
"""rewrite-grep-q-pipe.py — one-off mechanical rewriter for GitHub #640.

Turns the simple forms

    echo "$X" | grep <flags with q> [--] <pattern>
    echo "$(cmd ...)" | grep <flags with q> [--] <pattern>
    printf '%s\\n' "$X" | grep <flags with q> [--] <pattern>
    printf '%s' "$X" | grep <flags with q> [--] <pattern>

into

    grep <same flags> [--] <pattern> <<<"$X"

leaving everything after the pattern (`&&`, `||`, `2>/dev/null`, `{`, `;`)
unchanged. A here-string appends one newline, exactly as echo and
`printf '%s\\n'` do, so grep sees the same bytes. For `printf '%s'` (no
newline) grep still sees the same lines, since it treats an unterminated last
line as a line; the one difference is an empty $X, which becomes one empty
line, and that only matters for a pattern that matches an empty line. Every
`printf '%s'` site this was run on has a non-empty literal or argument
pattern. The here-string has no writer process,
so grep -q exiting early can no longer SIGPIPE anything into a pipefail 141.

Anything else is left alone and listed for manual review: `echo -e`/`-n`,
`printf` with any other format, a left side that is not one double-quoted
`$var`/`${...}`/`$(...)` word, a pattern that is not one complete word.

Usage:
    rewrite-grep-q-pipe.py [--dry-run] FILE... | @LISTFILE

Prints `converted N` and one `LEFT path:line: text` per remaining
`echo|printf ... | grep -q` line. Exit 0 always (it is a tool, not a gate;
scripts/check-grep-q-pipe.sh is the gate).
"""
import re
import sys

# A double-quoted word of literal text and plain $var/${...} expansions, not
# starting with "-" (echo would read that as an option).
DQ_VAR = r'"(?!-)(?:[^"\\$`]|\\.|\$(?:\{[^}"]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?]))*"'
# "$(...)" with up to two levels of nested parentheses; quotes inside are fine.
DQ_CMD = r'"\$\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)"'
LEFT = r"(?:echo|printf '%s\\n'|printf '%s'|printf \"%s\")"
FLAGS = r"((?:(?:-[A-Za-z]+|--quiet|--silent) )+)"
DASHDASH = r"((?:-- )?)"
PATTERN = (
    r"(\"(?:[^\"\\]|\\.)*\""  # "double quoted"
    r"|'[^']*'"  # 'single quoted'
    r"|\$'(?:[^'\\]|\\.)*'"  # $'ansi c'
    r"|\$\{[^}]*\}"  # ${var}
    r"|" + DQ_CMD +  # "$(cmd ...)"
    r"|\$[A-Za-z_][A-Za-z0-9_]*"  # $var
    r"|[^\s'\"\\;|&<>()`$]+)"  # bare word
)
END = r"(?=\s|$|;|\)|&|\|)"

SIMPLE = re.compile(
    LEFT + r" (" + DQ_VAR + "|" + DQ_CMD + r") \| grep " + FLAGS + DASHDASH + PATTERN + END
)
CANDIDATE = re.compile(
    r"(^|[^A-Za-z0-9_])(echo|printf)(\s[^|]*)?\|\s*grep(\s+-[A-Za-z0-9]+)*\s+"
    r"(-[A-Za-z0-9]*q[A-Za-z0-9]*|--quiet|--silent)(\s|$)"
)


def _quiet(flags):
    for f in flags.split():
        if f in ("--quiet", "--silent") or (not f.startswith("--") and "q" in f):
            return True
    return False


def _sub(m):
    x, flags, dd, pat = m.group(1), m.group(2), m.group(3), m.group(4)
    if not _quiet(flags):
        return m.group(0)
    return "grep " + flags + dd + pat + " <<<" + x


def main(argv):
    dry = False
    if argv and argv[0] == "--dry-run":
        dry, argv = True, argv[1:]
    paths = []
    for a in argv:
        if a.startswith("@"):
            with open(a[1:], encoding="utf-8") as fh:
                paths.extend(p.strip() for p in fh if p.strip())
        else:
            paths.append(a)
    converted = 0
    left = []
    for path in paths:
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            lines = fh.readlines()
        changed = False
        for i, line in enumerate(lines):
            if line.lstrip().startswith("#"):
                continue
            new = SIMPLE.sub(_sub, line)
            if new != line:
                converted += 1
                lines[i] = new
                changed = True
            if CANDIDATE.search(lines[i]):
                left.append("%s:%d: %s" % (path, i + 1, lines[i].rstrip("\n")))
        if changed and not dry:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
                fh.writelines(lines)
    print("converted %d" % converted)
    for entry in left:
        print("LEFT " + entry)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
