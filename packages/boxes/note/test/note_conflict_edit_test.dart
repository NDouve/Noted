// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'note_module_test.dart' show noteBox;

void main() {
  testWidgets('Edit manually: edit the other note, use it, the box is updated', (t) async {
    final modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true);
    final mine = noteBox('a', ['my text']);
    final theirs = noteBox('a', ['their text']);
    final conflicted = mine.withConflict(
      BoxConflict.other(
        node: theirs.toRaw(),
        at: DateTime(2026, 10, 25, 10, 30).millisecondsSinceEpoch,
        device: 'LAPTOP',
      ),
    );
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(conflicted),
      modules,
      deviceName: 'DESKTOP',
    );
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.byKey(const ValueKey('conflict-badge-a')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const ValueKey('conflict-edit')));
    await t.pump(const Duration(milliseconds: 300));

    Finder editorIn(String key) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(AppFlowyEditor),
    );
    // A pane shows its note without an editor until it is clicked.
    expect(editorIn('conflict-edit-mine'), findsNothing);
    expect(editorIn('conflict-edit-theirs'), findsNothing);
    expect(find.textContaining('their text', findRichText: true), findsWidgets);
    expect(find.text('LAPTOP · saved 2026-10-25 10:30'), findsOneWidget);
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('conflict-edit-theirs')),
        matching: find.textContaining('their text', findRichText: true),
      ),
    );
    await t.pump(const Duration(milliseconds: 300));
    expect(editorIn('conflict-edit-mine'), findsNothing);
    expect(editorIn('conflict-edit-theirs'), findsOneWidget);

    // Edit the other version in its pane.
    final editor = t.widget<AppFlowyEditor>(editorIn('conflict-edit-theirs')).editorState;
    final node = editor.document.nodeAtPath([0])!;
    await editor.apply(editor.transaction..insertText(node, 10, ' plus mine'));
    await t.pump(const Duration(milliseconds: 100));
    // The page is untouched until a version is chosen.
    expect((c.page.node('a')! as BoxRecord).snapshotText, 'my text');

    await t.tap(find.byKey(const ValueKey('conflict-use-theirs')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('conflict-edit-dialog')), findsNothing);
    final n = c.page.node('a')! as BoxRecord;
    expect(n.snapshotText, 'their text plus mine');
    expect(n.isConflicted, isFalse);
    expect(n.device, 'DESKTOP');
    expect(c.canUndo, isTrue);
    c.undo();
    expect((c.page.node('a')! as BoxRecord).snapshotText, 'my text');
    expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
  });
}
