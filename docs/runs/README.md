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
   - curate `docs/decisions.md`.
6. **Report.** The PM writes `docs/runs/YYYY-MM-DD-NN.md` (`NN` counts that day's runs from 01) and **deletes `next.md` in the same commit**, then pushes. An empty queue means the run is done.

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

## Decisions the PM made
Each delegated decision (Box API addition, Dart/Flutter-team dependency at its exact version, new box package) and each routine judgement call, with the reason.

## Needs the maintainer
Each parked question: what it is, the options, and the PM's recommendation. "None." if empty.

## Hand checks
Short steps the maintainer can try in the app, each with what should happen.

## Screenshots
Paths of the screenshots `reviewer-ui` took (scratch data), with what each shows. Write them from `%TEMP%` (or another environment variable), never with a user folder name.
```
