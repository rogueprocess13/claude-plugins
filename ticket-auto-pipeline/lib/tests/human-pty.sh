#!/usr/bin/env bash
# human-pty.sh — test helper: run a command the way a person at a terminal
# does. Sourced by tests of the person-only actuators (approve.sh, reject.sh,
# flow.sh human-approve / human-reject). Production has no switch that skips
# the terminal check (lib/human-terminal.sh), so a test gives the command a
# real pseudo-terminal (python3 pty) and types the answer there, exactly as
# test-regression-risk.sh does for regression-ack.sh.
#
#   human_pty_init                 once per test file; removes its temp dir at
#                                  exit unless the caller set its own EXIT trap
#                                  (then call human_pty_cleanup from it)
#   human_pty <answer> <cmd...>    runs cmd with a controlling terminal and
#                                  none of the agent/fleet variables, types
#                                  <answer> + newline when the prompt shows
#                                  ("anything else aborts"), prints all the
#                                  terminal showed (stdout and stderr, CR
#                                  stripped), exits with cmd's status
#   human_env <cmd...>             only drops the agent/fleet variables: a
#                                  person's environment with no terminal
#   human_unset                    the same for the current shell, for tests
#                                  that call a sourced writer in-process
#
# Not a test itself (no test-*.sh name), so it is not registered in the
# Makefile.

HUMAN_PTY_DIR=""

human_pty_cleanup() {
  [ -z "$HUMAN_PTY_DIR" ] || rm -rf "$HUMAN_PTY_DIR"
}

human_pty_init() {
  HUMAN_PTY_DIR=$(mktemp -d)
  [ -n "$(trap -p EXIT)" ] || trap human_pty_cleanup EXIT
  cat >"$HUMAN_PTY_DIR/pty_run.py" <<'PY'
import os, pty, select, sys, time

answer, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out, sent, deadline = b"", False, time.time() + 60
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if not sent and b"anything else aborts" in out:
        os.write(fd, answer.encode() + b"\n")
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
sys.exit(os.waitstatus_to_exitcode(status))
PY
}

human_env() {
  env -u CLAUDE_CODE_SESSION_ID -u FLEET_WORKER_PID -u FLEET_GENERATION "$@"
}

human_pty() {
  local answer="$1"
  shift
  human_env python3 "$HUMAN_PTY_DIR/pty_run.py" "$answer" "$@"
}

human_unset() {
  unset CLAUDE_CODE_SESSION_ID FLEET_WORKER_PID FLEET_GENERATION
}
