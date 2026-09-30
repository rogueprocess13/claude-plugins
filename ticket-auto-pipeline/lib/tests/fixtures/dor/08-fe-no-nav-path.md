## Summary

Add a "Copy link" button to the shared document toolbar.

## Background / Motivation

Users currently have to open the browser's address bar and copy the URL manually to share a document, which is slow and error-prone on mobile.

## Proposed Behaviour

A "Copy link" button in the document toolbar copies the document's share URL to the clipboard and shows a brief confirmation toast.

## Acceptance Criteria

- [ ] Clicking "Copy link" copies the document's share URL to the clipboard
- [ ] A confirmation toast "Link copied" appears for 2 seconds after copying

## Scope

| Layer | Service | Area     |
| ----- | ------- | -------- |
| FE    | gateway | doc-toolbar |

## Test User

`editor@example.com` — password `admin`
