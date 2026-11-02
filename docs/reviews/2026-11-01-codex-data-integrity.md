# Data integrity review

- Reviewer: Codex
- Date: 2026-11-01
- Commit reviewed: a960f3087979a75a83eee1c8708be1406b6f033a (a960f3), read from .git/HEAD and refs/heads/main; source observations concern the files currently on disk. Git status could not be established: Git returned “this operation must be run in a work tree”.
- Scope: page load/save, file watching, OneDrive-style conflict copies, per-box merging/resolution, recovery, encrypted-box boundaries, and AI writes through the running app. Closed-app MCP writing was inspected for boundary context, not exhaustively audited.
- Rules: AGENTS.md, CLAUDE.md, docs/decisions.md and docs/reviews/README.md. There were no earlier review reports in docs/reviews.

## Assessment

The main paths exist and have substantial regression coverage, but the implementation does not yet provide reliable no-loss behavior across unreadable external replacements, concurrent sync writes, or several recovery failures. The highest-priority findings are destructive overwrites/deletions (R-1 through R-3 and R-9). Encryption is a deferred feature, not a demonstrated working protection in this build; no plaintext leak from an implemented encrypted editor was established.

“Confirmed” below means established from the code; only the two explicitly identified Dart probes were executed. Concurrency sequences are deterministic code-level interleavings, not claims of a reproduced live OneDrive incident.

## Findings

### R-1 Autosave overwrites an unreadable or newer-format replacement of the open page
- Severity: P0
- Location: app/lib/src/notebook.dart:2555, :2563, :3071, :3075, :3189; packages/noted_core/lib/src/format/page_format.dart:46. Decisions 0051 and 0035.
- What happens: open a page, replace its file externally with malformed JSON or a valid page whose format is newer than this app, then edit and flush the open page. The pre-save check records the replacement text and catches the format error. _knownUnreadable immediately returns for the current page, without making it read-only or stopping the save. _enqueueSave then writes the old in-memory page over the replacement. A parse failure is therefore treated as permission to destroy an unreadable file, including content belonging to a newer app. An ordinary read error is also treated as a missing file by _checkFile.
- Test coverage: none for this case. app/test/external_changes_test.dart:102 and :114 cover unreadable closed pages; :246 covers a valid unseen external change.
- Confidence: confirmed (static control-flow trace).
- Status: fixed (7c7375c, df71483, b993f94, 9b1ebcf, d424230)
- Suggested correction: return a distinct unsafe-to-save result from the pre-save read; retain the disk file, preserve local edits in recovery, and expose the error until a readable version can be merged.

### R-2 Conflict-copy cleanup deletes a newer copy that was never merged
- Severity: P0
- Location: app/lib/src/notebook.dart:3048, :3116, :3127, :3146, :3157, :3167. Decision 0053.
- What happens: the watcher reads conflict copy C1; while the app merges and verifies C1, the sync provider replaces that same copy path with C2 containing additional edits. Verification compares the saved original against the in-memory C1. File(copyPath).delete() then removes C2 without reading or comparing it. Successful read-back of the destination does not prove the current source is the version that was merged. The closed-page original has a similar read/overwrite window at :3148–3155.
- Test coverage: none for source replacement during merge. app/test/conflict_copy_test.dart:246 and :261 cover a dropped write/read-back failure; :280 covers watcher pickup, not a changing source during cleanup.
- Confidence: confirmed (static interleaving).
- Status: fixed (7c7375c)
- Suggested correction: claim a stable source generation or retain the copy unless its current identity and bytes still match the consumed version; re-merge changed copies. Revalidate the destination before replacing it as well.

### R-3 AI writes to a closed page bypass the pre-save external-change merge
- Severity: P0
- Location: app/lib/src/notebook.dart:2469, :2482, :2499, :2738; packages/noted_core/lib/src/storage/page_store.dart:145. Decisions 0051 and 0106.
- What happens: while Noted runs with a different page open, an authorized AI write loads page P. A sync writer updates P after this load but before _write. _aiWriteClosed commits against the old page and calls _write directly, which saves without rereading or three-way merging. An edit to any other box can be silently overwritten, and a newly arrived conflict on the target is not rechecked. The in-process _saving queue orders app work but cannot serialize a sync provider. The open-page save at least invokes _checkFile; this path does not.
- Test coverage: none for an external disk edit between AI load and save. app/test/ai_write_test.dart:304 covers persistence; :743 covers AI queue ordering and opening a page concurrently; :827 covers a disappearing folder.
- Confidence: confirmed (static interleaving).
- Status: fixed (af822f1, b993f94, 9b1ebcf)
- Suggested correction: keep the loaded page as a merge base, reread before committing, merge external changes, and repeat conflict/permission checks against the resulting target. Use one guarded persistence path for both open and closed pages.

### R-4 Recovery is retired before its attachments have landed
- Severity: P1
- Location: app/lib/src/notebook.dart:2689, :2720, :2726; app/lib/src/recovery_store.dart:127. Decisions 0070 and 0098.
- What happens: both replay branches delete the recovery metadata and canvas before _landRecoveredAssets. If copying the assets fails or the app stops in between, the assets directory survives but there is no recovery entry left to trigger a retry. RecoveryStore.list only enumerates .canvas/.json entries, not orphan asset directories. The same device may still read the fallback bytes, but other devices see missing files, and subsequent launches do not complete the intended move.
- Test coverage: none for failure/crash between page replay and asset landing. app/test/attachments_test.dart:244 checks the successful recovery path.
- Confidence: confirmed (static trace).
- Status: fixed (d424230, be6ab4e, 99e6050)
- Suggested correction: keep a replay marker until assets are copied and verified; make retry work after restart even when the page itself already landed.

### R-5 Recovery entries collide for case-distinct storage locations
- Severity: P0
- Location: app/lib/src/recovery_store.dart:82–88; compare app/lib/src/notebook.dart:2773. Decision 0070.
- What happens: RecoveryStore._name lowercases every folder path on every platform. On a case-sensitive filesystem, /Notes and /notes are distinct storage locations. Recovery writes for the same page id in those locations use the same filename and the second replaces the first. Duplicate page ids are realistic when folders contain copied pages or a move leaves recovery behind. Notebook._key correctly limits case folding to Windows; recovery does not.
- Test coverage: none. app/test/recovery_test.dart:246 tests replacement of one page in one location, not distinct case-sensitive locations.
- Confidence: confirmed. An isolated Dart probe called RecoveryStore.write for /Notes and /notes with the same id; list() returned one entry. Executed on Windows with those paths stored as metadata; the actual case-sensitive-filesystem consequence follows from the unconditional naming function.
- Status: fixed (84c9e4b)
- Suggested correction: use platform-appropriate canonical location identity consistently for recovery naming; preserve existing entries when migrating names.

### R-6 Recovery accepts mismatched metadata, page and base identities
- Severity: P1
- Location: app/lib/src/recovery_store.dart:137–149; app/lib/src/notebook.dart:2659–2663, :2693. Decisions 0070 and 0077.
- What happens: the recovery reader validates that each component parses but never checks that metadata.pageId, page.id and base.id agree, or that the filename belongs to the metadata location/id. Replay then selects the target using the canvas page id and folder from the metadata, ignoring entry.pageId. A damaged or mismatched pair can be applied to the wrong page/location instead of being retained as an unverifiable entry.
- Test coverage: none for valid-but-mismatched components. app/test/recovery_test.dart:234 covers syntactically damaged files.
- Confidence: confirmed. An isolated Dart probe replaced an entry's canvas with a valid different-page canvas; list() accepted one entry with zero problems.
- Status: fixed (84c9e4b, 64a8d20, d424230)
- Suggested correction: validate all identities before accepting an entry, and retain/report any mismatch rather than replaying it.

### R-7 Unverifiable recovery replay is logged but not listed under Can't open
- Severity: P1
- Location: app/lib/src/notebook.dart:2637–2647, :2684–2687, :2709–2717; app/lib/src/recovery_store.dart:150–157. Decision 0077.
- What happens: only errors found during RecoveryStore.list populate recoveryProblems/recoveryDamaged. A readable entry that fails replay read-back or verifyRecoveredPage merely produces debugPrint output and returns. The entry is kept, but the promised sidebar reason is missing; general replay exceptions take the same log-only route.
- Test coverage: partial. app/test/recovery_test.dart:216 verifies that a failed check keeps the entry, but does not assert the sidebar/problem list; :234 covers parse failures only.
- Confidence: confirmed (static trace).
- Status: fixed (d424230)
- Suggested correction: retain per-entry replay failures in the same problems/damaged collections used by the sidebar and clear them only after successful replay.

### R-8 Unsupported boxes can be resolved destructively on a device that cannot run them
- Severity: P1
- Location: packages/noted_canvas/lib/src/conflict_dialog.dart:112, :199–212; packages/noted_canvas/lib/src/canvas_controller.dart:398, :408, :480. Decision 0035; decision 0119 explicitly leaves this behavior under maintainer consideration.
- What happens: inability to decode/run a box disables only Edit manually. Keep mine, Keep other version and Delete box remain enabled; the controller checks read-only status but not module support. They remove stored conflict versions on a device unable to inspect them properly. This contradicts the still-Active requirement that both versions remain until a supporting device resolves them. This is a known pending product decision, not a newly discovered lack of discussion.
- Test coverage: no enforcing test found. packages/noted_canvas/test/conflict_test.dart:124 tests ordinary resolution/undo. Core tests cover byte-preserving unsupported merges, not prohibition of unsupported resolution.
- Confidence: confirmed (static trace).
- Status: rejected: superseded. The maintainer decided that a device that can't open a box may settle its conflict by keeping one whole version or placing both, without reading the box data (decision 0120, which supersedes 0035's waiting rule). Deleting the box remains a normal user action.
- Suggested correction: preserve unresolved versions and disable destructive resolution for unsupported boxes unless the maintainer explicitly amends 0035.

### R-9 Failed page-move rollback can delete the last remaining copy
- Severity: P0
- Location: app/lib/src/notebook.dart:1473–1489, especially :1485–1488. Decisions 0049 and 0059.
- What happens: moving a page tree first verifies destination copies, then deletes sources. Suppose deleting source A succeeds and deleting source B fails because the source drive disappears. Restoring A also fails. The restoration exception is only logged; removeCopies still deletes every destination copy, including the only surviving A. The error then incorrectly says nothing was moved.
- Test coverage: no regression found for a partial source deletion followed by failed restoration. Existing binder/standalone move tests cover successful moves and earlier copy failures.
- Confidence: confirmed (static failure interleaving).
- Status: fixed (597bf62, b993f94, 9b1ebcf, d424230, be6ab4e)
- Suggested correction: track restoration success per page and never remove a verified destination unless an intact source is positively established; surface partial recovery explicitly.

### R-10 Recovery's two-file entry has no atomic generation boundary
- Severity: P2
- Location: app/lib/src/recovery_store.dart:91–117, :137–149. Decision 0070.
- What happens: each file is independently replaced, canvas first and metadata second. A crash after the first rename leaves either an orphan canvas on first write, or a new canvas paired with old metadata/base on replacement. There is no generation id or content digest to detect the latter. This is weaker than an atomic recovery entry and can leave valid-looking mismatched generations. An orphan is preserved, which limits loss, but automatic replay is not guaranteed.
- Test coverage: none for interruption between the two renames or mixed generations; ordinary write/replace/relaunch tests exist in app/test/recovery_test.dart.
- Confidence: confirmed (write ordering); the exact incorrect-merge consequence of a mixed base is not runtime reproduced.
- Status: fixed (84c9e4b, 64a8d20)
- Suggested correction: publish a manifest pointing at a complete immutable generation, or use a single transactional envelope, with startup handling for incomplete generations.

## Data-path trace and existing safeguards

| Area | Implemented path and positive evidence | Remaining limitation |
|---|---|---|
| Loading/format | readPage checks the header and rejects newer formats; raw JSON spans preserve unknown values and unchanged nodes. PageStore.scan records unreadable/duplicate pages. | Open-page unreadability is not a save barrier (R-1). |
| Normal saving | Controller changes schedule a 500 ms save; _saving orders saves; the open page checks the disk before save; PageStore writes a flushed temporary file then renames. | Atomic replacement is not a transaction with a sync writer. The final read-to-rename window is not guarded. Fixed .tmp names also assume one writer. |
| Watching | Folders are watched with 300 ms debounce; own text is ignored; availability is periodically checked. | Watch delivery cannot protect a write that already overwrote another version. |
| Three-way per-box merge | Revision-based content choice, codec merge, raw conflicting nodes, delete/edit flags, fieldwise headers and geometry rules. Core page_merge_test covers these branches and unsupported pass-through. | Unsupported conflict resolution remains destructive (R-8). |
| OneDrive-style copies | Filename candidate plus matching page id; revision/baseRev rules; verification before deleting the copy; startup and watcher paths. | Source mutation is unchecked (R-2). 0053 still labels the provider filename convention unverified; fixture tests are not a live two-device OneDrive validation. |
| Recovery | Saves exact page serialization and a base; replay merges, reads back, verifies and retains failed entries. | Identity, generation, reporting, case folding and attachment completion issues (R-4–R-7, R-10). |
| Running-app AI writes | Authorization/approval handling, serialized AI requests, recheck immediately before mutation, writer-mode enforcement, conflict/read-only/type checks. Open-page changes use the controller and are undoable. | Closed-page writes use a direct load/commit/save path (R-3). |
| MCP boundary | Separate server; current 0114/0117 allow append-only access logging and narrowly opted-in closed-app AI writes. The source invariant test reflects these exceptions. | Do not apply superseded 0103's blanket no-write rule to the current server. This review does not certify every closed-app writer race. |

## Active storage/sync decisions missing implementation or tests

This lists specific unimplemented obligations or missing regression scenarios, not whole decisions falsely described as untested. Coverage was assessed from repository source; the Flutter suite did not run in this session.

| Active decision | Implementation/coverage gap | Evidence / disposition |
|---|---|---|
| 0035 | Supporting-device-only conflict resolution is not enforced. | R-8; 0119 acknowledges the unresolved maintainer choice. Existing unsupported merge tests do not enforce resolution restrictions. |
| 0049, 0059 | “On any failure, sources stay” is not achieved when rollback itself fails; no corresponding failure-injection test found. | R-9. |
| 0051 | Unreadable/newer open-page replacements are not protected from save; no test for that case. | R-1. Valid external-change merge tests exist. |
| 0053 | A copy's current generation is not checked before deletion; no changing-source/destination race test found. | R-2. OneDrive filename examples remain explicitly unverified, with no live provider validation established by this audit. |
| 0070 | No atomic pair/generation publication, no component-identity check, and no case-sensitive location test. | R-5, R-6, R-10. The recovery mechanism itself is implemented and tested on normal paths. |
| 0077 | Readable-but-unverifiable replay errors do not enter the sidebar error list; no assertion for that behavior. | R-7. Parse-damaged entries do appear. |
| 0098 | No durable retry marker for recovery assets after page-entry deletion; no interrupted/failed asset-landing test. | R-4. Happy-path attachment recovery exists. |
| 0106 | Closed-page AI writes do not merge intervening external changes through the normal pre-save path; no sync-race regression found. | R-3. Permission, queue, open/close races and save-failure tests exist. |

### Active but explicitly deferred: do not count as current-phase defects

- 0007's swappable storage drivers and direct WebDAV/cloud integrations are not implemented by the local PageStore. 0038 and the current phase defer that work; syncing an ordinary folder is implemented.
- 0009, 0010, 0019, 0029, and the encrypted portions of 0020/0035 describe encrypted editors, key wrapping, secure copy, encrypted snapshots and unlock-before-resolution. The current phase defers encryption. app/lib/main.dart:38–49 registers note/drawing/image/file/AI/example modules, with no encrypted module; toolbar_placeholders.dart:19 is a disabled encrypted-box command. There is no actual encryption/key lifecycle or encrypted-editor recovery test to certify.
- MCP placeholder coverage does exist: packages/noted_mcp/lib/src/tools.dart:261 recognizes encrypted records; packages/noted_mcp/test/tools_test.dart:151 verifies placeholder output; invariant_test.dart:53 scans for prohibited encryption/key libraries. These tests are not proof of encryption at rest or of safe unlocked-editor state.
- 0026/0029 binder passwords and passphrase-scope moves, other providers' conflict-copy naming, and mobile background sync remain outside the stated phase. They are not findings here.
- Drawing image-snapshot storage remains explicitly an Open item under 0035/0041; the report does not treat an unresolved format choice as an implemented promise.

## Validation and limits

- Read relevant Active decisions, Open items and Risks to test early. No source, test, configuration or decision-log changes were made.
- Inspected implementation plus existing core/canvas/app regression tests; the audit's scratch files were outside the repository.
- Executed an isolated Dart 3.13.7 probe against the actual core/recovery classes: case-distinct folder writes produced one recovery entry; a different page id in the recovery canvas was accepted with zero reported problems. An additional malformed-byte scan probe completed without throwing and was not reported as a defect.
- Attempted the existing core page_store_test, page_merge_test and conflict_copy_test through flutter_tools.snapshot with --no-pub. Flutter stopped before tests ran because the sandbox denied access to the SDK's bin/cache/lockfile. No passing test-suite claim is made.
- No live OneDrive account, second device, power-loss injection, actual encrypted editor, or full app UI session was exercised. Race findings are supported by explicit code interleavings and need deterministic failure-injection regressions.

Recommended order: prevent destructive overwrites and cleanup first (R-1–R-3, R-9); then make recovery identity and lifecycle durable (R-4–R-7, R-10); resolve the explicit unsupported-box policy contradiction (R-8).
