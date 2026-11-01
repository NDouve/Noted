Read AGENTS.md at the repository root first and follow it.

You are running unattended. Do not create, change or delete any file. Your final message is the whole report: the script that ran you writes it to docs/reviews/ and adds the header (reviewer, commit, base). Start your final message with a "## Scope" line or two, then "## Findings" with one entry per finding in the format in docs/reviews/README.md (### R-<n> ..., every finding Status: open). If there are none, write "No findings." Finish with "## Not checked": anything in scope you could not check, and why.

Before reporting, read the earlier reports in docs/reviews/. Do not report again a finding whose status is rejected or fixed unless the code has changed since; if a finding that is open or accepted still applies, name its report and R-number instead of repeating it.

## Scope: the architecture invariants

Check the whole codebase against the five architecture invariants in CLAUDE.md, using their current wording (and the decisions they cite). For each invariant, say how you checked it (which files, searches and tests), then report each violation or gap as a finding. Also report invariants that no test enforces.
