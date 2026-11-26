# Box API changelog

The Box API (decision 0034) is versioned by `boxApiVersion` in
`lib/src/box_api/box_codec.dart`. While the major version is 0, a module must
target the host's exact version (`BoxApiVersion.canHost`); from 1.0, a module
runs on any host with the same major version and an equal or newer minor
version.

Versions are listed newest first.

Host-only (not the Box API), run 2026-11-25-01, task 1 (Android publishes without hard links): `useRenamePublishOnAndroid()` is exported by `noted_core.dart`; the host calls it once at start. On Android it registers `publishByRename`, which `publishExclusive` then uses (`link` first; if SELinux refuses it, `renameat2(RENAME_NOREPLACE)`, else an lstat and `rename(2)` in one synchronous call). `publishByRename`, `nonLinkPublisher` and the test seams (`debugLinkErrno`, `debugLinkCalls`, `debugNoReplaceErrno`, `debugPublishAsAndroid`) are hidden. No module-facing change, no version bump.

Host-only (not the Box API), run 2026-11-23-01, document import stage A: `PageCanvasState.captureImportTarget`, the public opaque `ImportTarget` (and `ImportInsert`, `importStoppedNotice`) in `import_target.dart`, and `PageCanvasState.insertImportInto` (not on `CommandHost`; `insertFiles` is unchanged). The note module implements the existing `createFromFile` for `<stem>.noted-blocks.json` and `.md`, with `fileAffinity` still 0. No module-facing member changed; no version bump.

Host-only (not the Box API), run 2026-11-22-01, task 3 step 2 (iCloud N4 sites, cloud-parity R5.4): `PageStore.save` is removed (no production caller; the app publishes with `saveNew` and replaces with `saveIfUnchanged`), and `TemplateStore.save` now publishes a unique temporary file with `publishExclusive` (a taken name is the same `FileSystemException`). `PageStore.scan` and `TemplateStore.save` make a missing folder through one coordinated write, and `BinderStore.create` rethrows a `StorageBusy` instead of reporting a drive that can't publish. No module-facing change, no version bump.

Host-only (not the Box API), run 2026-11-22-01, task 3 step 1 (iCloud coordination hook, cloud-parity R5.4): new `coordination.dart` (`StorageCoordinator`, `CoordinatedWrite`, `CoordinationIntent`, `CoordinationKind`, `StorageBusy`, `StorageBusyReason`, `registerCoordinator`, `unregisterCoordinator`, `coordinated`, `coordinationStartTimeout`), exported by `noted_core.dart` and reached by the MCP server only through `exclusive_publish.dart` (nothing registered there). `moveExclusive` and `PageStore.moveTo` now return a `Future` (a `StorageBusy` is `MoveOutcome.busy`) and `moveExclusive` takes `alsoMoved`; `publishExclusiveSync` is private. No module-facing change, no version bump.

Host-only (not the Box API), run 2026-11-22-01, task 2 stage A (rename-based move, noted_core primitives): new `exclusive_move.dart` (`moveExclusive`, `MoveOutcome`, `placeholderState`, `syncRootOf`) and `file_stamp.dart` (`FileStamp`, `fileStamp`), both exported by `noted_core.dart` and in no import graph of `noted_core_read` or the MCP server; `PageStore.moveTo`, `PageStore.scan(stamps:)` with `ReadablePage.stamp`, `onPublishStamp` on `PageStore.saveIfUnchanged` / `saveNew` / `saveNewText`, and `ContentIdentity.ofFileSync`. No module-facing change, no version bump.

Host-only (not the Box API), run 2026-11-16-01, task 1 (copy retire, codex area-data-integrity 2026-11-16 R-1; the same-id AI access rule): `mergeConflictCopy` and `verifyConflictCopyMerge` take `required bool topOfChain` (the page is in no binder and has no parent); the merged header keeps the original's fields except `ai`, the stricter of the two, and the check fails when the disk's `ai` is looser than either side's. New `stricterAiAccess`, `aiAccessRank` and `consumedCopyHeld` (whether a page file read later still holds a merged copy). No module-facing member changed; no version bump.

Run 2026-11-15-02, task 1 step 8 (multi-select). Additive member visible to modules (no version bump; decided by the PM under delegated authority): `CanvasController.multiSelection`, an unmodifiable `List<String>` of the boxes selected together, in the order added; default empty, never one (one box is `selectedId`). While it has two or more, `selectedId` is null. It is transient (not saved, not in Undo) and read-only for modules; no module is required to read it. Host-only (not the Box API): `toggleMulti`, `clearMulti` and `canToggleMulti`; the Ctrl+Shift+click (Cmd+Shift on macOS) and Ctrl+Shift+Space gestures; `restoreMulti` (puts the set back after a refused menu choice); `canvas.delete` and the layering commands are off with two or more selected (paste, insert, drop, Undo, Redo and Page background stay on); `select`, `beginGesture`, `setEditing(focused)`, the autofocus inserts, a picked tool and `beginToolSession` end a multi-selection.

Host-only (not the Box API), run 2026-11-15-02, task 1 step 6 (the 900 px layout): `NotedMetrics.narrowLayoutBelow` (default 1000, the new `defaultNarrowLayoutWidth`; `narrowLayoutWidth` stays as a deprecated alias) is the width under which `isNarrowLayout` is true; `notedThemeData` and `NotedMetrics.forBrightness` take it as `narrowLayoutBelow`. The app passes 720 on desktop and 1000 on a phone or tablet. The `PageCanvas` overlay panel now covers the header and the viewport but not the footer. No module-facing member changed; no version bump.

Host-only (not the Box API), run 2026-11-15-02, task 1 step 5 (toolbar, title and status strip): `PageCanvas.header` (a band between the toolbar and the viewport, left of the side panel) and `PageCanvas.footer` (a strip under the canvas, left of the side panel). No module-facing change, no version bump.

Host-only (not the Box API), run 2026-11-15-02, task 6 (checked deletes, codex area-invariants): `PageStore.delete` is removed (no production caller; the app deletes through `deleteIfUnchanged`). `TemplateStore.delete(path, ContentIdentity)` now returns a `DeleteResult` and deletes through `deleteFileIfMatches` (a changed file is kept). `ReadableTemplate` gains the `identity` (the `ContentIdentity` of the bytes the scan read) as a third constructor argument. `TemplateStore.scan({sweep})` (default false) puts back a crashed delete's `.cas-old` and `.cas-verified` leftovers first; without it they are listed as `UnreadableTemplate`. No module-facing member changed; no version bump.

Host-only (not the Box API), run 2026-11-15-01, task 7 (canvas context menus): `ContextMenuStyle` and `PageCanvas.contextMenuStyle`; `PageCanvasState.contextMenuOpen` (a `ValueListenable<bool>`, true while a context menu is open); `CanvasController.canDelete` (the guard of `delete`, now also the `canvas.delete` predicate); `CanvasTargetGuard` (the canvas half of the command-target guard, shared with the menu bar); `PageCanvasState.pasteFilesAt` and the paste target (`insertFiles`, `pasteFiles` and drops take their controller, page, store and point at their start and check them again before each box, so a page opened meanwhile gets nothing); the pick list's `PickChoice` result with its `more` flag (a row's More button). `canvas.delete` is now enabled only for a selection `delete` would remove. No module-facing member changed; no version bump.

Run 2026-11-15-01, task 6 (UI shell). Additive member visible to modules (no version bump; decided by the PM under delegated authority): `CanvasController.editorFocusHeld`, a `ValueListenable<bool>`, default false. While true, the host has moved focus away from a box's editor for a moment (an app menu) and will give it back: keep the editor mounted and its selection, save the selection when it becomes true and restore it when the editor regains focus while it is still true. The note module reads it; no module is required to. Host-only (not the Box API): `EditorFocusHold` (`hold`, `release`; the controller's `editorFocusHold` and `isDisposed`, used by the app), `PageCanvas.onCommandsChanged`, `PageCanvas.sidePanel`, `PageCanvas.overlayPanel`, `menuShortcutLabel`, the `meta` alternates of Undo and Redo, `NotedColors.boxFrame`, and the refresh of the commands when `PageCanvas.readOnly` changes. `canvas.paste` is labelled "Paste image or file".

Host-only (not the Box API), run 2026-11-15-01, task 1 (aside re-check, codex area-data-integrity-3 R-1): the additive named parameters `beforeAsideDelete`, `beforeFinalCheck` and `afterFinalRead` (`Future<void> Function(String path)?`, test seams) on `replaceIfUnchanged`, `deleteFileIfMatches`, `deleteFileIfUnchanged`, `PageStore.saveIfUnchanged` and `PageStore.deleteIfUnchanged`; the `beforeFinalCheck` and `afterFinalRead` fields of `BinderStore` (the same seams for its deletes and replaces); `ReplaceResult.alsoKept` and `DeleteResult.alsoKept` (default empty: further kept files when more than one was); `BinderStore.removeTemps(kept:)` (an optional out-list of the paths a delete kept a copy under); `KeptFileSystemException` (a `FileSystemException` with `keptPaths`, thrown by a delete that could not put a file back and kept it, or a late file, elsewhere). `ReplaceOutcome.replaced` may now carry a `-recovered-` `keptPath` (the field already allowed one). No module-facing member changed; no version bump.

Run 2026-11-14-02, task 3 (disallowed merge, codex area-invariants R-2). Additive member visible to modules (no version bump; the PM may decide it under delegated authority): `CanvasController.disallowedTypes` getter, the box types the open page disallows, default empty; the drawing tools read it and no module is required to. Host-only (not the Box API): the `disallowedTypes` setter, which the notebook, the owner of the open page's controller, is the one to call (`PageCanvas` asserts it equals its own filtered set). A box whose type is in the set is refused by `commit`, `editBox`, `replaceBoxData`, `resolveWithData` and `insertBox`, and kept by focus-loss cleanup. `PageHistory.undo` and `redo` take `blockedTypes` (default none) and `canUndoOn` and `canRedoOn` are new: a step that would revert a box's content through a disallowed type's codec stays on its stack and nothing is undone until the type is allowed again; add, remove, replace, bounds, order and landed steps are never blocked. `BoxHost` shows a disallowed box from its snapshot without decoding it.

Host-only (not the Box API), run 2026-11-14-02, task 2 (binder writes, codex area-data-integrity R-2): `BinderStore.update(BinderDelta)` replaces `BinderStore.save` (removed; no module calls it), with `BinderDelta`, `BinderDeltaKind`, `BinderField` (`BinderAiField`, `BinderBoxTypeField`), `BinderTemp`, `BinderUpdate` (`BinderUpdated`, `BinderRefused`), `BinderRefusal`, `BinderStore.removeTemps`, `fileHoldsBinderSync`, `hasBinderAsideSync`, `BinderStore.sweepLeftovers` (with `BinderSweep` and `BinderCopy`), `isBinderTempName` and `isBinderFileAsideName`. `BinderStore.create` now returns `BinderCreated` (`created` or `exists`) instead of the binder and no longer throws for an existing file. `deleteFileIfMatches(stillRedundant:)` and `sweepAsideFiles(only:)` are additive named parameters. `BinderStore` is no longer `final`, and gains the overridable `newTempFile` and `writeTemp` and the `retryDelay` and `tries` constructor parameters (test seams). No module-facing member changed; no version bump.

Host-only (not the Box API), run 2026-11-01-02: `PageCanvas.disallowedTypes`, `ModuleRegistry.isSwitchable` and `moduleForFile(exclude:)`, `convertPageAttachments(skipTypes:)` and `showConflictDialog(disallowedTypes:)` let a page treat a box type as switched off (module availability per page). No module-facing member changed; no version bump.

Host-only (not the Box API), run 2026-11-01-04: `PageChange.landed(id, before)` restores only a box's landed marker on undo (used by the canvas when a landed box is placed). Modules can construct `PageChange`s, but none needs this one; the subclasses stay private, so nothing switches on them. The page-issue helpers (`pageIssues`, keep, place both, accept merged) and the conflict UI are host code. No version bump.

Host-only (not the Box API), run 2026-11-04-02, task 3: `AttachmentConversion.failed` (default `0`) counts boxes whose conversion threw and were left as they were; `convertPageAttachments` converts the other boxes. `publishAttachment` (app) is the attachment publisher with the no-hard-link fallback. A paste or drop whose file cannot be stored makes no box and shows a notice. No version bump.

## 0.16 — 2026-11-15
- `CommandHost.invocation` (`CommandInvocation?`) and `CommandInvocation` (`anchor`, `isCurrent`) in noted_canvas: when the running command was chosen from a context menu at a page point, that point and a validity check, during the synchronous start of `invoke` only (null after the first `await`, on a toolbar, keyboard or menu-bar run, and after a throw). Read it before the first `await`; after an `await` insert nothing unless `isCurrent` (the canvas is still open on the same page, controller and commands, and the page is writable). The image and file modules insert at the anchor through `insertFiles(at:)`.
- Additive for modules, which only consume `CommandHost`; the implementers are host-side (`PageCanvasState` through `CanvasCommandTarget`, and a test fake). An outside fake that implements `CommandHost` must add the getter. Under 0.x `canHost` matches the exact version, so every 0.15 module must be rebuilt for 0.16; a module that reads `invocation` needs a host of 0.16 or later. Decided by the PM under delegated authority; run 2026-11-15-02, task 1 step 7.

## 0.15 — 2026-11-09
- `BoxModule.linkAt(String boxId, Offset global)` (default `false`; noted_canvas): whether the live box has a link at that screen point. The canvas asks only the topmost live box under an Alt/Option click, and opens the pick list (the boxes under the point) only when it answers false, so a link keeps the plain click it has today (decision 0099). The note module answers from its light view (`lightHitTest`) or its editor (the `href` at the position). Additive: a module that does not override it is unaffected. Decided by the PM under delegated authority; run 2026-11-09-02, task 4.

Host-only (not the Box API), run 2026-11-09-02, task 4: `StackMove`, `stackTarget` and `hasOwnId` (noted_core), `NotedPage.moveNode`, `PageChange.order`, `isEncryptedBox` (noted_core), `CanvasController.restack` and `canRestack` (modules hold the controller), `PageCanvas.boxTypeName`, `PageCanvasState.pickHighlightId`, `PageCanvas.pickOverlayKey`, `pickModifierHeld`, `boxHitRect`, `nodesAtPoint` and `pickRowLabel` (noted_canvas, exported for the app and tests; no module needs them), and the `CanvasCommands` ids `canvas.bringToFront`, `canvas.bringForward`, `canvas.sendBackward` and `canvas.sendToBack`.

## 0.14 — 2026-11-05
- `BoxCodec.folderFiles(data)` (default `const []`): the file names, relative to the page's assets folder, that a box keeps in that folder; an embedded ref gives none. The image and file codecs return their folder ref. The host asks only for boxes the registry resolved (module on, known data version, readable) and allowed on the page, and uses the answer to name the attachment files a Save a copy could not bring along (so the notebook no longer decodes image or file data itself). Additive: a codec that does not override it is unaffected. Decided by the PM under delegated authority; run 2026-11-05-03, task 1 (codex area-data-integrity-2 R-1).

## 0.13 — 2026-11-04
- `PageFolderAttachmentStore` (noted_canvas), an optional interface that extends `VerifyingAttachmentStore`: `putInPageFolder(bytes, {extension, storage})` is `put` without any recovery fallback (it stores in the page's own assets folder or throws a `FileSystemException`), and `verifyInPageFolder(fileName, {size})` is `verify` on the page's own assets folder only. Moving a box's attachment to the folder drops its embedded copy only after `putInPageFolder` and `verifyInPageFolder` both succeed, so a copy that exists only in a recovery folder never counts; a store that does not implement the interface cannot convert to the folder (the box keeps its embedded data).
- `AttachmentStore.put` is unchanged in signature; its documentation now says it throws a `FileSystemException` when no copy could be stored (it could already throw). `VerifyingAttachmentStore` is unchanged.
- Additive: a store or module that does not use the interface is unaffected. Decided by the PM under delegated authority; run 2026-11-04-02, task 3 (codex area-data-integrity-2 R-1).
- `isRunnableFileName`, `needsOpenConfirmation`, `lastExtension`, `pathExtExtensions`, `cleanNameForDisplay`, `RunnablePlatform` and `confirmOpenRunnable(context, name)` in noted_canvas: whether the system would run a file of that name (Windows with PATHEXT, macOS, Linux, Android) and the "Open this file?" question (Cancel is the default). A module that opens a file or link in another program should ask this first; the file box and note links do. Additive (no member a module implements changed); released with 0.13. Decided by the PM under delegated authority; run 2026-11-04-02, task 4.
- `linkSchemeNeedsConfirmation(scheme)` and `confirmOpenLinkScheme(context, scheme)` in noted_canvas: every link scheme but `http`, `https` and `mailto` (so `noted:` too, until the app handles it) asks "Open this link?" (the scheme on its own line, Cancel the default) before the link is handed to another program; note links ask through them. Additive. Asking for other schemes is the maintainer's decision; asking for `noted:` is the PM's, pending the maintainer's confirmation. Run 2026-11-04-03, task 6.

## 0.12 — 2026-11-03
- `VerifyingAttachmentStore` (noted_canvas), an optional interface that extends `AttachmentStore`: `readVerified(fileName, {size})` returns a `VerifiedAttachment` (`AttachmentState` `ok`, `syncing` or `damaged`, and the bytes when `ok`); `verify(fileName, {size})` returns the same without the bytes. A `damaged` result carries `keptAs` (the name the damaged copy was kept under) or, if it could not be set aside, `leftAt` (where it is), so the module can tell the user by the box's own name; the store does not notify for a check. The store checks a folder file against the hash in its name, treats a file shorter than the box's recorded size or still changing as `syncing`, and for a `damaged` file keeps it aside as `<name>.damaged-<12 hex of its actual hash>` (never over anything). `AttachmentState` and `VerifiedAttachment` (`state`, `bytes`, `keptAs`, `leftAt`) are the new types it uses. A missing file is first looked for among its kept copies (`<name>.damaged-…`, `<name>.kept-…`) and put back if one now holds the right hash.
- `AttachmentRef` (the image and file boxes' package, noted_box_attachments): new `damagedData` (the base64 of embedded data that did not match its hash, kept and written back unchanged by `toJson`) and `isDamaged`; new `readAttachment`, `verifyAttachment` and `loadDisplayCopyChecked` helpers. The page format is unchanged: a page with such data is saved byte for byte as it was read.
- Additive: `AttachmentStore` itself is unchanged, a store that does not implement the new interface still works (modules check the bytes against the hash in the box themselves, and cannot move a file aside). Decided by the PM under delegated authority; run 2026-11-03-01, task D4.
- `isAttachmentFileName(String)` in noted_core: whether a box's `file` value is `<64 lowercase hex>` or `<64 lowercase hex>.<1-10 lowercase letters or digits>`, the only form a module may join onto the assets folder; any other value is a missing file (not read, opened, verified or embedded). `attachmentNameInvalid(ref)` in noted_box_attachments tells a module that its ref names such a file, so it can say "file not found". Additive; no version bump (no member a module implements changed). Approved by the PM under delegated authority; run 2026-11-04-01, task 4.

## 0.11 — 2026-11-03
- `StylusRole` (`none`, `pen`, `eraser`) and `CanvasTool.stylusRole` (default `StylusRole.none`) in noted_canvas. While Select and type is picked, the canvas sends a stylus to the enabled tool with role `pen` and the eraser end of a stylus to the one with role `eraser`; the box layer takes no click from those pointers (0033). A picked tool is kept, except that the eraser end erases while the pen is picked. The drawing module's pen and eraser set the roles; a tool that does not override `stylusRole` is unaffected.
- Additive. Decided by the PM under delegated authority; decision 0033, run 2026-11-02-04.
- `contentHashOfStream(Stream<List<int>>)` in noted_core: the same SHA-256 as `contentHash`, over a stream of chunks, so a module can hash an attachment file without reading it whole. Additive. Streamed hashing for attachment moves (codex area-data-integrity-2 R-2), run 2026-11-02-04.

## 0.10 — 2026-11-01
- `AiWriteMode.replaceAiText`: replace only the box's AI-written blocks (those whose AI mark still matches their text) and keep every user-written block in place. Every run of consecutive AI-written blocks is removed and the new blocks go where the first run was, or at the end if there was none.
- `applyAiWrite(boxJson, AiWrite)` in noted_core: the AI box's write on its stored JSON (append, replace, replaceAiText), shared by the AI codec and the MCP server's closed-app write. `AiWrite` and `AiWriteMode` now live in `ai/ai_box.dart` (still exported from `noted_core.dart` and `box_codec.dart`).
- Not part of the API: `markdownToNoteBlocks` moved from the note package into noted_core (pure Dart on `package:markdown`, same output), and the code store, link protocol and page-file splice grew (`AiCode.approved`, Writer permission, closed-app writes, `write_box` modes `append|replace_ai|replace`, `not_permitted`).
- Additive: a codec that doesn't switch exhaustively over `AiWriteMode` is unaffected. Approved by the maintainer; run 2026-11-01-03.

## 0.9 — 2026-10-31
- `AiWriteMode` (`replace`, `append`) and `AiWrite` (`connectionId`, `content` as markdown, `mode`) in noted_core.
- `BoxCodec.aiOwner(data)` (default null): the id of the AI connection that owns the box, never a token or secret.
- `BoxCodec.aiWrite(data, write)` (default null): the box's data after an AI's write, or null if the type takes no AI writes. The host checks ownership and the page's AI setting before calling it.
- `CommandHost.viewCentre` (noted_canvas): the middle of the visible view in page coordinates, or null where there is no view. `CanvasController.insertBox` takes an optional `autofocus` to select the new box and focus its editor.
- Additive: a module that overrides none of these is unaffected. Decided by the PM under delegated authority; the AI box, run 2026-11-01-01, decision 0107.

## 0.8 — 2026-10-31
- `BoxModule.aspectRatioExtraHeight` (default 0): a fixed height below the part that keeps `aspectRatio`, such as the image box's alt-text strip. While resizing, the canvas keeps `height - extra = width / aspectRatio`.
- Not part of the API but visible to modules: a click on a box's content that doesn't move the focus into it (an image, a file, a drawing) now selects the box, as a click on its grip does, so Delete and Backspace remove it.
- Additive. Approved by the maintainer; decision 0102.

## 0.7 — 2026-10-31
- `AttachmentStore` (noted_canvas): the open page's images and files. `put` stores bytes embedded or in the page's assets folder (`<page id>.assets/<content hash>.<ext>`) as the page's "Store images and files" setting says, with files over `embedLimitBytes` (5 MB) always in the folder; `read`, `exists`, `changes` (files arriving from sync), `cacheDirectory` (never synced), `notify`, `open` (default app) and `pick` (file dialog).
- `BoxContext.attachments` and `CommandHost.attachments`: the store, or null.
- `IncomingFile` and file handling on `BoxModule`: `fileAffinity` (which module takes a pasted, dropped or picked file), `createFromFile` (data and size of the new box), `convertAttachments` (embed or move to folder), `aspectRatio` (kept while resizing unless Shift is held).
- `CommandHost.insertFiles` and `BoxContext.insertFilesBeside`: create boxes for files at a point or beside a box.
- `FileClipboard.read`: files (an image) on the system clipboard, set by the app.
- The core reads none of it: box data stays the module's, and the core only moves, copies and removes the assets folder with its page.
- noted_core: `AttachmentStorage`, the page header and binder setting (`"attachments"`), `effectiveAttachmentStorage`, `contentHash`, `attachmentFileName`, `assetsFolderName`, `embedLimitBytes`.
- Additive: a module that overrides none of these is unaffected. Decision 0098.

## 0.6 — 2026-10-26
- `BoxFind` (noted_core): the state of Find on page for a module: the `SearchQuery`, the box that holds the current match and which of its matches is current.
- `BoxContext.find` (noted_canvas): a `ValueListenable<BoxFind?>`; null while the find bar is closed. A module may use it to mark matches inside its own content, matching against its own text snapshot with `SearchQuery.rangesIn` / `termRangesIn`. The core never reports positions inside a box's data and never reads it.
- Search itself (the in-memory index, whole-word AND matching, the "Search all pages" panel) reads only `BoxRecord.snapshotText`; it needs no module hook.
- Additive: a module that ignores `find` is unaffected (the canvas still frames the matching boxes). Decision 0085.

## 0.5 — 2026-10-26
- `BoxModule.frameStyle`: how the canvas frames the module's boxes.
  - `BoxFrameStyle.framed` (the default): a surface fill and a hairline frame while idle, and an accent border when selected.
  - `BoxFrameStyle.framelessUntilSelected`: no fill and no frame until the box is selected, then a dashed accent outline. The drawing module uses it.
- `Command.menu`: the ids of the commands a command offers as a toolbar dropdown.
- `Command.readout`: the toolbar shows the command's text as an outlined numeric readout, as it does for the zoom level.
- All additive. Decisions 0074 and 0079.

## 0.4 — 2026-10-26
- Commands: `BoxModule.commands(CommandHost host)` returns the `Command`s a
  module adds (id, label, icon, optional shortcut, enabled and checked state,
  invoke). The canvas registers them, with its own, in a `CommandRegistry`;
  keyboard shortcuts and the default toolbar are built only from that
  registry.
- `CommandHost` gives a module the open page's `CanvasController` and the
  shared `CanvasToolSelection`.
- Each `CanvasTool` is also exposed by the canvas as a command with the tool's
  id, label, icon and shortcut, checked while the tool is active.
- `CanvasTool.buildOptions` is no longer shown by the default toolbar; a
  tool's options are commands (for example pen colors and widths).
- Additive: a module that doesn't override `commands` is unaffected.
  Decision 0067.

## 0.3 — 2026-10-26
- `ToolContext.brightness`: the theme's brightness, so a tool session's live
  feedback (for example the stroke being drawn) can match the theme.
- `ToolContext.colors`: the theme's `NotedColors` (app-specific color roles
  such as default ink and the conflict colors).
- Both are additive and implemented by the canvas. Decisions 0058 and 0062.

## 0.2 — 2026-10-25
- Canvas tools: `BoxModule.tools`, `CanvasTool`, `ToolSession`, `ToolPointer`,
  `ToolContext` (controller, scale, repaintOverlay) and `CanvasToolSelection`.
- `BoxEdit`: a module's own diff of a box's content, replayed by page undo
  through the box's codec (`PageChange.content`).
- `CanvasController.delete(undoTo:)`: undo restores the given record.
- Decision 0040.

## 0.1 — 2026-10-24
- First version: `BoxCodec` (type id, data version, sizing, create, decode,
  encode, text snapshot, isEmpty, AI exposure, merge, permissions),
  `CodecRegistry`, and on the Flutter side `BoxModule` (buildEditor,
  buildView, buildSettings, image snapshot hook) with `BoxContext`.
- Decision 0034.
