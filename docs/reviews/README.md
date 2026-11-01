# Reviews

Independent review reports on Noted, one file per review. Reviewers follow `AGENTS.md` at the repository root.

## File name

`YYYY-MM-DD-<reviewer>-<topic>.md`, for example `2026-11-01-codex-data-integrity.md`.

## Report format

Start with the reviewer, the date, the commit reviewed (`git rev-parse --short HEAD`) and the scope.

Then one entry per finding:

```
### R-<n> <short title>
- Severity: P0 | P1 | P2
- Location: <file>:<line>, and/or decision <number>
- What happens: <behavior, and how to reproduce it>
- Test coverage: <test that covers it, or "none">
- Confidence: confirmed | UNVERIFIED
- Status: open
```

## Status

Each finding starts as `open`. Once it is triaged, its status changes to one of:
- `accepted`: real, to be fixed in a run (name the run)
- `fixed`: name the commit
- `rejected`: not a real problem, with the reason

Rejected findings stay in the file, so later reviews don't raise them again. Reviewers check earlier reports in this folder before writing a new one.
