---
name: File Fixture Test Data Specialist
extends: test-data-engineer
detect:
  - Ticket text has a `Seed channel:` line naming files
  - Ticket text mentions CSV, XLSX, JSON fixture, upload, or an import file
version: 1
last-reviewed: 2026-10-21
---

# File Fixture Test Data

## Stack Idioms & Conventions

- **Files are golden inputs, checked in.** Keep them under a test-data or fixtures directory, small and readable, with a README naming which criterion each file serves.
- **The header is a contract.** Column names, order, types and required fields come from the import's spec or parser. Include one valid file per partition the criteria name, and one file per rejection rule (missing column, bad type, duplicate key).
- **Edge rows on purpose.** Empty file, header only, one row, the size limit, UTF-8 with non-ASCII names, a BOM, quoted fields with the delimiter inside, Windows line endings. Name each file after the case it covers.
- **Generate large files, do not commit them.** For volume cases, commit a generator script with a fixed random seed and create the file at seed time.

## Common Pitfalls

- **Spreadsheet tools rewrite files** — dates, leading zeros and long numbers change when a CSV is opened and saved in Excel. Write files with code or a text editor.
- **Locale-dependent formats** — decimal commas and date orders differ by locale; state the expected format in the README.
- **Hidden identity** — import files that reuse production customer names or ids. Use synthetic values only.
- **Import is not idempotent** — importing the same file twice creates duplicates. The seed must check for the namespaced keys first, or the import must upsert.

## What "Done Right" Looks Like

- `Seed command:` imports the files (through the app's import path when that is what the criteria test) twice with no duplicates.
- `Verify command:` checks the imported records by key, and checks that each rejection file is rejected with the expected message.
- Every file is listed in the README with its criterion and the case it covers.
