# Noted — instructions for review agents

This file is for AI agents that read `AGENTS.md`, such as Codex. In this repository their role is **reviewer**: they audit the code and report findings. Building is done by a separate team defined in `CLAUDE.md` and `.claude/agents/`.

## Role

- Do not change source code, tests, configuration or `docs/decisions.md`.
- The only file a review may create is its report in `docs/reviews/` (see `docs/reviews/README.md` for the format).
- If a fix seems obvious, describe it in the report. Do not apply it.

## Read before reviewing

1. **`CLAUDE.md`**, in particular:
   - **Architecture invariants (never violate).** A violation of any of the five is at least P1. Invariant 3 (encrypted plaintext) and invariant 4 (the MCP server's boundary) are P0.
   - **Current phase.** Items listed as out of scope are not missing features. Don't report them as gaps.
2. **`docs/decisions.md`**, the spec.
   - Entries with status **Active** are binding. **Superseded** entries are history. Code that implements a superseded entry, or contradicts an active one, is a finding.
   - Cite entries by their four-digit number (for example 0051).
   - Claims marked *unverified* in the log are not established facts.
3. The **Open items** and **Risks to test early** sections at the end of `docs/decisions.md`.

## Review guidelines

- Report correctness, data integrity, security, contradictions with the spec, active decisions with no implementation or no test, and dead or duplicated code.
- Skip style and formatting. `flutter analyze` and CI already cover lint.
- Every finding needs evidence: a file and line, or a decision number. A finding without evidence is marked UNVERIFIED.
- Severity:
  - **P0:** data loss or corruption, plaintext leaking from an encrypted box, or the MCP server writing files or reaching keys.
  - **P1:** wrong behavior, or a contradiction with an active decision or an invariant.
  - **P2:** risk, missing test coverage, or dead or duplicated code.
- State whether an existing test covers each finding.
- Say so when you are not confident. A short report with real findings is better than a long one.
