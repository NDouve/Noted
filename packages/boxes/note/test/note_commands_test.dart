// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_note/src/math_input.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

BoxRecord _note(String id, List<String> lines) {
  const codec = NoteCodec();
  final data = NoteData({
    'document': {
      'type': 'page',
      'children': [
        for (final l in lines)
          {
            'type': 'paragraph',
            'data': {
              'delta': [
                {'insert': l},
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
    bounds: const Bounds(100, 100, 300, 40),
    data: RawJson.encode(codec.encode(data)),
    snapshotText: codec.snapshotText(data),
    rev: 'r',
  );
}

void main() {
  late CanvasController c;

  Future<void> frames(WidgetTester t, [int n = 6]) async {
    // A focused editor blinks its cursor forever: never pumpAndSettle.
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester t, {CanvasToolSelection? tools}) async {
    // Wide enough for the text tools and Table and Equation in the test font.
    t.view.physicalSize = const Size(1600, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true);
    c = CanvasController(
      NotedPage.create(
        PageMeta.create(id: 'p', title: '', order: 0),
      ).insertNode(_note('n', ['first line'])),
      modules,
    );
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c, tools: tools)),
      ),
    );
    await t.pumpAndSettle();
  }

  PageCanvasState canvas(WidgetTester t) =>
      t.state<PageCanvasState>(find.byType(PageCanvas));

  // Table and Equation are ghost text buttons inside their tooltip.
  Finder button(String tooltip) => find.descendant(
    of: find.byTooltip(tooltip),
    matching: find.byType(TextButton),
  );

  bool enabled(WidgetTester t, String tooltip) =>
      t.widget<TextButton>(button(tooltip)).onPressed != null;

  Future<EditorState> focusNote(WidgetTester t) async {
    final b = c.page.node('n')!.bounds!;
    await t.tapAt(
      canvas(t).view!.toScreen(Offset(b.x + 40, b.y + 10)) +
          const Offset(0, CommandToolbar.height),
    );
    await frames(t);
    expect(c.editingId, 'n');
    return t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
  }

  testWidgets('insert table and insert equation are on the toolbar with their ids', (t) async {
    await pump(t);
    expect(find.byTooltip('Insert table'), findsOneWidget);
    expect(find.byTooltip('Insert equation'), findsOneWidget);
    final r = canvas(t).commands;
    expect(r[NoteCommands.insertTable], isNotNull);
    expect(r[NoteCommands.insertEquation], isNotNull);
    expect(NoteCommands.insertTable, 'noted.note.insertTable');
    expect(NoteCommands.insertEquation, 'noted.note.insertEquation');
  });

  testWidgets('they are enabled only while a note editor has focus', (t) async {
    await pump(t);
    expect(enabled(t, 'Insert table'), isFalse);
    expect(enabled(t, 'Insert equation'), isFalse);

    await focusNote(t);
    expect(enabled(t, 'Insert table'), isTrue);
    expect(enabled(t, 'Insert equation'), isTrue);

    // Focus going back to the canvas (a tool is picked, a grip is tapped).
    canvas(t).focusCanvas();
    await frames(t);
    expect(enabled(t, 'Insert table'), isFalse);
    expect(enabled(t, 'Insert equation'), isFalse);
  });

  testWidgets('insert table adds a table at the caret, like the slash menu', (t) async {
    await pump(t);
    final editor = await focusNote(t);
    expect(editor.document.root.children.map((n) => n.type), ['paragraph']);

    await t.tap(find.byTooltip('Insert table'));
    await frames(t);

    final types = editor.document.root.children.map((n) => n.type).toList();
    expect(types, ['paragraph', NoteFormat.tableType]);
    // The caret moves into the new table's first cell, as after /table.
    final sel = editor.selection!;
    expect(sel.isCollapsed, isTrue);
    expect(sel.end.path.first, 1);
    // The change reached the page through the codec.
    expect((c.page.node('n')! as BoxRecord).snapshotText, contains('first line'));
    expect(enabled(t, 'Insert table'), isTrue, reason: 'still focused');
  });

  testWidgets('insert equation adds an equation block after the caret line', (t) async {
    await pump(t);
    final editor = await focusNote(t);
    await t.tap(find.byTooltip('Insert equation'));
    await frames(t);
    final types = editor.document.root.children.map((n) => n.type).toList();
    expect(types.first, 'paragraph');
    expect(types[1], NoteFormat.mathBlockType);
    // Like the slash menu it asks for the formula.
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('with nothing focused the commands do nothing', (t) async {
    await pump(t);
    final before = (c.page.node('n')! as BoxRecord).snapshotText;
    expect(await canvas(t).commands.invoke(NoteCommands.insertTable), isFalse);
    expect(await canvas(t).commands.invoke(NoteCommands.insertEquation), isFalse);
    expect((c.page.node('n')! as BoxRecord).snapshotText, before);
  });

  testWidgets('Escape in a note with nothing open leaves the editor for Select', (t) async {
    final selection = CanvasToolSelection();
    addTearDown(selection.dispose);
    await pump(t, tools: selection);
    final editor = await focusNote(t);
    editor.selection = Selection.collapsed(Position(path: [0], offset: 2));
    await frames(t);
    expect(enabled(t, 'Insert table'), isTrue);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    expect(c.editingId, isNull);
    expect(enabled(t, 'Insert table'), isFalse);
    expect(selection.active, isNull);
    expect(c.page.node('n'), isNotNull, reason: 'a box with text stays');
  });

  testWidgets('Escape leaves the editor and an empty new box is discarded', (t) async {
    await pump(t);
    c.createBoxAt(const Bounds(500, 300, 0, 0));
    await frames(t);
    expect(c.editingId, isNotNull);
    final id = c.editingId!;
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    expect(c.editingId, isNull);
    expect(c.page.node(id), isNull);
  });

  testWidgets('Escape with a range selected clears it first; the next one leaves', (t) async {
    await pump(t);
    final editor = await focusNote(t);
    editor.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
    await frames(t);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    expect(editor.selection, isNull);
    expect(c.editingId, 'n', reason: 'first Escape only closed the selection');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    expect(c.editingId, isNull);
  });

  testWidgets('Escape with the slash menu open closes it; the next one leaves', (t) async {
    await pump(t);
    final editor = await focusNote(t);
    editor.selection = Selection.collapsed(Position(path: [0], offset: 10));
    await frames(t);
    await noteSlashCommand.execute(editor);
    await frames(t);
    expect(find.byType(SelectionMenuWidget), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    expect(find.byType(SelectionMenuWidget), findsNothing);
    expect(c.editingId, 'n', reason: 'the menu took the first Escape');

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    expect(c.editingId, isNull);
  });

  group('formatting commands', () {
    const formatting = [
      NoteCommands.paragraph,
      NoteCommands.heading1,
      NoteCommands.heading2,
      NoteCommands.heading3,
      NoteCommands.bold,
      NoteCommands.italic,
      NoteCommands.underline,
      NoteCommands.strikethrough,
      NoteCommands.highlight,
      NoteCommands.bulletedList,
      NoteCommands.numberedList,
      NoteCommands.checkList,
      NoteCommands.outdent,
      NoteCommands.indent,
      NoteCommands.clearFormatting,
      NoteCommands.insertDateTime,
    ];

    Future<void> run(WidgetTester t, String id) async {
      expect(await canvas(t).commands.invoke(id), isTrue, reason: id);
      await frames(t);
    }

    bool? isChecked(WidgetTester t, String id) => canvas(t).commands[id]!.checked;

    Map<String, dynamic>? marks(EditorState e) =>
        e.document.root.children.first.delta!.toJson().first['attributes'] as Map<String, dynamic>?;

    testWidgets('all registered, enabled only while a note has focus', (t) async {
      await pump(t);
      final r = canvas(t).commands;
      for (final id in formatting) {
        expect(r[id], isNotNull, reason: id);
        expect(r[id]!.enabled, isFalse, reason: id);
      }
      await focusNote(t);
      for (final id in formatting) {
        expect(r[id]!.enabled, isTrue, reason: id);
      }
    });

    testWidgets('bold, italic, underline, strikethrough toggle the selected text and show checked', (
      t,
    ) async {
      await pump(t);
      final editor = await focusNote(t);
      editor.selection = Selection.single(path: [0], startOffset: 0, endOffset: 10);
      await frames(t);
      for (final (id, key) in [
        (NoteCommands.bold, 'bold'),
        (NoteCommands.italic, 'italic'),
        (NoteCommands.underline, 'underline'),
        (NoteCommands.strikethrough, 'strikethrough'),
      ]) {
        expect(isChecked(t, id), isFalse, reason: id);
        await run(t, id);
        expect(marks(editor)?[key], isTrue, reason: id);
        expect(isChecked(t, id), isTrue, reason: id);
      }
      await run(t, NoteCommands.bold);
      expect(marks(editor)?['bold'], isNot(isTrue));
      expect(isChecked(t, NoteCommands.bold), isFalse);
      // The change reached the page.
      expect(
        (c.page.node('n')! as BoxRecord).data!.text,
        contains('italic'),
      );
    });

    testWidgets('highlight marks the selection; clear formatting removes it all', (t) async {
      await pump(t);
      final editor = await focusNote(t);
      editor.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
      await frames(t);
      await run(t, NoteCommands.highlight);
      await run(t, NoteCommands.bold);
      expect(marks(editor)?['bg_color'], isNotNull);
      expect(marks(editor)?['bold'], isTrue);
      await run(t, NoteCommands.clearFormatting);
      expect(marks(editor), anyOf(isNull, isEmpty));
    });

    testWidgets('styles and lists change the block, keep its text, and show checked', (t) async {
      await pump(t);
      final editor = await focusNote(t);
      Node block() => editor.document.root.children.first;
      for (final (id, type) in [
        (NoteCommands.heading2, 'heading'),
        (NoteCommands.bulletedList, 'bulleted_list'),
        (NoteCommands.numberedList, 'numbered_list'),
        (NoteCommands.checkList, 'todo_list'),
        (NoteCommands.paragraph, 'paragraph'),
      ]) {
        await run(t, id);
        expect(block().type, type, reason: id);
        expect(block().delta!.toPlainText(), 'first line', reason: id);
        expect(isChecked(t, id), isTrue, reason: id);
      }
      await run(t, NoteCommands.heading2);
      expect(block().attributes['level'], 2);
      expect(isChecked(t, NoteCommands.heading1), isFalse);
      // A list command on a list of its kind turns it back into body text.
      await run(t, NoteCommands.bulletedList);
      await run(t, NoteCommands.bulletedList);
      expect(block().type, 'paragraph');
    });

    testWidgets('indent and outdent nest a list item under the one above', (t) async {
      await pump(t);
      final editor = await focusNote(t);
      // Two bullets: the second can be indented under the first.
      editor.selection = Selection.collapsed(Position(path: [0], offset: 10));
      await frames(t);
      await editor.insertNewLine();
      await editor.insertTextAtCurrentSelection('second');
      editor.selection = Selection(
        start: Position(path: [0]),
        end: Position(path: [1], offset: 6),
      );
      await run(t, NoteCommands.bulletedList);
      editor.selection = Selection.collapsed(Position(path: [1], offset: 2));
      await frames(t);
      await run(t, NoteCommands.indent);
      expect(editor.document.root.children, hasLength(1));
      expect(editor.document.root.children.first.children.single.delta!.toPlainText(), 'second');
      await run(t, NoteCommands.outdent);
      expect(editor.document.root.children, hasLength(2));
    });

    testWidgets('insert date and time writes it at the caret', (t) async {
      await pump(t);
      final editor = await focusNote(t);
      editor.selection = Selection.collapsed(Position(path: [0], offset: 10));
      await frames(t);
      final before = DateTime.now();
      await run(t, NoteCommands.insertDateTime);
      final text = editor.document.root.children.first.delta!.toPlainText();
      expect(text, startsWith('first line'));
      expect(text.substring(10), matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d$')));
      expect(text.substring(10, 20), formatDateTime(before).substring(0, 10));
      expect(formatDateTime(DateTime(2026, 3, 4, 5, 6)), '2026-03-04 05:06');
    });

    testWidgets('the toolbar button works without taking focus from the note', (t) async {
      await pump(t);
      final editor = await focusNote(t);
      editor.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
      await frames(t);
      await t.tap(find.byTooltip('Bold (Ctrl+B)'));
      await frames(t);
      expect(marks(editor)?['bold'], isTrue);
      expect(c.editingId, 'n');
      expect(canvas(t).commands[NoteCommands.bold]!.enabled, isTrue);
    });
  });
}
