// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'design_tokens.g.dart';

/// WCAG 2.x contrast ratio between [a] and [b] (1 to 21). Translucent colors
/// are compared as given, so composite them first.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The design-token colors that [ColorScheme] has no slot for (see
/// `docs/design/README.md`, "Mapping to Flutter"). Register it in
/// `ThemeData.extensions`; [NotedColors.of] falls back to the light or dark
/// set by brightness when a theme has none, so widgets work under a plain
/// `ThemeData` too.
@immutable
class NotedColors extends ThemeExtension<NotedColors> {
  const NotedColors({
    required this.bgSidebar,
    required this.surfaceHover,
    required this.textDisabled,
    required this.conflict,
    required this.conflictSoft,
    required this.onConflict,
    required this.inkDefault,
    required this.inkBlue,
    required this.inkOrange,
    required this.inkGreen,
    required this.inkPurple,
    required this.binderGreen,
    required this.binderOrange,
    required this.binderBlue,
    required this.binderPurple,
    required this.binderTeal,
    required this.paperLine,
    required this.paperDot,
    required this.paperMargin,
    required this.toolRing,
    required this.readoutBackground,
    required this.onReadout,
  });

  /// The colors of the design tokens [c].
  factory NotedColors.fromTokens(DesignColors c) => NotedColors(
    bgSidebar: c.bgSidebar,
    surfaceHover: c.surfaceHover,
    textDisabled: c.textDisabled,
    conflict: c.conflict,
    conflictSoft: c.conflictSoft,
    onConflict: c.onConflict,
    inkDefault: c.inkDefault,
    inkBlue: c.inkBlue,
    inkOrange: c.inkOrange,
    inkGreen: c.inkGreen,
    inkPurple: c.inkPurple,
    binderGreen: c.binderGreen,
    binderOrange: c.binderOrange,
    binderBlue: c.binderBlue,
    binderPurple: c.binderPurple,
    binderTeal: c.binderTeal,
    paperLine: c.paperLine,
    paperDot: c.paperDot,
    paperMargin: c.paperMargin,
    // Eraser ring: secondary text color, so it passes 3:1 on the canvas.
    toolRing: c.textMuted,
    // Debug input readout: inverted text/surface, translucent.
    readoutBackground: c.text.withValues(alpha: 0.85),
    onReadout: c.surface,
  );

  /// The light theme's colors.
  static final NotedColors light = NotedColors.fromTokens(DesignColors.light);

  /// The dark theme's colors.
  static final NotedColors dark = NotedColors.fromTokens(DesignColors.dark);

  /// The colors for [brightness].
  static NotedColors forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The theme's, or the token set for its brightness.
  static NotedColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NotedColors>() ?? forBrightness(theme.brightness);
  }

  /// Sidebar (page tree) background.
  final Color bgSidebar;

  /// Hover fill for rows, menu items and ghost buttons.
  final Color surfaceHover;

  /// Inactive controls and unavailable pages only.
  final Color textDisabled;

  /// Sync conflicts only: box frame, badge, sidebar dot.
  final Color conflict;

  /// Read-only and recovery banners; conflict view header.
  final Color conflictSoft;

  /// Text on a solid [conflict] fill.
  final Color onConflict;

  /// Display color of default ink (stored as `#FF202124`); flips with the theme.
  final Color inkDefault;

  /// Ink swatches; fixed in both themes.
  final Color inkBlue;
  final Color inkOrange;
  final Color inkGreen;
  final Color inkPurple;

  /// Binder chip and stripe colors (the lifted shade in dark).
  final Color binderGreen;
  final Color binderOrange;
  final Color binderBlue;
  final Color binderPurple;
  final Color binderTeal;

  /// Graph and ruled page-background lines.
  final Color paperLine;

  /// Dot-grid page background.
  final Color paperDot;

  /// The left margin rule of the ruled page background.
  final Color paperMargin;

  /// Outline of tool feedback such as the eraser ring.
  final Color toolRing;

  /// The debug input readout and its text.
  final Color readoutBackground;
  final Color onReadout;

  @override
  NotedColors copyWith({
    Color? bgSidebar,
    Color? surfaceHover,
    Color? textDisabled,
    Color? conflict,
    Color? conflictSoft,
    Color? onConflict,
    Color? inkDefault,
    Color? inkBlue,
    Color? inkOrange,
    Color? inkGreen,
    Color? inkPurple,
    Color? binderGreen,
    Color? binderOrange,
    Color? binderBlue,
    Color? binderPurple,
    Color? binderTeal,
    Color? paperLine,
    Color? paperDot,
    Color? paperMargin,
    Color? toolRing,
    Color? readoutBackground,
    Color? onReadout,
  }) => NotedColors(
    bgSidebar: bgSidebar ?? this.bgSidebar,
    surfaceHover: surfaceHover ?? this.surfaceHover,
    textDisabled: textDisabled ?? this.textDisabled,
    conflict: conflict ?? this.conflict,
    conflictSoft: conflictSoft ?? this.conflictSoft,
    onConflict: onConflict ?? this.onConflict,
    inkDefault: inkDefault ?? this.inkDefault,
    inkBlue: inkBlue ?? this.inkBlue,
    inkOrange: inkOrange ?? this.inkOrange,
    inkGreen: inkGreen ?? this.inkGreen,
    inkPurple: inkPurple ?? this.inkPurple,
    binderGreen: binderGreen ?? this.binderGreen,
    binderOrange: binderOrange ?? this.binderOrange,
    binderBlue: binderBlue ?? this.binderBlue,
    binderPurple: binderPurple ?? this.binderPurple,
    binderTeal: binderTeal ?? this.binderTeal,
    paperLine: paperLine ?? this.paperLine,
    paperDot: paperDot ?? this.paperDot,
    paperMargin: paperMargin ?? this.paperMargin,
    toolRing: toolRing ?? this.toolRing,
    readoutBackground: readoutBackground ?? this.readoutBackground,
    onReadout: onReadout ?? this.onReadout,
  );

  @override
  NotedColors lerp(NotedColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return NotedColors(
      bgSidebar: l(bgSidebar, other.bgSidebar),
      surfaceHover: l(surfaceHover, other.surfaceHover),
      textDisabled: l(textDisabled, other.textDisabled),
      conflict: l(conflict, other.conflict),
      conflictSoft: l(conflictSoft, other.conflictSoft),
      onConflict: l(onConflict, other.onConflict),
      inkDefault: l(inkDefault, other.inkDefault),
      inkBlue: l(inkBlue, other.inkBlue),
      inkOrange: l(inkOrange, other.inkOrange),
      inkGreen: l(inkGreen, other.inkGreen),
      inkPurple: l(inkPurple, other.inkPurple),
      binderGreen: l(binderGreen, other.binderGreen),
      binderOrange: l(binderOrange, other.binderOrange),
      binderBlue: l(binderBlue, other.binderBlue),
      binderPurple: l(binderPurple, other.binderPurple),
      binderTeal: l(binderTeal, other.binderTeal),
      paperLine: l(paperLine, other.paperLine),
      paperDot: l(paperDot, other.paperDot),
      paperMargin: l(paperMargin, other.paperMargin),
      toolRing: l(toolRing, other.toolRing),
      readoutBackground: l(readoutBackground, other.readoutBackground),
      onReadout: l(onReadout, other.onReadout),
    );
  }
}
