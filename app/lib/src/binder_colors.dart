// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show contrastRatio;

import 'binder_cover.dart' show parseBinderColor;

/// The contrast a binder color must have against the surface it is drawn on
/// (WCAG 2.x, UI components).
const double binderMinContrast = 3.0;

/// How the stored binder color [stored] is shown on [surface].
///
/// A color that already has [binderMinContrast] is kept. Otherwise its HSL
/// lightness is moved (up on a dark surface, down on a light one) in steps of
/// 1% until it does, keeping hue and saturation so it stays recognizable. The
/// stored value is never changed; this is for display only.
Color binderDisplayColor(Color stored, Color surface) {
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
Color binderSidebarColor(BuildContext context, String hex) =>
    binderDisplayColor(
      parseBinderColor(hex),
      Theme.of(context).colorScheme.surfaceContainerLow,
    );

/// The binder color [hex] as shown on a page-colored surface.
Color binderPageColor(BuildContext context, String hex) => binderDisplayColor(
  parseBinderColor(hex),
  Theme.of(context).colorScheme.surface,
);
