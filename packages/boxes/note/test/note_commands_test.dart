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
    t.view.physicalSize = const Size(1200, 800);
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

  Finder button(String tooltip) => find.ancestor(
    of: find.byTooltip(tooltip),
    matching: find.byType(IconButton),
  );

  bool enabled(WidgetTester t, String tooltip) =>
      t.widget<IconButton>(button(tooltip)).onPressed != null;

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
}
