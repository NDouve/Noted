# Codex review: run-diff, 2026-11-02

- Reviewer: Codex (codex exec, read-only sandbox), run by app/scripts/codex-review.ps1
- Prompt: docs/reviews/prompts/run-diff.md
- Commit reviewed: 4af04a6
- Base: 28b9e10

## Scope

Read-only review of `28b9e10..4af04a6`, focused on changed persistence, recovery, merging, AI access, cleanup, and their direct callers. Read repository instructions, relevant Active decisions, and the earlier data-integrity report. No files were changed.

## Findings

### R-1 Recovery replacement and cleanup trust entries that replay rejects

- Severity: P0
- Location: app/lib/src/recovery_store.dart:247, :281, :408, :473; decision 0124.
- What happens: `_peek` parses envelope fields but does not validate the embedded page, base, or filename identities. `write` therefore overwrites an entry whose metadata matches the requested page even when its embedded page belongs to another page—the exact entry that `list` rejects and promises to preserve. Migration and temporary-file cleanup also use these unvalidated envelopes as evidence that an older recovery copy is superseded. For example, a valid temporary entry is deleted when an existing envelope has matching metadata and a later timestamp, even if that envelope contains an unreadable page. This can destroy the only usable recovery copy. Validate existing envelopes fully before treating them as replaceable or as evidence for deleting another generation.
- Test coverage: Partial. The identity tests in `app/test/recovery_store_test.dart` verify rejection during listing; they do not subsequently write to that slot or settle a valid temporary entry against an invalid later envelope.
- Confidence: confirmed by static control-flow trace. This is a destructive replacement/cleanup defect in the new layout, distinct from the earlier report’s R-6 replay-identity finding.
- Status: open

### R-2 Combining conflict records can discard the copy’s landed marker

- Severity: P1
- Location: packages/noted_core/lib/src/merge/conflict_copy.dart:141, :145; decision 0120.
- What happens: When the original wins and merging adds conflict records, `r.withConflicts(want)` creates a new object. The subsequent `identical(r, o)` check is then false, so marker inheritance reads the original again instead of the copy. If only the copy has a landed marker, the resulting box loses that outstanding placement issue. Reproduce with equal-revision boxes where the copy carries both a landed marker and an additional conflict record. Preserve the selected side explicitly, or consult both inputs for the marker independently of object identity.
- Test coverage: Partial. `packages/noted_core/test/page_issues_test.dart` tests “a marker on either side is kept,” but its inputs do not also require combining conflict records.
- Confidence: confirmed by static control-flow trace.
- Status: open

### R-3 App-side changes bypass revoked-code pruning

- Severity: P1
- Location: app/lib/src/ai/ai_access_service.dart:89, :98, :411; app/lib/src/ai/ai_link_authority.dart:654; decision 0126.
- What happens: Revoking an unused code calls `changed()`, which updates `_stamp` without pruning. The next poll sees that same stamp and returns before `pruneRevokedCodes()`. Consequently, the code remains until restart or an independently detected file change, contrary to the requirement to remove unused codes immediately after revocation. App activity-log updates use the same notification path, so trimming away a revoked code’s last activity can also bypass pruning. Run pruning on these app-side mutations before recording their final stamp.
- Test coverage: Partial. `app/test/ai_prune_revoked_test.dart` invokes pruning directly or changes a log externally. It does not exercise `service.revoke()` with polling enabled or app-side log trimming followed by `changed()`.
- Confidence: confirmed by static control-flow trace.
- Status: open

## Not checked

- Runtime tests, analysis, failure injection, and mutation testing were not run because they create files; test coverage was assessed statically.
- Live sync-provider races, filesystem failures, and Windows cleanup execution were not reproduced.
- Visual behavior and exhaustive test-by-test assessment across all 122 changed files were not completed; review concentrated on the persistence and merge paths above.
- Encryption implementation and unrelated code outside the diff and direct callers were excluded.
