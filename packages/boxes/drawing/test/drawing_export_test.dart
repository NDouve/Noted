// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The drawing box's export (Box API 0.18): a transparent PNG and an SVG of the
// box's rectangle.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';

Stroke line(String id, double x0, double y0, double x1, double y1, {int color = 0xFF000000, double size = 10}) {
  final pts = <double>[];
  for (var i = 0; i <= 10; i++) {
    final t = i / 10;
    pts.addAll([x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, 0.5, i * 16]);
  }
  return Stroke(id: id, color: color, size: size, points: Float64List.fromList(pts));
}

Future<(int, int, Uint8List)> decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  final r = (frame.image.width, frame.image.height, data!.buffer.asUint8List());
  frame.image.dispose();
  return r;
}

List<int> pixel((int, int, Uint8List) img, int x, int y) {
  final i = (y * img.$1 + x) * 4;
  return img.$3.sublist(i, i + 4);
}

void main() {
  final module = DrawingModule();

  test('lists png and svg', () {
    expect([for (final f in module.exportFormats(DrawingData())) f.id], ['png', 'svg']);
  });

  group('SVG', () {
    String svg(DrawingData d, {ui.Size size = const ui.Size(200, 100)}) => drawingToSvg(d, size);

    test('one filled path per stroke, in the box\'s size', () {
      final out = svg(DrawingData(strokes: [line('a', 10, 10, 90, 10), line('b', 10, 50, 90, 50)]));
      expect(out, contains('width="200" height="100" viewBox="0 0 200 100"'));
      expect('<path '.allMatches(out), hasLength(2));
      expect(out, startsWith('<?xml'));
    });

    test('a stored black is #000000 with no fill-opacity', () {
      final out = svg(DrawingData(strokes: [line('a', 10, 10, 90, 10, color: 0xFF000000)]));
      expect(out, contains('fill="#000000"'));
      expect(out, isNot(contains('fill-opacity')));
    });

    test('a half-transparent ink gives fill-opacity', () {
      final out = svg(DrawingData(strokes: [line('a', 10, 10, 90, 10, color: 0x80FF8000)]));
      expect(out, contains('fill="#FF8000"'));
      expect(out, contains('fill-opacity="0.502"'));
    });

    test('the default ink is black', () {
      final out = svg(DrawingData(strokes: [line('a', 10, 10, 90, 10, color: defaultInkValue)]));
      expect(out, contains('fill="#000000"'));
    });

    test('the origin applies, and the root\'s size clips what is outside', () {
      final out = svg(
        DrawingData(originX: 5, originY: -3, strokes: [line('a', 500, 500, 600, 500)]),
        size: const ui.Size(50, 40),
      );
      expect(out, contains('translate(5 -3)'));
      expect(out, contains('viewBox="0 0 50 40"'));
    });

    test('the path is the polygon strokeOutline fills', () {
      final s = line('a', 10, 10, 90, 40);
      final points = strokeOutlinePoints(s.points, size: s.size, hasPressure: false, complete: true);
      final out = svg(DrawingData(strokes: [s]));
      final d = RegExp(r' d="([^"]*)"').firstMatch(out)!.group(1)!;
      final numbers = RegExp(r'-?\d+(\.\d+)?').allMatches(d).map((m) => double.parse(m.group(0)!)).toList();
      expect(numbers.length, points.length * 2);
      for (var i = 0; i < points.length; i++) {
        expect(numbers[i * 2], closeTo(points[i].dx, 0.006));
        expect(numbers[i * 2 + 1], closeTo(points[i].dy, 0.006));
      }
      // strokeOutline builds its path from the same polygon.
      final path = strokeOutline(s.points, size: s.size, hasPressure: false, complete: true);
      final b = path.getBounds();
      final xs = points.map((p) => p.dx), ys = points.map((p) => p.dy);
      expect(b.left, closeTo(xs.reduce((a, b) => a < b ? a : b), 1e-3));
      expect(b.bottom, closeTo(ys.reduce((a, b) => a > b ? a : b), 1e-3));
    });

    test('the module exports it as UTF-8 under the SVG format', () async {
      final data = DrawingData(strokes: [line('a', 10, 10, 90, 10)]);
      final f = await module.export(data, ExportFormat.svg, const ExportContext(size: ui.Size(200, 100)));
      expect(f!.name, isEmpty);
      expect(utf8.decode(f.bytes), contains('<svg'));
    });
  });

  group('PNG', () {
    testWidgets('the box\'s rectangle at 2x, transparent, with light ink', (t) async {
      await t.runAsync(() async {
        final data = DrawingData(strokes: [line('a', 10, 50, 90, 50, size: 20, color: defaultInkValue)]);
        final f = await module.export(data, ExportFormat.png, const ExportContext(size: ui.Size(100, 100)));
        final img = await decode(f!.bytes);
        expect((img.$1, img.$2), (200, 200));
        // Transparent where there is no ink, the default ink in the light theme where there is.
        expect(pixel(img, 5, 5)[3], 0);
        final ink = pixel(img, 100, 100);
        expect(ink[3], 255);
        expect(ink[0], lessThan(80), reason: 'dark ink on paper, whatever the app theme');
      });
    });

    testWidgets('strokes outside the rectangle are clipped', (t) async {
      await t.runAsync(() async {
        final data = DrawingData(strokes: [line('a', 300, 300, 400, 300)]);
        final f = await module.export(data, ExportFormat.png, const ExportContext(size: ui.Size(100, 100)));
        final img = await decode(f!.bytes);
        expect(img.$3.where((b) => b != 0), isEmpty);
      });
    });

    testWidgets('the origin applies', (t) async {
      await t.runAsync(() async {
        final data = DrawingData(originX: 50, strokes: [line('a', 0, 50, 20, 50, size: 20)]);
        final f = await module.export(data, ExportFormat.png, const ExportContext(size: ui.Size(100, 100)));
        final img = await decode(f!.bytes);
        expect(pixel(img, 20, 100)[3], 0, reason: 'nothing at x = 10');
        expect(pixel(img, 120, 100)[3], 255, reason: 'the stroke is at x = 60');
      });
    });

    testWidgets('a wide box is scaled down to 4,096 px', (t) async {
      await t.runAsync(() async {
        final f = await module.export(DrawingData(), ExportFormat.png, const ExportContext(size: ui.Size(5000, 100)));
        final img = await decode(f!.bytes);
        expect(img.$1, 4096);
        expect(img.$2, lessThan(100));
      });
    });

    testWidgets('an empty rectangle gives nothing', (t) async {
      expect(await module.export(DrawingData(), ExportFormat.png, const ExportContext(size: ui.Size.zero)), isNull);
    });
  });
}
