// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_note/src/math_blocks.dart';
import 'package:noted_box_note/src/math_input.dart';
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

Map<String, Object?> inlineMath(String formula) => {
  'insert': NoteFormat.inlineMathChar,
  'attributes': {'formula': formula},
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

BoxRecord noteBoxOf(NoteData data, {double height = 40}) => BoxRecord.create(
  id: 'n',
  typeId: NoteCodec.id,
  dataVersion: 1,
  bounds: Bounds(100, 100, 300, height),
  data: RawJson.encode(codec.encode(data)),
  snapshotText: codec.snapshotText(data),
  rev: 'r',
);

void main() {
  group('codec', () {
    test('a table is one snapshot line per row, cells joined by " | "', () {
      final data = doc([
        para('before'),
        table([
          ['name', 'qty'],
          ['apple', '3'],
          ['pear', ''],
        ]),
        para('after'),
      ]);
      expect(
        codec.snapshotText(data),
        'before\nname | qty\napple | 3\npear | \nafter',
      );
      expect(codec.isEmpty(data), isFalse);
    });

    test(r'a block equation is $$latex$$, an inline one $latex$', () {
      final data = doc([
        blockMath(r'\frac{a}{b}'),
        {
          'type': 'paragraph',
          'data': {
            'delta': [
              {'insert': 'area is '},
              inlineMath('\\pi r^2'),
              {'insert': ' ok'},
            ],
          },
        },
      ]);
      expect(
        codec.snapshotText(data),
        '\$\$\\frac{a}{b}\$\$\narea is \$\\pi r^2\$ ok',
      );
      expect(codec.aiExposure(data), isA<AiText>());
      expect(codec.isEmpty(data), isFalse);
      expect(codec.isEmpty(doc([blockMath('')])), isFalse);
    });

    test('equations survive encode and decode unchanged', () {
      final data = doc([
        blockMath(r'\sum_{i=0}^n i'),
        {
          'type': 'paragraph',
          'data': {
            'delta': [
              inlineMath('x'),
              {'insert': 'y'},
            ],
          },
        },
        table([
          ['a', 'b'],
        ]),
      ]);
      final json = jsonDecode(jsonEncode(codec.encode(data)));
      final back = codec.decode(json, 1);
      expect(back.document, data.document);
      expect(codec.dataVersion, 1);
      // And through appflowy's own document model.
      final viaEditor = Document.fromJson(
        jsonDecode(jsonEncode(data.document)) as Map<String, Object?>,
      ).toJson();
      expect(jsonDecode(jsonEncode(viaEditor)), data.document);
    });

    test('a note with no equations or tables reads as before', () {
      final data = doc([para('one'), para('two')]);
      expect(codec.snapshotText(data), 'one\ntwo');
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

    /// The slash menu is a lazy list: scroll until [label] is built.
    Future<void> revealMenuItem(WidgetTester t, String label) async {
      await t.scrollUntilVisible(
        find.text(label),
        60,
        scrollable: find
            .descendant(
              of: find.byType(SelectionMenuWidget),
              matching: find.byType(Scrollable),
            )
            .last,
        duration: const Duration(milliseconds: 50),
      );
      await t.ensureVisible(find.text(label));
      await t.pump();
    }

    /// Clicks the box open for editing and returns its editor state.
    Future<EditorState> edit(WidgetTester t, CanvasController c) async {
      final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
      final b = c.page.node('n')!.bounds!;
      // The top-left corner of the box: a paragraph, not an equation or cell.
      await t.tapAt(canvas.view!.toScreen(Offset(b.x + 20, b.y + 10)) + const Offset(0, CommandToolbar.height));
      await frames(t);
      expect(c.editingId, 'n');
      return t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
    }

    testWidgets('block and inline equations render with the LaTeX renderer', (
      t,
    ) async {
      await pump(
        t,
        doc([
          blockMath(r'\frac{a}{b}'),
          {
            'type': 'paragraph',
            'data': {
              'delta': [
                {'insert': 'area '},
                inlineMath('\\pi r^2'),
              ],
            },
          },
        ]),
      );
      expect(find.byType(MathBlockComponentWidget), findsOneWidget);
      // One Math for the block, one for the inline run.
      expect(find.byType(Math), findsNWidgets(2));
      expect(find.byType(MathErrorPlaceholder), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('invalid LaTeX shows an error placeholder, not an exception', (
      t,
    ) async {
      await pump(
        t,
        doc([
          blockMath(r'\frac{1}{'),
          {
            'type': 'paragraph',
            'data': {
              'delta': [inlineMath(r'\notacommand{x}')],
            },
          },
        ]),
      );
      expect(find.byType(MathErrorPlaceholder), findsNWidgets(2));
      expect(t.takeException(), isNull);
    });

    testWidgets('an empty equation shows a hint', (t) async {
      await pump(t, doc([blockMath('')]));
      expect(find.textContaining('Empty equation'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a table renders in the box, which grows to fit it', (t) async {
      final c = await pump(
        t,
        doc([
          table([
            ['a', 'b'],
            ['c', 'd'],
            ['e', 'f'],
          ]),
        ]),
      );
      expect(find.byType(TableBlockComponentWidget), findsOneWidget);
      expect(find.text('c', findRichText: true), findsOneWidget);
      // Three rows of at least 40 px each, plus borders and padding.
      expect(c.page.node('n')!.bounds!.height, greaterThan(130));
      expect(t.takeException(), isNull);
    });

    testWidgets('editing a table cell commits and shows in the snapshot', (
      t,
    ) async {
      final c = await pump(
        t,
        doc([
          table([
            ['a', 'b'],
            ['c', 'd'],
          ]),
        ]),
      );
      final editor = await edit(t, c);
      final cell = editor.document.root.children.first.children
          .firstWhere(
            (n) =>
                n.attributes['colPosition'] == 1 &&
                n.attributes['rowPosition'] == 0,
          )
          .children
          .first;
      await editor.apply(editor.transaction..insertText(cell, 1, 'ZZ'));
      await frames(t);
      final box = c.page.node('n')! as BoxRecord;
      expect(box.snapshotText, 'a | bZZ\nc | d');
    });

    testWidgets('the slash menu inserts a table that then grows the box', (
      t,
    ) async {
      final c = await pump(t, doc([para('')]));
      final before = c.page.node('n')!.bounds!.height;
      final editor = await edit(t, c);
      editor.selection = Selection.collapsed(Position(path: [0]));
      await noteSlashCommand.execute(editor);
      await frames(t);
      // The menu offers both appflowy's table and the equation.
      await revealMenuItem(t, 'Equation');
      expect(find.text('Equation'), findsOneWidget);
      await t.tap(find.text('Table'));
      await frames(t, 10);
      expect(editor.document.root.children.first.type, 'table');
      expect(find.byType(TableBlockComponentWidget), findsOneWidget);
      expect(c.page.node('n')!.bounds!.height, greaterThan(before + 60));
      expect(t.takeException(), isNull);
    });

    testWidgets('the slash menu inserts a block equation and edits it', (
      t,
    ) async {
      final c = await pump(t, doc([para('')]));
      final editor = await edit(t, c);
      editor.selection = Selection.collapsed(Position(path: [0]));
      await noteSlashCommand.execute(editor);
      await frames(t);
      await revealMenuItem(t, 'Equation');
      await t.tap(find.text('Equation'));
      await frames(t, 10);
      // The formula dialog opens straight away.
      expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('math-source')), r'x^2');
      await frames(t);
      expect(find.byType(Math), findsOneWidget, reason: 'live preview');
      await t.tap(find.text('Done'));
      await frames(t, 10);
      final root = editor.document.root;
      expect(root.children.first.type, 'math_equation');
      expect(root.children.first.attributes['formula'], 'x^2');
      expect(find.byType(Math), findsOneWidget);
      expect(
        (c.page.node('n')! as BoxRecord).snapshotText,
        startsWith(r'$$x^2$$'),
      );
    });

    testWidgets(r'"$$ " at the start of a line makes a block equation', (
      t,
    ) async {
      final c = await pump(t, doc([para(r'$$')]));
      final editor = await edit(t, c);
      editor.selection = Selection.collapsed(Position(path: [0], offset: 2));
      expect(await blockMathShortcut.execute(editor), isTrue);
      await frames(t, 10);
      expect(editor.document.root.children.first.type, 'math_equation');
      expect(editor.document.root.children[1].type, 'paragraph');
      expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await frames(t, 10);
      expect(find.textContaining('Empty equation'), findsOneWidget);
    });

    testWidgets(r'a closing "$" turns $latex into an inline equation', (
      t,
    ) async {
      final c = await pump(t, doc([para(r'see $x^2')]));
      final editor = await edit(t, c);
      editor.selection = Selection.collapsed(Position(path: [0], offset: 8));
      expect(await inlineMathShortcut.execute(editor), isTrue);
      await frames(t);
      final node = editor.getNodeAtPath([0])!;
      expect(jsonDecode(jsonEncode(node.delta!.toJson())), [
        {'insert': 'see '},
        inlineMath('x^2'),
      ]);
      expect(
        editor.selection,
        Selection.collapsed(Position(path: [0], offset: 5)),
      );
      expect(find.byType(Math), findsOneWidget);
      expect((c.page.node('n')! as BoxRecord).snapshotText, r'see $x^2$');

      // Text typed next to the equation does not become part of it.
      await editor.apply(editor.transaction..insertText(node, 5, ' end'));
      expect(node.delta!.toList().last.attributes, anyOf(isNull, isEmpty));

      // Prices are left alone: "$5 and $" has a space before the closing $.
      await editor.apply(editor.transaction..insertText(node, 9, r' $5 and '));
      editor.selection = Selection.collapsed(
        Position(path: [0], offset: node.delta!.length),
      );
      expect(await inlineMathShortcut.execute(editor), isFalse);
    });

    testWidgets('tapping an inline equation edits it', (t) async {
      final c = await pump(
        t,
        doc([
          {
            'type': 'paragraph',
            'data': {
              'delta': [
                {'insert': 'a '},
                inlineMath('x'),
              ],
            },
          },
        ]),
      );
      final editor = await edit(t, c);
      await t.tap(find.byType(Math));
      await frames(t, 10);
      expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('math-source')), 'y_1');
      await t.tap(find.text('Done'));
      await frames(t, 10);
      expect((c.page.node('n')! as BoxRecord).snapshotText, 'a \$y_1\$');
      expect(editor.getNodeAtPath([0])!.delta!.toPlainText(), 'a ${NoteFormat.inlineMathChar}');
    });
  });
}
