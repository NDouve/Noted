// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The note under the host's editor focus hold (an app menu has the focus for a
// moment): the editor stays mounted, and the selection comes back.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'note_module_test.dart' show noteBox;

void main() {
  late ModuleRegistry modules;

  setUp(() {
    modules = ModuleRegistry()..register(const NoteModule(), alwaysOn: true, isDefault: true);
  });

  Future<void> frames(WidgetTester t, [int n = 4]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  // A note being edited, with the caret in the first line, and a node that
  // stands for the menu bar.
  Future<(CanvasController, FocusNode, EditorState)> pumpEditing(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0))
          .insertNode(noteBox('n', ['hello brave new world', 'second line'])),
      modules,
    );
    final menu = FocusNode(debugLabel: 'menu');
    addTearDown(menu.dispose);
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(
          body: Column(
            children: [
              Focus(focusNode: menu, child: const SizedBox(height: 20)),
              Expanded(child: PageCanvas(controller: c)),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
    final b = c.page.node('n')!.bounds!;
    await t.tapAt(
      canvas.view!.toScreen(Offset(b.x + 40, b.y + 12)) +
          const Offset(0, 20 + CommandToolbar.height),
    );
    await frames(t);
    expect(c.editingId, 'n');
    final editor = t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
    return (c, menu, editor);
  }

  testWidgets('the selection comes back after focus goes to the menu and back under the hold', (
    t,
  ) async {
    final (c, menu, editor) = await pumpEditing(t);
    final selection = Selection(
      start: Position(path: [0], offset: 5),
      end: Position(path: [0], offset: 9),
    );
    editor.updateSelectionWithReason(selection, reason: SelectionUpdateReason.uiEvent);
    await frames(t);
    expect(editor.selection, selection);
    final origin = FocusManager.instance.primaryFocus!;

    c.editorFocusHold.hold();
    menu.requestFocus();
    await frames(t);
    expect(editor.selection, isNull, reason: 'appflowy clears it when the editor loses focus');
    expect(c.editingId, 'n');
    expect(find.byType(AppFlowyEditor), findsOneWidget, reason: 'not demoted to the light view');

    origin.requestFocus();
    await frames(t);
    c.editorFocusHold.release();
    await frames(t);
    expect(editor.selection, selection, reason: 'the 5 to 9 selection, not null and not the start');
    expect(c.editingId, 'n');
    expect(find.byType(AppFlowyEditor), findsOneWidget);
  });

  testWidgets('a caret goes back where it was', (t) async {
    final (c, menu, editor) = await pumpEditing(t);
    final caret = Selection.collapsed(Position(path: [1], offset: 3));
    editor.updateSelectionWithReason(caret, reason: SelectionUpdateReason.uiEvent);
    await frames(t);
    final origin = FocusManager.instance.primaryFocus!;
    c.editorFocusHold.hold();
    menu.requestFocus();
    await frames(t);
    origin.requestFocus();
    await frames(t);
    c.editorFocusHold.release();
    await frames(t);
    expect(editor.selection, caret);
  });

  testWidgets(
    'a note that lost focus under the hold goes back to the light view after the release',
    (t) async {
      final (c, menu, _) = await pumpEditing(t);
      c.editorFocusHold.hold();
      menu.requestFocus();
      await frames(t);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      c.editorFocusHold.release();
      await frames(t);
      expect(c.editingId, isNull);
      expect(
        find.byType(AppFlowyEditor),
        findsNothing,
        reason: 'it demotes as it would without the menu',
      );
    },
  );

  testWidgets('without a hold, focus going away demotes the note and clears the selection', (
    t,
  ) async {
    final (c, menu, _) = await pumpEditing(t);
    menu.requestFocus();
    await frames(t);
    expect(c.editingId, isNull);
    expect(find.byType(AppFlowyEditor), findsNothing);
  });
}
