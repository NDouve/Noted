# Noted

Noted's look is **quiet chrome, content first**. The canvas belongs to the user's notes, ink and tables; everything around it (sidebar, toolbar, menus, box frames) stays neutral and recedes. This is direction A, "Quiet Utility", picked from the visual directions canvas.

## Principles

1. **Neutral first, one accent.** The chrome is greys. `accent` is the only brand hue, and it means one thing: *this is selected or active* (the active tool, the active page, a selected box, a focus ring, a link).
2. **Colour only for meaning.** `conflict` (amber) is only ever a sync conflict. `error` (red) is only ever an error. Binder colours identify binders. Ink colours are the user's. Nothing is coloured for decoration.
3. **Borders, not shadows.** Boxes sit on the canvas with a hairline (`border-box`) and `radius-lg`. Selection adds an `accent` border plus `shadow-selected`. The only drop shadow is `shadow-popover`, for things that float (menus, dialogs, tooltips).
4. **Both themes are first-class.** Every token has a light and a dark value, and every pairing in this book passes WCAG AA in both. Default ink (`ink-default`) flips with the theme; picked ink colours (`ink-*`) never do. Binder colours keep their stored value and show a lifted shade in dark.
5. **Dense but touchable.** Desktop controls are `control` (36px); on touch devices every control grows to `touch-target` (44px) and rows to 40px.

## Colour roles

| Role | Token | Use |
|---|---|---|
| Chrome | `bg-app`, `bg-sidebar` | Window behind sidebar and toolbar |
| Canvas | `bg-canvas` | The page; page backgrounds draw on it |
| Surfaces | `surface`, `surface-hover` | Boxes, toolbar, menus, dialogs; hover fills |
| Lines | `border`, `border-box` | Hairlines; idle box frames |
| Text | `text`, `text-muted`, `text-disabled` | Primary, secondary, inactive only |
| Selection | `accent`, `accent-soft`, `on-accent` | Active/selected states, focus, links |
| Conflict | `conflict`, `conflict-soft`, `on-conflict` | Sync conflicts, read-only and recovery banners |
| Error | `error` | Formula errors, failed saves, destructive actions |
| Ink | `ink-default`, `ink-blue`, `ink-orange`, `ink-green`, `ink-purple` | Pen swatches |
| Binders | `binder-green`, `binder-orange`, `binder-blue`, `binder-purple`, `binder-teal` | Binder chip and stripe |
| Paper | `paper-line`, `paper-dot`, `paper-margin` | Page backgrounds (decoration, below text contrast on purpose) |

Do: put `accent` text on `accent-soft` for the active row. Don't: use `accent` for headings or decoration, or `conflict` for warnings that aren't conflicts.

## Typography

One family, **Inter**, falling back to Segoe UI and the system sans. Equations render in KaTeX's own fonts (`math`). Use the styles, not ad-hoc sizes: `page-title` 26/32 bold, `box-title` 16/22 semibold, `body` 14/22, `body-strong`, `small` 12/16, `label` 12/16 semibold uppercase for sidebar group headers, `numeric` 13/18 with tabular figures for table cells and the zoom readout.

Licence note for the build: Inter is under the SIL Open Font License 1.1, which isn't on the project's dependency licence list (MIT, BSD, Apache-2.0, MPL-2.0). Bundling it needs the maintainer's sign-off; until then the fallback stack (Segoe UI on Windows) applies.

## Spacing, radius, size

A 4px base: `space-1` 4, `space-2` 8, `space-3` 12, `space-4` 16, `space-6` 24, `space-8` 32. Radii: `radius-sm` 4 (cells, chips), `radius-md` 6 (buttons, rows, menu items), `radius-lg` 8 (boxes, menus, dialogs), `radius-full` (badges, swatches). Sizes: `toolbar-height` 52, `control` 36, `touch-target` 44, `row` 32, `icon` 18, `handle` 8, `sidebar-width` 264, `paper-pitch` 20.

## Iconography

Line icons, 2px stroke, rounded caps and joins, drawn at `icon` (18px) inside a `control` (36px) button, coloured `text` (or `accent` when active). Use Material Symbols Rounded (outlined, weight 400): it ships under Apache-2.0, which fits the licence rule. Every icon-only button has a tooltip showing its label and shortcut, for example "Pen (P)".

## Page backgrounds

Each page can draw one background on `bg-canvas`, chosen per page and saved in page and binder templates: **Plain** (default), **Dots** (`paper-dot`), **Graph** (square grid in `paper-line`), and **Ruled** (horizontal `paper-line` rules with a `paper-margin` rule). The pitch is `paper-pitch` (20px) at 100% zoom and scales with zoom. Backgrounds are decoration: they never reach snapshots, exports for AI, or the text snapshot.

## Mapping to Flutter

Build one `ThemeData` per theme from these tokens. `ColorScheme`: `primary` = `accent`, `onPrimary` = `on-accent`, `primaryContainer` = `accent-soft`, `onPrimaryContainer` = `accent`, `surface` = `surface`, `onSurface` = `text`, `onSurfaceVariant` = `text-muted`, `outline` = `border`, `outlineVariant` = `border-box`, `error` = `error`, `surfaceContainerLowest` = `bg-canvas`, `surfaceContainerLow` = `bg-app`. Put the tokens with no Material slot (`conflict*`, `ink-*`, `binder-*`, `paper-*`, `text-disabled`) in a `ThemeExtension` called `NotedColors`. Spacing, radius and size tokens go in a `NotedMetrics` extension. Widgets read tokens only, never hex values.

## Components

Toolbar, SidebarRow, BoxFrame, Menu, Button and PageBackground: each has guidelines and a live preview in this system. The toolbar is built from registry commands, so its contents grow as commands are added; the styling here covers any command.
