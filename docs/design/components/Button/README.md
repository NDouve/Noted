# Button

Primary, secondary, ghost and destructive buttons for dialogs, the conflict view and covers.

- Height `control` (36px; `touch-target` on touch), `radius-md`, padding 0 14px, `body` semibold.
- Primary: `accent` fill, `on-accent` text. One per dialog, for the action that proceeds ("Use this version", "Create").
- Secondary: `surface` fill, 1px `border`, `text`.
- Ghost: no fill or border; `surface-hover` on hover. Toolbar text commands use this.
- Destructive: `error` text on a secondary button; confirm before acting.
- Focus: 2px `accent` outline, 2px offset. Disabled: `text-disabled`, no hover.
