// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show defaultNarrowLayoutWidth, notedThemeData;

import 'device_storage.dart' show isMobilePlatform;

/// Desktop windows narrower than this use the drawer (0178). A phone or tablet
/// keeps [defaultNarrowLayoutWidth] (0130).
const double desktopNarrowLayoutWidth = 720;

/// The app's theme in [brightness], built from the design tokens in
/// `docs/design/tokens.json` (see `notedThemeData`). [narrowBelow] is the
/// window width under which the sidebar is a drawer: by default 720 on
/// desktop and 1000 on a phone or tablet.
ThemeData buildNotedTheme(Brightness brightness, {bool touch = false, double? narrowBelow}) => notedThemeData(
  brightness,
  touch: touch,
  narrowLayoutBelow: narrowBelow ?? (isMobilePlatform ? defaultNarrowLayoutWidth : desktopNarrowLayoutWidth),
);
