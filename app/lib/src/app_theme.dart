// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedColors;

/// The seed of the color scheme, for both themes.
const Color notedSeed = Color(0xFF3F51B5);

/// The app's theme in [brightness], with its [NotedColors].
ThemeData buildNotedTheme(Brightness brightness) {
  final base = ThemeData(
    colorSchemeSeed: notedSeed,
    brightness: brightness,
    useMaterial3: true,
  );
  return base.copyWith(
    extensions: [NotedColors.fromScheme(base.colorScheme)],
  );
}
