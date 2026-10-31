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

  testWidgets('panning and zooming do not rebuild the boxes; a change does', (
    t,
  ) async {
    // Every pan or zoom frame rebuilds the canvas; the boxes (editors) must
    // be left alone, or a page with hundreds of them cannot keep up.
    final counting = _CountingModule();
    modules = ModuleRegistry()
      ..register(counting, alwaysOn: true, isDefault: true);
    var page = emptyPage();
    for (var i = 0; i < 3; i++) {
      page = page.insertNode(
        BoxRecord.create(
          id: 'b$i',
          typeId: 'test.text',
          dataVersion: 1,
          bounds: Bounds(100.0 + i * 400, 200, 300, 80),
          data: RawJson.parse('"box $i"'),
          snapshotText: 'box $i',
          rev: 'r',
        ),
      );
    }
    final c = controllerFor(page);
    await pump(t, c);
    await t.pump();
    final built = counting.editorBuilds;
    expect(built, greaterThanOrEqualTo(3));

    final pointer = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(const Offset(600, 500));
    for (var i = 0; i < 5; i++) {
      await t.sendEventToBinding(pointer.scroll(const Offset(40, 20)));
      await t.pump();
    }
    final before = t.state<PageCanvasState>(find.byType(PageCanvas)).view!;
    for (var i = 0; i < 5; i++) {
      await t.sendEventToBinding(
        PointerScaleEvent(position: const Offset(600, 500), scale: 1.2),
      );
      await t.pump();
    }
    final after = t.state<PageCanvasState>(find.byType(PageCanvas)).view!;
    expect(after.scale, greaterThan(before.scale * 2));
    expect(after.offset, isNot(before.offset));
    expect(counting.editorBuilds, built, reason: 'no box was rebuilt');

    // A change the boxes show rebuilds them.
    c.select('b1');
    await t.pump();
    expect(counting.editorBuilds, greaterThan(built));

    // Dragging a grip uses the zoom at that moment, not the one at the last
    // rebuild: 100 screen pixels are 100 / scale page pixels. Zoom around the
    // grip so it stays where it is.
    final b = c.page.node('b1')!.bounds!;
    final state = t.state<PageCanvasState>(find.byType(PageCanvas));
    state.fitAll();
    await t.pump();
    final grip = bar + state.view!.toScreen(Offset(b.x + 40, b.y - boxGripHeight / 2));
    expect(Rect.fromLTWH(0, 0, 1200, 800).contains(grip), isTrue, reason: '$grip');
    for (var i = 0; i < 4; i++) {
      await t.sendEventToBinding(PointerScaleEvent(position: grip, scale: 1.2));
      await t.pump();
    }
    final scale = state.view!.scale;
    expect(scale, greaterThan(1.5));
    await t.dragFrom(grip, const Offset(100, 0));
    await t.pump();
    expect(c.page.node('b1')!.bounds!.x - b.x, closeTo(100 / scale, 1));
  });

  testWidgets('a box that grows rebuilds alone, not its siblings', (t) async {
    // A note growing with its text changes the page; the other boxes show
    // nothing new, so their widgets must be kept (a page with hundreds of
    // notes would otherwise rebuild them all on every line wrap).
    final counting = _CountingModule();
    modules = ModuleRegistry()
      ..register(counting, alwaysOn: true, isDefault: true);
    var page = emptyPage();
    for (var i = 0; i < 3; i++) {
      page = page.insertNode(
        BoxRecord.create(
          id: 'b$i',
          typeId: 'test.text',
          dataVersion: 1,
          bounds: Bounds(100.0 + i * 400, 200, 300, 80),
          data: RawJson.parse('"box $i"'),
          snapshotText: 'box $i',
          rev: 'r',
        ),
      );
    }
    final c = controllerFor(page);
    await pump(t, c);
    await t.pump();
    Map<String, int> builds() => Map.of(counting.buildsPerBox);
    var before = builds();

    c.requestBounds('b0', const Bounds(100, 200, 300, 140));
    await t.pump();
    expect(c.page.node('b0')!.bounds!.height, 140);
    var after = builds();
    expect(after['b0'], greaterThan(before['b0']!));
    expect(after['b1'], before['b1'], reason: 'b1 not rebuilt');
    expect(after['b2'], before['b2'], reason: 'b2 not rebuilt');
    expect(
      t.getSize(find.byKey(const ValueKey('b0'))).height,
      greaterThan(140),
      reason: 'the grown box is laid out at its new height',
    );

    // Selecting rebuilds the box selected, and the one that was.
    before = builds();
    c.select('b1');
    await t.pump();
    after = builds();
    expect(after['b1'], greaterThan(before['b1']!));
    expect(after['b0'], before['b0']);
    expect(after['b2'], before['b2']);
    before = after;
    c.select('b2');
    await t.pump();
    after = builds();
    expect(after['b1'], greaterThan(before['b1']!));
    expect(after['b2'], greaterThan(before['b2']!));
    expect(after['b0'], before['b0']);

    // Read-only changes every box.
    before = after;
    c.readOnly = true;
    await t.pump();
    after = builds();
    for (final id in ['b0', 'b1', 'b2']) {
      expect(after[id], greaterThan(before[id]!), reason: id);
    }
  });
}

/// [_TextModule] that counts how often a box's editor is built, and how
/// often each box's content (editor or view) is built.
class _CountingModule extends _TextModule {
  _CountingModule();
  int editorBuilds = 0;
  final Map<String, int> buildsPerBox = {};
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) {
    editorBuilds++;
    buildsPerBox.update(box.boxId, (n) => n + 1, ifAbsent: () => 1);
    return super.buildEditor(context, box);
  }

  @override
  Widget buildView(BuildContext context, BoxContext<String> box) {
    buildsPerBox.update(box.boxId, (n) => n + 1, ifAbsent: () => 1);
    return super.buildView(context, box);
  }
}
