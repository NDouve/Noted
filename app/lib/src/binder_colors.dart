// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart'
    show DesignColors, contrastRatio;

import 'binder_cover.dart' show parseBinderColor;

/// The contrast a binder color must have against the surface it is drawn on
/// (WCAG 2.x, UI components).
const double binderMinContrast = 3.0;

/// The `binder-*` tokens as (light, dark) pairs. A stored binder color equal
/// to a light value is shown as the pair's value for the theme.
List<(Color light, Color dark)> get _binderTokens => [
  (DesignColors.light.binderGreen, DesignColors.dark.binderGreen),
  (DesignColors.light.binderOrange, DesignColors.dark.binderOrange),
  (DesignColors.light.binderBlue, DesignColors.dark.binderBlue),
  (DesignColors.light.binderPurple, DesignColors.dark.binderPurple),
  (DesignColors.light.binderTeal, DesignColors.dark.binderTeal),
];

/// How the stored binder color [stored] is shown on [surface] in a theme of
/// [brightness].
///
/// A color equal to a `binder-*` token's light value is shown as that token's
/// value for the theme. Any other color that already has [binderMinContrast]
/// is kept; otherwise its HSL lightness is moved (up on a dark surface, down
/// on a light one) in steps of 1% until it does, keeping hue and saturation so
/// it stays recognizable. The stored value is never changed; this is for
/// display only.
Color binderDisplayColor(Color stored, Color surface, Brightness brightness) {
  for (final (light, dark) in _binderTokens) {
    if (stored == light) return brightness == Brightness.dark ? dark : light;
  }
  if (contrastRatio(stored, surface) >= binderMinContrast) return stored;
  final hsl = HSLColor.fromColor(stored);
  final raise = surface.computeLuminance() < 0.5;
  var l = hsl.lightness;
  var shown = stored;
  while (contrastRatio(shown, surface) < binderMinContrast) {
    l += raise ? 0.01 : -0.01;
    if (l < 0 || l > 1) break;
    shown = hsl.withLightness(l).toColor();
  }
  return shown;
}

/// The binder color [hex] (`#AARRGGBB`) as shown in the sidebar.
Color binderSidebarColor(BuildContext context, String hex) {
  final theme = Theme.of(context);
  return binderDisplayColor(
    parseBinderColor(hex),
    theme.colorScheme.surfaceContainerLow,
    theme.brightness,
  );
}

/// The binder color [hex] as shown on a page-colored surface.
Color binderPageColor(BuildContext context, String hex) {
  final theme = Theme.of(context);
  return binderDisplayColor(
    parseBinderColor(hex),
    theme.colorScheme.surfaceContainerLowest,
    theme.brightness,
  );
}
