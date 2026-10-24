---
name: Python Debugging
extends: debugger
detect:
  - pyproject.toml
  - requirements.txt
  - poetry.lock
  - BE_TEST_RUNNER uses pyenv, pipenv or poetry
version: 1
last-reviewed: 2026-10-24
---

# Python Debugging

- **Tracebacks**: read from the last line up; find the lowest frame in project code. For chained errors read both the original and the "During handling" block.
- **Breakpoints**: drop `breakpoint()` at the suspect line and run the failing test with `pytest -x -s --pdb` to inspect locals at the failure.
- **Boundary logging**: `logging.getLogger(__name__).debug(...)` on the inputs and return value of the suspect function; run with `--log-cli-level=DEBUG`.
- **Async**: `PYTHONASYNCIODEBUG=1` (or `asyncio.run(main(), debug=True)`) reports slow callbacks and never-awaited coroutines.
