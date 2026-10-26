// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The visible part of a page: `screen = world * scale + offset`.
@immutable
final class CanvasView {
  const CanvasView(this.scale, this.offset);

  static const CanvasView identity = CanvasView(1, Offset.zero);

  final double scale;
  final Offset offset;

  Offset toScreen(Offset world) => world * scale + offset;
  Offset toWorld(Offset screen) => (screen - offset) / scale;

  /// The world rectangle visible in a viewport of [size].
  Rect visible(Size size) => Rect.fromPoints(
    toWorld(Offset.zero),
    toWorld(size.bottomRight(Offset.zero)),
  );

  @override
  bool operator ==(Object other) =>
      other is CanvasView && other.scale == scale && other.offset == offset;

  @override
  int get hashCode => Object.hash(scale, offset);

  @override
  String toString() => 'CanvasView($scale, $offset)';
}

/// Zoom limits and the margin around content, for 0003.
const double canvasMinScale = 0.1;
const double canvasMaxScale = 4;

/// Space kept around boxes inside the canvas child, so box chrome (grip and
/// resize handles) stays hit-testable.
const double canvasChromePadding = 24;

/// Where the canvas child sits and how far the view may go.
///
/// Panning is bounded to the content plus a margin of one viewport on every
/// side ([boundaryMargin], 0003): the content is never more than a screen
/// away. Zooming out stops once that whole area fills the viewport.
@immutable
final class CanvasGeometry {
  const CanvasGeometry._(this.viewport, this.child, this.boundaryMargin);

  /// [content] is the union of all box bounds, or null for an empty page.
  factory CanvasGeometry.compute({
    required Rect? content,
    required Size viewport,
  }) {
    final child = content == null
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : content.inflate(canvasChromePadding);
    var boundary = EdgeInsets.symmetric(
      horizontal: viewport.width,
      vertical: viewport.height,
    ).inflateRect(child);
    // On a long, narrow page the Fit all view is wider (or taller) than one
    // viewport of margin. Include it so the zoom floor never blocks Fit all.
    if (content != null && !viewport.isEmpty) {
      final s = _fitScale(content, viewport);
      boundary = boundary.expandToInclude(
        Rect.fromCenter(
          center: content.center,
          width: viewport.width / s,
          height: viewport.height / s,
        ),
      );
    }
    return CanvasGeometry._(
      viewport,
      child,
      EdgeInsets.fromLTRB(
        child.left - boundary.left,
        child.top - boundary.top,
        boundary.right - child.right,
        boundary.bottom - child.bottom,
      ),
    );
  }

  static double _fitScale(Rect content, Size viewport) {
    final r = content.inflate(canvasChromePadding);
    return math.min(
      1.0,
      math.min(viewport.width / r.width, viewport.height / r.height),
    );
  }

  final Size viewport;

  /// The canvas child's rectangle in world coordinates.
  final Rect child;

  /// The margin around [child] that panning may reach.
  final EdgeInsets boundaryMargin;

  /// Everything the view may show, in world coordinates.
  Rect get boundary => boundaryMargin.inflateRect(child);

  /// The smallest scale at which [boundary] still fills the viewport.
  double get minScale => math.max(
    canvasMinScale,
    math.max(
      viewport.width / boundary.width,
      viewport.height / boundary.height,
    ),
  );

  double get maxScale => canvasMaxScale;

  /// Brings [view] within the zoom limits and the pan boundary.
  CanvasView clamp(CanvasView view) {
    if (viewport.isEmpty) return view;
    final s = view.scale.clamp(minScale, maxScale).toDouble();
    final b = boundary;
    // Keep the visible world rect inside the boundary on each axis.
    final dx = _clampAxis(
      view.offset.dx,
      viewport.width - s * b.right,
      -s * b.left,
    );
    final dy = _clampAxis(
      view.offset.dy,
      viewport.height - s * b.bottom,
      -s * b.top,
    );
    return CanvasView(s, Offset(dx, dy));
  }

  // At the zoom floor the range can invert by a rounding error; centre then.
  static double _clampAxis(double v, double lo, double hi) =>
      lo > hi ? (lo + hi) / 2 : v.clamp(lo, hi).toDouble();

  /// Zooms by [factor] around [focal], a viewport point that stays put.
  ///
  /// [pan] first moves the content by that many viewport pixels (a pinch
  /// whose fingers also move): the world point that was under
  /// `focal - pan` ends up under [focal]. The anchor is exact; the pan
  /// bounds then move the view only by the overshoot on each axis. At a
  /// zoom limit, with no [pan], the view is returned untouched.
  CanvasView zoomAt(
    CanvasView view,
    Offset focal,
    double factor, {
    Offset pan = Offset.zero,
  }) {
    final s = (view.scale * factor).clamp(minScale, maxScale).toDouble();
    if (s == view.scale && pan == Offset.zero) return view;
    final world = view.toWorld(focal - pan);
    return clamp(CanvasView(s, focal - world * s));
  }

  /// Pans by [delta] viewport pixels.
  CanvasView pan(CanvasView view, Offset delta) =>
      clamp(CanvasView(view.scale, view.offset + delta));

  /// Fits [content] in the viewport, never zooming in past 100%.
  CanvasView fitAll(Rect? content) {
    if (content == null || viewport.isEmpty) return clamp(CanvasView.identity);
    final s = _fitScale(content, viewport);
    final offset = viewport.center(Offset.zero) - content.center * s;
    return clamp(CanvasView(s, offset));
  }

  /// The view a page opens with: 100%, content's top-left near the corner.
  CanvasView initial(Rect? content) {
    if (content == null) return clamp(CanvasView.identity);
    final topLeft =
        content.topLeft -
        const Offset(canvasChromePadding * 2, canvasChromePadding * 2);
    return clamp(CanvasView(1, -topLeft));
  }

  /// The InteractiveViewer matrix for [view]. Its child is laid out at the
  /// viewport origin, so the child's world position is folded in here.
  Matrix4 matrixFor(CanvasView view) {
    final s = view.scale;
    final t = view.offset + child.topLeft * s;
    return Matrix4(s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, t.dx, t.dy, 0, 1);
  }
}
