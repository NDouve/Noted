// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show notedThemeData;

/// The app's theme in [brightness], built from the design tokens in
/// `docs/design/tokens.json` (see `notedThemeData`).
ThemeData buildNotedTheme(Brightness brightness, {bool touch = false}) =>
    notedThemeData(brightness, touch: touch);
