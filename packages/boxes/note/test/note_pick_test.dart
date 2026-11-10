// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Picking among overlapping notes (Alt+click, a touch hold) and links
// (decisions 0024, 0099, 0129): the note module answers `linkAt` (Box API
// 0.15) so an Alt+click on a link is a plain click.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const _codec = NoteCodec();

BoxRecord _note(String id, String text, Bounds at, {String? href}) {
  final data = NoteData({
    'document': {
      'type': 'page',
      'children': [
        {
          'type': 'paragraph',
          'data': {
            'delta': [
              {
                'insert': text,
                if (href != null) 'attributes': {'href': href},
              },
            ],
          },
        },
      ],
    },
  });
  return BoxRecord.create(
    id: id,
    typeId: NoteCodec.id,
    dataVersion: 1,
    bounds: at,
    data: RawJson.encode(_codec.encode(data)),
    snapshotText: _codec.snapshotText(data),
    rev: 'r-$id',
  );
}

void main() {
  late CanvasController c;
  late List<String> opened;
  const bar = Offset(0, CommandToolbar.height);

  PageCanvasState canvas(WidgetTester t) => t.state<PageCanvasState>(find.byType(PageCanvas));
  Offset at(WidgetTester t, Offset world) => bar + canvas(t).view!.toScreen(world);
  Finder list() => find.byKey(const ValueKey('box-pick-list'));

  Future<void> frames(WidgetTester t, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester t, List<BoxRecord> notes) async {
    t.view.physicalSize = const Size(1600, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    opened = [];
    final before = linkOpener;
    linkOpener = (url) async => opened.add(url);
    addTearDown(() => linkOpener = before);
    final modules = ModuleRegistry()..register(const NoteModule(), alwaysOn: true, isDefault: true);
    var page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    for (final n in notes) {
      page = page.insertNode(n);
    }
    c = CanvasController(page, modules);
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
    await t.pumpAndSettle();
    canvas(t).zoomTo(1);
    await t.pump();
  }

  Future<void> altClick(WidgetTester t, Offset p, {bool ctrl = false}) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final g = await t.startGesture(p, kind: PointerDeviceKind.mouse);
    await g.up();
    await g.removePointer();
    if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await frames(t);
  }

  Future<void> ctrlClick(WidgetTester t, Offset p) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final g = await t.startGesture(p, kind: PointerDeviceKind.mouse);
    await g.up();
    await g.removePointer();
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(t);
  }

  const near = Bounds(100, 100, 400, 40);
  final linkPoint = const Offset(130, 114);

  group('links', () {
    testWidgets('Ctrl+click on a link in the light view opens it and no list', (t) async {
      await pump(t, [_note('n', 'linked words here', near, href: 'https://open.example')]);
      await ctrlClick(t, at(t, linkPoint));
      expect(opened, ['https://open.example']);
      expect(list(), findsNothing);
      expect(c.editingId, isNull);
    });

    testWidgets('Ctrl+click on a link in the editor opens it and no list', (t) async {
      await pump(t, [_note('n', 'linked words here', near, href: 'https://open.example')]);
      await t.tapAt(at(t, const Offset(300, 114)));
      await frames(t);
      expect(c.editingId, 'n');
      await ctrlClick(t, at(t, linkPoint));
      expect(opened, ['https://open.example']);
      expect(list(), findsNothing);
    });

    testWidgets('Alt+click on a link in the light view is a plain click: the caret is placed', (t) async {
      await pump(t, [_note('n', 'linked words here', near, href: 'https://open.example')]);
      await altClick(t, at(t, linkPoint));
      expect(list(), findsNothing);
      expect(opened, isEmpty);
      expect(c.editingId, 'n');
    });

    testWidgets('Alt+click on a link in the editor opens no list', (t) async {
      await pump(t, [_note('n', 'linked words here', near, href: 'https://open.example')]);
      await t.tapAt(at(t, const Offset(300, 114)));
      await frames(t);
      await altClick(t, at(t, linkPoint));
      // As a plain click on a link in the editor does: no list, nothing opened.
      expect(list(), findsNothing);
      expect(opened, isEmpty);
      expect(c.selectedId, 'n');
    });

    testWidgets('Alt+click over a link in a covered note opens the list', (t) async {
      await pump(t, [
        _note('under', 'linked words here', near, href: 'https://open.example'),
        _note('over', 'plain words on top', const Bounds(110, 100, 300, 40)),
      ]);
      await altClick(t, at(t, linkPoint));
      expect(list(), findsOneWidget);
      expect(find.descendant(of: list(), matching: find.byKey(const ValueKey('pick-row-over'))), findsOneWidget);
      expect(find.descendant(of: list(), matching: find.byKey(const ValueKey('pick-row-under'))), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('Alt+click in a mounted editor opens the list and keeps the caret', (t) async {
      await pump(t, [_note('n', 'linked words here', near)]);
      await t.tapAt(at(t, const Offset(300, 114)));
      await frames(t);
      expect(c.editingId, 'n');
      final editor = t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
      final caret = editor.selection;
      expect(caret, isNotNull);
      await altClick(t, at(t, const Offset(150, 114)));
      expect(list(), findsOneWidget);
      // The list took the focus, so the editor let go of its selection; the
      // click did not put the caret where it landed.
      expect(editor.selection == null || editor.selection == caret, isTrue);
    });
  });

  group('links in an edited note at other zooms', () {
    // Four paragraphs; the last has plain words and then a link at its end.
    BoxRecord multi() {
      Map<String, Object?> para(List<Map<String, Object?>> delta) => {
        'type': 'paragraph',
        'data': {'delta': delta},
      };
      final data = NoteData({
        'document': {
          'type': 'page',
          'children': [
            para([
              {'insert': 'first'},
            ]),
            para([
              {'insert': 'second'},
            ]),
            para([
              {'insert': 'third'},
            ]),
            para([
              {'insert': 'some plain words before '},
              {
                'insert': 'https://link.example',
                'attributes': {'href': 'https://link.example'},
              },
            ]),
          ],
        },
      });
      return BoxRecord.create(
        id: 'n',
        typeId: NoteCodec.id,
        dataVersion: 1,
        bounds: const Bounds(700, 300, 420, 160),
        data: RawJson.encode(_codec.encode(data)),
        snapshotText: _codec.snapshotText(data),
        rev: 'r',
      );
    }

    // The link's rectangle on screen, from the editor's own layout.
    Rect linkRect(WidgetTester t) {
      final editor = t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
      final selectable = editor.document.nodeAtPath([3])!.selectable!;
      final text = editor.document.nodeAtPath([3])!.delta!.toPlainText();
      final start = text.indexOf('https');
      final rects = selectable.getRectsInSelection(
        Selection(
          start: Position(path: [3], offset: start),
          end: Position(path: [3], offset: text.length),
        ),
        shiftWithBaseOffset: true,
      );
      final r = rects.single;
      return Rect.fromPoints(
        selectable.localToGlobal(r.topLeft, shiftWithBaseOffset: true),
        selectable.localToGlobal(r.bottomRight, shiftWithBaseOffset: true),
      );
    }

    for (final zoom in [1.0, 1.5, 2.0]) {
      testWidgets('at ${(zoom * 100).round()}%: Alt+click on a link low and to the right is a plain click', (t) async {
        await pump(t, [multi()]);
        canvas(t).fitAll();
        await t.pump();
        canvas(t).zoomTo(zoom);
        await t.pump();
        await t.tapAt(at(t, const Offset(800, 316)));
        await frames(t);
        expect(c.editingId, 'n');
        final r = linkRect(t);
        await altClick(t, r.center);
        expect(list(), findsNothing, reason: 'link at ${r.center}');
        expect(opened, isEmpty);
      });
    }

    for (final zoom in [1.5, 2.0]) {
      testWidgets('at ${(zoom * 100).round()}%: Alt+click right of a line-ending link opens the list', (t) async {
        await pump(t, [multi()]);
        canvas(t).fitAll();
        await t.pump();
        canvas(t).zoomTo(zoom);
        await t.pump();
        await t.tapAt(at(t, const Offset(800, 316)));
        await frames(t);
        expect(c.editingId, 'n');
        final r = linkRect(t);
        await altClick(t, Offset(r.right + 24, r.center.dy));
        expect(list(), findsOneWidget);
      });
    }
    for (final zoom in [1.0, 2.0]) {
      testWidgets('at ${(zoom * 100).round()}%: a to-do item ending with a link is hit on the glyphs the paragraph draws', (t) async {
        final data = NoteData({
          'document': {
            'type': 'page',
            'children': [
              {
                'type': 'todo_list',
                'data': {
                  'checked': false,
                  'delta': [
                    {'insert': 'item '},
                    {
                      'insert': 'https://link.example',
                      'attributes': {'href': 'https://link.example'},
                    },
                  ],
                },
              },
            ],
          },
        });
        final todo = BoxRecord.create(
          id: 'n',
          typeId: NoteCodec.id,
          dataVersion: 1,
          bounds: const Bounds(700, 300, 420, 160),
          data: RawJson.encode(_codec.encode(data)),
          snapshotText: _codec.snapshotText(data),
          rev: 'r',
        );
        await pump(t, [todo]);
        canvas(t).fitAll();
        await t.pump();
        canvas(t).zoomTo(zoom);
        await t.pump();
        await t.tapAt(at(t, const Offset(900, 316)));
        await frames(t);
        expect(c.editingId, 'n');
        // The link's box, from the paragraph that draws it.
        final para = find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('https://link.example'),
        );
        final render = t.renderObject<RenderParagraph>(para.first);
        final boxes = render.getBoxesForSelection(const TextSelection(baseOffset: 5, extentOffset: 25));
        expect(boxes, isNotEmpty);
        final rect = boxes
            .map((b) => Rect.fromPoints(render.localToGlobal(b.toRect().topLeft), render.localToGlobal(b.toRect().bottomRight)))
            .reduce((a, b) => a.expandToInclude(b));
        await altClick(t, Offset(rect.left + 4, rect.center.dy));
        expect(list(), findsNothing, reason: 'on the first glyphs of the link');
        await altClick(t, Offset(rect.right - 4, rect.center.dy));
        expect(list(), findsNothing, reason: 'on the last glyphs of the link');
        await altClick(t, Offset(rect.right + 12, rect.center.dy));
        expect(list(), findsOneWidget, reason: 'beside the link');
      });
    }

  });

  group('touch', () {
    testWidgets('a hold on a light-view note opens the list and places no caret', (t) async {
      await pump(t, [_note('n', 'plain words here', near)]);
      final g = await t.startGesture(at(t, const Offset(150, 114)), kind: PointerDeviceKind.touch);
      await t.pump(const Duration(milliseconds: 600));
      await g.up();
      await frames(t);
      expect(list(), findsOneWidget);
      expect(c.editingId, isNull);
      expect(c.selectedId, isNull);
    });

    testWidgets('a short tap on the light view still places the caret', (t) async {
      await pump(t, [_note('n', 'plain words here', near)]);
      await t.tapAt(at(t, const Offset(150, 114)));
      await frames(t);
      expect(list(), findsNothing);
      expect(c.editingId, 'n');
    });

    testWidgets('a hold in the editor being edited keeps the selection on a desktop platform', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pump(t, [_note('n', 'plain words here', near)]);
      await t.tapAt(at(t, const Offset(150, 114)));
      await frames(t);
      expect(c.editingId, 'n');
      final editor = t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
      final g = await t.startGesture(at(t, const Offset(220, 114)), kind: PointerDeviceKind.touch);
      await t.pump(const Duration(milliseconds: 600));
      await g.up();
      await frames(t);
      expect(list(), findsNothing);
      expect(c.editingId, 'n');
      expect(editor.selection, isNotNull);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('read-only', () {
    testWidgets('a slow tap on a link on a read-only page still opens it', (t) async {
      t.view.physicalSize = const Size(1600, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final opened = <String>[];
      final before = linkOpener;
      linkOpener = (url) async => opened.add(url);
      addTearDown(() => linkOpener = before);
      final modules = ModuleRegistry()..register(const NoteModule(), alwaysOn: true, isDefault: true);
      final page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0))
          .insertNode(_note('n', 'linked words here', near, href: 'https://open.example'));
      final ro = CanvasController(page, modules, readOnly: true);
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: noteLocalizationsDelegates,
          home: Scaffold(body: PageCanvas(controller: ro)),
        ),
      );
      await t.pumpAndSettle();
      final s = t.state<PageCanvasState>(find.byType(PageCanvas));
      s.zoomTo(1);
      await t.pump();
      final g = await t.startGesture(bar + s.view!.toScreen(linkPoint), kind: PointerDeviceKind.touch);
      await t.pump(const Duration(milliseconds: 600));
      await g.up();
      await frames(t);
      expect(opened, ['https://open.example']);
      expect(list(), findsNothing);
    });
  });
}
