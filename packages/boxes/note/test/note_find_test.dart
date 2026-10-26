// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const codec = NoteCodec();

Map<String, Object?> para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      if (text.isNotEmpty) {'insert': text},
    ],
  },
};

Map<String, Object?> blockMath(String formula) => {
  'type': 'math_equation',
  'data': {'formula': formula},
};

Map<String, Object?> table(List<List<String>> rows) {
  final cols = rows.first.length;
  return {
    'type': 'table',
    'data': {
      'colsLen': cols,
      'rowsLen': rows.length,
      'colDefaultWidth': 80.0,
      'rowDefaultHeight': 40.0,
      'colMinimumWidth': 40.0,
      'borderWidth': 2.0,
    },
    'children': [
      for (var c = 0; c < cols; c++)
        for (var r = 0; r < rows.length; r++)
          {
            'type': 'table/cell',
            'data': {'colPosition': c, 'rowPosition': r},
            'children': [para(rows[r][c])],
          },
    ],
  };
}

NoteData doc(List<Map<String, Object?>> children) => NoteData({
  'document': {'type': 'page', 'children': children},
});

BoxRecord noteBox(String id, NoteData data, {double x = 100, double y = 100}) =>
    BoxRecord.create(
      id: id,
      typeId: NoteCodec.id,
      dataVersion: 1,
      bounds: Bounds(x, y, 420, 300),
      data: RawJson.encode(codec.encode(data)),
      snapshotText: codec.snapshotText(data),
      rev: 'r',
    );

/// The highlighted pieces of text on screen, in order, with whether each
/// is the strong (current) kind.
List<(String, bool)> highlights(WidgetTester t, BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final out = <(String, bool)>[];
  for (final w in t.widgetList<RichText>(find.byType(RichText))) {
    w.text.visitChildren((span) {
      if (span is TextSpan && span.text != null) {
        final bg = span.style?.backgroundColor;
        if (bg == scheme.tertiary) out.add((span.text!, true));
        if (bg == scheme.tertiaryContainer) out.add((span.text!, false));
      }
      return true;
    });
  }
  return out;
}

void main() {
  group('snapshot parts', () {
    test('join to the snapshot and name the block each piece came from', () {
      final data = doc([
        para('before'),
        table([
          ['name', 'qty'],
          ['apple', '3'],
        ]),
        blockMath('x^2'),
        para('after'),
      ]);
      final parts = snapshotParts(data);
      expect(parts.map((p) => p.text).join(), codec.snapshotText(data));
      expect(parts.first.path, [0]);
      // Cells are named by their paragraph's path: table 1, cell index, 0.
      final cells = parts.where((p) => p.path != null && p.path!.length == 3);
      expect(cells.map((p) => p.text), ['name', 'qty', 'apple', '3']);
      expect(parts.where((p) => p.path == null).map((p) => p.text).toSet(), {
        '\n',
        ' | ',
      });
      expect(parts.singleWhere((p) => p.text == r'$$x^2$$').path, [2]);
    });
  });

  group('Find on page in a note', () {
    late ModuleRegistry modules;
    setUp(() {
      modules = ModuleRegistry()
        ..register(const NoteModule(), alwaysOn: true, isDefault: true);
    });

    Future<(CanvasController, GlobalKey<PageCanvasState>)> pump(
      WidgetTester t,
      List<BoxRecord> boxes, {
      bool readOnly = false,
    }) async {
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
      for (final b in boxes) {
        p = p.insertNode(b);
      }
      final c = CanvasController(p, modules);
      final key = GlobalKey<PageCanvasState>();
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: noteLocalizationsDelegates,
          home: Scaffold(
            body: PageCanvas(key: key, controller: c, readOnly: readOnly),
          ),
        ),
      );
      await t.pumpAndSettle();
      return (c, key);
    }

    final mixed = doc([
      para('Alpha beta alpha'),
      table([
        ['fruit', 'Beta cell'],
        ['apple', '3'],
      ]),
      blockMath(r'\beta + 1'),
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': 'inline '},
            {
              'insert': NoteFormat.inlineMathChar,
              'attributes': {'formula': r'\beta_2'},
            },
            {'insert': ' end'},
          ],
        },
      },
    ]);

    testWidgets('text, table cells and equations are highlighted', (t) async {
      final (_, key) = await pump(t, [noteBox('n', mixed)]);
      key.currentState!.find.open(text: 'beta');
      await t.pump();
      await t.pump();
      final ctx = t.element(find.byType(Scaffold));
      final marks = highlights(t, ctx);
      // Paragraph text and the table cell: "beta" and "Beta" (case ignored).
      expect(marks.map((m) => m.$1), containsAll(['beta', 'Beta']));
      // The first match on the page (reading order) is the current one.
      expect(marks.first, ('beta', true));
      expect(marks.where((m) => m.$2), hasLength(1));
      // The block equation and the inline one match on their source.
      expect(
        find.byKey(const ValueKey('find-math-match')),
        findsNWidgets(2),
        reason: 'block (\\beta + 1) and inline (\\beta_2); neither is current',
      );
      // The box is framed.
      expect(find.byKey(const ValueKey('find-frame-current')), findsOneWidget);
    });

    testWidgets('stepping moves the current highlight through the note',
        (t) async {
      final (_, key) = await pump(t, [noteBox('n', mixed)]);
      final f = key.currentState!.find..open(text: 'beta');
      await t.pump();
      await t.pump();
      final ctx = t.element(find.byType(Scaffold));
      // Matches in snapshot order: paragraph (1), cell "Beta cell" (1),
      // block equation (1), inline equation (1).
      expect(f.matches, hasLength(4));
      f.step(1);
      await t.pump();
      var marks = highlights(t, ctx);
      expect(marks.where((m) => m.$2).map((m) => m.$1), ['Beta']);
      f.step(1);
      await t.pump();
      expect(find.byKey(const ValueKey('find-math-current')), findsOneWidget);
      expect(highlights(t, ctx).where((m) => m.$2), isEmpty);
      f.step(1);
      await t.pump();
      expect(find.byKey(const ValueKey('find-math-current')), findsOneWidget);
      f.step(1);
      await t.pump();
      marks = highlights(t, ctx);
      expect(marks.where((m) => m.$2).map((m) => m.$1), ['beta']);
    });

    testWidgets('a note that lacks one of the words is not highlighted',
        (t) async {
      final (_, key) = await pump(t, [noteBox('n', mixed)]);
      key.currentState!.find.open(text: 'beta zebra');
      await t.pump();
      await t.pump();
      expect(highlights(t, t.element(find.byType(Scaffold))), isEmpty);
      expect(find.byKey(const ValueKey('find-frame-current')), findsNothing);
      expect(key.currentState!.find.matches, isEmpty);
    });

    testWidgets('whole words and accents apply inside the note', (t) async {
      final (_, key) = await pump(t, [
        noteBox('n', doc([para('Crème brûlée and category')])),
      ]);
      key.currentState!.find.open(text: 'creme cat');
      await t.pump();
      await t.pump();
      expect(key.currentState!.find.matches, isEmpty, reason: 'cat is a prefix');
      key.currentState!.find.setText('creme brulee');
      await t.pump();
      await t.pump();
      final marks = highlights(t, t.element(find.byType(Scaffold)));
      expect(marks.map((m) => m.$1), ['Crème', 'brûlée']);
    });

    testWidgets('Esc clears the highlights', (t) async {
      final (_, key) = await pump(t, [noteBox('n', mixed)]);
      key.currentState!.find.open(text: 'beta');
      await t.pump();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('find-bar')), findsNothing);
      expect(highlights(t, t.element(find.byType(Scaffold))), isEmpty);
      expect(find.byKey(const ValueKey('find-math-match')), findsNothing);
      expect(find.byKey(const ValueKey('find-math-current')), findsNothing);
    });

    testWidgets('highlights show in the read-only view too', (t) async {
      final (_, key) = await pump(t, [noteBox('n', mixed)], readOnly: true);
      key.currentState!.find.open(text: 'beta');
      await t.pump();
      await t.pump();
      expect(
        highlights(t, t.element(find.byType(Scaffold))).map((m) => m.$1),
        containsAll(['beta', 'Beta']),
      );
    });

    testWidgets('Ctrl+F works while the note editor has focus', (t) async {
      final (c, key) = await pump(t, [noteBox('n', mixed)]);
      // Put the caret in the note (no pumpAndSettle once focused).
      await t.tapAt(const Offset(180, 140 + CommandToolbar.height));
      await t.pump();
      await t.pump();
      expect(c.editingId, 'n');
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyF);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      await t.pump();
      expect(key.currentState!.find.isOpen, isTrue);
      expect(find.byKey(const ValueKey('find-bar')), findsOneWidget);
      // The note's text was not changed by the shortcut.
      expect(c.page.node('n')!.bounds, isNotNull);
      expect(
        (c.page.node('n')! as BoxRecord).snapshotText,
        startsWith('Alpha beta alpha'),
      );
    });

    testWidgets('Ctrl+Shift+F is not Ctrl+F while the editor has focus',
        (t) async {
      final (c, key) = await pump(t, [noteBox('n', mixed)]);
      await t.tapAt(const Offset(180, 140 + CommandToolbar.height));
      await t.pump();
      await t.pump();
      expect(c.editingId, 'n');
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyF);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      // Ctrl+Shift+F is the app's "Search all pages": no find bar here, and
      // the editor didn't swallow the event (the app tests cover the rest).
      expect(key.currentState!.find.isOpen, isFalse);
    });
  });
}
