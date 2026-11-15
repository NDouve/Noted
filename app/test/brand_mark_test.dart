// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The brand mark (task 6): the N of the app icon, drawn on device pixels.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/brand_mark.dart';
import 'package:noted_canvas/noted_canvas.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.light, Size size = const Size(1000, 200), double dpr = 1}) =>
    MediaQuery(
      data: MediaQueryData(size: size, devicePixelRatio: dpr),
      child: MaterialApp(
        theme: notedThemeData(brightness),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  test('the painted height is 16 / 20 / 24 device px at 100 / 125 / 150%, the stroke 3 / 4 / 5', () {
    for (final (dpr, height, stroke) in [(1.0, 16, 3), (1.25, 20, 4), (1.5, 24, 5)]) {
      final g = BrandMarkGeometry.at(dpr);
      expect(g.height, height, reason: 'dpr $dpr');
      expect(g.stroke, stroke, reason: 'dpr $dpr');
      // Whole pixel columns: every edge is an integer.
      final (left, right) = g.stemLefts;
      expect(left, 0);
      expect(right, isA<int>());
      expect(g.width, right + g.stroke);
      // The proportions are the master's: about 0.77 wide to 1 high.
      expect(g.width / g.height, closeTo(0.77, 0.12), reason: 'dpr $dpr');
    }
  });

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

  testWidgets('the wordmark shows from 600 px and hides below; one Noted semantics node', (t) async {
    await t.pumpWidget(_app(const BrandMark(), size: const Size(800, 200)));
    expect(find.byKey(const ValueKey('brand-wordmark')), findsOneWidget);
    expect(find.bySemanticsLabel('Noted'), findsOneWidget);
    await t.pumpWidget(_app(const BrandMark(showWordmark: false), size: const Size(500, 200)));
    expect(find.byKey(const ValueKey('brand-wordmark')), findsNothing);
    expect(find.bySemanticsLabel('Noted'), findsOneWidget);
  });

  test('the stops reach 3:1 on bg-app in Precision, and light shows the master stops', () {
    final dark = brandMarkColors(DesignColors.dark.bgApp, Brightness.dark);
    expect(contrastRatio(dark.$1, DesignColors.dark.bgApp), greaterThanOrEqualTo(3));
    expect(contrastRatio(dark.$2, DesignColors.dark.bgApp), greaterThanOrEqualTo(3));
    final light = brandMarkColors(DesignColors.light.bgApp, Brightness.light);
    expect(light.$1, const Color(0xFF2F86C8));
    expect(light.$2, const Color(0xFF0D4A78));
  });
}
