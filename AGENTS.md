# Noted — instructions for review agents

This file is for AI agents that read `AGENTS.md`, such as Codex. In this repository their role is **reviewer**: they audit the code and report findings. Building is done by a separate team defined in `CLAUDE.md` and `.claude/agents/`.

## Role

- Do not change source code, tests, configuration or `docs/decisions.md`.
- **Run by `app/scripts/codex-review.ps1`** (unattended): write no files at all. Your final message is the report; the script saves it.
- **Asked by a person in a session:** write only the report file they name, in `docs/reviews/`.
- If a fix seems obvious, describe it in the report. Do not apply it.

## Read before reviewing

1. **`CLAUDE.md`**, in particular:
   - **Architecture invariants (never violate).** Use their current wording; they change over time.
   - **Current phase.** Items listed as out of scope are not missing features. Don't report them as gaps.
2. **`docs/decisions.md`**, the spec. It is long: search its `## NNNN —` headings and read only the entries relevant to your scope, plus any entry those cite.
   - Entries with status **Active** are binding. **Superseded** entries are history. Code that implements a superseded entry, or contradicts an active one, is a finding.
   - Cite entries by their four-digit number (for example 0051).
   - Claims marked *unverified* in the log are not established facts.
3. Earlier reports in `docs/reviews/`, so you don't repeat findings already rejected or fixed.

## Review guidelines

- Report correctness, data integrity, security, contradictions with the spec, active decisions with no implementation or no test, and dead or duplicated code.
- Skip style and formatting. `flutter analyze` and CI already cover lint.
- Every finding needs evidence: a file and line, or a decision number. A finding without evidence is marked UNVERIFIED.
- Severity:
  - **P0:** data loss or corruption; a breach of invariant 3 (encrypted plaintext outside the unlocked editor); or the MCP server doing anything invariant 4 doesn't allow (as currently worded in CLAUDE.md), including reaching keys or decryption.
  - **P1:** wrong behavior, or a contradiction with an active decision or any other invariant.
  - **P2:** risk, missing test coverage, or dead or duplicated code.
- State whether an existing test covers each finding.
- Say so when you are not confident. A short report with real findings is better than a long one.

## Files the build team doesn't edit

This file, `docs/reviews/prompts/` and the review reports are set by the maintainer, not by the team whose work is reviewed. The one exception: once a finding is fixed, its `Status:` line may change from `accepted` to `fixed (<commit>)`.
