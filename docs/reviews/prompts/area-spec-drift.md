Read AGENTS.md at the repository root first and follow it.

You are running unattended. Do not create, change or delete any file. Your final message is the whole report: the script that ran you writes it to docs/reviews/ and adds the header (reviewer, commit, base). Start your final message with a "## Scope" line or two, then "## Findings" with one entry per finding in the format in docs/reviews/README.md (### R-<n> ..., every finding Status: open). If there are none, write "No findings." Finish with "## Not checked": anything in scope you could not check, and why.

Before reporting, read the earlier reports in docs/reviews/. Do not report again a finding whose status is rejected or fixed unless the code has changed since; if a finding that is open or accepted still applies, name its report and R-number instead of repeating it.

## Scope: drift between the spec and the code

Compare docs/decisions.md with the code, for the features listed as in scope in CLAUDE.md ("Current phase"). Search the decision headings and read only the entries for those features. Report:
- Active entries with no implementation, or implemented differently from what they say;
- behaviour from Superseded entries that is still in the code;
- features in the code that no Active entry describes;
- Active entries that contradict each other.
