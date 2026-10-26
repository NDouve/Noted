# Box API changelog

The Box API (decision 0034) is versioned by `boxApiVersion` in
`lib/src/box_api/box_codec.dart`. While the major version is 0, a module must
target the host's exact version (`BoxApiVersion.canHost`); from 1.0, a module
runs on any host with the same major version and an equal or newer minor
version.

Versions are listed newest first.

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
