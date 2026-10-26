// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'drawing_codec.dart';
import 'drawing_module.dart';
import 'ink_color.dart';
import 'stroke_render.dart';

/// A stroke that starts this close to a drawing box (page pixels) is added
/// to that box instead of starting a new one. To be tuned by hand.
const double joinDistance = 32;

/// Eraser radius in screen pixels, whatever the zoom.
const double eraserRadius = 10;

/// The pen's color and size, chosen in the toolbar.
class PenSettings extends ChangeNotifier {
  static const List<int> colors = [
    defaultInkValue,
    0xFF1A73E8,
    0xFFD93025,
    0xFF188038,
  ];
  static const List<double> sizes = [2, 4, 8];

  int _color = colors.first;
  double _size = sizes[1];

  int get color => _color;
  double get size => _size;

  set color(int value) {
    _color = value;
    notifyListeners();
  }

  set size(double value) {
    _size = value;
    notifyListeners();
  }
}

/// A drawing box on the page with its decoded data and coordinate frame.
typedef _Drawing = (BoxRecord box, DrawingData data, DrawingFrame frame);

/// Drawing boxes this device can run, topmost first.
Iterable<_Drawing> _drawings(DrawingModule module, CanvasController c) sync* {
  final nodes = c.page.nodes;
  for (var i = nodes.length - 1; i >= 0; i--) {
    final n = nodes[i];
    if (n is! BoxRecord || n.typeId != DrawingCodec.id) continue;
    final r = c.modules.codecs.resolve(n);
    if (r is! LiveBox) continue;
    final data = r.data! as DrawingData;
    final rect = n.bounds.rect;
    final (min, max) = scrollRange(data, rect.size);
    final s = module.scrollOf(n.id).value;
    final scroll = Offset(
      s.dx.clamp(min.dx, max.dx),
      s.dy.clamp(min.dy, max.dy),
    );
    yield (n, data, DrawingFrame(rect, data, scroll));
  }
}

/// The pen: ink anywhere (0016). A stroke goes into the drawing box it
/// starts in or near, which grows to fit it; otherwise it starts a new
/// drawing box, which may overlap other boxes (0024).
class PenTool extends CanvasTool {
  PenTool(this.module);

  final DrawingModule module;

  @override
  String get id => 'noted.drawing.pen';
  @override
  String get label => 'Pen';
  @override
  IconData get icon => Icons.edit;
  @override
  LogicalKeyboardKey? get shortcut => LogicalKeyboardKey.keyP;

  @override
  Widget? buildOptions(BuildContext context) => _PenOptions(module.settings);

  @override
  ToolSession? start(ToolContext context, ToolPointer pointer) {
    String? target;
    for (final (box, _, _) in _drawings(module, context.controller)) {
      if (box.bounds.rect.inflate(joinDistance).contains(pointer.position)) {
        target = box.id;
        break;
      }
    }
    return _PenSession(module, context, pointer, target);
  }
}

class _PenSession extends ToolSession {
  _PenSession(this.module, this.context, ToolPointer first, this.target)
    : color = module.settings.color,
      size = module.settings.size,
      hasPressure = first.pressure != null,
      startTime = first.time,
      startedAt = DateTime.now().millisecondsSinceEpoch {
    _add(first);
  }

  final DrawingModule module;
  final ToolContext context;
  final String? target;
  final int color;
  final double size;
  final bool hasPressure;
  final Duration startTime;
  final int startedAt;

  /// Page coordinates, four values per point as in [Stroke.points]. Every
  /// sample is kept: none are dropped or merged.
  final List<double> _points = [];

  /// The input, for tests.
  int get pointCount => _points.length ~/ 4;

  void _add(ToolPointer p) {
    _points
      ..add(p.position.dx)
      ..add(p.position.dy)
      ..add(p.pressure ?? 0.5)
      ..add((p.time - startTime).inMicroseconds / 1000);
  }

  @override
  void update(ToolPointer pointer) {
    _add(pointer);
    context.repaintOverlay();
  }

  @override
  void paint(Canvas canvas, double scale) {
    final path = strokeOutline(
      _points,
      size: size,
      hasPressure: hasPressure,
      complete: false,
    );
    canvas.drawPath(path, Paint()..color = displayInkColor(color, context.brightness));
  }

  @override
  void cancel() {}

  @override
  void end() {
    final c = context.controller;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (var i = 0; i < _points.length; i += 4) {
      minX = math.min(minX, _points[i]);
      maxX = math.max(maxX, _points[i]);
      minY = math.min(minY, _points[i + 1]);
      maxY = math.max(maxY, _points[i + 1]);
    }
    // The ink's page extent, padded for the stroke's width, on whole pixels.
    final pad = size / 2 + 2;
    final ink = Rect.fromLTRB(
      (minX - pad).floorToDouble(),
      (minY - pad).floorToDouble(),
      (maxX + pad).ceilToDouble(),
      (maxY + pad).ceilToDouble(),
    );

    _Drawing? into;
    if (target != null) {
      for (final d in _drawings(module, c)) {
        if (d.$1.id == target) into = d;
      }
    }

    Stroke strokeIn(Offset Function(Offset) toContent) {
      final pts = Float64List.fromList(_points);
      for (var i = 0; i < pts.length; i += 4) {
        final p = toContent(Offset(pts[i], pts[i + 1]));
        pts[i] = p.dx;
        pts[i + 1] = p.dy;
      }
      return Stroke(
        id: newId(),
        points: pts,
        color: color,
        size: size,
        hasPressure: hasPressure,
        t0: startedAt,
      );
    }

    const codec = DrawingCodec();
    if (into == null) {
      final stroke = strokeIn((p) => p - ink.topLeft);
      // Stamped with the device and time like any other content write.
      final at = c.deviceName == null ? null : DateTime.now().millisecondsSinceEpoch;
      final box = commitBox(
        createBox(codec, ink.bounds),
        codec,
        DrawingData(strokes: [stroke]),
        device: c.deviceName,
        at: at,
      );
      c.insertBox(box);
      return;
    }

    final (box, data, frame) = into;
    final stroke = strokeIn(frame.toContent);
    // Grow the box to fit the stroke. Growing left or up moves the box's
    // corner; shifting the origin by the same amount keeps every stroke
    // where it was on the page.
    final old = box.bounds.rect;
    final grown = old.expandToInclude(ink);
    final dx = old.left - grown.left;
    final dy = old.top - grown.top;
    final moved = dx != 0 || dy != 0;
    c.editBox(
      box.id,
      data.copyWith(
        originX: data.originX + dx,
        originY: data.originY + dy,
        strokes: [...data.strokes, stroke],
      ),
      bounds: grown == old ? null : grown.bounds,
      undo: StrokeEdit(
        remove: {stroke.id},
        origin: moved ? (data.originX, data.originY) : null,
      ),
    );
  }
}

/// The stroke eraser: removes whole strokes it touches. One drag is one
/// undo step. A drawing box left without strokes is deleted.
class EraserTool extends CanvasTool {
  EraserTool(this.module);

  final DrawingModule module;

  @override
  String get id => 'noted.drawing.eraser';
  @override
  String get label => 'Eraser';
  @override
  IconData get icon => Icons.layers_clear;
  @override
  LogicalKeyboardKey? get shortcut => LogicalKeyboardKey.keyE;

  @override
  ToolSession? start(ToolContext context, ToolPointer pointer) =>
      _EraserSession(module, context, pointer.position);
}

class _EraserSession extends ToolSession {
  _EraserSession(this.module, this.context, Offset start) : _at = start {
    _erase(start, start);
  }

  final DrawingModule module;
  final ToolContext context;
  Offset _at;

  /// Strokes erased in this drag, by box, for one undo step at the end.
  final Map<String, List<Stroke>> _erased = {};

  /// Each touched box as it was before this drag.
  final Map<String, BoxRecord> _before = {};

  @override
  void update(ToolPointer pointer) {
    final from = _at;
    _at = pointer.position;
    _erase(from, _at);
    context.repaintOverlay();
  }

  /// Erases every stroke within reach of the segment [a]–[b], so a fast
  /// drag doesn't skip strokes between two samples.
  void _erase(Offset a, Offset b) {
    final c = context.controller;
    final r = eraserRadius / context.scale;
    final reach = Rect.fromPoints(a, b).inflate(r);
    for (final (box, data, frame) in _drawings(module, c).toList()) {
      if (!box.bounds.rect.inflate(r).overlaps(reach)) continue;
      final ca = frame.toContent(a);
      final cb = frame.toContent(b);
      final hits = [
        for (final s in data.strokes)
          if (_touches(s, ca, cb, r)) s,
      ];
      if (hits.isEmpty) continue;
      final ids = {for (final s in hits) s.id};
      _before.putIfAbsent(box.id, () => box);
      c.editBox(
        box.id,
        data.copyWith(
          strokes: [
            for (final s in data.strokes)
              if (!ids.contains(s.id)) s,
          ],
          erased: {...data.erased, ...ids},
        ),
      );
      (_erased[box.id] ??= []).addAll(hits);
    }
  }

  @override
  void end() {
    final c = context.controller;
    for (final MapEntry(key: id, value: strokes) in _erased.entries) {
      final box = c.page.node(id);
      if (box is! BoxRecord) continue;
      final r = c.modules.codecs.resolve(box);
      if (r is LiveBox && r.codec.isEmpty(r.data)) {
        // Emptied: delete it, and let one undo bring it back with its ink.
        c.delete(id, undoTo: _before[id]);
      } else {
        c.recordChange(PageChange.content(id, StrokeEdit(add: strokes)));
      }
    }
  }

  @override
  void cancel() => end();

  @override
  void paint(Canvas canvas, double scale) {
    canvas.drawCircle(
      _at,
      eraserRadius / scale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale
        ..color = context.colors.toolRing,
    );
  }
}

/// Whether [s] passes within [r] (plus half its width) of segment [a]–[b].
bool _touches(Stroke s, Offset a, Offset b, double r) {
  final reach = r + s.size / 2;
  final (l, t, rr, bb) = s.extent;
  final box = Rect.fromLTRB(l, t, rr, bb).inflate(reach);
  if (!box.overlaps(Rect.fromPoints(a, b).inflate(0.001))) return false;
  if (s.length == 1) {
    return _pointSegment(Offset(s.x(0), s.y(0)), a, b) <= reach;
  }
  for (var i = 1; i < s.length; i++) {
    final p = Offset(s.x(i - 1), s.y(i - 1));
    final q = Offset(s.x(i), s.y(i));
    if (_segmentSegment(p, q, a, b) <= reach) return true;
  }
  return false;
}

double _pointSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.distanceSquared;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

double _segmentSegment(Offset p, Offset q, Offset a, Offset b) {
  double cross(Offset o, Offset u, Offset v) =>
      (u.dx - o.dx) * (v.dy - o.dy) - (u.dy - o.dy) * (v.dx - o.dx);
  final d1 = cross(a, b, p), d2 = cross(a, b, q);
  final d3 = cross(p, q, a), d4 = cross(p, q, b);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return 0;
  }
  return [
    _pointSegment(p, a, b),
    _pointSegment(q, a, b),
    _pointSegment(a, p, q),
    _pointSegment(b, p, q),
  ].reduce(math.min);
}

class _PenOptions extends StatelessWidget {
  const _PenOptions(this.settings);

  final PenSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in PenSettings.colors)
          IconButton(
            tooltip: 'Color',
            isSelected: settings.color == c,
            onPressed: () => settings.color = c,
            icon: Icon(
              settings.color == c ? Icons.radio_button_checked : Icons.circle,
              color: displayInkColor(c, Theme.of(context).brightness),
              size: 20,
            ),
          ),
        for (final s in PenSettings.sizes)
          IconButton(
            tooltip: 'Width ${s.toInt()}',
            isSelected: settings.size == s,
            onPressed: () => settings.size = s,
            icon: Container(
              width: 18,
              height: s + 1,
              decoration: BoxDecoration(
                color: settings.size == s
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                borderRadius: BorderRadius.circular(s),
              ),
            ),
          ),
      ],
    ),
  );
}
