# Runs

A run is one batch of work on Noted, led by the build team in `.claude/agents/` under the rules in CLAUDE.md ("Build team and delegated authority").

## The loop

1. **Queue.** The maintainer writes the next run in `docs/runs/next.md`: what to build, checks, and anything to curate or report.
2. **Start.** In Claude Code, at the repository root: *Run docs/runs/next.md as the PM*. The session takes the PM role from `.claude/agents/pm.md` (subagents can't start other subagents, so the PM is the main session) and uses `builder`, `reviewer` and `reviewer-ui` as subagents.
3. **Build.** The PM splits the run into tasks. Builders run in parallel only on separate files, each in its own worktree under `.claude/worktrees/`. Every diff is reviewed; visible changes are also screenshot-checked.
4. **Decide or park.** The PM decides what the delegated-authority rules allow, and logs it. Anything else is parked, not asked: the run goes on, and the question goes in the report.
5. **Finish.**
   - `flutter analyze` and all tests, and the integration suite when the app changed;
   - push, and confirm CI is green;
   - rebuild the release exe and zip;
   - curate `docs/decisions.md`;
   - the independent Codex review of the run's changes (and any area audit `next.md` names), with `app/scripts/codex-review.ps1`. Reports go to `docs/reviews/`, unchanged;
   - cleanup: stop the run's background agents and shells, then `app/scripts/cleanup-run.ps1` ends leftover Dart and `flutter_tester` processes and removes leftover worktree folders. Claude Code hooks in `.claude/settings.json`, once that file is in the repository, also run it whenever a subagent or the session stops.
6. **Report.** The PM writes `docs/runs/YYYY-MM-DD-NN.md` (`NN` counts that day's runs from 01) and **deletes `next.md` in the same commit**, then pushes. An empty queue means the run is done.

## Review cadence

- **Every run:** the Codex run-diff review runs at the end, automatically.
- **Area audits:** every `next.md` names one, chosen by the maintainer's PM chat. The rotation is `area-data-integrity` → `area-invariants` → `area-spec-drift` → `area-dead-code`, with `area-data-integrity` again whenever a run changes storage, sync, recovery or AI writes.
- **Triage:** after each run, the maintainer's PM chat reads the new reports, sets each finding to accepted or rejected with a reason, and queues the accepted ones in the next `next.md` by report and R-number. Rejected findings stay rejected.

## Report format

Technical only. No personal information: no names other than the maintainer's handle, no email addresses, no account or machine identifiers.

```markdown
# Run YYYY-MM-DD-NN: <short title>

## Summary
Two to five lines: what the run delivered and its state (CI, release).

## Done
What was built, per task, with the commits.

## Checks
Analyze, tests per package (counts), the integration suite, CI run, release build.

## Reviews
Findings from `reviewer` and `reviewer-ui`: each blocking finding and how it was resolved; non-blocking findings fixed or left (and why).

## Independent review
For each Codex report: its path, the count of findings by severity, and each P0 and P1 finding (R-number, title, one line). P0 findings are also listed first under "Needs the maintainer". Findings are reported as written, not triaged. If the review didn't run, why.

## Decisions the PM made
Each delegated decision (Box API addition, Dart/Flutter-team dependency at its exact version, new box package) and each routine judgement call, with the reason.

## Needs the maintainer
Each parked question: what it is, the options, and the PM's recommendation. "None." if empty.

## Hand checks
Short steps the maintainer can try in the app, each with what should happen.

## Screenshots
Paths of the screenshots `reviewer-ui` took (scratch data), with what each shows. Write them from `%TEMP%` (or another environment variable), never with a user folder name.
```
