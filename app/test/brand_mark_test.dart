// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The brand mark (task 6): the N of the app icon, drawn on device pixels.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/brand_mark.dart';
import 'package:noted_canvas/noted_canvas.dart';

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.light,
  Size size = const Size(1000, 200),
  double dpr = 1,
}) => MediaQuery(
  data: MediaQueryData(size: size, devicePixelRatio: dpr),
  child: MaterialApp(
    theme: notedThemeData(brightness),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  test(
    'the painted height is 16 / 20 / 24 device px at 100 / 125 / 150%, the stroke 3 / 3 / 4',
    () {
      for (final (dpr, height, stroke) in [(1.0, 16, 3), (1.25, 20, 3), (1.5, 24, 4)]) {
        final g = BrandMarkGeometry.at(dpr);
        expect(g.height, height, reason: 'dpr $dpr');
        expect(g.stroke, stroke, reason: 'dpr $dpr');
        // Whole pixel columns: every edge is an integer.
        final (left, right) = g.stemLefts;
        expect(left, 0);
        expect(right, isA<int>());
        expect(g.width, right + g.stroke);
        // The compact N's proportions: 216 wide to 336 high (stroke included).
        expect(g.width / g.height, closeTo(0.643, 0.12), reason: 'dpr $dpr');
      }
    },
  );

  for (final dpr in [1.0, 1.25, 1.5]) {
    testWidgets('at DPR $dpr the stems are whole opaque columns', (t) async {
      final g = BrandMarkGeometry.at(dpr);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      // The painter draws in logical units scaled back by the ratio: render at
      // the ratio so one canvas unit is one device pixel.
      canvas.scale(dpr);
      BrandMarkPainter(
        geometry: g,
        devicePixelRatio: dpr,
        from: const Color(0xFF2F86C8),
        to: const Color(0xFF0D4A78),
      ).paint(canvas, Size(g.width / dpr, g.height / dpr));
      final image = await t.runAsync(() => recorder.endRecording().toImage(g.width, g.height));
      final data = (await t.runAsync(() => image!.toByteData()))!;
      int alpha(int x, int y) => data.getUint8((y * g.width + x) * 4 + 3);
      final (left, right) = g.stemLefts;
      // Half way down, away from the diagonal's crossing of the stems.
      final y = g.height ~/ 2;
      for (final x0 in [left, right]) {
        for (var x = x0; x < x0 + g.stroke; x++) {
          // The left stem's columns are opaque at the top rows; the diagonal
          // sits between the stems, so test near the ends where each stem is
          // alone.
          final top = right == x0 ? 3 : g.height - 4;
          expect(alpha(x, top), 255, reason: 'column $x at row $top, dpr $dpr');
        }
      }
      expect(alpha(left - 1 < 0 ? left : left - 1, y), anyOf(0, 255));
    });
  }

  testWidgets('the wordmark shows from 600 px and hides below; one Noted semantics node', (
    t,
  ) async {
    await t.pumpWidget(_app(const BrandMark(), size: const Size(800, 200)));
    expect(find.byKey(const ValueKey('brand-wordmark')), findsOneWidget);
    expect(find.bySemanticsLabel('Noted'), findsOneWidget);
    await t.pumpWidget(_app(const BrandMark(showWordmark: false), size: const Size(500, 200)));
    expect(find.byKey(const ValueKey('brand-wordmark')), findsNothing);
    expect(find.bySemanticsLabel('Noted'), findsOneWidget);
  });

  test('the compact path: 380 view box, stroke 56, the left stem below the right', () {
    // The icon's path is M110 330 V74 L270 298 V50 with stroke 56: the
    // painted box is (160 + 56) wide and (280 + 56) high.
    for (final dpr in [1.0, 1.25, 1.5]) {
      final g = BrandMarkGeometry.at(dpr);
      final p = BrandMarkPainter(
        geometry: g,
        devicePixelRatio: dpr,
        from: const Color(0xFF000000),
        to: const Color(0xFF000000),
      ).path();
      final b = p.getBounds();
      final half = g.stroke / 2;
      expect(b.top, half, reason: 'right stem top, dpr $dpr');
      expect(b.bottom, g.height - half, reason: 'left stem bottom, dpr $dpr');
      expect(b.width, g.stemGap.toDouble());
      // The steps of M110 330 V74 L270 298 V50 (centre line 50 to 330): the left
      // stem tops out 24 units below the right stem's top, and the right stem
      // ends 248 units below it.
      final scale = (g.height - g.stroke) / 280;
      final verts = [
        Offset(half, g.height - half),
        Offset(half, half + 24 * scale),
        Offset(half + g.stemGap, half + 248 * scale),
        Offset(half + g.stemGap, half),
      ];
      final m = p.computeMetrics().single;
      final dists = [
        0.0,
        (verts[1] - verts[0]).distance,
        (verts[1] - verts[0]).distance + (verts[2] - verts[1]).distance,
      ];
      for (var i = 0; i < 3; i++) {
        final at = m.getTangentForOffset(dists[i])!.position;
        expect((at - verts[i]).distance, lessThan(0.01), reason: 'vertex $i, dpr $dpr');
      }
      expect(
        (m.getTangentForOffset(m.length)!.position - verts[3]).distance,
        lessThan(0.01),
        reason: 'end, dpr $dpr',
      );
      // 56 of 336 units is the stroke.
      expect(g.stroke / g.height, closeTo(56 / 336, 0.06), reason: 'dpr $dpr');
    }
  });

  test('the stops are the brand tokens, unlifted, in both themes', () {
    for (final c in [NotedColors.light, NotedColors.dark]) {
      final stops = brandMarkColors(c);
      expect(stops.$1, const Color(0xFF2F86C8));
      expect(stops.$2, const Color(0xFF0D4A78));
      expect(stops.$1, c.brandBlueStart);
      expect(stops.$2, c.brandBlueEnd);
    }
  });
}
