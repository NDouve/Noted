// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ui';

import 'package:perfect_freehand/perfect_freehand.dart';

/// The outline of a stroke through [points] (x, y, pressure, time per
/// point), as a fillable path. Pressure is simulated when the device gave
/// none. [complete] is false while the stroke is still being drawn.
Path strokeOutline(
  List<double> points, {
  required double size,
  required bool hasPressure,
  required bool complete,
}) {
  final vectors = <PointVector>[
    for (var i = 0; i + 3 < points.length; i += 4)
      PointVector(points[i], points[i + 1], hasPressure ? points[i + 2] : null),
  ];
  final outline = getStroke(
    vectors,
    options: StrokeOptions(
      size: size,
      thinning: hasPressure ? 0.6 : 0.4,
      smoothing: 0.5,
      streamline: 0.4,
      simulatePressure: !hasPressure,
      isComplete: complete,
    ),
  );
  final path = Path();
  if (outline.isEmpty) return path;
  path.addPolygon(outline, true);
  return path;
}
