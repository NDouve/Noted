// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'drawing_codec.dart';
import 'drawing_tools.dart';
import 'stroke_render.dart';

/// The drawing box module (0016, 0034): ink anywhere on a page with the pen
/// and eraser tools. Its boxes grow to fit every stroke; a resize crops the
/// visible area and the rest scrolls.
final class DrawingModule extends BoxModule<DrawingData> {
  DrawingModule() {
    pen = PenTool(this);
    eraser = EraserTool(this);
  }

  late final PenTool pen;
  late final EraserTool eraser;

  /// The pen's current color and size, shown in the toolbar.
  final PenSettings settings = PenSettings();

  /// Each drawing box's internal scroll offset, shared between the box's
  /// view and the tools (which map pointer positions into the box).
  final Map<String, ValueNotifier<Offset>> _scrolls = {};

  ValueNotifier<Offset> scrollOf(String boxId) =>
      _scrolls.putIfAbsent(boxId, () => ValueNotifier(Offset.zero));

  @override
  BoxCodec<DrawingData> get codec => const DrawingCodec();

  @override
  List<CanvasTool> get tools => [pen, eraser];

  @override
  Widget buildEditor(BuildContext context, BoxContext<DrawingData> box) =>
      DrawingView(box: box, scroll: scrollOf(box.boxId));

  @override
  Widget buildView(BuildContext context, BoxContext<DrawingData> box) =>
      DrawingView(box: box, scroll: scrollOf(box.boxId));
}

/// Converts between page and content coordinates for a drawing box.
@immutable
final class DrawingFrame {
  const DrawingFrame(this.box, this.data, this.scroll);

  final Rect box;
  final DrawingData data;
  final Offset scroll;

  Offset get _anchor =>
      box.topLeft + Offset(data.originX, data.originY) - scroll;

  Offset toContent(Offset page) => page - _anchor;
  Offset toPage(Offset content) => content + _anchor;
}

/// The range a drawing box's view may scroll: enough to reach all its ink,
/// never past it.
(Offset, Offset) scrollRange(DrawingData data, Size view) {
  final ink = data.inkExtent;
  if (ink == null) return (Offset.zero, Offset.zero);
  final (l, t, r, b) = ink;
  final left = l + data.originX;
  final top = t + data.originY;
  final right = r + data.originX;
  final bottom = b + data.originY;
  return (
    Offset(math.min(0, left), math.min(0, top)),
    Offset(math.max(0, right - view.width), math.max(0, bottom - view.height)),
  );
}

/// A drawing box on the canvas. It takes no pointer input itself: drawing
/// and erasing happen through the canvas tools. The wheel scrolls the part
/// of the drawing a resize cropped; Ctrl+wheel still zooms the canvas.
class DrawingView extends StatefulWidget {
  const DrawingView({super.key, required this.box, required this.scroll});

  final BoxContext<DrawingData> box;
  final ValueNotifier<Offset> scroll;

  @override
  State<DrawingView> createState() => _DrawingViewState();
}

class _DrawingViewState extends State<DrawingView> {
  /// Outlines by stroke id. Strokes never change, so an outline is built
  /// once, however often the box's data is decoded again.
  final Map<String, Path> _outlines = {};

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    final size = widget.box.bounds.size;
    final (min, max) = scrollRange(widget.box.data, size);
    var delta = event.scrollDelta;
    if (HardwareKeyboard.instance.isShiftPressed && delta.dx == 0) {
      delta = Offset(delta.dy, 0);
    }
    final current = widget.scroll.value;
    final next = Offset(
      (current.dx + delta.dx).clamp(min.dx, max.dx),
      (current.dy + delta.dy).clamp(min.dy, max.dy),
    );
    // Only claim the wheel if the drawing actually scrolls; otherwise the
    // canvas pans.
    if (next == current) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      widget.scroll.value = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.box.data;
    final ids = {for (final s in data.strokes) s.id};
    _outlines.removeWhere((id, _) => !ids.contains(id));
    return Listener(
      onPointerSignal: _onSignal,
      child: ValueListenableBuilder<Offset>(
        valueListenable: widget.scroll,
        builder: (context, scroll, _) {
          final (min, max) = scrollRange(data, widget.box.bounds.size);
          final clamped = Offset(
            scroll.dx.clamp(min.dx, max.dx),
            scroll.dy.clamp(min.dy, max.dy),
          );
          return RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: _StrokesPainter(data, clamped, _outlines),
            ),
          );
        },
      ),
    );
  }
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(this.data, this.scroll, this.outlines);

  final DrawingData data;
  final Offset scroll;
  final Map<String, Path> outlines;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(data.originX - scroll.dx, data.originY - scroll.dy);
    final paint = Paint()..style = PaintingStyle.fill;
    for (final s in data.strokes) {
      final path = outlines.putIfAbsent(
        s.id,
        () => strokeOutline(
          s.points,
          size: s.size,
          hasPressure: s.hasPressure,
          complete: true,
        ),
      );
      canvas.drawPath(path, paint..color = Color(s.color));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StrokesPainter old) =>
      !identical(old.data, data) || old.scroll != scroll;
}
