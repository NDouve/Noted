// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ui';

import 'package:noted_core/noted_core.dart';

extension BoundsToRect on Bounds {
  Rect get rect => Rect.fromLTWH(x, y, width, height);
}

extension RectToBounds on Rect {
  Bounds get bounds => Bounds(left, top, width, height);
}
