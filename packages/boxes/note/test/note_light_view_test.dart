// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_note/src/note_light_view.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const _codec = NoteCodec();

Map<String, Object?> _run(String text, [Map<String, Object?>? attributes]) => {
  'insert': text,
  'attributes': ?attributes,
};

Map<String, Object?> _block(
  String type,
  List<Map<String, Object?>> delta, {
  Map<String, Object?> data = const {},
}) => {
  'type': type,
  'data': {'delta': delta, ...data},
};

Map<String, Object?> _para(String text, {String? value}) => _block(
  'paragraph',
  [if (text.isNotEmpty) _run(text)],
  data: {'formulaValue': ?value},
);

Map<String, Object?> _math(String formula) => {
  'type': 'math_equation',
  'data': {'formula': formula},
};

Map<String, Object?> _inline(String formula) =>
    _run(NoteFormat.inlineMathChar, {'formula': formula});

/// A table the way appflowy stores it: cells column by column. [cells] is by
/// rows; a cell may be a string or a ready block.
Map<String, Object?> _table(
  List<List<Object>> cells, {
  Map<(int, int), Map<String, Object?>> cellData = const {},
  List<double>? widths,
}) {
  final cols = cells.first.length;
  return {
    'type': 'table',
    'data': {
      'colsLen': cols,
      'rowsLen': cells.length,
      'colDefaultWidth': 80.0,
      'rowDefaultHeight': 40.0,
      'colMinimumWidth': 40.0,
      'borderWidth': 2.0,
    },
    'children': [
      for (var c = 0; c < cols; c++)
        for (var r = 0; r < cells.length; r++)
          {
            'type': 'table/cell',
            'data': {
              'colPosition': c,
              'rowPosition': r,
              'width': ?widths?[c],
              ...?cellData[(r, c)],
            },
            'children': [
              switch (cells[r][c]) {
                final String s => _para(s),
                final Map<String, Object?> m => m,
                _ => _para(''),
              },
            ],
          },
    ],
  };
}

/// [table] with the sizes the editor stores once it has measured it.
Map<String, Object?> _measured(Map<String, Object?> table) {
  final data = Map<String, Object?>.from(table['data']! as Map);
  data['colsHeight'] = 100.0;
  return {
    ...table,
    'data': data,
    'children': [
      for (final cell in table['children']! as List)
        {
          ...(cell as Map<String, Object?>),
          'data': {
            ...(cell['data']! as Map<String, Object?>),
            'height': 40.0,
          },
        },
    ],
  };
}

NoteData _doc(List<Map<String, Object?>> children) => NoteData({
  'document': {'type': 'page', 'children': children},
});

class _FakeBox implements BoxContext<NoteData> {
  _FakeBox(
    this.data, {
    double width = 340,
    double height = 600,
    BoxFind? find,
  }) : bounds = Rect.fromLTWH(0, 0, width, height),
       find = ValueNotifier<BoxFind?>(find);

  @override
  final String boxId = 'b';
  @override
  NoteData data;
  @override
  Rect bounds;
  @override
  final bool readOnly = false;
  @override
  final bool autoHeight = false;
  @override
  final bool autofocus = false;
  @override
  final ValueNotifier<BoxFind?> find;

  /// The last data the note committed.
  NoteData? committed;

  /// The last height the note asked for.
  double? requestedHeight;

  @override
  void commit(NoteData data) => committed = data;

  @override
  void requestBounds(Rect bounds) => requestedHeight = bounds.height;
}

ThemeData _theme(Brightness b) => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: b),
  fontFamily: 'Inter',
);

Future<void> _loadInter() async {
  final loader = FontLoader('Inter');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    final f = File('../../../app/assets/fonts/Inter/Inter-$w.ttf');
    if (!f.existsSync()) return;
    loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await loader.load();
}

/// The pixels of the bounded box [key] (rgba), with its size.
Future<(Uint8List, int, int)> _pixels(WidgetTester t, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await t.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    return (data!.buffer.asUint8List(), image.width, image.height);
  }))!;
}

void main() {
  setUpAll(_loadInter);

  tearDown(() => noteLightViewEnabled = true);

  group('the light view looks like the editor', () {
    final key = GlobalKey();

    Future<(Uint8List, int, int)> shoot(
      WidgetTester t,
      _FakeBox box,
      Brightness b, {
      required bool light,
    }) async {
      noteLightViewEnabled = light;
      // A fresh tree, so the note decides again which view to start with.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        MaterialApp(
          theme: _theme(b),
          localizationsDelegates: noteLocalizationsDelegates,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: box.bounds.width,
                  height: box.bounds.height,
                  child: ColoredBox(
                    color: _theme(b).colorScheme.surface,
                    child: Builder(
                      builder: (context) =>
                          const NoteModule().buildEditor(context, box),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.byType(AppFlowyEditor),
        light ? findsNothing : findsOneWidget,
        reason: light ? 'the light view is shown' : 'the editor is shown',
      );
      return _pixels(t, key);
    }

    /// Renders [data] with the editor, then with the light view (from what
    /// the editor committed, which includes the table measurements it
    /// makes), and checks the two images are the same.
    void same(
      String name,
      NoteData data, {
      BoxFind? find,
      bool lightPlaysFirst = false,
    }) {
      for (final b in Brightness.values) {
        testWidgets('$name (${b.name})', (t) async {
          t.view.physicalSize = const Size(400, 700);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          final editorBox = _FakeBox(data, find: find);
          final editor = await shoot(t, editorBox, b, light: false);
          expect(t.takeException(), isNull);
          final lightBox = _FakeBox(editorBox.committed ?? data, find: find);
          final light = await shoot(t, lightBox, b, light: true);
          expect(t.takeException(), isNull);
          expect(light.$2, editor.$2);
          expect(light.$3, editor.$3);
          var differing = 0;
          int? first;
          for (var i = 0; i < editor.$1.length; i += 4) {
            if (editor.$1[i] != light.$1[i] ||
                editor.$1[i + 1] != light.$1[i + 1] ||
                editor.$1[i + 2] != light.$1[i + 2] ||
                editor.$1[i + 3] != light.$1[i + 3]) {
              differing++;
              first ??= i ~/ 4;
            }
          }
          expect(
            differing,
            0,
            reason: first == null
                ? null
                : '$differing pixels differ, the first at '
                      '(${first % editor.$2}, ${first ~/ editor.$2})',
          );
          // The image is not just the background.
          final distinct = <int>{};
          for (var i = 0; i < editor.$1.length; i += 4) {
            distinct.add(editor.$1[i] << 16 | editor.$1[i + 1] << 8 | editor.$1[i + 2]);
          }
          expect(distinct.length, greaterThan(2));
        });
      }
    }

    same(
      'mixed text with styles',
      _doc([
        _block('paragraph', [
          _run('Plain, '),
          _run('bold ', {'bold': true}),
          _run('italic ', {'italic': true}),
          _run('underline ', {'underline': true}),
          _run('strike ', {'strikethrough': true}),
          _run('code ', {'code': true}),
          _run('link ', {'href': 'https://example.com'}),
          _run('colored ', {'font_color': '0xFFCC3300'}),
          _run('highlight ', {'bg_color': '0x6600CC66'}),
          _run('big', {'font_size': 24.0}),
        ]),
        _para(
          'A long paragraph that has to wrap over several lines inside a '
          'narrow box, so line height, wrapping and the padding between '
          'blocks are all compared.',
        ),
        _para(''),
        _para('The last line'),
      ]),
    );

    same(
      'headings',
      _doc([
        _block('heading', [_run('Heading one')], data: {'level': 1}),
        _para('under one'),
        _block('heading', [_run('Heading two')], data: {'level': 2}),
        _block(
          'heading',
          [_run('Heading three, long enough to wrap onto a second line')],
          data: {'level': 3},
        ),
        _block('heading', [], data: {'level': 1}),
      ]),
    );

    same(
      'lists, to-dos and quotes',
      _doc([
        _block('bulleted_list', [_run('first bullet')]),
        _block('bulleted_list', [
          _run('second bullet with '),
          _run('bold', {'bold': true}),
        ]),
        _block('bulleted_list', []),
        _block('numbered_list', [_run('one')]),
        _block('numbered_list', [_run('two')]),
        _block('numbered_list', [_run('three')]),
        _para('break'),
        _block('numbered_list', [_run('starts again')]),
        _block('numbered_list', [_run('second')], data: {'number': 5}),
        _block('todo_list', [_run('open item')], data: {'checked': false}),
        _block('todo_list', [_run('done item')], data: {'checked': true}),
        _block('todo_list', [], data: {'checked': false}),
        _block('quote', [_run('A quotation that is long enough to wrap onto more than one line.')]),
        _block('quote', []),
        {'type': 'divider'},
        _para('after the divider'),
      ]),
    );

    // Formula values are stored with the cell, as the editor stores them.
    same(
      'a table with formulas, an equation and fills',
      _doc([
        _para('before'),
        _table(
          [
            ['Item', 'Qty', 'Total'],
            [
              'apple',
              '3',
              _block(
                'paragraph',
                [_run('=B2*2')],
                data: {'formulaValue': '6'},
              ),
            ],
            [
              'pear',
              _math(r'\frac{a}{b}'),
              _block(
                'paragraph',
                [_run('=B2/0')],
                data: {'formulaValue': '#DIV/0!'},
              ),
            ],
            [
              _block('paragraph', [
                _run('x '),
                _inline('y^2'),
                _run(' text that wraps in a narrow cell'),
              ]),
              '',
              'last',
            ],
          ],
          widths: [90, 70, 100],
          cellData: {
            for (var r = 0; r < 4; r++)
              (r, 0): {'colBackgroundColor': 'role:accent'},
            (2, 1): {'rowBackgroundColor': 'role:alert'},
            (2, 2): {'rowBackgroundColor': 'role:alert'},
            (3, 1): {'rowBackgroundColor': '0x80123456'},
          },
        ),
        _para('after'),
      ]),
    );

    same(
      'block and inline equations',
      _doc([
        _math(r'\int_0^1 x^2\,dx = \frac{1}{3}'),
        _block('paragraph', [
          _run('area '),
          _inline(r'\pi r^2'),
          _run(' and '),
          _inline(r'\notacommand{x}'),
          _run(' and an empty '),
          _inline(''),
        ]),
        _math(r'\frac{1}{'),
        _math(''),
      ]),
    );

    final findDoc = _doc([
      _para('Alpha beta alpha, beta again'),
      _block('heading', [_run('Beta heading')], data: {'level': 2}),
      _table([
        ['fruit', 'Beta cell'],
        [_block('paragraph', [_run('=1+1')], data: {'formulaValue': '2'}), 'x'],
      ]),
      _math(r'\beta + 1'),
      _block('paragraph', [
        _run('inline '),
        _inline(r'\beta_2'),
        _run(' end beta'),
      ]),
    ]);
    same(
      'find highlights and the current match',
      findDoc,
      find: BoxFind(
        query: SearchQuery.parse('beta'),
        currentBoxId: 'b',
        currentOccurrence: 2,
      ),
    );
  });

  group('the light view and the editor', () {
    late ModuleRegistry modules;

    setUp(() {
      modules = ModuleRegistry()
        ..register(const NoteModule(), alwaysOn: true, isDefault: true);
    });

    BoxRecord record(String id, NoteData data, {double x = 100, double y = 100}) =>
        BoxRecord.create(
          id: id,
          typeId: NoteCodec.id,
          dataVersion: 1,
          bounds: Bounds(x, y, 300, 40),
          data: RawJson.encode(_codec.encode(data)),
          snapshotText: _codec.snapshotText(data),
          rev: 'r',
        );

    Future<CanvasController> pump(
      WidgetTester t,
      List<BoxRecord> boxes, {
      bool readOnly = false,
    }) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
      for (final b in boxes) {
        p = p.insertNode(b);
      }
      final c = CanvasController(p, modules);
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: noteLocalizationsDelegates,
          home: Scaffold(body: PageCanvas(controller: c, readOnly: readOnly)),
        ),
      );
      await t.pumpAndSettle();
      return c;
    }

    // A focused editor blinks its cursor forever: pump fixed durations.
    Future<void> frames(WidgetTester t, [int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    Offset screenOf(WidgetTester t, Offset page) {
      final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
      return canvas.view!.toScreen(page) +
          const Offset(0, CommandToolbar.height);
    }

    EditorState editorOf(WidgetTester t) =>
        t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

    NoteData text(List<String> lines) =>
        _doc([for (final l in lines) _para(l)]);

    testWidgets('only the note being edited has an editor', (t) async {
      final c = await pump(t, [
        for (var i = 0; i < 30; i++)
          record(
            'n$i',
            text(['note $i', 'second line']),
            x: (i % 6) * 190.0,
            y: 100.0 + (i ~/ 6) * 120,
          ),
      ]);
      expect(find.byType(AppFlowyEditor), findsNothing);
      expect(find.textContaining('note 7', findRichText: true), findsOneWidget);
      final b = c.page.node('n7')!.bounds!;
      await t.tapAt(screenOf(t, Offset(b.x + 20, b.y + 10)));
      await frames(t);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(c.editingId, 'n7');
      // Clicking another note moves the editor there.
      final b2 = c.page.node('n8')!.bounds!;
      await t.tapAt(screenOf(t, Offset(b2.x + 20, b2.y + 10)));
      await frames(t, 12);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(c.editingId, 'n8');
      expect(t.takeException(), isNull);
    });

    for (final zoom in [1.0, 0.5, 2.0]) {
      testWidgets('a click puts the caret where it was made (zoom $zoom)', (
        t,
      ) async {
        await pump(t, [
          record(
            'n',
            _doc([
              _para('first line of the note'),
              _block('heading', [_run('A heading here')], data: {'level': 2}),
              _block('bulleted_list', [_run('bullet text')]),
              _para('last paragraph, with some words'),
            ]),
            // Near the middle of the view, so it stays on screen when zoomed.
            x: 450,
            y: 250,
          ),
        ]);
        final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
        if (zoom != 1) {
          // Centre the note, then zoom about the centre of the view.
          canvas.fitAll();
          await t.pumpAndSettle();
          canvas.zoomTo(zoom);
          await t.pumpAndSettle();
          expect(canvas.view!.scale, closeTo(zoom, 0.01));
        }
        expect(find.byType(AppFlowyEditor), findsNothing);
        // Click in the middle of the word "paragraph" of the last line: the
        // text widget tells where it is.
        final finder = find.textContaining(
          'last paragraph',
          findRichText: true,
        );
        final render = t.renderObject<RenderParagraph>(finder);
        const offset = 8; // "last par|agraph": between "par" and "agraph"
        final boxes = render.getBoxesForSelection(
          const TextSelection(baseOffset: offset, extentOffset: offset + 1),
        );
        final target = render.localToGlobal(boxes.first.toRect().center);
        await t.tapAt(target);
        await frames(t);
        final editor = editorOf(t);
        final sel = editor.selection!;
        expect(sel.isCollapsed, isTrue);
        expect(sel.end.path, [3]);
        expect(
          sel.end.offset,
          anyOf(offset, offset + 1),
          reason: 'the caret lands on the clicked character',
        );

        // A click to the right of a short line goes to its end.
        // (Back to the light view first.)
        expect(t.takeException(), isNull);
      });
    }

    for (final zoom in [1.0, 0.5, 2.0]) {
      testWidgets('the first press can drag a selection (zoom $zoom)', (
        t,
      ) async {
        await pump(t, [
          record(
            'n',
            _doc([
              _para('first line of the note'),
              _para('last paragraph, with some words'),
            ]),
            x: 450,
            y: 250,
          ),
        ]);
        final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
        if (zoom != 1) {
          canvas.fitAll();
          await t.pumpAndSettle();
          canvas.zoomTo(zoom);
          await t.pumpAndSettle();
        }
        expect(find.byType(AppFlowyEditor), findsNothing);
        Offset charAt(String line, int offset) {
          final render = t.renderObject<RenderParagraph>(
            find.textContaining(line, findRichText: true),
          );
          final boxes = render.getBoxesForSelection(
            TextSelection(baseOffset: offset, extentOffset: offset + 1),
          );
          return render.localToGlobal(boxes.first.toRect().center);
        }

        // From "fi|rst" on the first line to "last par|agraph" on the second.
        final from = charAt('first line', 2);
        final to = charAt('last paragraph', 8);
        final g = await t.startGesture(from, kind: PointerDeviceKind.mouse);
        await t.pump();
        // In steps, so the drag starts before the editor is there.
        for (var i = 1; i <= 8; i++) {
          await g.moveTo(Offset.lerp(from, to, i / 8)!);
          await t.pump(const Duration(milliseconds: 16));
        }
        await g.up();
        await frames(t);

        expect(find.byType(AppFlowyEditor), findsOneWidget);
        final sel = editorOf(t).selection!.normalized;
        expect(sel.isCollapsed, isFalse);
        expect(sel.start.path, [0]);
        expect(sel.start.offset, anyOf(2, 3));
        expect(sel.end.path, [1]);
        expect(sel.end.offset, anyOf(8, 9));
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('a click below the text puts the caret at the nearest line', (
      t,
    ) async {
      final c = await pump(t, [record('n', text(['alpha', 'beta']))]);
      final b = c.page.node('n')!.bounds!;
      // Far right of the first line.
      await t.tapAt(screenOf(t, Offset(b.x + b.width - 10, b.y + 12)));
      await frames(t);
      final sel = editorOf(t).selection!;
      expect(sel.end.path, [0]);
      expect(sel.end.offset, 5);
    });

    testWidgets('typing after a click works, and the note commits', (t) async {
      final c = await pump(t, [record('n', text(['hello']))]);
      final b = c.page.node('n')!.bounds!;
      await t.tapAt(screenOf(t, Offset(b.x + b.width - 10, b.y + 12)));
      await frames(t);
      final editor = editorOf(t);
      await editor.apply(
        editor.transaction..insertText(editor.getNodeAtPath([0])!, 5, '!!'),
      );
      await frames(t);
      expect((c.page.node('n')! as BoxRecord).snapshotText, 'hello!!');
    });

    testWidgets('undo survives leaving the note and coming back', (t) async {
      final c = await pump(t, [
        record('a', text(['alpha']), x: 100),
        record('b', text(['beta']), x: 500),
      ]);
      Offset at(String id) {
        final r = c.page.node(id)!.bounds!;
        return screenOf(t, Offset(r.x + 20, r.y + 12));
      }

      await t.tapAt(at('a'));
      await frames(t);
      var editor = editorOf(t);
      await editor.apply(
        editor.transaction..insertText(editor.getNodeAtPath([0])!, 5, ' one'),
      );
      await frames(t);
      expect((c.page.node('a')! as BoxRecord).snapshotText, 'alpha one');
      final firstState = editor;

      // Leave: the other note takes the focus and this one is light again.
      await t.tapAt(at('b'));
      await frames(t, 12);
      expect(c.editingId, 'b');
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(find.textContaining('alpha one', findRichText: true), findsOneWidget);

      // Come back: the same editor state, with its history.
      await t.tapAt(at('a'));
      await frames(t, 12);
      editor = editorOf(t);
      expect(identical(editor, firstState), isTrue);
      expect(editor.undoManager.undoStack.isEmpty, isFalse);
      // Ctrl+Z undoes the edit made before leaving.
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await frames(t);
      expect((c.page.node('a')! as BoxRecord).snapshotText, 'alpha');
      expect(t.takeException(), isNull);
    });

    testWidgets('the box height does not change across the switch', (t) async {
      final data = _doc([
        _block('heading', [_run('Title')], data: {'level': 1}),
        _para('A paragraph long enough to wrap onto a second line in a box '
            'three hundred pixels wide, and then some more words.'),
        _block('todo_list', [_run('thing')], data: {'checked': false}),
        _math(r'x^2'),
      ]);
      final c = await pump(t, [record('n', data)]);
      final before = c.page.node('n')!.bounds!.height;
      expect(find.byType(AppFlowyEditor), findsNothing);
      final b = c.page.node('n')!.bounds!;
      await t.tapAt(screenOf(t, Offset(b.x + 20, b.y + 20)));
      await frames(t, 12);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      final editing = c.page.node('n')!.bounds!.height;
      // Leave: click on the empty canvas (that creates a note elsewhere, so
      // blur through the keyboard instead).
      FocusManager.instance.primaryFocus?.unfocus();
      await frames(t, 12);
      expect(find.byType(AppFlowyEditor), findsNothing);
      final after = c.page.node('n')!.bounds!.height;
      expect(editing, closeTo(before, 0.6));
      expect(after, closeTo(before, 0.6));
    });

    testWidgets('a note with a table keeps its editor once edited', (t) async {
      // appflowy's table leaves listeners behind when its editor is taken
      // out of the tree; mounting the same state again made row heights flip
      // for ever, so such an editor stays (see _demote).
      final c = await pump(t, [
        record(
          'n',
          _doc([
            _para('top'),
            _measured(_table([['a', 'b']])),
          ]),
        ),
      ]);
      expect(find.byType(AppFlowyEditor), findsNothing);
      final b = c.page.node('n')!.bounds!;
      await t.tapAt(screenOf(t, Offset(b.x + 20, b.y + 14)));
      await frames(t, 12);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await frames(t, 12);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a box resized in width keeps its fitted height (light)', (
      t,
    ) async {
      final c = await pump(t, [
        record(
          'n',
          _doc([
            _para('A paragraph long enough to wrap onto several lines when the '
                'box is made narrower, so its height depends on its width.'),
          ]),
        ),
      ]);
      final wide = c.page.node('n')!.bounds!;
      c.beginGesture('n');
      c.updateGesture(
        'n',
        Bounds(wide.x, wide.y, 150, wide.height),
        setsHeight: false,
      );
      c.endGesture('n');
      await t.pumpAndSettle();
      expect(find.byType(AppFlowyEditor), findsNothing);
      final narrow = c.page.node('n')!.bounds!;
      expect(narrow.height, greaterThan(wide.height));
      // The same note, opened for editing at that width, is as tall.
      await t.tapAt(screenOf(t, Offset(narrow.x + 20, narrow.y + 20)));
      await frames(t, 12);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(c.page.node('n')!.bounds!.height, closeTo(narrow.height, 0.6));
    });

    testWidgets('a box created by a click starts as an editor', (t) async {
      final c = await pump(t, []);
      await t.tapAt(const Offset(400, 300));
      await frames(t);
      expect(c.page.nodes, hasLength(1));
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(c.editingId, c.page.nodes.single.id);
    });

    testWidgets('a note the light view cannot draw keeps its editor', (t) async {
      await pump(t, [
        record(
          'n',
          _doc([
            _block('bulleted_list', [_run('parent')]),
          ]).withChild(0, _block('bulleted_list', [_run('child')])),
        ),
      ]);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    test('which documents the light view draws', () {
      bool light(List<Map<String, Object?>> blocks) {
        final doc = Document.fromJson(_doc(blocks).document);
        return noteLightable(doc.root);
      }

      expect(light([_para('x'), _math('y')]), isTrue);
      expect(
        light([
          _block('heading', [_run('h')], data: {'level': 2}),
          _block('todo_list', [_run('t')], data: {'checked': true}),
          {'type': 'divider'},
          _table([
            ['a', _math('x')],
          ]),
        ]),
        isFalse,
        reason: 'the table has not been measured yet',
      );
      expect(
        light([
          _measured(_table([['a', 'b']])),
          {'type': 'divider'},
        ]),
        isTrue,
      );
      // Falls back to the editor:
      expect(light([]), isFalse);
      expect(light([{'type': 'image', 'data': {'url': 'x'}}]), isFalse);
      expect(light([{'type': 'something_new', 'data': {}}]), isFalse);
      expect(
        light([
          _block('paragraph', [_run('x')], data: {'align': 'center'}),
        ]),
        isFalse,
      );
      expect(
        light([
          _block('paragraph', [_run('x')], data: {'textDirection': 'rtl'}),
        ]),
        isFalse,
      );
      expect(
        light([
          _block('paragraph', [_run('x')], data: {'bgColor': '0xFF00FF00'}),
        ]),
        isFalse,
      );
      // A formula without a stored value (the editor works it out).
      expect(
        light([
          _measured(
            _table([
              [_block('paragraph', [_run('=1+1')])],
            ]),
          ),
        ]),
        isFalse,
      );
      expect(
        light([
          _measured(
            _table([
              [_block('paragraph', [_run('=1+1')], data: {'formulaValue': '2'})],
            ]),
          ),
        ]),
        isTrue,
      );
    });

    testWidgets('a to-do is checked without an editor, and can be undone', (
      t,
    ) async {
      final c = await pump(t, [
        record(
          'n',
          _doc([
            _block('todo_list', [_run('thing')], data: {'checked': false}),
          ]),
        ),
      ]);
      expect(find.byType(AppFlowyEditor), findsNothing);
      await t.tap(find.byIcon(Icons.check_box_outline_blank_rounded));
      await frames(t);
      expect(find.byType(AppFlowyEditor), findsNothing);
      expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
      expect((c.page.node('n')! as BoxRecord).data.toString(), contains('true'));
    });

    testWidgets('find highlights are shown by the light view', (t) async {
      final c = await pump(t, [
        record('n', _doc([_para('Alpha beta alpha'), _math(r'\beta')])),
      ]);
      final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
      canvas.find.open(text: 'beta');
      await t.pump();
      await t.pump();
      expect(find.byType(AppFlowyEditor), findsNothing);
      expect(find.byKey(const ValueKey('find-math-match')), findsOneWidget);
      final marks = <String>[];
      for (final w in t.widgetList<RichText>(find.byType(RichText))) {
        w.text.visitChildren((s) {
          if (s is TextSpan && s.style?.backgroundColor != null && s.text != null) {
            marks.add(s.text!);
          }
          return true;
        });
      }
      expect(marks, contains('beta'));
      expect(c.page.nodes, hasLength(1));
    });

    testWidgets('a read-only page shows the light view and has no editor', (
      t,
    ) async {
      await pump(t, [record('n', text(['read only text']))], readOnly: true);
      expect(find.byType(AppFlowyEditor), findsNothing);
      expect(find.textContaining('read only', findRichText: true), findsOneWidget);
    });
  });
}

extension on NoteData {
  /// This note with [child] under the block at index [at].
  NoteData withChild(int at, Map<String, Object?> child) {
    final doc = Map<String, Object?>.from(document['document']! as Map);
    final children = [...(doc['children']! as List)];
    final parent = Map<String, Object?>.from(children[at] as Map);
    parent['children'] = [child];
    children[at] = parent;
    doc['children'] = children;
    return NoteData({'document': doc});
  }
}
