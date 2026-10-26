// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_note/src/math_blocks.dart';
import 'package:noted_box_note/src/math_input.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const codec = NoteCodec();

Map<String, Object?> para(String text, {String? value}) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      if (text.isNotEmpty) {'insert': text},
    ],
    'formulaValue': ?value,
  },
};

/// A table the way appflowy stores it: cells column by column.
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

BoxRecord noteBoxOf(NoteData data) => BoxRecord.create(
  id: 'n',
  typeId: NoteCodec.id,
  dataVersion: 1,
  bounds: Bounds(100, 100, 400, 40),
  data: RawJson.encode(codec.encode(data)),
  snapshotText: codec.snapshotText(data),
  rev: 'r',
);

/// The cell node at (row, col) of the table at the top of [editor].
Node cellAt(EditorState editor, int row, int col) =>
    editor.document.root.children.first.children.firstWhere(
      (n) =>
          n.attributes['rowPosition'] == row &&
          n.attributes['colPosition'] == col,
    );

String textAt(EditorState editor, int row, int col) =>
    cellAt(editor, row, col).children.first.delta!.toPlainText();

Object? valueAt(EditorState editor, int row, int col) =>
    cellAt(editor, row, col).children.first.attributes['formulaValue'];

void main() {
  group('codec', () {
    test('a formula cell reads as its stored value in the snapshot', () {
      final data = doc([
        {
          'type': 'table',
          'data': {'colsLen': 2, 'rowsLen': 1},
          'children': [
            {
              'type': 'table/cell',
              'data': {'colPosition': 0, 'rowPosition': 0},
              'children': [para('=1+2', value: '3')],
            },
            {
              'type': 'table/cell',
              'data': {'colPosition': 1, 'rowPosition': 0},
              'children': [para('=1/0', value: '#DIV/0!')],
            },
          ],
        },
      ]);
      expect(codec.snapshotText(data), '3 | #DIV/0!');
    });

    test('text starting with = but no stored value is shown as it is', () {
      expect(codec.snapshotText(doc([para('=1+2')])), '=1+2');
      expect(NoteFormat.formulaValueKey, 'formulaValue');
    });

    test('a value left on a cell that is no longer a formula is ignored', () {
      expect(codec.snapshotText(doc([para('plain', value: '3')])), 'plain');
    });

    test('block and inline equations inside cells keep their LaTeX', () {
      final data = doc([
        {
          'type': 'table',
          'data': {'colsLen': 2, 'rowsLen': 1},
          'children': [
            {
              'type': 'table/cell',
              'data': {'colPosition': 0, 'rowPosition': 0},
              'children': [
                {
                  'type': 'math_equation',
                  'data': {'formula': r'\frac{a}{b}'},
                },
              ],
            },
            {
              'type': 'table/cell',
              'data': {'colPosition': 1, 'rowPosition': 0},
              'children': [
                {
                  'type': 'paragraph',
                  'data': {
                    'delta': [
                      {'insert': 'x '},
                      {
                        'insert': NoteFormat.inlineMathChar,
                        'attributes': {'formula': 'y^2'},
                      },
                    ],
                  },
                },
              ],
            },
          ],
        },
      ]);
      expect(codec.snapshotText(data), '\$\$\\frac{a}{b}\$\$ | x \$y^2\$');
    });
  });

  group('editor', () {
    late ModuleRegistry modules;

    setUp(() {
      modules = ModuleRegistry()
        ..register(const NoteModule(), alwaysOn: true, isDefault: true);
    });

    Future<CanvasController> pump(WidgetTester t, NoteData data) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
      p = p.insertNode(noteBoxOf(data));
      final c = CanvasController(p, modules);
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: noteLocalizationsDelegates,
          home: Scaffold(body: PageCanvas(controller: c)),
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

    Future<EditorState> edit(WidgetTester t, CanvasController c) async {
      final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
      final b = c.page.node('n')!.bounds!;
      await t.tapAt(canvas.view!.toScreen(Offset(b.x + 20, b.y + 10)));
      await frames(t);
      expect(c.editingId, 'n');
      return t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
    }

    String snapshot(CanvasController c) =>
        (c.page.node('n')! as BoxRecord).snapshotText;

    final shown = find.byKey(const ValueKey('formula-value'));

    /// A 3 x 2 table: numbers in column A, a formula in column B.
    NoteData sample() => doc([
      table([
        ['1', '=A1*2'],
        ['2', '=A2*2'],
        ['3', '=SUM(B1:B2)'],
      ]),
    ]);

    testWidgets('a formula cell shows its result, not its text', (t) async {
      final c = await pump(t, sample());
      expect(shown, findsNWidgets(3));
      expect(find.text('2'), findsWidgets);
      expect(t.widget<Text>(shown.first).data, '2');
      // Computed on load, though the document stored no values.
      expect(t.takeException(), isNull);
      final editor = await edit(t, c);
      expect(valueAt(editor, 0, 1), '2');
      expect(valueAt(editor, 1, 1), '4');
      expect(valueAt(editor, 2, 1), '6');
      expect(textAt(editor, 2, 1), '=SUM(B1:B2)');
      expect(snapshot(c), '1 | 2\n2 | 4\n3 | 6');
    });

    testWidgets('clicking a formula cell shows the formula to edit', (t) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      expect(shown, findsNWidgets(3));
      editor.selection = Selection.collapsed(
        Position(path: cellAt(editor, 0, 1).children.first.path, offset: 2),
      );
      await frames(t);
      expect(shown, findsNWidgets(2));
      expect(find.text('=A1*2', findRichText: true), findsOneWidget);
      // Leaving the cell shows the result again.
      editor.selection = Selection.collapsed(
        Position(path: cellAt(editor, 0, 0).children.first.path),
      );
      await frames(t);
      expect(shown, findsNWidgets(3));
      expect(find.text('=A1*2', findRichText: true), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('tapping the result opens the formula for editing', (t) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      await t.tap(shown.first);
      await frames(t);
      final sel = editor.selection!;
      expect(sel.end.path, cellAt(editor, 0, 1).children.first.path);
      expect(sel.end.offset, lessThanOrEqualTo(5));
      expect(shown, findsNWidgets(2));
      expect(t.takeException(), isNull);
    });

    testWidgets('editing a cell updates every result that uses it', (t) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      final a1 = cellAt(editor, 0, 0).children.first;
      await editor.apply(editor.transaction..deleteText(a1, 0, 1));
      await editor.apply(editor.transaction..insertText(a1, 0, '10'));
      await frames(t);
      expect(valueAt(editor, 0, 1), '20');
      expect(valueAt(editor, 2, 1), '24');
      expect(find.text('20'), findsWidgets);
      expect(snapshot(c), '10 | 20\n2 | 4\n3 | 24');

      // Typing into the formula itself.
      final b1 = cellAt(editor, 0, 1).children.first;
      await editor.apply(editor.transaction..insertText(b1, 5, '+1'));
      await frames(t);
      expect(valueAt(editor, 0, 1), '21');
      expect(valueAt(editor, 2, 1), '25');

      // Breaking it, then fixing it.
      await editor.apply(editor.transaction..insertText(b1, 7, '+'));
      await frames(t);
      expect(valueAt(editor, 0, 1), '#ERROR!');
      expect(valueAt(editor, 2, 1), '#ERROR!');
      await editor.apply(editor.transaction..deleteText(b1, 7, 1));
      await frames(t);
      expect(valueAt(editor, 0, 1), '21');
      expect(t.takeException(), isNull);
    });

    testWidgets('a cell that stops being a formula loses its value', (t) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      final b1 = cellAt(editor, 0, 1).children.first;
      await editor.apply(editor.transaction..deleteText(b1, 0, 1));
      await frames(t);
      expect(b1.attributes.containsKey('formulaValue'), isFalse);
      expect(snapshot(c), startsWith('1 | A1*2'));
      expect(shown, findsNWidgets(2));
    });

    testWidgets('editing does not add steps to the undo history', (t) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      final a1 = cellAt(editor, 0, 0).children.first;
      final before = editor.undoManager.undoStack.length;
      await editor.apply(editor.transaction..insertText(a1, 1, '5'));
      await frames(t);
      expect(valueAt(editor, 0, 1), '30');
      // One step for the typing; the recalculation adds none.
      expect(editor.undoManager.undoStack.length - before, 1);
      editor.undoManager.undo();
      await frames(t);
      expect(textAt(editor, 0, 0), '1');
      expect(valueAt(editor, 0, 1), '2');
      expect(c.editingId, 'n');
    });

    testWidgets('inserting a row adjusts the formulas', (t) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      TableActions.add(tableNode, 1, editor, TableDirection.row);
      await frames(t, 10);
      expect(tableNode.attributes['rowsLen'], 4);
      // The old row 2 is now row 3, and so on; the sum grew to cover the
      // new row 2.
      expect(textAt(editor, 0, 1), '=A1*2');
      expect(textAt(editor, 2, 1), '=A3*2');
      expect(textAt(editor, 3, 1), '=SUM(B1:B3)');
      expect(valueAt(editor, 3, 1), '6');
      expect(snapshot(c), '1 | 2\n | \n2 | 4\n3 | 6');
      expect(t.takeException(), isNull);

      // Typing in the new row now feeds the sum.
      final a2 = cellAt(editor, 1, 1).children.first;
      await editor.apply(editor.transaction..insertText(a2, 0, '7'));
      await frames(t);
      expect(valueAt(editor, 3, 1), '13');
    });

    testWidgets('inserting a row at the end leaves formulas alone', (t) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      TableActions.add(tableNode, 3, editor, TableDirection.row);
      await frames(t, 10);
      expect(textAt(editor, 2, 1), '=SUM(B1:B2)');
      expect(valueAt(editor, 2, 1), '6');
      expect(c.page.node('n'), isNotNull);
    });

    testWidgets('deleting a row adjusts the formulas', (t) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', '=A1*2'],
            ['2', '=A2*2'],
            ['3', '=A1+A2+A3'],
            ['', '=SUM(B1:B3)'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      TableActions.delete(tableNode, 1, editor, TableDirection.row);
      await frames(t, 10);
      expect(tableNode.attributes['rowsLen'], 3);
      expect(textAt(editor, 0, 1), '=A1*2');
      // The reference to the deleted row is #REF!, later ones moved up.
      expect(textAt(editor, 1, 1), '=A1+#REF!+A2');
      expect(valueAt(editor, 1, 1), '#REF!');
      expect(textAt(editor, 2, 1), '=SUM(B1:B2)');
      expect(valueAt(editor, 2, 1), '#REF!');
      expect(snapshot(c), '1 | 2\n3 | #REF!\n | #REF!');
      expect(t.takeException(), isNull);
    });

    testWidgets('inserting and deleting columns adjust the formulas', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', '2', '=A1+B1'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      TableActions.add(tableNode, 1, editor, TableDirection.col);
      await frames(t, 10);
      expect(textAt(editor, 0, 3), '=A1+C1');
      expect(valueAt(editor, 0, 3), '3');
      TableActions.delete(tableNode, 0, editor, TableDirection.col);
      await frames(t, 10);
      expect(textAt(editor, 0, 2), '=#REF!+B1');
      expect(valueAt(editor, 0, 2), '#REF!');
      expect(snapshot(c), ' | 2 | #REF!');
    });

    testWidgets('undo after inserting a row takes the formulas back', (
      t,
    ) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      TableActions.add(tableNode, 1, editor, TableDirection.row);
      await frames(t, 10);
      expect(textAt(editor, 3, 1), '=SUM(B1:B3)');
      // One undo takes back the row and the formula rewrite together.
      editor.undoManager.undo();
      await frames(t, 10);
      expect(tableNode.attributes['rowsLen'], 3);
      expect(textAt(editor, 2, 1), '=SUM(B1:B2)');
      expect(valueAt(editor, 2, 1), '6');
      editor.undoManager.redo();
      await frames(t, 10);
      expect(tableNode.attributes['rowsLen'], 4);
      expect(textAt(editor, 3, 1), '=SUM(B1:B3)');
      expect(t.takeException(), isNull);
    });

    testWidgets('column and row headers show while a table is focused', (
      t,
    ) async {
      final c = await pump(t, sample());
      expect(find.byKey(const ValueKey('col-header-A')), findsNothing);
      final editor = await edit(t, c);
      // The caret is in a paragraph outside any table, or none: no headers.
      editor.selection = null;
      await frames(t);
      expect(find.byKey(const ValueKey('col-header-A')), findsNothing);

      editor.selection = Selection.collapsed(
        Position(path: cellAt(editor, 1, 0).children.first.path),
      );
      await frames(t, 8);
      expect(find.byKey(const ValueKey('col-header-A')), findsOneWidget);
      expect(find.byKey(const ValueKey('col-header-B')), findsOneWidget);
      expect(find.byKey(const ValueKey('col-header-C')), findsNothing);
      for (final r in ['1', '2', '3']) {
        expect(find.byKey(ValueKey('row-header-$r')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('row-header-4')), findsNothing);
      // Above and left of the first cell.
      final a = t.getRect(find.byKey(const ValueKey('col-header-A')));
      final b = t.getRect(find.byKey(const ValueKey('col-header-B')));
      final r1 = t.getRect(find.byKey(const ValueKey('row-header-1')));
      final r2 = t.getRect(find.byKey(const ValueKey('row-header-2')));
      expect(b.left, greaterThan(a.left));
      expect(r2.top, greaterThan(r1.top));
      final cell = t.getRect(find.byType(TableBlockComponentWidget));
      expect(a.bottom, lessThanOrEqualTo(r1.top));
      expect(a.top, greaterThanOrEqualTo(cell.top - 4));
      expect(r1.right, lessThanOrEqualTo(cell.left + 60));
      // They are not part of the document, and take no taps.
      expect(snapshot(c), '1 | 2\n2 | 4\n3 | 6');

      // They follow a new column.
      TableActions.add(
        editor.document.root.children.first,
        2,
        editor,
        TableDirection.col,
      );
      await frames(t, 10);
      expect(find.byKey(const ValueKey('col-header-C')), findsOneWidget);

      // And go when the caret leaves the table.
      editor.selection = null;
      await frames(t);
      expect(find.byKey(const ValueKey('col-header-A')), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('a block equation in a cell: typed, rendered, edited', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['a', r'$$'],
            ['c', 'd'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final heightBefore = c.page.node('n')!.bounds!.height;
      final p = cellAt(editor, 0, 1).children.first;
      editor.selection = Selection.collapsed(Position(path: p.path, offset: 2));
      expect(await blockMathShortcut.execute(editor), isTrue);
      await frames(t, 10);
      // The equation took the place of the cell's line.
      final cell = cellAt(editor, 0, 1);
      expect(cell.children, hasLength(1));
      expect(cell.children.first.type, 'math_equation');
      expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
      await t.enterText(
        find.byKey(const ValueKey('math-source')),
        r'\frac{a}{b}',
      );
      await t.tap(find.text('Done'));
      await frames(t, 10);
      expect(cell.children.first.attributes['formula'], r'\frac{a}{b}');
      expect(find.byType(Math), findsOneWidget);
      expect(find.byType(MathBlockComponentWidget), findsOneWidget);
      // The cell, its row and the box grew to hold it.
      expect(c.page.node('n')!.bounds!.height, greaterThan(heightBefore));
      expect(snapshot(c), 'a | \$\$\\frac{a}{b}\$\$\nc | d');

      // Tapping it opens the dialog again.
      await t.tap(find.byType(Math));
      await frames(t, 10);
      expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('math-source')), 'x^2');
      await t.tap(find.text('Done'));
      await frames(t, 10);
      expect(snapshot(c), 'a | \$\$x^2\$\$\nc | d');

      // Emptied, it turns back into a line of text.
      await t.tap(find.byType(Math));
      await frames(t, 10);
      await t.enterText(find.byKey(const ValueKey('math-source')), '');
      await t.tap(find.text('Done'));
      await frames(t, 10);
      expect(cellAt(editor, 0, 1).children.first.type, 'paragraph');
      expect(find.byType(Math), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('cancelling a new block equation in a cell restores the line', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            [r'$$', 'b'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final p = cellAt(editor, 0, 0).children.first;
      editor.selection = Selection.collapsed(Position(path: p.path, offset: 2));
      expect(await blockMathShortcut.execute(editor), isTrue);
      await frames(t, 10);
      await t.tap(find.text('Cancel'));
      await frames(t, 10);
      expect(cellAt(editor, 0, 0).children.single.type, 'paragraph');
      expect(find.byType(MathBlockComponentWidget), findsNothing);
    });

    testWidgets('the slash menu inserts a block equation into an empty cell', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['', 'b'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      editor.selection = Selection.collapsed(
        Position(path: cellAt(editor, 0, 0).children.first.path),
      );
      unawaited(
        mathMenuItem.handler(
          editor,
          _FakeMenu(),
          t.element(find.byType(AppFlowyEditor)),
        ),
      );
      await frames(t, 10);
      expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('math-source')), 'z');
      await t.tap(find.text('Done'));
      await frames(t, 10);
      expect(cellAt(editor, 0, 0).children.first.type, 'math_equation');
      expect(snapshot(c), '\$\$z\$\$ | b');
    });

    testWidgets('the slash menu equation in a cell with text goes inline', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['ab', 'b'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      editor.selection = Selection.collapsed(
        Position(path: cellAt(editor, 0, 0).children.first.path, offset: 1),
      );
      unawaited(
        mathMenuItem.handler(
          editor,
          _FakeMenu(),
          t.element(find.byType(AppFlowyEditor)),
        ),
      );
      await frames(t, 10);
      await t.enterText(find.byKey(const ValueKey('math-source')), 'q');
      await t.tap(find.text('Done'));
      await frames(t, 10);
      expect(snapshot(c), 'a\$q\$b | b');
    });

    testWidgets(r'$latex$ in a cell becomes an inline equation and edits', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            [r'n $x^2', 'b'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final p = cellAt(editor, 0, 0).children.first;
      editor.selection = Selection.collapsed(Position(path: p.path, offset: 6));
      expect(await inlineMathShortcut.execute(editor), isTrue);
      await frames(t, 10);
      expect(find.byType(Math), findsOneWidget);
      expect(snapshot(c), r'n $x^2$ | b');

      await t.tap(find.byType(Math));
      await frames(t, 10);
      expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('math-source')), r'\pi');
      await t.tap(find.text('Done'));
      await frames(t, 10);
      expect(snapshot(c), r'n $\pi$ | b');
      expect(t.takeException(), isNull);
    });

    testWidgets('a tall inline equation makes its row, and the box, grow', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['a', 'b'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final before = c.page.node('n')!.bounds!.height;
      final p = cellAt(editor, 0, 0).children.first;
      await editor.apply(
        editor.transaction..insertText(
          p,
          1,
          NoteFormat.inlineMathChar,
          attributes: {'formula': r'\sum_{i=0}^{n}\frac{\frac{a}{b}}{c}'},
        ),
      );
      await frames(t, 12);
      expect(find.byType(Math), findsOneWidget);
      expect(c.page.node('n')!.bounds!.height, greaterThan(before));
    });

    testWidgets('a formula cell next to a math cell does not disturb it', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            [r'$$', '=A1'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      expect(valueAt(editor, 0, 1), r'$$');
      expect(snapshot(c), r'$$ | $$');
    });

    /// Duplicates row or column [index] the way a user does: hover the
    /// table, open the handle's menu and pick "Duplicate".
    Future<void> duplicate(
      WidgetTester t,
      EditorState editor,
      TableDirection dir,
      int index,
    ) async {
      final tableNode = editor.document.root.children.first;
      final cell = cellAt(
        editor,
        dir == TableDirection.row ? index : 0,
        dir == TableDirection.col ? index : 0,
      );
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(t.getCenter(find.byKey(cell.key)));
      await frames(t);
      await t.tap(find.byKey(ValueKey('table-handle-${dir.name}-$index')));
      await frames(t);
      final l10n = AppFlowyEditorL10n.current;
      await t.tap(
        find.text(
          dir == TableDirection.row ? l10n.rowDuplicate : l10n.colDuplicate,
        ),
      );
      await frames(t, 20);
      expect(tableNode.parent, isNotNull);
    }

    testWidgets('duplicating a row shifts its formulas down a row', (t) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', '10'],
            [r'=A1+$B$1', '=B1'],
            ['x', '=SUM(A1:A2)'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      await duplicate(t, editor, TableDirection.row, 1);
      expect(tableNode.attributes['rowsLen'], 4);
      // The original is as before; the copy is shifted by one row.
      expect(textAt(editor, 1, 0), r'=A1+$B$1');
      expect(textAt(editor, 2, 0), r'=A2+$B$1');
      expect(textAt(editor, 2, 1), '=B2');
      expect(textAt(editor, 3, 1), '=SUM(A1:A2)');
      expect(valueAt(editor, 1, 0), '11');
      expect(valueAt(editor, 2, 0), '21');
      expect(valueAt(editor, 2, 1), '10');
      expect(t.takeException(), isNull);
    });

    testWidgets('duplicating a column shifts its formulas right', (t) async {
      final c = await pump(
        t,
        doc([
          table([
            ['2', r'=A1*$A$1'],
            ['3', r'=A2*A$1'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      await duplicate(t, editor, TableDirection.col, 1);
      expect(tableNode.attributes['colsLen'], 3);
      expect(textAt(editor, 0, 1), r'=A1*$A$1');
      expect(textAt(editor, 0, 2), r'=B1*$A$1');
      expect(textAt(editor, 1, 2), r'=B2*B$1');
      expect(valueAt(editor, 0, 2), '8');
      expect(valueAt(editor, 1, 2), '24');
      expect(t.takeException(), isNull);
    });

    testWidgets('duplicating a column shifts column parts only', (t) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', r'=A1+B$1', 'x'],
            ['2', r'=A$1', 'y'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      await duplicate(t, editor, TableDirection.col, 1);
      expect(textAt(editor, 0, 1), '=A1+B\$1');
      expect(textAt(editor, 0, 2), '=B1+C\$1');
      // The column after the copy moved on, its content with it.
      expect(textAt(editor, 0, 3), 'x');
      expect(textAt(editor, 1, 2), '=B\$1');
      expect(textAt(editor, 1, 3), 'y');
    });

    testWidgets('duplicating a row adjusts references to rows after it', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', '=A1'],
            ['2', '=A2+A3'],
            ['3', '=SUM(A1:A3)'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      await duplicate(t, editor, TableDirection.row, 0);
      // Rows: 1, copy of 1, 2, 3. References to rows 2 and 3 follow them.
      expect(textAt(editor, 0, 1), '=A1');
      expect(textAt(editor, 1, 1), '=A2');
      expect(textAt(editor, 2, 1), '=A3+A4');
      expect(textAt(editor, 3, 1), '=SUM(A1:A4)');
      expect(textAt(editor, 1, 0), '1');
      expect(valueAt(editor, 3, 1), '7');
    });

    testWidgets('undo of a duplicate restores the table in one step', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', r'=A1+$A$1'],
            ['2', '=SUM(A1:A2)'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      await duplicate(t, editor, TableDirection.row, 0);
      expect(tableNode.attributes['rowsLen'], 3);
      expect(textAt(editor, 1, 1), r'=A2+$A$1');
      // The copy, the moved rows and every rewritten formula are one undo
      // step, and the only one.
      expect(editor.undoManager.undoStack.length, 1);
      final ops =
          (editor.undoManager.undoStack.last as dynamic).operations
              as List<Operation>;
      // The inserted cells (one per column) and the formula rewrites.
      expect(ops.whereType<InsertOperation>(), hasLength(2));
      expect(ops.whereType<UpdateOperation>().length, greaterThan(2));
      editor.undoManager.undo();
      await frames(t, 10);
      expect(tableNode.attributes['rowsLen'], 2);
      expect(textAt(editor, 0, 1), r'=A1+$A$1');
      expect(textAt(editor, 1, 1), '=SUM(A1:A2)');
      expect(valueAt(editor, 1, 1), '3');
    });

    testWidgets('a formula typed by hand is not shifted', (t) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', r'=A1+$B$1'],
            ['2', ''],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final empty = cellAt(editor, 1, 1).children.first;
      await editor.apply(editor.transaction..insertText(empty, 0, r'=A1+$B$1'));
      await frames(t, 10);
      expect(textAt(editor, 1, 1), r'=A1+$B$1');
      expect(textAt(editor, 0, 1), r'=A1+$B$1');
    });

    testWidgets('inserting a row or column is not taken for a duplicate', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', '=A1'],
            ['', ''],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final tableNode = editor.document.root.children.first;
      TableActions.add(tableNode, 1, editor, TableDirection.row);
      await frames(t, 10);
      expect(textAt(editor, 1, 1), '');
      expect(textAt(editor, 0, 1), '=A1');
      TableActions.add(tableNode, 2, editor, TableDirection.col);
      await frames(t, 10);
      expect(textAt(editor, 0, 2), '');
      expect(textAt(editor, 0, 1), '=A1');
    });

    testWidgets('appflowy duplicate item is gone from the menu', (t) async {
      final c = await pump(t, sample());
      final editor = await edit(t, c);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(t.getCenter(find.byKey(cellAt(editor, 0, 0).key)));
      await frames(t);
      await t.tap(find.byKey(const ValueKey('table-handle-row-0')));
      await frames(t);
      final l10n = AppFlowyEditorL10n.current;
      expect(find.text(l10n.rowDuplicate), findsOneWidget);
      expect(find.text(l10n.rowAddBefore), findsOneWidget);
    });

    Future<void> chord(WidgetTester t, LogicalKeyboardKey key) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.control);
      await t.sendKeyEvent(key);
      await t.sendKeyUpEvent(LogicalKeyboardKey.control);
      await frames(t);
    }

    testWidgets('copy and paste of a formula cell shifts its references', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['1', r'=A1*2+$A$1'],
            ['2', ''],
            ['3', 'plain'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      Node para(int r, int col) => cellAt(editor, r, col).children.first;
      editor.selection = Selection(
        start: Position(path: para(0, 1).path),
        end: Position(path: para(0, 1).path, offset: 10),
      );
      await frames(t);
      await chord(t, LogicalKeyboardKey.keyC);
      // The platform clipboard channel does not answer inside the test's
      // fake-async zone: stand in for it.
      AppFlowyClipboard.mockSetData(
        const AppFlowyClipboardData(text: r'=A1*2+$A$1'),
      );
      addTearDown(() => AppFlowyClipboard.mockSetData(null));
      editor.selection = Selection.collapsed(Position(path: para(1, 1).path));
      await frames(t);
      await chord(t, LogicalKeyboardKey.keyV);
      expect(textAt(editor, 1, 1), r'=A2*2+$A$1');
      expect(valueAt(editor, 1, 1), '5');
      expect(textAt(editor, 0, 1), r'=A1*2+$A$1');
      // Two rows down, in a cell that had text: replaced when selected.
      editor.selection = Selection(
        start: Position(path: para(2, 1).path),
        end: Position(path: para(2, 1).path, offset: 5),
      );
      await frames(t);
      await chord(t, LogicalKeyboardKey.keyV);
      expect(textAt(editor, 2, 1), r'=A3*2+$A$1');
      expect(valueAt(editor, 2, 1), '7');
      expect(t.takeException(), isNull);
    });
  });
}

/// The equation menu item does not use the menu service.
class _FakeMenu implements SelectionMenuService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
