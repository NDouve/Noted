// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// WCAG 2.x contrast ratio between [a] and [b] (1 to 21). Translucent colors
/// are compared as given, so composite them first.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// App-specific color roles that [ColorScheme] has no slot for. Register it
/// in `ThemeData.extensions`; [NotedColors.of] builds one from the scheme
/// when a theme has none, so widgets work under a plain `ThemeData` too.
@immutable
class NotedColors extends ThemeExtension<NotedColors> {
  const NotedColors({
    required this.defaultInk,
    required this.conflict,
    required this.conflictBadge,
    required this.onConflictBadge,
    required this.gridLabel,
    required this.formulaError,
    required this.readoutBackground,
    required this.onReadout,
    required this.toolRing,
    required this.mutedText,
  });

  /// The colors for a theme built from [scheme].
  factory NotedColors.fromScheme(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return NotedColors(
      defaultInk: dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
      // Amber that stays visible on the page: darker on light surfaces.
      conflict: dark ? const Color(0xFFF59E0B) : const Color(0xFFB45309),
      conflictBadge: const Color(0xFFF59E0B),
      onConflictBadge: const Color(0xFF000000),
      gridLabel: scheme.onSurfaceVariant,
      formulaError: scheme.error,
      readoutBackground: scheme.inverseSurface.withValues(alpha: 0.85),
      onReadout: scheme.onInverseSurface,
      toolRing: scheme.onSurfaceVariant,
      mutedText: scheme.onSurfaceVariant,
    );
  }

  /// The theme's, or one derived from its color scheme.
  static NotedColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NotedColors>() ??
        NotedColors.fromScheme(theme.colorScheme);
  }

  /// The pen's default color: black on light pages, white on dark ones.
  final Color defaultInk;

  /// Frame and marker of a conflicted box or page (UI component, 3:1).
  final Color conflict;

  /// Fill of the "Conflict" badge, and the text color on it.
  final Color conflictBadge;
  final Color onConflictBadge;

  /// Row and column letters/numbers of a table with formulas.
  final Color gridLabel;

  /// Text of a formula that doesn't evaluate.
  final Color formulaError;

  /// The debug input readout and its text.
  final Color readoutBackground;
  final Color onReadout;

  /// Outline of tool feedback such as the eraser ring.
  final Color toolRing;

  /// Secondary text such as placeholders and unavailable rows.
  final Color mutedText;

  @override
  NotedColors copyWith({
    Color? defaultInk,
    Color? conflict,
    Color? conflictBadge,
    Color? onConflictBadge,
    Color? gridLabel,
    Color? formulaError,
    Color? readoutBackground,
    Color? onReadout,
    Color? toolRing,
    Color? mutedText,
  }) => NotedColors(
    defaultInk: defaultInk ?? this.defaultInk,
    conflict: conflict ?? this.conflict,
    conflictBadge: conflictBadge ?? this.conflictBadge,
    onConflictBadge: onConflictBadge ?? this.onConflictBadge,
    gridLabel: gridLabel ?? this.gridLabel,
    formulaError: formulaError ?? this.formulaError,
    readoutBackground: readoutBackground ?? this.readoutBackground,
    onReadout: onReadout ?? this.onReadout,
    toolRing: toolRing ?? this.toolRing,
    mutedText: mutedText ?? this.mutedText,
  );

  @override
  NotedColors lerp(NotedColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return NotedColors(
      defaultInk: l(defaultInk, other.defaultInk),
      conflict: l(conflict, other.conflict),
      conflictBadge: l(conflictBadge, other.conflictBadge),
      onConflictBadge: l(onConflictBadge, other.onConflictBadge),
      gridLabel: l(gridLabel, other.gridLabel),
      formulaError: l(formulaError, other.formulaError),
      readoutBackground: l(readoutBackground, other.readoutBackground),
      onReadout: l(onReadout, other.onReadout),
      toolRing: l(toolRing, other.toolRing),
      mutedText: l(mutedText, other.mutedText),
    );
  }
}
