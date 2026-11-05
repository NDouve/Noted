# Box API changelog

The Box API (decision 0034) is versioned by `boxApiVersion` in
`lib/src/box_api/box_codec.dart`. While the major version is 0, a module must
target the host's exact version (`BoxApiVersion.canHost`); from 1.0, a module
runs on any host with the same major version and an equal or newer minor
version.

Versions are listed newest first.

Host-only (not the Box API), run 2026-11-01-02: `PageCanvas.disallowedTypes`, `ModuleRegistry.isSwitchable` and `moduleForFile(exclude:)`, `convertPageAttachments(skipTypes:)` and `showConflictDialog(disallowedTypes:)` let a page treat a box type as switched off (module availability per page). No module-facing member changed; no version bump.

Host-only (not the Box API), run 2026-11-01-04: `PageChange.landed(id, before)` restores only a box's landed marker on undo (used by the canvas when a landed box is placed). Modules can construct `PageChange`s, but none needs this one; the subclasses stay private, so nothing switches on them. The page-issue helpers (`pageIssues`, keep, place both, accept merged) and the conflict UI are host code. No version bump.

Host-only (not the Box API), run 2026-11-04-02, task 3: `AttachmentConversion.failed` (default `0`) counts boxes whose conversion threw and were left as they were; `convertPageAttachments` converts the other boxes. `publishAttachment` (app) is the attachment publisher with the no-hard-link fallback. A paste or drop whose file cannot be stored makes no box and shows a notice. No version bump.

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
