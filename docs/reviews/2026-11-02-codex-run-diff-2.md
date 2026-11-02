# Codex review: run-diff, 2026-11-02

- Reviewer: Codex (codex exec, read-only sandbox), run by app/scripts/codex-review.ps1
- Prompt: docs/reviews/prompts/run-diff.md
- Commit reviewed: 965527f
- Base: bac2f75

## Scope

Read-only review of `bac2f75..965527f`, covering changed code and direct callers, architecture invariants, relevant Active decisions, and regression tests. Read both earlier review reports. No files were written.

## Findings

Previously reported findings still apply: **R-1 and R-3 in `docs/reviews/2026-11-02-codex-run-diff.md`**. They are not repeated here.

### R-1 Attachment recovery can overwrite a different file arriving during landing

- Severity: P0
- Location: app/lib/src/notebook.dart:3526, :3530, :3536, :3538; decision 0124.
- What happens: `_landFiles` checks whether a non-hash destination exists before copying and verifying the temporary file. If a sync client creates a different `note.txt` during those awaited operations, the subsequent rename replaces that newly arrived file. If the rename fails, the fallback explicitly deletes the destination without checking its content, then retries. This destroys content that recovery never verified, contradicting 0124’s requirement to preserve different files sharing a non-hash name. Use publication that refuses an existing destination for non-hash names; retain both files and report the collision.
- Test coverage: Partial. `app/test/recovery_test.dart:614` covers a different destination present before landing starts, but not one arriving between the existence check and publication.
- Confidence: confirmed by static control-flow and interleaving analysis; not reproduced at runtime.
- Status: accepted (queued in docs/runs/next.md, 2026-11-02)

## Not checked

- Runtime tests, analysis, and mutation testing were not run because they create files; test coverage was assessed statically.
- Live sync races, filesystem failure injection, and cleanup-script execution were not performed.
- Visual behavior and exhaustive test-by-test verification across all changed files were not completed.
- Unchanged merge implementation containing the earlier run review’s R-2 was outside this diff’s focused review.
