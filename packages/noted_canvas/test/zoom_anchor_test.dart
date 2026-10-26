// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// Zoom stays anchored to the pointer (wheel, pinch, keyboard).

BoxRecord _box(String id, double x, double y) => BoxRecord.create(
  id: id,
  typeId: 'vendor.alien',
  dataVersion: 1,
  bounds: Bounds(x, y, 300, 200),
  data: RawJson.parse('{"n": 1}'),
  snapshotText: id,
  rev: 'r',
);

const Offset bar = Offset(0, CommandToolbar.height);

void main() {
  late CanvasController c;
  late CanvasGeometry geometry;

  PageCanvasState state(WidgetTester t) =>
      t.state<PageCanvasState>(find.byType(PageCanvas));
  CanvasView view(WidgetTester t) => state(t).view!;

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    for (final (i, p) in [
      (0.0, 0.0),
      (1500.0, 0.0),
      (0.0, 1200.0),
      (1500.0, 1200.0),
    ].indexed) {
      page = page.insertNode(_box('b$i', p.$1, p.$2));
    }
    c = CanvasController(page, ModuleRegistry(), onChanged: (_) {});
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
    await t.pump();
    final size = t.getSize(find.byType(LayoutBuilder).last);
    geometry = CanvasGeometry.compute(
      content: c.page.contentBounds!.rect,
      viewport: size,
    );
  }

  /// One Ctrl+wheel step at canvas point [local]; checks the anchor.
  Future<void> wheelStep(
    WidgetTester t,
    TestPointer pointer,
    Offset local,
    double dy,
  ) async {
    final before = view(t);
    final world = before.toWorld(local);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    final after = view(t);
    _expectAnchored(world, local, after);
  }

  testWidgets('Ctrl+wheel keeps the point under the pointer: 10 in, 10 out', (
    t,
  ) async {
    await pump(t);
    final size = geometry.viewport;
    final spots = <Offset>[
      Offset(size.width / 2, size.height / 2),
      const Offset(3, 3),
      Offset(size.width - 3, 3),
      Offset(3, size.height - 3),
      Offset(size.width - 3, size.height - 3),
      const Offset(200, 150),
    ];
    for (final local in spots) {
      state(t).fitAll();
      await t.pump();
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await t.sendEventToBinding(pointer.hover(bar + local));
      for (var i = 0; i < 10; i++) {
        await wheelStep(t, pointer, local, -60);
      }
      for (var i = 0; i < 10; i++) {
        await wheelStep(t, pointer, local, 60);
      }
    }
  });

  testWidgets('anchor holds with an unclamped view, including a fast burst', (
    t,
  ) async {
    await pump(t);
    final local = const Offset(700, 300);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(pointer.hover(bar + local));
    final world = view(t).toWorld(local);
    // Several events before the next frame.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 8; i++) {
      await t.sendEventToBinding(pointer.scroll(const Offset(0, -80)));
    }
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    _expectAnchored(world, local, view(t));
  });

  testWidgets('at the zoom limits more input changes nothing', (t) async {
    await pump(t);
    final local = const Offset(900, 100);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(pointer.hover(bar + local));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 40; i++) {
      await t.sendEventToBinding(pointer.scroll(const Offset(0, -200)));
      await t.pump();
    }
    expect(view(t).scale, geometry.maxScale);
    final atMax = view(t);
    await t.sendEventToBinding(pointer.scroll(const Offset(0, -200)));
    await t.pump();
    expect(view(t), atMax);

    for (var i = 0; i < 80; i++) {
      await t.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
      await t.pump();
    }
    expect(view(t).scale, closeTo(geometry.minScale, 1e-9));
    final atMin = view(t);
    await t.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
    await t.pump();
    expect(view(t), atMin);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('the clamp moves only the axis that overshoots', (t) async {
    await pump(t);
    // Zoom in around the viewport centre, then out around the top-left
    // corner: the view is pushed against the left bound only if needed.
    state(t).zoomTo(2);
    await t.pump();
    const local = Offset(2, 400);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(pointer.hover(bar + local));
    final before = view(t);
    final world = before.toWorld(local);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendEventToBinding(pointer.scroll(const Offset(0, 90)));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    final after = view(t);
    final s = after.scale;
    final unclamped = local - world * s;
    // Vertical: anchored exactly unless out of range.
    final b = geometry.boundary;
    final loY = geometry.viewport.height - s * b.bottom;
    final hiY = -s * b.top;
    if (unclamped.dy >= loY && unclamped.dy <= hiY) {
      expect(after.offset.dy, closeTo(unclamped.dy, 1e-6));
    }
    final loX = geometry.viewport.width - s * b.right;
    final hiX = -s * b.left;
    expect(
      after.offset.dx,
      closeTo(unclamped.dx.clamp(loX, hiX).toDouble(), 1e-6),
    );
  });

  testWidgets('pinch keeps the focal point under the fingers', (t) async {
    await pump(t);
    const focal = Offset(600, 300);
    final pointer = TestPointer(2, PointerDeviceKind.trackpad);
    final world = view(t).toWorld(focal);
    await t.sendEventToBinding(pointer.panZoomStart(bar + focal));
    // Zoom in with a slight drift of the fingers, then back out.
    for (var i = 1; i <= 40; i++) {
      final scale = 1 + i * 0.05;
      final pan = Offset(i * 1.5, -i * 1.0);
      await t.sendEventToBinding(
        pointer.panZoomUpdate(bar + focal, pan: pan, scale: scale),
      );
      await t.pump();
      _expectAnchored(world, focal + pan, view(t));
    }
    for (var i = 40; i >= 0; i--) {
      final scale = 1 + i * 0.05;
      final pan = Offset(i * 1.5, -i * 1.0);
      await t.sendEventToBinding(
        pointer.panZoomUpdate(bar + focal, pan: pan, scale: scale),
      );
      await t.pump();
      _expectAnchored(world, focal + pan, view(t));
    }
    await t.sendEventToBinding(pointer.panZoomEnd());
    await t.pump();
    // Back at the start scale, exactly where it began.
    expect(view(t).scale, closeTo(1, 1e-9));
  });

  testWidgets('Ctrl+= and Ctrl+- zoom around the hovered point', (t) async {
    await pump(t);
    const local = Offset(800, 250);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: bar + local);
    await mouse.moveTo(bar + local + const Offset(1, 1));
    await mouse.moveTo(bar + local);
    await t.pump();
    final world = view(t).toWorld(local);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.equal);
    await t.pump();
    expect(view(t).scale, greaterThan(1));
    _expectAnchored(world, local, view(t));
    await t.sendKeyEvent(LogicalKeyboardKey.minus);
    await t.pump();
    _expectAnchored(world, local, view(t));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('without a hover, keys zoom around the centre; so does the '
      'readout; leaving the canvas forgets the hover', (t) async {
    await pump(t);
    final centre = geometry.viewport.center(Offset.zero);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: bar + const Offset(300, 200));
    await mouse.moveTo(bar + const Offset(310, 210));
    // Off the canvas, over the toolbar.
    await mouse.moveTo(const Offset(600, 5));
    await t.pump();
    var world = view(t).toWorld(centre);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.equal);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    _expectAnchored(world, centre, view(t));

    // The readout resets to 100% around the centre.
    world = view(t).toWorld(centre);
    await t.tap(find.text('${(view(t).scale * 100).round()}%'));
    await t.pump();
    await t.pump();
    expect(view(t).scale, closeTo(1, 1e-9));
    _expectAnchored(world, centre, view(t));
  });
}

/// The world point [world] is under [local] on screen (0.5 px).
void _expectAnchored(Offset world, Offset local, CanvasView after) {
  final onScreen = after.toScreen(world);
  expect(onScreen.dx, closeTo(local.dx, 0.5), reason: '$after');
  expect(onScreen.dy, closeTo(local.dy, 0.5), reason: '$after');
}
