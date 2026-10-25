// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

/// An axis-aligned rectangle in page (world) coordinates.
///
/// The core is pure Dart and can't use `dart:ui`'s `Rect`. The canvas
/// converts between the two.
final class Bounds {
  const Bounds(this.x, this.y, this.width, this.height);

  static const Bounds zero = Bounds(0, 0, 0, 0);

  final double x;
  final double y;
  final double width;
  final double height;

  double get right => x + width;
  double get bottom => y + height;

  Bounds union(Bounds other) {
    final l = math.min(x, other.x);
    final t = math.min(y, other.y);
    return Bounds(
      l,
      t,
      math.max(right, other.right) - l,
      math.max(bottom, other.bottom) - t,
    );
  }

  /// Rounds every edge to whole pixels. JSON Canvas stores integers.
  Bounds rounded() => Bounds(
    x.roundToDouble(),
    y.roundToDouble(),
    width.roundToDouble(),
    height.roundToDouble(),
  );

  @override
  bool operator ==(Object other) =>
      other is Bounds &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'Bounds($x, $y, $width, $height)';
}
