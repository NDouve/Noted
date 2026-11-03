// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// A stylus inks whatever tool is picked; fingers and mouse use the picked
/// tool (0033).

class _Codec extends BoxCodec<String> {
  const _Codec(this.typeId);
  @override
  final String typeId;
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
  _Tool(this.id, [this.stylusRole = StylusRole.none]);
  @override
  final StylusRole stylusRole;
  @override
  final String id;
  final List<ToolPointer> samples = [];
  int started = 0;
  int ended = 0;
  int cancelled = 0;

  @override
  String get label => id;
  @override
  IconData get icon => Icons.edit;

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
  _Module(this.typeId, this.tools);
  final String typeId;
  @override
  final List<CanvasTool> tools;
  @override
  BoxCodec<String> get codec => _Codec(typeId);
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
}

const Offset bar = Offset(0, CommandToolbar.height);

void main() {
  late _Tool pen;
  late _Tool eraser;
  late CanvasController c;
  late CanvasToolSelection selection;

  CanvasView view(WidgetTester t) =>
      t.state<PageCanvasState>(find.byType(PageCanvas)).view!;

  Future<void> pump(
    WidgetTester t, {
    bool withPen = true,
    bool withEraser = true,
    bool readOnly = false,
    Set<String> disallowed = const {},
  }) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    pen = _Tool('draw.pen', StylusRole.pen);
    eraser = _Tool('draw.eraser', StylusRole.eraser);
    final modules = ModuleRegistry()
      ..register(_Module('test.text', const []), isDefault: true)
      ..register(_Module('test.draw', withPen ? [pen, if (withEraser) eraser] : const []));
    final page = NotedPage.create(
      PageMeta.create(id: 'p', title: '', order: 0),
    ).insertNode(
      BoxRecord.create(
        id: 'b0',
        typeId: 'test.text',
        dataVersion: 1,
        bounds: Bounds(100, 100, 200, 100),
        data: RawJson.encode('box'),
        snapshotText: 'box',
        rev: 'r',
      ),
    );
    c = CanvasController(page, modules);
    selection = CanvasToolSelection();
    addTearDown(selection.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(
            controller: c,
            readOnly: readOnly,
            disallowedTypes: disallowed,
            tools: selection,
            toolbar: const ContextualToolbarLayout(
              leading: [],
              sections: [],
              trailing: [
                [CanvasCommands.select],
              ],
            ),
          ),
        ),
      ),
    );
    await t.pump();
    t.state<PageCanvasState>(find.byType(PageCanvas)).zoomTo(1);
    await t.pump();
  }

  Offset onBox(WidgetTester t) => bar + view(t).toScreen(const Offset(200, 150));

  Future<void> drag(WidgetTester t, PointerDeviceKind kind, Offset at) async {
    final g = await t.startGesture(at, kind: kind);
    await g.moveBy(const Offset(30, 0));
    await g.up();
    await t.pump();
  }

  Future<void> tap(WidgetTester t, PointerDeviceKind kind, Offset at) async {
    final g = await t.startGesture(at, kind: kind);
    await g.up();
    await t.pumpAndSettle();
  }

  testWidgets('a stylus inks in Select over a box and over empty page', (
    t,
  ) async {
    await pump(t);
    expect(selection.active, isNull);
    await drag(t, PointerDeviceKind.stylus, onBox(t));
    expect(pen.started, 1);
    expect(pen.ended, 1);
    expect(pen.samples, hasLength(2));
    // The box under the pen was neither selected nor moved.
    expect(c.selectedId, isNull);
    expect(c.page.node('b0')!.bounds, Bounds(100, 100, 200, 100));
    await drag(t, PointerDeviceKind.stylus, bar + const Offset(800, 500));
    expect(pen.started, 2);
    expect(eraser.started, 0);
  });

  testWidgets('a stylus does not move a box by its grip', (t) async {
    await pump(t);
    final grip =
        bar + view(t).toScreen(const Offset(140, 100 - boxGripHeight / 2));
    await drag(t, PointerDeviceKind.stylus, grip);
    expect(pen.started, 1);
    expect(c.page.node('b0')!.bounds, Bounds(100, 100, 200, 100));
  });

  testWidgets('the eraser end of a stylus erases', (t) async {
    await pump(t);
    await drag(t, PointerDeviceKind.invertedStylus, onBox(t));
    expect(eraser.started, 1);
    expect(pen.started, 0);
  });

  testWidgets('with the pen picked the eraser end still erases', (t) async {
    await pump(t);
    selection.select(pen);
    await t.pump();
    await drag(t, PointerDeviceKind.invertedStylus, onBox(t));
    expect(eraser.started, 1);
    expect(pen.started, 0);
    await drag(t, PointerDeviceKind.stylus, onBox(t));
    expect(pen.started, 1);
  });

  testWidgets('a picked tool other than the pen keeps the stylus', (t) async {
    await pump(t);
    selection.select(eraser);
    await t.pump();
    await drag(t, PointerDeviceKind.stylus, onBox(t));
    expect(eraser.started, 1);
    expect(pen.started, 0);
  });

  testWidgets('a mouse in Select selects the box and does not ink', (t) async {
    await pump(t);
    await tap(t, PointerDeviceKind.mouse, onBox(t));
    expect(pen.started, 0);
    expect(c.selectedId, 'b0');
  });

  testWidgets('a finger in Select selects the box and does not ink', (t) async {
    await pump(t);
    await tap(t, PointerDeviceKind.touch, onBox(t));
    expect(pen.started, 0);
    expect(c.selectedId, 'b0');
  });

  testWidgets('without the drawing tools a stylus keeps selecting', (t) async {
    await pump(t, withPen: false);
    await tap(t, PointerDeviceKind.stylus, onBox(t));
    expect(c.selectedId, 'b0');
  });

  testWidgets('fingers resting do not disturb a stylus stroke in Select', (
    t,
  ) async {
    await pump(t);
    final s = await t.startGesture(
      bar + const Offset(600, 400),
      pointer: 1,
      kind: PointerDeviceKind.stylus,
    );
    final a = await t.startGesture(
      bar + const Offset(300, 500),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    final b = await t.startGesture(
      bar + const Offset(360, 520),
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );
    await s.moveBy(const Offset(30, 0));
    await a.moveBy(const Offset(10, 5));
    await b.moveBy(const Offset(10, 5));
    await s.up();
    expect(pen.cancelled, 0);
    expect(pen.ended, 1);
    expect(pen.samples, hasLength(2));
    await a.up();
    await b.up();
  });

  testWidgets('a stylus tap on a box inks and does not select it', (t) async {
    await pump(t);
    await tap(t, PointerDeviceKind.stylus, onBox(t));
    expect(pen.started, 1);
    expect(pen.ended, 1);
    expect(c.selectedId, isNull);
  });

  testWidgets('a hand resting on empty page during a stroke makes no note', (
    t,
  ) async {
    await pump(t);
    final nodes = c.page.nodes.length;
    final palm = await t.startGesture(
      bar + const Offset(900, 600),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    final s = await t.startGesture(
      bar + const Offset(600, 400),
      pointer: 1,
      kind: PointerDeviceKind.stylus,
    );
    await s.moveBy(const Offset(30, 0));
    await s.moveBy(const Offset(30, 0));
    await palm.up();
    await s.up();
    await t.pumpAndSettle();
    expect(pen.ended, 1);
    expect(c.page.nodes.length, nodes);
    // A later finger tap still makes a note.
    await tap(t, PointerDeviceKind.touch, bar + const Offset(900, 500));
    expect(c.page.nodes.length, nodes + 1);
  });

  testWidgets('on a read-only page a stylus does not ink', (t) async {
    await pump(t, readOnly: true);
    await drag(t, PointerDeviceKind.stylus, onBox(t));
    expect(pen.started, 0);
    expect(eraser.started, 0);
  });

  testWidgets('with drawing not allowed the stylus falls back to the tool', (
    t,
  ) async {
    await pump(t, disallowed: {'test.draw'});
    await tap(t, PointerDeviceKind.stylus, onBox(t));
    expect(pen.started, 0);
    expect(c.selectedId, 'b0');
  });

  testWidgets('a hand resting on a box during a stroke does not select it', (
    t,
  ) async {
    await pump(t);
    // The finger lands after the pen.
    final s = await t.startGesture(
      bar + const Offset(700, 500),
      pointer: 1,
      kind: PointerDeviceKind.stylus,
    );
    final palm = await t.startGesture(
      onBox(t),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    await s.moveBy(const Offset(30, 0));
    await palm.up();
    await s.up();
    await t.pumpAndSettle();
    expect(c.selectedId, isNull);

    // The finger was down before the pen.
    final palm2 = await t.startGesture(
      onBox(t),
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );
    final s2 = await t.startGesture(
      bar + const Offset(700, 500),
      pointer: 4,
      kind: PointerDeviceKind.stylus,
    );
    await s2.moveBy(const Offset(30, 0));
    await palm2.up();
    await s2.up();
    await t.pumpAndSettle();
    expect(c.selectedId, isNull);
    // A plain finger tap on the box still selects it.
    await tap(t, PointerDeviceKind.touch, onBox(t));
    expect(c.selectedId, 'b0');
  });

  testWidgets('a finger landing mid-stroke and lifting makes no note', (
    t,
  ) async {
    await pump(t);
    final nodes = c.page.nodes.length;
    final s = await t.startGesture(
      bar + const Offset(600, 400),
      pointer: 1,
      kind: PointerDeviceKind.stylus,
    );
    final palm = await t.startGesture(
      bar + const Offset(900, 600),
      pointer: 2,
      kind: PointerDeviceKind.touch,
    );
    await palm.up();
    await s.moveBy(const Offset(30, 0));
    await s.up();
    await t.pumpAndSettle();
    expect(pen.ended, 1);
    expect(c.page.nodes.length, nodes);
  });

  testWidgets('without an eraser tool the eraser end is not claimed', (
    t,
  ) async {
    await pump(t, withEraser: false);
    // Not claimed, so a tap by the eraser end still makes a note.
    final nodes = c.page.nodes.length;
    await tap(t, PointerDeviceKind.invertedStylus, bar + const Offset(800, 500));
    expect(pen.started, 0);
    expect(c.page.nodes.length, nodes + 1);
  });
}
