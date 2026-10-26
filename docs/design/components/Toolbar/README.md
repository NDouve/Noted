# Toolbar

The fixed bar across the top of the canvas, built only from registry commands.

- Height `toolbar-height` (52px), background `surface`, bottom hairline `border`, side padding `space-4`, gap `space-1`.
- Command buttons are `control` (36px) squares, `radius-md`, icon `icon` (18px) in `text`. Hover fills `surface-hover`. Active or checked (the current tool) fills `accent-soft` with the icon in `accent`, and sets `aria-pressed`.
- Groups (tools · ink · history · insert · view) are separated by a 1px × 24px `border` rule with `space-2` either side. View controls (Fit all, zoom) sit at the far right.
- Ink swatches are 28px discs, `radius-full`. The selected one has a 2px `accent` ring. While the Pen isn't active they show at 45% opacity and aren't clickable (per the current build).
- Text commands (Table, Equation, Fit all) are ghost buttons with a `body` label. Disabled commands use `text-disabled`.
- The zoom readout is an outlined `numeric` button that resets to 100%.
- Every button has a tooltip: label plus shortcut ("Pen (P)"). On touch devices buttons grow to `touch-target` and the bar wraps.
