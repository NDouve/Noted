// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart'
    show DesignColors, NotedColors, contrastRatio;

/// The pen's default color as stored (`PenSettings.colors.first`). Strokes
/// with this value are "default ink": drawn in the `ink-default` token (dark
/// on light pages, light on dark ones). The stored value never changes with
/// the theme.
const int defaultInkValue = 0xFF202124;

/// The contrast an ink swatch color must have against `bg-canvas` on screen
/// (WCAG 2.x, graphical objects).
const double inkMinContrast = 3.0;

/// The swatch inks' dark-theme display colors, by stored value: each `ink-*`
/// token whose value has less than [inkMinContrast] against the dark
/// `bg-canvas` is shown with its HSL lightness raised in 1% steps until it
/// does (hue and saturation kept). The others are shown as stored.
final Map<int, Color> _darkInks = {
  for (final ink in [
    DesignColors.light.inkBlue,
    DesignColors.light.inkOrange,
    DesignColors.light.inkGreen,
    DesignColors.light.inkPurple,
  ])
    ink.toARGB32(): _lifted(ink, DesignColors.dark.bgCanvas),
};

Color _lifted(Color ink, Color canvas) {
  final hsl = HSLColor.fromColor(ink);
  var l = hsl.lightness;
  var shown = ink;
  while (contrastRatio(shown, canvas) < inkMinContrast && l < 1) {
    l = (l + 0.01).clamp(0, 1).toDouble();
    shown = hsl.withLightness(l).toColor();
  }
  return shown;
}

/// The color a stroke stored as [stored] is drawn in on a page of
/// [brightness]. Default ink follows the theme. In dark mode a swatch ink
/// that would be too faint on the canvas is shown lifted, the way binder
/// colors are (0071). Every other color is drawn as stored, and the stored
/// value never changes.
Color displayInkColor(int stored, Brightness brightness) {
  if (stored == defaultInkValue) {
    return NotedColors.forBrightness(brightness).inkDefault;
  }
  if (brightness == Brightness.dark) {
    final lifted = _darkInks[stored];
    if (lifted != null) return lifted;
  }
  return Color(stored);
}
