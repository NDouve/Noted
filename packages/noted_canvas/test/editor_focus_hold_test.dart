// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The host's hold on a box editor's focus (an app menu takes the focus for a
// moment): the box stays in editing, and the real focus is read again when the
// hold ends. Also the host-only PageCanvas parameters of the UI shell.

import 'package:flutter/material.dart';
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
  Widget buildEditor(BuildContext context, BoxContext<String> box) => _Editor(box: box);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
}

class _Editor extends StatefulWidget {
  const _Editor({required this.box});
  final BoxContext<String> box;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final TextEditingController _text = TextEditingController(text: widget.box.data);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // `autofocus:` is ignored while the canvas holds focus; ask explicitly.
    if (widget.box.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
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
      widget.box.requestBounds(Rect.fromLTWH(b.left, b.top, b.width, 20.0 * lines + 20));
    },
  );
}

void main() {
  late ModuleRegistry modules;

  setUp(() {
    modules = ModuleRegistry()..register(const _TextModule(), alwaysOn: true, isDefault: true);
  });

  NotedPage emptyPage() => NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));

  test('the hold is a counter: each hold needs its release', () {
    final c = CanvasController(emptyPage(), modules);
    addTearDown(c.dispose);
    expect(c.editorFocusHeld.value, isFalse);
    c.editorFocusHold.hold();
    c.editorFocusHold.hold();
    expect(c.editorFocusHold.count, 2);
    c.editorFocusHold.release();
    expect(c.editorFocusHeld.value, isTrue);
    c.editorFocusHold.release();
    expect(c.editorFocusHeld.value, isFalse);
    c.editorFocusHold.release();
    expect(c.editorFocusHold.count, 0, reason: 'an extra release does nothing');
  });

  test('hold and release after dispose do nothing', () {
    final c = CanvasController(emptyPage(), modules)..dispose();
    c.editorFocusHold.hold();
    c.editorFocusHold.release();
    expect(c.editorFocusHold.count, 0);
  });

  Future<(CanvasController, FocusNode)> pumpEditing(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = CanvasController(emptyPage(), modules);
    final other = FocusNode(debugLabel: 'menu');
    addTearDown(other.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Focus(focusNode: other, child: const SizedBox(height: 20)),
              Expanded(child: PageCanvas(controller: c)),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    await t.tapAt(const Offset(400, 300) + const Offset(0, 20 + CommandToolbar.height));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(c.editingId, isNotNull);
    return (c, other);
  }

  testWidgets('while held, losing the editor focus does not end editing', (t) async {
    final (c, menu) = await pumpEditing(t);
    final id = c.editingId!;
    c.editorFocusHold.hold();
    menu.requestFocus();
    await t.pump();
    expect(c.editingId, id);
    expect(c.page.node(id), isNotNull, reason: 'an empty box is not discarded');
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('release reads the real focus: back in the editor, still editing', (t) async {
    final (c, menu) = await pumpEditing(t);
    final id = c.editingId!;
    final origin = FocusManager.instance.primaryFocus!;
    c.editorFocusHold.hold();
    menu.requestFocus();
    await t.pump();
    origin.requestFocus();
    await t.pump();
    c.editorFocusHold.release();
    await t.pump();
    expect(c.editingId, id);
    expect(c.editorFocusHeld.value, isFalse);
  });

  testWidgets('release with the focus elsewhere ends editing as it would without the hold', (
    t,
  ) async {
    final (c, menu) = await pumpEditing(t);
    final id = c.editingId!;
    c.editorFocusHold.hold();
    menu.requestFocus();
    await t.pump();
    c.editorFocusHold.release();
    await t.pump();
    expect(c.editingId, isNull);
    expect(c.page.node(id), isNull, reason: 'the empty box goes, as on any focus loss');
  });

  testWidgets('without a hold, losing the focus ends editing', (t) async {
    final (c, menu) = await pumpEditing(t);
    menu.requestFocus();
    await t.pump();
    expect(c.editingId, isNull);
  });

  group('onCommandsChanged', () {
    Future<List<CommandRegistry?>> pumpCanvas(
      WidgetTester t,
      CanvasController c, {
      bool readOnly = false,
    }) async {
      final seen = <CommandRegistry?>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCanvas(controller: c, readOnly: readOnly, onCommandsChanged: seen.add),
          ),
        ),
      );
      await t.pump();
      return seen;
    }

    testWidgets('reports the registry after the first frame', (t) async {
      final c = CanvasController(emptyPage(), modules);
      final seen = await pumpCanvas(t, c);
      expect(seen, hasLength(1));
      expect(seen.single, isNotNull);
      expect(seen.single!['canvas.undo'], isNotNull);
    });

    testWidgets(
      'reports a new registry when the page changes, and disposes the old one a frame later',
      (t) async {
        final a = CanvasController(emptyPage(), modules);
        final b = CanvasController(
          NotedPage.create(PageMeta.create(id: 'q', title: '', order: 0)),
          modules,
        );
        final seen = await pumpCanvas(t, a);
        final first = seen.single!;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PageCanvas(controller: b, onCommandsChanged: seen.add),
            ),
          ),
        );
        expect(seen, hasLength(2));
        expect(seen.last, isNot(same(first)));

        // The old registry is still readable in the frame it was replaced.
        expect(first['canvas.undo'], isNotNull);
        await t.pump();
        expect(first['canvas.undo'], isNull, reason: 'disposed one frame later');
      },
    );

    testWidgets('reports null in the frame after the canvas is disposed', (t) async {
      final c = CanvasController(emptyPage(), modules);
      final seen = await pumpCanvas(t, c);
      final registry = seen.single!;
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await t.pump();
      expect(seen.last, isNull);
      expect(registry['canvas.undo'], isNull);
    });

    testWidgets('a page that turns read-only turns the edit commands off at once', (t) async {
      final box = BoxRecord.create(
        id: 'b',
        typeId: 'test.text',
        dataVersion: 1,
        bounds: const Bounds(10, 10, 100, 40),
        data: RawJson.encode('x'),
        snapshotText: 'x',
        rev: 'r',
      );
      final c = CanvasController(emptyPage().insertNode(box), modules)..select('b');
      final seen = await pumpCanvas(t, c);
      final delete = seen.single!['canvas.delete']!;
      var notified = 0;
      delete.addListener(() => notified++);
      expect(delete.enabled, isTrue);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCanvas(controller: c, readOnly: true, onCommandsChanged: seen.add),
          ),
        ),
      );
      expect(delete.enabled, isFalse);
      expect(notified, 1, reason: 'the command told its listeners in the same frame');
    });
  });

  group('sidePanel', () {
    testWidgets('is built with the live registry, right of the canvas and below the toolbar', (
      t,
    ) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = CanvasController(emptyPage(), modules);
      CommandRegistry? given;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCanvas(
              controller: c,
              sidePanel: (context, registry) {
                given = registry;
                return const SizedBox(key: ValueKey('panel'), width: 264);
              },
            ),
          ),
        ),
      );
      await t.pump();
      expect(given, isNotNull);
      final panel = t.getRect(find.byKey(const ValueKey('panel')));
      expect(panel.right, 1200);
      expect(panel.top, CommandToolbar.height);
      expect(
        t.getSize(find.byType(CommandToolbar)).width,
        1200,
        reason: 'the toolbar keeps its full width',
      );
    });
  });

  group('header and footer', () {
    testWidgets('the header is under the toolbar and left of the side panel, the footer under both', (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = CanvasController(emptyPage(), modules);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCanvas(
              controller: c,
              header: const SizedBox(key: ValueKey('header'), height: 70),
              footer: const SizedBox(key: ValueKey('footer'), height: 34),
              sidePanel: (context, registry) => const SizedBox(key: ValueKey('panel'), width: 264),
            ),
          ),
        ),
      );
      await t.pump();
      final header = t.getRect(find.byKey(const ValueKey('header')));
      final footer = t.getRect(find.byKey(const ValueKey('footer')));
      final panel = t.getRect(find.byKey(const ValueKey('panel')));
      expect(header.top, CommandToolbar.height);
      expect(header.left, 0);
      expect(header.right, 1200 - 264);
      expect(panel.top, CommandToolbar.height);
      expect(panel.bottom, footer.top);
      expect(footer.bottom, 800);
      expect(footer.width, 1200);
      // The viewport starts under the header.
      expect(t.getRect(find.byKey(PageCanvas.overlayKey)).top, header.bottom);
    });
  });
}
