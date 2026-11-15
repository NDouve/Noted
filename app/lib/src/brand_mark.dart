// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

/// The compact N of the app icon (`docs/design/icon`, 380 x 380 view box): the
/// path `M110 330 V74 L270 298 V50`, stroke 56, round caps and joins, with the
/// master's two-stop gradient (`brand-blue-start` to `brand-blue-end`). The
/// superscript d is left out, as in the icon's 16 and 20 px sizes. The brand
/// blue is the icon's, not `accent`, and is decorative: no contrast role.
const double _pathHeight = 280; // 50 to 330 (centre line)
const double _pathWidth = 160; // 110 to 270
const double _strokeUnits = 56;
const double _leftTop = 74 - 50; // left stem's top, below the right stem's
const double _rightBottom = 298 - 50; // right stem's bottom, above the left's

/// How tall the mark is, in logical pixels.
const double brandMarkHeight = 16;

/// Where the N is drawn, in device pixels: whole numbers, so the stems are
/// whole opaque pixel columns (the 0096 rule).
class BrandMarkGeometry {
  const BrandMarkGeometry._(this.height, this.stroke, this.stemGap);

  /// The geometry for a height of [brandMarkHeight] logical px at
  /// [devicePixelRatio]: 16 / 20 / 24 device px high at 100 / 125 / 150%.
  factory BrandMarkGeometry.at(double devicePixelRatio) {
    final h = (brandMarkHeight * devicePixelRatio).round();
    final stroke = (h * _strokeUnits / (_pathHeight + _strokeUnits)).round().clamp(1, h);
    // The stems' centre lines are this far apart (the path's 160 units against
    // its 280, scaled to the height the caps leave).
    final gap = ((h - stroke) * _pathWidth / _pathHeight).round();
    return BrandMarkGeometry._(h, stroke, gap);
  }

  /// Painted height, in device pixels.
  final int height;

  /// Stroke width, in device pixels.
  final int stroke;

  /// Distance between the two stems' centre lines, in device pixels.
  final int stemGap;

  /// Painted width, in device pixels.
  int get width => stemGap + stroke;

  /// The left edge of the left and the right stem, in device pixels.
  (int, int) get stemLefts => (0, stemGap);
}

/// The two gradient stops of the mark: the brand tokens, with no lightness
/// lift (the brand roles come straight from the master gradient).
(Color, Color) brandMarkColors(NotedColors colors) => (
  colors.brandBlueStart,
  colors.brandBlueEnd,
);

/// The mark and, when [showWordmark], "Noted" beside it. One semantics node
/// labelled "Noted"; not focusable and not a button.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.showWordmark = true});

  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final (from, to) = brandMarkColors(NotedColors.of(context));
    final geometry = BrandMarkGeometry.at(dpr);
    return Semantics(
      label: 'Noted',
      container: true,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            key: const ValueKey('brand-mark'),
            size: Size(geometry.width / dpr, geometry.height / dpr),
            painter: BrandMarkPainter(
              geometry: geometry,
              devicePixelRatio: dpr,
              from: from,
              to: to,
            ),
          ),
          if (showWordmark) ...[
            SizedBox(width: m.space2),
            Text(
              'Noted',
              key: const ValueKey('brand-wordmark'),
              style: NotedTypography.of(context).bodyStrong
                  .copyWith(color: theme.colorScheme.onSurface),
            ),
          ],
        ],
      ),
    );
  }
}

/// Draws the N in device pixels (the canvas is scaled back by the ratio).
class BrandMarkPainter extends CustomPainter {
  const BrandMarkPainter({
    required this.geometry,
    required this.devicePixelRatio,
    required this.from,
    required this.to,
  });

  final BrandMarkGeometry geometry;
  final double devicePixelRatio;
  final Color from;
  final Color to;

  /// The N's centre line in device pixels.
  Path path() {
    final g = geometry;
    final half = g.stroke / 2;
    final (left, right) = g.stemLefts;
    final x0 = left + half;
    final x1 = right + half;
    // The path's own steps: the left stem is lower than the right.
    final scale = (g.height - g.stroke) / _pathHeight;
    return Path()
      ..moveTo(x0, g.height - half)
      ..lineTo(x0, half + _leftTop * scale)
      ..lineTo(x1, half + _rightBottom * scale)
      ..lineTo(x1, half);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    canvas.save();
    canvas.scale(1 / devicePixelRatio);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = g.stroke.toDouble()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..shader = ui.Gradient.linear(Offset.zero, Offset(g.width.toDouble(), g.height.toDouble()), [
        from,
        to,
      ]);
    canvas.drawPath(path(), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(BrandMarkPainter old) =>
      old.geometry != geometry ||
      old.devicePixelRatio != devicePixelRatio ||
      old.from != from ||
      old.to != to;
}
