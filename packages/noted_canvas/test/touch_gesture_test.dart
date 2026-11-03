// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// Touch input on the canvas (0033, 0129): two fingers pan and pinch-zoom,
/// one finger does what the tool does.

class _Codec extends BoxCodec<String> {
  const _Codec();
  @override
  String get typeId => 'test.text';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

class _Tool extends CanvasTool {
  final List<ToolPointer> samples = [];
  int started = 0;
  int ended = 0;
  int cancelled = 0;

  @override
  String get id => 'test.tool';
  @override
  String get label => 'Record';
  @override
  IconData get icon => Icons.edit;
  @override
  LogicalKeyboardKey? get shortcut => LogicalKeyboardKey.keyR;

  @override
  ToolSession? start(ToolContext context, ToolPointer pointer) {
    started++;
    samples.add(pointer);
    return _Session(this);
  }
}

class _Session extends ToolSession {
  _Session(this.tool);
  final _Tool tool;
  @override
  void update(ToolPointer pointer) => tool.samples.add(pointer);
  @override
  void end() => tool.ended++;
  @override
  void cancel() => tool.cancelled++;
  @override
  void paint(Canvas canvas, double scale) {}
}

class _Module extends BoxModule<String> {
  _Module(this.tool);
  final _Tool tool;
  @override
  BoxCodec<String> get codec => const _Codec();
  @override
  List<CanvasTool> get tools => [tool];
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
}

const Offset bar = Offset(0, CommandToolbar.height);

void main() {
  late _Tool tool;
  late CanvasController c;
  late CanvasToolSelection selection;

  PageCanvasState state(WidgetTester t) =>
      t.state<PageCanvasState>(find.byType(PageCanvas));
  CanvasView view(WidgetTester t) => state(t).view!;

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    tool = _Tool();
    final modules = ModuleRegistry()..register(_Module(tool), isDefault: true);
    var page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    for (final (i, p) in [(0.0, 0.0), (1500.0, 1200.0)].indexed) {
      page = page.insertNode(
        BoxRecord.create(
          id: 'b$i',
          typeId: 'test.text',
          dataVersion: 1,
          bounds: Bounds(p.$1, p.$2, 200, 100),
          data: RawJson.encode('box'),
          snapshotText: 'box',
          rev: 'r',
        ),
      );
    }
    c = CanvasController(page, modules);
    selection = CanvasToolSelection();
    addTearDown(selection.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(
            controller: c,
            tools: selection,
            toolbar: const ContextualToolbarLayout(
              leading: [],
              sections: [],
              trailing: [
                [CanvasCommands.select, 'test.tool'],
              ],
            ),
          ),
        ),
      ),
    );
    await t.pump();
    // Room to move in both directions.
    state(t).zoomTo(1);
    await t.pump();
  }

  Future<TestGesture> finger(WidgetTester t, int id, Offset local) =>
      t.startGesture(bar + local, pointer: id, kind: PointerDeviceKind.touch);

  testWidgets('two fingers apart zoom in around their centre', (t) async {
    await pump(t);
    final before = view(t);
    final world = before.toWorld(const Offset(600, 300));
    final a = await finger(t, 1, const Offset(500, 300));
    final b = await finger(t, 2, const Offset(700, 300));
    await a.moveTo(bar + const Offset(450, 300));
    await b.moveTo(bar + const Offset(750, 300));
    await t.pump();
    final after = view(t);
    expect(after.scale, closeTo(before.scale * 1.5, 1e-6));
    // The page point that was between the fingers still is.
    expect(after.toScreen(world).dx, closeTo(600, 1e-6));
    expect(after.toScreen(world).dy, closeTo(300, 1e-6));
    await a.up();
    await b.up();
  });

  testWidgets('two fingers moving together pan the page', (t) async {
    await pump(t);
    final before = view(t);
    final a = await finger(t, 1, const Offset(500, 300));
    final b = await finger(t, 2, const Offset(700, 300));
    await a.moveBy(const Offset(-80, -40));
    await b.moveBy(const Offset(-80, -40));
    await t.pump();
    final after = view(t);
    expect(after.scale, closeTo(before.scale, 1e-9));
    expect(after.offset.dx, closeTo(before.offset.dx - 80, 1e-6));
    expect(after.offset.dy, closeTo(before.offset.dy - 40, 1e-6));
    await a.up();
    await b.up();
  });

  testWidgets('pinching stays within the zoom limits', (t) async {
    await pump(t);
    final a = await finger(t, 1, const Offset(590, 300));
    final b = await finger(t, 2, const Offset(610, 300));
    await a.moveTo(bar + const Offset(10, 300));
    await b.moveTo(bar + const Offset(1190, 300));
    await t.pump();
    expect(view(t).scale, canvasMaxScale);
    await a.moveTo(bar + const Offset(600, 300));
    await b.moveTo(bar + const Offset(601, 300));
    await t.pump();
    expect(
      view(t).scale,
      closeTo(
        CanvasGeometry.compute(
          content: c.page.contentBounds!.rect,
          viewport: t.getSize(find.byType(LayoutBuilder).last),
        ).minScale,
        1e-9,
      ),
    );
    await a.up();
    await b.up();
  });

  testWidgets('panning with two fingers stays inside the page bounds', (
    t,
  ) async {
    await pump(t);
    final a = await finger(t, 1, const Offset(500, 300));
    final b = await finger(t, 2, const Offset(700, 300));
    final before = view(t);
    await a.moveBy(const Offset(5000, 5000));
    await b.moveBy(const Offset(5000, 5000));
    await t.pump();
    final g = CanvasGeometry.compute(
      content: c.page.contentBounds!.rect,
      viewport: t.getSize(find.byType(LayoutBuilder).last),
    );
    expect(view(t), isNot(before));
    expect(view(t), g.clamp(view(t)));
    await a.up();
    await b.up();
  });

  testWidgets('one finger does not pan; a tap makes a note, a two-finger '
      'tap does not', (t) async {
    await pump(t);
    final before = view(t);
    final one = await finger(t, 1, const Offset(400, 400));
    await one.moveBy(const Offset(120, 60));
    await one.up();
    await t.pump();
    expect(view(t), before);

    final nodes = c.page.nodes.length;
    final tap = await finger(t, 2, const Offset(900, 500));
    await tap.up();
    await t.pumpAndSettle();
    expect(c.page.nodes.length, nodes + 1);
    c.select(null);
    await t.pump();

    final n = c.page.nodes.length;
    final a = await finger(t, 3, const Offset(300, 600));
    final b = await finger(t, 4, const Offset(340, 600));
    await a.up();
    await b.up();
    await t.pumpAndSettle();
    expect(c.page.nodes.length, n);
  });

  testWidgets('with a tool, one finger goes to the tool and a second '
      'finger cancels it and pinches', (t) async {
    await pump(t);
    selection.select(tool);
    await t.pump();
    final start = view(t);

    final solo = await finger(t, 1, const Offset(400, 400));
    await solo.moveBy(const Offset(50, 0));
    await solo.up();
    await t.pump();
    expect(tool.started, 1);
    expect(tool.ended, 1);
    expect(tool.samples, hasLength(2));
    expect(view(t), start);

    final a = await finger(t, 2, const Offset(500, 300));
    expect(tool.started, 2);
    final b = await finger(t, 3, const Offset(700, 300));
    expect(tool.cancelled, 1);
    await a.moveTo(bar + const Offset(400, 300));
    await b.moveTo(bar + const Offset(800, 300));
    await t.pump();
    expect(view(t).scale, closeTo(start.scale * 2, 1e-6));
    // Nothing more reached the tool, and the second finger started none.
    expect(tool.started, 2);
    expect(tool.samples, hasLength(3));
    await a.up();
    await b.up();
    expect(tool.ended, 1);
  });

  testWidgets('a mouse and a stylus do not pinch or pan', (t) async {
    await pump(t);
    final before = view(t);
    final m = await t.startGesture(
      bar + const Offset(500, 300),
      pointer: 1,
      kind: PointerDeviceKind.mouse,
    );
    final s = await t.startGesture(
      bar + const Offset(700, 300),
      pointer: 2,
      kind: PointerDeviceKind.stylus,
    );
    await m.moveTo(bar + const Offset(300, 300));
    await s.moveTo(bar + const Offset(900, 300));
    await t.pump();
    expect(view(t), before);
    await m.up();
    await s.up();
  });

  testWidgets('a pen stroke is not cancelled by touches landing', (t) async {
    await pump(t);
    selection.select(tool);
    await t.pump();
    final before = view(t);
    final pen = await t.startGesture(
      bar + const Offset(400, 400),
      pointer: 1,
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveBy(const Offset(30, 0));
    final a = await finger(t, 2, const Offset(500, 300));
    final b = await finger(t, 3, const Offset(700, 300));
    await a.moveTo(bar + const Offset(300, 300));
    await b.moveTo(bar + const Offset(900, 300));
    await pen.moveBy(const Offset(30, 0));
    await t.pump();
    expect(tool.cancelled, 0);
    expect(tool.started, 1);
    expect(view(t), before);
    expect(tool.samples, hasLength(3));
    await pen.up();
    expect(tool.ended, 1);
    await a.up();
    await b.up();
  });

  testWidgets('lifting one of three fingers does not jump the view', (t) async {
    await pump(t);
    final a = await finger(t, 1, const Offset(500, 300));
    final b = await finger(t, 2, const Offset(700, 300));
    final c3 = await finger(t, 3, const Offset(900, 600));
    await a.moveBy(const Offset(10, 0));
    await t.pump();
    final before = view(t);
    await a.up();
    // The pair is now the second and third fingers, far apart in a
    // different direction; a small move must only change the view a little.
    await b.moveBy(const Offset(2, 0));
    await t.pump();
    final after = view(t);
    expect((after.scale - before.scale).abs(), lessThan(0.05));
    expect((after.offset - before.offset).distance, lessThan(40));
    await b.up();
    await c3.up();
  });

  testWidgets('a pinch then lifting never makes a note; a later tap does', (
    t,
  ) async {
    await pump(t);
    final nodes = c.page.nodes.length;
    final a = await finger(t, 1, const Offset(500, 300));
    final b = await finger(t, 2, const Offset(700, 300));
    // Moves under the touch slop: the tap recognizer is not beaten by drag.
    await b.moveBy(const Offset(4, 0));
    await b.up();
    await a.up();
    await t.pumpAndSettle();
    expect(c.page.nodes.length, nodes);

    final tap = await finger(t, 3, const Offset(900, 500));
    await tap.up();
    await t.pumpAndSettle();
    expect(c.page.nodes.length, nodes + 1);
  });

  testWidgets('a box under a finger stops moving once a second finger lands', (
    t,
  ) async {
    await pump(t);
    final start = c.page.nodes.first.bounds!;
    final grip = view(t).toScreen(
      Offset(start.x + 40, start.y - boxGripHeight / 2),
    );
    final a = await t.startGesture(
      bar + grip,
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    await a.moveBy(const Offset(40, 0));
    await t.pump();
    final moved = c.page.nodes.first.bounds!;
    expect(moved.x, greaterThan(start.x));
    final b = await finger(t, 2, const Offset(900, 500));
    await a.moveBy(const Offset(60, 0));
    await b.moveBy(const Offset(60, 0));
    await t.pump();
    expect(c.page.nodes.first.bounds, moved);
    await a.up();
    await b.up();
  });

  testWidgets('disposing the canvas in the middle of a stroke is safe', (
    t,
  ) async {
    await pump(t);
    selection.select(tool);
    await t.pump();
    final g = await t.startGesture(
      bar + const Offset(400, 400),
      pointer: 1,
      kind: PointerDeviceKind.mouse,
    );
    await g.moveBy(const Offset(30, 0));
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(t.takeException(), isNull);
    await g.up();
  });

  testWidgets('fingers resting during a pen stroke pinch once the pen lifts', (
    t,
  ) async {
    await pump(t);
    selection.select(tool);
    await t.pump();
    final pen = await t.startGesture(
      bar + const Offset(400, 400),
      pointer: 1,
      kind: PointerDeviceKind.stylus,
    );
    final a = await finger(t, 2, const Offset(500, 300));
    await pen.moveBy(const Offset(30, 0));
    await pen.up();
    expect(tool.ended, 1);
    final before = view(t);
    final b = await finger(t, 3, const Offset(700, 300));
    // No ink from the touches, and the pinch has the pair as its start.
    expect(tool.started, 1);
    await a.moveTo(bar + const Offset(400, 300));
    await b.moveTo(bar + const Offset(800, 300));
    await t.pump();
    expect(view(t).scale, closeTo(before.scale * 2, 1e-6));
    expect(tool.started, 1);
    await a.up();
    await b.up();
  });

  testWidgets('resting fingers do not stop the pen from inking again', (
    t,
  ) async {
    await pump(t);
    selection.select(tool);
    await t.pump();
    final before = view(t);
    final a = await finger(t, 1, const Offset(200, 600));
    final b = await finger(t, 2, const Offset(260, 620));
    for (final id in [3, 4]) {
      final pen = await t.startGesture(
        bar + const Offset(500, 300),
        pointer: id,
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveBy(const Offset(30, 0));
      // The palm shifts while the pen is down.
      await a.moveBy(const Offset(10, 5));
      await b.moveBy(const Offset(10, 5));
      await pen.up();
      await t.pump();
    }
    // The first finger's session was dropped by the second; both strokes
    // were drawn.
    expect(tool.started, 3);
    expect(tool.cancelled, 1);
    expect(tool.ended, 2);
    expect(view(t), before);
    await a.up();
    await b.up();
  });
}
