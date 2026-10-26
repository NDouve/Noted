# PageBackground

The pattern a page draws on `bg-canvas`: Plain, Dots, Graph or Ruled, chosen per page and kept in templates.

- Plain: `bg-canvas` only (the default).
- Dots: 1.5px dots in `paper-dot` at `paper-pitch`.
- Graph (graph paper): a square grid of 1px `paper-line` lines at `paper-pitch`.
- Ruled: horizontal 1px `paper-line` rules at `paper-pitch`, plus a 1px `paper-margin` rule 64px from the left edge.
- The pitch scales with zoom, and the pattern is anchored to the page origin so it doesn't swim while you pan.
- Decoration only: it's left out of box snapshots, AI-facing output and the text snapshot. Boxes keep their `surface` fill, so text never sits on the lines.
- Choosing a background is a page setting (part of the page format) and a template field. It needs maintainer sign-off before it's built.
