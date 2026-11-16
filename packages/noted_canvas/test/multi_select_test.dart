// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Multi-select (UI follow-up, step 8): a transient set on the controller,
// toggled with Ctrl+Shift+click (Cmd+Shift on macOS) or Ctrl+Shift+Space.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

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

int linkOpens = 0;

class _Module extends BoxModule<String> {
  const _Module(this.id, [this.kind = '']);
  final String id;
  final String kind;

  @override
  BoxCodec<String> get codec => _Codec(id);

  @override
  BoxFrameStyle get frameStyle =>
      kind == 'draw' ? BoxFrameStyle.framelessUntilSelected : BoxFrameStyle.framed;

  @override
  bool linkAt(String boxId, Offset global) => kind == 'link';

  Widget _body(BuildContext context, BoxContext<String> box) {
    switch (kind) {
      case 'link':
        // The note's own link handling: Ctrl or Cmd (Shift or not) opens.
        return Listener(
          onPointerDown: (_) {
            final k = HardwareKeyboard.instance;
            if (k.isControlPressed || k.isMetaPressed) linkOpens++;
          },
          child: SizedBox.expand(child: Text(box.data)),
        );
      case 'edit':
        return TextField(controller: TextEditingController(text: box.data), maxLines: null);
      default:
        return Text(box.data);
    }
  }

  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => _body(context, box);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => _body(context, box);
}

BoxRecord _box(String id, String type, Bounds at, String text) => BoxRecord.create(
  id: id,
  typeId: type,
  dataVersion: 1,
  bounds: at,
  data: RawJson.encode(text),
  snapshotText: text,
  rev: 'r-$id',
);

NotedPage _page(List<CanvasNode> nodes) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

const Offset _bar = Offset(0, CommandToolbar.height);

// Apart: a, b (notes), c (drawing), d (a link), e (a text field). Overlapping:
// p and q.
const Bounds _a = Bounds(100, 100, 250, 120);
const Bounds _b = Bounds(450, 100, 250, 120);
const Bounds _c = Bounds(800, 100, 250, 120);
const Bounds _d = Bounds(100, 300, 250, 100);
const Bounds _e = Bounds(450, 300, 250, 100);
const Bounds _p = Bounds(100, 480, 250, 150);
const Bounds _q = Bounds(200, 530, 250, 150);

List<CanvasNode> _nodes() => [
  _box('a', 'test.text', _a, 'alpha'),
  _box('b', 'test.text', _b, 'bravo'),
  _box('c', 'test.draw', _c, 'chart'),
  _box('d', 'test.link', _d, 'delta'),
  _box('e', 'test.edit', _e, 'echo'),
  _box('p', 'test.text', _p, 'papa'),
  _box('q', 'test.text', _q, 'quebec'),
];

Offset _inside(Bounds b) => Offset(b.x + 20, b.y + 40);

void main() {
  late CanvasController c;
  late List<NotedPage> saved;
  late CanvasToolSelection selection;
  late CommandRegistry registry;
  late ModuleRegistry modules;
  var off = <String>{};

  PageCanvasState state(WidgetTester t) => t.state<PageCanvasState>(find.byType(PageCanvas));
  Offset at(WidgetTester t, Offset world) => _bar + state(t).view!.toScreen(world);
  Offset gripOf(WidgetTester t, Bounds b) => at(t, Offset(b.x + 60, b.y - 7));
  List<String> order() => [for (final n in c.page.nodes) n.id];

  Widget buildApp(WidgetTester t, {bool readOnly = false, CanvasController? controller}) => MaterialApp(
    home: Scaffold(
      body: PageCanvas(
        controller: controller ?? c,
        tools: selection,
        readOnly: readOnly,
        attachments: null,
        disallowedTypes: off,
        onCommandsChanged: (r) {
          if (r != null) registry = r;
        },
        boxTypeName: (id) => id == 'test.text' ? 'Note' : null,
        toolbar: const ContextualToolbarLayout(
          leading: [],
          sections: [],
          trailing: [
            [CanvasCommands.select],
          ],
        ),
      ),
    ),
  );

  Future<void> pump(WidgetTester t, {List<CanvasNode>? nodes, bool readOnly = false}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    linkOpens = 0;
    off = {};
    saved = [];
    modules = ModuleRegistry()
      ..register(const _Module('test.text'), isDefault: true)
      ..register(const _Module('test.draw', 'draw'))
      ..register(const _Module('test.link', 'link'))
      ..register(const _Module('test.edit', 'edit'));
    c = CanvasController(_page(nodes ?? _nodes()), modules, onChanged: saved.add);
    selection = CanvasToolSelection();
    addTearDown(selection.dispose);
    await t.pumpWidget(buildApp(t, readOnly: readOnly));
    await t.pump();
    state(t).zoomTo(1);
    await t.pump();
  }


  Future<void> frames(WidgetTester t, [int n = 4]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  /// A primary click at [p] with Ctrl (or [meta]) and Shift held.
  Future<void> multiClick(
    WidgetTester t,
    Offset p, {
    bool meta = false,
    bool ctrl = true,
    bool shift = true,
    bool alt = false,
  }) async {
    if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (meta) await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final g = await t.startGesture(p, kind: PointerDeviceKind.mouse);
    await g.up();
    await g.removePointer();
    if (alt) await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (meta) await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(t);
  }

  Future<void> toggle(WidgetTester t, Bounds b) => multiClick(t, at(t, _inside(b)));

  Future<void> selectTwo(WidgetTester t, [Bounds first = _a, Bounds second = _b]) async {
    await toggle(t, first);
    await toggle(t, second);
  }

  Future<void> key(WidgetTester t, LogicalKeyboardKey k, {bool ctrl = false, bool shift = false}) async {
    if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(k);
    if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(t);
  }

  group('toggling', () {
    testWidgets('Ctrl+Shift+click adds and removes boxes in order; the first click selects', (t) async {
      await pump(t);
      await toggle(t, _a);
      // One box is the ordinary selection.
      expect(c.selectedId, 'a');
      expect(c.multiSelection, isEmpty);
      await toggle(t, _b);
      expect(c.multiSelection, ['a', 'b']);
      expect(c.selectedId, isNull);
      await toggle(t, _c);
      expect(c.multiSelection, ['a', 'b', 'c']);
      await toggle(t, _a);
      expect(c.multiSelection, ['b', 'c']);
      await toggle(t, _c);
      // Back to one: the ordinary selection again.
      expect(c.multiSelection, isEmpty);
      expect(c.selectedId, 'b');
      expect(() => c.multiSelection.add('x'), throwsUnsupportedError);
    });

    testWidgets('nothing is created, saved or put on the undo stack', (t) async {
      await pump(t);
      final before = c.page;
      await selectTwo(t);
      await toggle(t, _c);
      expect(c.multiSelection, hasLength(3));
      expect(identical(c.page, before), isTrue);
      expect(saved, isEmpty);
      expect(c.canUndo, isFalse);
      expect(order(), ['a', 'b', 'c', 'd', 'e', 'p', 'q']);
    });

    testWidgets('a plain click on a box collapses the set to it', (t) async {
      await pump(t);
      await selectTwo(t);
      await t.tapAt(gripOf(t, _c));
      await frames(t);
      expect(c.multiSelection, isEmpty);
      expect(c.selectedId, 'c');
    });

    testWidgets('Escape clears the set first, then the selection', (t) async {
      await pump(t);
      await selectTwo(t);
      await key(t, LogicalKeyboardKey.escape);
      expect(c.multiSelection, isEmpty);
      expect(c.selectedId, isNull);
      expect(saved, isEmpty);
    });

    testWidgets('a blank click clears the set and makes no box', (t) async {
      await pump(t);
      await selectTwo(t);
      await t.tapAt(at(t, const Offset(1000, 600)));
      await frames(t);
      expect(c.multiSelection, isEmpty);
      expect(order(), hasLength(7));
      expect(saved, isEmpty);
    });

    testWidgets('a box that cannot be run or is disallowed is never added', (t) async {
      await pump(t);
      off = {'test.draw'};
      c.disallowedTypes = off;
      await t.pumpWidget(buildApp(t));
      await t.pump();
      expect(c.toggleMulti('c'), isFalse);
      expect(c.toggleMulti('missing'), isFalse);
      expect(c.multiSelection, isEmpty);
    });
  });

  group('pruning', () {
    testWidgets('a read-only flip clears the set', (t) async {
      await pump(t);
      await selectTwo(t);
      c.readOnly = true;
      await t.pump();
      expect(c.multiSelection, isEmpty);
    });

    testWidgets('a box removed from outside leaves the set; one left is the selection', (t) async {
      await pump(t);
      await selectTwo(t);
      await toggle(t, _c);
      c.applyExternal(c.page.removeNode('b'), save: false);
      await t.pump();
      expect(c.multiSelection, ['a', 'c']);
      c.applyExternal(c.page.removeNode('a'), save: false);
      await t.pump();
      expect(c.multiSelection, isEmpty);
      expect(c.selectedId, 'c');
    });

    testWidgets('a box type that becomes disallowed leaves the set', (t) async {
      await pump(t);
      await selectTwo(t);
      await toggle(t, _c);
      off = {'test.draw'};
      c.disallowedTypes = off;
      await t.pumpWidget(buildApp(t));
      await t.pump();
      expect(c.multiSelection, ['a', 'b']);
    });

    testWidgets('a page opened in the canvas starts with no set', (t) async {
      await pump(t);
      await selectTwo(t);
      final other = CanvasController(_page(_nodes()), modules);
      addTearDown(other.dispose);
      await t.pumpWidget(buildApp(t, controller: other));
      await t.pump();
      expect(other.multiSelection, isEmpty);
    });
  });

  group('commands', () {
    testWidgets('with two selected, delete, arrange and paste are off; with one they are on', (t) async {
      await pump(t);
      const ids = [
        CanvasCommands.delete,
        CanvasCommands.bringToFront,
        CanvasCommands.bringForward,
        CanvasCommands.sendBackward,
        CanvasCommands.sendToBack,
      ];
      await toggle(t, _b);
      expect(registry[CanvasCommands.delete]!.enabled, isTrue);
      expect(registry[CanvasCommands.sendToBack]!.enabled, isTrue);
      await toggle(t, _a);
      expect(c.multiSelection, hasLength(2));
      for (final id in ids) {
        expect(registry[id]!.enabled, isFalse, reason: id);
      }
      await toggle(t, _a);
      expect(registry[CanvasCommands.delete]!.enabled, isTrue);
    });

    testWidgets('keyboard shortcuts with two selected write nothing', (t) async {
      await pump(t);
      await selectTwo(t);
      final before = c.page;
      await key(t, LogicalKeyboardKey.delete);
      await key(t, LogicalKeyboardKey.backspace);
      await key(t, LogicalKeyboardKey.bracketRight, ctrl: true);
      await key(t, LogicalKeyboardKey.bracketRight, ctrl: true, shift: true);
      await key(t, LogicalKeyboardKey.bracketLeft, ctrl: true);
      await key(t, LogicalKeyboardKey.bracketLeft, ctrl: true, shift: true);
      await key(t, LogicalKeyboardKey.keyV, ctrl: true);
      expect(identical(c.page, before), isTrue);
      expect(saved, isEmpty);
      expect(c.canUndo, isFalse);
      expect(c.multiSelection, ['a', 'b']);
    });

    testWidgets('members are not moved or resized', (t) async {
      await pump(t);
      await selectTwo(t);
      await t.dragFrom(gripOf(t, _a), const Offset(40, 40));
      await frames(t);
      // The right edge of b, where its resize handle is for a single box.
      await t.dragFrom(at(t, Offset(_b.x + _b.width, _b.y + 60)), const Offset(40, 0));
      await frames(t);
      expect((c.page.node('a')! as BoxRecord).bounds, _a);
      expect((c.page.node('b')! as BoxRecord).bounds, _b);
      expect(saved, isEmpty);
      expect(c.canUndo, isFalse);
      expect(c.multiSelection, ['a', 'b']);
    });
  });

  group('links', () {
    testWidgets('Ctrl+Shift+click on a link opens the link and toggles nothing', (t) async {
      await pump(t);
      await selectTwo(t);
      await toggle(t, _d);
      expect(linkOpens, 1);
      expect(c.multiSelection, ['a', 'b']);
    });

    testWidgets('Alt+click still picks among overlapping boxes with a set', (t) async {
      await pump(t);
      await selectTwo(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      final g = await t.startGesture(at(t, const Offset(250, 600)), kind: PointerDeviceKind.mouse);
      await g.up();
      await g.removePointer();
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await frames(t);
      expect(find.byKey(const ValueKey('box-pick-list')), findsOneWidget);
      expect(c.multiSelection, ['a', 'b']);
      await key(t, LogicalKeyboardKey.escape);
      expect(find.byKey(const ValueKey('box-pick-list')), findsNothing);
      expect(c.multiSelection, ['a', 'b']);
    });
  });

  group('macOS', () {
    testWidgets('Cmd+Shift+click toggles; Ctrl+Shift+click opens the context menu and toggles nothing', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await pump(t);
        await multiClick(t, at(t, _inside(_a)), ctrl: false, meta: true);
        await multiClick(t, at(t, _inside(_b)), ctrl: false, meta: true);
        expect(c.multiSelection, ['a', 'b']);
        // Ctrl+click is the secondary click there.
        await multiClick(t, at(t, _inside(_c)));
        expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
        expect(c.multiSelection, ['a', 'b']);
        await key(t, LogicalKeyboardKey.escape);
        await t.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Cmd+Shift+Space on the chrome toggles; Ctrl+Shift+Space does not', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await pump(t);
        Focus.of(t.element(find.byKey(const ValueKey('box-chrome-a')))).requestFocus();
        await t.pump();
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pump();
        expect(c.selectedId, isNull);
        await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await t.pump();
        expect(c.selectedId, 'a');
        await t.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('editing', () {
    testWidgets('while a box is being edited the toggle is refused and nothing changes', (t) async {
      await pump(t);
      await t.tapAt(at(t, _inside(_e)));
      await frames(t);
      expect(c.editingId, 'e');
      expect(c.selectedId, 'e');
      expect(c.toggleMulti('a'), isFalse);
      expect(c.canToggleMulti('a'), isFalse);
      // The click goes where it goes today: no toggle.
      await toggle(t, _a);
      expect(c.multiSelection, isEmpty);
    });

    testWidgets('the controller never closes the editor to make room', (t) async {
      await pump(t);
      await t.tapAt(at(t, _inside(_e)));
      await frames(t);
      expect(c.editingId, 'e');
      final selected = c.selectedId;
      expect(c.toggleMulti('a'), isFalse);
      expect(c.editingId, 'e');
      expect(c.selectedId, selected);
      expect(c.multiSelection, isEmpty);
    });
  });

  group('context menu', () {
    Future<void> rightClick(WidgetTester t, Offset p) async {
      final g = await t.startGesture(p, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await g.up();
      await g.removePointer();
      await frames(t);
    }

    testWidgets('opening on a member keeps the set; Escape keeps it; activating collapses to the target', (t) async {
      await pump(t);
      await selectTwo(t);
      await rightClick(t, at(t, _inside(_a)));
      expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
      expect(c.multiSelection, ['a', 'b']);
      await key(t, LogicalKeyboardKey.escape);
      expect(find.byKey(const ValueKey('context-menu')), findsNothing);
      expect(c.multiSelection, ['a', 'b']);

      await rightClick(t, at(t, _inside(_a)));
      await t.tap(find.byKey(const ValueKey('context-${CanvasCommands.bringToFront}')));
      await frames(t, 6);
      expect(c.multiSelection, isEmpty);
      expect(c.selectedId, 'a');
      expect(order().last, 'a');
    });
  });

  group('outlines', () {
    testWidgets('members get a 2 px accent outline, a drawing a dashed 6/4 one, and no handles', (t) async {
      await pump(t);
      await toggle(t, _a);
      await toggle(t, _c);
      expect(c.multiSelection, ['a', 'c']);
      final scheme = Theme.of(t.element(find.byType(PageCanvas))).colorScheme;
      Finder inBox(String id, String key) =>
          find.descendant(of: find.byKey(ValueKey(id)), matching: find.byKey(ValueKey(key)));
      final border = t.widget<DecoratedBox>(inBox('a', 'box-frame-border')).decoration as BoxDecoration;
      expect(border.border!.top.width, 2);
      expect(border.border!.top.color, scheme.primary);
      final dashed = t.widget<CustomPaint>(inBox('c', 'box-frame-dashed')).painter! as DashedOutlinePainter;
      expect((dashed.strokeWidth, dashed.dash, dashed.gap), (2.0, 6.0, 4.0));
      expect(find.byKey(const ValueKey('box-handle-left')), findsNothing);
      expect(find.byKey(const ValueKey('box-handle-bottomRight')), findsNothing);
      // A box that is not a member keeps its 1 px border.
      final other = t.widget<DecoratedBox>(inBox('b', 'box-frame-border')).decoration as BoxDecoration;
      expect(other.border!.top.width, 1);
    });
  });

  group('keyboard', () {
    testWidgets('Ctrl+Shift+Space on the focused chrome toggles, and the count is announced', (t) async {
      final handle = t.ensureSemantics();
      await pump(t);
      Future<void> space(String id) async {
        Focus.of(t.element(find.byKey(ValueKey('box-chrome-$id')))).requestFocus();
        await t.pump();
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await frames(t);
      }

      await space('a');
      expect(c.selectedId, 'a');
      await space('b');
      expect(c.multiSelection, ['a', 'b']);
      await t.pump();
      expect(find.bySemanticsLabel('2 boxes selected'), findsOneWidget);
      await space('c');
      expect(c.multiSelection, ['a', 'b', 'c']);
      expect(find.bySemanticsLabel('3 boxes selected'), findsOneWidget);
      await space('a');
      expect(c.multiSelection, ['b', 'c']);
      expect(saved, isEmpty);
      handle.dispose();
    });
  });
}
