// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The list of boxes under a point (Alt+click, a touch hold) and the layering
// it offers (0024, 0129, 0130).

import 'dart:async';

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

/// Pen and eraser, for a stylus.
class _Tool extends CanvasTool {
  _Tool(this.id, this.stylusRole);
  @override
  final String id;
  @override
  final StylusRole stylusRole;
  int started = 0;
  @override
  String get label => id;
  @override
  IconData get icon => Icons.edit;
  @override
  ToolSession? start(ToolContext context, ToolPointer pointer) {
    started++;
    return _Session();
  }
}

class _Session extends ToolSession {
  @override
  void update(ToolPointer pointer) {}
  @override
  void end() {}
  @override
  void cancel() {}
  @override
  void paint(Canvas canvas, double scale) {}
}

int taps = 0;
int longPresses = 0;
bool linkHere = false;

class _Module extends BoxModule<String> {
  const _Module(this.id, [this.kind = '']);
  final String id;
  final String kind;

  @override
  BoxCodec<String> get codec => _Codec(id);

  @override
  bool linkAt(String boxId, Offset global) => kind == 'link' && linkHere;

  Widget _body(BuildContext context, BoxContext<String> box) {
    switch (kind) {
      case 'tap':
        // Like a to-do checkbox: a tap target inside the box.
        return Center(
          child: GestureDetector(
            key: const ValueKey('checkbox'),
            onTap: () => taps++,
            child: const SizedBox(width: 60, height: 40, child: ColoredBox(color: Colors.blue)),
          ),
        );
      case 'long':
        // A module with a long-press of its own.
        return RawGestureDetector(
          gestures: {
            LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              LongPressGestureRecognizer.new,
              (r) => r.onLongPress = () => longPresses++,
            ),
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

class _DrawModule extends _Module {
  _DrawModule(this.tools) : super('test.draw');
  @override
  final List<CanvasTool> tools;
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

const Offset bar = Offset(0, CommandToolbar.height);

/// Three boxes stacked up on each other, a at the bottom: every one contains
/// the page point (250, 250).
const Bounds _ba = Bounds(100, 100, 300, 200);
const Bounds _bb = Bounds(150, 150, 300, 200);
const Bounds _bc = Bounds(200, 200, 300, 200);
const Offset _point = Offset(250, 250);

NotedPage _page(List<CanvasNode> nodes) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

void main() {
  late CanvasController c;
  late List<NotedPage> saved;
  late CanvasToolSelection selection;
  late _Tool pen;
  late _Tool eraser;

  PageCanvasState state(WidgetTester t) => t.state<PageCanvasState>(find.byType(PageCanvas));
  CanvasView view(WidgetTester t) => state(t).view!;
  Offset at(WidgetTester t, Offset world) => bar + view(t).toScreen(world);
  List<String> order() => [for (final n in c.page.nodes) n.id];

  Future<void> pump(
    WidgetTester t, {
    NotedPage? page,
    bool readOnly = false,
    bool withPen = false,
  }) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    taps = 0;
    longPresses = 0;
    linkHere = false;
    saved = [];
    pen = _Tool('draw.pen', StylusRole.pen);
    eraser = _Tool('draw.eraser', StylusRole.eraser);
    final modules = ModuleRegistry()
      ..register(const _Module('test.text'), isDefault: true)
      ..register(const _Module('test.tap', 'tap'))
      ..register(const _Module('test.long', 'long'))
      ..register(const _Module('test.link', 'link'))
      ..register(const _Module('test.edit', 'edit'))
      ..register(_DrawModule(withPen ? [pen, eraser] : const []));
    c = CanvasController(
      page ??
          _page([
            _box('a', 'test.text', _ba, 'alpha words'),
            _box('b', 'test.text', _bb, 'bravo words'),
            _box('c', 'test.text', _bc, 'charlie words'),
          ]),
      modules,
      onChanged: saved.add,
    );
    selection = CanvasToolSelection();
    addTearDown(selection.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(
            controller: c,
            tools: selection,
            readOnly: readOnly,
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
      ),
    );
    await t.pump();
    state(t).zoomTo(1);
    await t.pump();
  }

  /// A mouse click at [p] with Alt held, then released.
  Future<void> altClick(WidgetTester t, Offset p) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final g = await t.startGesture(p, kind: PointerDeviceKind.mouse);
    await g.up();
    await g.removePointer();
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await t.pump();
  }

  Finder row(String id) => find.byKey(ValueKey('pick-row-$id'));
  Finder list() => find.byKey(const ValueKey('box-pick-list'));
  List<String> rowIds(WidgetTester t) {
    final ids = [
      for (final e in t.widgetList<GestureDetector>(find.byWidgetPredicate(
        (w) => w is GestureDetector && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('pick-row-'),
      )))
        (e.key! as ValueKey<String>).value.substring('pick-row-'.length),
    ];
    return ids;
  }

  Future<TestGesture> hold(
    WidgetTester t,
    Offset p, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
    int pointer = 1,
    Duration time = const Duration(milliseconds: 600),
  }) async {
    final g = await t.startGesture(p, kind: kind, pointer: pointer);
    await t.pump(time);
    return g;
  }

  group('opening with Alt+click', () {
    testWidgets('lists the boxes under the point, topmost first, with type and words', (t) async {
      await pump(t);
      await altClick(t, at(t, _point));
      expect(list(), findsOneWidget);
      expect(rowIds(t), ['c', 'b', 'a']);
      expect(find.text('Note · charlie words'), findsOneWidget);
      expect(find.text('Note · bravo words'), findsOneWidget);
      expect(find.text('Note · alpha words'), findsOneWidget);
      // Nothing was selected or made by the click.
      expect(c.selectedId, isNull);
      expect(c.page.nodes, hasLength(3));
      // Only the boxes under the point: a point inside a alone lists a alone.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await altClick(t, at(t, const Offset(120, 120)));
      expect(rowIds(t), ['a']);
    });

    testWidgets('an encrypted box shows its type only; an unsupported one its snapshot', (t) async {
      final enc = _box('e', 'noted.encrypted.note', const Bounds(100, 100, 300, 200), 'secret words');
      final alien = _box('u', 'vendor.alien', const Bounds(150, 150, 300, 200), 'alien snapshot');
      final foreign = ForeignNode.read(
        const RawJson.trusted('{"id":"g","type":"text","x":200,"y":200,"width":300,"height":200,"text":"canvas  text\\nhere"}'),
        fallbackId: 'g',
      );
      await pump(t, page: _page([enc, alien, foreign]));
      await altClick(t, at(t, _point));
      expect(find.text('Encrypted box'), findsOneWidget);
      expect(find.descendant(of: list(), matching: find.textContaining('secret')), findsNothing);
      expect(find.text('Unsupported box · alien snapshot'), findsOneWidget);
      expect(find.text('Not a Noted box · canvas text here'), findsOneWidget);
    });

    testWidgets('long words are cut at 60 characters', (t) async {
      final long = 'x' * 100;
      await pump(t, page: _page([_box('a', 'test.text', _ba, long)]));
      await altClick(t, at(t, _point));
      expect(find.text('Note · ${'x' * 60}…'), findsOneWidget);
    });

    testWidgets('hover and the arrow keys move the highlight, and the outline', (t) async {
      await pump(t);
      await altClick(t, at(t, _point));
      final overlay = find.descendant(of: find.byKey(PageCanvas.pickOverlayKey), matching: find.byType(CustomPaint));
      expect(state(t).pickHighlightId, isNull);
      expect(t.renderObject(overlay.first), isNot(paints..path()));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(state(t).pickHighlightId, 'c');
      expect(t.renderObject(overlay.first), paints..path()..rrect());
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(state(t).pickHighlightId, 'b');
      await t.sendKeyEvent(LogicalKeyboardKey.end);
      expect(state(t).pickHighlightId, 'a');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(state(t).pickHighlightId, 'b');
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      expect(state(t).pickHighlightId, 'c');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(row('a')));
      await mouse.moveTo(t.getCenter(row('a')) + const Offset(1, 1));
      await t.pump();
      expect(state(t).pickHighlightId, 'a');
      await mouse.removePointer();
    });

    testWidgets('a click selects the row\'s box, closes the list and focuses the canvas', (t) async {
      await pump(t);
      await altClick(t, at(t, _point));
      final g = await t.startGesture(t.getCenter(row('a')) - const Offset(40, 0), kind: PointerDeviceKind.mouse);
      await g.up();
      await t.pumpAndSettle();
      expect(list(), findsNothing);
      expect(c.selectedId, 'a');
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas');
      expect(state(t).pickHighlightId, isNull);
    });

    testWidgets('Enter selects the highlighted row', (t) async {
      await pump(t);
      await altClick(t, at(t, _point));
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(list(), findsOneWidget, reason: 'nothing is highlighted yet');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(list(), findsNothing);
      expect(c.selectedId, 'b');
      // The canvas has the keys now: Delete acts on the box.
      await t.sendKeyEvent(LogicalKeyboardKey.delete);
      expect(c.page.node('b'), isNull);
    });

    testWidgets('Escape changes nothing and focuses the canvas', (t) async {
      await pump(t);
      c.select('b');
      final before = c.page;
      await altClick(t, at(t, _point));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(list(), findsNothing);
      expect(identical(c.page, before), isTrue);
      expect(c.selectedId, 'b');
      expect(saved, isEmpty);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas');
    });

    testWidgets('Escape while a note was being edited: it has left its editor, nothing else changed', (t) async {
      await pump(
        t,
        page: _page([
          _box('a', 'test.edit', _ba, 'alpha'),
          _box('c', 'test.text', _bc, 'charlie'),
        ]),
      );
      await t.tapAt(at(t, const Offset(120, 250)));
      await t.pumpAndSettle();
      expect(c.editingId, 'a');
      final before = c.page;
      await altClick(t, at(t, _point));
      expect(list(), findsOneWidget);
      expect(c.editingId, isNull);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(identical(c.page, before), isTrue);
      expect(order(), ['a', 'c']);
    });

    testWidgets('a row\'s Bring to front reorders the page and re-sorts the list', (t) async {
      await pump(t);
      await altClick(t, at(t, _point));
      await t.tap(find.byKey(const ValueKey('pick-front-a')));
      await t.pump();
      expect(order(), ['b', 'c', 'a']);
      expect(rowIds(t), ['a', 'c', 'b']);
      expect(list(), findsOneWidget);
      // The button of a box already on top is off; Send to back puts it down.
      expect(t.widget<IconButton>(find.byKey(const ValueKey('pick-front-a'))).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('pick-back-a')));
      await t.pump();
      expect(order(), ['a', 'b', 'c']);
      expect(saved, hasLength(2));
    });

    testWidgets('a row button acts on its row, not the selection', (t) async {
      await pump(t);
      c.select('c');
      await altClick(t, at(t, _point));
      await t.tap(find.byKey(const ValueKey('pick-back-b')));
      await t.pump();
      expect(order(), ['b', 'a', 'c']);
      expect(c.selectedId, 'c');
    });

    testWidgets('a node with no id of its own lists with no buttons', (t) async {
      final page = readPage(
        '{"nodes":[{"type":"group","x":100,"y":100,"width":300,"height":200,"label":"g"},'
        '{"id":"a","type":"group","x":150,"y":150,"width":300,"height":200}],"edges":[],'
        '"noted":{"format":1,"pageId":"p","parentId":null,"title":"T","order":0}}',
      );
      await pump(t, page: page);
      await altClick(t, at(t, _point));
      expect(rowIds(t), ['a', '#node0']);
      expect(find.byKey(const ValueKey('pick-front-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-front-#node0')), findsNothing);
      expect(find.byKey(const ValueKey('pick-back-#node0')), findsNothing);
    });

    testWidgets('a box taken away by an outside change drops its row', (t) async {
      await pump(t);
      await altClick(t, at(t, _point));
      c.applyExternal(c.page.removeNode('b'));
      await t.pump();
      expect(rowIds(t), ['c', 'a']);
      expect(list(), findsOneWidget);
    });

    testWidgets('an Alt+drag on the grip does not move the box', (t) async {
      await pump(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      final grip = at(t, const Offset(250, 100 - boxGripHeight / 2 + 0.5));
      final g = await t.startGesture(grip, kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(80, 0));
      await g.up();
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.pumpAndSettle();
      expect(c.page.node('a')!.bounds, _ba);
      expect(list(), findsNothing);
    });

    testWidgets('a plain click and a Ctrl+Alt click open no list', (t) async {
      await pump(t);
      final g = await t.startGesture(at(t, _point), kind: PointerDeviceKind.mouse);
      await g.up();
      await t.pump();
      expect(list(), findsNothing);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await altClick(t, at(t, _point));
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(list(), findsNothing);
    });

    testWidgets('read-only and empty canvas open nothing and create no box', (t) async {
      await pump(t, readOnly: true);
      await altClick(t, at(t, _point));
      expect(list(), findsNothing);
      await t.pumpWidget(const SizedBox());
      await pump(t);
      await altClick(t, at(t, const Offset(700, 500)));
      expect(list(), findsNothing);
      expect(c.page.nodes, hasLength(3));
    });

    testWidgets('with the pen the Alt+click inks', (t) async {
      await pump(t, withPen: true);
      selection.select(pen);
      await t.pump();
      await altClick(t, at(t, _point));
      expect(list(), findsNothing);
      expect(pen.started, 1);
    });

    testWidgets('Alt+click on a link opens no list; over a link in a covered note it does', (t) async {
      await pump(
        t,
        page: _page([
          _box('a', 'test.text', _ba, 'alpha'),
          _box('l', 'test.link', _bb, 'link'),
        ]),
      );
      linkHere = true;
      await altClick(t, at(t, _point));
      expect(list(), findsNothing, reason: 'the topmost box has a link there');
      await t.pumpWidget(const SizedBox());
      await pump(
        t,
        page: _page([
          _box('l', 'test.link', _ba, 'link'),
          _box('b', 'test.text', _bb, 'bravo'),
        ]),
      );
      linkHere = true;
      await altClick(t, at(t, _point));
      expect(rowIds(t), ['b', 'l'], reason: 'only the topmost box is asked');
    });
  });

  group('opening with a touch hold', () {
    testWidgets('hold and release lists the boxes; a tap highlights, a second tap selects', (t) async {
      await pump(t);
      final g = await hold(t, at(t, _point));
      expect(list(), findsNothing);
      await g.up();
      await t.pump();
      expect(rowIds(t), ['c', 'b', 'a']);
      expect(c.selectedId, isNull);
      await t.tap(row('b'));
      await t.pump();
      expect(state(t).pickHighlightId, 'b');
      expect(list(), findsOneWidget);
      await t.tap(row('b'));
      await t.pumpAndSettle();
      expect(list(), findsNothing);
      expect(c.selectedId, 'b');
    });

    testWidgets('a short press is a tap as before', (t) async {
      await pump(t);
      final g = await hold(t, at(t, _point), time: const Duration(milliseconds: 100));
      await g.up();
      await t.pump();
      expect(list(), findsNothing);
    });

    testWidgets('a hold on a to-do-like tap target opens the list and does not toggle it', (t) async {
      await pump(t, page: _page([_box('a', 'test.tap', _ba, '')]));
      final centre = at(t, const Offset(250, 200));
      var g = await t.startGesture(centre, kind: PointerDeviceKind.touch);
      await g.up();
      await t.pump();
      expect(taps, 1, reason: 'a quick tap toggles');
      g = await hold(t, centre);
      await g.up();
      await t.pump();
      expect(taps, 1);
      expect(rowIds(t), ['a']);
    });

    testWidgets('a hold on a light-view style box with a tap of its own places nothing', (t) async {
      await pump(t, page: _page([_box('a', 'test.tap', _ba, '')]));
      final g = await hold(t, at(t, const Offset(250, 200)));
      await g.up();
      await t.pump();
      expect(c.selectedId, isNull);
      expect(c.editingId, isNull);
    });

    testWidgets('a hold on the grip, then a move, moves the box and opens no list', (t) async {
      await pump(t);
      final g = await hold(t, at(t, const Offset(300, 100 - boxGripHeight / 2 + 0.5)));
      await g.moveBy(const Offset(60, 0));
      await g.up();
      await t.pumpAndSettle();
      expect(c.page.node('a')!.bounds!.x, closeTo(160, 1));
      expect(list(), findsNothing);
    });

    testWidgets('a hold on a handle, then a move, resizes and opens no list', (t) async {
      await pump(t);
      // The right edge of a, below the others' reach.
      final g = await hold(t, at(t, const Offset(400, 110)));
      await g.moveBy(const Offset(40, 0));
      await g.up();
      await t.pumpAndSettle();
      expect(c.page.node('a')!.bounds!.width, closeTo(340, 1));
      expect(list(), findsNothing);
    });

    testWidgets('a hold, a 200 px grip drag and a drag back moves the box and opens no list', (t) async {
      await pump(t);
      final g = await hold(t, at(t, const Offset(300, 100 - boxGripHeight / 2 + 0.5)));
      await g.moveBy(const Offset(200, 0));
      await g.moveBy(const Offset(-200, 0));
      await g.up();
      await t.pumpAndSettle();
      expect(list(), findsNothing);
      expect(c.page.node('a')!.bounds!.x, closeTo(100, 1));
    });

    testWidgets('a hold on empty canvas creates a note as today', (t) async {
      await pump(t);
      final g = await hold(t, at(t, const Offset(800, 600)));
      await g.up();
      await t.pumpAndSettle();
      expect(list(), findsNothing);
      expect(c.page.nodes, hasLength(4));
    });

    testWidgets('a box with a long-press of its own keeps it and opens no list', (t) async {
      await pump(t, page: _page([_box('a', 'test.long', _ba, 'press me')]));
      final g = await hold(t, at(t, const Offset(250, 200)));
      await g.up();
      await t.pump();
      expect(longPresses, 1);
      expect(list(), findsNothing);
    });

    testWidgets('a stylus long-press inks', (t) async {
      await pump(t, withPen: true);
      final g = await hold(t, at(t, _point), kind: PointerDeviceKind.stylus);
      await g.up();
      await t.pump();
      expect(pen.started, 1);
      expect(list(), findsNothing);
    });

    testWidgets('read-only and a tool in use take no hold', (t) async {
      await pump(t, readOnly: true);
      var g = await hold(t, at(t, _point));
      await g.up();
      await t.pump();
      expect(list(), findsNothing);
      await t.pumpWidget(const SizedBox());
      await pump(t, withPen: true);
      selection.select(pen);
      await t.pump();
      g = await hold(t, at(t, _point));
      await g.up();
      await t.pump();
      expect(list(), findsNothing);
    });

    testWidgets('a hold in the box being edited keeps the caret on a desktop platform', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pump(t, page: _page([_box('a', 'test.edit', _ba, 'alpha')]));
      await t.tapAt(at(t, const Offset(150, 150)));
      await t.pumpAndSettle();
      expect(c.editingId, 'a');
      final g = await hold(t, at(t, const Offset(150, 150)));
      await g.up();
      await t.pumpAndSettle();
      expect(list(), findsNothing);
      expect(c.editingId, 'a');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a hold on a text field keeps its own press and opens no list', (t) async {
      // The limit: a TextField (a sticky label, an image caption) keeps its
      // touch long-press. The workaround is to select the box and Send to
      // back.
      await pump(t, page: _page([_box('a', 'test.edit', _ba, 'alpha')]));
      final g = await hold(t, at(t, const Offset(150, 150)));
      await g.up();
      await t.pumpAndSettle();
      expect(list(), findsNothing);
    });
  });

  group('palms, pens and a second finger', () {
    testWidgets('palm down, pen writes, palm lifts: no list', (t) async {
      await pump(t, withPen: true);
      final palm = await hold(t, at(t, _point));
      final stylus = await t.startGesture(at(t, const Offset(700, 500)), kind: PointerDeviceKind.stylus, pointer: 2);
      await stylus.moveBy(const Offset(40, 0));
      await t.pump(const Duration(milliseconds: 600));
      await stylus.up();
      await palm.up();
      await t.pumpAndSettle();
      expect(pen.started, 1);
      expect(list(), findsNothing);
    });

    testWidgets('a palm that lands while the pen writes and is held: no list', (t) async {
      await pump(t, withPen: true);
      final stylus = await t.startGesture(at(t, const Offset(700, 500)), kind: PointerDeviceKind.stylus, pointer: 2);
      final palm = await hold(t, at(t, _point));
      await palm.up();
      await t.pump();
      await stylus.up();
      await t.pumpAndSettle();
      expect(pen.started, 1);
      expect(list(), findsNothing);
    });

    testWidgets('a palm held while a stylus taps with drawing off: no list', (t) async {
      await pump(t);
      final palm = await hold(t, at(t, _point));
      final stylus = await t.startGesture(at(t, const Offset(700, 500)), kind: PointerDeviceKind.stylus, pointer: 2);
      await stylus.up();
      await palm.up();
      await t.pumpAndSettle();
      expect(list(), findsNothing);
    });

    testWidgets('hold, then a second finger pinches: no list', (t) async {
      await pump(t);
      final a = await hold(t, at(t, _point));
      final b = await t.startGesture(at(t, const Offset(700, 500)), kind: PointerDeviceKind.touch, pointer: 2);
      await b.moveBy(const Offset(30, 0));
      await b.up();
      await a.up();
      await t.pumpAndSettle();
      expect(list(), findsNothing);
    });
  });
}
