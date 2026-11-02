# Next run: data-integrity fixes (Codex review), automatic cleanup, small fixes

Approved by the maintainer. Pull main first. Decision numbers are this repo's.

**Priority:** the data-integrity fixes in section 1 come first. They are the reason for this run. Don't start section 3 until section 1 is reviewed and merged.

**Area audit for this run:** none extra. The Codex run-diff review at the end must cover this run's fixes (see section 5).

## 1. Accepted Codex findings: `docs/reviews/2026-11-01-codex-data-integrity.md`

Codex reviewed commit a960f30, before run 2026-11-01-04, so line numbers have moved. Re-locate each finding in the current code first. If one no longer applies, say exactly why in the report instead of fixing it.

Every fix gets a **failure-injection regression test** that fails without the fix: simulate the sync writer, the crash or the failing delete at the exact point the finding describes. When a fix is merged, change that finding's status from `accepted (...)` to `fixed (<commit>)`, as pm.md allows. Don't change anything else in the review file.

Do them in this order:

**First: destructive overwrites and deletions (P0)**
- **R-1:** an unreadable or newer-format replacement of the open page must block the save. Keep the file on disk, put the local edits in recovery, mark the page read-only and show the error until a readable version can be merged.
- **R-2:** never delete a conflict copy unless its current bytes still match the version that was merged. If the copy changed, merge it again. Revalidate the destination before replacing it too.
- **R-3:** AI writes to a page that isn't open must go through the same guarded save path as the open page: keep the loaded page as the merge base, reread before committing, merge external changes, and recheck the conflict and permission rules against the result. One guarded persistence path for open and closed pages. Check the closed-app writer in noted_mcp (0117) for the same race and fix it the same way if it applies.
- **R-9:** a failed move rollback must never delete a verified destination copy unless an intact source is positively established. Track restoration per page, and report a partial move honestly.

**Then: recovery identity and lifecycle (P1/P2)**
- **R-5 (P0):** recovery file names use the same platform-correct location identity as `Notebook._key`. Case folding only on Windows. Migrate existing entries without losing any.
- **R-4:** keep a replay marker until recovered assets are copied and verified, and retry after a restart even if the page itself already landed.
- **R-6:** validate that `metadata.pageId`, the page's id, the base's id and the file name all agree before accepting an entry; keep and report mismatches.
- **R-7:** replay failures go into the same problems list the sidebar shows under "Can't open", and clear only after a successful replay.
- **R-10:** make a recovery entry atomic: one complete generation (a manifest pointing at immutable files, or a single envelope), with startup handling for incomplete generations.

**Rejected, don't act on it:** R-8 (superseded by 0120).

## 2. Automatic cleanup

### Cleanup script
`app/scripts/cleanup-run.ps1`:
- **Processes:** ends `flutter_tester` and `dart` processes whose command line or working directory is inside this repository, including its worktrees. Never touch processes outside the repository, other Flutter or Dart work, or Noted running from the release folder.
- **Worktrees:** runs `git worktree prune`, then removes folders under `.claude\worktrees\` that aren't registered worktrees. Never removes the main checkout, a worktree with uncommitted changes, or anything outside `.claude\worktrees\`.
- **Behaviour:** prints what it ended and removed. Idempotent. `-WhatIf` lists without acting.
- **Tests:** cover the selection logic without killing real processes.

### Hooks
In `.claude/settings.json`, run the script on **SubagentStop** and **Stop**. A hook failure prints a warning and never stops the session. If committing the file is blocked, leave it uncommitted and say so in the report.

### Agent rules
- **`builder.md`:** no background commands without a time limit; stop every background command you started before handing back.
- **`pm.md`:**
  - Before the report, stop all background agents and shells from the run, run `cleanup-run.ps1`, and list what was stopped.
  - Pull main before looking for `next.md`.
  - If `codex` isn't on PATH, also look for the CLI where its installers put it before giving up, and report the path searched.

If committing the agent files is blocked, leave them uncommitted and say so.

## 3. Small fixes
- **Linux CI:** fix the three Linux-only test failures. Have the formula parser cap nesting depth explicitly, and have the link-server tests accept Linux's broken-pipe and reset errors as "refused". Then make the Linux job blocking.
- **Revoked codes:** prune a revoked code once its activity has aged out of both logs.
- **Test helper:** one shared helper that settles saves inside the fake-time zone before teardown. Replace the bounded flush in `search_ui_test` and use it in every app test that flushes the notebook.

## 4. Review cadence (record it)
Add a "Review cadence" section to `docs/runs/README.md`:
- **Every run:** the Codex run-diff review runs at the end, automatically.
- **Area audits:** every `next.md` names one, chosen by the maintainer's PM chat. The rotation is `area-data-integrity` → `area-invariants` → `area-spec-drift` → `area-dead-code`, with `area-data-integrity` again whenever a run changes storage, sync, recovery or AI writes.
- **Triage:** after each run, the maintainer's PM chat reads the new reports, sets each finding to accepted or rejected with a reason, and queues the accepted ones in the next `next.md` by report and R-number. Rejected findings stay rejected.

## 5. Finish
1. Run analyze, all tests and the integration suite, then push and confirm CI. Rebuild the release exe and zip.
2. Curate the data-integrity fixes, the cleanup and hooks, the review cadence, and the small fixes.
3. Run the Codex run-diff review (`codex-review.ps1 -Base <this run's start commit>`) and commit its report.
4. Write the report in the standard format, with a table: each R-number, its fix commit, its regression test, and its new status.
