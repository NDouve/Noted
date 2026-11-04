// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Counts how often each drawing box paints its ink (see 0091, 0095): a new
// stroke must repaint the box it lands in and no other box.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

extension on CanvasView {
  Offset screen(Offset world) =>
      toScreen(world) + const Offset(0, CommandToolbar.height);
}

void main() {
  late DrawingModule module;
  late CanvasController c;
  late CanvasToolSelection tools;

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    module = DrawingModule();
    final modules = ModuleRegistry()..register(module);
    c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)),
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

  List<BoxRecord> boxes() => c.page.nodes.whereType<BoxRecord>().toList();

  Future<void> draw(WidgetTester t, List<Offset> page) async {
    final view = t.state<PageCanvasState>(find.byType(PageCanvas)).view!;
    final g = await t.startGesture(
      view.screen(page.first),
      kind: PointerDeviceKind.mouse,
    );
    for (final p in page.skip(1)) {
      await g.moveTo(view.screen(p));
    }
    await g.up();
    await t.pump();
  }

  List<Offset> zigzag(Offset start, int n) => [
    for (var i = 0; i < n; i++)
      start + Offset(i * 7, (i.isEven ? 0 : 20) + math.sin(i / 9) * 10),
  ];

  /// The render object that paints each box's ink, by box id.
  Map<String, RenderObject> inkPainters(WidgetTester t) => {
    for (final b in boxes())
      b.id: t.renderObject(
        find
            .descendant(
              of: find.byKey(ValueKey(b.id)),
              matching: find.byWidgetPredicate(
                (w) => w is CustomPaint && w.painter is StrokesPainter,
              ),
            )
            .first,
      ),
  };

  testWidgets('a new stroke repaints only its own box', (t) async {
    await pump(t);
    // Three drawing boxes, far enough apart not to join.
    for (final x in [60.0, 400.0, 740.0]) {
      await draw(t, zigzag(Offset(x, 100), 20));
    }
    expect(boxes(), hasLength(3));
    final painters = inkPainters(t);
    final ids = painters.keys.toList();
    final counts = <RenderObject, int>{};
    // The binding requires render debug variables to be unset when the test
    // ends, so the hook is removed in the body and the checks come after.
    debugOnProfilePaint = (o) => counts[o] = (counts[o] ?? 0) + 1;
    Map<String, int> paints() => {
      for (final e in painters.entries) e.key: counts[e.value] ?? 0,
    };

    // A stroke that joins the middle box.
    final r = boxes().firstWhere((b) => b.id == ids[1]).bounds.rect;
    final joinBefore = paints();
    await draw(t, [
      r.center,
      r.center + const Offset(30, 15),
      r.center + const Offset(60, -5),
    ]);
    final boxCount = boxes().length;
    final joinAfter = paints();

    // A stroke far from every box starts a new box.
    await draw(t, zigzag(const Offset(400, 500), 20));
    final newBoxCount = boxes().length;
    final newAfter = paints();
    debugOnProfilePaint = null;

    expect(boxCount, 3, reason: 'the stroke joined a box');
    expect(
      joinAfter[ids[1]]! - joinBefore[ids[1]]!,
      greaterThan(0),
      reason: 'the counter sees the box paint',
    );
    expect(joinAfter[ids[0]], joinBefore[ids[0]], reason: 'first box');
    expect(joinAfter[ids[2]], joinBefore[ids[2]], reason: 'last box');
    expect(newBoxCount, 4);
    for (final id in ids) {
      expect(newAfter[id], joinAfter[id], reason: 'box $id, new box drawn');
    }
  });
}
