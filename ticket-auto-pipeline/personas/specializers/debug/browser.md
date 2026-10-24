---
name: Browser Debugging
extends: debugger
detect:
  - angular.json
  - package.json with react, react-dom or vue
version: 1
last-reviewed: 2026-10-24
---

# Browser Debugging

- **Console and network**: reproduce with Playwright, then read `browser_console_messages` and the failed requests (status, payload, response body) before reading any component code.
- **Page state**: take a `browser_snapshot` at the failing step; compare what is rendered with what the criterion expects.
- **Angular**: in the console, `ng.getComponent(el)` shows a component's live fields; a long zone stack in the error points at the async origin.
- **Subscriptions**: count active RxJS subscriptions (or React effect cleanups) before and after leaving the view; a growing count means a leak.
