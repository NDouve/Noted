// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'note_module_test.dart' show noteBox;

void main() {
  Future<CanvasController> open(WidgetTester t) async {
    final modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true);
    final conflicted = noteBox('a', ['my text']).withConflict(
      BoxConflict.other(
        node: noteBox('a', ['their text']).toRaw(),
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
    await t.pump(const Duration(milliseconds: 400));
    return c;
  }

  testWidgets('the issue dialog shows both note versions and keeps the other', (t) async {
    final c = await open(t);
    expect(find.byKey(const ValueKey('issues-dialog')), findsOneWidget);
    expect(find.text('LAPTOP · saved 2026-10-25 10:30'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('conflict-mine')), matching: find.text('my text')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('conflict-theirs')), matching: find.text('their text')),
      findsOneWidget,
    );
    // Nothing manual: choose a version.
    expect(find.byKey(const ValueKey('conflict-edit')), findsNothing);
    await t.tap(find.byKey(const ValueKey('conflict-keep-theirs')));
    await t.pump(const Duration(milliseconds: 400));
    final n = c.page.node('a')! as BoxRecord;
    expect(n.snapshotText, 'their text');
    expect(n.isConflicted, isFalse);
    expect(c.canUndo, isTrue);
    c.undo();
    expect((c.page.node('a')! as BoxRecord).snapshotText, 'my text');
    expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
  });

  testWidgets('place both keeps the note and adds the other as a new note', (t) async {
    final c = await open(t);
    await t.tap(find.byKey(const ValueKey('conflict-place-both')));
    await t.pump(const Duration(milliseconds: 400));
    expect(c.page.nodes, hasLength(2));
    expect((c.page.node('a')! as BoxRecord).snapshotText, 'my text');
    final added = c.page.nodes.firstWhere((n) => n.id != 'a') as BoxRecord;
    expect(added.snapshotText, 'their text');
    expect(added.typeId, NoteCodec.id);
    expect(added.isConflicted, isFalse);
    c.undo();
    expect(c.page.nodes, hasLength(1));
    expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
  });
}
