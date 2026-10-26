// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// The toolbar sits above the canvas, so screen y is the canvas's plus its height.
extension on CanvasView {
  Offset screen(Offset world) =>
      toScreen(world) + const Offset(0, CommandToolbar.height);
}

void main() {
  late DrawingModule module;
  late CanvasController c;
  late CanvasToolSelection tools;

  Future<void> pump(WidgetTester t, {NotedPage? page}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    module = DrawingModule();
    final modules = ModuleRegistry()..register(module);
    c = CanvasController(
      page ?? NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)),
      modules,
    );
    tools = CanvasToolSelection();
    addTearDown(tools.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(controller: c, tools: tools),
        ),
      ),
    );
    tools.select(module.pen);
    await t.pump();
  }

  PageCanvasState canvas(WidgetTester t) =>
      t.state<PageCanvasState>(find.byType(PageCanvas));

  List<BoxRecord> boxes() => c.page.nodes.whereType<BoxRecord>().toList();

  DrawingData dataOf(BoxRecord b) =>
      (c.modules.codecs.resolve(b) as LiveBox).data! as DrawingData;

  /// Every stored point of [s] in [b], converted back to page coordinates.
  List<Offset> pagePoints(BoxRecord b, Stroke s) {
    final frame = DrawingFrame(
      b.bounds.rect,
      dataOf(b),
      module.scrollOf(b.id).value,
    );
    return [
      for (var i = 0; i < s.length; i++) frame.toPage(Offset(s.x(i), s.y(i))),
    ];
  }

  /// Draws through [page] points (page coordinates) with the mouse. Returns
  /// the gesture, still pressed when [release] is false.
  Future<TestGesture> draw(
    WidgetTester t,
    List<Offset> page, {
    bool release = true,
  }) async {
    final view = canvas(t).view!;
    final g = await t.startGesture(
      view.screen(page.first),
      kind: PointerDeviceKind.mouse,
    );
    for (final p in page.skip(1)) {
      await g.moveTo(view.screen(p));
    }
    if (release) await g.up();
    return g;
  }

  void expectSamePoints(List<Offset> actual, List<Offset> expected) {
    expect(actual, hasLength(expected.length));
    for (var i = 0; i < expected.length; i++) {
      // Stored to 0.1 page px.
      expect(
        (actual[i] - expected[i]).distance,
        lessThan(0.08),
        reason: 'point $i',
      );
    }
  }

  /// A fast, long, zig-zag stroke: big jumps between samples.
  List<Offset> zigzag(
    Offset start,
    int n, {
    double step = 7,
    double amp = 120,
  }) => [
    for (var i = 0; i < n; i++)
      start + Offset(i * step, (i.isEven ? 0 : amp) + math.sin(i / 9) * 30),
  ];

  testWidgets(
    'a fast long stroke keeps every input point and fits its new box',
    (t) async {
      await pump(t);
      final input = zigzag(const Offset(40, 60), 500);
      await draw(t, input);
      await t.pump();

      final b = boxes().single;
      expect(b.typeId, DrawingCodec.id);
      final s = dataOf(b).strokes.single;
      expectSamePoints(pagePoints(b, s), input);
      final rect = b.bounds.rect;
      for (final p in input) {
        expect(rect.contains(p), isTrue, reason: '$p outside $rect');
      }
    },
  );

  testWidgets('the stroke is committed on pointer up, before the next frame', (
    t,
  ) async {
    await pump(t);
    final g = await draw(t, zigzag(const Offset(100, 100), 50), release: false);
    expect(canvas(t).toolSession, isNotNull);
    expect(boxes(), isEmpty);
    // Releasing dispatches the event without pumping a frame.
    await g.up();
    expect(
      canvas(t).toolSession,
      isNull,
      reason: 'overlay clears in the same frame…',
    );
    expect(
      dataOf(boxes().single).strokes,
      hasLength(1),
      reason: '…that the box gets the stroke',
    );
  });

  testWidgets('a stroke near a box joins it and grows it in every direction', (
    t,
  ) async {
    await pump(t);
    final first = zigzag(const Offset(200, 200), 40, amp: 50);
    await draw(t, first);
    final b0 = boxes().single;
    final firstStroke = dataOf(b0).strokes.single;
    final firstOnPage = pagePoints(b0, firstStroke);

    // Starts within the join distance of the top-left corner and runs
    // up-left, then far down-right: the box must grow on all four sides.
    final r0 = b0.bounds.rect;
    final second = [
      r0.topLeft - const Offset(joinDistance / 2, joinDistance / 2),
      r0.topLeft - const Offset(80, 90),
      r0.bottomRight + const Offset(150, 160),
    ];
    await draw(t, second);
    await t.pump();

    expect(boxes(), hasLength(1));
    final b1 = boxes().single;
    final r1 = b1.bounds.rect;
    expect(r1.left, lessThan(r0.left));
    expect(r1.top, lessThan(r0.top));
    expect(r1.right, greaterThan(r0.right));
    expect(r1.bottom, greaterThan(r0.bottom));
    final data = dataOf(b1);
    expect(data.strokes, hasLength(2));
    // The first stroke didn't move on the page.
    expectSamePoints(
      pagePoints(b1, data.strokes.firstWhere((s) => s.id == firstStroke.id)),
      firstOnPage,
    );
    expectSamePoints(
      pagePoints(b1, data.strokes.firstWhere((s) => s.id != firstStroke.id)),
      second,
    );
  });

  testWidgets('a stroke far from every box starts a new box', (t) async {
    await pump(t);
    await draw(t, zigzag(const Offset(100, 100), 20, amp: 20));
    await draw(t, zigzag(const Offset(700, 500), 20, amp: 20));
    expect(boxes(), hasLength(2));
  });

  testWidgets('a click makes a dot, not a note', (t) async {
    await pump(t);
    await draw(t, [const Offset(300, 300)]);
    expect(dataOf(boxes().single).strokes.single.length, 1);
  });

  testWidgets('undo and redo strokes, including the growth they caused', (
    t,
  ) async {
    await pump(t);
    await draw(t, zigzag(const Offset(200, 200), 30, amp: 40));
    final r0 = boxes().single.bounds;
    await draw(t, [
      r0.rect.bottomRight - const Offset(5, 5),
      r0.rect.bottomRight + const Offset(200, 200),
    ]);
    final id = boxes().single.id;
    final second = dataOf(boxes().single).strokes.last.id;

    c.undo();
    expect(boxes().single.bounds, r0);
    expect(dataOf(boxes().single).strokes, hasLength(1));
    expect(dataOf(boxes().single).erased, contains(second));

    c.redo();
    expect(dataOf(boxes().single).strokes.map((s) => s.id), contains(second));
    expect(dataOf(boxes().single).erased, isNot(contains(second)));

    c.undo();
    c.undo();
    expect(
      c.page.node(id),
      isNull,
      reason: 'undoing the first stroke removes its box',
    );
  });

  testWidgets('the eraser removes the strokes it crosses, in one undo step', (
    t,
  ) async {
    await pump(t);
    for (final y in [200.0, 220.0, 240.0]) {
      await draw(t, [Offset(100, y), Offset(400, y)]);
    }
    expect(boxes(), hasLength(1));
    tools.select(module.eraser);
    await t.pump();
    // A fast vertical swipe crossing the first two lines between samples.
    // Ends at 225: the eraser (10 px) plus half the line width reaches 237,
    // short of the third line at 240.
    await draw(t, [const Offset(250, 180), const Offset(250, 225)]);
    expect(dataOf(boxes().single).strokes, hasLength(1));
    expect(dataOf(boxes().single).erased, hasLength(2));

    c.undo();
    expect(dataOf(boxes().single).strokes, hasLength(3));

    // Erasing everything deletes the box; one undo brings it back whole.
    await draw(t, [const Offset(250, 180), const Offset(250, 260)]);
    expect(boxes(), isEmpty);
    c.undo();
    expect(dataOf(boxes().single).strokes, hasLength(3));
  });

  for (final zoom in [0.3, 3.0]) {
    testWidgets('drawing at ${zoom}x stores the right page positions', (
      t,
    ) async {
      await pump(t);
      canvas(t).zoomTo(zoom);
      await t.pump();
      final centre = canvas(t).view!.toWorld(const Offset(600, 400));
      final input = zigzag(centre, 60, step: 2 / zoom, amp: 30 / zoom);
      await draw(t, input);
      final b = boxes().single;
      expectSamePoints(pagePoints(b, dataOf(b).strokes.single), input);
      // The pen's width is in page pixels, whatever the zoom.
      expect(dataOf(b).strokes.single.size, module.settings.size);
    });
  }

  testWidgets(
    'a cropped, scrolled box still grows to fit a stroke past its edge',
    (t) async {
      await pump(t);
      // Tall enough that the resize handles don't cover the ink.
      final first = zigzag(const Offset(100, 200), 70, amp: 80);
      await draw(t, first);
      final id = boxes().single.id;
      // Crop it to its left part, then scroll its content sideways. With a
      // tool active boxes ignore all pointers, the wheel included, so
      // scrolling a box is done with the select tool.
      final r = boxes().single.bounds;
      c.requestBounds(id, Bounds(r.x, r.y, 150, r.height));
      tools.select(null);
      await t.pump();
      final view = canvas(t).view!;
      final pointer = TestPointer(9, PointerDeviceKind.mouse)
        ..hover(view.screen(Offset(r.x + 50, r.y + r.height / 2)));
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(
        module.scrollOf(id).value.dx,
        greaterThan(0),
        reason: 'the cropped ink scrolls',
      );
      tools.select(module.pen);
      await t.pump();

      final cropped = boxes().single.bounds.rect;
      final second = [
        cropped.centerLeft + const Offset(10, 0),
        cropped.centerRight + const Offset(300, 40),
      ];
      await draw(t, second);
      final b = boxes().single;
      expect(b.bounds.rect.right, greaterThanOrEqualTo(second.last.dx));
      final s = dataOf(b).strokes.last;
      expectSamePoints(pagePoints(b, s), second);
    },
  );

  testWidgets('wheel and Ctrl+wheel still pan and zoom with the pen', (
    t,
  ) async {
    await pump(t);
    final v0 = canvas(t).view!;
    final pointer = TestPointer(3, PointerDeviceKind.mouse)
      ..hover(const Offset(600, 400));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(canvas(t).view!.scale, greaterThan(v0.scale));
    expect(boxes(), isEmpty);
  });

  testWidgets('debug builds show input points per second for the last stroke', (
    t,
  ) async {
    await pump(t);
    await draw(t, zigzag(const Offset(100, 100), 120));
    await t.pump();
    expect(find.textContaining('pts/s · 120 pts'), findsOneWidget);
  });

  testWidgets('a page with many long strokes builds and draws', (t) async {
    final rnd = math.Random(1);
    final strokes = [
      for (var i = 0; i < 200; i++)
        Stroke(
          id: 's$i',
          t0: i,
          points: Float64List.fromList([
            for (var j = 0; j < 200; j++) ...[
              rnd.nextDouble() * 1000,
              rnd.nextDouble() * 700,
              0.5,
              j * 8.0,
            ],
          ]),
        ),
    ];
    const codec = DrawingCodec();
    final box = commitBox(
      createBox(codec, const Bounds(0, 0, 1000, 700)),
      codec,
      DrawingData(strokes: strokes),
    );
    await pump(
      t,
      page: NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0))
          .insertNode(box),
    );
    final sw = Stopwatch()..start();
    await t.pump();
    sw.stop();
    expect(t.takeException(), isNull);
    // Not a benchmark (debug mode, test renderer); it guards against
    // something pathological, like rebuilding every outline per frame.
    debugPrint(
      '200 strokes x 200 points: first frame ${sw.elapsedMilliseconds} ms',
    );
    await draw(t, zigzag(const Offset(1060, 100), 10, amp: 10));
    expect(boxes(), hasLength(2));
  });

  /// A drawing box whose ink runs well past its right edge (cropped).
  Future<String> croppedBox(WidgetTester t) async {
    await draw(t, zigzag(const Offset(100, 200), 70, amp: 80));
    final id = boxes().single.id;
    final r = boxes().single.bounds;
    c.requestBounds(id, Bounds(r.x, r.y, 150, r.height));
    tools.select(null);
    await t.pump();
    return id;
  }

  testWidgets(
    'two-finger scroll reveals a cropped drawing; the canvas stays put',
    (t) async {
      await pump(t);
      final id = await croppedBox(t);
      final v0 = canvas(t).view!;
      final r = boxes().single.bounds;
      final g = await t.startGesture(
        v0.screen(Offset(r.x + 75, r.y + r.height / 2)),
        kind: PointerDeviceKind.trackpad,
      );
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(-12, 0)); // fingers left: reveal the right
        await t.pump();
      }
      await g.up();
      await t.pump();
      expect(module.scrollOf(id).value.dx, closeTo(120, 1e-6));
      expect(canvas(t).view!.offset, v0.offset);
    },
  );

  testWidgets('two-finger scroll over an uncropped drawing pans the canvas', (
    t,
  ) async {
    await pump(t);
    await draw(t, zigzag(const Offset(100, 200), 30, amp: 80));
    tools.select(null);
    await t.pump();
    final id = boxes().single.id;
    final v0 = canvas(t).view!;
    final r = boxes().single.bounds;
    final g = await t.startGesture(
      v0.screen(r.rect.center),
      kind: PointerDeviceKind.trackpad,
    );
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(0, -10));
      await t.pump();
    }
    await g.up();
    await t.pump();
    expect(module.scrollOf(id).value, Offset.zero);
    expect(canvas(t).view!.offset, isNot(v0.offset));
  });

  testWidgets('a pinch over a cropped drawing still zooms the canvas', (
    t,
  ) async {
    await pump(t);
    await croppedBox(t);
    final v0 = canvas(t).view!;
    final r = boxes().single.bounds;
    final at = v0.screen(Offset(r.x + 75, r.y + r.height / 2));
    await t.sendEventToBinding(
      PointerPanZoomStartEvent(pointer: 7, position: at),
    );
    await t.sendEventToBinding(
      PointerPanZoomUpdateEvent(pointer: 7, position: at, scale: 1.5),
    );
    await t.sendEventToBinding(
      PointerPanZoomEndEvent(pointer: 7, position: at),
    );
    await t.pump();
    expect(canvas(t).view!.scale, closeTo(v0.scale * 1.5, 1e-6));
  });

  testWidgets(
    'a stroke held at the edge auto-pans, keeps every point and fits its box',
    (t) async {
      await pump(t);
      final g = await t.startGesture(
        const Offset(600, 300),
        kind: PointerDeviceKind.mouse,
      );
      final screen = [
        for (var x = 620.0; x <= 1180; x += 20) Offset(x, 300 + (x % 60)),
      ];
      for (final p in screen) {
        await g.moveTo(p);
      }
      final v0 = canvas(t).view!;
      // Hold 20 px from the right edge for two seconds.
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(canvas(t).view!.offset.dx, lessThan(v0.offset.dx - 300));
      await g.up();
      await t.pump();

      final b = boxes().single;
      final s = dataOf(b).strokes.single;
      final points = pagePoints(b, s);
      // At least one point per input event plus the auto-pan samples.
      expect(points.length, greaterThan(screen.length + 1 + 30));
      // The stroke reaches into space that was beyond the original view, and
      // the box contains all of it.
      final xs = [for (final p in points) p.dx];
      expect(
        xs.reduce(math.max),
        greaterThan(v0.toWorld(const Offset(1200, 0)).dx + 300),
      );
      for (final p in points) {
        expect(
          b.bounds.rect.inflate(0.1).contains(p),
          isTrue,
          reason: '$p outside ${b.bounds}',
        );
      }
    },
  );
}
