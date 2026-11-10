// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The layering commands (bring to front, bring forward, send backward, send
// to back): enabled states, keys, undo, and a box that is being edited.

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

class _Module extends BoxModule<String> {
  const _Module();
  @override
  BoxCodec<String> get codec => const _Codec();
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      _Editor(box: box);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
}

class _Editor extends StatefulWidget {
  const _Editor({required this.box});
  final BoxContext<String> box;
  @override
  State<_Editor> createState() => _EditorState();
}

int editorsBuilt = 0;

class _EditorState extends State<_Editor> {
  late final TextEditingController _text = TextEditingController(text: widget.box.data);

  @override
  void initState() {
    super.initState();
    editorsBuilt++;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextField(key: const ValueKey('field'), controller: _text, maxLines: null);
}

BoxRecord _box(String id, Bounds at) => BoxRecord.create(
  id: id,
  typeId: 'test.text',
  dataVersion: 1,
  bounds: at,
  data: RawJson.encode(id),
  snapshotText: id,
  rev: 'r-$id',
);

void main() {
  late CanvasController c;
  late List<NotedPage> saved;

  // a and b overlap, b and c overlap, d is on its own.
  NotedPage threeAndOne() {
    var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    for (final n in [
      _box('a', const Bounds(100, 100, 200, 100)),
      _box('b', const Bounds(200, 150, 200, 100)),
      _box('c', const Bounds(350, 200, 200, 100)),
      _box('d', const Bounds(800, 500, 100, 100)),
    ]) {
      p = p.insertNode(n);
    }
    return p;
  }

  List<String> order() => [for (final n in c.page.nodes) n.id];

  Future<PageCanvasState> pump(WidgetTester t, {bool readOnly = false}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    editorsBuilt = 0;
    saved = [];
    final modules = ModuleRegistry()..register(const _Module(), isDefault: true);
    c = CanvasController(threeAndOne(), modules, onChanged: saved.add);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PageCanvas(controller: c, readOnly: readOnly)),
      ),
    );
    await t.pump();
    return t.state<PageCanvasState>(find.byType(PageCanvas));
  }

  Future<void> key(
    WidgetTester t,
    LogicalKeyboardKey k, {
    bool ctrl = true,
    bool shift = false,
    bool meta = false,
  }) async {
    if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (meta) await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(k);
    if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (meta) await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
  }

  Future<Offset> tapPoint(WidgetTester t, Offset world) async {
    final s = t.state<PageCanvasState>(find.byType(PageCanvas));
    s.zoomTo(1);
    await t.pump();
    return const Offset(0, CommandToolbar.height) + s.view!.toScreen(world);
  }

  const front = CanvasCommands.bringToFront;
  const forward = CanvasCommands.bringForward;
  const backward = CanvasCommands.sendBackward;
  const back = CanvasCommands.sendToBack;

  group('enabled states', () {
    testWidgets('none selected: all four are off', (t) async {
      final s = await pump(t);
      for (final id in [front, forward, backward, back]) {
        expect(s.commands[id]!.enabled, isFalse, reason: id);
      }
    });

    testWidgets('read-only: all four are off, and the keys do nothing', (t) async {
      final s = await pump(t, readOnly: true);
      c.select('a');
      for (final id in [front, forward, backward, back]) {
        expect(s.commands[id]!.enabled, isFalse, reason: id);
      }
      await key(t, LogicalKeyboardKey.bracketRight, shift: true);
      expect(order(), ['a', 'b', 'c', 'd']);
    });

    testWidgets('bottom, middle and top boxes, and a box that overlaps none', (t) async {
      final s = await pump(t);
      bool on(String id) => s.commands[id]!.enabled;
      c.select('a');
      expect([on(front), on(forward), on(backward), on(back)], [true, true, false, false]);
      c.select('b');
      expect([on(front), on(forward), on(backward), on(back)], [true, true, true, true]);
      c.select('c');
      expect([on(front), on(forward), on(backward), on(back)], [true, false, true, true]);
      // d overlaps nothing: it can go to the ends but not one step.
      c.select('d');
      expect([on(front), on(forward), on(backward), on(back)], [false, false, false, true]);
    });

    testWidgets('the keys and tooltips', (t) async {
      final s = await pump(t);
      expect(find.byTooltip('Bring to front (Ctrl+Shift+])'), findsOneWidget);
      expect(find.byTooltip('Send to back (Ctrl+Shift+[)'), findsOneWidget);
      expect(s.commands[front]!.tooltip, 'Bring to front (Ctrl+Shift+])');
      expect(s.commands[forward]!.tooltip, 'Bring forward (Ctrl+])');
      expect(s.commands[backward]!.tooltip, 'Send backward (Ctrl+[)');
      expect(s.commands[back]!.tooltip, 'Send to back (Ctrl+Shift+[)');
    });
  });

  group('keys on the canvas', () {
    testWidgets('Ctrl+Shift+] and Ctrl+Shift+[ (and Cmd) go to the ends', (t) async {
      await pump(t);
      c.select('a');
      await key(t, LogicalKeyboardKey.bracketRight, shift: true);
      expect(order(), ['b', 'c', 'd', 'a']);
      await key(t, LogicalKeyboardKey.bracketLeft, shift: true);
      expect(order(), ['a', 'b', 'c', 'd']);
      await key(t, LogicalKeyboardKey.bracketRight, ctrl: false, meta: true, shift: true);
      expect(order(), ['b', 'c', 'd', 'a']);
    });

    testWidgets('Ctrl+] and Ctrl+[ step past the next overlapping box', (t) async {
      await pump(t);
      c.select('a');
      await key(t, LogicalKeyboardKey.bracketRight);
      expect(order(), ['b', 'a', 'c', 'd']);
      await key(t, LogicalKeyboardKey.bracketRight);
      expect(order(), ['b', 'a', 'c', 'd'], reason: 'a overlaps nothing above it now');
      await key(t, LogicalKeyboardKey.bracketLeft);
      expect(order(), ['a', 'b', 'c', 'd']);
    });

    testWidgets('Ctrl+] does nothing inside a focused editor', (t) async {
      await pump(t);
      await t.tapAt(await tapPoint(t, const Offset(150, 140)));
      await t.pumpAndSettle();
      expect(c.editingId, 'a');
      await key(t, LogicalKeyboardKey.bracketRight, shift: true);
      expect(order(), ['a', 'b', 'c', 'd']);
    });
  });

  group('undo and the box being edited', () {
    testWidgets('Ctrl+Shift+] then Ctrl+Z restores the order, then redo', (t) async {
      await pump(t);
      c.select('a');
      await key(t, LogicalKeyboardKey.bracketRight, shift: true);
      expect(order(), ['b', 'c', 'd', 'a']);
      expect(saved, hasLength(1), reason: 'a restack is saved like a move');
      await key(t, LogicalKeyboardKey.keyZ);
      expect(order(), ['a', 'b', 'c', 'd']);
      await key(t, LogicalKeyboardKey.keyY);
      expect(order(), ['b', 'c', 'd', 'a']);
    });

    testWidgets('undo after an outside change that added a box', (t) async {
      await pump(t);
      c.select('a');
      await key(t, LogicalKeyboardKey.bracketRight, shift: true);
      c.applyExternal(c.page.insertNode(_box('x', const Bounds(600, 600, 50, 50)), 1));
      expect(order(), ['b', 'x', 'c', 'd', 'a']);
      await key(t, LogicalKeyboardKey.keyZ);
      expect(order(), ['a', 'b', 'x', 'c', 'd']);
    });

    testWidgets('restacking the box being edited keeps its editor and caret', (t) async {
      await pump(t);
      await t.tapAt(await tapPoint(t, const Offset(150, 140)));
      await t.pumpAndSettle();
      expect(c.editingId, 'a');
      final built = editorsBuilt;
      final field = t.widget<TextField>(find.byKey(const ValueKey('field')).first);
      field.controller!.selection = const TextSelection.collapsed(offset: 1);
      expect(c.restack('a', StackMove.front), isTrue);
      await t.pump();
      expect(order(), ['b', 'c', 'd', 'a']);
      expect(editorsBuilt, built, reason: 'the keyed host keeps its state');
      expect(c.editingId, 'a');
      expect(field.controller!.selection.baseOffset, 1);
    });

    testWidgets('a restack that changes nothing records nothing', (t) async {
      await pump(t);
      expect(c.restack('d', StackMove.front), isFalse);
      expect(c.restack('zz', StackMove.front), isFalse);
      expect(c.canUndo, isFalse);
      expect(saved, isEmpty);
    });
  });
}
