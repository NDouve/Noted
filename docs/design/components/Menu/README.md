# Menu

Context menus, the / menu, the table row/column handle menu and toolbar dropdowns.

- Container: `surface`, 1px `border`, `radius-lg`, `shadow-popover`, padding `space-1`, min width 220px.
- Item: height `row` (40px on touch), `radius-md`, padding `space-2` × 10px, `body` in `text`; hover or keyboard focus fills `surface-hover`. A shortcut sits right-aligned in `small` `text-muted`.
- Separator: 1px `border` with `space-1` margins.
- Disabled: `text-disabled`, no hover.
- Destructive (Delete page, Delete row): label in `error`, still confirmed before acting.
