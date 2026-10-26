# BoxFrame

The frame every box type draws on the canvas: idle, selected, conflicted and read-only.

- Idle: `surface` fill, 1px `border-box`, `radius-lg`, padding `space-4` × 14px. No drop shadow.
- Selected: 1px `accent` border plus `shadow-selected`. Resize handles are `handle` (8px) squares, `surface` fill with a 1px `accent` border, on the left, right and bottom edges and the bottom corners (same handles for every box type, D-017).
- Drawing box: no fill and no frame while idle. When selected it shows a 1px dashed `accent` outline with the same handles.
- Conflict: 2px `conflict` border with a `Conflict` badge (`radius-full`, `conflict` fill, `on-conflict` text, `small` semibold) overlapping the top edge at the right. The device line underneath is `small` in `text-muted`.
- Read-only (folder missing, damaged binder): a `conflict-soft` banner across the top inside the frame, `small` text, saying why and that edits are paused.
- Box headings use `box-title`; body text uses `body`.
