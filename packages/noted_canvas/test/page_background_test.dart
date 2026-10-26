// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const Size viewport = Size(400, 300);
const double pitch = 20;

BackgroundPrimitives prims(
  PageBackground b,
  CanvasView v, {
  Size size = viewport,
  double dpr = 1,
}) => backgroundPrimitives(
  background: b,
  view: v,
  size: size,
  pitch: pitch,
  devicePixelRatio: dpr,
);

void main() {
  group('backgroundPrimitives', () {
    test('plain draws nothing', () {
      final p = prims(PageBackground.plain, CanvasView.identity);
      expect(p.dots, isEmpty);
      expect(p.verticalLines, isEmpty);
      expect(p.horizontalLines, isEmpty);
      expect(p.marginLine, isNull);
    });

    test('dots sit on the pitch from the page origin', () {
      final p = prims(PageBackground.dots, CanvasView.identity);
      expect(p.dots, contains(const Offset(0, 0)));
      expect(p.dots, contains(const Offset(40, 60)));
      expect(p.dots.every((o) => o.dx % 20 == 0 && o.dy % 20 == 0), isTrue);
      expect(p.dots.length, greaterThanOrEqualTo(20 * 15));
      expect(p.verticalLines, isEmpty);
    });

    test('graph has vertical and horizontal lines at the pitch', () {
      final p = prims(PageBackground.graph, CanvasView.identity);
      expect(p.verticalLines.take(3), [0, 20, 40]);
      expect(p.horizontalLines.take(3), [0, 20, 40]);
      expect(p.marginLine, isNull);
      expect(p.dots, isEmpty);
    });

    test('ruled has horizontal rules and a margin 64 from the page origin', () {
      final p = prims(PageBackground.ruled, CanvasView.identity);
      expect(p.horizontalLines.take(3), [0, 20, 40]);
      expect(p.verticalLines, isEmpty);
      expect(p.marginLine, 64);
      // The margin pans and scales with the page.
      expect(prims(PageBackground.ruled, const CanvasView(1, Offset(-30, 0))).marginLine, 34);
      expect(prims(PageBackground.ruled, const CanvasView(2, Offset(10, 0))).marginLine, 138);
      expect(prims(PageBackground.ruled, const CanvasView(1, Offset(-100, 0))).marginLine, isNull);
    });

    test('the pattern is anchored to the page origin while panning', () {
      for (final dx in [0.0, 7.0, -33.0, 125.0]) {
        final v = CanvasView(1, Offset(dx, 0));
        final p = prims(PageBackground.graph, v);
        for (final x in p.verticalLines) {
          // Back in page coordinates every line is a multiple of the pitch.
          expect((v.toWorld(Offset(x, 0)).dx / pitch) % 1, 0);
        }
        expect(p.verticalLines.first, lessThanOrEqualTo(0));
        expect(p.verticalLines.last, greaterThanOrEqualTo(viewport.width - pitch));
      }
    });

    test('the pitch scales with the zoom', () {
      final p = prims(PageBackground.graph, const CanvasView(2, Offset.zero));
      expect(p.verticalLines.take(3), [0, 40, 80]);
      final q = prims(PageBackground.graph, const CanvasView(0.5, Offset.zero));
      // 10px on screen is above the 8px floor: nothing is thinned.
      expect(q.verticalLines.take(3), [0, 10, 20]);
      expect(q.step, pitch);
    });

    test('lines snap to device pixels', () {
      final p = prims(
        PageBackground.graph,
        const CanvasView(1, Offset(0.3, 0.7)),
        dpr: 2,
      );
      for (final v in [...p.verticalLines, ...p.horizontalLines]) {
        expect((v * 2) % 1, 0);
      }
    });

    test('at tiny zoom the pattern is thinned and never exceeds the cap', () {
      const big = Size(3840, 2160);
      for (final b in [PageBackground.dots, PageBackground.graph, PageBackground.ruled]) {
        for (final scale in [1.0, 0.5, 0.3, 0.1, 0.01]) {
          final p = prims(b, CanvasView(scale, Offset.zero), size: big);
          final n = p.dots.length + p.verticalLines.length + p.horizontalLines.length;
          expect(n, lessThanOrEqualTo(maxBackgroundPrimitives), reason: '$b at $scale');
          if (p.step > 0) {
            final floor = b == PageBackground.dots ? minDotSpacing : minLineSpacing;
            expect(p.step * scale, greaterThanOrEqualTo(floor));
          }
        }
      }
      // Thinning keeps a subset of the full pattern (doubling the step).
      final thin = prims(PageBackground.graph, const CanvasView(0.1, Offset.zero));
      expect(thin.step, 80);
      expect(thin.verticalLines.take(3), [0, 8, 16]);
    });

    test('a 1920x1080 view at 100% draws only a few thousand dots', () {
      final p = prims(
        PageBackground.dots,
        CanvasView.identity,
        size: const Size(1920, 1080),
      );
      expect(p.dots.length, lessThan(6000));
    });
  });

  group('on the canvas', () {
    late CanvasController c;

    Future<void> pump(
      WidgetTester t, {
      PageBackground background = PageBackground.plain,
      bool readOnly = false,
    }) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var meta = PageMeta.create(id: 'p', title: '', order: 0);
      meta = meta.withBackground(background);
      c = CanvasController(
        NotedPage.create(meta),
        ModuleRegistry(),
        readOnly: readOnly,
      );
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PageCanvas(controller: c, readOnly: readOnly)),
        ),
      );
    }

    PageBackgroundPainter painter(WidgetTester t) {
      final p = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<PageBackgroundPainter>()
          .single;
      return p;
    }

    testWidgets('draws the page background in the paper tokens', (t) async {
      await pump(t, background: PageBackground.ruled);
      final p = painter(t);
      final colors = NotedColors.of(t.element(find.byType(PageCanvas)));
      expect(p.background, PageBackground.ruled);
      expect(p.pitch, DesignMetrics.paperPitch);
      expect(p.lineColor, colors.paperLine);
      expect(p.dotColor, colors.paperDot);
      expect(p.marginColor, colors.paperMargin);
      expect(p.view.scale, 1);
    });

    testWidgets('the toolbar dropdown shows the current one and changes it', (t) async {
      await pump(t);
      await t.tap(find.byTooltip('Page background'));
      await t.pumpAndSettle();
      expect(find.text('Page background: Dots'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await t.tap(find.text('Page background: Dots'));
      await t.pumpAndSettle();
      expect(c.page.meta.background, PageBackground.dots);
      expect(painter(t).background, PageBackground.dots);
      // The dropdown's button shows the new background's icon.
      expect(
        find.descendant(
          of: find.byType(CommandToolbar),
          matching: find.byIcon(pageBackgroundIcon(PageBackground.dots)),
        ),
        findsOneWidget,
      );

      await t.tap(find.byTooltip('Page background'));
      await t.pumpAndSettle();
      final checked = find.ancestor(
        of: find.byIcon(Icons.check_rounded),
        matching: find.byType(NotedMenuItem<String>),
      );
      expect(
        find.descendant(of: checked, matching: find.text('Page background: Dots')),
        findsOneWidget,
      );
      await t.tap(find.text('Page background: Ruled'));
      await t.pumpAndSettle();
      expect(painter(t).background, PageBackground.ruled);
    });

    testWidgets('Ctrl+Z restores the previous background in one press', (t) async {
      await pump(t, background: PageBackground.graph);
      final registry = t.state<PageCanvasState>(find.byType(PageCanvas)).commands;
      await registry.invoke(CanvasCommands.pageBackgroundOf(PageBackground.dots));
      await t.pump();
      expect(c.page.meta.background, PageBackground.dots);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(c.page.meta.background, PageBackground.graph);
      expect(c.canUndo, isFalse);
      expect(painter(t).background, PageBackground.graph);
    });

    testWidgets('the commands are checked as the page is and saved through onChanged', (t) async {
      await pump(t);
      final registry = t.state<PageCanvasState>(find.byType(PageCanvas)).commands;
      expect(registry[CanvasCommands.pageBackgroundOf(PageBackground.plain)]!.checked, isTrue);
      NotedPage? saved;
      final c2 = CanvasController(c.page, ModuleRegistry(), onChanged: (p) => saved = p);
      addTearDown(c2.dispose);
      c2.setBackground(PageBackground.graph);
      expect(saved!.meta.background, PageBackground.graph);
      c2.setBackground(PageBackground.graph);
      expect(c2.canUndo, isTrue);
    });

    testWidgets('a read-only page shows the background but cannot change it', (t) async {
      await pump(t, background: PageBackground.dots, readOnly: true);
      expect(painter(t).background, PageBackground.dots);
      final registry = t.state<PageCanvasState>(find.byType(PageCanvas)).commands;
      for (final b in PageBackground.values) {
        expect(registry[CanvasCommands.pageBackgroundOf(b)]!.enabled, isFalse);
      }
      expect(registry[CanvasCommands.pageBackground]!.enabled, isFalse);
      expect(find.byTooltip('Page background'), findsNothing);
      c.setBackground(PageBackground.ruled);
      expect(c.page.meta.background, PageBackground.dots);
    });
  });
}
