# Next run: automatic cleanup of leftover processes, agents and worktrees

Approved by the maintainer. Pull main first.

Runs keep leaving things behind: background builder agents that never stop, background shells, `flutter_tester` and `dart` processes, and worktree folders under `.claude\worktrees\` that can't be deleted while those processes hold files. Prevent it.

## 1. Cleanup script

`app/scripts/cleanup-run.ps1`:
- Ends `flutter_tester` and `dart` processes whose command line or working directory is inside this repository (including its worktrees). Never touch processes outside the repository, any other Flutter or Dart work, or Noted itself when it runs from the release folder.
- Removes worktrees under `.claude\worktrees\` that are no longer in use (`git worktree prune`, then remove folders that aren't registered worktrees). Never removes the main checkout, a worktree with uncommitted changes, or anything outside `.claude\worktrees\`.
- Prints what it ended and removed. Idempotent; safe to run any time. A `-WhatIf` switch lists without acting.
- Tests for the selection logic (which processes and folders qualify), run without killing real processes.

## 2. Run it automatically: Claude Code hooks

In `.claude/settings.json`, add hooks that run the script on **SubagentStop** and on **Stop** (the session going idle). Keep each hook fast and non-blocking: a failure prints a warning and never stops the session. If committing `.claude/settings.json` is blocked, leave it uncommitted and say so in the report.

## 3. Rules for the agents

- `builder.md`: don't start background commands unless they have a time limit; stop every background command you started before handing back.
- `pm.md`: the last step before writing the report is to stop all background agents and shells from the run, run `cleanup-run.ps1`, and confirm nothing is left (list what was stopped in the report). Also: pull main before looking for `docs/runs/next.md`.

If committing the agent files is blocked, leave them uncommitted and say so.

## 4. Missed reviews

If the `codex` CLI is installed and logged in by the time you reach the end of this run, run the run-diff review that run 2026-11-01-04 missed (`codex-review.ps1 -Base 28b9e10`) and commit its report. **Don't** run `area-data-integrity` again: the maintainer already has that report (`docs/reviews/2026-11-01-codex-data-integrity.md`) and commits it through the QC process; leave it alone. Then run this run's own review as usual. If `codex` isn't installed, say so and carry on.

## 5. Finish

Analyze, all tests, push, confirm CI. No release rebuild is needed unless app code changed. Report in the standard format, including the cleanup script's output from the end of this run.
