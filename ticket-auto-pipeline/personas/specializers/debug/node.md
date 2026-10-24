---
name: Node.js Debugging
extends: debugger
detect:
  - package.json without angular, react or vue
version: 1
last-reviewed: 2026-10-24
---

# Node.js Debugging

- **Breakpoints**: `node --inspect-brk <entry>` (or `--inspect` for a running service) and attach Chrome DevTools or the editor debugger.
- **Uncaught errors**: `node --trace-uncaught --trace-warnings` prints where an unhandled throw or rejection originated, not just where it landed.
- **Source maps**: run with `--enable-source-maps` so stack frames point at the TypeScript line instead of compiled output.
- **Event loop**: measure lag with `perf_hooks.monitorEventLoopDelay()` when a request hangs; a high p99 points at blocking synchronous work.
