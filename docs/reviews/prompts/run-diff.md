Read AGENTS.md at the repository root first and follow it.

You are running unattended. Do not create, change or delete any file. Your final message is the whole report: the script that ran you writes it to docs/reviews/ and adds the header (reviewer, commit, base). Start your final message with a "## Scope" line or two, then "## Findings" with one entry per finding in the format in docs/reviews/README.md (### R-<n> ..., every finding Status: open). If there are none, write "No findings." Finish with "## Not checked": anything in scope you could not check, and why.

Before reporting, read the earlier reports in docs/reviews/. Do not report again a finding whose status is rejected or fixed unless the code has changed since; if a finding that is open or accepted still applies, name its report and R-number instead of repeating it.

## Scope: the changes in {{BASE}}..{{HEAD}}

Review what changed between commits {{BASE}} and {{HEAD}}: start with `git log --oneline {{BASE}}..{{HEAD}}` and `git diff --stat {{BASE}}..{{HEAD}}`, then read the diffs and, where needed, the code that calls the changed code.

Check:
- correctness and data integrity of the changed code;
- the architecture invariants in CLAUDE.md;
- contradictions with Active entries in docs/decisions.md, especially entries added or changed in this range: does the code do what the entry says?
- whether the tests added or changed would fail without the change, and changed behaviour with no test;
- code made dead or duplicated by the change.

Stay inside the diff and its direct callers. Problems elsewhere go under "Not checked" as one line each, not as findings.
