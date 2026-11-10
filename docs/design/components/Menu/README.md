# Menu

Context menus, the / menu, the table row/column handle menu and toolbar dropdowns.

- Container: `surface`, 1px `border`, `radius-lg`, `shadow-popover`, padding `space-1`, min width 220px.
- Item: height `row` (40px on touch), `radius-md`, padding `space-2` × 10px, `body` in `text`; hover or keyboard focus fills `surface-hover`. A shortcut sits right-aligned in `small` `text-muted`.
- Separator: 1px `border` with `space-1` margins.
- Disabled: `text-disabled`, no hover.
- Destructive (Delete page, Delete row): label in `error`, still confirmed before acting.
- Pick list (boxes under a point): the same container, anchored at the press and kept inside the canvas. A row is `<Type> · <first words>` in `body` (up to 60 characters of the snapshot text; an encrypted box shows its type only), with two icon buttons at the right, Bring to front and Send to back, in `text-muted` and `text` when enabled. The row under the pointer or keyboard highlight fills `surface-hover` and the canvas outlines its box (BoxFrame).
