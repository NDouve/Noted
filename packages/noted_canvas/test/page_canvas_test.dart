// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// A minimal module: a text field whose box grows by 20 px per line.
class _TextCodec extends BoxCodec<String> {
  const _TextCodec();
  @override
  String get typeId => 'test.text';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.growsWithContent;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  bool isEmpty(String data) => data.trim().isEmpty;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

class _TextModule extends BoxModule<String> {
  const _TextModule();
  @override
  BoxCodec<String> get codec => const _TextCodec();
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      _Editor(box: box);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
}

class _Editor extends StatefulWidget {
  const _Editor({required this.box});
  final BoxContext<String> box;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final TextEditingController _text = TextEditingController(
    text: widget.box.data,
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // `autofocus:` is ignored while the canvas holds focus; ask explicitly.
    if (widget.box.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focus.requestFocus(),
      );
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    maxLines: null,
    onChanged: (s) {
      widget.box.commit(s);
      if (!widget.box.autoHeight) return;
      final b = widget.box.bounds;
      final lines = '\n'.allMatches(s).length + 1;
      widget.box.requestBounds(
        Rect.fromLTWH(b.left, b.top, b.width, 20.0 * lines + 20),
      );
    },
  );
}

BoxRecord _foreignTypeBox() => BoxRecord.create(
  id: 'alien',
  typeId: 'vendor.alien',
  dataVersion: 1,
  bounds: const Bounds(400, 300, 200, 80),
  data: RawJson.parse('{"secret": 1.0}'),
  snapshotText: 'alien snapshot',
  rev: 'r',
);

/// The toolbar sits above the canvas, so screen y is the canvas's plus this.
const Offset bar = Offset(0, CommandToolbar.height);

void main() {
  late ModuleRegistry modules;
  late List<NotedPage> saved;

  setUp(() {
    modules = ModuleRegistry()
      ..register(const _TextModule(), alwaysOn: true, isDefault: true);
    saved = [];
  });

  CanvasController controllerFor(NotedPage page) =>
      CanvasController(page, modules, onChanged: saved.add);

  NotedPage emptyPage() =>
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));

  Future<void> pump(WidgetTester t, CanvasController c) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
  }

  testWidgets('click creates a focused box; typing saves; it grows', (t) async {
    final c = controllerFor(emptyPage());
    await pump(t, c);
    await t.tapAt(const Offset(300, 200));
    await t.pumpAndSettle();
    expect(c.page.nodes, hasLength(1));
    expect(c.editingId, c.page.nodes.single.id);

    await t.enterText(find.byType(TextField), 'hello\nworld');
    await t.pumpAndSettle();
    final box = c.page.nodes.single as BoxRecord;
    expect(box.snapshotText, 'hello\nworld');
    expect(box.data!.text, '"hello\\nworld"');
    expect(box.bounds.height, 60);
    expect(saved, isNotEmpty);
    // Undo history isn't touched by growth.
    c.undo();
    expect(c.page.nodes, isEmpty);
  });

  testWidgets('an empty box is discarded when it loses focus', (t) async {
    final c = controllerFor(emptyPage());
    await pump(t, c);
    await t.tapAt(const Offset(300, 200));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(800, 600));
    await t.pumpAndSettle();
    // The second click made a new box and the first, empty one went away.
    expect(c.page.nodes, hasLength(1));
    expect(c.page.nodes.single.bounds!.x, greaterThan(700));
    expect(c.canUndo, isTrue);
    c.undo();
    expect(c.page.nodes, isEmpty);
    expect(c.canUndo, isFalse);
  });

  testWidgets('dragging the grip moves a box; undo restores it', (t) async {
    final c = controllerFor(emptyPage());
    await pump(t, c);
    await t.tapAt(const Offset(300, 200));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'x');
    await t.pumpAndSettle();
    final before = c.page.nodes.single.bounds!;
    final grip = c.page.nodes.single.bounds!;
    // The grip sits just above the box; the view is at 100% on the origin.
    final view = t.state<PageCanvasState>(find.byType(PageCanvas)).view!;
    final gripScreen = bar + view.toScreen(
      Offset(grip.x + 40, grip.y - boxGripHeight / 2),
    );
    await t.dragFrom(gripScreen, const Offset(120, 80));
    await t.pumpAndSettle();
    final after = c.page.nodes.single.bounds!;
    expect(after.x - before.x, closeTo(120, 1));
    expect(after.y - before.y, closeTo(80, 1));
    // Leave the editor so page undo applies.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    c.undo();
    expect(c.page.nodes.single.bounds, before);
  });

  testWidgets('unsupported boxes show their snapshot and stay untouched', (
    t,
  ) async {
    final page = emptyPage().insertNode(_foreignTypeBox());
    final c = controllerFor(page);
    await pump(t, c);
    expect(find.text('alien snapshot'), findsOneWidget);
    expect(find.text('Editable on other devices'), findsOneWidget);
    c.delete('alien');
    expect(c.page.node('alien'), isNotNull);
    expect(writePage(c.page), contains('"data":{"secret": 1.0}'));
  });

  testWidgets('wheel pans, Ctrl+wheel zooms', (t) async {
    final page = emptyPage().insertNode(_foreignTypeBox());
    final c = controllerFor(page);
    await pump(t, c);
    PageCanvasState state() =>
        t.state<PageCanvasState>(find.byType(PageCanvas));
    final v0 = state().view!;

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(const Offset(100, 100));
    await t.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
    await t.pump();
    expect(state().view!.offset.dy, v0.offset.dy - 50);
    expect(state().view!.scale, v0.scale);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(state().view!.scale, greaterThan(v0.scale));
  });

  testWidgets('Fit all zooms out to show distant boxes', (t) async {
    var page = emptyPage();
    for (final (i, x) in [0.0, 6000.0].indexed) {
      page = page.insertNode(
        BoxRecord.create(
          id: 'b$i',
          typeId: 'test.text',
          dataVersion: 1,
          bounds: Bounds(x, 0, 200, 40),
          data: RawJson.encode('box $i'),
          snapshotText: 'box $i',
          rev: 'r',
        ),
      );
    }
    final c = controllerFor(page);
    await pump(t, c);
    await t.tap(find.text('Fit all'));
    await t.pump();
    expect(
      t.state<PageCanvasState>(find.byType(PageCanvas)).view!.scale,
      lessThan(0.25),
    );
  });

  test('always-on modules cannot be switched off', () {
    expect(() => modules.setEnabled('test.text', false), throwsStateError);
  });

  Offset screenOf(WidgetTester t, Offset world) =>
      bar + t.state<PageCanvasState>(find.byType(PageCanvas)).view!.toScreen(world);

  testWidgets(
    'a height resize fixes the height; double-clicking the bottom edge restores auto height',
    (t) async {
      final c = controllerFor(emptyPage());
      await pump(t, c);
      await t.tapAt(const Offset(300, 200));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'a');
      await t.pumpAndSettle();
      BoxRecord box() => c.page.nodes.single as BoxRecord;
      expect(box().bounds.height, 40);
      expect(c.isAutoHeight(box()), isTrue);

      // Width only: still auto.
      final b0 = box().bounds;
      await t.dragFrom(
        screenOf(t, Offset(b0.right, b0.y + b0.height / 2)),
        const Offset(60, 0),
      );
      await t.pumpAndSettle();
      expect(box().bounds.width, b0.width + 60);
      expect(box().fixedHeight, isFalse);

      // Height: fixed from now on, and typing no longer grows the box.
      final b1 = box().bounds;
      final bottom = screenOf(t, Offset(b1.x + b1.width / 2, b1.bottom));
      await t.dragFrom(bottom, const Offset(0, 100));
      await t.pumpAndSettle();
      expect(box().bounds.height, 140);
      expect(box().fixedHeight, isTrue);
      await t.enterText(find.byType(TextField), 'a\nb\nc\nd\ne\nf\ng\nh');
      await t.pumpAndSettle();
      expect(box().bounds.height, 140);

      // Double-click the bottom edge: back to growing with content.
      final b2 = box().bounds;
      final edge = screenOf(t, Offset(b2.x + b2.width / 2, b2.bottom));
      await t.tapAt(edge);
      await t.pump(const Duration(milliseconds: 50));
      await t.tapAt(edge);
      await t.pumpAndSettle();
      expect(box().fixedHeight, isFalse);
      await t.enterText(find.byType(TextField), 'a\nb\nc');
      await t.pumpAndSettle();
      expect(box().bounds.height, 80);

      // Page undo restores the fixed height.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      c.undo();
      expect(box().fixedHeight, isTrue);
    },
  );

  testWidgets('BoxScrollScope scrolls on wheel but lets Ctrl+wheel through', (
    t,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var outer = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Listener(
          onPointerSignal: (e) => GestureBinding.instance.pointerSignalResolver
              .register(e, (_) => outer++),
          child: BoxScrollScope(
            child: ListView(
              controller: scroll,
              children: [
                for (var i = 0; i < 50; i++) const SizedBox(height: 50),
              ],
            ),
          ),
        ),
      ),
    );
    final pointer = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(const Offset(100, 100));
    await t.sendEventToBinding(pointer.scroll(const Offset(0, 60)));
    await t.pump();
    expect(scroll.offset, greaterThan(0));
    expect(outer, 0);

    final before = scroll.offset;
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendEventToBinding(pointer.scroll(const Offset(0, 60)));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(scroll.offset, before);
    expect(outer, 1);
  });
}
