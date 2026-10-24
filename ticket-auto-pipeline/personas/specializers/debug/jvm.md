---
name: JVM Debugging
extends: debugger
detect:
  - pom.xml
  - build.gradle
  - build.gradle.kts
  - settings.gradle
version: 1
last-reviewed: 2026-10-24
---

# JVM Debugging

- **Stack traces**: read the `Caused by:` chain from the bottom up; the deepest frame in our own packages is where to start, framework frames above it are transport.
- **Snapshots**: `jstack <pid>` or `jcmd <pid> Thread.print` for threads (take two, a few seconds apart, to spot a stuck one); `jcmd <pid> GC.heap_info` for memory.
- **Boundary logging**: log inputs and outputs at the entry and exit of the suspect call, tagged with the request correlation id, then grep one request end to end.
- **Breakpoints**: start a local JVM with `-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5005` and attach; never against a shared environment.
