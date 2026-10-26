// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

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

/// Records every pointer sample a session receives.
class _RecordingTool extends CanvasTool {
  final List<ToolPointer> samples = [];
  int ended = 0;
  bool? interactingDuringSession;

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
    samples.add(pointer);
    return _Session(this, context);
  }
}

class _Session extends ToolSession {
  _Session(this.tool, this.context);
  final _RecordingTool tool;
  final ToolContext context;

  @override
  void update(ToolPointer pointer) {
    tool.samples.add(pointer);
    tool.interactingDuringSession = context.controller.isInteracting;
  }

  @override
  void end() => tool.ended++;
  @override
  void cancel() {}
  @override
  void paint(Canvas canvas, double scale) {}
}

class _Module extends BoxModule<String> {
  _Module(this.tool);
  final _RecordingTool tool;
  @override
  BoxCodec<String> get codec => const _Codec();
  @override
  List<CanvasTool> get tools => [tool];
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => taps++,
        child: Text(box.data),
      );
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
}

int taps = 0;

/// The toolbar sits above the canvas, so screen y is the canvas's plus this.
const Offset bar = Offset(0, CommandToolbar.height);

void main() {
  late _RecordingTool tool;
  late CanvasController c;
  late CanvasToolSelection selection;

  /// [sidebar] puts that much other UI to the canvas's left, as in the app.
  Future<void> pump(WidgetTester t, {double sidebar = 0}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    tool = _RecordingTool();
    final modules = ModuleRegistry()..register(_Module(tool), isDefault: true);
    final box = BoxRecord.create(
      id: 'b',
      typeId: 'test.text',
      dataVersion: 1,
      bounds: const Bounds(0, 0, 200, 100),
      data: RawJson.encode('box'),
      snapshotText: 'box',
      rev: 'r',
    );
    c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0))
          .insertNode(box),
      modules,
    );
    selection = CanvasToolSelection();
    addTearDown(selection.dispose);
    taps = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: sidebar),
              Expanded(
                child: PageCanvas(
                  controller: c,
                  tools: selection,
                  toolbarLayout: const [
                    [CanvasCommands.select, 'test.tool'],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PageCanvasState canvas(WidgetTester t) =>
      t.state<PageCanvasState>(find.byType(PageCanvas));

  testWidgets('the active tool gets every pointer sample in page coordinates', (
    t,
  ) async {
    await pump(t);
    selection.select(tool);
    await t.pump();
    final view = canvas(t).view!;

    // A fast stroke: 300 moves with large jumps, starting over the box.
    final start = view.toScreen(const Offset(50, 50)) + bar;
    final g = await t.startGesture(start, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 300; i++) {
      await g.moveTo(start + Offset(i * 3.0, (i % 7) * 40.0));
    }
    expect(c.isInteracting, isTrue);
    await g.up();
    await t.pump();

    expect(tool.samples, hasLength(301));
    expect(tool.samples.first.position.dx, closeTo(50, 1e-6));
    expect(
      tool.samples.last.position,
      view.toWorld(start - bar + Offset(900, (300 % 7) * 40.0)),
    );
    expect(tool.ended, 1);
    expect(tool.interactingDuringSession, isTrue);
    expect(c.isInteracting, isFalse);
    // The box under the pointer got nothing, and no note box was created.
    expect(taps, 0);
    expect(c.page.nodes, hasLength(1));
  });

  testWidgets('wheel and Ctrl+wheel still pan and zoom with a tool active', (
    t,
  ) async {
    await pump(t);
    selection.select(tool);
    await t.pump();
    final v0 = canvas(t).view!;
    final pointer = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(const Offset(600, 400));
    await t.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
    await t.pump();
    expect(canvas(t).view!.offset, isNot(v0.offset));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(canvas(t).view!.scale, greaterThan(v0.scale));
    expect(tool.samples, isEmpty);
  });

  testWidgets('shortcut selects the tool; Escape and V go back to select', (
    t,
  ) async {
    await pump(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(selection.active, tool);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(selection.active, isNull);
    await t.tap(find.byTooltip('Record (R)'));
    expect(selection.active, tool);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    expect(selection.active, isNull);
  });

  testWidgets('without a tool, boxes get the pointer again', (t) async {
    await pump(t);
    final view = canvas(t).view!;
    // The toolbar is above the canvas, not over it.
    await t.tapAt(view.toScreen(const Offset(150, 80)) + bar);
    await t.pump();
    expect(taps, 1);
    expect(tool.samples, isEmpty);
  });

  test('editBox records a diff that undo replays', () {
    final codecModules = ModuleRegistry()..register(_Module(_RecordingTool()));
    final box = BoxRecord.create(
      id: 'b',
      typeId: 'test.text',
      dataVersion: 1,
      bounds: const Bounds(0, 0, 10, 10),
      data: RawJson.encode('a'),
      snapshotText: 'a',
      rev: 'r',
    );
    final ctl = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0))
          .insertNode(box),
      codecModules,
    );
    ctl.editBox(
      'b',
      'ab',
      bounds: const Bounds(0, 0, 20, 10),
      undo: const _Suffix('b'),
    );
    expect((ctl.page.node('b')! as BoxRecord).snapshotText, 'ab');
    ctl.undo();
    final undone = ctl.page.node('b')! as BoxRecord;
    expect(undone.snapshotText, 'a');
    expect(undone.bounds.width, 10);
    ctl.redo();
    expect((ctl.page.node('b')! as BoxRecord).snapshotText, 'ab');
  });

  testWidgets(
    'holding the pointer near an edge pans into new space and keeps every sample',
    (t) async {
      await pump(t);
      selection.select(tool);
      await t.pump();
      final v0 = canvas(t).view!;
      final rightBefore = CanvasGeometry.compute(
        content: c.page.contentBounds!.rect,
        viewport: const Size(1200, 800),
      ).boundary.right;

      // Real input, with the page position each sample must be recorded at.
      final expected = <Offset>[];
      final g = await t.startGesture(
        const Offset(600, 400),
        kind: PointerDeviceKind.mouse,
      );
      expected.add(canvas(t).view!.toWorld(const Offset(600, 400) - bar));
      for (final x in [800.0, 1000.0, 1185.0]) {
        await g.moveTo(Offset(x, 400));
        expected.add(canvas(t).view!.toWorld(Offset(x, 400) - bar));
      }
      // Hold 15 px from the right edge for three seconds.
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final panned = canvas(t).view!;
      expect(
        panned.offset.dx,
        lessThan(v0.offset.dx - 500),
        reason: 'the canvas auto-panned',
      );
      expect(
        panned.visible(const Size(1200, 800)).right,
        greaterThan(rightBefore),
        reason: 'pan bounds grew during the stroke',
      );
      // Past the edge: faster.
      await g.moveTo(const Offset(1260, 400));
      expected.add(canvas(t).view!.toWorld(const Offset(1260, 400) - bar));
      final before = canvas(t).view!.offset.dx;
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));
      final fastStep = before - canvas(t).view!.offset.dx;
      // Back inside: the panning stops.
      await g.moveTo(const Offset(700, 400));
      expected.add(canvas(t).view!.toWorld(const Offset(700, 400) - bar));
      final stopped = canvas(t).view!.offset;
      await t.pump(const Duration(milliseconds: 200));
      expect(canvas(t).view!.offset, stopped);
      await g.up();
      await t.pump();

      // Every real sample is there, in order, at the right page position.
      var at = 0;
      for (final want in expected) {
        while (at < tool.samples.length &&
            (tool.samples[at].position - want).distance > 1e-6) {
          at++;
        }
        expect(
          at,
          lessThan(tool.samples.length),
          reason: 'sample at $want missing',
        );
      }
      // Auto-pan samples follow the pointer into the new space, steadily.
      final xs = [for (final s in tool.samples) s.position.dx];
      final holdStart = xs.indexOf(expected[3].dx);
      for (
        var i = holdStart + 1;
        i < xs.length && xs[i] > xs[i - 1] - 1e-6;
        i++
      ) {
        expect(xs[i], greaterThanOrEqualTo(xs[i - 1]));
      }
      expect(tool.samples.length, greaterThan(expected.length + 50));
      // Further past the edge pans faster than near it (450 px/s at 15 px in).
      expect(fastStep, greaterThan(450 * 0.1 * 1.5));
      expect(tool.ended, 1);
    },
  );

  testWidgets(
    'a stroke over the sidebar pans left; its ink is clipped to the canvas',
    (t) async {
      await pump(t, sidebar: 260);
      selection.select(tool);
      await t.pump();
      // The overlay covers the canvas only, not the sidebar.
      final overlay = t.getRect(find.byKey(PageCanvas.overlayKey));
      expect(overlay.left, 260);
      expect(t.widget(find.byKey(PageCanvas.overlayKey)), isA<ClipRect>());

      final v0 = canvas(t).view!;
      final g = await t.startGesture(
        const Offset(600, 400),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(const Offset(100, 400)); // over the sidebar
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(
        canvas(t).view!.offset.dx,
        greaterThan(v0.offset.dx),
        reason: 'panned left',
      );
      await g.up();
      expect(tool.ended, 1);
    },
  );
}

/// Undo of appending [suffix]; its inverse appends it again.
class _Suffix implements BoxEdit {
  const _Suffix(this.suffix, {this.append = false});
  final String suffix;
  final bool append;
  @override
  (Object?, BoxEdit) apply(Object? data) {
    final s = data! as String;
    return append
        ? ('$s$suffix', _Suffix(suffix))
        : (
            s.substring(0, s.length - suffix.length),
            _Suffix(suffix, append: true),
          );
  }
}
