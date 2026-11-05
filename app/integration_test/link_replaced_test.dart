// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Insert link when the note's data changes from outside while the link dialog
// is open (a reload, a sync merge): the note starts over with a new editor,
// and the link must still land in it, or the user is told. Run from `app/`:
//
//     flutter test integration_test/link_replaced_test.dart -d windows

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_note/src/note_link.dart' show linkNotAddedNotice;

import 'support/harness.dart';
import 'support/note_helpers.dart';
import 'support/semantics_guard.dart';

NoteData _text(String text, [String? second]) => NoteData({
  'document': {
    'type': 'page',
    'children': [para(text), if (second != null) para(second)],
  },
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  ignorePlatformSemantics();

  Future<void> confirm(Session s, String address) async {
    await s.tester.enterText(find.byKey(const ValueKey('link-address')), address);
    await s.tester.testTextInput.receiveAction(TextInputAction.done);
    await s.until(() => find.text('Insert link').evaluate().isEmpty, what: 'the dialog to close');
    await s.pump(300);
  }

  testWidgets('the note replaced under the dialog (on a page of 30 notes): the link still lands', (t) async {
    await withSession(t, 'linkreplaced', (s) async {
      // A crowded page: the box under test is one of many.
      for (var i = 0; i < 29; i++) {
        addNote(s, [para('other $i')], x: 100 + (i % 6) * 120, y: 400 + (i ~/ 6) * 60);
      }
      final id = addNote(s, [para('go: ')]);
      await s.pump(600);
      final editor = await editNote(s, id);
      final sel = editor.selection;
      final at = sel.start.copyWith(path: [0], offset: 4);
      editor.selection = sel.copyWith(start: at, end: at);
      await s.pump(200);
      await s.ctrl(LogicalKeyboardKey.keyK);
      await s.pump(300);
      expect(find.text('Insert link'), findsOneWidget);
      // The same box, changed from outside while the dialog is open.
      s.nb.current!.replaceBoxData({id: _text('go: ', 'changed elsewhere')});
      await s.pump(600);
      expect(editor.isDisposed, isTrue, reason: 'the note started over with a new editor');
      await confirm(s, 'https://later.example');
      expect(find.text(linkNotAddedNotice), findsNothing);
      await s.flush();
      final stored = snapshotOf(s, id);
      expect(stored, contains('https://later.example'));
      expect(stored, contains('changed elsewhere'));
    });
  });

  testWidgets('the text under the saved caret gone: the user is told', (t) async {
    await withSession(t, 'linkgone', (s) async {
      final id = addNote(s, [para('a long line of text')]);
      await s.pump(600);
      final editor = await editNote(s, id);
      final sel = editor.selection;
      final at = sel.start.copyWith(path: [0], offset: 15);
      editor.selection = sel.copyWith(start: at, end: at);
      await s.pump(200);
      await s.ctrl(LogicalKeyboardKey.keyK);
      await s.pump(300);
      s.nb.current!.replaceBoxData({id: _text('x')});
      await s.pump(600);
      await confirm(s, 'https://later.example');
      expect(find.text(linkNotAddedNotice), findsOneWidget);
      await s.flush();
      expect(snapshotOf(s, id), isNot(contains('later.example')));
    });
  });

  testWidgets('text inserted before the caret under the dialog: the link is not put on other text', (t) async {
    await withSession(t, 'linkshift', (s) async {
      final id = addNote(s, [para('go: ')]);
      await s.pump(600);
      final editor = await editNote(s, id);
      final sel = editor.selection;
      final at = sel.start.copyWith(path: [0], offset: 4);
      editor.selection = sel.copyWith(start: at, end: at);
      await s.pump(200);
      await s.ctrl(LogicalKeyboardKey.keyK);
      await s.pump(300);
      s.nb.current!.replaceBoxData({id: _text('Hi go: ')});
      await s.pump(600);
      await confirm(s, 'https://later.example');
      expect(find.text(linkNotAddedNotice), findsOneWidget);
      await s.flush();
      expect(snapshotOf(s, id), isNot(contains('later.example')));
    });
  });
}
