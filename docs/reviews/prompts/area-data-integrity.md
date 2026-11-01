Read AGENTS.md at the repository root first and follow it.

You are running unattended. Do not create, change or delete any file. Your final message is the whole report: the script that ran you writes it to docs/reviews/ and adds the header (reviewer, commit, base). Start your final message with a "## Scope" line or two, then "## Findings" with one entry per finding in the format in docs/reviews/README.md (### R-<n> ..., every finding Status: open). If there are none, write "No findings." Finish with "## Not checked": anything in scope you could not check, and why.

Before reporting, read the earlier reports in docs/reviews/. Do not report again a finding whose status is rejected or fixed unless the code has changed since; if a finding that is open or accepted still applies, name its report and R-number instead of repeating it.

## Scope: data integrity

Audit the data path: saving and loading pages, file-based sync and OneDrive conflict-copy merging, per-box conflicts, the recovery store, encrypted boxes, image and file boxes' stored files, and writes by AI (through the app, and by noted_mcp while Noted is closed).

Look for anything that can lose, corrupt or silently overwrite user data; break invariant 2 (pass-through of unsupported box data) or invariant 3 (encrypted plaintext); or leave a crash mid-save in a bad state. Also list the Active entries in docs/decisions.md about storage or sync that have no implementation or no test.
