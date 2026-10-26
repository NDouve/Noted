// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedColors;

/// The pen's default color as stored (`PenSettings.colors.first`). Strokes
/// with this value are "default ink": drawn in the `ink-default` token (dark
/// on light pages, light on dark ones). The stored value never changes with
/// the theme.
const int defaultInkValue = 0xFF202124;

/// The color a stroke stored as [stored] is drawn in on a page of
/// [brightness]. Only default ink adapts; every other color is kept.
Color displayInkColor(int stored, Brightness brightness) {
  if (stored == defaultInkValue) {
    return NotedColors.forBrightness(brightness).inkDefault;
  }
  return Color(stored);
}
