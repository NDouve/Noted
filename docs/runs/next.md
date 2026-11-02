# Next run: move the build team to the private repo, then Codex fixes

Approved by the maintainer. Pull main first. Decision numbers are this repo's.

**Area audit for this run:** `area-data-integrity` (this run changes recovery and storage again).

## Part A: move the build team to the private repo `NDouve/Noted-build`

The maintainer created `NDouve/Noted-build` (private, empty). The public repo keeps only the app. Do Part A first, completely, before any code work.

### Layout on this machine
- `C:\Users\ngdou\Documents\dev\Noted-build\` is a clone of `Noted-build`. It is the workspace Claude Code is started from from now on.
- The public repo is cloned inside it as `Noted-build\noted\`, a fresh clone of `NDouve/Noted`. `noted/` is listed in the private repo's `.gitignore`.
- The old checkout `Documents\dev\Noted` stays untouched until everything below works. Then say in the report that it can be deleted by hand.

### What moves to the private repo (and is removed from the public one)
| Public path | Private path |
|---|---|
| `.claude/agents/*` | `.claude/agents/*` |
| (hooks, not yet committed) | `.claude/settings.json`, with the hooks from report 2026-11-02-01 item 5, adjusted for the new paths |
| CLAUDE.md "Build team and delegated authority" section | private `CLAUDE.md` (build-team rules: agents, delegated authority, the run loop, review cadence, cleanup). It points to `noted/CLAUDE.md` for the app's rules |
| `AGENTS.md` | `AGENTS.md` (the Codex reviewer instructions; content unchanged except paths) |
| `docs/runs/*` (reports, README) | `runs/` |
| `docs/reviews/*` (reports, README, prompts) | `reviews/` |
| `app/scripts/codex-review.ps1`, `app/scripts/cleanup-run.ps1` (+ their tests) | `scripts/` |

`app/scripts/screenshot-window.ps1` stays public; it is app tooling.

- A gitignored `local.md` in the private repo holds this machine's specifics: the GPU limits, and the Codex path `C:\Users\ngdou\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe`. `pm.md` says to read it if present. Nothing machine-specific goes in committed files.
- **Clean the agent files while moving them.** There must be one rule per topic, with no duplicates (pm.md currently has two codex-search rules). The Codex rule becomes one line: find it with `Get-Command codex`, then the path in `local.md`, then the standard install folders. From now on, editing an agent rule means replacing it, never appending a second version.
- Every path in the moved files is updated: the code lives under `noted/`, and the reports and reviews under `runs/` and `reviews/`. The PM pulls both repos at the start of a run and reads `runs/next.md` from the private repo. Code commits go to `noted/` and run reports to the private repo.
- In the public repo, remove the moved files, keep `CLAUDE.md`'s app rules, and add a one-line note to its working rules: "Build tooling and run history live in a separate private repository." Don't name it. Don't rewrite history.
- Re-point everything that used the old checkout's paths:
  - Rebuild the release under `Noted-build\noted\`.
  - Re-register `noted_mcp` with Claude Code at the new exe path.
  - Recreate both shortcuts with `-ResetIconCache`.
  - Check that `settings.json` (`%APPDATA%\Noted`) and the AI link are unaffected; they're per-user, not per-checkout.
- If committing `.claude/settings.json`, `CLAUDE.md` or the agent files is blocked in either repo, leave them uncommitted, list them in the report and keep going.

### Verify before Part B
- Claude Code started from `Noted-build` lists the four agents (`/agents`).
- The hooks fire on SubagentStop and Stop; `/hooks` shows them.
- `scripts/codex-review.ps1` runs Codex on `noted\` and Codex picks up `AGENTS.md`. If it doesn't, place a copy or a pointer where Codex reads it, inside the private repo only, and say what you did.
- `scripts/cleanup-run.ps1 -WhatIf` sees the new layout's worktrees.

## Part B: accepted Codex findings

Each fix gets a failure-injection regression test that fails without the fix. Mark each one `fixed (<commit>)` when it's done.

From `reviews/2026-11-02-codex-run-diff.md` (moved from `docs/reviews/`):
- **R-1 (P0):** recovery entries trusted before validation. Do both: (a) validate an existing envelope fully (embedded page, base and file name) before it may be replaced or count as superseding; (b) refuse to write over an invalid slot, writing to `_dup<n>` instead. Test a write over an invalid slot, and settling a valid tmp against an invalid later envelope.
- **R-2 (P1):** a landed marker is lost when conflict records combine. Take the marker from both inputs, independent of object identity.
- **R-3 (P1):** prune revoked codes on app-side changes, both on revoke and on app-side log trims.

From `reviews/2026-11-02-codex-run-diff-2.md`:
- **R-1 (P0):** attachment landing races a non-hash file. Publish non-hash names with an exclusive create or link, and never use the delete fallback for them. If a different file arrives at that name, keep both and report the collision.

Also accepted, from report 2026-11-02-01:
- An exclusive save in `PageStore`, to close the last restore and conflict-copy windows (item 6).
- Formula dependencies evaluated with an explicit stack, so a long running total doesn't overflow and the result doesn't depend on evaluation order (item 7).

Not now: the `crypto` dependency for streamed hashing (item 8).

## Finish
Analyze, all tests and the integration suite, push both repos, confirm CI on the public repo, and rebuild the release. Curate (public `docs/decisions.md`): the build tooling's move out of the public repo (no repo name), and the fixes. Run Codex (run-diff, then `area-data-integrity`) and commit their reports to the private `reviews/`. The report goes to the private `runs/`, committed with the deletion of `runs/next.md`. Delete `docs/runs/next.md` in the public repo once the private copy exists. The report must include the exact command to start the next session from the new workspace.
