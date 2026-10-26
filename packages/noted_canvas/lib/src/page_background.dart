// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/widgets.dart';
import 'package:noted_core/noted_core.dart';

import 'canvas_view.dart';

/// Where the ruled background's margin line sits: 64 page units from the
/// page origin (page x = 0), so it scales and pans with the page.
const double pageMarginX = 64;

/// The thinnest the pattern may get on screen, in logical pixels. Below it
/// the pattern keeps every 2nd, 4th, ... line or dot (always a subset of the
/// full pattern, so nothing shifts) until it is at least this far apart.
const double minLineSpacing = 8;
const double minDotSpacing = 12;

/// No more than this many dots or lines are ever drawn for one frame.
const int maxBackgroundPrimitives = 20000;

/// A line is 1 logical pixel wide, a dot 1.5.
const double backgroundLineWidth = 1;
const double backgroundDotSize = 1.5;

/// What to draw for one frame, in screen coordinates. Computed from the view
/// alone, so it can be tested without painting.
@immutable
final class BackgroundPrimitives {
  const BackgroundPrimitives({
    this.dots = const [],
    this.verticalLines = const [],
    this.horizontalLines = const [],
    this.marginLine,
    this.step = 0,
  });

  /// Dot centres (Dots).
  final List<Offset> dots;

  /// Screen x of each vertical grid line (Graph).
  final List<double> verticalLines;

  /// Screen y of each horizontal line (Graph, Ruled).
  final List<double> horizontalLines;

  /// Screen x of the margin line (Ruled), or null if off screen or not Ruled.
  final double? marginLine;

  /// The spacing used, in page units (a multiple of the pitch when thinned);
  /// 0 for Plain.
  final double step;
}

/// The primitives [background] draws in a viewport of [size] showing [view].
///
/// The pattern lies on page coordinates: lines and dots are at multiples of
/// the [pitch] from the page origin (0, 0) and the pitch scales with the zoom,
/// so nothing swims while panning. With [devicePixelRatio] the line positions
/// snap to device pixels so they stay crisp.
BackgroundPrimitives backgroundPrimitives({
  required PageBackground background,
  required CanvasView view,
  required Size size,
  required double pitch,
  double devicePixelRatio = 1,
}) {
  if (background == PageBackground.plain || size.isEmpty || pitch <= 0) {
    return const BackgroundPrimitives();
  }
  final s = view.scale;
  final dots = background == PageBackground.dots;
  final minSpacing = dots ? minDotSpacing : minLineSpacing;
  final world = view.visible(size);

  int count(double step) {
    final cols = (world.width / step).ceil() + 1;
    final rows = (world.height / step).ceil() + 1;
    return switch (background) {
      PageBackground.dots => cols * rows,
      PageBackground.graph => cols + rows,
      _ => rows,
    };
  }

  var step = pitch;
  while (step * s < minSpacing || count(step) > maxBackgroundPrimitives) {
    step *= 2;
  }

  double snap(double v) =>
      (v * devicePixelRatio).roundToDouble() / devicePixelRatio;

  List<double> multiples(double lo, double hi, double Function(double) toScreen) {
    final out = <double>[];
    for (var k = (lo / step).floor(); k * step <= hi; k++) {
      out.add(toScreen(k * step));
    }
    return out;
  }

  double sx(double x) => snap(x * s + view.offset.dx);
  double sy(double y) => snap(y * s + view.offset.dy);

  switch (background) {
    case PageBackground.plain:
      return const BackgroundPrimitives();
    case PageBackground.dots:
      final xs = multiples(world.left, world.right, (x) => x * s + view.offset.dx);
      final ys = multiples(world.top, world.bottom, (y) => y * s + view.offset.dy);
      return BackgroundPrimitives(
        dots: [
          for (final y in ys)
            for (final x in xs) Offset(snap(x), snap(y)),
        ],
        step: step,
      );
    case PageBackground.graph:
      return BackgroundPrimitives(
        verticalLines: multiples(world.left, world.right, sx),
        horizontalLines: multiples(world.top, world.bottom, sy),
        step: step,
      );
    case PageBackground.ruled:
      final mx = sx(pageMarginX);
      return BackgroundPrimitives(
        horizontalLines: multiples(world.top, world.bottom, sy),
        marginLine: mx >= -backgroundLineWidth && mx <= size.width ? mx : null,
        step: step,
      );
  }
}

/// Draws a page's background under its boxes: Plain nothing, Dots, Graph
/// (square grid) or Ruled (horizontal rules and a margin line). Colors come
/// from the theme's paper tokens; the canvas color is drawn by the caller.
class PageBackgroundPainter extends CustomPainter {
  const PageBackgroundPainter({
    required this.background,
    required this.view,
    required this.pitch,
    required this.lineColor,
    required this.dotColor,
    required this.marginColor,
    this.devicePixelRatio = 1,
  });

  final PageBackground background;
  final CanvasView view;
  final double pitch;
  final Color lineColor;
  final Color dotColor;
  final Color marginColor;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final p = backgroundPrimitives(
      background: background,
      view: view,
      size: size,
      pitch: pitch,
      devicePixelRatio: devicePixelRatio,
    );
    if (p.dots.isNotEmpty) {
      final points = Float32List(p.dots.length * 2);
      for (var i = 0; i < p.dots.length; i++) {
        points[i * 2] = p.dots[i].dx;
        points[i * 2 + 1] = p.dots[i].dy;
      }
      canvas.drawRawPoints(
        PointMode.points,
        points,
        Paint()
          ..color = dotColor
          ..strokeWidth = backgroundDotSize
          ..strokeCap = StrokeCap.round,
      );
    }
    final line = Paint()
      ..color = lineColor
      ..isAntiAlias = false;
    for (final x in p.verticalLines) {
      canvas.drawRect(Rect.fromLTWH(x, 0, backgroundLineWidth, size.height), line);
    }
    for (final y in p.horizontalLines) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, backgroundLineWidth), line);
    }
    final m = p.marginLine;
    if (m != null) {
      canvas.drawRect(
        Rect.fromLTWH(m, 0, backgroundLineWidth, size.height),
        Paint()
          ..color = marginColor
          ..isAntiAlias = false,
      );
    }
  }

  @override
  bool shouldRepaint(PageBackgroundPainter old) =>
      old.background != background ||
      old.view != view ||
      old.pitch != pitch ||
      old.lineColor != lineColor ||
      old.dotColor != dotColor ||
      old.marginColor != marginColor ||
      old.devicePixelRatio != devicePixelRatio;
}
