# Reviews

Independent review reports on Noted, one file per review. Reviewers follow `AGENTS.md` at the repository root.

## How reviews run

- **Every run, automatically.** At the end of a run the PM runs `app/scripts/codex-review.ps1 -Base <commit the run started from>`. Codex reviews that run's changes with the fixed prompt `prompts/run-diff.md`, and the script writes the report here.
- **Area audits, when asked.** `next.md` (or the maintainer by hand) names one of the other prompts in `prompts/`: `area-data-integrity`, `area-invariants`, `area-spec-drift`, `area-dead-code`. These read much more code and use more of the Codex plan's usage.
- **By hand**, in a Codex session, with the scope given in the chat. The reviewer writes the report file itself.

The prompts and this folder's reports are not edited by the build team (see `AGENTS.md`), so the build team never sets the scope of its own review.

## File name

`YYYY-MM-DD-codex-<prompt>.md` (with `-2`, `-3`, ... for a second review that day), or for a hand review `YYYY-MM-DD-<reviewer>-<topic>.md`.

## Report format

The header gives the reviewer, the date, the commit reviewed and the scope. The script writes it as `- Commit reviewed: <commit>`; the next run-diff review starts from that commit when no base is given.

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

Each finding starts as `open`. Triage (by the maintainer, outside the build team) changes it to one of:
- `accepted`: real; to be scheduled in a run
- `rejected`: not a real problem, with the reason

Once an accepted finding is fixed, the PM changes its status to `fixed (<commit>)`. That is the only edit the build team makes to a report.

Rejected findings stay in the file, so later reviews don't raise them again.
