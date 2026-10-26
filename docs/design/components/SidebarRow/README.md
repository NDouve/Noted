# SidebarRow

One row of the page tree, plus the group header above a binder or the loose pages.

- Group header: `label` style in `text-muted`, uppercase, with an 8px `radius-sm` chip in the binder's colour (`binder-*`; loose pages use `text-muted`).
- Row: height `row` (32px; 40px on touch), `radius-md`, padding `space-2`, indent 20px per level, `body` in `text`. Hover fills `surface-hover`.
- Divider (a page with subpages): a chevron (▾ or ▸) in `text-muted` before the title. It's still a page; only the chevron differs.
- Active page: `accent-soft` fill, `body-strong` in `accent`.
- Conflict: an 8px `conflict` dot at the right edge, labelled "Has a conflict" for screen readers.
- Unavailable ("On another device", damaged binder file): title in `text-disabled`, with a `small` status line, and opens read-only.
